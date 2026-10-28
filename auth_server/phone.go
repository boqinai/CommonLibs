package authserver

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"log"
	"math/big"
	"net/http"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"

	"golang.org/x/crypto/bcrypt"
)

// Verified-phone login: a PhoneVerifier proves the caller owns a phone
// number (SMS code, carrier fusion auth, ...); the Server then logs in the
// matching user, registering one with an unusable random password if needed.

var (
	// ErrVerificationFailed: wrong/expired code or rejected token (401).
	ErrVerificationFailed = errors.New("authserver: phone verification failed")
	// ErrTooFrequent: resend cooldown or upstream frequency control (429).
	ErrTooFrequent = errors.New("authserver: too frequent")
	// ErrDailyLimit: per-phone daily send cap (429).
	ErrDailyLimit = errors.New("authserver: daily limit reached")
	// ErrInvalidPhone: malformed or rejected number (400).
	ErrInvalidPhone = errors.New("authserver: invalid phone")
)

// PhoneCredential is the login request body: an SMS login sends Phone and
// Code; a fusion login sends Token.
type PhoneCredential struct {
	Phone string `json:"phone"`
	Code  string `json:"code"`
	Token string `json:"token"`
}

// PhoneVerifier returns the verified phone for a credential, or
// ErrVerificationFailed.
type PhoneVerifier interface {
	VerifyPhone(ctx context.Context, cred PhoneCredential) (string, error)
}

// PhoneVerifierFunc adapts a function to PhoneVerifier.
type PhoneVerifierFunc func(context.Context, PhoneCredential) (string, error)

func (f PhoneVerifierFunc) VerifyPhone(ctx context.Context, c PhoneCredential) (string, error) {
	return f(ctx, c)
}

// CodeSender delivers a verification code (e.g. aliyun.SMSSender).
type CodeSender interface {
	SendCode(ctx context.Context, phone, code string, ttl time.Duration) error
}

// MainlandPhone matches an 11-digit mainland China mobile number.
var MainlandPhone = regexp.MustCompile(`^1[3-9]\d{9}$`)

// SMSCodes issues and verifies self-managed one-time codes: stored as
// HMAC-SHA256(HMACKey, code), compared in constant time, single use, with
// expiry, max attempts, resend cooldown and a per-phone daily cap. State is
// in process memory only (not shared across replicas; restarts drop unused
// codes). The zero value of each limit field uses its default.
//
// HMACKey should be a server secret (JWT secret is fine). When empty,
// RegisterPhoneRoutes copies Server's JWT secret; calling Send/Verify
// without a key panics.
type SMSCodes struct {
	Sender      CodeSender
	HMACKey     []byte         // required; see above
	TTL         time.Duration  // default 5m
	Cooldown    time.Duration  // default 60s
	MaxAttempts int            // default 5
	DailyLimit  int            // default 10 per phone per 24h
	CodeLength  int            // default 6
	PhoneFormat *regexp.Regexp // default MainlandPhone
	// IPDailyLimit caps sends per client IP per 24h when the context carries
	// an IP via WithSMSClientIP (SendSMSCode sets it). Zero uses
	// defaultIPDailyLimit, which sits above the default 20/hour HTTP limiter.
	// A negative value disables the cap.
	IPDailyLimit int
	Now          func() time.Time

	mu      sync.Mutex
	codes   map[string]*smsCode
	sends   map[string][]time.Time
	ipSends map[string][]time.Time
}

type smsCode struct {
	hash     [32]byte
	expires  time.Time
	attempts int
}

func (s *SMSCodes) now() time.Time {
	if s.Now != nil {
		return s.Now()
	}
	return time.Now()
}

func (s *SMSCodes) ttl() time.Duration { return durOr(s.TTL, 5*time.Minute) }

// CooldownSeconds is the resend interval reported to clients.
func (s *SMSCodes) CooldownSeconds() int { return int(durOr(s.Cooldown, time.Minute) / time.Second) }

func durOr(d, def time.Duration) time.Duration {
	if d <= 0 {
		return def
	}
	return d
}

func intOr(v, def int) int {
	if v <= 0 {
		return def
	}
	return v
}

