# release_tool

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
