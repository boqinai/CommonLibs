package authserver

import (
	"context"
	"database/sql"
	"errors"
	"time"
)

// SQLiteTokenBlacklist is a process-shared TokenBlacklist on SQLite 3.22
// or newer. Consume checks and inserts inside one transaction. jti is the
// primary key, so a second insert does not land. The statements are
// INSERT OR IGNORE plus RowsAffected.
type SQLiteTokenBlacklist struct {
	db *sql.DB
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
	_, err := b.db.ExecContext(ctx, `
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
// and the insert share one transaction, so two callers cannot both win.
func (b *SQLiteTokenBlacklist) Consume(ctx context.Context, jti string, exp time.Time) (bool, error) {
	return b.insertIfActive(ctx, jti, exp)
}

func (b *SQLiteTokenBlacklist) insertIfActive(ctx context.Context, jti string, exp time.Time) (bool, error) {
	now := time.Now()
	if jti == "" || !exp.After(now) {
		return false, nil
	}
	tx, err := b.db.BeginTx(ctx, nil)
	if err != nil {
		return false, err
	}
	defer func() { _ = tx.Rollback() }()
	if _, err := tx.ExecContext(ctx, `DELETE FROM auth_token_blacklist WHERE jti = ? AND exp <= ?`, jti, now.UnixMilli()); err != nil {
		return false, err
	}
	res, err := tx.ExecContext(ctx, `INSERT OR IGNORE INTO auth_token_blacklist (jti, exp) VALUES (?, ?)`, jti, exp.UnixMilli())
	if err != nil {
		return false, err
	}
	inserted, err := res.RowsAffected()
	if err != nil {
		return false, err
	}
	if err := tx.Commit(); err != nil {
		return false, err
	}
	return inserted == 1, nil
}
