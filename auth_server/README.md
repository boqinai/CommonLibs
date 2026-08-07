# auth_server

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
go get github.com/boqinai/CommonLibs/auth_server@latest
```

使用 `modernc.org/sqlite` 连接池时，应在 DSN 上为每条连接设置 PRAGMA：

```go
db, err := sql.Open(
    "sqlite",
    "./app.db?_busy_timeout=5000&_journal_mode=wal",
)
```

`Init` 不会修改宿主的连接池大小。生产服务必须在反向代理或 HTTP 中间件中对注册、登录接口限流；手机号限制为 6–32 字节，密码限制为 6–72 字节。
