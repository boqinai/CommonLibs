## 0.9.0

- Validate the APK package name and signing-certificate lineage before marking a download complete or opening either installer entry point.
- Handle Android 15 dataSync foreground-service timeouts, persist the terminal failure, and surface it as a timed-out download to Dart.

## 0.8.2

- Show the Android foreground-service download notification immediately so short downloads are visible in the notification shade.

## 0.8.0

- Check existing local APK MD5, SHA-256 and size before downloading to avoid duplicate downloads.
- Add support for MD5 checksum validation in AppUpdateInfo and download pipeline.

## 0.7.0

- Verify APK SHA-256 integrity and file size before opening the installer.
- Guard against concurrent foreground download services and support typed UpdateFailure reporting.
- Add inactivity timeout alongside overall download timeout.

## 0.6.0

- Stream native download progress through EventChannel, with polling fallback for older plugin builds.
- Allow apps to configure a dedicated monochrome notification icon through manifest metadata.

## 0.5.0

- Add a reusable Material update dialog with release notes, forced-update handling, and a background-download action.
- Add custom update-check policies and harden native download task cleanup and lifecycle handling.

## 0.4.0

- Replace DownloadManager with a foreground download service and a single notification showing an explicit percentage.
- Request Android 13+ notification permission before starting an update download.
- Keep Wi-Fi-only downloads waiting in the foreground until Wi-Fi is available.
- Pass the declared data-sync type when starting the foreground service on Android 10+.
- Complete pending notification-permission calls when the Activity or Flutter engine detaches.
- Fall back to copying the completed APK when an atomic rename is unavailable.

## 0.3.0

- Require HTTPS for remote update endpoints and APK downloads.
- Cancel orphaned DownloadManager tasks and fix controller retry/dispose races.
- Support Flutter built-in Kotlin while retaining Flutter 3.41 compatibility.

## 0.2.0

- Add launch, daily, and weekly automatic-check scheduling.
- Add Wi-Fi-only DownloadManager constraints and a UI-independent download controller.
## 0.1.0

- Extract shared update-center protocol handling.
- Add Android DownloadManager download, progress, cancellation, and APK installation.
