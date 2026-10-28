package authserver

import (
	"context"
	"database/sql"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	_ "modernc.org/sqlite"
)

func TestSQLiteBlacklistConsumeOnce(t *testing.T) {
	db, err := sql.Open("sqlite", "file:blacklist-consume?mode=memory&cache=shared")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = db.Close() })
	db.SetMaxOpenConns(8)
	bl, err := NewSQLiteTokenBlacklist(db)
	if err != nil {
		t.Fatal(err)
	}
	exp := time.Now().Add(time.Hour)
	const n = 32
	var wins atomic.Int32
	var wg sync.WaitGroup
	start := make(chan struct{})
	for range n {
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-start
			ok, err := bl.Consume(context.Background(), "jti-1", exp)
			if err != nil {
				t.Error(err)
				return
			}
			if ok {
				wins.Add(1)
			}
		}()
	}
	close(start)
	wg.Wait()
	if wins.Load() != 1 {
		t.Fatalf("wins=%d", wins.Load())
	}
	revoked, err := bl.IsRevoked(context.Background(), "jti-1")
	if err != nil || !revoked {
		t.Fatalf("revoked=%v err=%v", revoked, err)
	}
	if err := bl.Revoke(context.Background(), "jti-1", exp); err != nil {
		t.Fatal(err)
	}
	ok, err := bl.Consume(context.Background(), "expired", time.Now().Add(-time.Second))
	if err != nil || ok {
		t.Fatal("expired consume")
	}
	revoked, err = bl.IsRevoked(context.Background(), "missing")
	if err != nil || revoked {
		t.Fatal(revoked, err)
	}
}

func TestSQLitePruneAndConsumeSampling(t *testing.T) {
	db := openBlacklistDB(t)
	bl, err := NewSQLiteTokenBlacklist(db)
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	now := time.Now()
	if _, err := db.Exec(`INSERT INTO auth_token_blacklist (jti, exp) VALUES (?, ?), (?, ?)`,
		"old", now.Add(-time.Hour).UnixMilli(),
		"new", now.Add(time.Hour).UnixMilli()); err != nil {
		t.Fatal(err)
	}
	if err := bl.Prune(ctx, now); err != nil {
		t.Fatal(err)
	}
	var n int
	if err := db.QueryRow(`SELECT COUNT(*) FROM auth_token_blacklist`).Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Fatalf("rows after prune: %d", n)
	}
	revoked, err := bl.IsRevoked(ctx, "new")
	if err != nil || !revoked {
		t.Fatalf("new revoked=%v err=%v", revoked, err)
	}
	if _, err := db.Exec(`INSERT INTO auth_token_blacklist (jti, exp) VALUES (?, ?)`, "aged", now.Add(-time.Minute).UnixMilli()); err != nil {
		t.Fatal(err)
	}
	for i := range blacklistPruneEvery {
		if _, err := bl.Consume(ctx, "sample-"+string(rune('a'+i%26))+string(rune('0'+i%10)), now.Add(time.Hour)); err != nil {
			t.Fatal(err)
		}
	}
	if err := db.QueryRow(`SELECT COUNT(*) FROM auth_token_blacklist WHERE jti = ?`, "aged").Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n != 0 {
		t.Fatal("consume sampling left an expired row")
	}
}

func TestSQLiteConsumeWaitsOutBusy(t *testing.T) {
	db := openBlacklistDB(t)
	db.SetMaxOpenConns(2)
	bl, err := NewSQLiteTokenBlacklist(db)
	if err != nil {
		t.Fatal(err)
	}
	holder, err := db.Conn(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	defer holder.Close()
	if _, err := holder.ExecContext(context.Background(), `BEGIN IMMEDIATE`); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() {
		_, err := bl.Consume(context.Background(), "waited", time.Now().Add(time.Hour))
		done <- err
	}()
	select {
	case err := <-done:
		t.Fatalf("consume returned while the database was locked: %v", err)
	case <-time.After(150 * time.Millisecond):
	}
	if _, err := holder.ExecContext(context.Background(), `COMMIT`); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(8 * time.Second):
		t.Fatal("consume did not finish after the lock was released")
	}
}

func TestSQLiteConcurrentRefreshNever500(t *testing.T) {
	db, err := sql.Open("sqlite", filepath.Join(t.TempDir(), "auth.db")+"?_busy_timeout=5000&_journal_mode=WAL")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = db.Close() })
	db.SetMaxOpenConns(8)
	bl, err := NewSQLiteTokenBlacklist(db)
	if err != nil {
		t.Fatal(err)
	}
	srv := New(db, []byte("test-secret"), WithBcryptCost(4), WithTokenBlacklist(bl))
	if err := srv.Init(context.Background()); err != nil {
		t.Fatal(err)
	}
	mux := http.NewServeMux()
	srv.RegisterRoutes(mux)
	post := func(path, body string) (int, map[string]any) {
		t.Helper()
		req := httptest.NewRequest(http.MethodPost, path, strings.NewReader(body))
		req.RemoteAddr = "203.0.113.8:9"
		res := httptest.NewRecorder()
		mux.ServeHTTP(res, req)
		var out map[string]any
		_ = json.Unmarshal(res.Body.Bytes(), &out)
		return res.Code, out
	}
	if code, body := post("/api/auth/register", `{"phone":"13800000000","password":"12345678"}`); code != http.StatusCreated {
		t.Fatal(code, body)
	}
	code, login := post("/api/auth/login", `{"phone":"13800000000","password":"12345678"}`)
	refresh, _ := login["refresh_token"].(string)
	if code != http.StatusOK || refresh == "" {
		t.Fatal(code, login)
	}
	const n = 24
	codes := make([]int, n)
	var wg sync.WaitGroup
	start := make(chan struct{})
	for i := range n {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			<-start
			req := httptest.NewRequest(http.MethodPost, "/api/auth/refresh", strings.NewReader(`{"refresh_token":"`+refresh+`"}`))
			req.RemoteAddr = "203.0.113.9:9"
			res := httptest.NewRecorder()
			mux.ServeHTTP(res, req)
			codes[i] = res.Code
		}(i)
	}
	close(start)
	wg.Wait()
	wins := 0
	for _, code := range codes {
		switch code {
		case http.StatusOK:
			wins++
		case http.StatusUnauthorized:
		default:
			t.Fatalf("status %d in %v", code, codes)
		}
	}
	if wins != 1 {
		t.Fatalf("wins=%d codes=%v", wins, codes)
	}
}

func openBlacklistDB(t *testing.T) *sql.DB {
	t.Helper()
	db, err := sql.Open("sqlite", filepath.Join(t.TempDir(), "blacklist.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = db.Close() })
	return db
}

func TestSQLiteBlacklistSQLStays322(t *testing.T) {
	src, err := os.ReadFile("blacklist_sqlite.go")
	if err != nil {
		t.Fatal(err)
	}
	upper := strings.ToUpper(string(src))
	if strings.Contains(upper, "RETURNING") || strings.Contains(upper, "ON CONFLICT") {
		t.Fatal("blacklist SQL must stay compatible with SQLite 3.22")
	}
}
