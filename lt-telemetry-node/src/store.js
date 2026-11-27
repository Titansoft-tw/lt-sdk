'use strict';
/* The disk queue behind createTelemetry, the same mechanism as the apps' TelemetryStore (lt-telemetry-android /
 * LtTelemetry-ios): every record is written to disk before it is sent, so a crash or restart of the server loses
 * nothing that was queued; what is left goes out when the process starts again. Once appendFileSync returns the bytes are in the OS page cache and outlive the process (only a
 * power loss could lose them, so there is no fsync).
 *
 * Layout: append-only segment files `<seq>-<lane>.jsonl` in `dir`, one JSON record per line. append() writes to the
 * open segment of the record's lane; next() seals the OLDEST segment (any lane, by seq: a server is not short of
 * bandwidth, so records go out in the order they were made) and hands it out as one batch; complete() deletes it.
 * Over `maxBytes` the oldest segment of the least important lane goes first (event → critical); segments older than
 * `maxAgeMs` are dropped. Drops are counted by reason (takeDropped) and survive a restart too.
 *
 * Without a usable directory (dir null, or it cannot be created) the same queue lives in memory. Never throws. */
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const UID = 'log.record.uid';
const DEFAULT_MAX_BYTES = 5 * 1024 * 1024;
const DEFAULT_MAX_AGE_MS = 7 * 24 * 3600 * 1000;
const SEGMENT_RECORDS = 200;               // one segment = at most one POST
const SEGMENT_BYTES = 256 * 1024;
const SEGMENT_NAME = /^(\d{12})-([a-z])\.jsonl$/;
/** Eviction order, least important last: app_error and call_summary are kept longest. */
const LANES = ['c', 'e'];
const laneOf = r => (r.body === 'app_error' || r.body === 'call_summary' ? 'c' : 'e');
const DROPS = ['overflow', 'expired', 'rejected', 'corrupt'];

