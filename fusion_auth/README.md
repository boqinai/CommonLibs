# fusion_auth

阿里云号码认证·融合认证（本机号码一键登录）Flutter 插件，支持 Android 与 iOS。

**SDK 版本说明：** Android 发布包 / Maven 坐标为 fusionauth **1.2.16**；AAR 内 `versionName` 仍可能显示更旧的构建号（例如 1.2.8），以文件名与坐标为准。iOS 为 AlicomFusionAuth.xcframework **1.2.15**（最低 iOS 15.0）及其资源包。不集成友盟（SDK 运行时探测，缺失时跳过）。

**权限：** 插件 Manifest 移除了 `READ_PHONE_STATE`、`AD_ID`、`RECEIVE_USER_PRESENT`、`CHANGE_WIFI_STATE`、`CHANGE_NETWORK_STATE`；保留 `ACCESS_WIFI_STATE`（运营商检测可能需要）。

**Maven 仓库：** 插件自带文件 Maven 仓库，并在常规 Flutter 工程里通过 `allprojects` 自动注册。若宿主启用了 `dependencyResolutionManagement` / `RepositoriesMode.FAIL_ON_PROJECT_REPOS`，请在 `settings.gradle(.kts)` 里手动加入：

```kotlin
dependencyResolutionManagement {
  repositories {
    maven { url = uri("<path-to-fusion_auth>/android/repo") }
  }
}
```

```yaml
dependencies:
  fusion_auth:
    git:
      url: https://github.com/boqinai/CommonLibs.git
      ref: fusion_auth-v0.2.0
      path: fusion_auth
```

## 流程

1. 服务端调用 `GetFusionAuthToken` 下发鉴权 Token（auth_server ≥ 0.9.0：`aliyun.Client` + `PhoneRoutes.FusionToken`；auth_client：`fusionAuthToken(platform)`）。
2. App 调用 `FusionAuth.start(token:, schemeCode:, templateId:)`，SDK 拉起认证页，返回 `FusionVerifyResult`。
3. `result.ok` 时把 `verifyToken` 交给服务端 `VerifyWithFusionAuthToken` 换取手机号并登录（auth_client：`loginWithFusionToken`）。
4. 按服务端结果调用 `FusionAuth.finish(success)` 关闭 SDK 页面；用户取消或失败时回退到短信验证码登录。`FusionAuth.cancel()` 释放 SDK。

鉴权 Token 有效期通常约 3600 秒。若场景可能更长，在 `start` 前设置 `FusionAuth.onTokenUpdate`，从服务端取新 Token 返回；未设置或不应答时继续使用 `start` 时的 Token。

```dart
FusionAuth.onTokenUpdate = () async {
  final payload = await auth.fusionAuthToken(Platform.isIOS ? 'ios' : 'android');
  return payload['token'] as String?;
};

if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
  final r = await FusionAuth.start(token: t, schemeCode: s, templateId: '100001');
  if (r.ok) {
    try {
      await auth.loginWithFusionToken(r.verifyToken!);
      await FusionAuth.finish(true);
    } catch (_) {
      await FusionAuth.finish(false);
      // 显示短信验证码表单
    }
  }
}
```

其他平台（Web、桌面）没有实现，调用方必须先判断平台。方案号（SchemeCode）、包名/签名、BundleId 与 AccessKey 均属于宿主应用配置，由服务端持有，插件不包含任何密钥。

## 验证

```bash
flutter analyze --fatal-infos && flutter test
```
