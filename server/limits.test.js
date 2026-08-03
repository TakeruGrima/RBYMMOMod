#!/usr/bin/env node
'use strict';

/*
 * Unit tests for `lib/limits.js`, the module that decides whether the hub
 * survives contact with the open internet.
 *
 * Everything here is socket-free and timer-free by construction: `Limits`
 * takes an injected clock, so every scenario below drives time by hand
 * through a plain variable and a `now: () => clock` closure. No `setTimeout`,
 * no real sleep, no port opened.
 *
 * Idiom matches `hub.test.js`: a bespoke, dependency-free runner with a
 * throwing `ok(cond, label)`, scenario functions, and a final pass count.
 * No test framework, no dependencies -- this both runs directly
 * (`node server/limits.test.js`) and is discovered by `node --test`
 * (`server/package.json`'s `test` script), which just executes the file as
 * a script and treats an uncaught throw / non-zero exit as the failure
 * signal.
 *
 * Run: node server/limits.test.js
 */

const assert = require('assert');
const { Limits, normalizeIp, DEFAULTS, BOUNDS } = require('./lib/limits.js');

let passed = 0;
const ok = (cond, label) => {
  if (!cond) throw new Error('FAIL: ' + label);
  passed++;
};

// A clock the test drives by hand. `tick()` advances it; `now` is what gets
// injected into `new Limits({ now })`.
function makeClock(start = 0) {
  let t = start;
  return {
    now: () => t,
    set(value) { t = value; },
    advance(ms) { t += ms; },
  };
}

function freshLimits(overrides, clock) {
  return new Limits(Object.assign({ now: clock.now }, overrides));
}

// -------------------------------------------------------------- normalizeIp

function testNormalizeIp() {
  // Dual-stack spellings fold to the same key.
  ok(normalizeIp('::ffff:203.0.113.7') === '203.0.113.7',
    'IPv4-mapped IPv6 folds to the bare dotted quad');
  ok(normalizeIp('203.0.113.7') === '203.0.113.7',
    'a bare dotted quad passes through unchanged');
  ok(normalizeIp('::ffff:203.0.113.7') === normalizeIp('203.0.113.7'),
    'both spellings produce the identical key');

  // The hex-mapped spelling some stacks emit.
  ok(normalizeIp('::ffff:cb00:7107') === '203.0.113.7',
    'the hex-mapped IPv4-in-IPv6 form decodes to the same dotted quad');

  // The deprecated IPv4-compatible form.
  ok(normalizeIp('::203.0.113.7') === '203.0.113.7',
    'the deprecated ::a.b.c.d compatible form folds too');

  // Bracketed forms.
  ok(normalizeIp('[203.0.113.7]') === '203.0.113.7',
    'a bracketed IPv4 address is unwrapped');
  ok(normalizeIp('[::ffff:203.0.113.7]') === '203.0.113.7',
    'a bracketed mapped IPv6 address is unwrapped and folded');

  // Zone index stripped.
  ok(normalizeIp('fe80::1%en0') === 'fe80::1',
    'a %zone suffix is stripped');
  ok(normalizeIp('[fe80::1%en0]') === 'fe80::1',
    'a %zone suffix inside brackets is stripped too');

  // Case-insensitivity.
  ok(normalizeIp('FE80::1') === 'fe80::1', 'IPv6 is lowercased for comparison');

  // Plain IPv6, unmapped, passes through lowercased.
  ok(normalizeIp('2001:DB8::1') === '2001:db8::1',
    'a non-mapped IPv6 address is handled (lowercased, unchanged shape)');

  // Non-string / empty input.
  ok(normalizeIp(undefined) === '', 'a non-string input normalizes to empty');
  ok(normalizeIp(123) === '', 'a number input normalizes to empty');
  ok(normalizeIp('   ') === '', 'whitespace-only input normalizes to empty');
  ok(normalizeIp('') === '', 'empty string normalizes to empty');

  // ------- the consequence: a ban/count on one spelling hits the other

  const clock = makeClock();
  const limits = freshLimits({}, clock);

  limits.setBans(['::ffff:203.0.113.7']);
  ok(limits.admit('203.0.113.7').reason === 'banned',
    'a ban entered as the mapped spelling catches the bare dotted quad');
  ok(limits.admit('::ffff:203.0.113.7').reason === 'banned',
    'and catches its own spelling too, obviously');

  const limits2 = freshLimits({ perIpConnections: 100 }, clock);
  limits2.register('sock-a', '203.0.113.7');
  ok(limits2.connectionsFrom('::ffff:203.0.113.7') === 1,
    'a count taken under the bare spelling is visible under the mapped one');
  limits2.register('sock-b', '::ffff:203.0.113.7');
  ok(limits2.connectionsFrom('203.0.113.7') === 2,
    'and registrations under either spelling accumulate into one bucket');
}

