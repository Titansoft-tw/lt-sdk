'use strict';
/* Ported from lt-voice-relay test/telemetry.test.js, errors.test.js and callsetup.test.js (the parts that are
 * about the reporter, not the relay's endpoints), against a local collector. */
const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { createTelemetry, milestoneRecord, setupRecord, summaryRecord, errorRecord, rawRecord, encode } = require('../src');
const contract = require('../src/contract');

const CALL = '3f2b8c1e-9a4d-4f6b-8e21-0c5d7a9b1e42';

/** A fresh queue directory per reporter, so tests never see each other's records. */
const dirs = [];
const tmpDir = () => { const d = fs.mkdtempSync(path.join(os.tmpdir(), 'lt-telemetry-test-')); dirs.push(d); return d; };
test.after(() => { for (const d of dirs) fs.rmSync(d, { recursive: true, force: true }); });

/** A collector that answers `status` and keeps what it received, flattened to { body, ...attributes }. */
async function collector(status = 200) {
  const c = { paths: [], auths: [], services: [], records: [] };
  const server = http.createServer((req, res) => {
    let body = '';
    req.on('data', d => { body += d; });
    req.on('end', () => {
      if (req.method === 'GET') { c.configGets = (c.configGets || 0) + 1; res.writeHead(404).end(); return; } // no remote config
      c.paths.push(req.url); c.auths.push(req.headers.authorization);
      for (const rl of JSON.parse(body).resourceLogs) {
        c.services.push(rl.resource.attributes.find(a => a.key === 'service.name').value.stringValue);
        for (const r of rl.scopeLogs[0].logRecords) {
          const flat = { body: r.body.stringValue, severityText: r.severityText, timeUnixNano: r.timeUnixNano };
          for (const a of r.attributes) flat[a.key] = a.value.stringValue;
          c.records.push(flat);
        }
      }
      res.writeHead(status).end();
    });
  });
  await new Promise(r => server.listen(0, '127.0.0.1', r));
  c.url = `http://127.0.0.1:${server.address().port}`;
  c.stop = () => new Promise(r => server.close(r));
  return c;
}

const REPORT = {
  v: 1, provider: 'webrtc', room: '123456', user: '004321', peer: '123456', callId: 'abcd1234-ef5',
  line: 'outgoing', role: 'caller', failed: false, reason: '對方已掛斷',
  durationMs: 58123.5, connectMs: 790, ringMs: 24000, talkMs: 32500, firstAudioMs: 925, reconnects: 1, reconnectMs: 0,
  samples: 33, rttMs: { avg: 12.3, max: 40, n: 33 }, mos: { avg: 4.3, min: 4.1, n: 32 },
  candidateType: 'relay', protocol: 'udp', relayProtocol: 'tcp', codec: 'audio/opus',
  device: 'Google Pixel 3a XL', os: 'Android 12 (31)', app: '0.1.0',
};

test('posts to the full URL with the service name, and the token only when set', async t => {
  const c = await collector(); t.after(c.stop);
  const a = createTelemetry({ queueDir: tmpDir(), url: `${c.url}/v1/logs`, token: 'otlp-token-0123456789', serviceName: 'lt-voice-relay' });
  a.summary(REPORT);
  await a.close();
  const b = createTelemetry({ queueDir: tmpDir(), url: `${c.url}/custom/path`, serviceName: 'other' });
  b.summary(REPORT);
  await b.close();
  assert.deepEqual(c.paths, ['/v1/logs', '/custom/path']); // Nothing appended: the caller gives the whole URL.
  assert.deepEqual(c.auths, ['Bearer otlp-token-0123456789', undefined]);
  assert.deepEqual(c.services, ['lt-voice-relay', 'other']);
});

test('a report is one call_summary with string values; unmeasured values stay absent', async t => {
  const c = await collector(); t.after(c.stop);
  const s = createTelemetry({ queueDir: tmpDir(), url: `${c.url}/v1/logs`, serviceName: 'lt-voice-relay' });
  s.summary(REPORT);
  await s.close();
  assert.equal(c.records.length, 1);
  const [r] = c.records;
  assert.equal(r.body, 'call_summary');
  assert.match(r.timeUnixNano, /^\d{13}000000$/);
  assert.deepEqual([r.call_id, r.channel, r.leg_uid, r.peer_uid, r.engine, r.source], ['abcd1234-ef5', '123456', '4321', '123456', 'webrtc', 'relay']);
  assert.deepEqual([r.role, r.failed, r.relay, r.transport, r.duration_ms, r.talk_ms], ['caller', '0', '1', 'udp', '58123.5', '32500']);
  assert.equal(r.rtt_ms_avg, '12.3');
  assert.equal(r.rtt_ms_min, undefined);
  assert.equal(r.loss_pct_avg, undefined);
  assert.equal(r.app_version, '0.1.0');
  assert.match(r.relay_recv_ts, /^\d{13}$/);
});

test('a failing collector is logged once and never throws; the URL stays out of the log', async t => {
  const c = await collector(503); t.after(c.stop);
  const lines = [];
  const s = createTelemetry({ queueDir: tmpDir(), url: `${c.url}/v1/logs`, serviceName: 'lt-voice-relay', log: (...a) => lines.push(a) });
  s.summary(REPORT); await s.flush();
  s.summary(REPORT); await s.close();
  assert.equal(lines.length, 1);
  assert.equal(lines[0][0], 'telemetry');
  assert.ok(!JSON.stringify(lines).includes('127.0.0.1'));
});

