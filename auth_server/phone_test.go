package authserver

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	_ "modernc.org/sqlite"
)

type captureSender struct {
	last string
	err  error
}

func (c *captureSender) SendCode(_ context.Context, _, code string, _ time.Duration) error {
	if c.err != nil {
		return c.err
	}
	c.last = code
	return nil
}

func TestPhoneRoutes(t *testing.T) {
	db, err := sql.Open("sqlite", ":memory:")
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	db.SetMaxOpenConns(1)
	auth := New(db, []byte("secret"), WithBcryptCost(4))
	if err := auth.Init(context.Background()); err != nil {
		t.Fatal(err)
	}
	now := time.Unix(1_700_000_000, 0)
	sender := &captureSender{}
	codes := &SMSCodes{Sender: sender, HMACKey: []byte("secret"), Now: func() time.Time { return now }}
	fusion := PhoneVerifierFunc(func(_ context.Context, c PhoneCredential) (string, error) {
		if c.Token == "good" {
			return "13900139000", nil
		}
		return "", ErrVerificationFailed
	})
	mux := http.NewServeMux()
	auth.RegisterRoutes(mux)
	auth.RegisterPhoneRoutes(mux, PhoneRoutes{
		SMS: codes, Fusion: fusion,
		FusionToken:  func(context.Context, string) (any, error) { return map[string]string{"token": "t"}, nil },
		SendLimiter:  NewRateLimiter(5, time.Hour),
		LoginLimiter: NewRateLimiter(100, time.Hour),
	})
	call := func(path, body string) (int, map[string]any) {
		t.Helper()
		res := httptest.NewRecorder()
		mux.ServeHTTP(res, httptest.NewRequest(http.MethodPost, path, strings.NewReader(body)))
		var out map[string]any
		_ = json.Unmarshal(res.Body.Bytes(), &out)
		return res.Code, out
	}

	if c, out := call("/api/auth/sms/send", `{"phone":"12345"}`); c != 400 || out["code"] != "invalid_phone" {
		t.Fatal(c, out)
	}
	c, out := call("/api/auth/sms/send", `{"phone":"13800138000"}`)
	if c != 200 || out["cooldown"] != float64(60) || len(sender.last) != 6 || strings.Contains(toJSON(out), sender.last) {
		t.Fatal(c, out)
	}
	if c, out := call("/api/auth/sms/send", `{"phone":"13800138000"}`); c != 429 || out["code"] != "sms_too_frequent" {
		t.Fatal(c, out)
	}
	if c, _ := call("/api/auth/sms/login", `{"phone":"13800138000","code":"000000"}`); c != 401 && sender.last != "000000" {
		t.Fatal(c)
	}
	c, out = call("/api/auth/sms/login", `{"phone":"13800138000","code":"`+sender.last+`"}`)
	if c != 200 || out["token"] == "" || out["refresh_token"] == "" || out["expires_in"] != float64(7200) || out["created"] != true {
		t.Fatal(c, out)
	}
	if c, _ := call("/api/auth/sms/login", `{"phone":"13800138000","code":"`+sender.last+`"}`); c != 401 {
		t.Fatal("code reused", c)
	}
	// Upstream failure: 502 and the cooldown slot is released.
	now = now.Add(2 * time.Minute)
	sender.err = errors.New("boom")
	if c, out := call("/api/auth/sms/send", `{"phone":"13700137000"}`); c != 502 || out["code"] != "sms_unavailable" {
		t.Fatal(c, out)
	}
	sender.err = nil
	if c, _ := call("/api/auth/sms/send", `{"phone":"13700137000"}`); c != 200 {
		t.Fatal("reservation not released", c)
	}
	// Per-IP send cap (5/hour shared with fusion/token) is now exhausted.
	if c, out := call("/api/auth/fusion/token", `{"platform":"ios"}`); c != 429 || out["code"] != "too_many_requests" {
		t.Fatal(c, out)
	}
	if c, out := call("/api/auth/fusion/login", `{"token":"good"}`); c != 200 || out["created"] != true || out["refresh_token"] == "" || out["token"] == "" {
		t.Fatal(c, out)
	}
	if c, out := call("/api/auth/fusion/login", `{"token":"good"}`); c != 200 || out["created"] != false {
		t.Fatal(c, out)
	}
	if c, _ := call("/api/auth/fusion/login", `{"token":"bad"}`); c != 401 {
		t.Fatal(c)
	}
	// Phone-registered users cannot log in with a guessed password.
	if c, _ := call("/api/auth/login", `{"phone":"13900139000","password":"12345678"}`); c != 401 {
		t.Fatal(c)
	}
}