// -------------------------------------------------------------- per-IP cap

function testPerIpCap() {
  const clock = makeClock();
  const limits = freshLimits(
    { perIpConnections: 2, connectBurst: 100, maxPending: 100 }, clock);

  ok(limits.admit('1.1.1.1').ok, 'first connection from an address is admitted');
  limits.register('k1', '1.1.1.1');
  ok(limits.admit('1.1.1.1').ok, 'second connection from the same address is admitted');
  limits.register('k2', '1.1.1.1');

  const third = limits.admit('1.1.1.1');
  ok(third.ok === false && third.reason === 'per_ip',
    'a third connection from the same address is refused as per_ip');

  // a different address does not share the budget
  const other = limits.admit('2.2.2.2');
  ok(other.ok, 'a different address is unaffected by the first one being at cap');

  // release frees a slot
  ok(limits.release('k1') === true, 'release reports success for a live key');
  const fourth = limits.admit('1.1.1.1');
  ok(fourth.ok, 'freeing a slot lets the next connection from that address in');
}

// -------------------------------------------------------------- token bucket

function testTokenBucket() {
  const clock = makeClock();
  const limits = freshLimits(
    { connectBurst: 3, connectPerMinute: 60, perIpConnections: 1000, maxPending: 1000 },
    clock);

  ok(limits.admit('9.9.9.1').ok, 'burst admission 1 of 3 succeeds immediately');
  ok(limits.admit('9.9.9.1').ok, 'burst admission 2 of 3 succeeds immediately');
  ok(limits.admit('9.9.9.1').ok, 'burst admission 3 of 3 succeeds immediately');
  const fourth = limits.admit('9.9.9.1');
  ok(fourth.ok === false && fourth.reason === 'rate',
    'the next admission beyond the burst is refused as rate');

  // connectPerMinute: 60 => exactly one token refills per second
  clock.advance(500);
  ok(limits.admit('9.9.9.1').reason === 'rate',
    'half a second is not enough time to refill one token');
  clock.advance(500); // now a full second since the last spend
  ok(limits.admit('9.9.9.1').ok, 'a full second refills exactly one token');
  ok(limits.admit('9.9.9.1').reason === 'rate',
    'and only one token was refilled, not more');

  // the bucket never exceeds capacity, however long you wait
  clock.advance(3600000); // one hour of accumulated "tokens" if unbounded
  let admitted = 0;
  for (let i = 0; i < 10; i++) {
    if (limits.admit('9.9.9.1').ok) admitted++;
  }
  ok(admitted === 3,
    'after an hour of idle refill, only connectBurst (3) admissions succeed');
  ok(limits.admit('9.9.9.1').reason === 'rate',
    'the one after that is refused: the bucket capped out at capacity');

  // ------- a rejected connection still costs a token
  //
  // Construct a case where the *rate* check would pass but the connection is
  // ultimately refused for a different reason (per_ip). The rate bucket must
  // still be charged on that call, or an attacker already pinned at their
  // per-IP cap gets unlimited free retries.
  const clock2 = makeClock();
  const gate = freshLimits(
    { perIpConnections: 1, connectBurst: 3, connectPerMinute: 60, maxPending: 100 },
    clock2);

  const first = gate.admit('9.9.9.2');
  ok(first.ok, 'first admission for the pinned address succeeds (spends token 1/3)');
  gate.register('pinned', '9.9.9.2'); // now at the per-ip cap

  const second = gate.admit('9.9.9.2');
  ok(second.reason === 'per_ip',
    'over the per-ip cap: refused as per_ip, not rate (spends token 2/3)');
  const third = gate.admit('9.9.9.2');
  ok(third.reason === 'per_ip',
    'still per_ip (spends token 3/3, exhausting the burst)');

  // no time has passed, so if those two per_ip rejections had not spent a
  // token, the bucket would still show 1 token left and this would also be
  // 'per_ip'. Getting 'rate' here proves they did spend one each.
  const fourthGate = gate.admit('9.9.9.2');
  ok(fourthGate.reason === 'rate',
    'once the burst is exhausted by rejected attempts too, the verdict flips to rate');
}

