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

type Server struct {
	db        *sql.DB
	secret    []byte
	dummyHash []byte
}

func New(db *sql.DB, jwtSecret []byte) *Server {
	if db == nil {
		panic("authserver: nil database")
	}
	if len(jwtSecret) == 0 {
		panic("authserver: empty JWT secret")
	}
	dummyHash, _ := bcrypt.GenerateFromPassword([]byte("invalid-password"), bcrypt.DefaultCost)
	return &Server{db: db, secret: append([]byte(nil), jwtSecret...), dummyHash: dummyHash}
}

func (s *Server) Init(ctx context.Context) error {
	_, err := s.db.ExecContext(ctx, `PRAGMA journal_mode=WAL;
	PRAGMA busy_timeout=5000;
	CREATE TABLE IF NOT EXISTS users (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		phone TEXT UNIQUE NOT NULL,
		password_hash TEXT NOT NULL,
		created_at INTEGER NOT NULL
	)`)
	return err
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
	var exists int
	err := s.db.QueryRowContext(r.Context(), "SELECT 1 FROM users WHERE phone=?", phone).Scan(&exists)
	if err == nil {
		writeError(w, http.StatusConflict, "phone_already_registered", "phone already registered")
		return
	}
	if !errors.Is(err, sql.ErrNoRows) {
		writeError(w, http.StatusInternalServerError, "internal_error", "registration failed")
		return
	}
	hash, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal_error", "password hashing failed")
		return
	}
	_, err = s.db.ExecContext(
		r.Context(),
		"INSERT INTO users(phone,password_hash,created_at) VALUES(?,?,?)",
		phone,
		string(hash),
		time.Now().UnixMilli(),
	)
	if err != nil {
		if s.db.QueryRowContext(r.Context(), "SELECT 1 FROM users WHERE phone=?", phone).Scan(&exists) == nil {
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
	var id int64
	var hash string
	err := s.db.QueryRowContext(
		r.Context(),
		"SELECT id,password_hash FROM users WHERE phone=?",
		phone,
	).Scan(&id, &hash)
	if errors.Is(err, sql.ErrNoRows) {
		hash = string(s.dummyHash)
	}
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		writeError(w, http.StatusInternalServerError, "internal_error", "login failed")
		return
	}
	passwordError := bcrypt.CompareHashAndPassword([]byte(hash), []byte(password))
	if errors.Is(err, sql.ErrNoRows) || passwordError != nil {
		writeError(w, http.StatusUnauthorized, "invalid_credentials", "invalid phone or password")
		return
	}
	token := jwt.NewWithClaims(jwt.SigningMethodHS256, jwt.MapClaims{
		"sub": strconv.FormatInt(id, 10),
		"exp": time.Now().Add(30 * 24 * time.Hour).Unix(),
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
	var phone string
	if err := s.db.QueryRowContext(r.Context(), "SELECT phone FROM users WHERE id=?", id).Scan(&phone); err != nil {
		writeError(w, http.StatusNotFound, "user_not_found", "user not found")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"id": id, "phone": phone})
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
		return 0, errors.New("missing bearer token")
	}
	token, err := jwt.Parse(
		strings.TrimSpace(tokenText),
		func(*jwt.Token) (any, error) { return s.secret, nil },
		jwt.WithValidMethods([]string{jwt.SigningMethodHS256.Alg()}),
	)
	if err != nil || !token.Valid {
		return 0, errors.New("invalid token")
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