func TestSMSCodesAttemptsAndExpiry(t *testing.T) {
	now := time.Unix(0, 0)
	s := &SMSCodes{Sender: &captureSender{}, HMACKey: []byte("secret"), Now: func() time.Time { return now }, MaxAttempts: 2}
	ctx := context.Background()
	if err := s.Send(ctx, "13800138000"); err != nil {
		t.Fatal(err)
	}
	code := s.Sender.(*captureSender).last
	for range 2 {
		if _, err := s.VerifyPhone(ctx, PhoneCredential{Phone: "13800138000", Code: "x"}); !errors.Is(err, ErrVerificationFailed) {
			t.Fatal(err)
		}
	}
	if _, err := s.VerifyPhone(ctx, PhoneCredential{Phone: "13800138000", Code: code}); err == nil {
		t.Fatal("accepted after max attempts")
	}
	now = now.Add(time.Minute)
	_ = s.Send(ctx, "13800138000")
	code = s.Sender.(*captureSender).last
	now = now.Add(6 * time.Minute)
	if _, err := s.VerifyPhone(ctx, PhoneCredential{Phone: "13800138000", Code: code}); err == nil {
		t.Fatal("accepted expired code")
	}
	s2 := &SMSCodes{Sender: &captureSender{}, HMACKey: []byte("secret"), DailyLimit: 2, Cooldown: time.Second, Now: func() time.Time { return now }}
	for i := range 3 {
		now = now.Add(2 * time.Second)
		err := s2.Send(ctx, "13800138000")
		if (i < 2) != (err == nil) || i == 2 && !errors.Is(err, ErrDailyLimit) {
			t.Fatal(i, err)
		}
	}
}

func TestRateLimiterAndClientIP(t *testing.T) {
	l := NewRateLimiter(2, time.Minute)
	t0 := time.Unix(0, 0)
	if !l.Allow("a", t0) || !l.Allow("a", t0) || l.Allow("a", t0) || !l.Allow("b", t0) || !l.Allow("a", t0.Add(time.Minute)) {
		t.Fatal("limiter")
	}
	r := httptest.NewRequest("POST", "/", nil)
	r.RemoteAddr = "10.0.0.1:5"
	if ClientIP(r) != "10.0.0.1" {
		t.Fatal(ClientIP(r))
	}
	r.Header.Set("X-Forwarded-For", "6.6.6.6, 1.2.3.4")
	if ClientIP(r) != "10.0.0.1" {
		t.Fatalf("default ClientIP trusted XFF: %s", ClientIP(r))
	}
	trusted, err := parseTrustedProxies([]string{"10.0.0.1"})
	if err != nil {
		t.Fatal(err)
	}
	if got := clientIP(r, trusted); got != "1.2.3.4" {
		t.Fatalf("trusted proxy client: %s", got)
	}
	if MaskPhone("13800138000") != "138******00" {
		t.Fatal(MaskPhone("13800138000"))
	}
}

func toJSON(v any) string { b, _ := json.Marshal(v); return string(b) }

func TestRateLimiterCompaction(t *testing.T) {
	l := NewRateLimiterWithCap(2, time.Minute, 3)
	t0 := time.Unix(0, 0)
	for _, k := range []string{"a", "b", "c", "d"} {
		if !l.Allow(k, t0) {
			t.Fatal(k)
		}
	}
	l.mu.Lock()
	n := len(l.hits)
	l.mu.Unlock()
	if n > 3 {
		t.Fatalf("expected <=3 keys, got %d", n)
	}
}

