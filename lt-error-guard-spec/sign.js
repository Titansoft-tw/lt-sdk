#!/usr/bin/env node
'use strict';
/* Signs a remote rules envelope for GuardRulesLoader (README "Remote rules"): ECDSA P-256 over the file's exact bytes,
 * SHA-256, DER signature in base64 written next to it as <file>.sig. Upload both; the app embeds the public key.
 *   node sign.js --keygen <name>                 write <name>.key (PKCS#8, keep secret) and <name>.pub.pem (ship in the app)
 *   node sign.js <envelope.json> <private.key>   validate, then write <envelope.json>.sig
 *   node sign.js --verify <envelope.json> <public.pem>   check <envelope.json>.sig */

const crypto = require('crypto');
const fs = require('fs');
const { envelopeProblems } = require('./validate');

/** Base64 DER signature of [data] (Buffer) with an EC P-256 private key (PEM). */
const sign = (data, privatePem) => crypto.sign('sha256', data, privatePem).toString('base64');

/** Whether [signature] (base64 DER, surrounding whitespace allowed) is valid for [data] under the public key (PEM). */
function verify(data, signature, publicPem) {
  try { return crypto.verify('sha256', data, publicPem, Buffer.from(String(signature).trim(), 'base64')); } catch { return false; }
}

function keygen() {
  const { privateKey, publicKey } = crypto.generateKeyPairSync('ec', { namedCurve: 'P-256' });
  return { privatePem: privateKey.export({ type: 'pkcs8', format: 'pem' }), publicPem: publicKey.export({ type: 'spki', format: 'pem' }) };
}

function main(args) {
  if (args[0] === '--keygen' && args[1]) {
    const { privatePem, publicPem } = keygen();
    fs.writeFileSync(`${args[1]}.key`, privatePem, { mode: 0o600 });
    fs.writeFileSync(`${args[1]}.pub.pem`, publicPem);
    console.log(`wrote ${args[1]}.key (secret, never commit) and ${args[1]}.pub.pem`);
    return 0;
  }
  if (args[0] === '--verify' && args[2]) {
    const ok = verify(fs.readFileSync(args[1]), fs.readFileSync(`${args[1]}.sig`, 'utf8'), fs.readFileSync(args[2], 'utf8'));
    console.log(ok ? `${args[1]}: signature ok` : `${args[1]}: signature INVALID`);
    return ok ? 0 : 1;
  }
  if (args.length === 2) {
    const data = fs.readFileSync(args[0]);
    let found;
    try { found = envelopeProblems(JSON.parse(data.toString('utf8'))); } catch (e) { found = [e.message]; }
    if (found.length) { console.error(found.map(p => `${args[0]}: ${p}`).join('\n')); return 1; }
    fs.writeFileSync(`${args[0]}.sig`, sign(data, fs.readFileSync(args[1], 'utf8')) + '\n');
    console.log(`wrote ${args[0]}.sig`);
    return 0;
  }
  console.error('usage: node sign.js --keygen <name> | <envelope.json> <private.key> | --verify <envelope.json> <public.pem>');
  return 2;
}

if (require.main === module) process.exitCode = main(process.argv.slice(2));
module.exports = { sign, verify, keygen };
