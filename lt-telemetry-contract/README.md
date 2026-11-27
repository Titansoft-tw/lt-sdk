# lt-telemetry-contract (#0)

The single source of truth for record bodies, `sdk_event` labels and reasons, error domains, setup stages and
attribute names (lt-observability `docs/ARCHITECTURE.md` §5). Not a runtime SDK: `generate.js` writes constants into
the reporting SDKs, and the SDK tests compare their own enums against them.

| Output | Used by |
|---|---|
| `lt-telemetry-android/src/main/java/com/tswork/lt/telemetry/Contract.kt` | #3 |
| `LtTelemetry-ios/Sources/LtTelemetry/Contract.swift` | #4 |
| `lt-telemetry-node/src/contract.js` | #5 |

```sh
node lt-telemetry-contract/generate.js          # regenerate after editing contract.json
node lt-telemetry-contract/generate.js --check  # CI: rules hold and outputs are up to date
node --test lt-telemetry-contract/generate.test.js   # generator tests
```

Rules checked on every run:

- No attribute name matches `collectorDeletedKeyPattern` (the Collector deletes it), except entries in
  `knownViolations` (`trace_ip` today, plan §9 Q4).
- No attribute name matches `secretPattern` (the encoders drop it).
- No attribute is `reserved` (filled in by the platform: `exit_carrier`, `deployment.environment`).
- Every setup stage is a `call_setup` reason.

Changing a name is a cross-repo change: MV, dashboards, `send-sample.sh`, `lt_zh()` and the docs in lt-observability
change with it. Not here yet (plan §4): attribute types / nullability / `consumer`, the `lt_zh()` check and generating
the ARCHITECTURE.md table.
