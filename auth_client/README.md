# auth_client

新版登录响应为 `{ "token": "...", "user": { ... } }`。登录成功后可通过 `client.profile` 同步读取缓存资料，或调用 `currentUserProfile()`；已有缓存时不会再次请求 `/me`，传入 `forceRefresh: true` 可强制刷新。客户端仍兼容旧服务端仅返回 `token` 的响应。

Boqinai Flutter 应用共用的手机号/密码认证客户端。

Token 默认保存在系统安全存储（Android Keystore 加密存储、Apple Keychain）中。仅测试或低安全场景才显式传入文件型 `TokenStore`。Android 最低 API 23；各平台配置见
[`flutter_secure_storage`](https://pub.dev/packages/flutter_secure_storage)。`restore(validate: true)` 遇到网络失败时保留缓存会话，只有服务端明确返回 401 才清除。


公共库负责注册/登录协议、Token 持久化、恢复、退出、Bearer 请求头，以及可选的 `/api/auth/me` 校验。表单、密码规则、错误文案和登录后的业务流程仍由各 App 负责。

`AuthException.code` 提供稳定的机器错误码，客户端应使用 `AuthErrorCode` 翻译用户提示；`message` 保留服务端原始信息。客户端仍兼容旧服务端的纯文本错误响应，此时 `code` 为 `null`。

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
await auth.logout();
```

认证端点默认位于 `/api/auth`。旧服务使用其他路径时可传入 `authPath`，例如 `AuthClient(baseUrl: apiUrl, authPath: '/auth')`。

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

远程认证地址必须使用 HTTPS；仅本机开发地址允许 HTTP。迁移旧明文 Token 时显式传入：

```dart
final auth = AuthClient(
  baseUrl: apiUrl,
  tokenStore: MigratingTokenStorage(
    primary: SecureTokenStore(),
    legacy: TokenStore(name: 'old_session'),
  ),
);
```

首次读取成功后旧 Token 会写入安全存储并从旧位置删除。

## 短信验证码 / 本机号码一键登录（0.13.0，需 auth_server ≥ 0.9.0）

```dart
final cooldown = await auth.sendSmsCode(phone);    // 返回重发冷却秒数（默认 60）
await auth.loginWithSmsCode(phone, code);           // 未注册时自动注册

final init = await auth.fusionAuthToken('android'); // {"token","schemeCode",...}，交给 fusion_auth 插件
await auth.loginWithFusionToken(verifyToken);       // SDK 回调的统一认证 Token
```

错误使用 `AuthErrorCode.invalidPhone`、`verificationFailed`、`smsTooFrequent`、`smsDailyLimit`、`tooManyRequests`、`smsUnavailable`、`verificationUnavailable` 翻译。UI（倒计时、协议勾选、一键登录失败回退到验证码表单）由各 App 自行实现。
