# auth_client

登录响应为 `{ "token": "...", "refresh_token": "...", "expires_in": 7200, "user": { "id", "phone", "nickname", "avatar" } }`。`token`、`refresh_token` 和 `user` 都必填；短信/融合登录还可带 `created`。登录成功后可通过 `client.profile` 同步读取缓存资料，或调用 `currentUserProfile()`；已有缓存时不会再次请求 `/me`，传入 `forceRefresh: true` 可强制刷新。

access token 默认 2 小时，refresh token 默认 30 天。401 会自动 `POST /api/auth/refresh`（与 `onRefreshToken` 一样合并并发、并在 logout 后丢弃过期结果）。自定义 `onRefreshToken` 优先于内置刷新，它只返回新的 access token，并沿用当前 refresh token。`logout()` 请求 `POST /api/auth/logout` 撤销 access 与 refresh；服务端失败也会清本地会话。

Boqinai Flutter 应用共用的手机号/密码认证客户端。

Token 默认保存在系统安全存储（Android Keystore 加密存储、Apple Keychain）中。仅测试或低安全场景才显式传入文件型 `TokenStore`。Android 最低 API 23；各平台配置见
[`flutter_secure_storage`](https://pub.dev/packages/flutter_secure_storage)。`restore(validate: true)` 遇到网络失败时保留缓存会话，只有服务端明确返回 401 才清除。


公共库负责注册/登录协议、Token 持久化、恢复、退出、Bearer 请求头，以及可选的 `/api/auth/me` 校验。表单、密码规则、错误文案和登录后的业务流程仍由各 App 负责。

`AuthException.code` 提供稳定的机器错误码，客户端应使用 `AuthErrorCode` 翻译用户提示；`message` 保留服务端原始信息。这些字符串与 auth_server `codes.go` 一致（含 `profile_not_supported`、`invalid_refresh_token`）。`invalid_response` 和 `network_failure` 只由客户端产生。错误体必须是带 `message` 的 JSON，否则为 `invalid_response`。

```yaml
dependencies:
  auth_client:
    git:
      url: https://github.com/boqinai/CommonLibs.git
      path: auth_client
```

```dart
final auth = AuthClient(baseUrl: 'https://api.example.com/product');
await auth.register(phone, password);
await auth.login(phone, password);
final token = await auth.restore();
final user = await auth.currentUser(); // 服务端支持 /api/auth/me 时使用
final headers = auth.authorizationHeaders;
await auth.logout(); // 通知服务端撤销，并清除本地会话
```

认证端点默认位于 `/api/auth`。服务挂在其他路径时传入 `authPath`，例如 `AuthClient(baseUrl: apiUrl, authPath: '/auth')`。

ChessGame 启动恢复使用 `restore(validate: true)`；MoneyMap 没有 `/me`，使用默认 `restore()`。

## 认证后的业务请求

```dart
final data = await auth.authenticatedRequest(
  'PUT',
  '/api/document',
  body: {'value': 7},
);
```

支持 GET、POST、PUT、PATCH、DELETE；自动添加 Bearer Token、编码/解析 JSON，并在 401 时清除失效会话。不再使用时调用 `auth.close()`。

远程认证地址必须使用 HTTPS；仅本机开发地址允许 HTTP。测试或明确的低安全场景可以传入文件型 `TokenStore`。

## 短信验证码 / 本机号码一键登录

```dart
final cooldown = await auth.sendSmsCode(phone);    // 服务端返回的重发冷却秒数
await auth.loginWithSmsCode(phone, code);           // 未注册时自动注册

final init = await auth.fusionAuthToken('android'); // {"token","schemeCode",...}，交给 fusion_auth 插件
await auth.loginWithFusionToken(verifyToken);       // SDK 回调的统一认证 Token
```

错误使用 `AuthErrorCode.invalidPhone`、`verificationFailed`、`smsTooFrequent`、`smsDailyLimit`、`tooManyRequests`、`smsUnavailable`、`verificationUnavailable`、`unsupportedPlatform`、`profileNotSupported`、`invalidRefreshToken` 翻译。路径仍是 `/sms/send`、`/sms/login`、`/fusion/token`、`/fusion/login`，与服务端公开路径一致。UI（倒计时、协议勾选、一键登录失败回退到验证码表单）由各 App 自行实现。

内置 `TokenStore` / `SecureTokenStore` 把 refresh token 存在 access token 旁边（文件名加 `.refresh`，或 secure storage key 加 `.refresh`）。自定义 `TokenStorage` 必须同时持久化 access token 和 refresh token。
