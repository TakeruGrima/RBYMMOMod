#!/usr/bin/env node
'use strict';

/*
 * Pin the authentication primitives in server/lib/auth.js.
 *
 * This is the most load-bearing suite in the self-hosting feature: auth.js
 * decides whether a stranger gets into someone's game. The HMAC wire
 * contract in particular is cross-checked against an independently computed
 * digest -- never by calling back into auth.js's own sign() -- and a fixed
 * known-answer vector is hard-coded so a refactor that silently changes the
 * key or message derivation gets caught before it reaches a player.
 *
 * Same bespoke idiom as server/hub.test.js: a throwing ok(cond, label)
 * helper, plain scenario functions, a final console.log of the pass count.
 * No test framework, no dependencies beyond node:crypto.
 *
 * Run: node server/auth.test.js
 * Also runs under `npm test` (node --test), which auto-discovers *.test.js
 * siblings and runs each as its own process. This file has no node:test
 * imports, so --test treats the whole script as one implicit test and calls
 * it a pass as long as it exits 0 -- exactly how hub.test.js already behaves
 * under both invocations.
 */

const crypto = require('crypto');
const auth = require('./lib/auth.js');

let passed = 0;
const ok = (cond, label) => {
  if (!cond) throw new Error('FAIL: ' + label);
  passed++;
};

// ---------------------------------------------------------------- join codes

const GROUP_PATTERN = `[${auth.ALPHABET}]{${auth.CODE_GROUP_LEN}}`;
const CODE_RE = new RegExp('^' + Array(auth.CODE_GROUPS).fill(GROUP_PATTERN).join('-') + '$');

function testJoinCodes() {
  const SAMPLE = 5000;
  const codes = [];
  for (let i = 0; i < SAMPLE; i++) codes.push(auth.generateJoinCode());

  ok(codes.every((c) => CODE_RE.test(c)),
    `all ${SAMPLE} generated codes match the dashed ABCD-EFGH-JKMN-PQRS shape`);

  const allChars = codes.join('').replace(/-/g, '');
  ok(allChars.length === SAMPLE * auth.CODE_LEN,
    'the sample produced the expected total character count');
  ok([...allChars].every((ch) => auth.ALPHABET.includes(ch)),
    'every character across the whole sample is in ALPHABET');
  ok(!/[ILOU]/.test(allChars),
    'the excluded characters I, L, O and U never appear across the sample');

  const unique = new Set(codes);
  ok(unique.size === SAMPLE, `no repeats across ${SAMPLE} generated codes (crude uniqueness check)`);
}

// --------------------------------------------------------------- normalising

function testNormalization() {
  const dashed = 'ABCD-EFGH-JKMN-PQRS';
  const undashed = 'ABCDEFGHJKMNPQRS';
  const lower = 'abcd-efgh-jkmn-pqrs';
  const messy = ' abcd efgh, jkmn! pqrs?? ';
  const expected = undashed;

  ok(auth.normalizeCode(dashed) === expected, 'the dashed form normalises to the bare 16 characters');
  ok(auth.normalizeCode(undashed) === expected, 'the undashed form is unchanged');
  ok(auth.normalizeCode(lower) === expected, 'lowercase normalises the same as uppercase');
  ok(auth.normalizeCode(messy) === expected, 'spaces and stray punctuation are stripped');

  ok(auth.normalizeCode('ABCD-EFGH-JKMN') === null, 'a too-short input returns null');
  ok(auth.normalizeCode('ABCD-EFGH-JKMN-PQRS-TVWX') === null, 'a too-long input returns null');

  for (const bad of [42, null, undefined, {}, [], true, Symbol('x')]) {
    ok(auth.normalizeCode(bad) === null, `a non-string input (${String(bad)}) returns null`);
  }

  ok(auth.formatCode(auth.normalizeCode(dashed)) === dashed,
    'formatCode(normalizeCode(x)) round-trips the canonical dashed form');
  ok(auth.formatCode(auth.normalizeCode(messy)) === dashed,
    'a messy input round-trips to the same canonical dashed form');
}

// -------------------------------------------------------- the HMAC contract

