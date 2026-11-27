'use strict';
/* The apps' delivery mechanism for servers: disk queue first, uid per record, backoff with Retry-After, nothing lost
 * across a restart, drops reported, remote config (kill switch, drop_labels, rules for platform=server). */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { createTelemetry, backoffDelay, parseRetryAfter, deriveConfigUrl, errorRecord, setupRecord } = require('../src');
const { createStore, UID } = require('../src/store');
const { parseConfig, compareVersions, DEFAULT_SETTINGS } = require('../src/remote-config');

const dirs = [];
const tmpDir = () => { const d = fs.mkdtempSync(path.join(os.tmpdir(), 'lt-delivery-')); dirs.push(d); return d; };
test.after(() => { for (const d of dirs) fs.rmSync(d, { recursive: true, force: true }); });
const segments = dir => fs.readdirSync(dir).filter(n => n.endsWith('.jsonl'));

/**
 * A fake fetch. POSTs are answered from `answers` in order ({ status, retryAfter }), then 200; GET of the config
 * returns `config` (null = 404) with `etag`, 304 when If-None-Match matches.
 */
function fake({ answers = [], config = null, etag = '"v1"' } = {}) {
  const f = { posts: [], gets: [], config, etag };
  f.fetch = async (url, init) => {
    if (init.method === 'GET') {
      f.gets.push({ url, ifNoneMatch: init.headers['if-none-match'], auth: init.headers.authorization });
      if (f.config === null) return { status: 404, headers: { get: () => null }, text: async () => '' };
      if (init.headers['if-none-match'] === f.etag) return { status: 304, headers: { get: () => f.etag }, text: async () => '' };
      return { status: 200, headers: { get: k => (k === 'etag' ? f.etag : null) }, text: async () => f.config };
    }
    f.posts.push(JSON.parse(init.body));
    const a = answers.shift() || { status: 200 };
    return { status: a.status, ok: a.status < 300, headers: { get: k => (k === 'retry-after' ? a.retryAfter || null : null) } };
  };
  return f;
}
const records = f => f.posts.flatMap(b => b.resourceLogs[0].scopeLogs[0].logRecords)
  .map(r => ({ body: r.body.stringValue, ...Object.fromEntries(r.attributes.map(a => [a.key, a.value.stringValue])) }));
const opts = (f, extra = {}) => ({ url: 'https://otel.test/v1/logs', serviceName: 'letstalk-server', token: 't0k',
  queueDir: tmpDir(), fetch: f.fetch, ...extra });

test('records that were not delivered survive a restart and are sent once, with the same uid', async () => {
  const dir = tmpDir();
  const down = fake({ answers: [{ status: 503 }, { status: 503 }] });
  const first = createTelemetry(opts(down, { queueDir: dir, configUrl: '' }));
  first.error({ domain: 'api', code: 'token_issue_failed_agora', room: 'r1' });
  await first.flush();
  await first.close(); // The server stops; the record is still on disk.
  const uid = records(down)[0][UID];
  assert.ok(segments(dir).length >= 1);

  const up = fake();
  const second = createTelemetry(opts(up, { queueDir: dir, configUrl: '' }));
  await second.flush();
  const sent = records(up).filter(r => r.body === 'app_error');
  assert.equal(sent.length, 1);
  assert.equal(sent[0][UID], uid);
  assert.deepEqual(segments(dir), []);
  await second.close();
});

test('a failure backs off: new records only queue, flush does not cut a Retry-After short', async () => {
  const f = fake({ answers: [{ status: 429, retryAfter: '120' }] });
  const t = createTelemetry(opts(f, { configUrl: '' }));
  t.error({ domain: 'push', code: 'fcm_503' });
  await t.flush();
  t.error({ domain: 'push', code: 'fcm_504' });
  await t.flush();
  assert.equal(f.posts.length, 1);
  assert.equal(t.queue.isEmpty, false);
  await t.close();
});