// -------------------------------------------------------------- admit order

function testAdmitOrdering() {
  const clock = makeClock();

  // banned beats everything, including an explicit allowlist entry
  {
    const limits = freshLimits(
      { perIpConnections: 1, connectBurst: 1, maxPending: 1 }, clock);
    limits.setAllowlist(['6.6.6.6']);
    limits.setBans(['6.6.6.6']);
    const verdict = limits.admit('6.6.6.6');
    ok(verdict.ok === false && verdict.reason === 'banned',
      'a ban on an allow-listed address still wins: banned beats not_allowed');
  }

  // not_allowed, on its own, with nothing else in play
  {
    const limits = freshLimits({}, clock);
    limits.setAllowlist(['7.7.7.7']);
    const verdict = limits.admit('8.8.8.8');
    ok(verdict.ok === false && verdict.reason === 'not_allowed',
      'an address outside a non-empty allowlist is refused as not_allowed');
  }

  // rate beats per_ip: exhaust the bucket, and the still-open per_ip slot
  // must not be reached
  {
    const limits = freshLimits(
      { perIpConnections: 100, connectBurst: 1, maxPending: 100 }, clock);
    ok(limits.admit('9.1.1.1').ok, 'spend the single token');
    const verdict = limits.admit('9.1.1.1');
    ok(verdict.reason === 'rate',
      'with tokens exhausted and the per_ip slot still free, rate wins');
  }

  // per_ip beats pending: the same address is over its own cap while the
  // global pending pool is also full
  {
    const limits = freshLimits(
      { perIpConnections: 1, connectBurst: 100, maxPending: 1 }, clock);
    ok(limits.admit('9.2.2.2').ok, 'first admission for A succeeds');
    limits.register('a', '9.2.2.2'); // perIp[A] = 1 (at cap), pending = 1 (at cap)
    const verdict = limits.admit('9.2.2.2');
    ok(verdict.reason === 'per_ip',
      'over its own per-ip cap and over the global pending cap: per_ip wins');
  }

  // pure pending: a *different* address, under its own per-ip cap, refused
  // only because the global pending pool is full
  {
    const limits = freshLimits(
      { perIpConnections: 100, connectBurst: 100, maxPending: 1 }, clock);
    ok(limits.admit('9.3.3.3').ok, 'A is admitted and fills the one pending slot');
    limits.register('a', '9.3.3.3');
    const verdict = limits.admit('9.4.4.4');
    ok(verdict.reason === 'pending',
      'B, unrelated to A, is refused as pending once the global pool is full');
  }
}

// ------------------------------------------------------------------- allow

function testAllowlist() {
  const clock = makeClock();

  const empty = freshLimits({}, clock);
  ok(empty.admit('1.2.3.4').ok, 'an empty allowlist means everyone is allowed');
  ok(empty.admit('99.99.99.99').ok, 'including an address nobody configured');

  const restricted = freshLimits({}, clock);
  restricted.setAllowlist(['1.2.3.4']);
  ok(restricted.admit('1.2.3.4').ok, 'a listed address is allowed');
  ok(restricted.admit('5.6.7.8').reason === 'not_allowed',
    'an unlisted address is refused');

  // allowlist entries are normalized the same way ban/perIp keys are
  const normalized = freshLimits({}, clock);
  normalized.setAllowlist(['::ffff:1.2.3.4']);
  ok(normalized.admit('1.2.3.4').ok,
    'an allowlist entered as the mapped spelling still matches the bare one');
}

// ------------------------------------------------------------- maxPending