function testHmacContract() {
  const code = 'ABCD-EFGH-JKMN-PQRS';
  const nonce = auth.newNonce();
  const normalized = auth.normalizeCode(code);

  // Independently computed -- this does NOT call back into auth.js's own
  // HMAC path. A test that asserted sign() equalled sign() would prove
  // nothing about the wire contract; this proves auth.js agrees with the
  // literal recipe documented at the top of lib/auth.js.
  const expected = crypto
    .createHmac('sha256', Buffer.from(normalized, 'ascii'))
    .update(nonce, 'ascii')
    .digest('hex');

  const actual = auth.sign(code, nonce);
  ok(actual === expected,
    'sign() matches an independently computed HMAC-SHA256(normalizedCode, nonce)');
  ok(/^[0-9a-f]{64}$/.test(actual), 'the signature is 64 lowercase hex characters');

  const dashedSig = auth.sign('ABCD-EFGH-JKMN-PQRS', nonce);
  const undashedSig = auth.sign('ABCDEFGHJKMNPQRS', nonce);
  ok(dashedSig === undashedSig, 'a dashed and an undashed spelling of the same code sign identically');
}

/*
 * Known-answer vector -- the cross-language contract with src/Sha256.lua.
 *
 *   code:   ABCD-EFGH-JKMN-PQRS   (normalises to ABCDEFGHJKMNPQRS)
 *   nonce:  a1b2c3d4e5f6070819293a4b5c6d7e8f   (32 lowercase hex chars)
 *   digest: HMAC-SHA256(key = 'ABCDEFGHJKMNPQRS' as ASCII bytes,
 *                        message = the nonce string above, as ASCII bytes)
 *
 * Computed once, offline, with node:crypto:
 *
 *   crypto.createHmac('sha256', Buffer.from('ABCDEFGHJKMNPQRS', 'ascii'))
 *     .update('a1b2c3d4e5f6070819293a4b5c6d7e8f', 'ascii')
 *     .digest('hex')
 *   === '025b38b6dc30464f973489da3bf148a208877406707fd1b6d93abfc521c663e7'
 *
 * src/Sha256.lua's HMAC-SHA256 must reproduce this exact 64-hex-character
 * value for the same two inputs. If it does not, a correct join code will
 * look like a wrong one to a client on the pure-Lua implementation -- silent
 * auth failure, not a crash, which is why this is pinned as a literal rather
 * than derived from any code path.
 */
const KAT_CODE = 'ABCD-EFGH-JKMN-PQRS';
const KAT_NONCE = 'a1b2c3d4e5f6070819293a4b5c6d7e8f';
const KAT_DIGEST = '025b38b6dc30464f973489da3bf148a208877406707fd1b6d93abfc521c663e7';

function testKnownAnswerVector() {
  ok(KAT_DIGEST.length === 64, 'the fixed vector literal is 64 characters long');
  ok(/^[0-9a-f]{64}$/.test(KAT_DIGEST), 'the fixed vector literal is lowercase hex');
  ok(auth.sign(KAT_CODE, KAT_NONCE) === KAT_DIGEST,
    'sign() reproduces the fixed known-answer vector');
}

// ------------------------------------------------------------------- verify

