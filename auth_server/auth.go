package authserver

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/netip"
	"regexp"
	"strconv"
	"strings"
	"time"

	"golang.org/x/crypto/bcrypt"
)

type userContextKey struct{}

var (
	ErrMissingBearerToken = errors.New("authserver: missing bearer token")
	ErrInvalidToken       = errors.New("authserver: invalid token")
)

type Option func(*Server)

// WithTokenExpiry sets the access-token lifetime. The default is
// DefaultAccessTokenTTL (2 hours). The value must be positive.
func WithTokenExpiry(expiry time.Duration) Option { return func(s *Server) { s.tokenExpiry = expiry } }

// WithRefreshTokenExpiry sets the refresh-token lifetime. The default is
// DefaultRefreshTokenTTL (30 days). The value must be positive.
func WithRefreshTokenExpiry(expiry time.Duration) Option {
	return func(s *Server) { s.refreshExpiry = expiry }
}

// WithTokenBlacklist sets the jti revocation store. Nil uses
// MemoryTokenBlacklist, which is process-local and needs no database.
// Multi-instance deployments must pass a shared store.
func WithTokenBlacklist(blacklist TokenBlacklist) Option {
	return func(s *Server) { s.blacklist = blacklist }
}
func WithBcryptCost(cost int) Option { return func(s *Server) { s.bcryptCost = cost } }
func WithDatabaseTimeout(timeout time.Duration) Option {
	return func(s *Server) { s.databaseTimeout = timeout }
}

// WithCredentialRateLimiters replaces the default per-IP limiters on
// /register and /login (20/hour and 30/10min). Pass nil limiters via
// WithoutCredentialRateLimit for tests.
func WithCredentialRateLimiters(register, login *RateLimiter) Option {
	return func(s *Server) {
		s.registerLimiter = register
		s.loginLimiter = login
	}
}

// WithoutCredentialRateLimit disables built-in /register and /login rate
// limits (useful in tests). Production hosts should keep the defaults or
// supply their own limiters.
func WithoutCredentialRateLimit() Option {
	return func(s *Server) {
		s.registerLimiter = nil
		s.loginLimiter = nil
	}
}

// WithPhoneValidator overrides the password register/login phone check.
// The default is MainlandPhone. A nil regexp is ignored.
func WithPhoneValidator(re *regexp.Regexp) Option {
	return func(s *Server) {
		if re != nil {
			s.phoneValidator = re
		}
	}
}

// WithTrustedProxies enables X-Forwarded-For parsing for peers in this list.
// Build the list with ParseTrustedProxies so an invalid PENNY_TRUSTED_PROXIES
// value returns an error instead of panicking inside New. The header is
// ignored for every other peer, which is the default when this option is
// omitted. When WithClientIPResolver is also set, the resolver wins.
//
// If every forwarded hop is itself trusted, the rate-limit key is the TCP
// peer (RemoteAddr), not the leftmost X-Forwarded-For value. A hop that is
// not a valid IP is not a key either: that header is abandoned and the peer
// is used, so illegal strings cannot rotate into fresh buckets.
func WithTrustedProxies(prefixes ...netip.Prefix) Option {
	copied := append([]netip.Prefix(nil), prefixes...)
	return func(s *Server) {
		s.trustedProxies = copied
	}
}

// WithClientIPResolver sets the rate-limit key function. It replaces both
// RemoteAddr and trusted-proxy X-Forwarded-For handling. A nil resolver panics.
func WithClientIPResolver(resolve ClientIPResolver) Option {
	return func(s *Server) {
		if resolve == nil {
			panic("authserver: nil ClientIPResolver")
		}
		s.clientIPResolver = resolve
	}
}

type Server struct {
	store            UserStore
	secret           []byte
	dummyHash        []byte
	tokenExpiry      time.Duration
	refreshExpiry    time.Duration
	blacklist        TokenBlacklist
	bcryptCost       int
	databaseTimeout  time.Duration
	registerLimiter  *RateLimiter
	loginLimiter     *RateLimiter
	refreshLimiter   *RateLimiter
	phoneValidator   *regexp.Regexp
	minPasswordLen   int
	trustedProxies   []netip.Prefix
	clientIPResolver ClientIPResolver
	// signer, when set, replaces HS256 issuance. Production leaves it nil.
	// Tests set it so a failing signer does not consume the refresh token.
	signer func(userID int64, typ string, ttl time.Duration) (string, string, time.Time, error)
}

func New(db *sql.DB, jwtSecret []byte, options ...Option) *Server {
	if db == nil {
		panic("authserver: nil database")
	}
	if len(jwtSecret) == 0 {
		panic("authserver: empty JWT secret")
	}
	return newWithStore(NewSQLiteUserStore(db), jwtSecret, options...)
}

