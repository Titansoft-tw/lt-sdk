'use strict';
/* Remote telemetry config (`<collector base>/config/telemetry.json`, schema 1; lt-call-demo
 * docs/telemetry-delivery-proposal.md §4.3), the server side of what lt-telemetry-android's RemoteTelemetryConfig
 * parses. A server uses the knobs that apply to it: enabled (kill switch), drop_labels, retry_base_s / retry_max_s,
 * queue_max_kb / queue_max_age_h (next start). quality_every_s / call_sample_percent / batch_records are app knobs and
 * are parsed but unused here. Every value is clamped, so no file can break the server or flood the collector. */

const SCHEMA = 1;
const MAX_DROP_LABELS = 50;

const DEFAULT_SETTINGS = Object.freeze({
  enabled: true,
  qualityEverySec: 1,
  callSamplePercent: 100,
  batchRecords: 3,
  retryBaseMs: 10_000,
  retryMaxMs: 300_000,
  queueMaxBytes: 5 * 1024 * 1024,
  queueMaxAgeMs: 7 * 24 * 3600 * 1000,
  dropLabels: Object.freeze([]),
  version: null,
});

/** Numeric, segment by segment ("1.10.0" > "1.9"); a segment's leading digits count, the rest is ignored. */
function compareVersions(a, b) {
  const parts = v => String(v).trim().split('.').map(s => Number((/^\d+/.exec(s) || ['0'])[0]));
  const x = parts(a); const y = parts(b);
  for (let i = 0; i < Math.max(x.length, y.length); i++) {
    const c = (x[i] || 0) - (y[i] || 0);
    if (c !== 0) return Math.sign(c);
  }
  return 0;
}

const isObject = v => v !== null && typeof v === 'object' && !Array.isArray(v);
const num = v => (typeof v === 'number' && Number.isFinite(v) ? v : null);

function matches(match, target) {
  if (!isObject(match)) return true;
  if (typeof match.platform === 'string' && match.platform.toLowerCase() !== target.platform.toLowerCase()) return false;
  if (typeof match.build === 'string' && match.build.toLowerCase() !== target.build.toLowerCase()) return false;
  if (typeof match.app_version_min === 'string' && compareVersions(target.appVersion, match.app_version_min) < 0) return false;
  if (typeof match.app_version_below === 'string' && compareVersions(target.appVersion, match.app_version_below) >= 0) return false;
  return true;
}

function settings(m, version) {
  const d = DEFAULT_SETTINGS;
  const int = (key, def, min, max) => {
    const v = num(m[key]);
    return v === null ? def : Math.min(Math.max(Math.trunc(v), min), max);
  };
  const retryBaseS = int('retry_base_s', d.retryBaseMs / 1000, 5, 300);
  return {
    enabled: typeof m.enabled === 'boolean' ? m.enabled : d.enabled,
    qualityEverySec: int('quality_every_s', d.qualityEverySec, 1, 10),
    callSamplePercent: int('call_sample_percent', d.callSamplePercent, 0, 100),
    batchRecords: int('batch_records', d.batchRecords, 1, 30),
    retryBaseMs: retryBaseS * 1000,
    retryMaxMs: int('retry_max_s', d.retryMaxMs / 1000, retryBaseS, 3600) * 1000,
    queueMaxBytes: int('queue_max_kb', d.queueMaxBytes / 1024, 512, 20_480) * 1024,
    queueMaxAgeMs: int('queue_max_age_h', d.queueMaxAgeMs / 3_600_000, 1, 720) * 3_600_000,
    dropLabels: [...new Set((Array.isArray(m.drop_labels) ? m.drop_labels : [])
      .filter(l => typeof l === 'string' && l.trim()).slice(0, MAX_DROP_LABELS))],
    version,
  };
}

/**
 * The settings `json` gives `target` ({ platform, appVersion, build }), or null when the file is unusable (not JSON,
 * not an object, schema ≠ 1, no integer version): the caller keeps its last good settings. `bucket` (0–99) is the local
 * rollout bucket; a rule with `rollout_percent` applies only when bucket < percent. Unknown fields are ignored.
 */
function parseConfig(json, target, bucket) {
  let root;
  try { root = JSON.parse(json); } catch (e) { return null; }
  if (!isObject(root) || root.schema !== SCHEMA) return null;
  const version = root.version;
  if (!Number.isInteger(version) || version < 0) return null;
  const merged = { ...(isObject(root.telemetry) ? root.telemetry : {}) };
  for (const rule of Array.isArray(root.rules) ? root.rules : []) {
    if (!isObject(rule) || !matches(rule.match, target)) continue;
    const percent = num(rule.rollout_percent) === null ? 100 : Math.min(Math.max(rule.rollout_percent, 0), 100);
    if (bucket >= percent) continue;
    if (isObject(rule.telemetry)) Object.assign(merged, rule.telemetry);
  }
  return settings(merged, version);
}

module.exports = { parseConfig, compareVersions, DEFAULT_SETTINGS, SCHEMA };