function createStore({ dir = null, maxBytes = DEFAULT_MAX_BYTES, maxAgeMs = DEFAULT_MAX_AGE_MS, now = Date.now,
  newUid = () => crypto.randomUUID(), log = () => {} } = {}) {
  let disk = !!dir;
  if (disk) {
    try { fs.mkdirSync(dir, { recursive: true }); } catch (e) {
      disk = false;
      log('telemetry', 'queue directory not usable, keeping the queue in memory');
    }
  }
  /** seq → { seq, lane, file, records (count, -1 = unknown), bytes, lines (memory mode), modified } */
  const segments = new Map();
  const open = {};
  const inFlight = new Set();
  const dropped = Object.fromEntries(DROPS.map(d => [d, 0]));
  const droppedFile = disk ? path.join(dir, 'dropped.json') : null;
  let nextSeq = 1;
  let totalBytes = 0;

  if (disk) {
    let names = [];
    try { names = fs.readdirSync(dir); } catch (e) { /* empty */ }
    for (const name of names.sort()) {
      const m = SEGMENT_NAME.exec(name);
      if (!m || !LANES.includes(m[2])) continue;
      const file = path.join(dir, name);
      let st;
      try { st = fs.statSync(file); } catch (e) { continue; }
      const seq = Number(m[1]);
      // Segments left by an earlier process are sealed: new records go to new segments.
      segments.set(seq, { seq, lane: m[2], file, records: -1, bytes: st.size, modified: st.mtimeMs });
      nextSeq = Math.max(nextSeq, seq + 1);
      totalBytes += st.size;
    }
    try {
      const saved = JSON.parse(fs.readFileSync(droppedFile, 'utf8'));
      for (const d of DROPS) if (Number.isInteger(saved[d]) && saved[d] > 0) dropped[d] = saved[d];
    } catch (e) { /* none yet */ }
  }

  const ordered = () => [...segments.values()].sort((a, b) => a.seq - b.seq);

  function saveDropped() {
    if (!disk) return;
    try {
      const any = DROPS.some(d => dropped[d] > 0);
      if (!any) { fs.rmSync(droppedFile, { force: true }); return; }
      const tmp = `${droppedFile}.tmp`;
      fs.writeFileSync(tmp, JSON.stringify(dropped));
      fs.renameSync(tmp, droppedFile);
    } catch (e) { /* counts are best effort */ }
  }
  function count(reason, n) {
    if (n <= 0) return;
    dropped[reason] += n;
    saveDropped();
  }
  function readLines(s) {
    if (!disk) return s.lines.slice();
    try { return fs.readFileSync(s.file, 'utf8').split('\n').filter(l => l.trim()); } catch (e) { return []; }
  }
  function recordsIn(s) { return s.records >= 0 ? s.records : readLines(s).length; }
  function remove(s) {
    segments.delete(s.seq);
    if (open[s.lane] === s) delete open[s.lane];
    totalBytes -= s.bytes;
    if (disk) { try { fs.rmSync(s.file, { force: true }); } catch (e) { /* gone already */ } }
  }
  function openSegment(lane, size) {
    const cur = open[lane];
    if (cur && segments.has(cur.seq) && cur.records >= 0 && cur.records < SEGMENT_RECORDS && cur.bytes + size <= SEGMENT_BYTES) return cur;
    if (size > maxBytes) return null;
    const seq = nextSeq++;
    const s = { seq, lane, file: disk ? path.join(dir, `${String(seq).padStart(12, '0')}-${lane}.jsonl`) : null,
      records: 0, bytes: 0, lines: disk ? undefined : [], modified: now() };
    segments.set(seq, s);
    open[lane] = s;
    return s;
  }
  function enforceCap() {
    while (totalBytes > maxBytes) {
      let victim = null;
      for (const lane of [...LANES].reverse()) {
        victim = ordered().find(s => s.lane === lane && !inFlight.has(s.seq));
        if (victim) break;
      }
      if (!victim) return;
      count('overflow', recordsIn(victim));
      remove(victim);
    }
  }
  function expire() {
    const cutoff = now() - maxAgeMs;
    for (const s of ordered()) {
      if (inFlight.has(s.seq)) continue;
      if (s.modified > 0 && s.modified < cutoff) { count('expired', recordsIn(s)); remove(s); }
    }
  }

  return {
    /** Writes each record before returning; each gets a log.record.uid (kept on retries, for de-duplication). */
    append(records) {
      for (const r of records) {
        if (!r) continue;
        const rec = r.attributes && r.attributes[UID] ? r : { ...r, attributes: { ...r.attributes, [UID]: newUid() } };
        const line = `${JSON.stringify(rec)}\n`;
        const size = Buffer.byteLength(line);
        const s = openSegment(laneOf(rec), size);
        if (!s) { count('overflow', 1); continue; }
        if (disk) {
          try { fs.appendFileSync(s.file, line); } catch (e) { count('overflow', 1); continue; }
        } else s.lines.push(line.trimEnd());
        s.records++;
        s.bytes += size;
        s.modified = now();
        totalBytes += size;
      }
      enforceCap();
    },
    /** The oldest waiting segment, sealed, as { seq, records }; null when nothing waits. Expired segments go first. */
    next() {
      expire();
      for (const s of ordered()) {
        if (inFlight.has(s.seq) || s.bytes === 0) continue;
        if (open[s.lane] === s) delete open[s.lane];
        const lines = readLines(s);
        const records = [];
        for (const l of lines) { try { records.push(JSON.parse(l)); } catch (e) { /* counted below */ } }
        if (records.length < lines.length) count('corrupt', lines.length - records.length);
        if (!records.length) { remove(s); continue; }
        inFlight.add(s.seq);
        return { seq: s.seq, records };
      }
      return null;
    },
    /** sent = the collector took it; false = rejected for good. Either way the segment is deleted. */
    complete(batch, sent) {
      inFlight.delete(batch.seq);
      if (!sent) count('rejected', batch.records.length);
      const s = segments.get(batch.seq);
      if (s) remove(s);
    },
    /** Not delivered now: stays queued. */
    release(batch) { inFlight.delete(batch.seq); },
    /** Dropped counts since the last call ({ overflow: 3, ... }, only reasons > 0), then reset. */
    takeDropped() {
      const out = {};
      for (const d of DROPS) if (dropped[d] > 0) { out[d] = dropped[d]; dropped[d] = 0; }
      if (Object.keys(out).length) saveDropped();
      return out;
    },
    get isEmpty() { return ![...segments.values()].some(s => s.bytes > 0); },
    get bytes() { return totalBytes; },
    get onDisk() { return disk; },
  };
}

module.exports = { createStore, laneOf, UID, DEFAULT_MAX_BYTES, DEFAULT_MAX_AGE_MS, SEGMENT_RECORDS };