func NewWithStore(store UserStore, jwtSecret []byte, options ...Option) *Server {
	if store == nil {
		panic("authserver: nil user store")
	}
	if len(jwtSecret) == 0 {
		panic("authserver: empty JWT secret")
	}
	return newWithStore(store, jwtSecret, options...)
}

func newWithStore(store UserStore, jwtSecret []byte, options ...Option) *Server {
	server := &Server{
		store:           store,
		secret:          append([]byte(nil), jwtSecret...),
		tokenExpiry:     DefaultAccessTokenTTL,
		refreshExpiry:   DefaultRefreshTokenTTL,
		bcryptCost:      bcrypt.DefaultCost,
		databaseTimeout: 5 * time.Second,
		registerLimiter: NewRateLimiter(20, time.Hour),
		loginLimiter:    NewRateLimiter(30, 10*time.Minute),
		refreshLimiter:  NewRateLimiter(60, 10*time.Minute),
		phoneValidator:  MainlandPhone,
		minPasswordLen:  8,
	}
	for _, option := range options {
		option(server)
	}
	if server.tokenExpiry <= 0 {
		panic("authserver: token expiry must be positive")
	}
	if server.refreshExpiry <= 0 {
		panic("authserver: refresh token expiry must be positive")
	}
	if server.blacklist == nil {
		server.blacklist = NewMemoryTokenBlacklist()
	}
	if server.databaseTimeout <= 0 {
		panic("authserver: database timeout must be positive")
	}
	if server.minPasswordLen < 8 {
		server.minPasswordLen = 8
	}
	if server.minPasswordLen > 72 {
		panic("authserver: min password length must be <= 72")
	}
	dummyHash, err := bcrypt.GenerateFromPassword([]byte("invalid-password"), server.bcryptCost)
	if err != nil {
		panic("authserver: invalid bcrypt cost")
	}
	server.dummyHash = dummyHash
	return server
}

func (s *Server) dbContext(parent context.Context) (context.Context, context.CancelFunc) {
	return context.WithTimeout(parent, s.databaseTimeout)
}

func (s *Server) Init(ctx context.Context) error {
	return s.store.Init(ctx)
}

func (s *Server) RegisterRoutes(mux *http.ServeMux) {
	mux.Handle("/api/auth/register", s.maybeLimited(s.registerLimiter, http.HandlerFunc(s.Register)))
	mux.Handle("/api/auth/login", s.maybeLimited(s.loginLimiter, http.HandlerFunc(s.Login)))
	mux.Handle("/api/auth/refresh", s.maybeLimited(s.refreshLimiter, http.HandlerFunc(s.Refresh)))
	mux.Handle("/api/auth/logout", http.HandlerFunc(s.Logout))
	mux.Handle("/api/auth/me", s.RequireAuth(http.HandlerFunc(s.Me)))
	mux.Handle("/api/auth/profile", s.RequireAuth(http.HandlerFunc(s.UpdateProfile)))
}

func (s *Server) maybeLimited(l *RateLimiter, next http.Handler) http.Handler {
	if l == nil {
		return next
	}
	return limited(l, s.requestClientIP, next)
}

func (s *Server) requestClientIP(r *http.Request) string {
	if s.clientIPResolver != nil {
		return s.clientIPResolver(r)
	}
	return clientIP(r, s.trustedProxies)
}

func (s *Server) Register(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, CodeMethodNotAllowed, "method not allowed")
		return
	}
	phone, password, ok := s.credentials(w, r)
	if !ok {
		return
	}
	ctx, cancel := s.dbContext(r.Context())
	defer cancel()
	exists, err := s.store.UserExists(ctx, phone)
	if err != nil {
		writeError(w, http.StatusInternalServerError, CodeInternalError, "registration failed")
		return
	}
	if exists {
		writeError(w, http.StatusConflict, CodePhoneAlreadyRegistered, "phone already registered")
		return
	}
	hash, err := bcrypt.GenerateFromPassword([]byte(password), s.bcryptCost)
	if err != nil {
		writeError(w, http.StatusInternalServerError, CodeInternalError, "password hashing failed")
		return
	}
	_, err = s.store.CreateUser(ctx, phone, string(hash))
	if err != nil {
		if exists, _ := s.store.UserExists(ctx, phone); exists {
			writeError(w, http.StatusConflict, CodePhoneAlreadyRegistered, "phone already registered")
			return
		}
		writeError(w, http.StatusInternalServerError, CodeInternalError, "registration failed")
		return
	}
	writeJSON(w, http.StatusCreated, map[string]bool{"ok": true})
}

