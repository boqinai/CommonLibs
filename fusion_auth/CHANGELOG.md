## 0.2.0

- Ask Dart for a refreshed 鉴权Token via `onTokenUpdate` when the SDK calls `onSDKTokenUpdate`; falls back to the `start` token (document ~3600s limit) if unanswered.
- Remove `RECEIVE_USER_PRESENT`, `CHANGE_WIFI_STATE`, and `CHANGE_NETWORK_STATE` from the merged manifest (`ACCESS_WIFI_STATE` kept for carrier detection).
- Soften file-Maven `allprojects` injection: catch failures and document `FAIL_ON_PROJECT_REPOS` / settings.gradle setup.
- Clarify SDK package version vs AAR `versionName` in the README.
- Include the package in CI (analyze + test).

## 0.1.0

- Initial release, extracted from Penny's `penny_fusion_auth`: Aliyun 融合认证 bridge (`FusionAuth.start` / `finish` / `cancel`) on channel `boqinai/fusion_auth`.
- Bundles Android fusionauth 1.2.16 (file Maven repo, auto-registered on the host build) and iOS AlicomFusionAuth.xcframework 1.2.15 (min iOS 15). No Umeng.
