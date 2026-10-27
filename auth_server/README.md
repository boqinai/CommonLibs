# auth_server

登录成功响应同时包含 JWT 和完整用户资料：`{"token":"...","user":{"id":1,"phone":"...","nickname":"","avatar":"0"}}`，客户端无需再请求 `/me` 才能建立登录态。

`WithTokenExpiry` 与 `WithDatabaseTimeout` 必须传入正数；无效配置会在构造 Server 时立即失败。

Boqinai Go 服务共用的手机号/密码认证模块：SQLite 用户表、bcrypt 密码哈希、30 天 HS256 JWT、注册、登录、`/me` 和认证中间件。

错误响应为 `{"code":"invalid_credentials","message":"invalid phone or password"}`。客户端应根据稳定的 `code` 翻译提示，`message` 仅用于日志和兼容旧客户端。

`Init` 会启用 SQLite WAL 和 5 秒 busy timeout，但不会修改宿主配置的连接池大小。

```go
auth := authserver.New(db, []byte(os.Getenv("JWT_SECRET")))
if err := auth.Init(context.Background()); err != nil { log.Fatal(err) }
auth.RegisterRoutes(mux)

mux.Handle("/api/private", auth.RequireAuth(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
    userID, _ := authserver.UserID(r)
    // ...
})))
```

引用模块：

```bash
go get github.com/boqinai/CommonLibs/auth_server@auth_server/v0.10.0
```

使用 `modernc.org/sqlite` 连接池时，应在 DSN 上为每条连接设置 PRAGMA：

```go
db, err := sql.Open(
    "sqlite",
    "./app.db?_busy_timeout=5000&_journal_mode=wal",
)
```

`Init` 不会修改宿主的连接池大小。`RegisterRoutes` 自带按 IP 限流（注册默认每小时 20 次，登录默认 10 分钟 30 次），可用 `WithCredentialRateLimiters` 自定义或 `WithoutCredentialRateLimit` 关闭（测试用）。生产仍建议在反向代理再加一层。默认密码 8–72 字节；手机号默认仍是宽松的 6–32 字节校验，新应用建议 `WithPhoneValidator(MainlandPhone)`。`UpdateProfile` 不依赖 SQLite `RETURNING`（兼容 3.22+）。

## 手机号验证登录（短信验证码 / 本机号码一键登录）

`v0.9.0` 起提供“已验证手机号”登录：`PhoneVerifier` 证明调用方拥有某手机号，服务端随即登录该用户；用户不存在时自动注册（随机不可用密码，无法用密码登录，直到业务另行设置）。响应与 `/login` 相同，额外带 `"created": true|false`。

```go
import "github.com/boqinai/CommonLibs/auth_server/aliyun"

dypns := &aliyun.Client{AccessKeyID: id, AccessKeySecret: secret} // 由宿主从自己的配置读取
codes := &authserver.SMSCodes{Sender: &aliyun.SMSSender{
    Client: dypns, SignName: "速通互联验证码", TemplateCode: "100001",
}}
auth.RegisterPhoneRoutes(mux, authserver.PhoneRoutes{
    SMS:    codes,                              // POST /api/auth/sms/send {"phone"} → {"ok":true,"cooldown":60}
                                                // POST /api/auth/sms/login {"phone","code"}
    Fusion: aliyun.FusionVerifier{Client: dypns}, // POST /api/auth/fusion/login {"token"}
    FusionToken: func(ctx context.Context, platform string) (any, error) { /* 按平台调用 GetFusionAuthToken */ },
})
```

- `SMSCodes`：验证码自行生成与校验——存 `HMAC-SHA256(HMACKey, code)`（`RegisterPhoneRoutes` 在 HMACKey 为空时用 JWT secret）、常量时间比较、一次性、默认 5 分钟过期、最多 5 次尝试、60 秒重发冷却、每号每天 10 条；**状态仅在单进程内存中**（多副本/重启会丢未用验证码，需要跨实例时请自备存储）。验证码永远不会出现在响应或日志里（日志中手机号经 `MaskPhone` 脱敏）。
- 限流：`SendLimiter`（`/sms/send` 与 `/fusion/token` 共用，默认每 IP 每小时 20 次）和 `LoginLimiter`（默认每 IP 10 分钟 30 次），按 `ClientIP`（取 `X-Forwarded-For` 最后一跳，需由宿主自己的反向代理追加；不经代理时应剥离该头）。`RateLimiter` 也可单独用于宿主自己的路由。
- 错误码：`invalid_phone` 400、`verification_failed` 401、`sms_too_frequent` / `sms_daily_limit` / `too_many_requests` 429、`sms_unavailable` / `verification_unavailable` 502。
- 只需要 JWT 时可单独使用 `Server.UserForPhone` 与 `Server.IssueToken`。

### `aliyun` 子包

号码认证服务 dypns（2017-05-25）最小客户端，零第三方依赖：`GetFusionAuthToken`、`VerifyWithFusionAuthToken`、`SendSmsVerifyCode`、`CheckSmsVerifyCode`、通用 `Call` 与 `Sign`。不读取环境变量，凭据由宿主传入。

`SMSSender` 用 `SendSmsVerifyCode` 下发显式验证码（`TemplateParam {"code","min"}`），适配控制台“赠送签名/赠送模板”（模板变量 `${code}`、`${min}`），因此无需调用 `CheckSmsVerifyCode`。阿里云的 `FREQUENCY_FAIL`、`BUSINESS_LIMIT_CONTROL`、`MOBILE_NUMBER_ILLEGAL` 分别映射为 `ErrTooFrequent`、`ErrDailyLimit`、`ErrInvalidPhone`。

RAM 权限：短信需 `dypns:SendSmsVerifyCode`（使用阿里云生成的验证码时再加 `dypns:CheckSmsVerifyCode`）；一键登录需 `dypns:GetFusionAuthToken`、`dypns:VerifyWithFusionAuthToken`。
