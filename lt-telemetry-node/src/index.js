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
 * the apps use (lt-observability docs/ARCHITECTURE.md). Nothing here can block or fail a call.
 *
 * Delivery is the apps' mechanism (lt-call-demo docs/telemetry-delivery-proposal.md): every record goes to a disk
 * queue first (store.js) with a log.record.uid, batches go out about once a second with observedTimeUnixNano,
 * no answer / 408 / 429 / 5xx keeps the batch and retries with backoff or after Retry-After, a crash or restart loses
 * nothing queued, drops are reported, and a remote config (remote-config.js) can switch it off or tune it.
 *
 * Extracted from lt-voice-relay src/telemetry.js (origin/main 0482efe); createTelemetry takes one options object. */

const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');
const contract = require('./contract');
const { createStore } = require('./store');
const { parseConfig, DEFAULT_SETTINGS } = require('./remote-config');

const DEFAULTS = {
  flushMs: 1000, timeoutMs: 5000, retryMs: 10_000, maxRetryMs: 5 * 60_000, configRefreshMs: 5 * 60_000,
};
const MAX_RETRY_AFTER_MS = 60 * 60_000;
const MAX_CONFIG_BYTES = 64 * 1024;
const CONFIG_PATH = '/config/telemetry.json';
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

/** base × 2^(failures−1), capped at max, then ±20% (unit: a random number from 0 up to 1); as lt-telemetry-android. */
function backoffDelay(failures, base, max, unit) {
  const raw = Math.min(base * 2 ** Math.min(Math.max(failures - 1, 0), 30), max);
  return Math.floor(raw * (0.8 + 0.4 * unit));
}

/** `Retry-After: <seconds>` or an HTTP date, in ms; null when absent or unreadable. */
function parseRetryAfter(value, nowMs = Date.now()) {
  const text = typeof value === 'string' ? value.trim() : '';
  if (!text) return null;
  if (/^\d+$/.test(text)) return Number(text) * 1000;
  const at = Date.parse(text);
  return Number.isFinite(at) ? Math.max(0, at - nowMs) : null;
}

const retryable = status => status === 0 || status === 408 || status === 429 || status >= 500;

/** The `telemetry/dropped` report, like the apps': counts by reason (overflow, expired, rejected, corrupt). */
function droppedRecord(dropped, at) {
  const a = { source: 'relay', label: 'telemetry', event: 'telemetry records dropped', reason: 'dropped', relay_recv_ts: String(at) };
  for (const [reason, n] of Object.entries(dropped)) a[`dropped_${reason}`] = String(n);
  return { body: 'sdk_event', at, attributes: a };
}

function encode(records, serviceName, observedMs) {
  const str = v => ({ stringValue: v });
  const observed = observedMs ? { observedTimeUnixNano: `${observedMs}000000` } : {};
  return {
    resourceLogs: [{
      resource: { attributes: [{ key: 'service.name', value: str(serviceName) }] },
      scopeLogs: [{
        logRecords: records.map(r => ({
          timeUnixNano: `${r.at}000000`, ...observed, severityText: r.severity || 'INFO', body: str(r.body),
          attributes: Object.entries(r.attributes).map(([key, v]) => ({ key, value: str(v) })),
        })),
      }],
    }],
  };
}

/** `<base>/config/telemetry.json` for a logs URL ending in /v1/logs; null otherwise. */
function deriveConfigUrl(url) {
  const base = String(url).replace(/\/+$/, '');
  return base.endsWith('/v1/logs') ? base.slice(0, -'/v1/logs'.length) + CONFIG_PATH : null;
}

function readText(file) { try { return fs.readFileSync(file, 'utf8'); } catch (e) { return null; } }
function writeText(file, text) {
  try { const tmp = `${file}.tmp`; fs.writeFileSync(tmp, text); fs.renameSync(tmp, file); } catch (e) { /* best effort */ }
}

/**
 * Options (only `url` and `serviceName` are needed):
 *   url            the full logs URL, e.g. https://otel.example/v1/logs; empty = every method is a no-op, enabled = false
 *   token          the Collector's OTLP_TOKEN, sent as a bearer token (uploads and config) when set
 *   serviceName    `service.name`, required when on
 *   serviceVersion this server's version, what the remote config's app_version rules match (default '0')
 *   build          'release' (default) or 'debug', what the config's build rules match
 *   queueDir       the disk queue's directory; null or 'memory' = memory only; default <tmp>/lt-telemetry/<serviceName>
 *   maxQueueBytes / maxQueueAgeMs   queue limits (5 MB / 7 days) unless the remote config sets them
 *   configUrl      remote config; default derived from a url ending in /v1/logs; '' = off
 *   configRefreshMs  how often the config is re-fetched (5 min; the timer never keeps the process alive)
 *   log(tag, message)  only on reachable <-> unreachable changes and config changes, never the URL or a header
 *   flushMs, timeoutMs, retryMs, maxRetryMs, fetch, now, random   tuning and test hooks
 */