function testMaxPending() {
  const clock = makeClock();
  const limits = freshLimits(
    { maxPending: 2, perIpConnections: 100, connectBurst: 100 }, clock);

  ok(limits.admit('a').ok, 'first pending slot admitted');
  limits.register('ka', 'a');
  ok(limits.pendingCount === 1, 'pendingCount reflects the one registration');

  ok(limits.admit('b').ok, 'second pending slot admitted');
  limits.register('kb', 'b');
  ok(limits.pendingCount === 2, 'pendingCount reflects both');

  const third = limits.admit('c');
  ok(third.reason === 'pending', 'a third ungreeted registration is capped');

  ok(limits.markGreeted('ka') === true, 'markGreeted succeeds for a pending key');
  ok(limits.pendingCount === 1, 'markGreeted frees one pending slot');

  ok(limits.admit('c').ok, 'the freed slot lets the next registration in');
  ok(limits.markGreeted('ka') === false,
    'markGreeted on an already-greeted key is a no-op (returns false)');
  ok(limits.pendingCount === 1, 'and does not free a slot twice');
}

// ------------------------------------------------------------------- sweep

function testSweep() {
  // ---- handshake timeout: fires strictly after the budget, not at it
  {
    const clock = makeClock(0);
    const limits = freshLimits({ handshakeTimeoutMs: 1000 }, clock);
    limits.register('k', '1.1.1.1');

    clock.set(1000); // exactly at the budget
    ok(limits.sweep().length === 0,
      'handshake_timeout does not fire at exactly the budget');

    clock.set(1001); // one tick past
    const doomed = limits.sweep();
    ok(doomed.length === 1 && doomed[0].reason === 'handshake_timeout',
      'handshake_timeout fires one tick after the budget');

    // sweep reports, it does not release
    ok(limits.connectionsFrom('1.1.1.1') === 1,
      'sweep does not release the connection it reports');
    ok(limits.pendingCount === 1, 'the pending slot is still held after sweep');
    limits.release('k');
    ok(limits.connectionsFrom('1.1.1.1') === 0,
      'the caller releasing it afterward is what actually frees the slot');
  }

  // ---- idle timeout: same boundary discipline, for a greeted connection
  {
    const clock = makeClock(0);
    const limits = freshLimits({ idleTimeoutMs: 5000 }, clock);
    limits.register('k', '2.2.2.2');
    limits.markGreeted('k'); // lastActivity = 0

    clock.set(5000);
    ok(limits.sweep().length === 0, 'idle_timeout does not fire at exactly the budget');
    clock.set(5001);
    const doomed = limits.sweep();
    ok(doomed.length === 1 && doomed[0].reason === 'idle_timeout',
      'idle_timeout fires one tick after the budget');
  }

  // ---- a greeted, active connection is never swept
  {
    const clock = makeClock(0);
    const limits = freshLimits(
      { idleTimeoutMs: 5000, handshakeTimeoutMs: 1000 }, clock);
    limits.register('k', '3.3.3.3');
    limits.markGreeted('k');

    for (let i = 0; i < 10; i++) {
      clock.advance(4000); // always well under the 5000ms idle budget
      limits.noteActivity('k', { completedLine: true });
      ok(limits.sweep().length === 0,
        'a connection kept active never gets swept, however long it runs');
    }
  }

  // ---- an ungreeted connection is judged only on the handshake budget,
  // never on the slowloris partial-line clock -- even if it has one
  {
    const clock = makeClock(0);
    const limits = freshLimits(
      { handshakeTimeoutMs: 5000, partialLineTimeoutMs: 1000 }, clock);
    limits.register('k', '4.4.4.4');
    clock.set(500);
    limits.noteActivity('k', { bytes: 3 }); // starts a partial-line clock

    clock.set(2000); // past partialLineTimeoutMs, well under handshakeTimeoutMs
    ok(limits.sweep().length === 0,
      'an ungreeted connection is not swept as slowloris no matter its partial clock');

    clock.set(5001);
    const doomed = limits.sweep();
    ok(doomed.length === 1 && doomed[0].reason === 'handshake_timeout',
      'once ungreeted for too long, it is reported as handshake_timeout, not slowloris');
  }

  // ---- precedence: when a stalled partial line and idleness are both true
  // at once, slowloris is reported, not idle_timeout
  {
    const clock = makeClock(0);
    const limits = freshLimits(
      { handshakeTimeoutMs: 1000, partialLineTimeoutMs: 1000, idleTimeoutMs: 5000 },
      clock);
    limits.register('k', '5.5.5.5');
    limits.markGreeted('k');
    limits.noteActivity('k', { bytes: 1 }); // partialSince = 0, lastActivity = 0

    clock.set(5001); // both partialLineTimeoutMs and idleTimeoutMs have elapsed
    const doomed = limits.sweep();
    ok(doomed.length === 1 && doomed[0].reason === 'slowloris',
      'with both conditions true, slowloris is reported, not idle_timeout');
  }

  // ---- completedLine clears the partial clock, so a completed line
  // followed by silence is judged as idle, not slowloris
  {
    const clock = makeClock(0);
    // idleTimeoutMs has a documented floor of 5000ms (BOUNDS.idleTimeoutMs),
    // so this stays at the floor rather than an arbitrary smaller number.
    const limits = freshLimits(
      { partialLineTimeoutMs: 1000, idleTimeoutMs: 5000 }, clock);
    limits.register('k', '6.6.6.6');
    limits.markGreeted('k');
    limits.noteActivity('k', { bytes: 1 }); // partialSince = 0
    clock.set(500);
    limits.noteActivity('k', { completedLine: true }); // clears partialSince, lastActivity = 500

    clock.set(5600); // past partialLineTimeoutMs from t=0, past idleTimeoutMs from t=500
    const doomed = limits.sweep();
    ok(doomed.length === 1 && doomed[0].reason === 'idle_timeout',
      'a completed line clears the partial clock, so this is judged as idle_timeout');
  }
}