function testVerify() {
  const code = 'ABCD-EFGH-JKMN-PQRS';
  const nonce = auth.newNonce();
  const goodResponse = auth.sign(code, nonce);
  const credential = auth.newCredential({ secret: code });

  {
    const result = auth.verify(nonce, goodResponse, [credential]);
    ok(result.ok === true, 'a correct response is accepted');
    ok(result.credentialId === credential.id, 'credentialId names the credential that matched');
    ok(result.reason === null, 'a successful verify carries no reason');
  }

  {
    const wrong = auth.sign('WXYZ-2345-6789-ABCD', nonce);
    const result = auth.verify(nonce, wrong, [credential]);
    ok(result.ok === false, 'a wrong response is rejected');
    ok(result.reason === 'rejected', 'and reported as a plain rejection');
    ok(result.credentialId === null, 'and names no credential');
  }

  // A response of the wrong length/case/charset must be refused as
  // 'malformed' before any credential is consulted -- proven by getting the
  // same verdict whether or not a matching credential, or any credential at
  // all, is present.
  const malformedCases = [
    ['too short', goodResponse.slice(0, 10)],
    ['too long', goodResponse + 'ab'],
    ['wrong case', 'A' + goodResponse.slice(1)],
    ['wrong charset', goodResponse.slice(0, 63) + 'z'],
  ];
  for (const [label, response] of malformedCases) {
    const withCreds = auth.verify(nonce, response, [credential]);
    ok(withCreds.reason === 'malformed',
      `${label} response is rejected as malformed even with a matching credential present`);
    const withoutCreds = auth.verify(nonce, response, []);
    ok(withoutCreds.reason === 'malformed',
      `${label} response is rejected as malformed ahead of the empty-credential-list check`);
  }

  {
    const result = auth.verify(nonce, goodResponse, []);
    ok(result.ok === false, 'an empty credential list never admits');
    ok(result.reason === 'no_credentials', 'and is reported distinctly from a wrong code');
  }

  // Revoked, expired and used-up credentials must be indistinguishable from
  // a plain wrong code in the reason returned -- a refusal must not be an
  // oracle for enumerating which invites a hub has issued. Each is tested
  // alongside one genuinely active credential so the hub is in the same
  // "has active credentials" state as the plain-wrong-code case above --
  // otherwise activeCredentials() would filter the pool down to nothing and
  // the comparison would be against 'no_credentials' instead, which is a
  // different question (whether *any* credential is active right now, not
  // whether *this* one is).
  const now = Date.now();
  const revoked = Object.assign(
    auth.newCredential({ secret: 'AAAA-AAAA-AAAA-AAAA' }), { revoked: true });
  const expired = Object.assign(
    auth.newCredential({ secret: 'BBBB-BBBB-BBBB-BBBB' }),
    { expiresAt: new Date(now - 1000).toISOString() });
  const usedUp = Object.assign(
    auth.newCredential({ secret: 'CCCC-CCCC-CCCC-CCCC', maxUses: 1 }), { uses: 1 });
  const bystander = auth.newCredential({ secret: 'ZZZZ-ZZZZ-ZZZZ-ZZZZ' });

  for (const [label, cred, signCode] of [
    ['a revoked credential', revoked, 'AAAA-AAAA-AAAA-AAAA'],
    ['an expired credential', expired, 'BBBB-BBBB-BBBB-BBBB'],
    ['a used-up credential', usedUp, 'CCCC-CCCC-CCCC-CCCC'],
  ]) {
    const response = auth.sign(signCode, nonce);
    const result = auth.verify(nonce, response, [cred, bystander], now);
    ok(result.ok === false, `${label} is rejected even with the right underlying code`);
    ok(result.reason === 'rejected', `${label} looks identical to a plain wrong code`);
  }

  {
    const valid = auth.newCredential({ secret: 'DDDD-DDDD-DDDD-DDDD' });
    const pool = [revoked, expired, usedUp, valid];
    const response = auth.sign('DDDD-DDDD-DDDD-DDDD', nonce);
    const result = auth.verify(nonce, response, pool, now);
    ok(result.ok === true, 'a valid credential is still found among several invalid ones');
    ok(result.credentialId === valid.id, 'and identified by the right id');
  }
}

// --------------------------------------------------- isActive / activeCredentials