function createTelemetry({ url, token, serviceName, serviceVersion = '0', build = 'release', queueDir,
  maxQueueBytes = DEFAULT_SETTINGS.queueMaxBytes, maxQueueAgeMs = DEFAULT_SETTINGS.queueMaxAgeMs, configUrl,
  configRefreshMs = DEFAULTS.configRefreshMs, flushMs = DEFAULTS.flushMs, timeoutMs = DEFAULTS.timeoutMs,
  retryMs = DEFAULTS.retryMs, maxRetryMs = DEFAULTS.maxRetryMs, log = () => {}, fetch: send = globalThis.fetch,
  now = Date.now, random = Math.random } = {}) {
  const off = {
    enabled: false, milestone() {}, setup() {}, event() {}, summary() {}, error() {}, record() {},
    flush: async () => {}, close: async () => {}, refreshConfig: async () => {}, settings: DEFAULT_SETTINGS,
  };
  if (!url) return off;
  if (!serviceName) throw new TypeError('createTelemetry: serviceName is required');
  const headers = { 'content-type': 'application/json' };
  if (token) headers.authorization = `Bearer ${token}`;
  const dir = queueDir === undefined ? path.join(os.tmpdir(), 'lt-telemetry', serviceName.replace(/[^\w.-]+/g, '_'))
    : (queueDir === 'memory' ? null : queueDir);

  // Remote config: the last good file (next to the queue) applies from the first record; a fresh one is fetched.
  const remoteUrl = configUrl === undefined ? deriveConfigUrl(url) : (configUrl || null);
  const target = { platform: 'server', appVersion: String(serviceVersion), build };
  const configFile = dir && path.join(dir, 'telemetry-config.json');
  const etagFile = dir && path.join(dir, 'telemetry-config.etag');
  const bucket = (() => {
    const file = dir && path.join(dir, 'telemetry-bucket.txt');
    const text = file ? (readText(file) || '').trim() : '';
    const saved = /^\d{1,2}$/.test(text) ? Number(text) : -1;
    if (saved >= 0) return saved;
    const b = crypto.randomInt(100);
    if (file) { try { fs.mkdirSync(dir, { recursive: true }); } catch (e) { /* store reports it */ } writeText(file, String(b)); }
    return b;
  })();
  let settings = (remoteUrl && configFile && parseConfig(readText(configFile) || '', target, bucket)) || DEFAULT_SETTINGS;
  let cachedBody = null;
  let lastFetch = 0;
  const remote = () => settings.version !== null;

  const store = createStore({ dir, now, log,
    maxBytes: remote() ? settings.queueMaxBytes : maxQueueBytes, maxAgeMs: remote() ? settings.queueMaxAgeMs : maxQueueAgeMs });
  let ok = null;
  let timer = null;      // the next batch, about flushMs after a record arrives
  let retry = null;      // a pending retry after a failure: new records only queue meanwhile
  let failures = 0;
  let running = null;
  let closed = false;

  /** HTTP status (0 = no answer) and the Retry-After delay, if any. */
  async function post(records) {
    try {
      const res = await send(url, {
        method: 'POST', headers,
        body: JSON.stringify(encode(records, serviceName, now())), signal: AbortSignal.timeout(timeoutMs),
      });
      const after = res.headers && typeof res.headers.get === 'function' ? res.headers.get('retry-after') : null;
      return { status: res.status || (res.ok ? 200 : 0), retryAfterMs: parseRetryAfter(after, now()) };
    } catch (e) { return { status: 0, retryAfterMs: null }; }
  }
  function outcome(sent) {
    // Sent every second under load, so only a change of outcome is logged. Never log the URL.
    if (sent !== ok) { ok = sent; log('telemetry', sent ? 'collector reachable' : 'collector unreachable, records are kept on disk and retried'); }
  }
  function backOff(retryAfterMs) {
    failures++;
    const base = remote() ? settings.retryBaseMs : retryMs;
    const max = remote() ? settings.retryMaxMs : maxRetryMs;
    const delay = retryAfterMs !== null ? Math.min(Math.max(retryAfterMs, base), MAX_RETRY_AFTER_MS)
      : backoffDelay(failures, base, max, random());
    retry = setTimeout(() => { retry = null; run(); }, delay);
    retry.unref();
  }
  /** Sends segment after segment until the queue is empty or one fails. */
  async function pass() {
    for (;;) {
      if (retry || !settings.enabled) return; // Kill switch: the queue waits (until it expires).
      const batch = store.next();
      if (!batch) return;
      const r = await post(batch.records);
      const sent = r.status >= 200 && r.status < 300;
      outcome(sent);
      if (sent) {
        store.complete(batch, true);
        failures = 0;
        // Losses are reported once there is a working path to report them on.
        const d = store.takeDropped();
        if (Object.keys(d).length) store.append([stamp(droppedRecord(d, now()))]);
      } else if (retryable(r.status)) {
        store.release(batch);
        if (!closed) backOff(r.retryAfterMs);
        return;
      } else {
        // A permanent rejection (bad token, bad payload) would block everything behind it: dropped and counted.
        store.complete(batch, false);
      }
    }
  }
  function run() {
    if (!running) running = pass().finally(() => { running = null; });
    return running;
  }
  function schedule() {
    if (timer || retry || closed) return;
    timer = setTimeout(() => { timer = null; run(); }, flushMs);
    timer.unref();
  }
  function stamp(record) {
    return remote() ? { ...record, attributes: { ...record.attributes, config_version: String(settings.version) } } : record;
  }
  function push(record) {
    if (!record || closed || !settings.enabled) return;
    if (record.body === 'sdk_event' && settings.dropLabels.includes(record.attributes.label)) return;
    store.append([stamp(record)]);
    schedule();
  }

  /** Fetches the remote config unless the last fetch is younger than minIntervalMs; a bad file changes nothing. */
  async function refreshConfig(minIntervalMs = 0) {
    if (!remoteUrl) return;
    const t = now();
    if (lastFetch && t - lastFetch < minIntervalMs) return;
    lastFetch = t;
    const h = token ? { authorization: `Bearer ${token}` } : {};
    const etag = etagFile && readText(etagFile);
    if (etag && (cachedBody || readText(configFile))) h['if-none-match'] = etag.trim();
    let body;
    let newEtag;
    try {
      const res = await send(remoteUrl, { method: 'GET', headers: h, signal: AbortSignal.timeout(timeoutMs) });
      if (res.status !== 200) return;
      body = await res.text();
      newEtag = res.headers && typeof res.headers.get === 'function' ? res.headers.get('etag') : null;
    } catch (e) { return; }
    if (typeof body !== 'string' || Buffer.byteLength(body) > MAX_CONFIG_BYTES) return;
    const parsed = parseConfig(body, target, bucket);
    if (!parsed) { log('telemetry', 'remote config is not valid, keeping the current settings'); return; }
    cachedBody = body;
    if (configFile) { writeText(configFile, body); if (newEtag) writeText(etagFile, newEtag); else { try { fs.rmSync(etagFile, { force: true }); } catch (e) { /* none */ } } }
    if (parsed.version !== settings.version) log('telemetry', `remote config v${parsed.version} applied`);
    const wasEnabled = settings.enabled;
    settings = parsed;
    if (!wasEnabled && settings.enabled && !store.isEmpty) schedule();
  }
  const refresher = remoteUrl ? setInterval(() => { refreshConfig(0); }, configRefreshMs) : null;
  if (refresher) refresher.unref();
  if (remoteUrl) refreshConfig(0);

  // What the last process could not send.
  if (!store.isEmpty) schedule();
  return {
    enabled: true,
    milestone: m => push(milestoneRecord(m)),
    setup: m => push(setupRecord(m)),
    event: (attributes, at) => push(rawRecord(attributes, at)),
    summary: report => push(summaryRecord(report)),
    error: e => push(errorRecord(e)),
    /** Any already built record ({ body, at, attributes, severity? }), e.g. from your own builder. */
    record: r => push(r),
    /** Sends what is queued now (unless a retry is pending) and resolves when that pass ends. */
    async flush() {
      if (timer) { clearTimeout(timer); timer = null; }
      await run();
      // A record queued while the pass was posting may still wait: one more pass picks it up.
      if (!retry && !store.isEmpty && settings.enabled) await run();
    },
    /** One last pass; anything not delivered stays on disk for the next start. */
    async close() {
      if (timer) { clearTimeout(timer); timer = null; }
      if (retry) { clearTimeout(retry); retry = null; }
      if (refresher) clearInterval(refresher);
      closed = true;
      await run();
    },
    refreshConfig,
    /** The settings in effect (the remote config, or the defaults with version null). */
    get settings() { return settings; },
    /** Diagnostics and tests: the queue (isEmpty, bytes, onDisk). */
    get queue() { return store; },
  };
}

module.exports = { createTelemetry, milestoneRecord, setupRecord, rawRecord, summaryRecord, errorRecord, droppedRecord, encode,
  backoffDelay, parseRetryAfter, deriveConfigUrl };
