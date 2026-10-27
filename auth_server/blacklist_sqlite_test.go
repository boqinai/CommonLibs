package authserver

import (
	"context"
	"database/sql"
	"os"
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
