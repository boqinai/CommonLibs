package authserver

import (
	"context"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
	_ "modernc.org/sqlite"
)

func newTokenServer(t *testing.T, opts ...Option) (*Server, *sql.DB, *http.ServeMux) {
	t.Helper()
	db, err := sql.Open("sqlite", ":memory:")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = db.Close() })
	all := append([]Option{WithBcryptCost(4)}, opts...)
	srv := New(db, []byte("test-secret"), all...)
	if err := srv.Init(context.Background()); err != nil {
		t.Fatal(err)
	}
	mux := http.NewServeMux()
	srv.RegisterRoutes(mux)
	mux.Handle("/private", srv.RequireAuth(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		id, _ := UserID(r)
		writeJSON(w, http.StatusOK, map[string]int64{"id": id})
	})))
	return srv, db, mux
}

func postAuth(t *testing.T, mux *http.ServeMux, path, body, token string) (int, map[string]any) {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, path, strings.NewReader(body))
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	res := httptest.NewRecorder()
	mux.ServeHTTP(res, req)
	var out map[string]any
	_ = json.Unmarshal(res.Body.Bytes(), &out)
	return res.Code, out
}

func authGet(t *testing.T, mux *http.ServeMux, path, token string) int {
	t.Helper()
	req := httptest.NewRequest(http.MethodGet, path, nil)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	res := httptest.NewRecorder()
	mux.ServeHTTP(res, req)
	return res.Code
}

func claimsOf(t *testing.T, raw string) *sessionClaims {
	t.Helper()
	claims := &sessionClaims{}
	token, err := jwt.ParseWithClaims(raw, claims, func(*jwt.Token) (any, error) {
		return []byte("test-secret"), nil
	}, jwt.WithValidMethods([]string{jwt.SigningMethodHS256.Alg()}))
	if err != nil || !token.Valid {
		t.Fatalf("parse token: %v", err)
	}
	return claims
}

func near(t *testing.T, got, want int64) {
	t.Helper()
	if got < want-3 || got > want+3 {
		t.Fatalf("expiry delta %d, want about %d", got, want)
	}
}

