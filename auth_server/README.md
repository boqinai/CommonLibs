# auth_server

Boqinai Go 服务共用的手机号/密码认证模块：SQLite 用户表、bcrypt 密码哈希、30 天 HS256 JWT、注册、登录、`/me` 和认证中间件。

`Init` 会启用 SQLite WAL 和 5 秒 busy timeout，并限制为单连接以保证连接级 PRAGMA 对所有认证请求生效。

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
