package authserver

import (
	"net"
	"net/http"
	"strings"
	"sync"
	"time"
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

// ClientIP returns the last X-Forwarded-For hop (the one appended by the
// host's own reverse proxy; earlier hops are client-supplied), else the
// peer address. Hosts not behind a proxy that sets X-Forwarded-For should
// strip the header.
func ClientIP(r *http.Request) string {
	if f := r.Header.Get("X-Forwarded-For"); f != "" {
		parts := strings.Split(f, ",")
		if ip := strings.TrimSpace(parts[len(parts)-1]); ip != "" {
			return ip
		}
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}