func (s *SMSCodes) hashCode(code string) [32]byte {
	if len(s.HMACKey) == 0 {
		panic("authserver: SMSCodes.HMACKey is empty")
	}
	mac := hmac.New(sha256.New, s.HMACKey)
	_, _ = mac.Write([]byte(code))
	var out [32]byte
	copy(out[:], mac.Sum(nil))
	return out
}

const (
	smsMapSoftCap = 10_000
	// defaultIPDailyLimit is above the default 20/hour send route limiter
	// (480/day), so that limiter still binds first.
	defaultIPDailyLimit = 1000
)

type sendActivity struct {
	phone string
	last  time.Time
}

type smsClientIPKey struct{}

// WithSMSClientIP attaches the client IP used by SMSCodes.IPDailyLimit.
// SendSMSCode sets it from the server's client-IP policy.
func WithSMSClientIP(ctx context.Context, ip string) context.Context {
	return context.WithValue(ctx, smsClientIPKey{}, strings.TrimSpace(ip))
}

func smsClientIP(ctx context.Context) string {
	ip, _ := ctx.Value(smsClientIPKey{}).(string)
	return ip
}

// compactLocked drops send timestamps older than 24h and deletes empty keys.
// An entry is evicted for the soft cap only when it has no active code and
// no sends inside the daily window. Protected entries stay even if the map
// remains above the cap; Send refuses new numbers instead of resetting them.
// Callers must hold s.mu.
func (s *SMSCodes) compactLocked(now time.Time) {
	if s.sends == nil {
		s.sends = map[string][]time.Time{}
	}
	if s.ipSends == nil {
		s.ipSends = map[string][]time.Time{}
	}
	s.pruneSendMapLocked(s.sends, now, true)
	s.pruneSendMapLocked(s.ipSends, now, false)
	for phone, c := range s.codes {
		if c == nil || now.After(c.expires) {
			delete(s.codes, phone)
		}
	}
	s.evictUnprotectedLocked(now)
}

func (s *SMSCodes) pruneSendMapLocked(entries map[string][]time.Time, now time.Time, keepActiveCodes bool) {
	for key, times := range entries {
		kept := sendsWithinWindow(times, now)
		if len(kept) == 0 {
			if keepActiveCodes && s.hasActiveCodeLocked(key, now) {
				entries[key] = nil
				continue
			}
			delete(entries, key)
			continue
		}
		entries[key] = kept
	}
}

func (s *SMSCodes) evictUnprotectedLocked(now time.Time) {
	if len(s.sends) <= smsMapSoftCap {
		return
	}
	activities := make([]sendActivity, 0)
	for phone, times := range s.sends {
		if s.protectedLocked(phone, times, now) {
			continue
		}
		var last time.Time
		for _, ts := range times {
			if last.IsZero() || ts.After(last) {
				last = ts
			}
		}
		activities = append(activities, sendActivity{phone: phone, last: last})
	}
	sort.Slice(activities, func(i, j int) bool {
		if activities[i].last.Equal(activities[j].last) {
			return activities[i].phone < activities[j].phone
		}
		return activities[i].last.Before(activities[j].last)
	})
	for _, activity := range activities {
		if len(s.sends) <= smsMapSoftCap {
			return
		}
		if s.protectedLocked(activity.phone, s.sends[activity.phone], now) {
			continue
		}
		delete(s.sends, activity.phone)
		delete(s.codes, activity.phone)
	}
}

func (s *SMSCodes) protectedLocked(phone string, times []time.Time, now time.Time) bool {
	if s.hasActiveCodeLocked(phone, now) {
		return true
	}
	return len(sendsWithinWindow(times, now)) > 0
}

func (s *SMSCodes) hasActiveCodeLocked(phone string, now time.Time) bool {
	c := s.codes[phone]
	return c != nil && !now.After(c.expires)
}

func sendsWithinWindow(times []time.Time, now time.Time) []time.Time {
	kept := make([]time.Time, 0, len(times))
	for _, ts := range times {
		if now.Sub(ts) < 24*time.Hour {
			kept = append(kept, ts)
		}
	}
	return kept
}

func (s *SMSCodes) ipDailyLimit() int {
	if s.IPDailyLimit < 0 {
		return -1
	}
	if s.IPDailyLimit == 0 {
		return defaultIPDailyLimit
	}
	return s.IPDailyLimit
}

