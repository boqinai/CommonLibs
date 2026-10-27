## 0.14.0

- Expose `lastLoginCreated` after verified-phone login (SMS / fusion) so hosts can tell new registrations apart without parsing raw JSON.
- Correct the 0.4.0 CHANGELOG note: `flutter_secure_storage` remains 10.3.1 (not 11.0.0).
- Document that plaintext `TokenStore` is for tests/migration only; production should keep the default `SecureTokenStore`.

## 0.13.0

- Add verified-phone login against auth_server >= 0.9.0: `sendSmsCode`, `loginWithSmsCode`, `fusionAuthToken`, `loginWithFusionToken`.
- Add error codes for SMS / fusion login (`invalid_phone`, `verification_failed`, `sms_too_frequent`, `sms_daily_limit`, `too_many_requests`, `sms_unavailable`, `verification_unavailable`, `unsupported_platform`).

## 0.12.0

- Parse and cache the user profile returned alongside the login token.
- Reuse the cached profile after login and keep it synchronized after profile updates.
- Keep compatibility with legacy login responses that only contain a token.

## 0.11.1

- Validate profile payloads and classify invalid UTF-8 responses as `invalid_response`.
- Reject malformed profile-update responses instead of hiding them with a follow-up request.

## 0.11.0

- Add `UserProfile` model and `updateProfile` API to manage user nickname and avatar.
- Decode responses as UTF-8 by default.

## 0.10.0

- Invalidate in-flight token refresh completions if logout occurs concurrently.
- Validate HTTP methods against supported verbs upfront.

## 0.9.0

- Coalesce concurrent token refresh attempts so parallel 401 responses reuse one refresh operation.

## 0.8.0

- Add authentication state events, dynamic header injection, typed response decoding, and token refresh hooks.
- Improve exception diagnostics and reuse compiled regular expressions.

## 0.7.0

- Add PATCH support and normalize relative request paths.
- Avoid serializing absent POST and PUT bodies as JSON `null`.
- Classify successful non-JSON responses as `invalid_response`.

## 0.4.0

- Add one-time legacy TokenStorage migration.
- Require HTTPS for remote authentication endpoints.
- Depend on flutter_secure_storage 10.3.1 (CHANGELOG previously misstated 11.0.0).

## 0.3.0

- Store tokens in platform secure storage by default.
- Preserve cached sessions when validation fails because the device is offline.

## 0.2.0

- Add authenticated JSON business requests, 401 session cleanup, and HTTP client close.
## 0.1.0

- Add shared registration, login, token persistence, restore, logout, and optional current-user validation.
