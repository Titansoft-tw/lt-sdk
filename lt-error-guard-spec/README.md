# lt-error-guard-spec (#6)

The error guard decides which **handled** error events reach the crash reporter, so that a few devices with a
broken external dependency (no Google Play services, a blocked host, a retry loop) cannot flood Sentry. Crashes
(unhandled, or level fatal) are always kept. Proposal: Obsidian `02 Tech Design & Proposals/Letstalk 錯誤雜訊防護 —
lt-error-guard SDK 提案.md`.

| File | What |
|---|---|
| `rules.schema.json` | The rules format (editor support; `validate.js` checks the same and also unique ids) |
| `default-rules.json` | Shipped defaults: network errors, FCM / GMS unavailable, third-party-only stacks are deduplicated; 30 handled events per session |
| `vectors/decisions.json` | Event sequences with the expected decision; run by the Android and iOS tests |
| `vectors/invalid.json` | Rules every implementation rejects |
| `validate.js` | `node validate.js rules.json` before shipping a customer's rules |
| `generate.js` | Copies `default-rules.json` into `DefaultRules.kt` / `DefaultRules.swift`; `--check` also checks the vectors and that default domains are contract error domains |

## How a decision is made

1. The app's own beforeSend runs first; what it drops is not counted.
2. Crash (unhandled or level fatal) → keep, not counted against the budget.
3. The first rule whose `match` holds decides: `keep`, `drop`, `sample` (kept when the draw < `rate`) or `dedupe` (the
   first event per fingerprint and session is kept). No rule → keep.
4. A kept event beyond `sessionBudget.maxEvents` is dropped as rule `budget` (domain `telemetry`, code `error_budget_exceeded`).
5. Each suppression is tallied per (rule, domain, code): the sink gets the first one (count 1) at once and
   `endSession()` returns the totals above 1, the same scheme as `AppErrorTally` / `fact_app_error` (take max).

`match` conditions are ANDed: `exceptionType` (globs on any exception's `module.type`, case-sensitive), `message`
(globs on the message or any exception value, case-insensitive), `inApp` (`false` = has frames, none of them the
app's), `level`, `tags` (every listed tag present and matching). Globs know only `*` and `?`.

Changing a rule's meaning means changing both SDKs and adding a vector; `./gradlew test` and `swift test` run them.
