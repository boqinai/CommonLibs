## 0.3.0

- Move the Android `fusionauth-1.2.16.aar` and the iOS `AlicomFusionAuth` Mach-O binaries (device and simulator) to Git LFS. Contributors and CI need `git lfs install` and `git lfs pull`; `actions/checkout` uses `lfs: true`. Headers and resource bundles stay in regular Git.
- Document the plugin release (`0.3.0` / tag `fusion_auth-v0.3.0`) separately from the vendored SDK labels: Android Maven coordinate and AAR filename **1.2.16**, AAR manifest `android:versionName` **1.2.8**, iOS drop labeled **1.2.15** while `CFBundleShortVersionString` inside the framework is **1.2.14**.
- Minimums unchanged: iOS 15.0, Android `minSdk` 24 (the AAR manifest's minSdk 21 is not adopted).
- Align the podspec version with the Flutter package version.

## 0.2.0

- Ask Dart for a refreshed 鉴权Token via `onTokenUpdate` when the SDK calls `onSDKTokenUpdate`; falls back to the `start` token (document ~3600s limit) if unanswered.
- Remove `RECEIVE_USER_PRESENT`, `CHANGE_WIFI_STATE`, and `CHANGE_NETWORK_STATE` from the merged manifest (`ACCESS_WIFI_STATE` kept for carrier detection).
- Soften file-Maven `allprojects` injection: catch failures and document `FAIL_ON_PROJECT_REPOS` / settings.gradle setup.
- Clarify SDK package version vs AAR `versionName` in the README.
- Include the package in CI (analyze + test).

## 0.1.0

- Initial release, extracted from Penny's `penny_fusion_auth`: Aliyun 融合认证 bridge (`FusionAuth.start` / `finish` / `cancel`) on channel `boqinai/fusion_auth`.
- Bundles Android fusionauth 1.2.16 (file Maven repo, auto-registered on the host build) and iOS AlicomFusionAuth.xcframework 1.2.15 (min iOS 15). No Umeng.
