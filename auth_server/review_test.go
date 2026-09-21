package authserver

import (
	"context"
	"database/sql"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	_ "modernc.org/sqlite"
)

func TestRejectsOversizedCredentials(t *testing.T) {
	db, err := sql.Open("sqlite", ":memory:")
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	auth := New(db, []byte("test-secret"))
	if err := auth.Init(context.Background()); err != nil {
		t.Fatal(err)
	}

	request := httptest.NewRequest(
		http.MethodPost,
		"/api/auth/register",
		strings.NewReader(`{"phone":"13800000000","password":"`+strings.Repeat("x", 73)+`"}`),
	)
	response := httptest.NewRecorder()
	auth.Register(response, request)
	if response.Code != http.StatusBadRequest {
		t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
	}
}

func TestRejectsNonPositiveDurations(t *testing.T) {
	db, err := sql.Open("sqlite", ":memory:")
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	for _, option := range []Option{WithTokenExpiry(0), WithDatabaseTimeout(-time.Second)} {
		func() {
			defer func() {
				if recover() == nil {
					t.Fatal("expected invalid duration to panic")
				}
			}()
			New(db, []byte("test-secret"), option)
		}()
	}
}

func TestInitDoesNotChangeConnectionPoolLimit(t *testing.T) {
	db, err := sql.Open("sqlite", ":memory:")
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	db.SetMaxOpenConns(7)

	if err := New(db, []byte("test-secret")).Init(context.Background()); err != nil {
		t.Fatal(err)
	}
	if got := db.Stats().MaxOpenConnections; got != 7 {
		t.Fatalf("max open connections changed to %d", got)
	}
}

type legacyUserStore struct{}

func (legacyUserStore) Init(context.Context) error { return nil }
func (legacyUserStore) UserExists(context.Context, string) (bool, error) {
	return false, nil
}
func (legacyUserStore) CreateUser(context.Context, string, string) (int64, error) {
	return 1, nil
}
func (legacyUserStore) GetUserByPhone(context.Context, string) (*User, error) {
	return nil, ErrUserNotFound
}
func (legacyUserStore) GetUserByID(context.Context, int64) (*User, error) {
	return &User{ID: 1, Phone: "13800000000"}, nil
}

func TestLegacyUserStoreRemainsCompatible(t *testing.T) {
	auth := NewWithStore(legacyUserStore{}, []byte("test-secret"))
	request := httptest.NewRequest(http.MethodPut, "/api/auth/profile", strings.NewReader(`{"nickname":"new"}`))
	request = request.WithContext(context.WithValue(request.Context(), userContextKey{}, int64(1)))
	response := httptest.NewRecorder()

	auth.UpdateProfile(response, request)

	if response.Code != http.StatusNotImplemented {
		t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
	}
}