// reserveIPLocked records one send for ip. A new IP is refused when the IP
// map is still at the cap after compaction. Callers must hold s.mu.
func (s *SMSCodes) reserveIPLocked(ip string, now time.Time) error {
	if ip == "" || s.ipDailyLimit() < 0 {
		return nil
	}
	if s.ipSends == nil {
		s.ipSends = map[string][]time.Time{}
	}
	kept := sendsWithinWindow(s.ipSends[ip], now)
	if len(kept) == 0 {
		delete(s.ipSends, ip)
		if len(s.ipSends) >= smsMapSoftCap {
			return ErrTooFrequent
		}
	}
	if len(kept) >= s.ipDailyLimit() {
		s.ipSends[ip] = kept
		return ErrDailyLimit
	}
	s.ipSends[ip] = append(kept, now)
	return nil
}

func (s *SMSCodes) rollbackIPLocked(ip string, now time.Time) {
	if ip == "" || s.ipSends == nil {
		return
	}
	history := s.ipSends[ip]
	if len(history) > 0 && history[len(history)-1].Equal(now) {
		history = history[:len(history)-1]
	}
	if len(history) == 0 {
		delete(s.ipSends, ip)
		return
	}
	s.ipSends[ip] = history
}

// ValidPhone reports whether phone matches PhoneFormat.
func (s *SMSCodes) ValidPhone(phone string) bool {
	f := s.PhoneFormat
	if f == nil {
		f = MainlandPhone
	}
	return f.MatchString(phone)
}

// Send generates and delivers a fresh code for phone.
func (s *SMSCodes) Send(ctx context.Context, phone string) error {
	if s.Sender == nil {
		return errors.New("authserver: SMSCodes has no Sender")
	}
	if !s.ValidPhone(phone) {
		return ErrInvalidPhone
	}
	now := s.now()
	ip := smsClientIP(ctx)
	s.mu.Lock()
	if s.sends == nil {
		s.sends, s.codes = map[string][]time.Time{}, map[string]*smsCode{}
	}
	if len(s.sends) >= smsMapSoftCap || len(s.codes) >= smsMapSoftCap || len(s.ipSends) >= smsMapSoftCap {
		s.compactLocked(now)
	}
	if _, known := s.sends[phone]; !known && !s.hasActiveCodeLocked(phone, now) &&
		(len(s.sends) >= smsMapSoftCap || len(s.codes) >= smsMapSoftCap) {
		s.mu.Unlock()
		return ErrTooFrequent
	}
	if err := s.reserveIPLocked(ip, now); err != nil {
		s.mu.Unlock()
		return err
	}
	recent := sendsWithinWindow(s.sends[phone], now)
	s.sends[phone] = recent
	if n := len(recent); n > 0 && now.Sub(recent[n-1]) < durOr(s.Cooldown, time.Minute) {
		s.rollbackIPLocked(ip, now)
		s.mu.Unlock()
		return ErrTooFrequent
	}
	if len(recent) >= intOr(s.DailyLimit, 10) {
		s.rollbackIPLocked(ip, now)
		s.mu.Unlock()
		return ErrDailyLimit
	}
	s.sends[phone] = append(recent, now) // reserve before the slow send
	s.mu.Unlock()

	code, err := RandomDigits(intOr(s.CodeLength, 6))
	if err != nil {
		return err
	}
	if err := s.Sender.SendCode(ctx, phone, code, s.ttl()); err != nil {
		if !errors.Is(err, ErrTooFrequent) && !errors.Is(err, ErrDailyLimit) {
			s.mu.Lock() // not delivered: release the reservation
			if l := s.sends[phone]; len(l) > 0 && l[len(l)-1].Equal(now) {
				s.sends[phone] = l[:len(l)-1]
				if len(s.sends[phone]) == 0 {
					delete(s.sends, phone)
				}
			}
			s.rollbackIPLocked(ip, now)
			s.mu.Unlock()
		}
		return err
	}
	s.mu.Lock()
	s.codes[phone] = &smsCode{hash: s.hashCode(code), expires: now.Add(s.ttl())}
	s.mu.Unlock()
	return nil
}

