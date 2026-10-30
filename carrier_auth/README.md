# carrier_auth

独立阿里云号码认证 Flutter 插件，Android 24+、iOS 15+。SDK 展示当前数据卡的真实脱敏号码及运营商协议，用户明确授权后返回一次性 token。插件不包含账号、短信发送、HTTP 后端、GetX、路由或产品政策。

## 使用

```dart
import 'package:carrier_auth/carrier_auth.dart';

const carrier = CarrierAuthClient();
final result = await carrier.authorize(CarrierOptions(
  sdkKey: sdkKeyFromYourConfiguration,
  agreements: const [
    CarrierAgreement(title: '用户协议', url: 'https://example.test/terms'),
    CarrierAgreement(title: '隐私政策', url: 'https://example.test/privacy'),
  ],
  // 从宿主设计系统传入配色、字号、圆角；不依赖某个 App 的 Token。
  appearance: const CarrierAppearance(primaryColor: 0xFF2563EB),
));
if (result.accepted) {
  // 只将 result.token 交给自己的服务端，用 GetMobile 换手机号再完成账号登录。
} else if (result.requestsSms) {
  // 宿主打开自己的验证码登录页；插件不会自动发短信。
}
```

SDK 密钥必须与平台、包名/Bundle ID、签名一致；它不是服务端 AccessKey。协议必须是 HTTPS；支持 1–3 份宿主协议，运营商协议始终保留且不预勾选。`CarrierOptions` 可设置标题、登录/短信按钮文案、配色、字体、圆角、SDK 超时和授权页停留时限。不同平台保留各自 SDK 的授权页布局约束。

`CarrierResult` 只有 `code=600000` 且 token 非空才是 `accepted`；取消、请求短信、忙碌、失败不会携带 token。错误不返回供应商原始 payload。全局并发守卫防止不同 client 实例重复打开授权页，超时和生命周期结束会关闭 SDK 页。`cancel()` 可主动关闭；同一引擎仅允许一个授权请求。

## Android

Flutter 自动注册插件，宿主不再在 MainActivity 注册 Channel 或手工声明 fusion_auth。Dart transitive dependency 会注册 fusion_auth 工程，其 implementation 是唯一 SDK 运行时来源；carrier_auth 对同一 AAR 使用 compileOnly，仅用于编译公开 API。旧的同坐标重复声明也会被 Gradle 去重，并不是两份不同 AAR。Manifest 声明网络访问、网络状态、Wi-Fi 状态、网络切换四项普通权限；无需电话状态、广告标识或 Wi-Fi 修改权限。宿主 Application 主题需继承 AppCompat（SDK 使用 AppCompat Activity）。支持 AGP 9 内置 Kotlin。

## iOS

Flutter 自动注册 `CarrierAuthPlugin`，不在 AppDelegate 手工注册；依赖 UIKit 和已固定的供应商 framework。通过其已包含的公开 `TXCommonHandler` / `TXCustomModel` API 授权，不启动融合代理。仍需 macOS/Xcode 构建与 iPhone 真机验证；Dart 测试不等于 iOS 原生验证。

## SDK 二进制与版本

0.1.0 尚未发布。当前依赖固定的 `fusion_auth-v0.3.5` 作为供应商二进制载体（号码认证 SDK 2.14.21），不调用其融合入口，不执行融合模板或图形验证码。这样不复制受 Git LFS 管理的大二进制，也不在同一个 App 重复链接 SDK；以后替换成独立 vendor 包时需一次性移除旧载体。开发环境需要 Git LFS 和 CommonLibs 仓库读取权限。

CommonLibs 打版本 Tag 后以 `carrier_auth-vX.Y.Z` 固定引用；不打 Tag 时也可将 Flutter Git 依赖固定到已推送的完整提交 SHA。服务端 `aliyun.Client.GetMobile` / `CarrierVerifier` 是 auth_server 的独立变更，Go 可引用该提交解析出的伪版本。本地联调也可用同级路径；不要引用不存在的远程 Tag。

双卡使用默认数据卡。网络/运营商预取号失败由宿主给出提示，插件不会关闭 Wi-Fi、改 APN、切数据卡、绕过授权或自动降级发短信。

## 验证

```sh
flutter pub get
flutter analyze --fatal-infos
flutter test
```

独立宿主在 `example/`，只直接声明 carrier_auth；CI 分别在 Linux 编译 Android APK、在 macOS 编译 iOS Simulator。配置变化时只暂时解绑 Activity，保留授权请求；永久分离和超时才关闭。Android 稳定状态日志及失败诊断仅在 debuggable 宿主输出。测试覆盖配置注入、成功/取消/切换短信、并发、超时、无效 token 和错误脱敏。桥接代码为 MIT；阿里云 SDK 适用其供应商条款。