// --------------------------------------------------------------- slowloris

function testSlowloris() {
  const clock = makeClock(0);
  const limits = freshLimits({ partialLineTimeoutMs: 1000 }, clock);
  limits.register('k', '7.7.7.7');
  limits.markGreeted('k');

  // bytes with no completed line start the clock
  limits.noteActivity('k', { bytes: 1 }); // partialSince = 0
  clock.set(400);
  ok(limits.sweep().length === 0, 'not yet stalled long enough');

  // dribbling more bytes does not reset the partial-line clock -- only a
  // completed line does. A connection dribbling forever is still eventually
  // swept.
  clock.set(700);
  limits.noteActivity('k', { bytes: 1 }); // still no completed line
  ok(limits.sweep().length === 0, 'still under the budget, measured from the first byte');

  clock.set(1001); // > 1000ms since partialSince (t=0), despite dribbling in between
  const doomed = limits.sweep();
  ok(doomed.length === 1 && doomed[0].reason === 'slowloris',
    'a connection dribbling bytes forever without a completed line is eventually swept');

  // a completed line clears it
  const clock2 = makeClock(0);
  const limits2 = freshLimits({ partialLineTimeoutMs: 1000 }, clock2);
  limits2.register('k2', '7.7.7.8');
  limits2.markGreeted('k2');
  limits2.noteActivity('k2', { bytes: 1 });
  clock2.set(500);
  limits2.noteActivity('k2', { completedLine: true });
  clock2.set(1600); // past the original partial budget
  ok(limits2.sweep().length === 0,
    'a completed line clears the partial clock, so slowloris no longer fires from it');
}

// ------------------------------------------------------------ writeAllowed

function testWriteAllowed() {
  const clock = makeClock();
  const limits = freshLimits({ maxWriteBufferBytes: 4096 }, clock);

  ok(limits.writeAllowed('unknown-key', 4096) === true,
    'writeAllowed does not require a registered key: true at the cap');
  ok(limits.writeAllowed('unknown-key', 4097) === false,
    'one byte over the cap is disallowed');
  ok(limits.writeAllowed('unknown-key', 0) === true, 'zero buffered is allowed');
  ok(limits.writeAllowed('unknown-key', Number.NaN) === true,
    'a non-finite writableLength (NaN) does not kill the connection');
  ok(limits.writeAllowed('unknown-key', Infinity) === true,
    'a non-finite writableLength (Infinity) does not kill the connection');
  ok(limits.writeAllowed('unknown-key', -Infinity) === true,
    'a non-finite writableLength (-Infinity) does not kill the connection');
}

