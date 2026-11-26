# LtDeviceInfo (#2, iOS)

Reads device, network, audio route and power state on iOS. Sends nothing and does not depend on telemetry. SPM
product `LtDeviceInfo` from the repo root `Package.swift`; iOS 17.

```swift
let info = IOSDeviceInfo(exitCountryLookup: { try? await relay.whoami() }, ownCallUUID: { IncomingCalls.shared.callUUID })
info.onAudioSession = { event in /* .interruption / .routeChanged / .mediaServicesReset */ }
info.staticDevice; info.network(); info.audioRoute(); info.deviceState(); info.deviceSnapshot()
info.isForeground(); info.processUptimeMs()
let metrics = MetricKitSource(onDiagnostics: { … }, onExits: { … })   // keep it alive
```

Pure parts (`DeviceInfo.deviceModel` / `audioRoute(port:name:)` / `cellularRadio`, `OsNetType`, `VpnState`, `Thermal`,
`AppLaunchTracker`, `AudioInterruption`) build on macOS too, so `swift test` runs them on the Mac. `IOSDeviceInfo`
and `MetricKitSource` are iOS only.

Extracted from lt-call-demo `LtCallDemo/IOSCallEnvironment.swift`, `LtCallDemo/MetricKitReporter.swift` and the
platform readers in `LtCallCore` (`AppTelemetry.swift`, `CallSetup.swift`, `PushTelemetry.swift`, `Telemetry.swift`).
Not yet (plan §5.2): network / screen observers.
