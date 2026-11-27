# lt-sdk

Telemetry SDKs for Let's Talk: device info and OTLP/HTTP log reporting for Android (Kotlin), iOS (Swift) and the
Node.js relay, with a shared telemetry contract. Interface plan: `otel-sdk-interface-plan.md` (v4) next to this repo.

| # | Folder | What | Platform |
|---|---|---|---|
| 0 | `lt-telemetry-contract/` | `contract.json` + generator for the Kotlin / Swift / JS constants | Node script |
| 1 | `lt-device-info-android/` | Device, network, audio route and power readers | Android library |
| 2 | `LtDeviceInfo-ios/` | Same, iOS | Swift package target |
| 3 | `lt-telemetry-android/` | OTLP log encoding, queue, retry, durable queue | Android library |
| 4 | `LtTelemetry-ios/` | Same, iOS | Swift package target |
| 5 | `lt-telemetry-node/` | Server-side observability for a voice backend (lt-voice-relay, the Let's Talk backend): call events, disk queue, retry, remote config; zero dependencies | Node.js (CommonJS) |
| 6 | `lt-error-guard-spec/` | Error guard rules: schema, defaults, shared test vectors, `validate.js` | Node script |
| 7 | `lt-error-guard-android/` | Error guard: which handled errors reach the crash reporter (dedupe, sample, budget) | Android library |
| 8 | `lt-error-guard-sentry-android/` | #7 in Sentry's beforeSend (the app brings Sentry 8.x) | Android library |
| 9 | `LtErrorGuard-ios/` | Same as #7, iOS | Swift package target |
| 10 | `LtErrorGuardSentry-ios/` | Same as #8, iOS (sentry-cocoa 8.x–9.x) | Swift package target |

Dependencies: #3 → #1, #4 → #2, #8 → #7, #10 → #9. #1, #2, #7 and #9 work on their own; the guard does not need
the telemetry SDKs (an app can wire its sink to them, see `lt-error-guard-android/README.md`).

## Using the SDKs

**iOS (SPM)**: add one package, `https://github.com/Titansoft-tw/lt-sdk.git`, then pick the `LtDeviceInfo` and/or
`LtTelemetry` products (`LtErrorGuard` / `LtErrorGuardSentry` for the error guard; the package depends on sentry-cocoa
for the latter, which SPM resolves but only builds when you pick that product). The root `Package.swift` points each target into its folder with `path:`.

**Android (JitPack)**: tag a release, then

```kotlin
// settings.gradle.kts
dependencyResolutionManagement { repositories { maven("https://jitpack.io") } }
// app/build.gradle.kts
implementation("com.github.Titansoft-tw.lt-sdk:lt-telemetry-android:<tag>")   // brings lt-device-info-android
implementation("com.github.Titansoft-tw.lt-sdk:lt-device-info-android:<tag>") // device info only
implementation("com.github.Titansoft-tw.lt-sdk:lt-error-guard-sentry-android:<tag>") // brings lt-error-guard-android
```

`jitpack.yml` pins JDK 17; JitPack builds every module listed in `settings.gradle.kts`.

**Node (relay)**: npm git dependencies cannot point at a subfolder, so during relay validation add this repo as a
git submodule and depend on the folder:

```json
"@lt/telemetry-node": "file:./lt-sdk/lt-telemetry-node"
```

It has no dependencies. Publish to npm later.

## Checks

```sh
export JAVA_HOME="$(/usr/libexec/java_home -v 17)"
./gradlew test                     # Android unit tests
swift test                         # iOS targets (macOS host)
node --test lt-telemetry-node/test/*.js   # server SDK (Node 22 does not take a directory)
node lt-telemetry-contract/generate.js --check   # generated constants are up to date
node --test lt-error-guard-spec/*.test.js       # rules validator, signing and spec consistency
node lt-error-guard-spec/generate.js --check     # default rules copied into the guard SDKs are up to date
```
