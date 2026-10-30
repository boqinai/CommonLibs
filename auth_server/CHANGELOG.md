## Unreleased

- GetMobile defaults to the standalone endpoint without mutating shared configuration; classify only explicit invalid-token errors as verification rejections while preserving operational failures.

- Add standalone `aliyun.Client.GetMobile` and `aliyun.CarrierVerifier`; SDK authorization tokens stay distinct from fusion verify tokens. No app configuration or account/session policy is included.

## 0.15.1

- `ParseTrustedProxies` normalizes IPv4-mapped IPv6 CIDRs such as `::ffff:10.0.0.0/104` to their IPv4 equivalent (`10.0.0.0/8`). The prefix is masked, so a non-aligned form such as `::ffff:10.1.2.3/104` is `10.0.0.0/8` and `::ffff:10.1.2.3/128` is the host `10.1.2.3/32`. Mapped prefixes shorter than `/96` are rejected because they cannot be represented as an IPv4 network after XFF address canonicalization.
- Prefix length 0 is rejected. That includes `0.0.0.0/0`, `::/0`, and mapped forms that normalize to a `/0` (`::ffff:0.0.0.0/96`, `::ffff:10.1.2.3/96`). A `/0` would treat every peer as a trusted proxy and honor `X-Forwarded-For` from any client.

## 0.15.0

- Trusted-proxy `X-Forwarded-For` hops that are not valid IP addresses are not rate-limit keys. The right-to-left walk stops at the first illegal hop and uses the TCP peer (`RemoteAddr`). Rotating illegal strings cannot mint fresh buckets, and hops to the left of that illegal hop are ignored. Valid hops are canonical (`netip.Addr` with IPv4-mapped addresses unmapped and zones removed), so equivalent spellings share one bucket. `ClientIP` still returns `RemoteAddr` and ignores `X-Forwarded-For`. `ParseTrustedProxies` is unchanged.
- `SMSCodes.Send` rolls back the phone cooldown/daily reservation and the IP daily reservation when the CSPRNG fails before a code is sent. `SMSCodes.Entropy` overrides that reader (`nil` uses `crypto/rand`). A failed draw does not cool the number down or consume either daily quota.

## 0.14.0

- **Breaking:** `WithTrustedProxies` takes `...netip.Prefix`, not raw strings, and does not panic. Parse `PENNY_TRUSTED_PROXIES` with `ParseTrustedProxies(string) ([]netip.Prefix, error)` (commas, semicolons, or whitespace). An empty string means no trusted proxies. When every `X-Forwarded-For` hop is trusted, the rate-limit key is the TCP peer (`RemoteAddr`), not the leftmost hop.
- **Breaking:** `TokenBlacklist` gains `Prune(ctx, now)`, which bulk-deletes expired `jti` rows. `MemoryTokenBlacklist` and `SQLiteTokenBlacklist` sample it from `Consume`.
- SMS compaction no longer evicts a phone that still has an unexpired code or a send inside the 24h window. Flooding the soft cap cannot reset a victim's daily limit or delete its code. A new number is refused with `ErrTooFrequent` while protected entries still fill the cap. `IPDailyLimit` (default 1000, negative disables) caps sends per client IP per 24h when `WithSMSClientIP` is set; `SendSMSCode` sets it from the server client-IP policy.
- `SQLiteTokenBlacklist` takes the write lock with `BEGIN IMMEDIATE`, sets `busy_timeout`, and retries `SQLITE_BUSY`. A concurrent refresh loser is revoked (401), not HTTP 500. Statements stay on SQLite 3.22 (`INSERT OR IGNORE`, no UPSERT, no `RETURNING`).
- `POST /api/auth/refresh` signs the replacement pair before `Consume`. If signing fails, the presented refresh token stays valid.

## 0.13.0