// ---------------------------------------------------------------- release

function testReleaseIdempotent() {
  const clock = makeClock();
  const limits = freshLimits({ perIpConnections: 1, connectBurst: 100 }, clock);

  limits.register('k', '10.0.0.1');
  ok(limits.connectionsFrom('10.0.0.1') === 1, 'registered once, counted once');

  ok(limits.release('k') === true, 'first release reports success');
  ok(limits.connectionsFrom('10.0.0.1') === 0, 'count drops to zero');

  ok(limits.release('k') === false,
    'a second release of the same key reports failure (nothing to release)');
  ok(limits.connectionsFrom('10.0.0.1') === 0,
    'and does not drive the count negative');

  // prove it by exhausting the cap afterward: if the double release had
  // decremented twice, the count would sit at -1 and never trip per_ip.
  ok(limits.admit('10.0.0.1').ok, 'a fresh admission succeeds');
  limits.register('k2', '10.0.0.1'); // count = 1, at the cap (perIpConnections: 1)
  const second = limits.admit('10.0.0.1');
  ok(second.ok === false && second.reason === 'per_ip',
    'the per-ip cap still trips correctly -- the earlier double release left no residue');
}

// ------------------------------------------------------------- clamping

function testClamping() {
  // defaults with no options at all
  {
    const limits = new Limits();
    for (const name of Object.keys(DEFAULTS)) {
      ok(limits[name] === DEFAULTS[name],
        `${name} falls back to its documented default with no options object`);
    }
  }

  // every bound: below min clamps to min, above max clamps to max, and a
  // non-finite value falls back to the default -- per the bounds table
  // documented at the top of limits.js
  for (const name of Object.keys(BOUNDS)) {
    const [min, max] = BOUNDS[name];

    const low = new Limits({ [name]: min - 1000000 });
    ok(low[name] === min, `${name} below its floor clamps up to ${min}`);

    const high = new Limits({ [name]: max + 1000000 });
    ok(high[name] === max, `${name} above its ceiling clamps down to ${max}`);

    const nan = new Limits({ [name]: Number.NaN });
    ok(nan[name] === DEFAULTS[name], `${name} set to NaN falls back to the default`);

    const notNumber = new Limits({ [name]: 'not-a-number' });
    ok(notNumber[name] === DEFAULTS[name],
      `${name} set to a non-numeric string falls back to the default`);

    const atMin = new Limits({ [name]: min });
    ok(atMin[name] === min, `${name} exactly at its floor is accepted unchanged`);

    const atMax = new Limits({ [name]: max });
    ok(atMax[name] === max, `${name} exactly at its ceiling is accepted unchanged`);
  }

  // pins the documented table itself against silent drift
  ok(BOUNDS.perIpConnections[0] === 1 && BOUNDS.perIpConnections[1] === 256,
    'perIpConnections bounds match the documented table');
  ok(BOUNDS.connectBurst[0] === 1 && BOUNDS.connectBurst[1] === 1000,
    'connectBurst bounds match the documented table');
  ok(BOUNDS.connectPerMinute[0] === 1 && BOUNDS.connectPerMinute[1] === 60000,
    'connectPerMinute bounds match the documented table');
  ok(BOUNDS.maxPending[0] === 1 && BOUNDS.maxPending[1] === 1024,
    'maxPending bounds match the documented table');
  ok(BOUNDS.handshakeTimeoutMs[0] === 1000 && BOUNDS.handshakeTimeoutMs[1] === 300000,
    'handshakeTimeoutMs bounds match the documented table');
  ok(BOUNDS.idleTimeoutMs[0] === 5000 && BOUNDS.idleTimeoutMs[1] === 3600000,
    'idleTimeoutMs bounds match the documented table');
  ok(BOUNDS.partialLineTimeoutMs[0] === 1000 && BOUNDS.partialLineTimeoutMs[1] === 300000,
    'partialLineTimeoutMs bounds match the documented table');
  ok(BOUNDS.maxWriteBufferBytes[0] === 4096 && BOUNDS.maxWriteBufferBytes[1] === 67108864,
    'maxWriteBufferBytes bounds match the documented table');
}

