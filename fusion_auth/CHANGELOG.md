## 0.3.6

- Bound initial SDK token authentication to 15 seconds on Android and iOS (`sdk_auth_timeout`); cancel the deadline after authentication and teardown.
- Capture scene SDK/template per request and guard queued cleanup against newer generations.
- Android bridge logs are generic and debug-only.
- Document callback threads: release/start_failed deliver on the main-thread caller, resolve on the SDK thread. `launch` returns `busy` instead of throwing if the start gate cannot be armed.
- Document `sdk_auth_timeout` and other result codes with generic host handling.
- Replace source-grep assertions with executable watchdog/controller tests; native CI compiles the shared wrapper through carrier_auth/example.

## 0.3.5

- Android waits for `onSDKTokenAuthSuccess` before posting `startSceneWithTemplateId` to the main thread. Duplicate token-auth success callbacks queue the scene only once, and cancellation before the posted action prevents a stale page from opening.
- Register the SDK callback only after `initWithToken` creates the underlying auth proxy. Token-auth failures keep exposing the SDK's original code and message.
- Add stage-only Android logs without tokens, phone numbers, or verification payloads to diagnose SDK initialization and scene startup.

## 0.3.4

- Android serializes `release` against SDK initialization while concurrent `launch` calls still return `busy` immediately. Activity/engine detachment can no longer advance the session generation between gate setup and SDK start, leaving the pending Flutter result unresolved.
- `launch` and `release` run on the main thread. `FusionAuthPlugin` asserts `Looper.myLooper() == Looper.getMainLooper()`. Result callbacks run after the lifecycle lock is released. `startSdk` and `destroySdk` stay inside that lock so `release` still waits for initialization.
- A `launch` from the `start_failed` callback, before the failing `launch` returns, returns `busy`. The atomic launch claim is held across that callback, so the retry does not reset the gate or start a second session. Retry after `launch` returns.

## 0.3.3

- Android `FusionSceneController.launch` claims launch ownership with an atomic that is independent of the pending callback and the start gate. A concurrent launch returns `busy` and does not reset the gate, tear down the SDK, or start a second session.

## 0.3.2

- iOS SDK callbacks carry a generation counter, matching Android. A callback from a previous request, including one that resumes after `dispatch_async`, cannot update the token, continue the scene, or resolve `start`. SDK init that throws still completes the pending `start` once, as `start_failed`.

## 0.3.1

- SDK init failures complete the pending `start` once, with `start_failed`. `release` takes the terminal code and message; a later `cancelled` cannot replace a result that was already delivered. Same ordering on Android (`FusionStartGate`) and iOS (`FusionStartGate`).

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
