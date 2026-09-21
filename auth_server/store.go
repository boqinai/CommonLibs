package authserver

import (
	"context"
	"database/sql"
	"errors"
	"strings"
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
}

// UserProfileStore is an optional capability implemented by stores that
// support atomic partial profile updates.
type UserProfileStore interface {
	UpdateProfile(context.Context, int64, *string, *string) (*User, error)
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
		avatar TEXT NOT NULL DEFAULT '0'
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
		rows.Close()
		return err
	}
	if err := rows.Close(); err != nil {
		return err
	}

	if !hasNickname {
		if err := s.addColumn(ctx, `ALTER TABLE users ADD COLUMN nickname TEXT NOT NULL DEFAULT ''`); err != nil {
			return err
		}
	}
	if !hasAvatar {
		if err := s.addColumn(ctx, `ALTER TABLE users ADD COLUMN avatar TEXT NOT NULL DEFAULT '0'`); err != nil {
			return err
		}
	}
	return nil
}

func (s *SQLiteUserStore) addColumn(ctx context.Context, statement string) error {
	_, err := s.db.ExecContext(ctx, statement)
	if err != nil && strings.Contains(strings.ToLower(err.Error()), "duplicate column name") {
		return nil
	}
	return err
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

func (s *SQLiteUserStore) UpdateProfile(
	ctx context.Context,
	id int64,
	nickname *string,
	avatar *string,
) (*User, error) {
	user := &User{}
	err := s.db.QueryRowContext(
		ctx,
		`UPDATE users
		 SET nickname=COALESCE(?, nickname), avatar=COALESCE(?, avatar)
		 WHERE id=?
		 RETURNING id, phone, password_hash, nickname, avatar`,
		nickname,
		avatar,
		id,
	).Scan(&user.ID, &user.Phone, &user.PasswordHash, &user.Nickname, &user.Avatar)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrUserNotFound
	}
	if err != nil {
		return nil, err
	}
	return user, nil
}
