package authserver

import (
	"context"
	"database/sql"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

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
