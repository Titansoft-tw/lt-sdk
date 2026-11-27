'use strict';
const test = require('node:test');
const assert = require('node:assert');
const { problems, envelopeProblems } = require('./validate');
const { sign, verify, keygen } = require('./sign');
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

test('a signature verifies only for the same bytes and key', () => {
  const { privatePem, publicPem } = keygen();
  const body = Buffer.from('{"rulesVersion": 1, "rules": {"version": 1, "rules": []}}');
  const sig = sign(body, privatePem);
  assert.ok(verify(body, `${sig}\n`, publicPem));
  assert.ok(!verify(Buffer.from(body.toString().replace('1,', '2,')), sig, publicPem));
  assert.ok(!verify(body, sig, keygen().publicPem));
  assert.ok(!verify(body, 'not base64 !', publicPem));
});

test('envelope problems', () => {
  const rules = { version: 1, rules: [] };
  assert.deepStrictEqual(envelopeProblems({ rulesVersion: 3, rules }), []);
  assert.match(envelopeProblems([]).join(), /must be an object/);
  assert.match(envelopeProblems({ rulesVersion: 0, rules }).join(), /rulesVersion/);
  assert.match(envelopeProblems({ rulesVersion: 1.5, rules }).join(), /rulesVersion/);
  assert.match(envelopeProblems({ rulesVersion: 1, rules, extra: 1 }).join(), /unknown key extra/);
  assert.match(envelopeProblems({ rulesVersion: 1 }).join(), /rules: missing/);
  assert.match(envelopeProblems({ rulesVersion: 1, rules: { version: 2, rules: [] } }).join(), /^rules\.version/);
});
