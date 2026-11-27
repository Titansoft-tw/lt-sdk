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

Dependencies: #3 → #1, #4 → #2. #1 and #2 work on their own.

## Using the SDKs

**iOS (SPM)**: add one package, `https://github.com/Titansoft-tw/lt-sdk.git`, then pick the `LtDeviceInfo` and/or
`LtTelemetry` products. The root `Package.swift` points each target into its folder with `path:`.

**Android (JitPack)**: tag a release, then

```kotlin
// settings.gradle.kts
dependencyResolutionManagement { repositories { maven("https://jitpack.io") } }
// app/build.gradle.kts
implementation("com.github.Titansoft-tw.lt-sdk:lt-telemetry-android:<tag>")   // brings lt-device-info-android
implementation("com.github.Titansoft-tw.lt-sdk:lt-device-info-android:<tag>") // device info only
```

`jitpack.yml` pins JDK 17; JitPack builds both modules listed in `settings.gradle.kts`.

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
```