func TestIssueRefreshAndRevoke(t *testing.T) {
	srv, db, mux := newTokenServer(t)
	if code, body := postAuth(t, mux, "/api/auth/register", `{"phone":"13800000000","password":"12345678"}`, ""); code != http.StatusCreated || body["token"] != nil || body["refresh_token"] != nil {
		t.Fatalf("register must not issue a jwt: %d %v", code, body)
	}
	code, login := postAuth(t, mux, "/api/auth/login", `{"phone":"13800000000","password":"12345678"}`, "")
	access, _ := login["token"].(string)
	refresh, _ := login["refresh_token"].(string)
	if code != http.StatusOK || access == "" || refresh == "" || login["expires_in"] != float64(7200) {
		t.Fatalf("login: %d %v", code, login)
	}
	accessClaims := claimsOf(t, access)
	refreshClaims := claimsOf(t, refresh)
	if accessClaims.Typ != TokenTypeAccess || refreshClaims.Typ != TokenTypeRefresh {
		t.Fatalf("typ access=%q refresh=%q", accessClaims.Typ, refreshClaims.Typ)
	}
	if accessClaims.ID == "" || refreshClaims.ID == "" || accessClaims.ID == refreshClaims.ID {
		t.Fatalf("jti access=%q refresh=%q", accessClaims.ID, refreshClaims.ID)
	}
	if accessClaims.Subject != refreshClaims.Subject {
		t.Fatal("subject mismatch")
	}
	now := time.Now().Unix()
	near(t, accessClaims.ExpiresAt.Unix()-now, int64(DefaultAccessTokenTTL/time.Second))
	near(t, refreshClaims.ExpiresAt.Unix()-now, int64(DefaultRefreshTokenTTL/time.Second))
	headerJSON, err := base64.RawURLEncoding.DecodeString(strings.Split(access, ".")[0])
	if err != nil || !strings.Contains(string(headerJSON), `"alg":"HS256"`) {
		t.Fatalf("header %s err %v", headerJSON, err)
	}
	second, err := srv.IssueToken(1)
	if err != nil {
		t.Fatal(err)
	}
	if claimsOf(t, second).ID == accessClaims.ID {
		t.Fatal("jti reused")
	}
	if authGet(t, mux, "/private", access) != http.StatusOK {
		t.Fatal("access token rejected")
	}
	if authGet(t, mux, "/private", refresh) != http.StatusUnauthorized {
		t.Fatal("refresh token was accepted as an access token")
	}

	code, rotated := postAuth(t, mux, "/api/auth/refresh", `{"refresh_token":"`+refresh+`"}`, "")
	newAccess, _ := rotated["token"].(string)
	newRefresh, _ := rotated["refresh_token"].(string)
	if code != http.StatusOK || newAccess == "" || newRefresh == "" || newRefresh == refresh {
		t.Fatalf("refresh: %d %v", code, rotated)
	}
	if authGet(t, mux, "/private", access) != http.StatusOK {
		t.Fatal("rotation revoked the previous access token")
	}
	if code, body := postAuth(t, mux, "/api/auth/refresh", `{"refresh_token":"`+refresh+`"}`, ""); code != http.StatusUnauthorized || body["code"] != CodeInvalidRefreshToken {
		t.Fatalf("reused refresh: %d %v", code, body)
	}
	if authGet(t, mux, "/private", newAccess) != http.StatusOK {
		t.Fatal("rotated access token rejected")
	}

	code, body := postAuth(t, mux, "/api/auth/logout", `{"refresh_token":"`+newRefresh+`"}`, newAccess)
	if code != http.StatusOK || body["ok"] != true {
		t.Fatalf("logout: %d %v", code, body)
	}
	if authGet(t, mux, "/private", newAccess) != http.StatusUnauthorized {
		t.Fatal("revoked access token still works")
	}
	if authGet(t, mux, "/private", access) != http.StatusOK {
		t.Fatal("logout revoked a different access token")
	}
	if code, _ := postAuth(t, mux, "/api/auth/refresh", `{"refresh_token":"`+newRefresh+`"}`, ""); code != http.StatusUnauthorized {
		t.Fatalf("revoked refresh still works: %d", code)
	}

	if _, err := db.Exec(`DELETE FROM users`); err != nil {
		t.Fatal(err)
	}
	fresh, err := srv.IssueTokens(1)
	if err != nil {
		t.Fatal(err)
	}
	if code, body := postAuth(t, mux, "/api/auth/refresh", `{"refresh_token":"`+fresh.RefreshToken+`"}`, ""); code != http.StatusUnauthorized || body["code"] != CodeInvalidRefreshToken {
		t.Fatalf("deleted user refresh: %d %v", code, body)
	}
}

