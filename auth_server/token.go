package authserver

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

const (
	// DefaultAccessTokenTTL is the access-token lifetime when WithTokenExpiry
	// is not set.
	DefaultAccessTokenTTL = 2 * time.Hour
	// DefaultRefreshTokenTTL is the refresh-token lifetime when
	// WithRefreshTokenExpiry is not set.
	DefaultRefreshTokenTTL = 30 * 24 * time.Hour

	// TokenTypeAccess and TokenTypeRefresh are the "typ" claim values.
	TokenTypeAccess  = "access"
	TokenTypeRefresh = "refresh"
)

// TokenPair is an access token plus a refresh token for the same user.
type TokenPair struct {
	AccessToken  string
	RefreshToken string
	ExpiresIn    time.Duration // access token TTL
}

// TokenBlacklist records revoked token IDs (jti) until each token's own
// expiry. Revoke of an already-expired token should be a no-op. IsRevoked
// must return false once exp has passed so callers can drop the row.
//
// The default implementation is MemoryTokenBlacklist: process-local, no
// database. Hosts that run more than one instance need a shared store
// (WithTokenBlacklist). A SQLite store, if added by a host, should stay
// compatible with SQLite 3.22 (no UPSERT or RETURNING).
type TokenBlacklist interface {
	Revoke(ctx context.Context, jti string, exp time.Time) error
	IsRevoked(ctx context.Context, jti string) (bool, error)
}

// MemoryTokenBlacklist keeps revoked jti values in memory until exp.
// It is not shared across processes.
type MemoryTokenBlacklist struct {
	mu    sync.Mutex
	until map[string]time.Time
	// now is replaceable by tests. Production leaves it nil (time.Now).
	now func() time.Time
}

// NewMemoryTokenBlacklist returns an empty in-memory blacklist.
func NewMemoryTokenBlacklist() *MemoryTokenBlacklist {
	return &MemoryTokenBlacklist{}
}

func (m *MemoryTokenBlacklist) clock() time.Time {
	if m.now != nil {
		return m.now()
	}
	return time.Now()
}

func (m *MemoryTokenBlacklist) compactLocked(now time.Time) {
	for jti, exp := range m.until {
		if !exp.After(now) {
			delete(m.until, jti)
		}
	}
}

// Revoke marks jti unusable until exp. An empty jti or an expiry that is
// not in the future is ignored.
func (m *MemoryTokenBlacklist) Revoke(_ context.Context, jti string, exp time.Time) error {
	now := m.clock()
	if jti == "" || !exp.After(now) {
		return nil
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.until == nil {
		m.until = map[string]time.Time{}
	}
	if len(m.until) > 1024 {
		m.compactLocked(now)
	}
	m.until[jti] = exp
	return nil
}

// IsRevoked reports whether jti is still revoked. Expired entries are
// deleted and reported as not revoked.
func (m *MemoryTokenBlacklist) IsRevoked(_ context.Context, jti string) (bool, error) {
	if jti == "" {
		return false, nil
	}
	now := m.clock()
	m.mu.Lock()
	defer m.mu.Unlock()
	exp, ok := m.until[jti]
	if !ok {
		return false, nil
	}
	if !exp.After(now) {
		delete(m.until, jti)
		return false, nil
	}
	return true, nil
}

type sessionClaims struct {
	jwt.RegisteredClaims
	Typ string `json:"typ,omitempty"`
}

// IssueToken signs an HS256 access token (typ=access, with jti) accepted by
// RequireAuth. The default lifetime is DefaultAccessTokenTTL.
func (s *Server) IssueToken(userID int64) (string, error) {
	signed, _, _, err := s.sign(userID, TokenTypeAccess, s.tokenExpiry)
	return signed, err
}

// IssueTokens signs an access token and a refresh token. Login, SMS login,
// and fusion login use this. Register does not issue a JWT.
func (s *Server) IssueTokens(userID int64) (TokenPair, error) {
	access, _, _, err := s.sign(userID, TokenTypeAccess, s.tokenExpiry)
	if err != nil {
		return TokenPair{}, err
	}
	refresh, _, _, err := s.sign(userID, TokenTypeRefresh, s.refreshExpiry)
	if err != nil {
		return TokenPair{}, err
	}
	return TokenPair{
		AccessToken:  access,
		RefreshToken: refresh,
		ExpiresIn:    s.tokenExpiry,
	}, nil
}

func (s *Server) sign(userID int64, typ string, ttl time.Duration) (string, string, time.Time, error) {
	now := time.Now()
	exp := now.Add(ttl)
	jti, err := newJTI()
	if err != nil {
		return "", "", time.Time{}, err
	}
	signed, err := jwt.NewWithClaims(jwt.SigningMethodHS256, sessionClaims{
		RegisteredClaims: jwt.RegisteredClaims{
			Subject:   strconv.FormatInt(userID, 10),
			ExpiresAt: jwt.NewNumericDate(exp),
			IssuedAt:  jwt.NewNumericDate(now),
			ID:        jti,
		},
		Typ: typ,
	}).SignedString(s.secret)
	if err != nil {
		return "", "", time.Time{}, err
	}
	return signed, jti, exp, nil
}

func newJTI() (string, error) {
	var buf [16]byte
	if _, err := rand.Read(buf[:]); err != nil {
		return "", err
	}
	return hex.EncodeToString(buf[:]), nil
}

func (s *Server) writeAuthSession(w http.ResponseWriter, user *User, created *bool) {
	body, err := s.tokenPairJSON(user.ID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, CodeInternalError, "token creation failed")
		return
	}
	body["user"] = userJSON(user)
	if created != nil {
		body["created"] = *created
	}
	writeJSON(w, http.StatusOK, body)
}