// VerifyPhone consumes the code for cred.Phone (PhoneVerifier).
func (s *SMSCodes) VerifyPhone(_ context.Context, cred PhoneCredential) (string, error) {
	phone := strings.TrimSpace(cred.Phone)
	s.mu.Lock()
	defer s.mu.Unlock()
	c := s.codes[phone]
	if c == nil || cred.Code == "" {
		return "", ErrVerificationFailed
	}
	if s.now().After(c.expires) || c.attempts >= intOr(s.MaxAttempts, 5) {
		delete(s.codes, phone)
		return "", ErrVerificationFailed
	}
	h := s.hashCode(strings.TrimSpace(cred.Code))
	if subtle.ConstantTimeCompare(h[:], c.hash[:]) != 1 {
		c.attempts++
		return "", ErrVerificationFailed
	}
	delete(s.codes, phone)
	return phone, nil
}

// RandomDigits returns n cryptographically random decimal digits.
func RandomDigits(n int) (string, error) {
	b := make([]byte, n)
	for i := range b {
		d, err := rand.Int(rand.Reader, big.NewInt(10))
		if err != nil {
			return "", err
		}
		b[i] = byte('0' + d.Int64())
	}
	return string(b), nil
}

// PhoneRoutes configures RegisterPhoneRoutes. Nil fields disable their routes.
type PhoneRoutes struct {
	SMS    *SMSCodes     // POST {auth}/sms/send, {auth}/sms/login
	Fusion PhoneVerifier // POST {auth}/fusion/login
	// FusionToken serves POST {auth}/fusion/token {"platform":"android|ios"}
	// with the SDK init payload (host-specific scheme codes).
	FusionToken func(ctx context.Context, platform string) (any, error)
	// SendLimiter / LoginLimiter cap requests per client IP; default
	// 20/hour and 30/10min. Shared across routes of the same kind.
	// The address comes from Server's client-IP policy (RemoteAddr unless
	// WithTrustedProxies or WithClientIPResolver is set).
	SendLimiter  *RateLimiter
	LoginLimiter *RateLimiter
	Prefix       string // default "/api/auth"
}

// RegisterPhoneRoutes mounts verified-phone login routes.
func (s *Server) RegisterPhoneRoutes(mux *http.ServeMux, cfg PhoneRoutes) {
	prefix := cfg.Prefix
	if prefix == "" {
		prefix = "/api/auth"
	}
	send := cfg.SendLimiter
	if send == nil {
		send = NewRateLimiter(20, time.Hour)
	}
	login := cfg.LoginLimiter
	if login == nil {
		login = NewRateLimiter(30, 10*time.Minute)
	}
	if cfg.SMS != nil {
		if len(cfg.SMS.HMACKey) == 0 {
			cfg.SMS.HMACKey = append([]byte(nil), s.secret...)
		}
		mux.Handle(prefix+"/sms/send", s.maybeLimited(send, s.SendSMSCode(cfg.SMS)))
		mux.Handle(prefix+"/sms/login", s.maybeLimited(login, s.PhoneLogin(cfg.SMS)))
	}
	if cfg.Fusion != nil {
		mux.Handle(prefix+"/fusion/login", s.maybeLimited(login, s.PhoneLogin(cfg.Fusion)))
	}
	if cfg.FusionToken != nil {
		mux.Handle(prefix+"/fusion/token", s.maybeLimited(send, fusionToken(cfg.FusionToken)))
	}
}

func limited(l *RateLimiter, clientIP func(*http.Request) string, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			writeError(w, http.StatusMethodNotAllowed, CodeMethodNotAllowed, "method not allowed")
			return
		}
		if !l.Allow(clientIP(r), time.Now()) {
			writeError(w, http.StatusTooManyRequests, CodeTooManyRequests, "too many requests")
			return
		}
		next.ServeHTTP(w, r)
	})
}

func decodeBody(w http.ResponseWriter, r *http.Request, v any) bool {
	r.Body = http.MaxBytesReader(w, r.Body, 1<<16)
	d := json.NewDecoder(r.Body)
	d.DisallowUnknownFields()
	if d.Decode(v) != nil || d.Decode(&struct{}{}) != io.EOF {
		writeError(w, http.StatusBadRequest, CodeInvalidRequest, "invalid request")
		return false
	}
	return true
}