func TestTokenExpiryAndAlgorithms(t *testing.T) {
	_, _, mux := newTokenServer(t, WithTokenExpiry(15*time.Minute), WithRefreshTokenExpiry(48*time.Hour))
	if code, _ := postAuth(t, mux, "/api/auth/register", `{"phone":"13800000000","password":"12345678"}`, ""); code != http.StatusCreated {
		t.Fatal(code)
	}
	code, login := postAuth(t, mux, "/api/auth/login", `{"phone":"13800000000","password":"12345678"}`, "")
	access, _ := login["token"].(string)
	refresh, _ := login["refresh_token"].(string)
	if code != http.StatusOK || login["expires_in"] != float64(900) {
		t.Fatalf("custom ttl: %d %v", code, login)
	}
	now := time.Now().Unix()
	near(t, claimsOf(t, access).ExpiresAt.Unix()-now, 15*60)
	near(t, claimsOf(t, refresh).ExpiresAt.Unix()-now, int64((48*time.Hour)/time.Second))

	expired, err := jwt.NewWithClaims(jwt.SigningMethodHS256, sessionClaims{
		RegisteredClaims: jwt.RegisteredClaims{
			Subject:   "1",
			ExpiresAt: jwt.NewNumericDate(time.Now().Add(-time.Minute)),
			ID:        "expired-access",
		},
		Typ: TokenTypeAccess,
	}).SignedString([]byte("test-secret"))
	if err != nil {
		t.Fatal(err)
	}
	if authGet(t, mux, "/private", expired) != http.StatusUnauthorized {
		t.Fatal("expired access token accepted")
	}
	expiredRefresh, err := jwt.NewWithClaims(jwt.SigningMethodHS256, sessionClaims{
		RegisteredClaims: jwt.RegisteredClaims{
			Subject:   "1",
			ExpiresAt: jwt.NewNumericDate(time.Now().Add(-time.Minute)),
			ID:        "expired-refresh",
		},
		Typ: TokenTypeRefresh,
	}).SignedString([]byte("test-secret"))
	if err != nil {
		t.Fatal(err)
	}
	if code, body := postAuth(t, mux, "/api/auth/refresh", `{"refresh_token":"`+expiredRefresh+`"}`, ""); code != http.StatusUnauthorized || body["code"] != CodeInvalidRefreshToken {
		t.Fatalf("expired refresh: %d %v", code, body)
	}

	legacy, err := jwt.NewWithClaims(jwt.SigningMethodHS256, jwt.MapClaims{
		"sub": "1",
		"exp": time.Now().Add(time.Hour).Unix(),
	}).SignedString([]byte("test-secret"))
	if err != nil {
		t.Fatal(err)
	}
	if authGet(t, mux, "/private", legacy) != http.StatusOK {
		t.Fatal("legacy sub+exp token rejected")
	}
	if code, body := postAuth(t, mux, "/api/auth/logout", "", legacy); code != http.StatusOK || body["ok"] != true {
		t.Fatalf("legacy logout: %d %v", code, body)
	}
	if authGet(t, mux, "/private", legacy) != http.StatusOK {
		t.Fatal("legacy token without jti was revoked")
	}

	hs384, err := jwt.NewWithClaims(jwt.SigningMethodHS384, jwt.MapClaims{
		"sub": "1",
		"exp": time.Now().Add(time.Hour).Unix(),
		"typ": TokenTypeAccess,
	}).SignedString([]byte("test-secret"))
	if err != nil {
		t.Fatal(err)
	}
	if authGet(t, mux, "/private", hs384) != http.StatusUnauthorized {
		t.Fatal("HS384 token accepted")
	}
	exp := strconv.FormatInt(time.Now().Add(time.Hour).Unix(), 10)
	noneHeader := base64.RawURLEncoding.EncodeToString([]byte(`{"alg":"none","typ":"JWT"}`))
	nonePayload := base64.RawURLEncoding.EncodeToString([]byte(`{"sub":"1","exp":` + exp + `}`))
	if authGet(t, mux, "/private", noneHeader+"."+nonePayload+".") != http.StatusUnauthorized {
		t.Fatal("alg=none token accepted")
	}
}

func TestPhoneAndFusionLoginIssueRefreshTokens(t *testing.T) {
	db, err := sql.Open("sqlite", ":memory:")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = db.Close() })
	auth := New(db, []byte("test-secret"), WithBcryptCost(4))
	if err := auth.Init(context.Background()); err != nil {
		t.Fatal(err)
	}
	sender := &captureSender{}
	mux := http.NewServeMux()
	auth.RegisterRoutes(mux)
	auth.RegisterPhoneRoutes(mux, PhoneRoutes{
		SMS: &SMSCodes{Sender: sender, HMACKey: []byte("test-secret")},
		Fusion: PhoneVerifierFunc(func(_ context.Context, cred PhoneCredential) (string, error) {
			if cred.Token == "good" {
				return "13900139000", nil
			}
			return "", ErrVerificationFailed
		}),
		SendLimiter:  NewRateLimiter(20, time.Hour),
		LoginLimiter: NewRateLimiter(20, time.Hour),
	})
	if code, _ := postAuth(t, mux, "/api/auth/sms/send", `{"phone":"13800138000"}`, ""); code != http.StatusOK {
		t.Fatal(code)
	}
	code, sms := postAuth(t, mux, "/api/auth/sms/login", `{"phone":"13800138000","code":"`+sender.last+`"}`, "")
	smsAccess, _ := sms["token"].(string)
	smsRefresh, _ := sms["refresh_token"].(string)
	if code != http.StatusOK || sms["created"] != true || claimsOf(t, smsAccess).Typ != TokenTypeAccess || claimsOf(t, smsRefresh).Typ != TokenTypeRefresh {
		t.Fatalf("sms login: %d %v", code, sms)
	}
	code, fusionBody := postAuth(t, mux, "/api/auth/fusion/login", `{"token":"good"}`, "")
	fusionAccess, _ := fusionBody["token"].(string)
	fusionRefresh, _ := fusionBody["refresh_token"].(string)
	if code != http.StatusOK || fusionBody["created"] != true || claimsOf(t, fusionAccess).Typ != TokenTypeAccess || claimsOf(t, fusionRefresh).Typ != TokenTypeRefresh {
		t.Fatalf("fusion login: %d %v", code, fusionBody)
	}
	if smsRefresh == fusionRefresh {
		t.Fatal("refresh tokens collided")
	}
}

