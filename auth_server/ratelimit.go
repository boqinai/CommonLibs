package authserver

import (
	"fmt"
	"net"
	"net/http"
	"net/netip"
	"strings"
	"sync"
	"time"
	"unicode"
)

// RateLimiter is an in-memory fixed-window counter per key (typically a
// client IP). Limits apply per server process. Expired keys are swept every
// window; when the map exceeds maxKeys, expired entries are dropped and
// surplus live keys are evicted oldest-first.
type RateLimiter struct {
	mu      sync.Mutex
	max     int
	window  time.Duration
	maxKeys int
	hits    map[string]*rateWindow
	sweep   time.Time
}

type rateWindow struct {
	start time.Time
	n     int
}

const defaultRateLimiterMaxKeys = 10_000

// NewRateLimiter allows max hits per key in each window.
func NewRateLimiter(max int, window time.Duration) *RateLimiter {
	return NewRateLimiterWithCap(max, window, defaultRateLimiterMaxKeys)
}

// NewRateLimiterWithCap is NewRateLimiter with an explicit key cap.
func NewRateLimiterWithCap(max int, window time.Duration, maxKeys int) *RateLimiter {
	if max <= 0 || window <= 0 {
		panic("authserver: rate limit must be positive")
	}
	if maxKeys <= 0 {
		maxKeys = defaultRateLimiterMaxKeys
	}
	return &RateLimiter{max: max, window: window, maxKeys: maxKeys, hits: map[string]*rateWindow{}}
}

// Allow records one hit for key at now and reports whether it is within the limit.
func (l *RateLimiter) Allow(key string, now time.Time) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	if now.Sub(l.sweep) > l.window || len(l.hits) > l.maxKeys {
		l.compactLocked(now)
		l.sweep = now
	}
	w := l.hits[key]
	if w == nil || now.Sub(w.start) >= l.window {
		w = &rateWindow{start: now}
		l.hits[key] = w
	}
	w.n++
	if len(l.hits) > l.maxKeys {
		l.compactLocked(now)
	}
	return w.n <= l.max
}

func (l *RateLimiter) compactLocked(now time.Time) {
	for k, w := range l.hits {
		if now.Sub(w.start) >= l.window {
			delete(l.hits, k)
		}
	}
	for len(l.hits) > l.maxKeys {
		var oldestKey string
		var oldest time.Time
		first := true
		for k, w := range l.hits {
			if first || w.start.Before(oldest) {
				oldestKey, oldest, first = k, w.start, false
			}
		}
		delete(l.hits, oldestKey)
	}
}

// ClientIPResolver extracts the address used as a rate-limit key.
// WithClientIPResolver installs one and skips RemoteAddr / X-Forwarded-For handling.
type ClientIPResolver func(r *http.Request) string

// ClientIP returns the TCP peer from RemoteAddr. It ignores X-Forwarded-For.
// A client can set that header itself, so it is only consulted when the
// immediate peer is a trusted proxy (WithTrustedProxies) or the host
// installs a ClientIPResolver.
func ClientIP(r *http.Request) string {
	return remoteHost(r)
}

// clientIP applies trusted-proxy rules. An empty trusted list matches ClientIP.
// When the peer is trusted, X-Forwarded-For is walked from the right and the
// first hop that is not itself a trusted proxy is the client. Spoofed values
// to the left of the real client are ignored. If every hop is trusted, the
// peer (RemoteAddr) is the client — the leftmost value is not.
func clientIP(r *http.Request, trusted []netip.Prefix) string {
	peer := remoteHost(r)
	if len(trusted) == 0 || !ipInPrefixes(peer, trusted) {
		return peer
	}
	var hops []string
	for _, part := range strings.Split(r.Header.Get("X-Forwarded-For"), ",") {
		if hop := strings.TrimSpace(part); hop != "" {
			hops = append(hops, hop)
		}
	}
	if len(hops) == 0 {
		return peer
	}
	for i := len(hops) - 1; i >= 0; i-- {
		if !ipInPrefixes(hops[i], trusted) {
			return hops[i]
		}
	}
	return peer
}

// ParseTrustedProxies parses a PENNY_TRUSTED_PROXIES-style list of IP
// addresses and CIDRs. Separators are commas, semicolons, and whitespace.
// An empty string is valid and means no trusted proxies. Invalid entries
// return an error; nothing here panics.
func ParseTrustedProxies(raw string) ([]netip.Prefix, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil, nil
	}
	fields := strings.FieldsFunc(raw, func(r rune) bool {
		return r == ',' || r == ';' || unicode.IsSpace(r)
	})
	out := make([]netip.Prefix, 0, len(fields))
	for _, field := range fields {
		prefix, err := parseTrustedProxy(field)
		if err != nil {
			return nil, err
		}
		out = append(out, prefix)
	}
	return out, nil
}

func parseTrustedProxy(v string) (netip.Prefix, error) {
	if strings.Contains(v, "/") {
		prefix, err := netip.ParsePrefix(v)
		if err != nil {
			return netip.Prefix{}, fmt.Errorf("invalid trusted proxy %q: %w", v, err)
		}
		return prefix.Masked(), nil
	}
	addr, err := netip.ParseAddr(v)
	if err != nil {
		return netip.Prefix{}, fmt.Errorf("invalid trusted proxy %q", v)
	}
	addr = addr.Unmap()
	bits := addr.BitLen()
	return netip.PrefixFrom(addr, bits).Masked(), nil
}

func remoteHost(r *http.Request) string {
	host, _, err := net.SplitHostPort(strings.TrimSpace(r.RemoteAddr))
	if err != nil {
		return strings.TrimSpace(r.RemoteAddr)
	}
	return host
}

func ipInPrefixes(host string, prefixes []netip.Prefix) bool {
	addr, err := netip.ParseAddr(strings.TrimSpace(host))
	if err != nil {
		return false
	}
	addr = addr.Unmap()
	for _, prefix := range prefixes {
		if prefix.Contains(addr) {
			return true
		}
	}
	return false
}
