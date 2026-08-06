# auth_client

Boqinai Flutter 应用共用的手机号/密码认证客户端。

公共库负责注册/登录协议、Token 持久化、恢复、退出、Bearer 请求头，以及可选的 `/api/auth/me` 校验。表单、密码规则、错误文案和登录后的业务流程仍由各 App 负责。

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

ChessGame 启动恢复使用 `restore(validate: true)`；MoneyMap 没有 `/me`，使用默认 `restore()`。
