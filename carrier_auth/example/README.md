# carrier_auth example

This host declares only carrier_auth. fusion_auth is a transitive vendor dependency;
the local override lets CI compile the current checkout without private Git fetches.
No SDK key is stored here and CI never invokes authorization or GetMobile.

```sh
flutter pub get
flutter test
flutter build apk --debug
# macOS only:
flutter build ios --simulator --debug
```

For a device run, provide your app-bound SDK key and actual HTTPS policy URLs using
`--dart-define=CARRIER_SDK_KEY=...`, `CARRIER_TERMS_URL`, `CARRIER_PRIVACY_URL`.
The key must match this example's package/bundle ID and signing certificate.
The demo never logs or displays the returned token and has no account backend.