func TestRefreshAndLogoutEdges(t *testing.T) {
	_, _, mux := newTokenServer(t)
	if code, _ := postAuth(t, mux, "/api/auth/register", `{"phone":"13800000000","password":"12345678"}`, ""); code != http.StatusCreated {
		t.Fatal(code)
	}
	_, login := postAuth(t, mux, "/api/auth/login", `{"phone":"13800000000","password":"12345678"}`, "")
	access := login["token"].(string)
	refresh := login["refresh_token"].(string)

	if code, body := postAuth(t, mux, "/api/auth/refresh", `{}`, ""); code != http.StatusBadRequest || body["code"] != CodeInvalidRequest {
		t.Fatalf("empty refresh: %d %v", code, body)
	}
	if code, body := postAuth(t, mux, "/api/auth/refresh", `{"refresh_token":"`+access+`"}`, ""); code != http.StatusUnauthorized || body["code"] != CodeInvalidRefreshToken {
		t.Fatalf("access used as refresh: %d %v", code, body)
	}
	req := httptest.NewRequest(http.MethodGet, "/api/auth/refresh", nil)
	res := httptest.NewRecorder()
	mux.ServeHTTP(res, req)
	if res.Code != http.StatusMethodNotAllowed {
		t.Fatalf("GET refresh: %d", res.Code)
	}
	req = httptest.NewRequest(http.MethodGet, "/api/auth/logout", nil)
	res = httptest.NewRecorder()
	mux.ServeHTTP(res, req)
	if res.Code != http.StatusMethodNotAllowed {
		t.Fatalf("GET logout: %d", res.Code)
	}
	if code, _ := postAuth(t, mux, "/api/auth/logout", `{`, ""); code != http.StatusBadRequest {
		t.Fatalf("bad logout body: %d", code)
	}
	if refresh == "" || access == "" {
		t.Fatal("missing tokens")
	}
}

func TestRefreshRateLimit(t *testing.T) {
	db, err := sql.Open("sqlite", ":memory:")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = db.Close() })
	srv := New(db, []byte("test-secret"), WithBcryptCost(4))
	srv.refreshLimiter = NewRateLimiter(1, time.Hour)
	if err := srv.Init(context.Background()); err != nil {
		t.Fatal(err)
	}
	mux := http.NewServeMux()
	srv.RegisterRoutes(mux)
	if code, _ := postAuth(t, mux, "/api/auth/register", `{"phone":"13800000000","password":"12345678"}`, ""); code != http.StatusCreated {
		t.Fatal(code)
	}
	_, login := postAuth(t, mux, "/api/auth/login", `{"phone":"13800000000","password":"12345678"}`, "")
	refresh, _ := login["refresh_token"].(string)
	if code, _ := postAuth(t, mux, "/api/auth/refresh", `{"refresh_token":"`+refresh+`"}`, ""); code != http.StatusOK {
		t.Fatal(code)
	}
	if code, body := postAuth(t, mux, "/api/auth/refresh", `{"refresh_token":"anything"}`, ""); code != http.StatusTooManyRequests || body["code"] != CodeTooManyRequests {
		t.Fatalf("refresh limit: %d %v", code, body)
	}
}

type flakyBlacklist struct {
	failRead   bool
	failRevoke bool
}

func (f flakyBlacklist) Revoke(context.Context, string, time.Time) error {
	if f.failRevoke {
		return errors.New("store down")
	}
	return nil
}

func (f flakyBlacklist) IsRevoked(context.Context, string) (bool, error) {
	if f.failRead {
		return false, errors.New("store down")
	}
	return false, nil
}

