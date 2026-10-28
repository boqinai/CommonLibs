# CommonLibs

Boqinai 应用共用基础库，避免在每个项目重复实现更新、认证和发布流程。

| 模块 | 用途 |
| --- | --- |
| `app_update` | Flutter Android 更新检查、前台服务下载和安装 |
| `fusion_auth` | Flutter 阿里云融合认证（本机号码一键登录）插件，Android/iOS |
| `auth_client` | Flutter 注册、登录、短信验证码/一键登录、Bearer 请求和安全 Token 存储 |
| `auth_server` | Go/SQLite 注册、登录、短信验证码/一键登录、JWT、限流和认证中间件 |
| `release_tool` | Flutter APK 构建、GitHub Release 和更新中心上传 |

各模块独立版本化。业务项目应固定到对应 Tag，不要长期引用 `main`。接入和迁移方式见各模块 README。

## Tag 命名

| 模块 | Tag 格式 | 示例 |
| --- | --- | --- |
| `auth_server` | 斜杠 | `auth_server/v0.14.0` |
| `auth_client` | 连字符 | `auth_client-v0.16.0` |
| `fusion_auth` | 连字符 | `fusion_auth-v0.3.2` |
| `app_update` | 连字符 | `app_update-v0.10.2` |
| `release_tool` | 连字符 | `release_tool-v0.5.0` |

Go 模块用斜杠 Tag（`go get ...@auth_server/vX.Y.Z`）；Flutter 包用连字符 Tag（pub `ref:`）。

## Git LFS

`fusion_auth` 的 Android AAR 和 iOS xcframework 里的 Mach-O 二进制走 Git LFS。贡献者和 CI 必须拉下 LFS 对象，否则这两个文件只是指针文本，原生构建会失败：

```bash
git lfs install
git lfs pull
```

本仓库 GitHub Actions 的 `actions/checkout` 设置了 `lfs: true`。头文件和资源包仍在普通 Git 里。

## 验证

```bash
(cd app_update && flutter analyze --fatal-infos && flutter test)
(cd auth_client && flutter analyze --fatal-infos && flutter test)
(cd fusion_auth && flutter analyze --fatal-infos && flutter test)
(cd auth_server && go vet ./... && go test -race ./...)
(cd release_tool && python -m unittest discover -v)
```

许可证：[MIT](LICENSE)。
