# CommonLibs

Boqinai 应用共用基础库，避免在每个项目重复实现更新、认证和发布流程。

| 模块 | 用途 |
| --- | --- |
| `app_update` | Flutter Android 更新检查、DownloadManager 下载和安装 |
| `auth_client` | Flutter 注册、登录、Bearer 请求和安全 Token 存储 |
| `auth_server` | Go/SQLite 注册、登录、JWT 和认证中间件 |
| `release_tool` | Flutter APK 构建、GitHub Release 和更新中心上传 |

各模块独立版本化。业务项目应固定到对应 Tag，不要长期引用 `main`。接入和迁移方式见各模块 README。

## 验证

```bash
(cd app_update && flutter analyze --fatal-infos && flutter test)
(cd auth_client && flutter analyze --fatal-infos && flutter test)
(cd auth_server && go vet ./... && go test ./...)
(cd release_tool && python -m unittest discover -v)
```

许可证：[MIT](LICENSE)。
