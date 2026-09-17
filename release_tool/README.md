# release_tool

发布前会先验证全部 Publisher 的依赖与配置，避免某个目标尚未就绪时提前发布到其他目标。更新中心请求携带基于应用、版本和渠道生成的 `Idempotency-Key`，服务端可据此安全处理重复执行。

统一构建和发布 Flutter Android APK，无第三方 Python 依赖。

```bash
# 构建 arm64 APK、创建/更新 GitHub Release，并在配置 Token 时上传更新中心
python release_tool/release.py --project G:/New_Workspace/ChessGame \
  --repo boiqin/RedBlackChess --publish

# 上传已有 APK 到更新中心
python release_tool/release.py app.apk --project . --app-name 钱在哪 --publish
```

环境变量：

- `UPDATE_CENTER_TOKEN`：更新中心 Bearer Token。
- `UPDATE_CENTER_URL`：默认 `https://api.boqinai.com/updatecenter`。

可选参数包括 `--channel`、`--notes`、`--force`、`--rollout`、`--min-version` 和 `--no-update-center`。

发布标识保留 Flutter 完整版本（例如 `1.2.3+1002003`），避免仅增加 build number 时覆盖已有 Release。远程更新中心必须使用 HTTPS；HTTP 仅允许本机测试地址。