func (s *Server) tokenPairJSON(userID int64) (map[string]any, error) {
	pair, err := s.IssueTokens(userID)
	if err != nil {
		return nil, err
	}
	return map[string]any{
		"token":         pair.AccessToken,
		"refresh_token": pair.RefreshToken,
		"expires_in":    int64(pair.ExpiresIn / time.Second),
	}, nil
}

// Refresh exchanges a refresh token for a new access/refresh pair and
// revokes the presented refresh token's jti (rotation).
func (s *Server) Refresh(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, CodeMethodNotAllowed, "method not allowed")
		return
	}
	var in struct {
		RefreshToken string `json:"refresh_token"`
	}
	if !decodeBody(w, r, &in) {
		return
	}
	raw := strings.TrimSpace(in.RefreshToken)
	if raw == "" {
		writeError(w, http.StatusBadRequest, CodeInvalidRequest, "invalid request")
		return
	}
	claims, err := s.parseRaw(raw, false)
	if err != nil || claims.Typ != TokenTypeRefresh || claims.ID == "" || claims.ExpiresAt == nil {
		writeError(w, http.StatusUnauthorized, CodeInvalidRefreshToken, "invalid refresh token")
		return
	}
	if err := s.rejectRevoked(r.Context(), claims); err != nil {
		writeError(w, http.StatusUnauthorized, CodeInvalidRefreshToken, "invalid refresh token")
		return
	}
	userID, err := strconv.ParseInt(claims.Subject, 10, 64)
	if err != nil || userID <= 0 {
		writeError(w, http.StatusUnauthorized, CodeInvalidRefreshToken, "invalid refresh token")
		return
	}
	ctx, cancel := s.dbContext(r.Context())
	defer cancel()
	if _, err := s.store.GetUserByID(ctx, userID); err != nil {
		if errors.Is(err, ErrUserNotFound) {
			writeError(w, http.StatusUnauthorized, CodeInvalidRefreshToken, "invalid refresh token")
			return
		}
		writeError(w, http.StatusInternalServerError, CodeInternalError, "login failed")
		return
	}
	if s.blacklist != nil {
		if err := s.blacklist.Revoke(r.Context(), claims.ID, claims.ExpiresAt.Time); err != nil {
			writeError(w, http.StatusInternalServerError, CodeInternalError, "token revocation failed")
			return
		}
	}
	body, err := s.tokenPairJSON(userID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, CodeInternalError, "token creation failed")
		return
	}
	writeJSON(w, http.StatusOK, body)
}

