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
