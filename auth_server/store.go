package authserver

import (
	"context"
	"database/sql"
	"errors"
	"time"
)

var ErrUserNotFound = errors.New("authserver: user not found")

type User struct {
	ID           int64
	Phone        string
	PasswordHash string
	Nickname     string
	Avatar       string
}

type UserStore interface {
	Init(context.Context) error
	UserExists(context.Context, string) (bool, error)
	CreateUser(context.Context, string, string) (int64, error)
	GetUserByPhone(context.Context, string) (*User, error)
	GetUserByID(context.Context, int64) (*User, error)
	UpdateProfile(context.Context, int64, string, string) error
}

type SQLiteUserStore struct{ db *sql.DB }

func NewSQLiteUserStore(db *sql.DB) *SQLiteUserStore { return &SQLiteUserStore{db: db} }

func (s *SQLiteUserStore) Init(ctx context.Context) error {
	_, err := s.db.ExecContext(ctx, `PRAGMA journal_mode=WAL;
	PRAGMA busy_timeout=5000;
	CREATE TABLE IF NOT EXISTS users (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		phone TEXT UNIQUE NOT NULL,
		password_hash TEXT NOT NULL,
		created_at INTEGER NOT NULL,
		nickname TEXT NOT NULL DEFAULT '',
		avatar TEXT NOT NULL DEFAULT ''
	)`)
	if err != nil {
		return err
	}
	return s.ensureColumns(ctx)
}

func (s *SQLiteUserStore) ensureColumns(ctx context.Context) error {
	rows, err := s.db.QueryContext(ctx, `PRAGMA table_info(users)`)
	if err != nil {
		return err
	}
	defer rows.Close()

	hasNickname := false
	hasAvatar := false
	for rows.Next() {
		var cid int
		var name, colType string
		var notNull, pk int
		var dfltValue any
		if err := rows.Scan(&cid, &name, &colType, &notNull, &dfltValue, &pk); err != nil {
			return err
		}
		switch name {
		case "nickname":
			hasNickname = true
		case "avatar":
			hasAvatar = true
		}
	}
	if err := rows.Err(); err != nil {
		return err
	}

	if !hasNickname {
		if _, err := s.db.ExecContext(ctx, `ALTER TABLE users ADD COLUMN nickname TEXT NOT NULL DEFAULT ''`); err != nil {
			return err
		}
	}
	if !hasAvatar {
		if _, err := s.db.ExecContext(ctx, `ALTER TABLE users ADD COLUMN avatar TEXT NOT NULL DEFAULT ''`); err != nil {
			return err
		}
	}
	return nil
}

func (s *SQLiteUserStore) UserExists(ctx context.Context, phone string) (bool, error) {
	var exists int
	err := s.db.QueryRowContext(ctx, "SELECT 1 FROM users WHERE phone=?", phone).Scan(&exists)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	return err == nil, err
}

func (s *SQLiteUserStore) CreateUser(ctx context.Context, phone, hash string) (int64, error) {
	result, err := s.db.ExecContext(ctx, "INSERT INTO users(phone,password_hash,created_at,nickname,avatar) VALUES(?,?,?,'','0')", phone, hash, time.Now().UnixMilli())
	if err != nil {
		return 0, err
	}
	return result.LastInsertId()
}

func (s *SQLiteUserStore) GetUserByPhone(ctx context.Context, phone string) (*User, error) {
	user := &User{}
	err := s.db.QueryRowContext(ctx, "SELECT id,phone,password_hash,nickname,avatar FROM users WHERE phone=?", phone).Scan(&user.ID, &user.Phone, &user.PasswordHash, &user.Nickname, &user.Avatar)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrUserNotFound
	}
	if err != nil {
		return nil, err
	}
	return user, nil
}

func (s *SQLiteUserStore) GetUserByID(ctx context.Context, id int64) (*User, error) {
	user := &User{ID: id}
	err := s.db.QueryRowContext(ctx, "SELECT phone,password_hash,nickname,avatar FROM users WHERE id=?", id).Scan(&user.Phone, &user.PasswordHash, &user.Nickname, &user.Avatar)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrUserNotFound
	}
	if err != nil {
		return nil, err
	}
	return user, nil
}

func (s *SQLiteUserStore) UpdateProfile(ctx context.Context, id int64, nickname, avatar string) error {
	res, err := s.db.ExecContext(ctx, "UPDATE users SET nickname=?, avatar=? WHERE id=?", nickname, avatar, id)
	if err != nil {
		return err
	}
	affected, err := res.RowsAffected()
	if err != nil {
		return err
	}
	if affected == 0 {
		return ErrUserNotFound
	}
	return nil
}
