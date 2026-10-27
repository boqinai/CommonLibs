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