function testActiveCredentials() {
  const now = 1700000000000; // a fixed reference instant

  const justBefore = { secret: 'AAAA-AAAA-AAAA-AAAA', expiresAt: new Date(now + 1).toISOString() };
  const exactlyAt = { secret: 'AAAA-AAAA-AAAA-AAAA', expiresAt: new Date(now).toISOString() };
  const justAfter = { secret: 'AAAA-AAAA-AAAA-AAAA', expiresAt: new Date(now - 1).toISOString() };
  ok(auth.isActive(justBefore, now) === true, 'a credential expiring 1ms in the future is still active');
  ok(auth.isActive(exactlyAt, now) === false, 'a credential expiring exactly now is already expired');
  ok(auth.isActive(justAfter, now) === false, 'a credential that expired 1ms ago is expired');

  const underMax = { secret: 'AAAA-AAAA-AAAA-AAAA', maxUses: 3, uses: 2 };
  const atMax = { secret: 'AAAA-AAAA-AAAA-AAAA', maxUses: 3, uses: 3 };
  const overMax = { secret: 'AAAA-AAAA-AAAA-AAAA', maxUses: 3, uses: 4 };
  ok(auth.isActive(underMax, now) === true, 'one use below maxUses is still active');
  ok(auth.isActive(atMax, now) === false, 'uses equal to maxUses is exhausted');
  ok(auth.isActive(overMax, now) === false, 'uses above maxUses is exhausted');

  const revoked = { secret: 'AAAA-AAAA-AAAA-AAAA', revoked: true };
  ok(auth.isActive(revoked, now) === false, 'a revoked credential is never active');

  const badExpiry = { secret: 'AAAA-AAAA-AAAA-AAAA', expiresAt: 'not-a-date' };
  ok(auth.isActive(badExpiry, now) === false, 'an unparseable expiresAt is treated as expired');

  // The same rule, one field over: a use count the hub cannot read is a
  // budget it cannot enforce, so it counts as spent. This is the last gate
  // before admission and it must have no fail-open branch -- a credential
  // whose `uses` was hand-edited to a string, or corrupted to an object, used
  // to make the `uses >= maxUses` comparison unreachable and stay active for
  // ever regardless of maxUses.
  const unreadableUses = [
    ['a string', 'lots'],
    ['an object', {}],
    ['NaN', Number.NaN],
    ['Infinity', Number.POSITIVE_INFINITY],
  ];
  for (const [label, uses] of unreadableUses) {
    const credential = { secret: 'AAAA-AAAA-AAAA-AAAA', maxUses: 3, uses };
    ok(auth.isActive(credential, now) === false,
      `${label} as the use count fails closed, not open`);
  }

  // ...but a *missing* count is genuinely zero uses, which is what every
  // freshly-minted credential has before anyone has spent it.
  ok(auth.isActive({ secret: 'AAAA-AAAA-AAAA-AAAA', maxUses: 3 }, now) === true,
    'a credential with no uses recorded yet is still active');
  ok(auth.isActive({ secret: 'AAAA-AAAA-AAAA-AAAA', maxUses: 3, uses: null }, now) === true,
    'and so is one whose count is null');

  // And the whole way through verify(), with the right underlying code: an
  // unreadable count must look exactly like a spent one from outside.
  {
    const nonce = auth.newNonce();
    const broken = { id: 'broken', secret: 'AAAA-AAAA-AAAA-AAAA', maxUses: 1, uses: 'one' };
    const result = auth.verify(nonce, auth.sign('AAAA-AAAA-AAAA-AAAA', nonce), [broken], now);
    ok(result.ok === false,
      'verify refuses a credential whose use count cannot be read, even with the right code');
    ok(result.reason === 'no_credentials',
      'and it is filtered out before the comparison rather than failing it');
  }

  const pool = [justBefore, exactlyAt, atMax, revoked, underMax];
  const active = auth.activeCredentials(pool, now);
  ok(active.length === 2, 'activeCredentials keeps only the active entries');
  ok(active.includes(justBefore) && active.includes(underMax), 'and keeps the right ones');
}

// ------------------------------------------------------------- newCredential

function testNewCredential() {
  const generated = auth.newCredential({});
  ok(typeof generated.secret === 'string' && auth.normalizeCode(generated.secret) !== null,
    'newCredential generates a usable secret when none is given');

  const given = auth.newCredential({ secret: 'ABCD-EFGH-JKMN-PQRS' });
  ok(auth.normalizeCode(given.secret) === 'ABCDEFGHJKMNPQRS', 'a given secret is kept');

  ok(typeof generated.createdAt === 'string' && !Number.isNaN(Date.parse(generated.createdAt)),
    'createdAt is stamped with a parseable date');

  ok(generated.uses === 0, 'uses starts at 0');

  const ids = new Set();
  for (let i = 0; i < 50; i++) ids.add(auth.newCredential({}).id);
  ok(ids.size === 50, 'newCredential gives distinct ids');
}

// --------------------------------------------------------------------- main

function main() {
  testJoinCodes();
  testNormalization();
  testHmacContract();
  testKnownAnswerVector();
  testVerify();
  testActiveCredentials();
  testNewCredential();
  console.log(`\n  ${passed}/${passed} checks passed  (auth)\n`);
  console.log(`  known-answer vector -- code: ${KAT_CODE}  nonce: ${KAT_NONCE}`);
  console.log(`  known-answer vector -- digest: ${KAT_DIGEST}\n`);
}

try {
  main();
} catch (err) {
  console.error('\n  ' + err.message + '\n');
  process.exit(1);
}