test('a permanent rejection is dropped and reported once delivery works', async () => {
  const f = fake({ answers: [{ status: 400 }] });
  const t = createTelemetry(opts(f, { configUrl: '', queueDir: 'memory' }));
  assert.equal(t.queue.onDisk, false);
  t.summary({ provider: 'agora', room: 'r', user: '1' });
  await t.flush();
  t.summary({ provider: 'agora', room: 'r', user: '2' });
  await t.flush();
  const report = records(f).find(r => r.label === 'telemetry');
  assert.deepEqual([report.reason, report.dropped_rejected, report.source], ['dropped', '1', 'relay']);
  await t.close();
});

test('remote config: fetched with the token, cached, conditional on the next start, applied with its version', async () => {
  const dir = tmpDir();
  const config = JSON.stringify({ schema: 1, version: 4, telemetry: { drop_labels: ['signaling'] },
    rules: [{ match: { platform: 'server', app_version_below: '2.0' }, telemetry: { retry_base_s: 20 } },
      { match: { platform: 'android' }, telemetry: { enabled: false } }] });
  const f = fake({ config });
  const t = createTelemetry(opts(f, { queueDir: dir, serviceVersion: '1.3.0' }));
  await t.refreshConfig(0);
  assert.equal(f.gets[0].url, 'https://otel.test/config/telemetry.json');
  assert.equal(f.gets[0].auth, 'Bearer t0k');
  assert.deepEqual([t.settings.version, t.settings.enabled, t.settings.retryBaseMs], [4, true, 20_000]); // android rule skipped
  t.milestone({ room: 'r', user: '1', type: 'ring', callId: 'c' }); // label=signaling: dropped by the config
  t.error({ domain: 'api', code: 'x' });
  await t.flush();
  const sent = records(f);
  assert.deepEqual(sent.map(r => r.body), ['app_error']);
  assert.equal(sent[0].config_version, '4');
  const gets = f.gets.length; // One at start, one above.
  await t.refreshConfig(60_000); // Too soon: no request.
  assert.equal(f.gets.length, gets);
  await t.close();

  const next = createTelemetry(opts(f, { queueDir: dir, serviceVersion: '1.3.0' }));
  assert.equal(next.settings.version, 4); // From disk, before any fetch.
  await next.refreshConfig(0);
  assert.equal(f.gets.at(-1).ifNoneMatch, '"v1"'); // Answered 304.
  assert.equal(next.settings.version, 4);
  await next.close();
});

test('remote config: the kill switch stops sending; a bad file keeps the last good settings', async () => {
  const f = fake({ config: JSON.stringify({ schema: 1, version: 2, telemetry: { enabled: false } }) });
  const t = createTelemetry(opts(f));
  await t.refreshConfig(0);
  t.error({ domain: 'api', code: 'x' });
  await t.flush();
  assert.equal(f.posts.length, 0);
  f.config = '{broken'; f.etag = '"v2"';
  await t.refreshConfig(0);
  assert.equal(t.settings.version, 2);
  await t.close();
  assert.equal(createTelemetry(opts(fake(), { url: 'https://otel.test/custom' })).settings.version, null); // no derivable config URL
});

test('config parsing: defaults, clamps, rules in order, rollout, unusable files', () => {
  const server = { platform: 'server', appVersion: '1.4.2', build: 'release' };
  assert.deepEqual(parseConfig('{"schema":1,"version":3}', server, 0), { ...DEFAULT_SETTINGS, dropLabels: [], version: 3 });
  const c = parseConfig(JSON.stringify({ schema: 1, version: 1, telemetry: { retry_base_s: 1, retry_max_s: 2, queue_max_kb: 1,
    queue_max_age_h: 99999, drop_labels: ['mic', '', 5, 'mic'] } }), server, 0);
  assert.deepEqual([c.retryBaseMs, c.retryMaxMs, c.queueMaxBytes, c.queueMaxAgeMs, c.dropLabels],
    [5000, 5000, 512 * 1024, 720 * 3_600_000, ['mic']]);
  const rules = JSON.stringify({ schema: 1, version: 2, rules: [
    { match: { platform: 'server' }, telemetry: { retry_base_s: 30 } },
    { match: { app_version_min: '1.4.0', build: 'release' }, telemetry: { retry_base_s: 40 } },
    { rollout_percent: 10, telemetry: { enabled: false } }] });
  assert.equal(parseConfig(rules, server, 50).retryBaseMs, 40_000);
  assert.equal(parseConfig(rules, server, 50).enabled, true);
  assert.equal(parseConfig(rules, server, 9).enabled, false);
  assert.equal(parseConfig(rules, { ...server, appVersion: '1.3.9' }, 50).retryBaseMs, 30_000);
  for (const bad of ['', 'x', '[]', '{"version":1}', '{"schema":2,"version":1}', '{"schema":1}', '{"schema":1,"version":1.5}']) {
    assert.equal(parseConfig(bad, server, 0), null, bad);
  }
  assert.ok(compareVersions('1.10.0', '1.9') > 0);
  assert.equal(compareVersions('1.4.0-rc1', '1.4'), 0);
});