func TestBlacklistFailuresAndMemoryTTL(t *testing.T) {
	_, _, mux := newTokenServer(t, WithTokenBlacklist(flakyBlacklist{failRead: true}))
	if code, _ := postAuth(t, mux, "/api/auth/register", `{"phone":"13800000000","password":"12345678"}`, ""); code != http.StatusCreated {
		t.Fatal(code)
	}
	_, login := postAuth(t, mux, "/api/auth/login", `{"phone":"13800000000","password":"12345678"}`, "")
	if authGet(t, mux, "/private", login["token"].(string)) != http.StatusUnauthorized {
		t.Fatal("blacklist read error was ignored")
	}

	_, _, mux = newTokenServer(t, WithTokenBlacklist(flakyBlacklist{failRevoke: true}))
	if code, _ := postAuth(t, mux, "/api/auth/register", `{"phone":"13800000000","password":"12345678"}`, ""); code != http.StatusCreated {
		t.Fatal(code)
	}
	_, login = postAuth(t, mux, "/api/auth/login", `{"phone":"13800000000","password":"12345678"}`, "")
	access := login["token"].(string)
	refresh := login["refresh_token"].(string)
	if code, body := postAuth(t, mux, "/api/auth/logout", `{"refresh_token":"`+refresh+`"}`, access); code != http.StatusInternalServerError || body["code"] != CodeInternalError {
		t.Fatalf("logout store failure: %d %v", code, body)
	}
	if authGet(t, mux, "/private", access) != http.StatusOK {
		t.Fatal("failed revoke blocked the access token")
	}
	if code, _ := postAuth(t, mux, "/api/auth/refresh", `{"refresh_token":"`+refresh+`"}`, ""); code != http.StatusInternalServerError {
		t.Fatalf("refresh store failure: %d", code)
	}

	bl := NewMemoryTokenBlacklist()
	now := time.Unix(1_700_000_000, 0)
	bl.now = func() time.Time { return now }
	if err := bl.Revoke(context.Background(), "live", now.Add(time.Hour)); err != nil {
		t.Fatal(err)
	}
	if err := bl.Revoke(context.Background(), "stale", now.Add(-time.Second)); err != nil {
		t.Fatal(err)
	}
	revoked, err := bl.IsRevoked(context.Background(), "live")
	if err != nil || !revoked {
		t.Fatalf("live jti: %v %v", revoked, err)
	}
	revoked, err = bl.IsRevoked(context.Background(), "stale")
	if err != nil || revoked {
		t.Fatal("expired jti stored")
	}
	now = now.Add(2 * time.Hour)
	revoked, err = bl.IsRevoked(context.Background(), "live")
	if err != nil || revoked {
		t.Fatal("jti lived past exp")
	}
	bl.mu.Lock()
	left := len(bl.until)
	bl.mu.Unlock()
	if left != 0 {
		t.Fatalf("blacklist retained %d entries", left)
	}

	var wg sync.WaitGroup
	shared := NewMemoryTokenBlacklist()
	for i := range 32 {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			jti := strconv.Itoa(i)
			exp := time.Now().Add(time.Hour)
			if err := shared.Revoke(context.Background(), jti, exp); err != nil {
				t.Error(err)
			}
			if _, err := shared.IsRevoked(context.Background(), jti); err != nil {
				t.Error(err)
			}
		}(i)
	}
	wg.Wait()
}

func TestErrorCodeValues(t *testing.T) {
	codes := map[string]string{
		"invalid_request":            CodeInvalidRequest,
		"invalid_credentials_format": CodeInvalidCredentialsFormat,
		"phone_already_registered":   CodePhoneAlreadyRegistered,
		"invalid_credentials":        CodeInvalidCredentials,
		"unauthorized":               CodeUnauthorized,
		"user_not_found":             CodeUserNotFound,
		"method_not_allowed":         CodeMethodNotAllowed,
		"internal_error":             CodeInternalError,
		"profile_not_supported":      CodeProfileNotSupported,
		"invalid_phone":              CodeInvalidPhone,
		"verification_failed":        CodeVerificationFailed,
		"sms_too_frequent":           CodeSMSTooFrequent,
		"sms_daily_limit":            CodeSMSDailyLimit,
		"too_many_requests":          CodeTooManyRequests,
		"sms_unavailable":            CodeSMSUnavailable,
		"verification_unavailable":   CodeVerificationUnavailable,
		"unsupported_platform":       CodeUnsupportedPlatform,
		"invalid_refresh_token":      CodeInvalidRefreshToken,
	}
	for want, got := range codes {
		if got != want {
			t.Fatalf("code drift: %s != %s", got, want)
		}
	}
}
