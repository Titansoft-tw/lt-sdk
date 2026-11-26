# @lt/telemetry-node (#5)

Relay-side OTLP/HTTP JSON log reporting for lt-observability. CommonJS, zero dependencies, Node 20+ (global `fetch`).

```js
const { createTelemetry } = require('@lt/telemetry-node');
const t = createTelemetry({
  url: cfg.telemetryUrl && `${cfg.telemetryUrl}/v1/logs`, // full URL; empty = every method is a no-op, enabled = false
  token: cfg.telemetryToken,                               // the Collector's OTLP_TOKEN
  serviceName: 'lt-voice-relay',                           // required when on
  log: (tag, msg) => {},                                   // only on reachable <-> unreachable changes, never the URL
});
t.milestone({ room, user, type, callId, reason, engine, setupId }); // sdk_event label=signaling
t.setup({ room, user, event, stage, callId, engine, detail, setupId }); // label=call_setup, relay stages only
t.event(attributes, atMs);                               // NCS, as built
t.summary(sanitizedReport);                              // call_summary
t.error({ domain, code, severity, stage, callId, room, user, engine, fatal, count, detail, setupId }); // app_error
await t.close();
```

Optional: `flushMs` (1000), `maxQueue` (1000, oldest dropped), `maxBatch` (200), `timeoutMs` (5000), `fetch`.

Extracted from lt-voice-relay `origin/main` (0482efe) `src/telemetry.js`. The only change is the factory: the
relay's `createTelemetry(cfg, log, send)` built `{TELEMETRY_URL}/v1/logs` itself and wrote `service.name` as
`lt-voice-relay`; now the caller passes the full URL and the service name (plan §7). Relay stages and severities come
from `src/contract.js` (generated). Not yet: retry once on 0 / 429 / 5xx (plan §9 Q5).

```sh
node --test lt-telemetry-node
```
