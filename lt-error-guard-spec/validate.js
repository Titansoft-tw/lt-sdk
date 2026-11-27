#!/usr/bin/env node
'use strict';
/* Checks lt-error-guard rule files (rules.schema.json, plus unique ids). The SDKs' GuardRules.parse rejects the same files.
 *   node validate.js rules.json [more.json ...]   exit 1 and list the problems when a file is invalid */

const fs = require('fs');

const ACTIONS = ['keep', 'drop', 'sample', 'dedupe'];
const LEVELS = ['error', 'warning', 'info', 'debug'];
const ID = /^[a-z0-9_-]+$/;
const CODE = /^[a-z0-9_]+$/;
const isObject = v => typeof v === 'object' && v !== null && !Array.isArray(v);

function unknownKeys(where, o, allowed, out) {
  for (const k of Object.keys(o)) if (!allowed.includes(k)) out.push(`${where}: unknown key ${k}`);
}

function globs(where, v, out) {
  if (!Array.isArray(v) || v.length === 0) out.push(`${where}: must be a non-empty list`);
  else if (!v.every(g => typeof g === 'string' && g.length > 0)) out.push(`${where}: every glob must be a non-empty string`);
}

/** Every problem with [rules] (parsed JSON); empty when the file is valid. */
function problems(rules) {
  const out = [];
  if (!isObject(rules)) return ['rules: must be an object'];
  unknownKeys('rules', rules, ['version', 'sessionBudget', 'rules'], out);
  if (rules.version !== 1) out.push('version: must be 1');
  if ('sessionBudget' in rules) {
    const b = rules.sessionBudget;
    if (!isObject(b)) out.push('sessionBudget: must be an object');
    else {
      unknownKeys('sessionBudget', b, ['maxEvents'], out);
      if (!Number.isInteger(b.maxEvents) || b.maxEvents < 1) out.push('sessionBudget.maxEvents: must be an integer of at least 1');
    }
  }
  if (!Array.isArray(rules.rules)) { out.push('rules: must be a list'); return out; }
  const seen = new Set();
  rules.rules.forEach((r, i) => {
    const where = `rules[${i}]${isObject(r) && typeof r.id === 'string' ? ` (${r.id})` : ''}`;
    if (!isObject(r)) { out.push(`${where}: must be an object`); return; }
    unknownKeys(where, r, ['id', 'match', 'action', 'rate', 'domain', 'code'], out);
    if (typeof r.id !== 'string' || !ID.test(r.id)) out.push(`${where}: id must match ${ID}`);
    else if (r.id === 'budget') out.push(`${where}: id budget is reserved for the session budget`);
    else if (seen.has(r.id)) out.push(`${where}: duplicate id`);
    else seen.add(r.id);
    if (!ACTIONS.includes(r.action)) out.push(`${where}: action must be one of ${ACTIONS.join(', ')}`);
    if (r.action === 'sample') {
      if (typeof r.rate !== 'number' || !(r.rate >= 0 && r.rate <= 1)) out.push(`${where}: rate must be a number from 0 to 1`);
    } else if ('rate' in r) out.push(`${where}: rate is only for action sample`);
    if (r.action === 'keep') {
      for (const k of ['domain', 'code']) if (k in r) out.push(`${where}: a keep rule has no ${k} (nothing is suppressed)`);
    } else if (ACTIONS.includes(r.action)) {
      for (const k of ['domain', 'code']) if (typeof r[k] !== 'string' || !CODE.test(r[k])) out.push(`${where}: ${k} must match ${CODE}`);
    }
    if (!isObject(r.match)) { out.push(`${where}: match must be an object`); return; }
    const m = r.match;
    unknownKeys(`${where}.match`, m, ['exceptionType', 'message', 'inApp', 'level', 'tags'], out);
    if ('exceptionType' in m) globs(`${where}.match.exceptionType`, m.exceptionType, out);
    if ('message' in m) globs(`${where}.match.message`, m.message, out);
    if ('inApp' in m && typeof m.inApp !== 'boolean') out.push(`${where}.match.inApp: must be true or false`);
    if ('level' in m && (!Array.isArray(m.level) || m.level.length === 0 || !m.level.every(l => LEVELS.includes(l)))) {
      out.push(`${where}.match.level: must be a non-empty list of ${LEVELS.join(', ')} (crashes are always kept)`);
    }
    if ('tags' in m) {
      if (!isObject(m.tags) || Object.keys(m.tags).length === 0) out.push(`${where}.match.tags: must be a non-empty object`);
      else for (const [k, v] of Object.entries(m.tags)) globs(`${where}.match.tags.${k}`, v, out);
    }
  });
  return out;
}

function main(files) {
  if (files.length === 0) { console.error('usage: node validate.js rules.json [more.json ...]'); return 2; }
  let bad = 0;
  for (const file of files) {
    let found;
    try { found = problems(JSON.parse(fs.readFileSync(file, 'utf8'))); } catch (e) { found = [e.message]; }
    if (found.length) { bad++; console.error(found.map(p => `${file}: ${p}`).join('\n')); } else console.log(`${file}: ok`);
  }
  return bad ? 1 : 0;
}

if (require.main === module) process.exitCode = main(process.argv.slice(2));
module.exports = { problems };