test('off without a URL; serviceName is required when on', async () => {
  const off = createTelemetry({ queueDir: tmpDir(), url: '', serviceName: 'x' });
  assert.equal(off.enabled, false);
  off.summary(REPORT); off.milestone({}); await off.close();
  assert.equal(createTelemetry().enabled, false);
  assert.throws(() => createTelemetry({ queueDir: tmpDir(), url: 'http://x/v1/logs' }), /serviceName/);
});

test('records go out in batches of at most 200, oldest first, each with a uid and the send time', async () => {
  const bodies = [];
  const s = createTelemetry({ queueDir: tmpDir(), url: 'http://x/v1/logs', serviceName: 's', configUrl: '',
    fetch: async (u, init) => { bodies.push(JSON.parse(init.body)); return { status: 200, ok: true }; } });
  for (let i = 0; i < 450; i++) s.event({ label: 'agora_server', reason: `r${i}` }, i);
  await s.close();
  const logs = bodies.map(b => b.resourceLogs[0].scopeLogs[0].logRecords);
  assert.deepEqual(logs.map(l => l.length), [200, 200, 50]);
  const flat = logs.flat();
  assert.equal(flat[0].attributes.find(a => a.key === 'reason').value.stringValue, 'r0');
  assert.equal(new Set(flat.map(r => r.attributes.find(a => a.key === 'log.record.uid').value.stringValue)).size, 450);
  assert.ok(flat.every(r => /^\d{13}000000$/.test(r.observedTimeUnixNano)));
});

test('milestones need a call id and name hangups by reason', () => {
  assert.equal(milestoneRecord({ room: 'r', user: 'u', type: 'ring', callId: '' }), null);
  assert.equal(milestoneRecord({ room: 'r', user: 'u', type: 'restart-request', callId: 'c' }, 1).attributes.reason, 'restart_request');
  const h = milestoneRecord({ room: 'r1', user: '111111', type: 'hangup', callId: 'call-1', reason: 'no-answer', setupId: 's1' }, 2).attributes;
  assert.deepEqual([h.label, h.event, h.reason, h.relay_recv_ts, h.setup_id], ['signaling', 'hangup', 'hangup_no_answer', '2', 's1']);
  assert.equal(summaryRecord({ provider: 'agora', room: 'audio-lab', user: '1001' }, 1).attributes.call_id, 'audio-lab');
});

test('setupRecord only accepts the contract relay stages and needs a call id', () => {
  assert.deepEqual([...contract.setupStages.relay], ['dial', 'ringing', 'accept', 'push_sent', 'push_failed']);
  assert.equal(setupRecord({ room: 'r', user: 'u', stage: 'dial', callId: '' }), null);
  assert.equal(setupRecord({ room: 'r', user: 'u', stage: 'nonsense', callId: CALL }), null);
  const r = setupRecord({ room: 'r', user: '0042', stage: 'push_failed', event: 'invite', callId: CALL, engine: 'agora', detail: 'apns 410 Unregistered' }, 5);
  assert.deepEqual(r, { body: 'sdk_event', at: 5, attributes: {
    call_id: CALL, channel: 'r', leg_uid: '42', engine: 'agora', source: 'relay', label: 'call_setup',
    event: 'invite', reason: 'push_failed', relay_recv_ts: '5', detail: 'apns 410 Unregistered',
  } });
});

test('errorRecord follows the app_error contract with source=relay; encode uses its severity', () => {
  const r = errorRecord({
    domain: 'push', code: 'fcm_404_UNREGISTERED', severity: 'WARN', stage: 'dial',
    callId: CALL, room: 'room1', user: '000042', engine: 'livekit', detail: 'fcm 404 UNREGISTERED', setupId: 'setup-1',
  }, 5);
  assert.deepEqual(r, { body: 'app_error', at: 5, severity: 'WARN', attributes: {
    error_domain: 'push', error_code: 'fcm_404_UNREGISTERED', stage: 'dial', fatal: '0', count: '1', source: 'relay',
    call_id: CALL, channel: 'room1', leg_uid: '42', engine: 'livekit', detail: 'fcm 404 UNREGISTERED',
    relay_recv_ts: '5', setup_id: 'setup-1',
  } });
  const bare = errorRecord({ domain: 'api', code: 'token_issue_failed_webrtc' }, 6);
  assert.deepEqual(bare.attributes, { error_domain: 'api', error_code: 'token_issue_failed_webrtc', fatal: '0', count: '1', source: 'relay', relay_recv_ts: '6' });
  assert.equal(bare.severity, 'ERROR');
  assert.equal(errorRecord({ domain: 'push' }), null);
  assert.equal(errorRecord({ code: 'x' }), null);
  assert.equal(errorRecord({ domain: 'api', code: 'x', severity: 'LOUD' }).severity, 'ERROR');
  assert.equal(errorRecord({ domain: 'api', code: 'x', fatal: true }).attributes.fatal, '1');

  const ordinary = milestoneRecord({ room: 'r', user: 'u', type: 'ring', callId: CALL }, 1);
  const logs = encode([ordinary, summaryRecord({ provider: 'webrtc', room: 'r', user: 'u' }, 2), r, bare], 'lt-voice-relay')
    .resourceLogs[0].scopeLogs[0].logRecords;
  assert.deepEqual(logs.map(l => l.severityText), ['INFO', 'INFO', 'WARN', 'ERROR']);
});

test('raw NCS events keep their own time and get the relay receive time; values become strings', () => {
  const r = rawRecord({ label: 'agora_server', reason: '104', uid: 42, skip: undefined }, 7);
  assert.equal(r.at, 7);
  assert.deepEqual([r.attributes.uid, 'skip' in r.attributes], ['42', false]);
  assert.match(r.attributes.relay_recv_ts, /^\d{13}$/);
  assert.equal(rawRecord({ relay_recv_ts: 9 }, 1).attributes.relay_recv_ts, '9');
});
