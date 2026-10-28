package authserver

import (
	"context"
	"database/sql"
	"errors"
	"strings"
	"sync/atomic"
	"time"

	"modernc.org/sqlite"
)

// SQLiteTokenBlacklist is a process-shared TokenBlacklist on SQLite 3.22
// or newer. Consume checks and inserts inside one immediate transaction.
// jti is the primary key, so a second insert does not land. The statements
// are INSERT OR IGNORE plus RowsAffected, which SQLite 3.22 already has.
//
// Each attempt sets busy_timeout and starts with BEGIN IMMEDIATE, then
// retries SQLITE_BUSY. The loser of a concurrent Consume observes the
// committed row and returns revoked (false), which refresh maps to 401.
type SQLiteTokenBlacklist struct {
	db  *sql.DB
	ops atomic.Uint32
}

// NewSQLiteTokenBlacklist creates the revocation table when it is missing.
func NewSQLiteTokenBlacklist(db *sql.DB) (*SQLiteTokenBlacklist, error) {
	if db == nil {
		return nil, errors.New("authserver: nil database")
	}
	b := &SQLiteTokenBlacklist{db: db}
	if err := b.ensure(context.Background()); err != nil {
		return nil, err
	}
	return b, nil
}

func (b *SQLiteTokenBlacklist) ensure(ctx context.Context) error {
	conn, err := b.db.Conn(ctx)
	if err != nil {
		return err
	}
	defer conn.Close()
	if _, err := conn.ExecContext(ctx, `PRAGMA busy_timeout = 5000`); err != nil {
		return err
	}
	_, err = conn.ExecContext(ctx, `
		CREATE TABLE IF NOT EXISTS auth_token_blacklist (
			jti TEXT PRIMARY KEY NOT NULL,
			exp INTEGER NOT NULL
		)`)
	return err
}

// Revoke marks jti until exp. A repeat call is a no-op. An expiry that is
// not in the future is ignored.
func (b *SQLiteTokenBlacklist) Revoke(ctx context.Context, jti string, exp time.Time) error {
	_, err := b.insertIfActive(ctx, jti, exp)
	return err
}

// IsRevoked reports whether jti is still revoked. An expired row is deleted.
func (b *SQLiteTokenBlacklist) IsRevoked(ctx context.Context, jti string) (bool, error) {
	if jti == "" {
		return false, nil
	}
	var expMs int64
	err := b.db.QueryRowContext(ctx, `SELECT exp FROM auth_token_blacklist WHERE jti = ?`, jti).Scan(&expMs)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	now := time.Now()
	if !time.UnixMilli(expMs).After(now) {
		_, err := b.db.ExecContext(ctx, `DELETE FROM auth_token_blacklist WHERE jti = ? AND exp <= ?`, jti, now.UnixMilli())
		return false, err
	}
	return true, nil
}

// Consume revokes jti if it is still active. The delete of an expired row
// and the insert share one immediate transaction, so two callers cannot both
// win. SQLITE_BUSY is retried; a lost race returns false, not an error.
func (b *SQLiteTokenBlacklist) Consume(ctx context.Context, jti string, exp time.Time) (bool, error) {
	if b.ops.Add(1)%blacklistPruneEvery == 0 {
		_ = b.Prune(ctx, time.Now())
	}
	return b.insertIfActive(ctx, jti, exp)
}

// Prune bulk-deletes blacklist rows whose expiry is at or before now.
func (b *SQLiteTokenBlacklist) Prune(ctx context.Context, now time.Time) error {
	return b.withImmediate(ctx, func(conn *sql.Conn) error {
		_, err := conn.ExecContext(ctx, `DELETE FROM auth_token_blacklist WHERE exp <= ?`, now.UnixMilli())
		return err
	})
}

func (b *SQLiteTokenBlacklist) insertIfActive(ctx context.Context, jti string, exp time.Time) (bool, error) {
	now := time.Now()
	if jti == "" || !exp.After(now) {
		return false, nil
	}
	var inserted int64
	err := b.withImmediate(ctx, func(conn *sql.Conn) error {
		if _, err := conn.ExecContext(ctx, `DELETE FROM auth_token_blacklist WHERE jti = ? AND exp <= ?`, jti, now.UnixMilli()); err != nil {
			return err
		}
		res, err := conn.ExecContext(ctx, `INSERT OR IGNORE INTO auth_token_blacklist (jti, exp) VALUES (?, ?)`, jti, exp.UnixMilli())
		if err != nil {
			return err
		}
		n, err := res.RowsAffected()
		if err != nil {
			return err
		}
		inserted = n
		return nil
	})
	if err != nil {
		return false, err
	}
	return inserted == 1, nil
}

func (b *SQLiteTokenBlacklist) withImmediate(ctx context.Context, fn func(*sql.Conn) error) error {
	const attempts = 6
	var err error
	for attempt := 0; attempt < attempts; attempt++ {
		err = b.onceImmediate(ctx, fn)
		if err == nil || !isSQLiteBusy(err) {
			return err
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(time.Duration(attempt+1) * 5 * time.Millisecond):
		}
	}
	return err
}

func (b *SQLiteTokenBlacklist) onceImmediate(ctx context.Context, fn func(*sql.Conn) error) error {
	conn, err := b.db.Conn(ctx)
	if err != nil {
		return err
	}
	defer conn.Close()
	if _, err := conn.ExecContext(ctx, `PRAGMA busy_timeout = 5000`); err != nil {
		return err
	}
	if _, err := conn.ExecContext(ctx, `BEGIN IMMEDIATE`); err != nil {
		return err
	}
	committed := false
	defer func() {
		if !committed {
			_, _ = conn.ExecContext(context.Background(), `ROLLBACK`)
		}
	}()
	if err := fn(conn); err != nil {
		return err
	}
	if _, err := conn.ExecContext(ctx, `COMMIT`); err != nil {
		return err
	}
	committed = true
	return nil
}

func isSQLiteBusy(err error) bool {
	var se *sqlite.Error
	if errors.As(err, &se) {
		if se.Code()&0xff == 5 { // SQLITE_BUSY and extended busy codes
			return true
		}
	}
	msg := strings.ToLower(err.Error())
	return strings.Contains(msg, "sqlite_busy") || strings.Contains(msg, "database is locked")
}
