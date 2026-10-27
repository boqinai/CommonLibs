package authserver

import (
	"fmt"
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
// to the left of the real client are ignored.
func clientIP(r *http.Request, trusted []*net.IPNet) string {
	peer := remoteHost(r)
	if len(trusted) == 0 || !ipInNets(peer, trusted) {
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
		if !ipInNets(hops[i], trusted) {
			return hops[i]
		}
	}
	return hops[0]
}

func remoteHost(r *http.Request) string {
	host, _, err := net.SplitHostPort(strings.TrimSpace(r.RemoteAddr))
	if err != nil {
		return strings.TrimSpace(r.RemoteAddr)
	}
	return host
}

func parseTrustedProxies(values []string) ([]*net.IPNet, error) {
	out := make([]*net.IPNet, 0, len(values))
	for _, raw := range values {
		v := strings.TrimSpace(raw)
		if v == "" {
			return nil, fmt.Errorf("empty trusted proxy")
		}
		if strings.Contains(v, "/") {
			_, network, err := net.ParseCIDR(v)
			if err != nil {
				return nil, fmt.Errorf("%s: %w", v, err)
			}
			out = append(out, network)
			continue
		}
		ip := net.ParseIP(v)
		if ip == nil {
			return nil, fmt.Errorf("invalid trusted proxy %q", v)
		}
		if v4 := ip.To4(); v4 != nil {
			out = append(out, &net.IPNet{IP: v4, Mask: net.CIDRMask(32, 32)})
			continue
		}
		out = append(out, &net.IPNet{IP: ip, Mask: net.CIDRMask(128, 128)})
	}
	return out, nil
}

func ipInNets(host string, nets []*net.IPNet) bool {
	ip := net.ParseIP(strings.TrimSpace(host))
	if ip == nil {
		return false
	}
	for _, network := range nets {
		candidate := ip
		if len(network.IP) == net.IPv4len {
			if v4 := ip.To4(); v4 != nil {
				candidate = v4
			}
		}
		if network.Contains(candidate) {
			return true
		}
	}
	return false
}