test('backoff doubles to the cap with jitter; Retry-After reads seconds and HTTP dates; config URL derivation', () => {
  assert.equal(backoffDelay(1, 10_000, 300_000, 0.5), 10_000);
  assert.equal(backoffDelay(2, 10_000, 300_000, 0.5), 20_000);
  assert.equal(backoffDelay(20, 10_000, 300_000, 0.5), 300_000);
  assert.equal(backoffDelay(1, 10_000, 300_000, 0), 8_000);
  assert.equal(parseRetryAfter('120'), 120_000);
  assert.equal(parseRetryAfter('Wed, 21 Oct 2015 07:28:30 GMT', Date.parse('Wed, 21 Oct 2015 07:28:00 GMT')), 30_000);
  assert.equal(parseRetryAfter('soon'), null);
  assert.equal(deriveConfigUrl('https://o.test/v1/logs/'), 'https://o.test/config/telemetry.json');
  assert.equal(deriveConfigUrl('https://o.test/ingest'), null);
});

test('store: over the cap events go before app_error / call_summary; old and corrupt segments are counted', () => {
  const dir = tmpDir();
  let now = 1_000_000;
  const err = errorRecord({ domain: 'api', code: 'x', room: 'r' }, 1);
  const ev = setupRecord({ room: 'r', user: 'u', stage: 'dial', callId: 'c' }, 2);
  const size = Buffer.byteLength(JSON.stringify({ ...ev, attributes: { ...ev.attributes, [UID]: '0'.repeat(36) } })) + 1;
  const store = createStore({ dir, maxBytes: size * 4, now: () => now });
  store.append([err]);
  for (let i = 0; i < 6; i++) { store.append([ev]); const b = store.next(); if (b) store.release(b); }
  const left = [];
  for (let b = store.next(); b; b = store.next()) { left.push(...b.records); store.complete(b, true); }
  assert.ok(left.some(r => r.body === 'app_error'));
  assert.ok(store.takeDropped().overflow >= 1);

  const aging = createStore({ dir, maxAgeMs: 1000, now: () => now });
  aging.append([ev, ev]);
  now += 5000;
  assert.equal(aging.next(), null);
  assert.deepEqual(createStore({ dir }).takeDropped(), { expired: 2 });

  createStore({ dir }).append([ev]);
  fs.appendFileSync(path.join(dir, segments(dir)[0]), 'garbage\n');
  const reread = createStore({ dir });
  assert.equal(reread.next().records.length, 1);
  assert.deepEqual(reread.takeDropped(), { corrupt: 1 });
});

test('store: without a usable directory the same queue works in memory', () => {
  const file = path.join(tmpDir(), 'not-a-dir');
  fs.writeFileSync(file, 'x');
  const lines = [];
  const store = createStore({ dir: path.join(file, 'queue'), log: (...l) => lines.push(l.join(' ')) });
  assert.equal(store.onDisk, false);
  assert.ok(lines.some(l => l.includes('in memory')));
  store.append([errorRecord({ domain: 'api', code: 'x' }, 1)]);
  const b = store.next();
  assert.equal(b.records.length, 1);
  store.complete(b, true);
  assert.equal(store.isEmpty, true);
});