// --------------------------------------------------------- verdict objects

function testVerdictSingletons() {
  const clock = makeClock();
  const limits = freshLimits({ connectBurst: 1, perIpConnections: 100 }, clock);

  const okVerdict1 = limits.admit('11.0.0.1'); // spends 11.0.0.1's one-token burst
  const okVerdict2 = limits.admit('11.0.0.2'); // a different, unrelated address
  ok(okVerdict1 === okVerdict2,
    'two independent OK verdicts are the exact same frozen object by reference');
  ok(Object.isFrozen(okVerdict1), 'the OK verdict is frozen');

  // 11.0.0.1's burst (1) is already spent, so both of these read rate
  const rate1 = limits.admit('11.0.0.1');
  const rate2 = limits.admit('11.0.0.1');
  ok(rate1.reason === 'rate' && rate2.reason === 'rate',
    'repeated over-rate calls for the same exhausted bucket both read rate');
  ok(rate1 === rate2, 'and are the same frozen singleton by reference');
  ok(Object.isFrozen(rate1), 'the rate verdict is frozen');

  // sanity: a fresh, unrelated address is unaffected by 11.0.0.1's bucket
  ok(limits.admit('11.0.0.3').ok, 'an unrelated fresh address still admits cleanly');

  // frozen means an assignment attempt throws under this file's strict mode
  let threw = false;
  try {
    rate1.reason = 'tampered';
  } catch (err) {
    threw = true;
  }
  ok(threw, 'mutating a frozen verdict throws in strict mode');
}

// ------------------------------------------------------ misc documented behavior

function testRegisterTwiceAbsorbed() {
  const clock = makeClock();
  const limits = freshLimits({ perIpConnections: 1 }, clock);

  limits.register('k', '12.0.0.1');
  limits.register('k', '12.0.0.1'); // caller bug, not a security event
  ok(limits.connectionsFrom('12.0.0.1') === 1,
    'registering the same key twice charges the address only once');
  ok(limits.pendingCount === 1, 'and only counts as one pending slot');
}

function testNoteActivityUnknownKey() {
  const clock = makeClock();
  const limits = freshLimits({}, clock);
  ok(limits.noteActivity('never-registered', { bytes: 5 }) === false,
    'noteActivity on an unknown key reports failure rather than throwing');
}

function testBansAndAllowlistAcceptNonArray() {
  const clock = makeClock();
  const limits = freshLimits({}, clock);

  limits.setBans(null);
  ok(limits.admit('13.0.0.1').ok,
    'setBans(null) does not throw and leaves nobody banned');

  limits.setAllowlist(undefined);
  ok(limits.admit('13.0.0.2').ok,
    'setAllowlist(undefined) does not throw and leaves the allowlist empty (everyone)');
}

// ---------------------------------------------------- bucket pruning (white-box)
//
// This pins a specific documented internal decision -- "bucket pruning is
// interval-gated" -- by reading the internal `_buckets`/`_prunedAt` state.
// That is a deliberate exception to the black-box discipline used
// everywhere else in this file: pruning a full bucket is *designed* to be
// externally invisible (a pruned bucket behaves identically to a bucket that
// never existed, per the comment in limits.js), so there is no admit()/
// sweep()-observable consequence to assert against. The memory-bounds test
// below keeps to the black-box rule and explains why.

function testBucketPruningIntervalGated() {
  const clock = makeClock(0);
  const limits = freshLimits({ connectBurst: 10, connectPerMinute: 60 }, clock);

  limits.admit('20.0.0.1');
  const prunedAtAfterFirst = limits._prunedAt;
  ok(prunedAtAfterFirst === 0, 'the very first admit call runs an (empty) prune');

  clock.set(1000); // well within the 30s prune interval
  limits.admit('20.0.0.2');
  ok(limits._prunedAt === prunedAtAfterFirst,
    'a second admit inside the prune interval does not re-run the prune');

  clock.set(30001); // past the interval
  limits.admit('20.0.0.3');
  ok(limits._prunedAt === 30001,
    'once the interval has elapsed, the next admit runs the prune again');
}