func (s *Server) Login(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, CodeMethodNotAllowed, "method not allowed")
		return
	}
	phone, password, ok := s.credentials(w, r)
	if !ok {
		return
	}
	ctx, cancel := s.dbContext(r.Context())
	defer cancel()
	user, err := s.store.GetUserByPhone(ctx, phone)
	hash := string(s.dummyHash)
	if err == nil {
		hash = user.PasswordHash
	}
	if err != nil && !errors.Is(err, ErrUserNotFound) {
		writeError(w, http.StatusInternalServerError, CodeInternalError, "login failed")
		return
	}
	passwordError := bcrypt.CompareHashAndPassword([]byte(hash), []byte(password))
	if errors.Is(err, ErrUserNotFound) || passwordError != nil {
		writeError(w, http.StatusUnauthorized, CodeInvalidCredentials, "invalid phone or password")
		return
	}
	s.writeAuthSession(w, user, nil)
}

func (s *Server) Me(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, CodeMethodNotAllowed, "method not allowed")
		return
	}
	id, ok := UserID(r)
	if !ok {
		writeError(w, http.StatusUnauthorized, CodeUnauthorized, "unauthorized")
		return
	}
	ctx, cancel := s.dbContext(r.Context())
	defer cancel()
	user, err := s.store.GetUserByID(ctx, id)
	if errors.Is(err, ErrUserNotFound) {
		writeError(w, http.StatusNotFound, CodeUserNotFound, "user not found")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, CodeInternalError, "user lookup failed")
		return
	}
	writeJSON(w, http.StatusOK, userJSON(user))
}

func (s *Server) UpdateProfile(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPut && r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, CodeMethodNotAllowed, "method not allowed")
		return
	}
	id, ok := UserID(r)
	if !ok {
		writeError(w, http.StatusUnauthorized, CodeUnauthorized, "unauthorized")
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 1<<20)
	var input struct {
		Nickname *string `json:"nickname"`
		Avatar   *string `json:"avatar"`
	}
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if decoder.Decode(&input) != nil || decoder.Decode(&struct{}{}) != io.EOF {
		writeError(w, http.StatusBadRequest, CodeInvalidRequest, "invalid request")
		return
	}
	ctx, cancel := s.dbContext(r.Context())
	defer cancel()
	var nickname *string
	if input.Nickname != nil {
		value := strings.TrimSpace(*input.Nickname)
		nickname = &value
	}
	var avatar *string
	if input.Avatar != nil {
		value := strings.TrimSpace(*input.Avatar)
		avatar = &value
	}
	if (nickname != nil && len(*nickname) > 64) ||
		(avatar != nil && len(*avatar) > 256) {
		writeError(w, http.StatusBadRequest, CodeInvalidRequest, "nickname must be <= 64 bytes and avatar <= 256 bytes")
		return
	}
	profileStore, ok := s.store.(UserProfileStore)
	if !ok {
		writeError(w, http.StatusNotImplemented, CodeProfileNotSupported, "user store does not support profiles")
		return
	}
	user, err := profileStore.UpdateProfile(ctx, id, nickname, avatar)
	if errors.Is(err, ErrUserNotFound) {
		writeError(w, http.StatusNotFound, CodeUserNotFound, "user not found")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, CodeInternalError, "failed to update profile")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"ok": true,
		"profile": map[string]any{
			"id":       id,
			"phone":    user.Phone,
			"nickname": user.Nickname,
			"avatar":   user.Avatar,
		},
	})
}

func (s *Server) RequireAuth(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		id, err := s.authenticate(r.Context(), r.Header.Get("Authorization"))
		if err != nil {
			writeError(w, http.StatusUnauthorized, CodeUnauthorized, "unauthorized")
			return
		}
		next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), userContextKey{}, id)))
	})
}

func UserID(r *http.Request) (int64, bool) {
	id, ok := r.Context().Value(userContextKey{}).(int64)
	return id, ok
}

func (s *Server) credentials(w http.ResponseWriter, r *http.Request) (string, string, bool) {
	r.Body = http.MaxBytesReader(w, r.Body, 1<<20)
	var input struct {
		Phone    string `json:"phone"`
		Password string `json:"password"`
	}
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if decoder.Decode(&input) != nil || decoder.Decode(&struct{}{}) != io.EOF {
		writeError(w, http.StatusBadRequest, CodeInvalidRequest, "invalid request")
		return "", "", false
	}
	input.Phone = strings.TrimSpace(input.Phone)
	minPass := s.minPasswordLen
	if minPass < 8 {
		minPass = 8
	}
	if !s.phoneValidator.MatchString(input.Phone) || len(input.Password) < minPass || len(input.Password) > 72 {
		writeError(w, http.StatusBadRequest, CodeInvalidCredentialsFormat,
			"phone format invalid and password must contain "+strconv.Itoa(minPass)+"-72 bytes")
		return "", "", false
	}
	return input.Phone, input.Password, true
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}

func writeError(w http.ResponseWriter, status int, code, message string) {
	writeJSON(w, status, map[string]string{"code": code, "message": message})
}

func userJSON(user *User) map[string]any {
	return map[string]any{
		"id":       user.ID,
		"phone":    user.Phone,
		"nickname": user.Nickname,
		"avatar":   user.Avatar,
	}
}
