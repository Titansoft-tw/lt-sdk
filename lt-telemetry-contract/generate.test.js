'use strict';
const test = require('node:test');
const assert = require('node:assert');
const { problems } = require('./generate');
const contract = require('./contract.json');

test('the contract passes its own rules', () => {
  assert.deepStrictEqual(problems(contract), []);
});

test('an attribute the Collector deletes fails the check', () => {
  const bad = structuredClone(contract);
  bad.attributes.path_trace.push('client_ip');
  assert.match(problems(bad).join('\n'), /client_ip: deleted by the Collector/);
});

test('a secret looking or reserved attribute fails the check', () => {
  const bad = structuredClone(contract);
  bad.attributes.sdk_event.push('media_key', 'exit_carrier');
  const found = problems(bad).join('\n');
  assert.match(found, /media_key: dropped by the encoders/);
  assert.match(found, /exit_carrier: reserved/);
});

test('every setup stage is a call_setup reason', () => {
  const bad = structuredClone(contract);
  bad.setupStages.app.push('teleported');
  assert.match(problems(bad).join('\n'), /teleported: setup stage missing/);
});
