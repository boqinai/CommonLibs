package authserver

import (
	"context"
	"database/sql"
	"encoding/json"
	"net/http"
	"net/http/httptest"
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
	}
	if res := call("POST", "/api/auth/login", "", `{"phone":"13800000000","password":"bad-password"}`); res.Code != http.StatusUnauthorized {
		t.Fatalf("bad login: %d %s", res.Code, res.Body.String())
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
	if res := call("GET", "/private", "", ""); res.Code != http.StatusUnauthorized {
		t.Fatalf("unauthorized: %d %s", res.Code, res.Body.String())
	}
}
