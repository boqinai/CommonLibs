# fusion_auth

阿里云号码认证·融合认证（本机号码一键登录）Flutter 插件，支持 Android 与 iOS。

## 版本

插件发布版本和阿里云 SDK 的版本不是同一个数。

| 名称 | 版本 |
| --- | --- |
| Flutter 包 / Tag | **0.3.5**（`fusion_auth-v0.3.5`，`pubspec.yaml` 的 `version`） |
| Android 发布标签 | Maven `com.alicom.fusion:fusionauth:1.2.16`，文件 `fusionauth-1.2.16.aar` |
| AAR 内部 `android:versionName` | **1.2.8**（清单里的旧构建号；判断 SDK 时以文件名和 Maven 坐标 1.2.16 为准） |
| iOS 发布标签 | AlicomFusionAuth.xcframework **1.2.15** |
| iOS 框架内 `CFBundleShortVersionString` | **1.2.14**（二进制 Info.plist 比发布标签更旧，同样以 1.2.15 这个投放版本为准） |
| 插件最低系统 | iOS **15.0**（podspec），Android **minSdk 24** |

AAR 清单自己的 `minSdkVersion` 是 21。插件不把它降到 24 以下。不集成友盟（SDK 运行时探测，缺失时跳过）。

## Git LFS

Android AAR 和 iOS xcframework 里的两份 Mach-O（真机 `ios-arm64`、模拟器 `ios-arm64_x86_64-simulator`）用 Git LFS 存放。头文件、podspec、资源包仍是普通 Git 文件。

克隆仓库的人和 CI 都要取出 LFS 对象，否则这三个文件只是指针，Android / iOS 构建会失败：

```bash
git lfs install
git lfs pull
```

GitHub Actions 必须在 `actions/checkout` 上设置 `lfs: true`（本仓库 `.github/workflows/ci.yml` 已设置，并在 `fusion_auth` job 里检查文件不是 LFS 指针）。没有 LFS 的环境可以跑 Dart 单元测试，但不能链接原生 SDK。

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
      ref: fusion_auth-v0.3.5
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

## Android 线程

`FusionSceneController.launch` 和 `release` 在主线程调用。`FusionAuthPlugin` 用 `Looper.myLooper() == Looper.getMainLooper()` 断言，不在主线程时抛出 `IllegalStateException`。

回调线程取决于完成路径：`start_failed` 的初始化异常回调和 `release` 回调，在主线程调用方释放生命周期锁后执行；`resolve` 则在调用它的线程（通常是 SDK 线程）直接执行，甚至可能发生在 SDK 初始化尚未返回时。不能把 `onResult` 当作主线程回调，也不能在其中等待初始化线程。当前 `FusionAuthPlugin.succeed` 会把 MethodChannel 结果投递回主线程；后续重构必须保留这一边界。

`startSdk` 和 `destroySdk` 仍在锁内，因此并发的 `release` 会等 SDK 初始化结束，再推进 session generation 并销毁 SDK。SDK 的 `resolve` 使用本次请求独立的 gate/callback，不等待初始化锁。`gate.arm()` 若意外未成功，`launch` 返回 `busy` 而非抛异常，由插件向 Flutter 返回明确的忙碌错误。

初始化失败时，`launch` 的原子占用要到这次 `launch` 返回才放开。在 `start_failed` 回调里立刻再调用 `launch` 会得到 `busy`：这次重试不会清掉 gate，也不会启动第二次会话。等外层 `launch` 返回后再重试。

## 错误码与宿主处理

| 类型 | code | 含义与建议 |
|---|---|---|
| `FusionVerifyResult` | `sdk_auth_timeout` | 初始 SDK token 鉴权在 15 秒内未完成；本次请求已结束并清理 SDK，提示登录超时，允许重试或手动选择短信。不会表示用户在授权页停留太久。 |
| `FusionVerifyResult` | `start_failed` | 初始化或场景启动失败，提示该方式暂不可用，允许改用短信。 |
| `FusionVerifyResult` | `cancelled` | 调用方或用户结束了本次请求，不应当成登录成功。 |
| `PlatformException` | `busy` | 已有请求或启动占用（含 arm 失败兜底）；不关闭其他请求、不再打开一页。 |
| `PlatformException` | `bad_args` / `no_activity` | 缺少参数或没有前台宿主，修正配置或等待页面就绪。 |
| SDK 结果 | 供应商 code | 只有非空 verifyToken 才继续服务端校验；按供应商 code 映射友好提示，不直接展示原始 message。 |

`result.ok == false` 时，宿主应先处理取消、超时和失败，不能仅忽略结果。Penny 已使用独立号码认证入口（常规超时码 `600015`），其适配层也兼容 `sdk_auth_timeout` 并显示相同的超时提示，不会重新启用融合流程。

## 发布联动检查

以后获得授权发布 `fusion_auth-v0.3.6` 时，同时更新 `fusion_auth/pubspec.yaml`、iOS podspec，以及 `carrier_auth/pubspec.yaml` 的 Git ref 和 `carrier_auth/ios/carrier_auth.podspec` 的原生版本约束，再解析依赖并验证。旧 tag 不会自动包含这些改动；新 tag 创建前不把依赖改成不存在的版本。

版本一致性检查：`python tool/check_fusion_versions.py`。本轮不创建 tag，也不提前改写当前 0.3.5 的依赖。

## 验证

```bash
flutter analyze --fatal-infos && flutter test
```

## 当前源码中的待发布修正

初始 SDK token 鉴权最多等待 15 秒，超时返回 `sdk_auth_timeout` 并清理 SDK 以允许重试；鉴权成功后取消此看门狗，不限制用户阅读授权页的时间。取消与失败也清理计时器，旧代际的迟到回调不得打开或关闭新场景。Android 仅在 debuggable 宿主输出 `FusionAuth` 桥接日志。

JVM 行为测试使用注入时钟验证 deadline、取消、重试和迟到回调，不依靠 grep 源码。`carrier_auth/example` 覆盖当前 checkout 的原生编译，iOS 编译由 macOS CI 执行。以上是未发布源码变更，不代表旧 `fusion_auth-v0.3.5` tag 已包含修复。
