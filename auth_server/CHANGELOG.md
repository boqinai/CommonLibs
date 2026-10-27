## 0.9.0

- Add verified-phone login (`PhoneVerifier`, `RegisterPhoneRoutes`, `PhoneLogin`, `UserForPhone`, `IssueToken`) with auto-registration.
- Add self-managed SMS codes (`SMSCodes`, `CodeSender`): hashed, constant-time, single-use, expiry, attempts, cooldown and daily caps.
- Add per-IP `RateLimiter` and `ClientIP`.
- Add `aliyun` subpackage: dypns client (fusion auth + SMS verification), `SMSSender`, `FusionVerifier`.
