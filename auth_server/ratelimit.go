package authserver

import (
	"net"
	"net/http"
	"strings"
	"sync"
	"time"
)

// RateLimiter is an in-memory fixed-window counter per key (typically a
// client IP). Limits apply per server process.
type RateLimiter struct {
	mu     sync.Mutex
	max    int
	window time.Duration
	hits   map[string]*rateWindow
	sweep  time.Time
}

type rateWindow struct {
	start time.Time
	n     int
}

// NewRateLimiter allows max hits per key in each window.
func NewRateLimiter(max int, window time.Duration) *RateLimiter {
	if max <= 0 || window <= 0 {
		panic("authserver: rate limit must be positive")
	}
	return &RateLimiter{max: max, window: window, hits: map[string]*rateWindow{}}
}

// Allow records one hit for key at now and reports whether it is within the limit.
func (l *RateLimiter) Allow(key string, now time.Time) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	if now.Sub(l.sweep) > l.window {
		for k, w := range l.hits {
			if now.Sub(w.start) >= l.window {
				delete(l.hits, k)
			}
		}
		l.sweep = now
	}
	w := l.hits[key]
	if w == nil || now.Sub(w.start) >= l.window {
		w = &rateWindow{start: now}
		l.hits[key] = w
	}
	w.n++
	return w.n <= l.max
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