// MaskPhone keeps the first 3 and last 2 digits for logs.
func MaskPhone(p string) string {
	if len(p) < 7 {
		return "***"
	}
	return p[:3] + strings.Repeat("*", len(p)-5) + p[len(p)-2:]
}

// SendSMSCode handles {"phone"} and responds {"ok":true,"cooldown":60}.
// The code is never included in responses or logs.
func (s *Server) SendSMSCode(codes *SMSCodes) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var in struct {
			Phone string `json:"phone"`
		}
		if !decodeBody(w, r, &in) {
			return
		}
		phone := strings.TrimSpace(in.Phone)
		ctx := WithSMSClientIP(r.Context(), s.requestClientIP(r))
		switch err := codes.Send(ctx, phone); {
		case err == nil:
			writeJSON(w, http.StatusOK, map[string]any{"ok": true, "cooldown": codes.CooldownSeconds()})
		case errors.Is(err, ErrInvalidPhone):
			writeError(w, http.StatusBadRequest, CodeInvalidPhone, "invalid phone number")
		case errors.Is(err, ErrTooFrequent):
			writeError(w, http.StatusTooManyRequests, CodeSMSTooFrequent, "please wait before requesting another code")
		case errors.Is(err, ErrDailyLimit):
			writeError(w, http.StatusTooManyRequests, CodeSMSDailyLimit, "daily code limit reached")
		default:
			log.Printf("authserver: sms send to %s failed: %v", MaskPhone(phone), err)
			writeError(w, http.StatusBadGateway, CodeSMSUnavailable, "sms service unavailable")
		}
	})
}

// PhoneLogin verifies a PhoneCredential and responds like Login, plus
// "created" when a new user was registered.
func (s *Server) PhoneLogin(v PhoneVerifier) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var cred PhoneCredential
		if !decodeBody(w, r, &cred) {
			return
		}
		phone, err := v.VerifyPhone(r.Context(), cred)
		if err != nil {
			if !errors.Is(err, ErrVerificationFailed) {
				log.Printf("authserver: phone verification error: %v", err)
				writeError(w, http.StatusBadGateway, CodeVerificationUnavailable, "verification service unavailable")
				return
			}
			writeError(w, http.StatusUnauthorized, CodeVerificationFailed, "verification failed")
			return
		}
		user, created, err := s.UserForPhone(r.Context(), phone)
		if err != nil {
			writeError(w, http.StatusInternalServerError, CodeInternalError, "login failed")
			return
		}
		s.writeAuthSession(w, user, &created)
	})
}

// UserForPhone returns the user for a verified phone, registering one with
// an unusable random password when absent.
func (s *Server) UserForPhone(parent context.Context, phone string) (*User, bool, error) {
	ctx, cancel := s.dbContext(parent)
	defer cancel()
	user, err := s.store.GetUserByPhone(ctx, phone)
	if err == nil {
		return user, false, nil
	}
	if !errors.Is(err, ErrUserNotFound) {
		return nil, false, err
	}
	secret := make([]byte, 32)
	if _, err := rand.Read(secret); err != nil {
		return nil, false, err
	}
	hash, err := bcrypt.GenerateFromPassword([]byte(hex.EncodeToString(secret)[:64]), s.bcryptCost)
	if err != nil {
		return nil, false, err
	}
	if _, err := s.store.CreateUser(ctx, phone, string(hash)); err != nil {
		// Lost a race with a concurrent registration: use that user.
		if user, err2 := s.store.GetUserByPhone(ctx, phone); err2 == nil {
			return user, false, nil
		}
		return nil, false, err
	}
	user, err = s.store.GetUserByPhone(ctx, phone)
	return user, err == nil, err
}

func fusionToken(issue func(context.Context, string) (any, error)) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var in struct {
			Platform string `json:"platform"`
		}
		if !decodeBody(w, r, &in) {
			return
		}
		if in.Platform != "android" && in.Platform != "ios" {
			writeError(w, http.StatusBadRequest, CodeUnsupportedPlatform, "unsupported platform")
			return
		}
		out, err := issue(r.Context(), in.Platform)
		if err != nil {
			log.Printf("authserver: fusion token (%s) failed: %v", in.Platform, err)
			writeError(w, http.StatusBadGateway, CodeVerificationUnavailable, "verification service unavailable")
			return
		}
		writeJSON(w, http.StatusOK, out)
	})
}
