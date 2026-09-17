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
- Upgrade flutter_secure_storage to 11.0.0.

## 0.3.0

- Store tokens in platform secure storage by default.
- Preserve cached sessions when validation fails because the device is offline.

## 0.2.0

- Add authenticated JSON business requests, 401 session cleanup, and HTTP client close.
## 0.1.0

- Add shared registration, login, token persistence, restore, logout, and optional current-user validation.

