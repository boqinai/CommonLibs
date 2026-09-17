package authserver

import (
	"context"
	"database/sql"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"

	_ "modernc.org/sqlite"
)

func TestRegisterLoginAndAuthenticatedRoutes(t *testing.T) {
	db, err := sql.Open("sqlite", ":memory:")
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	auth := New(db, []byte("test-secret"))
	if err := auth.Init(context.Background()); err != nil {
		t.Fatal(err)
	}
	mux := http.NewServeMux()
	auth.RegisterRoutes(mux)
	mux.Handle("/private", auth.RequireAuth(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		id, ok := UserID(r)
		if !ok {
			t.Fatal("missing user ID")
		}
		writeJSON(w, http.StatusOK, map[string]int64{"id": id})
	})))

	call := func(method, path, token, body string) *httptest.ResponseRecorder {
		t.Helper()
		req := httptest.NewRequest(method, path, strings.NewReader(body))
		if token != "" {
			req.Header.Set("Authorization", "Bearer "+token)
		}
		res := httptest.NewRecorder()
		mux.ServeHTTP(res, req)
		return res
	}

	if res := call("POST", "/api/auth/register", "", `{"phone":"13800000000","password":"123456"}`); res.Code != http.StatusCreated {
		t.Fatalf("register: %d %s", res.Code, res.Body.String())
	}
	if res := call("POST", "/api/auth/register", "", `{"phone":"13800000000","password":"123456"}`); res.Code != http.StatusConflict {
		t.Fatalf("duplicate: %d %s", res.Code, res.Body.String())
	} else {
		var failure struct{ Code string }
		if json.Unmarshal(res.Body.Bytes(), &failure) != nil || failure.Code != "phone_already_registered" {
			t.Fatalf("duplicate error: %s", res.Body.String())
		}
	}
	if res := call("POST", "/api/auth/login", "", `{"phone":"13800000000","password":"bad-password"}`); res.Code != http.StatusUnauthorized {
		t.Fatalf("bad login: %d %s", res.Code, res.Body.String())
	} else {
		var failure struct{ Code string }
		if json.Unmarshal(res.Body.Bytes(), &failure) != nil || failure.Code != "invalid_credentials" {
			t.Fatalf("login error: %s", res.Body.String())
		}
	}

	login := call("POST", "/api/auth/login", "", `{"phone":"13800000000","password":"123456"}`)
	var session struct{ Token string }
	if login.Code != http.StatusOK || json.Unmarshal(login.Body.Bytes(), &session) != nil || session.Token == "" {
		t.Fatalf("login: %d %s", login.Code, login.Body.String())
	}
	if res := call("GET", "/api/auth/me", session.Token, ""); res.Code != http.StatusOK {
		t.Fatalf("me: %d %s", res.Code, res.Body.String())
	}
	if res := call("GET", "/private", session.Token, ""); res.Code != http.StatusOK {
		t.Fatalf("private: %d %s", res.Code, res.Body.String())
	}
	req := httptest.NewRequest("GET", "/private", nil)
	req.Header.Set("Authorization", "bearer "+session.Token)
	res := httptest.NewRecorder()
	mux.ServeHTTP(res, req)
	if res.Code != http.StatusOK {
		t.Fatalf("lowercase bearer: %d %s", res.Code, res.Body.String())
	}
	if res := call("GET", "/private", "", ""); res.Code != http.StatusUnauthorized {
		t.Fatalf("unauthorized: %d %s", res.Code, res.Body.String())
	} else {
		var failure struct{ Code string }
		if json.Unmarshal(res.Body.Bytes(), &failure) != nil || failure.Code != "unauthorized" {
			t.Fatalf("unauthorized error: %s", res.Body.String())
		}
	}
}

func TestInitConfiguresSQLiteForConcurrentWrites(t *testing.T) {
	db, err := sql.Open("sqlite", filepath.Join(t.TempDir(), "auth.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if err := New(db, []byte("test-secret")).Init(context.Background()); err != nil {
		t.Fatal(err)
	}

	var journalMode string
	var busyTimeout int
	if err := db.QueryRow("PRAGMA journal_mode").Scan(&journalMode); err != nil {
		t.Fatal(err)
	}
	if err := db.QueryRow("PRAGMA busy_timeout").Scan(&busyTimeout); err != nil {
		t.Fatal(err)
	}
	if journalMode != "wal" || busyTimeout != 5000 {
		t.Fatalf("journal_mode=%q busy_timeout=%d", journalMode, busyTimeout)
	}
}
