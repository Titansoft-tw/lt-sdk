'use strict';
/* Server-side telemetry for lt-observability: OTLP/HTTP JSON log records posted to an
 * OpenTelemetry Collector (POST to the full logs URL, e.g. https://otel.example/v1/logs). The apps send the per-second media
 * quality themselves; this adds the two things only the backend sees or collects:
 *
 *   sdk_event     one per signaling milestone (ring, ringing, accept, restart-request, hangup),
 *                 label=signaling; one per call-setup stage the relay sees (dial, ringing, accept,
 *                 push_sent, push_failed), label=call_setup; one per Agora NCS event, label=agora_server
 *   call_summary  one per POST /v1/report, i.e. per leg of a finished call
 *   app_error     one per relay-side failure (push not delivered, token not issued), source=relay,
 *                 same attributes as the apps' app_error; its severity (WARN/ERROR) is the OTLP
 *                 severityText. Every other record stays INFO.
 *
 * The record body is the message type and every value is a string attribute, the same contract
 * the apps use (lt-observability docs/ARCHITECTURE.md). Nothing here can block or fail a call:
 * records are queued, sent in the background and dropped when the collector is unreachable.
 *
 * Extracted from lt-voice-relay src/telemetry.js (origin/main 0482efe); createTelemetry takes one options object. */

const contract = require('./contract');

const DEFAULTS = { flushMs: 1000, maxQueue: 1000, maxBatch: 200, timeoutMs: 5000 };
const STATS = { rttMs: 'rtt_ms', lossPct: 'loss_pct', jitterMs: 'jitter_ms', concealPct: 'conceal_pct', mos: 'mos', receiveKbps: 'receive_kbps' };
const FIELDS = {
  line: 'line', role: 'role', failed: 'failed', reason: 'reason', reconnects: 'reconnects', samples: 'samples',
  candidateType: 'candidate_type', protocol: 'transport', relayProtocol: 'relay_protocol', codec: 'codec',
  device: 'device', os: 'os', app: 'app_version',
  durationMs: 'duration_ms', connectMs: 'connect_ms', ringMs: 'ring_ms', talkMs: 'talk_ms',
  firstAudioMs: 'first_audio_ms', reconnectMs: 'reconnect_ms',
  region: 'server_region', caseId: 'case_id', runId: 'test_run_id', testRole: 'test_role', testGroup: 'test_group',
  errorDomain: 'error_domain', errorCode: 'error_code',
};

/** The platform stores leg ids as UInt32, so "001234" is sent as "1234" (as the apps do). */
const uid = id => (/^\d{1,15}$/.test(id) ? String(Number(id)) : id);

/** A signaling milestone as an sdk_event, or null when it has no call id to hang it on. */
function milestoneRecord({ room, user, type, callId, reason, engine = 'webrtc', setupId }, at = Date.now()) {
  if (!callId) return null;
  const attributes = {
    call_id: callId, channel: room, leg_uid: uid(user), engine, source: 'relay',
    label: 'signaling', event: type,
    reason: (type === 'hangup' ? `hangup_${reason || 'other'}` : type).replace(/-/g, '_'),
    relay_recv_ts: String(at),                 // relay clock; anchors cross-service durations
  };
  if (setupId) attributes.setup_id = setupId;  // correlation id for the whole dial attempt (when the app sends one)
  return { body: 'sdk_event', at, attributes };
}

/** Call-setup stages the relay itself sees (contract item 2), e.g. dial, ringing, accept, push_sent. */
const SETUP_STAGES = new Set(contract.setupStages.relay);

/** A call-setup stage as an sdk_event with label call_setup, or null without a call id or a known stage. */
function setupRecord({ room, user, event, stage, callId, engine = 'webrtc', detail = '', setupId }, at = Date.now()) {
  if (!callId || !SETUP_STAGES.has(stage)) return null;
  const a = {
    call_id: callId, channel: room, leg_uid: uid(user), engine, source: 'relay',
    label: 'call_setup', event: event || stage, reason: stage, relay_recv_ts: String(at),
  };
  if (detail) a.detail = detail;
  if (setupId) a.setup_id = setupId;
  return { body: 'sdk_event', at, attributes: a };
}

/** An already-built sdk_event (Agora NCS, see ncs.js). Attribute values are coerced to strings. */
function rawRecord(attributes, at = Date.now()) {
  const a = {};
  for (const [k, v] of Object.entries(attributes)) if (v !== undefined && v !== null) a[k] = String(v);
  // `at` is the event's own clock (e.g. Agora's for NCS), which we don't trust; stamp the relay's
  // receive time separately so the platform can anchor cross-service durations to the relay clock.
  if (a.relay_recv_ts === undefined) a.relay_recv_ts = String(Date.now());
  return { body: 'sdk_event', at, attributes: a };
}

const SEVERITIES = new Set(contract.severities.filter(s => s !== 'INFO'));

/**
 * A relay-side failure as an app_error (lt-observability docs/ARCHITECTURE.md §5「app_error」), or null
 * without a domain and code. Unlike sdk_event it needs no call id: call-less errors are counted one by one.
 * The relay never knows whether the call still connected, so `fatal` defaults to 0; the app reports that.
 */