func TestSMSCodesRequiresHMAC(t *testing.T) {
	s := &SMSCodes{Sender: &captureSender{}}
	defer func() {
		if recover() == nil {
			t.Fatal("expected panic without HMACKey")
		}
	}()
	_ = s.Send(context.Background(), "13800138000")
}

func TestRegisterRoutesRateLimit(t *testing.T) {
	db, err := sql.Open("sqlite", ":memory:")
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	auth := New(db, []byte("secret"), WithBcryptCost(4),
		WithCredentialRateLimiters(NewRateLimiter(2, time.Hour), NewRateLimiter(2, time.Hour)))
	if err := auth.Init(context.Background()); err != nil {
		t.Fatal(err)
	}
	mux := http.NewServeMux()
	auth.RegisterRoutes(mux)
	post := func(path, body string) int {
		res := httptest.NewRecorder()
		req := httptest.NewRequest(http.MethodPost, path, strings.NewReader(body))
		req.RemoteAddr = "9.9.9.9:1"
		mux.ServeHTTP(res, req)
		return res.Code
	}
	body := `{"phone":"13800138001","password":"12345678"}`
	if c := post("/api/auth/register", body); c != 201 {
		t.Fatal(c)
	}
	if c := post("/api/auth/register", `{"phone":"13800138002","password":"12345678"}`); c != 201 {
		t.Fatal(c)
	}
	if c := post("/api/auth/register", `{"phone":"13800138003","password":"12345678"}`); c != 429 {
		t.Fatalf("expected 429, got %d", c)
	}
}

func TestSpoofedXForwardedForDoesNotBypassDefaultLimit(t *testing.T) {
	db, err := sql.Open("sqlite", ":memory:")
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	auth := New(db, []byte("secret"), WithBcryptCost(4),
		WithCredentialRateLimiters(NewRateLimiter(1, time.Hour), NewRateLimiter(1, time.Hour)))
	if err := auth.Init(context.Background()); err != nil {
		t.Fatal(err)
	}
	mux := http.NewServeMux()
	auth.RegisterRoutes(mux)
	post := func(phone, xff string) int {
		res := httptest.NewRecorder()
		req := httptest.NewRequest(http.MethodPost, "/api/auth/register", strings.NewReader(`{"phone":"`+phone+`","password":"12345678"}`))
		req.RemoteAddr = "203.0.113.8:4000"
		req.Header.Set("X-Forwarded-For", xff)
		mux.ServeHTTP(res, req)
		return res.Code
	}
	if c := post("13800138011", "1.1.1.1"); c != http.StatusCreated {
		t.Fatal(c)
	}
	if c := post("13800138012", "8.8.8.8, 2.2.2.2"); c != http.StatusTooManyRequests {
		t.Fatalf("spoofed XFF bypassed the default limit: %d", c)
	}
}

func TestTrustedProxyUsesForwardedClient(t *testing.T) {
	db, err := sql.Open("sqlite", ":memory:")
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	auth := New(db, []byte("secret"), WithBcryptCost(4),
		WithTrustedProxies("10.0.0.0/8"),
		WithCredentialRateLimiters(NewRateLimiter(1, time.Hour), NewRateLimiter(1, time.Hour)))
	if err := auth.Init(context.Background()); err != nil {
		t.Fatal(err)
	}
	mux := http.NewServeMux()
	auth.RegisterRoutes(mux)
	post := func(phone, xff string) int {
		res := httptest.NewRecorder()
		req := httptest.NewRequest(http.MethodPost, "/api/auth/register", strings.NewReader(`{"phone":"`+phone+`","password":"12345678"}`))
		req.RemoteAddr = "10.0.0.1:443"
		req.Header.Set("X-Forwarded-For", xff)
		mux.ServeHTTP(res, req)
		return res.Code
	}
	if c := post("13800138101", "6.6.6.6, 198.51.100.10"); c != http.StatusCreated {
		t.Fatal(c)
	}
	if c := post("13800138102", "9.9.9.9, 198.51.100.10"); c != http.StatusTooManyRequests {
		t.Fatalf("same client behind the proxy was counted twice: %d", c)
	}
	if c := post("13800138103", "198.51.100.11"); c != http.StatusCreated {
		t.Fatalf("second client behind the proxy was blocked: %d", c)
	}
}

