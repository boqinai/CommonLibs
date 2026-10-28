# auth_server

登录成功响应同时包含 JWT 和完整用户资料：`{"token":"...","user":{"id":1,"phone":"...","nickname":"","avatar":"0"}}`，客户端无需再请求 `/me` 才能建立登录态。

`WithTokenExpiry` 与 `WithDatabaseTimeout` 必须传入正数；无效配置会在构造 Server 时立即失败。

Boqinai Go 服务共用的手机号/密码认证模块：SQLite 用户表、bcrypt 密码哈希、HS256 access/refresh JWT、注册、登录、`/me` 和认证中间件。

错误响应为 `{"code":"invalid_credentials","message":"invalid phone or password"}`。客户端应根据稳定的 `code` 翻译提示，`message` 用于日志。

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
go get github.com/boqinai/CommonLibs/auth_server@auth_server/v0.15.1
```

使用 `modernc.org/sqlite` 连接池时，应在 DSN 上为每条连接设置 PRAGMA：

```go
db, err := sql.Open(
    "sqlite",
    "./app.db?_busy_timeout=5000&_journal_mode=wal",
)
```

`Init` 不会修改宿主的连接池大小。`RegisterRoutes` 自带按 IP 限流（注册默认每小时 20 次，登录默认 10 分钟 30 次），可用 `WithCredentialRateLimiters` 自定义或 `WithoutCredentialRateLimit` 关闭（测试用）。生产仍建议在反向代理再加一层。默认密码 8–72 字节。密码注册/登录的手机号默认是 `MainlandPhone`（大陆 11 位）；其他格式用 `WithPhoneValidator`。`UpdateProfile` 使用 UPDATE 再 SELECT，不依赖 SQLite `RETURNING`（保持 3.22 可用）。

## Access / Refresh Token

登录、短信登录、融合认证登录成功时同时签发一对 HS256 token（算法只接受 HS256）。access token 必须带 `typ=access` 和 `jti`，否则 `RequireAuth` 拒绝。`WithTokenExpiry` 设置 access token 有效期，默认 **2 小时**（`DefaultAccessTokenTTL`）。

登录、短信登录、融合认证登录成功时的响应：

```json
{"token":"<access>","refresh_token":"<refresh>","expires_in":7200,"user":{"id":1,"phone":"..."}}
```

短信 / 融合认证响应带 `"created"`。`POST /api/auth/register` **不**签发 JWT。

| | access | refresh |
| --- | --- | --- |
| 默认 TTL | 2 小时（`WithTokenExpiry`） | 30 天（`WithRefreshTokenExpiry`） |
| `typ` | `access` | `refresh` |
| 其它 claims | `jti`（每次随机）、`sub`（用户 id）、`exp` | 同左 |

`RequireAuth` 拒绝 refresh token。`POST /api/auth/refresh` body `{"refresh_token":"..."}` 校验通过后**先签发**新的 access + refresh，**再**用 `TokenBlacklist.Consume` 作废旧 refresh 的 `jti`（检查和写入在同一临界区）。只有 `Consume` 成功才把新一对返回给客户端（不含 `user`）。签发失败时旧 refresh 仍然有效。同一 refresh 并发两次，最多一次成功。用户已删除或该 `jti` 已被消费时返回 401 `invalid_refresh_token`。该路由默认按 IP 每 10 分钟 60 次。

`POST /api/auth/logout` 撤销 `Authorization: Bearer` access token 的 `jti`（过期也认签名，便于退出），body 可带 `{"refresh_token":"..."}` 一并撤销。签名不对的字符串会被忽略。成功响应 `{"ok":true}`。黑名单存储失败时返回 500，调用方应重试；auth_client 仍会清掉本地会话。

撤销列表是 `TokenBlacklist`（`Revoke`、`IsRevoked`、`Consume`、`Prune`）。`Prune(ctx, now)` 批量删除已过期的 `jti`；内存和 SQLite 实现大约每 32 次 `Consume` 抽样调用一次，宿主也可以自己定时调用。默认 `MemoryTokenBlacklist` 把 `jti` 留到该 token 自己的 `exp`，进程内有效，**不使用 SQLite**。多实例用 `NewSQLiteTokenBlacklist` 或 `WithTokenBlacklist` 换共享存储。自备或使用 SQLite 时保持 3.22 兼容：`Consume` 用 `BEGIN IMMEDIATE` 加 `busy_timeout`，忙则重试，语句仍是 `INSERT OR IGNORE` 加 `RowsAffected`，靠 `jti` 主键决定谁赢。并发输家得到 401，而不是 `SQLITE_BUSY` 变成的 500。不要用 `UPSERT` / `RETURNING`。`IssueToken` 只返回 access token；`IssueTokens` 返回一对。

## 错误码

响应形如 `{"code":"...","message":"..."}`。`code` 是稳定字符串，定义在 `codes.go`，与 auth_client `AuthErrorCode` 对齐。下面这些值在 0.11.0 没有改名；短信 / 融合认证的 URL 也没有改：

| code | 典型 HTTP |
| --- | --- |
| `invalid_request` | 400 |
| `invalid_credentials_format` | 400 |
| `invalid_phone` | 400 |
| `unsupported_platform` | 400 |
| `invalid_credentials` | 401 |
| `unauthorized` | 401 |
| `verification_failed` | 401 |
| `invalid_refresh_token` | 401 |
| `user_not_found` | 404 |
| `phone_already_registered` | 409 |
| `method_not_allowed` | 405 |
| `profile_not_supported` | 501 |
| `sms_too_frequent` / `sms_daily_limit` / `too_many_requests` | 429 |
| `sms_unavailable` / `verification_unavailable` | 502 |
| `internal_error` | 500 |

客户端另有 `invalid_response`、`network_failure`，服务端不会返回。

公开路径（与现有 App 对齐，不要改）：

- `POST /api/auth/sms/send`
- `POST /api/auth/sms/login`
- `POST /api/auth/fusion/login`
- `POST /api/auth/fusion/token`
- `POST /api/auth/refresh`
- `POST /api/auth/logout`

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

- `SMSCodes`：验证码自行生成与校验——存 `HMAC-SHA256(HMACKey, code)`（`RegisterPhoneRoutes` 在 HMACKey 为空时用 JWT secret）、常量时间比较、一次性、默认 5 分钟过期、最多 5 次尝试、60 秒重发冷却、每号每天 10 条；**状态仅在单进程内存中**（多副本/重启会丢未用验证码，需要跨实例时请自备存储）。压缩时丢掉 24 小时前的发送时间、删除空键。软上限只淘汰**没有未过期验证码、且 24 小时窗口内没有发送记录**的号码；这些受保护的号码仍占满上限时，新号码返回 `ErrTooFrequent`（429），不会清掉受害者的日限额或未过期验证码。`IPDailyLimit` 为每个客户端 IP 的 24 小时发送上限（0 表示默认 1000，负数关闭）；`SendSMSCode` 会用 `WithSMSClientIP` 带上当前客户端 IP。抽随机数失败时，手机号冷却/日限额和 IP 日限额都会退回，不会在没发出短信时扣配额。测试可以把 `SMSCodes.Entropy` 换成会失败的 `io.Reader`（`nil` 使用 `crypto/rand`）。验证码永远不会出现在响应或日志里（日志中手机号经 `MaskPhone` 脱敏）。
- 限流：`SendLimiter`（`/sms/send` 与 `/fusion/token` 共用，默认每 IP 每小时 20 次）和 `LoginLimiter`（默认每 IP 10 分钟 30 次）。默认只认 `RemoteAddr`（`ClientIP`）。在反向代理后面时先 `ParseTrustedProxies` 再 `WithTrustedProxies`（见下），或用 `WithClientIPResolver` 自定义。未配置时，客户端伪造的 `X-Forwarded-For` 不能换限流桶。`RateLimiter` 也可单独用于宿主自己的路由。

`PENNY_TRUSTED_PROXIES` 是逗号、分号或空白分隔的 IP / CIDR。非法配置必须由宿主处理错误，`New` 不会因此 panic：

```go
prefixes, err := authserver.ParseTrustedProxies(os.Getenv("PENNY_TRUSTED_PROXIES"))
if err != nil {
    log.Fatalf("PENNY_TRUSTED_PROXIES: %v", err)
}
auth := authserver.New(db, secret, authserver.WithTrustedProxies(prefixes...))
```

只解析来自这些代理的 `X-Forwarded-For`，从右向左跳过仍受信任的代理。如果每一跳都在信任列表里，限流键是 TCP 对端 `RemoteAddr`，不是最左边那个值。遇到不是合法 IP 的跳（带端口、括号、或其它无法解析的字符串）时停住，丢弃这一跳及其左边的值，改用 TCP 对端 `RemoteAddr`，因此轮换非法字符串不能换新桶。合法地址会规范成同一写法（IPv4-mapped IPv6 还原成 IPv4，并去掉 zone），同址不同拼法共用一个桶。`ParseTrustedProxies` 把 IPv4-mapped 前缀还原并掩码：`::ffff:10.0.0.0/104` 与未对齐的 `::ffff:10.1.2.3/104` 都是 `10.0.0.0/8`，`::ffff:10.1.2.3/128` 是主机 `10.1.2.3/32`。短于 `/96` 的 mapped 前缀会被拒绝。前缀长度为 0 的项也会被拒绝，包括 `0.0.0.0/0`、`::/0`，以及规范化之后变成 `/0` 的 mapped 写法（`::ffff:0.0.0.0/96`、`::ffff:10.1.2.3/96`）。信任所有地址会让任意对端的 `X-Forwarded-For` 生效。`ClientIP` 本身仍只返回 `RemoteAddr`。空字符串表示不信任任何代理。
- 错误码见上面的表。短信 / 融合认证路径字符串保持原样。
- 只需要 JWT 时可单独使用 `Server.UserForPhone` 与 `Server.IssueToken`（仅 access）或 `Server.IssueTokens`（一对）。

### `aliyun` 子包

号码认证服务 dypns（2017-05-25）最小客户端，零第三方依赖：`GetFusionAuthToken`、`VerifyWithFusionAuthToken`、`SendSmsVerifyCode`、`CheckSmsVerifyCode`、通用 `Call` 与 `Sign`。不读取环境变量，凭据由宿主传入。

`SMSSender` 用 `SendSmsVerifyCode` 下发显式验证码（`TemplateParam {"code","min"}`），适配控制台“赠送签名/赠送模板”（模板变量 `${code}`、`${min}`），因此无需调用 `CheckSmsVerifyCode`。阿里云的 `FREQUENCY_FAIL`、`BUSINESS_LIMIT_CONTROL`、`MOBILE_NUMBER_ILLEGAL` 分别映射为 `ErrTooFrequent`、`ErrDailyLimit`、`ErrInvalidPhone`。

RAM 权限：短信需 `dypns:SendSmsVerifyCode`（使用阿里云生成的验证码时再加 `dypns:CheckSmsVerifyCode`）；一键登录需 `dypns:GetFusionAuthToken`、`dypns:VerifyWithFusionAuthToken`。