// -------------------------------------------------------------- memory bounds
//
// The public surface of Limits -- `admit`, `register`, `release`,
// `pendingCount`, `connectionsFrom`, `stats()` -- exposes connection and
// per-IP bookkeeping, but nothing about the rate-limiter's bucket map. And
// unlike a leaked connection count, an unpruned bucket has no correctness
// consequence a caller can observe: a bucket that refilled to capacity and
// was never removed behaves *identically* to one that was removed and
// recreated fresh (a full bucket "carries no information", per the comment
// in limits.js), so admit()'s return values cannot distinguish "pruned
// correctly" from "leaking silently". There is, honestly, no black-box way
// to assert the bucket map's cardinality without reading the private
// `_buckets` field, which this test deliberately does not do (see the
// pruning test above for the one place this file makes that exception, for
// a decision that genuinely has no other observable).
//
// The closest available external proxy is operational: admitting a large,
// strictly-growing set of distinct addresses must keep working correctly
// (fresh addresses still get a full burst) and must not degrade, which is
// what a correctly bounded structure guarantees and an unbounded one (O(n)
// work per admit as the map grows without limit) would eventually fail at.
// The timing assertion below is intentionally very generous to avoid
// flakiness on a loaded machine -- it is a sanity check against
// catastrophic unbounded growth, not a precise bound on the internal map.

function testMemoryBoundsProxy() {
  const clock = makeClock(0); // frozen: no time-based refill muddies the count
  const limits = freshLimits(
    // maxPending is irrelevant here: this test never calls register(), so
    // `_pending` never moves off zero regardless of the configured cap.
    { connectBurst: 2, connectPerMinute: 60, perIpConnections: 1000 },
    clock);

  const ADDRESSES = 20000; // comfortably past the internal MAX_BUCKETS (4096)

  const ipFor = (i) =>
    `${10 + (i >>> 24 & 255)}.${i >>> 16 & 255}.${i >>> 8 & 255}.${i & 255}`;

  // Every address here is brand new, so every one of these must succeed --
  // that is true whether or not old buckets were ever pruned, which is
  // exactly why this cannot prove boundedness on its own; it proves
  // correctness survives at scale, which is the property we can observe.
  let allFresh = true;
  const start = process.hrtime.bigint();
  for (let i = 0; i < ADDRESSES; i++) {
    const verdict = limits.admit(ipFor(i));
    if (!verdict.ok) allFresh = false;
  }
  const elapsedMs = Number(process.hrtime.bigint() - start) / 1e6;

  ok(allFresh,
    `cycling ${ADDRESSES} distinct addresses through admit() never misfires ` +
    'on a fresh address, however many have come before it');

  // Generous: this would need to be off by orders of magnitude to trip on
  // any real machine. It exists only to catch a genuinely unbounded
  // structure making each successive call slower without limit.
  ok(elapsedMs < 5000,
    `admitting ${ADDRESSES} distinct addresses completes in bounded time ` +
    `(${elapsedMs.toFixed(1)}ms) rather than degrading; this is the closest ` +
    'externally observable proxy for the internal map staying bounded -- ' +
    'see the comment above this test for why a direct assertion is not possible');
}

// ------------------------------------------------------------------- main

function main() {
  testNormalizeIp();
  testPerIpCap();
  testTokenBucket();
  testAdmitOrdering();
  testAllowlist();
  testMaxPending();
  testSweep();
  testSlowloris();
  testWriteAllowed();
  testReleaseIdempotent();
  testClamping();
  testVerdictSingletons();
  testRegisterTwiceAbsorbed();
  testNoteActivityUnknownKey();
  testBansAndAllowlistAcceptNonArray();
  testBucketPruningIntervalGated();
  testMemoryBoundsProxy();

  console.log(`\n  ${passed}/${passed} checks passed  (limits)\n`);
}

try {
  main();
} catch (err) {
  console.error('\n  ' + (err && err.stack || err) + '\n');
  process.exit(1);
}
