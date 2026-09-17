package authserver

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"golang.org/x/crypto/bcrypt"
)

type userContextKey struct{}

var (
	ErrMissingBearerToken = errors.New("authserver: missing bearer token")
	ErrInvalidToken       = errors.New("authserver: invalid token")
)

type Option func(*Server)

func WithTokenExpiry(expiry time.Duration) Option { return func(s *Server) { s.tokenExpiry = expiry } }
func WithBcryptCost(cost int) Option               { return func(s *Server) { s.bcryptCost = cost } }
func WithDatabaseTimeout(timeout time.Duration) Option {
	return func(s *Server) { s.databaseTimeout = timeout }
}

type Server struct {
	store           UserStore
	secret          []byte
	dummyHash       []byte
	tokenExpiry     time.Duration
	bcryptCost      int
	databaseTimeout time.Duration
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
		tokenExpiry:     30 * 24 * time.Hour,
		bcryptCost:      bcrypt.DefaultCost,
		databaseTimeout: 5 * time.Second,
	}
	for _, option := range options {
		option(server)
	}
	if server.tokenExpiry <= 0 {
		panic("authserver: token expiry must be positive")
	}
	if server.databaseTimeout <= 0 {
		panic("authserver: database timeout must be positive")
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
	mux.HandleFunc("/api/auth/register", s.Register)
	mux.HandleFunc("/api/auth/login", s.Login)
	mux.Handle("/api/auth/me", s.RequireAuth(http.HandlerFunc(s.Me)))
}

func (s *Server) Register(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "method not allowed")
		return
	}
	phone, password, ok := credentials(w, r)
	if !ok {
		return
	}
	ctx, cancel := s.dbContext(r.Context())
	defer cancel()
	exists, err := s.store.UserExists(ctx, phone)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal_error", "registration failed")
		return
	}
	if exists {
		writeError(w, http.StatusConflict, "phone_already_registered", "phone already registered")
		return
	}
	hash, err := bcrypt.GenerateFromPassword([]byte(password), s.bcryptCost)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal_error", "password hashing failed")
		return
	}
	_, err = s.store.CreateUser(ctx, phone, string(hash))
	if err != nil {
		if exists, _ := s.store.UserExists(ctx, phone); exists {
			writeError(w, http.StatusConflict, "phone_already_registered", "phone already registered")
			return
		}
		writeError(w, http.StatusInternalServerError, "internal_error", "registration failed")
		return
	}
	writeJSON(w, http.StatusCreated, map[string]bool{"ok": true})
}

func (s *Server) Login(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "method not allowed")
		return
	}
	phone, password, ok := credentials(w, r)
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
		writeError(w, http.StatusInternalServerError, "internal_error", "login failed")
		return
	}
	passwordError := bcrypt.CompareHashAndPassword([]byte(hash), []byte(password))
	if errors.Is(err, ErrUserNotFound) || passwordError != nil {
		writeError(w, http.StatusUnauthorized, "invalid_credentials", "invalid phone or password")
		return
	}
	token := jwt.NewWithClaims(jwt.SigningMethodHS256, jwt.MapClaims{
		"sub": strconv.FormatInt(user.ID, 10),
		"exp": time.Now().Add(s.tokenExpiry).Unix(),
	})
	signed, err := token.SignedString(s.secret)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal_error", "token creation failed")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"token": signed})
}

func (s *Server) Me(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "method not allowed")
		return
	}
	id, ok := UserID(r)
	if !ok {
		writeError(w, http.StatusUnauthorized, "unauthorized", "unauthorized")
		return
	}
	ctx, cancel := s.dbContext(r.Context())
	defer cancel()
	user, err := s.store.GetUserByID(ctx, id)
	if errors.Is(err, ErrUserNotFound) {
		writeError(w, http.StatusNotFound, "user_not_found", "user not found")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal_error", "user lookup failed")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"id": id, "phone": user.Phone})
}

func (s *Server) RequireAuth(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		id, err := s.authenticate(r.Header.Get("Authorization"))
		if err != nil {
			writeError(w, http.StatusUnauthorized, "unauthorized", "unauthorized")
			return
		}
		next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), userContextKey{}, id)))
	})
}

func UserID(r *http.Request) (int64, bool) {
	id, ok := r.Context().Value(userContextKey{}).(int64)
	return id, ok
}

func (s *Server) authenticate(header string) (int64, error) {
	scheme, tokenText, found := strings.Cut(header, " ")
	if !found || !strings.EqualFold(scheme, "Bearer") {
		return 0, ErrMissingBearerToken
	}
	token, err := jwt.Parse(
		strings.TrimSpace(tokenText),
		func(*jwt.Token) (any, error) { return s.secret, nil },
		jwt.WithValidMethods([]string{jwt.SigningMethodHS256.Alg()}),
	)
	if err != nil || !token.Valid {
		return 0, ErrInvalidToken
	}
	subject, err := token.Claims.GetSubject()
	if err != nil {
		return 0, err
	}
	return strconv.ParseInt(subject, 10, 64)
}

func credentials(w http.ResponseWriter, r *http.Request) (string, string, bool) {
	r.Body = http.MaxBytesReader(w, r.Body, 1<<20)
	var input struct {
		Phone    string `json:"phone"`
		Password string `json:"password"`
	}
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if decoder.Decode(&input) != nil || decoder.Decode(&struct{}{}) != io.EOF {
		writeError(w, http.StatusBadRequest, "invalid_request", "invalid request")
		return "", "", false
	}
	input.Phone = strings.TrimSpace(input.Phone)
	if len(input.Phone) < 6 ||
		len(input.Phone) > 32 ||
		len(input.Password) < 6 ||
		len(input.Password) > 72 {
		writeError(w, http.StatusBadRequest, "invalid_credentials_format", "phone must contain 6-32 bytes and password 6-72 bytes")
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