function errorRecord({ domain, code, severity = 'ERROR', stage, callId, room, user, engine, fatal = false, count = 1, detail, setupId }, at = Date.now()) {
  if (!domain || !code) return null;
  const a = { error_domain: domain, error_code: code };
  if (stage) a.stage = stage;
  a.fatal = fatal ? '1' : '0';
  a.count = String(count);
  a.source = 'relay';
  if (callId) a.call_id = callId;
  if (room) a.channel = room;
  if (user) a.leg_uid = uid(user);
  if (engine) a.engine = engine;
  if (detail) a.detail = detail;
  a.relay_recv_ts = String(at);
  if (setupId) a.setup_id = setupId;
  return { body: 'app_error', at, severity: SEVERITIES.has(severity) ? severity : 'ERROR', attributes: a };
}

/** A sanitized report (see report.js) as a call_summary. Unmeasured values stay absent. */
function summaryRecord(report, at = Date.now()) {
  const a = {
    // Same rule as the apps: providers without a call id of their own use the room name.
    call_id: report.callId || report.room, channel: report.room, leg_uid: uid(report.user),
    engine: report.provider, source: 'relay',
  };
  if (report.peer) a.peer_uid = uid(report.peer);
  for (const [from, to] of Object.entries(FIELDS)) {
    const v = report[from];
    if (v !== undefined) a[to] = typeof v === 'boolean' ? (v ? '1' : '0') : String(v);
  }
  if (report.candidateType) a.relay = report.candidateType === 'relay' ? '1' : '0';
  for (const [from, to] of Object.entries(STATS)) {
    const s = report[from];
    if (!s) continue;
    for (const k of ['avg', 'min', 'max']) if (s[k] !== undefined) a[`${to}_${k}`] = String(s[k]);
  }
  a.relay_recv_ts = String(at);
  if (report.setupId) a.setup_id = report.setupId;
  return { body: 'call_summary', at, attributes: a };
}

function encode(records, serviceName) {
  const str = v => ({ stringValue: v });
  return {
    resourceLogs: [{
      resource: { attributes: [{ key: 'service.name', value: str(serviceName) }] },
      scopeLogs: [{
        logRecords: records.map(r => ({
          timeUnixNano: `${r.at}000000`, severityText: r.severity || 'INFO', body: str(r.body),
          attributes: Object.entries(r.attributes).map(([key, v]) => ({ key, value: str(v) })),
        })),
      }],
    }],
  };
}

/**
 * Options: `url` the full logs URL (empty = every method is a no-op and `enabled` is false), `token` the
 * Collector's OTLP_TOKEN (sent as a bearer token when set), `serviceName` (required), `flushMs`, `maxQueue`,
 * `maxBatch`, `timeoutMs`, `log(tag, message)` (only on reachable <-> unreachable changes, never the URL) and
 * `fetch` (injectable for tests).
 */
function createTelemetry({ url, token, serviceName, flushMs = DEFAULTS.flushMs, maxQueue = DEFAULTS.maxQueue, maxBatch = DEFAULTS.maxBatch,
  timeoutMs = DEFAULTS.timeoutMs, log = () => {}, fetch: send = globalThis.fetch } = {}) {
  const off = { enabled: false, milestone() {}, setup() {}, event() {}, summary() {}, error() {}, flush: async () => {}, close: async () => {} };
  if (!url) return off;
  if (!serviceName) throw new TypeError('createTelemetry: serviceName is required');
  const headers = { 'content-type': 'application/json' };
  if (token) headers.authorization = `Bearer ${token}`;
  let queue = [];
  let ok = null;
  let pending = Promise.resolve();

  async function post(batch) {
    let sent = false;
    try {
      const res = await send(url, {
        method: 'POST', headers,
        body: JSON.stringify(encode(batch, serviceName)), signal: AbortSignal.timeout(timeoutMs),
      });
      sent = res.ok;
    } catch (e) { /* unreachable collector: the batch is dropped */ }
    // Sent every second under load, so only a change of outcome is logged. Never log the URL.
    if (sent !== ok) { ok = sent; log('telemetry', sent ? 'collector reachable' : 'collector unreachable, records are being dropped'); }
  }
  function flush() {
    while (queue.length) {
      const batch = queue.splice(0, maxBatch);
      pending = pending.then(() => post(batch));
    }
    return pending;
  }
  function push(record) {
    if (!record) return;
    if (queue.length >= maxQueue) queue.shift();
    queue.push(record);
  }
  const timer = setInterval(flush, flushMs);
  timer.unref();
  return {
    enabled: true,
    milestone: m => push(milestoneRecord(m)),
    setup: m => push(setupRecord(m)),
    event: (attributes, at) => push(rawRecord(attributes, at)),
    summary: report => push(summaryRecord(report)),
    error: e => push(errorRecord(e)),
    flush,
    close() { clearInterval(timer); return flush(); },
  };
}

module.exports = { createTelemetry, milestoneRecord, setupRecord, rawRecord, summaryRecord, errorRecord, encode };
