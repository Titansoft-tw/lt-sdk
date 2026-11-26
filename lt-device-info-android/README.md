# lt-device-info-android (#1)

Reads device, network, audio route and power state. Sends nothing and does not depend on telemetry, so the Lab
environment check can use it alone. Package `com.tswork.lt.deviceinfo`, minSdk 26.

```kotlin
val info = AndroidDeviceInfo(context, exitCountryLookup = { relay.whoami() }) // lookup optional, runs off the main thread
info.staticDevice     // platform, os, app version, model, brand
info.network()        // net_type, net_type_os, carrier, country, vpn, exit_country, radio levels
info.audioRoute()     // speaker / earpiece / wired / bluetooth + accessory model + bt profile
info.deviceState()    // once a second: battery, power save, thermal, doze, mic silenced
info.deviceSnapshot() // once per call: adds permissions, battery optimisation, background limits, standby bucket
info.isForeground(); info.processUptimeMs(); info.exitReason(sinceEpochMs)
```

Unknown values are blank strings or null, never 0 or the system's placeholder text. The library manifest only adds
`ACCESS_NETWORK_STATE` and `ACCESS_WIFI_STATE` (normal permissions); `READ_PHONE_STATE` (cellular generation before
Android 12), `RECORD_AUDIO` and `POST_NOTIFICATIONS` stay the app's decision.

Extracted from lt-call-demo `CallEnvironment.kt` (`AndroidCallEnvironment`), `rtc/AppTelemetry.kt` (`DeviceState`,
`Thermal`, `ExitReasons`), `rtc/CallSetup.kt` (`OsNetType`), `rtc/PushTelemetry.kt` (`AppLaunchTracker`) and
`Telemetry.deviceModel`. Not yet (plan §5.2): observers (`observe` for network / route / screen), `normalizeCarrier`,
audio focus events.
