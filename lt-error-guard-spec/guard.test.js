'use strict';
const test = require('node:test');
const assert = require('node:assert');
const { problems } = require('./validate');
const { specProblems, kotlin } = require('./generate');

test('the defaults, vectors and contract agree', () => {
  assert.deepStrictEqual(specProblems(), []);
});

test('every invalid vector fails with its own problem', () => {
  for (const c of require('./vectors/invalid.json').cases) {
    assert.ok(problems(c.rules).some(p => p.includes(c.error)), `${c.name}: ${JSON.stringify(problems(c.rules))}`);
  }
});

test('valid rules have no problems', () => {
  assert.deepStrictEqual(problems(require('./default-rules.json')), []);
  assert.deepStrictEqual(problems({ version: 1, rules: [] }), []);
  assert.deepStrictEqual(problems({ version: 1, rules: [{ id: 'a', match: {}, action: 'sample', rate: 0, domain: 'api', code: 'x' }] }), []);
});

test('a dollar sign survives the Kotlin raw string', () => {
  assert.match(kotlin('{"message": "$x"}'), /"\$\{'\$'\}x"/);
});