// Logout revokes the bearer access token (signature checked, expiry ignored)
// and, when the body includes refresh_token, that refresh token too.
// Unknown or already-expired tokens are ignored. The response is {"ok":true}
// unless the blacklist store itself fails.
func (s *Server) Logout(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, CodeMethodNotAllowed, "method not allowed")
		return
	}
	var in struct {
		RefreshToken string `json:"refresh_token"`
	}
	if !decodeOptionalJSON(w, r, &in) {
		return
	}
	var failed error
	if raw, err := bearerToken(r.Header.Get("Authorization")); err == nil {
		if err := s.revokeSigned(r.Context(), raw); err != nil {
			failed = err
		}
	}
	if refresh := strings.TrimSpace(in.RefreshToken); refresh != "" {
		if err := s.revokeSigned(r.Context(), refresh); err != nil {
			failed = err
		}
	}
	if failed != nil {
		writeError(w, http.StatusInternalServerError, CodeInternalError, "logout failed")
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

func (s *Server) revokeSigned(ctx context.Context, raw string) error {
	claims, err := s.parseRaw(raw, true)
	if err != nil || claims.ID == "" || claims.ExpiresAt == nil || s.blacklist == nil {
		return nil
	}
	return s.blacklist.Revoke(ctx, claims.ID, claims.ExpiresAt.Time)
}

func (s *Server) authenticate(ctx context.Context, header string) (int64, error) {
	raw, err := bearerToken(header)
	if err != nil {
		return 0, err
	}
	claims, err := s.parseRaw(raw, false)
	if err != nil {
		return 0, err
	}
	// Access tokens always carry typ=access and a jti. Refresh tokens, and
	// any token missing those claims, do not authorize API calls.
	if claims.Typ != TokenTypeAccess || claims.ID == "" {
		return 0, ErrInvalidToken
	}
	if err := s.rejectRevoked(ctx, claims); err != nil {
		return 0, err
	}
	id, err := strconv.ParseInt(claims.Subject, 10, 64)
	if err != nil || id <= 0 {
		return 0, ErrInvalidToken
	}
	return id, nil
}

func (s *Server) rejectRevoked(ctx context.Context, claims *sessionClaims) error {
	if claims.ID == "" || s.blacklist == nil {
		return nil
	}
	revoked, err := s.blacklist.IsRevoked(ctx, claims.ID)
	if err != nil || revoked {
		return ErrInvalidToken
	}
	return nil
}

func bearerToken(header string) (string, error) {
	scheme, tokenText, found := strings.Cut(header, " ")
	if !found || !strings.EqualFold(scheme, "Bearer") || strings.TrimSpace(tokenText) == "" {
		return "", ErrMissingBearerToken
	}
	return strings.TrimSpace(tokenText), nil
}

func (s *Server) parseRaw(tokenText string, allowExpired bool) (*sessionClaims, error) {
	options := []jwt.ParserOption{
		jwt.WithValidMethods([]string{jwt.SigningMethodHS256.Alg()}),
		jwt.WithExpirationRequired(),
	}
	if allowExpired {
		options = []jwt.ParserOption{
			jwt.WithValidMethods([]string{jwt.SigningMethodHS256.Alg()}),
			jwt.WithoutClaimsValidation(),
		}
	}
	claims := &sessionClaims{}
	token, err := jwt.ParseWithClaims(strings.TrimSpace(tokenText), claims, func(*jwt.Token) (any, error) {
		return s.secret, nil
	}, options...)
	if err != nil || !token.Valid {
		return nil, ErrInvalidToken
	}
	if strings.TrimSpace(claims.Subject) == "" {
		return nil, ErrInvalidToken
	}
	if !allowExpired && claims.ExpiresAt == nil {
		return nil, ErrInvalidToken
	}
	return claims, nil
}

func decodeOptionalJSON(w http.ResponseWriter, r *http.Request, dest any) bool {
	r.Body = http.MaxBytesReader(w, r.Body, 1<<16)
	raw, err := io.ReadAll(r.Body)
	if err != nil {
		writeError(w, http.StatusBadRequest, CodeInvalidRequest, "invalid request")
		return false
	}
	if len(bytes.TrimSpace(raw)) == 0 {
		return true
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	if dec.Decode(dest) != nil || dec.Decode(&struct{}{}) != io.EOF {
		writeError(w, http.StatusBadRequest, CodeInvalidRequest, "invalid request")
		return false
	}
	return true
}