func TestClientIPResolverOverridesPeer(t *testing.T) {
	db, err := sql.Open("sqlite", ":memory:")
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	auth := New(db, []byte("secret"), WithBcryptCost(4),
		WithCredentialRateLimiters(NewRateLimiter(1, time.Hour), NewRateLimiter(1, time.Hour)),
		WithClientIPResolver(func(r *http.Request) string { return r.Header.Get("X-Client") }))
	if err := auth.Init(context.Background()); err != nil {
		t.Fatal(err)
	}
	mux := http.NewServeMux()
	auth.RegisterRoutes(mux)
	post := func(phone, client string) int {
		res := httptest.NewRecorder()
		req := httptest.NewRequest(http.MethodPost, "/api/auth/register", strings.NewReader(`{"phone":"`+phone+`","password":"12345678"}`))
		req.RemoteAddr = "203.0.113.8:9"
		req.Header.Set("X-Client", client)
		mux.ServeHTTP(res, req)
		return res.Code
	}
	if post("13800138201", "client-a") != http.StatusCreated || post("13800138202", "client-b") != http.StatusCreated {
		t.Fatal("resolver did not split keys")
	}
	if post("13800138203", "client-a") != http.StatusTooManyRequests {
		t.Fatal("resolver key was not limited")
	}
}

func TestSMSCompactBoundsMemory(t *testing.T) {
	base := time.Unix(1_700_000_000, 0)
	now := base
	s := &SMSCodes{
		Sender:   &captureSender{},
		HMACKey:  []byte("secret"),
		Cooldown: time.Nanosecond,
		Now:      func() time.Time { return now },
	}
	s.sends = map[string][]time.Time{}
	s.codes = map[string]*smsCode{}
	total := smsMapSoftCap + 50
	for i := range total {
		phone := fmt.Sprintf("13%09d", i)
		ts := base.Add(time.Duration(i) * time.Second)
		s.sends[phone] = []time.Time{ts.Add(-48 * time.Hour), ts}
		s.codes[phone] = &smsCode{expires: ts.Add(time.Minute)}
	}
	now = base.Add(time.Duration(total) * time.Second)
	s.mu.Lock()
	s.compactLocked(now)
	n := len(s.sends)
	_, oldest := s.sends["13000000000"]
	newest := fmt.Sprintf("13%09d", total-1)
	stamps := append([]time.Time(nil), s.sends[newest]...)
	s.mu.Unlock()
	if n != smsMapSoftCap || oldest || len(stamps) != 1 {
		t.Fatalf("sends=%d oldestKept=%v newestStamps=%v", n, oldest, stamps)
	}
	now = now.Add(24*time.Hour + time.Second)
	s.mu.Lock()
	s.compactLocked(now)
	left, codesLeft := len(s.sends), len(s.codes)
	s.mu.Unlock()
	if left != 0 || codesLeft != 0 {
		t.Fatalf("after 24h sends=%d codes=%d", left, codesLeft)
	}

	old := now.Add(-25 * time.Hour)
	s.mu.Lock()
	s.sends = map[string][]time.Time{}
	s.codes = map[string]*smsCode{}
	for i := range smsMapSoftCap + 5 {
		s.sends[fmt.Sprintf("13%09d", i)] = []time.Time{old}
	}
	s.mu.Unlock()
	if err := s.Send(context.Background(), "13900000000"); err != nil {
		t.Fatal(err)
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if len(s.sends) != 1 {
		t.Fatalf("send compact left %d keys", len(s.sends))
	}
	if _, ok := s.sends["13900000000"]; !ok {
		t.Fatal("new phone evicted")
	}
	if _, ok := s.sends["13000000000"]; ok {
		t.Fatal("stale phone survived Send compact")
	}
}
