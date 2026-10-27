# fusion_auth

阿里云号码认证·融合认证（本机号码一键登录）Flutter 插件，支持 Android 与 iOS。SDK 已内置：Android fusionauth 1.2.16（插件自带文件 Maven 仓库，并自动注册到宿主工程，无需修改宿主 gradle），iOS AlicomFusionAuth.xcframework 1.2.15（最低 iOS 15.0）及其资源包。不集成友盟（SDK 运行时探测，缺失时跳过）；插件 Manifest 移除了 `READ_PHONE_STATE` 与 `AD_ID` 权限。

```yaml
dependencies:
  fusion_auth:
    git:
      url: https://github.com/boqinai/CommonLibs.git
      ref: fusion_auth-v0.1.0
      path: fusion_auth
```

## 流程

1. 服务端调用 `GetFusionAuthToken` 下发鉴权 Token（auth_server ≥ 0.9.0：`aliyun.Client` + `PhoneRoutes.FusionToken`；auth_client：`fusionAuthToken(platform)`）。
2. App 调用 `FusionAuth.start(token:, schemeCode:, templateId:)`，SDK 拉起认证页，返回 `FusionVerifyResult`。
3. `result.ok` 时把 `verifyToken` 交给服务端 `VerifyWithFusionAuthToken` 换取手机号并登录（auth_client：`loginWithFusionToken`）。
4. 按服务端结果调用 `FusionAuth.finish(success)` 关闭 SDK 页面；用户取消或失败时回退到短信验证码登录。`FusionAuth.cancel()` 释放 SDK。

```dart
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
