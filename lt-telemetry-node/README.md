# @lt/telemetry-node (#5)

Observability for a Let's Talk voice backend: call events in the lt-observability contract, posted as OTLP/HTTP JSON
logs to the OpenTelemetry Collector, with the same delivery guarantees as the Android and iOS SDKs. CommonJS, zero
dependencies, Node 20+ (global `fetch`). lt-voice-relay uses it as the reference integration.

## What it does for you

- **Records in the contract**: signaling milestones, call-setup stages, `app_error` and `call_summary`, with the
  attribute names, `call_id` / `leg_uid` rules and severities the dashboards expect (lt-observability
  `docs/ARCHITECTURE.md` §5). Values are strings; unmeasured values are left out, never zero.
- **Nothing lost on a crash or restart**: every record is written to a disk queue before it is sent; what a dead
  process left goes out when the next one starts. 5 MB / 7 days by default; when full, ordinary events go first,
  `app_error` and `call_summary` last.
- **Never blocks or fails a call**: methods return at once and never throw. Batches (up to 200 records, oldest first)
  go out about once a second in the background.
- **Retries politely**: no answer / 408 / 429 / 5xx keeps the batch and retries after 10 s doubling to 5 min (±20%), or
  after the Collector's `Retry-After` (capped at 1 h); any other 4xx (bad token, bad payload) drops that batch so it
  cannot block the rest.
- **De-duplication and late delivery**: every record gets a `log.record.uid` (kept across retries) and every batch an
  `observedTimeUnixNano`; lt-observability collapses duplicates and measures how late records arrived.
- **Losses are visible**: records dropped (queue full, too old, rejected, corrupt) are reported as
  `sdk_event label=telemetry reason=dropped` with `dropped_<reason>` counts once delivery works again.
- **Remote config**: the same `telemetry.json` the apps read (`<collector base>/config/telemetry.json`, ETag, cached on
  disk, re-fetched every 5 minutes) can switch reporting off (`enabled`), drop event labels (`drop_labels`), and tune
  retries and queue limits, without a deploy. Rules can target `"platform": "server"`, `app_version_*` (your
  `serviceVersion`) and `build`. Records sent under a remote config carry `config_version`.

## Install

The package is not on npm yet. Add lt-sdk as a git submodule and depend on the folder:

```sh
git submodule add git@github.com:Titansoft-tw/lt-sdk.git lt-sdk
npm install ./lt-sdk/lt-telemetry-node   # package.json: "@lt/telemetry-node": "file:lt-sdk/lt-telemetry-node"
```

In a Docker build, copy `lt-sdk/lt-telemetry-node` into the image before `npm ci` (see lt-voice-relay's `Dockerfile`),
and mount a volume at `queueDir` so undelivered records also survive re-creating the container.

## Use

```js
const { createTelemetry } = require('@lt/telemetry-node');

const telemetry = createTelemetry({
  url: process.env.TELEMETRY_URL,          // full logs URL, e.g. https://otel.example/v1/logs; empty = off (no-ops)
  token: process.env.TELEMETRY_TOKEN,      // the Collector's OTLP_TOKEN; also sent when fetching the remote config
  serviceName: 'letstalk-server',          // service.name; required when on
  serviceVersion: '3.2.0',                 // what the remote config's app_version rules match
  queueDir: '/var/lib/letstalk/telemetry', // default <tmp>/lt-telemetry/<serviceName>; 'memory' = no disk
  log: (tag, msg) => logger.info(tag, msg), // reachable <-> unreachable and config changes only; never the URL or token
});

// Signaling milestone (ring, ringing, accept, restart-request, hangup) → sdk_event label=signaling
telemetry.milestone({ room, user, type: 'hangup', callId, reason: 'no-answer', engine: 'webrtc', setupId });

// Call-setup stage the server sees (dial, ringing, accept, push_sent, push_failed) → sdk_event label=call_setup
telemetry.setup({ room, user, event: 'invite', stage: 'push_sent', callId, engine: 'agora', detail: 'fcm 200' });

// Server-side failure → app_error source=relay (severity WARN / ERROR / FATAL becomes severityText)
telemetry.error({ domain: 'push', code: 'fcm_404_UNREGISTERED', severity: 'WARN', stage: 'dial', callId, room, user });

// One per leg of a finished call → call_summary (camelCase in, snake_case out, stats flattened to rtt_ms_avg …)
telemetry.summary({ provider: 'agora', room, user, peer, callId, role: 'caller', durationMs, talkMs,
  rttMs: { avg: 42, min: 20, max: 90 }, mos: { avg: 4.2 } });

// Anything else, already in the contract (e.g. an Agora NCS event you mapped yourself)
telemetry.event({ call_id: callId, channel: room, label: 'agora_server', event: 'user_leave', reason: 'leave_quit' }, atMs);

// On shutdown: one last attempt; whatever is not delivered stays on disk for the next start.
await telemetry.close();
```

`source=relay` and `relay_recv_ts` (this server's clock) mark every record as coming from the backend; the dashboards
use them to tell server records from the apps' and to anchor cross-service durations. A milestone or setup stage
without a `callId` is skipped; `app_error` does not need one. `room` is the channel name, `user` the leg's numeric id
(leading zeros are dropped, as the apps do), `callId` the caller's per-call UUID.

Other options: `build` (`release`), `maxQueueBytes` / `maxQueueAgeMs`, `configUrl` (default derived from a `url` ending
in `/v1/logs`; `''` turns remote config off), `configRefreshMs` (5 min), `flushMs` (1000), `timeoutMs` (5000),
`retryMs` / `maxRetryMs`, and the test hooks `fetch`, `now`, `random`. Read-only: `telemetry.enabled`,
`telemetry.settings` (the remote config in effect; `version: null` for the defaults), `telemetry.queue`
(`isEmpty`, `bytes`, `onDisk`). `await telemetry.flush()` sends now (tests); `await telemetry.refreshConfig(ms)`
re-fetches the config unless the last fetch is younger than `ms`; `telemetry.record(r)` queues a record you built.

Run one instance per process and give each process its own `queueDir`: two processes must not share one.

## Privacy

Send no credentials, tokens or IP addresses: the builders only copy contract fields, and `detail` should be an error
code or a short status (`fcm 404 UNREGISTERED`), never exception text. The Collector masks IPs, emails and phone
numbers again (`transform/pii`).

## Files

| File | What |
|---|---|
| `src/index.js` | `createTelemetry`, record builders (`milestoneRecord`, `setupRecord`, `errorRecord`, `summaryRecord`, `rawRecord`, `droppedRecord`), `encode`, `backoffDelay`, `parseRetryAfter`, `deriveConfigUrl` |
| `src/store.js` | the disk queue (segments per lane, cap and age eviction, drop counts; memory fallback) |
| `src/remote-config.js` | `parseConfig` (schema 1: clamps, ordered rules, local rollout bucket), `compareVersions` |
| `src/contract.js` | generated by `lt-telemetry-contract/generate.js`; do not edit |

Extracted from lt-voice-relay `src/telemetry.js` (0482efe), then given the apps' delivery mechanism.

```sh
node --test lt-telemetry-node/test/*.js
```