- **Breaking:** `TokenBlacklist` gains `Consume`, the atomic revoke-if-active used by `POST /api/auth/refresh`. Two refreshes of the same token can no longer both succeed. `MemoryTokenBlacklist.Consume` holds one lock for the check and the insert. `SQLiteTokenBlacklist` does the same in one transaction with `INSERT OR IGNORE` and `RowsAffected` (SQLite 3.22: no UPSERT, no RETURNING).
- **Breaking:** `ClientIP` returns `RemoteAddr` only. `X-Forwarded-For` is ignored unless `WithTrustedProxies` lists the immediate peer (IP or CIDR) or `WithClientIPResolver` replaces the policy. A spoofed forwarding header no longer skips per-IP limits.
- `SMSCodes.compactLocked` drops send timestamps older than 24h, deletes empty keys, and evicts the oldest phones by last activity when the map is still above the soft cap.

## 0.12.0

- Access tokens must include `typ=access` and a `jti`. `RequireAuth` rejects tokens that only have `sub` and `exp`, tokens without `typ`, and access tokens without `jti`.
- `Init` creates the full `users` table, including `nickname` and `avatar`. It no longer alters an older table to add those columns.
- Password register and login use `MainlandPhone` unless `WithPhoneValidator` supplies another pattern.
- `WithTokenExpiry` still sets the access-token lifetime (default 2 hours). It is not a switch back to a previous default.

## 0.11.0

- **Breaking:** default access-token TTL is 2 hours (`DefaultAccessTokenTTL`), not 30 days. Hosts that still want a long-lived access token can pass `WithTokenExpiry(30 * 24 * time.Hour)` and ignore refresh tokens. Tokens already issued with only `sub` and `exp` stay valid until that original `exp`, but they have no `jti` and cannot be revoked.
- Login, SMS login, and fusion login return `token` (access), `refresh_token` (default 30 days, `DefaultRefreshTokenTTL`), and `expires_in` (access TTL in seconds). `POST /api/auth/register` still does not issue a JWT.
- Access and refresh tokens stay HS256 and add `jti`, `typ` (`access` or `refresh`), `sub`, and `exp`. `RequireAuth` rejects refresh tokens.
- `POST /api/auth/refresh` rotates the refresh token. `POST /api/auth/logout` revokes the bearer access token's `jti` and an optional `refresh_token`.
- Revocation uses `TokenBlacklist`. The default `MemoryTokenBlacklist` keeps each `jti` until that token's `exp` and does not use SQLite. More than one process must pass a shared store to `WithTokenBlacklist`.
- `WithRefreshTokenExpiry` sets the refresh TTL. `IssueToken` still returns only an access token; `IssueTokens` returns both.
- `/api/auth/refresh` is limited per IP (default 60 requests / 10 minutes).
- HTTP `code` strings are constants in `codes.go`. Values are unchanged. New code: `invalid_refresh_token`. SMS and fusion URL paths are unchanged.

## 0.10.0

- Built-in per-IP rate limits on `/register` and `/login` (defaults 20/hour and 30/10min); customize with `WithCredentialRateLimiters` or disable with `WithoutCredentialRateLimit`.
- Raise minimum password length from 6 to 8 bytes.
- Store SMS codes as HMAC-SHA256(server secret, code) instead of bare SHA-256; `RegisterPhoneRoutes` copies the JWT secret when `SMSCodes.HMACKey` is empty.
- `UpdateProfile` uses UPDATE then SELECT (no `RETURNING`) for broader SQLite compatibility.
- Optional `WithPhoneValidator` for password register/login (default keeps the historical loose 6–32 byte phone rule).
- `RateLimiter` and in-memory SMS maps compact / cap growth under load.
- Bump `modernc.org/sqlite` to v1.61.0 and `golang.org/x/crypto` to v0.58.0.

## 0.9.0

- Add verified-phone login (`PhoneVerifier`, `RegisterPhoneRoutes`, `PhoneLogin`, `UserForPhone`, `IssueToken`) with auto-registration.
- Add self-managed SMS codes (`SMSCodes`, `CodeSender`): hashed, constant-time, single-use, expiry, attempts, cooldown and daily caps.
- Add per-IP `RateLimiter` and `ClientIP`.
- Add `aliyun` subpackage: dypns client (fusion auth + SMS verification), `SMSSender`, `FusionVerifier`.
