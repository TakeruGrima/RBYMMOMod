#!/usr/bin/env node
'use strict';

/*
 * End-to-end test for the hardened hub, over real TCP sockets.
 *
 * hub.test.js drives the unauthenticated relay -- roster, movement, chat
 * scopes, sessions -- against `node hub.js` as a child process. This file
 * drives everything Wave 2 (plan §3.1-3.6, `docs/plans/self-hosting-server-app.md`)
 * built around that relay: the HMAC challenge/response handshake, refusal
 * uniformity, replay resistance, the §3.6 seat-at-hello fix, per-IP and ban
 * enforcement, the handshake timeout, invite use-counting, and graceful
 * shutdown.
 *
 * Same idiom as hub.test.js on purpose: the throwing `ok()`, the
 * promise-based `Client` wrapper with `expect`/`expectSilence`, one scenario
 * function per behaviour, a final pass count. No test framework, no
 * dependencies beyond Node core.
 *
 * Most scenarios start `lib/server.js` in-process on an ephemeral port
 * (`listen.port: 0`) -- faster and immune to port collisions with any other
 * suite running alongside this one. Only the SIGTERM scenario spawns a real
 * child process, because signal handling cannot be exercised any other way;
 * that one child claims a fixed, pid-derived port picked to sit clear of the
 * range hub.test.js uses (PORT..PORT+2, i.e. 7801 + pid%200 .. +2).
 *
 * Run: node server/server.test.js
 */

const net = require('net');
const os = require('node:os');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawn } = require('child_process');
const assert = require('assert');

const { start } = require('./lib/server.js');

const CHILD_PORT = 8801 + (process.pid % 200); // clear of hub.test.js's 7801-8002
const SERVER_JS_PATH = path.join(__dirname, 'lib', 'server.js');

let passed = 0;
const ok = (cond, label) => {
  if (!cond) throw new Error('FAIL: ' + label);
  passed++;
};

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function waitFor(predicate, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (predicate()) return true;
    await sleep(50);
  }
  return false;
}

// ------------------------------------------------------------------ Client
// Copied verbatim in shape from hub.test.js: a thin promise-based wrapper
// around a real socket speaking the mod's newline-JSON.

class Client {
  constructor(port) {
    this.socket = net.createConnection({ port, host: '127.0.0.1' });
    this.socket.setEncoding('utf8');
    this.buffer = '';
    this.inbox = [];
    this.socket.on('data', (chunk) => {
      this.buffer += chunk;
      let i;
      while ((i = this.buffer.indexOf('\n')) >= 0) {
        const line = this.buffer.slice(0, i);
        this.buffer = this.buffer.slice(i + 1);
        if (line) this.inbox.push(JSON.parse(line));
      }
    });
  }
  ready() {
    return new Promise((resolve, reject) => {
      this.socket.once('connect', resolve);
      this.socket.once('error', reject);
    });
  }
  send(type, payload) {
    this.socket.write(JSON.stringify(Object.assign({}, payload, { type })) + '\n');
  }
  async expect(type, timeoutMs = 1500) {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      const index = this.inbox.findIndex((m) => m.type === type);
      if (index >= 0) return this.inbox.splice(index, 1)[0];
      await sleep(10);
    }
    throw new Error(`timed out waiting for ${type}; saw ` +
      JSON.stringify(this.inbox.map((m) => m.type)));
  }
  async expectSilence(type, windowMs = 300) {
    const deadline = Date.now() + windowMs;
    while (Date.now() < deadline) {
      if (this.inbox.some((m) => m.type === type)) {
        throw new Error(`unexpectedly received ${type}`);
      }
      await sleep(10);
    }
    return true;
  }
  close() { this.socket.destroy(); }
}

function rawConnect(port) {
  return new Promise((resolve, reject) => {
    const socket = net.createConnection({ port, host: '127.0.0.1' });
    socket.once('connect', () => resolve(socket));
    socket.once('error', reject);
  });
}

// -------------------------------------------------------------- HMAC, by hand
//
// The wire contract (server/lib/auth.js's header comment): key is the
// normalised join code as ASCII bytes, message is the nonce as its
// lowercase-hex ASCII *string*, response is 64 lowercase hex characters.
// Computed here with node:crypto directly -- never via auth.sign()/verify()
// -- so a bug in auth.js has an independent witness instead of grading its
// own homework.
function hmacHex(key, nonceHex) {
  return crypto.createHmac('sha256', Buffer.from(key, 'ascii'))
    .update(nonceHex, 'ascii')
    .digest('hex');
}

// Three join codes, hand-picked from the mod's Crockford-style alphabet
// (0-9, A-Z minus I L O U) so they are valid without going through
// auth.normalizeCode() at all -- stripping the dashes is the whole job.
const PRIMARY_CODE = 'ABCD-EFGH-JKMN-PQRS';
const PRIMARY_KEY = 'ABCDEFGHJKMNPQRS';
const EXPIRED_CODE = 'TVWX-YZ01-2345-6789';
const EXPIRED_KEY = 'TVWXYZ0123456789';
const REVOKED_CODE = 'GHJK-MNPQ-RSTV-WXYZ';
const REVOKED_KEY = 'GHJKMNPQRSTVWXYZ';

// ------------------------------------------------------------- server helper

const NULL_LOG = { debug() {}, info() {}, warn() {}, error() {} };

function baseConfig(overrides = {}) {
  const cfg = {
    version: 1,
    listen: { host: '127.0.0.1', port: 0 },
    maxPlayers: 4,
    auth: { required: false, credentials: [] },
    limits: {},
    bans: [],
    allowlist: [],
    network: { upnp: { enabled: false, leaseSeconds: 3600 } },
    log: { level: 'silent' },
  };
  return Object.assign({}, cfg, overrides, {
    listen: Object.assign({}, cfg.listen, overrides.listen),
    auth: Object.assign({}, cfg.auth, overrides.auth),
    limits: Object.assign({}, cfg.limits, overrides.limits),
  });
}

function startServer(overrides = {}, extra = {}) {
  return start(Object.assign({
    config: baseConfig(overrides),
    log: NULL_LOG,
    handleSignals: false,
  }, extra));
}

// =========================================================================
// scenarios
// =========================================================================

// ------- the auth handshake: happy path, refusal uniformity, replay, edges

async function authHandshakeTest() {
  const handle = await startServer({
    auth: {
      required: true,
      credentials: [
        {
          id: 'primary', label: 'Primary', secret: PRIMARY_CODE,
          createdAt: new Date().toISOString(), expiresAt: null,
          maxUses: null, uses: 0, revoked: false,
        },
        {
          id: 'expired', label: 'Expired', secret: EXPIRED_CODE,
          createdAt: new Date().toISOString(),
          expiresAt: new Date(Date.now() - 60000).toISOString(),
          maxUses: null, uses: 0, revoked: false,
        },
        {
          id: 'revoked', label: 'Revoked', secret: REVOKED_CODE,
          createdAt: new Date().toISOString(), expiresAt: null,
          maxUses: null, uses: 0, revoked: true,
        },
      ],
    },
  });
  const port = handle.port;

  try {
    // ---- happy path
    const good = new Client(port);
    await good.ready();
    good.send('mmo.hello', { proto: 2, name: 'GOOD' });
    const challenge = await good.expect('mmo.challenge');
    ok(/^[0-9a-f]{32}$/.test(challenge.nonce),
      'the nonce is 32 lowercase hex characters');
    good.send('mmo.auth', { response: hmacHex(PRIMARY_KEY, challenge.nonce) });
    const welcome = await good.expect('mmo.welcome');
    ok(typeof welcome.id === 'string', 'a correctly-answered challenge is welcomed');
    good.close();

    // ---- wrong code
    const wrong = new Client(port);
    await wrong.ready();
    wrong.send('mmo.hello', { proto: 2, name: 'WRONG' });
    const wrongChallenge = await wrong.expect('mmo.challenge');
    wrong.send('mmo.auth', {
      response: hmacHex('ZZZZYYYYXXXXWWWW', wrongChallenge.nonce),
    });
    const wrongRefusal = await wrong.expect('mmo.error');
    wrong.close();

    // ---- a valid-but-expired code
    const expired = new Client(port);
    await expired.ready();
    expired.send('mmo.hello', { proto: 2, name: 'EXPIRED' });
    const expiredChallenge = await expired.expect('mmo.challenge');
    expired.send('mmo.auth', {
      response: hmacHex(EXPIRED_KEY, expiredChallenge.nonce),
    });
    const expiredRefusal = await expired.expect('mmo.error');
    expired.close();

    // ---- a valid-but-revoked code
    const revoked = new Client(port);
    await revoked.ready();
    revoked.send('mmo.hello', { proto: 2, name: 'REVOKED' });
    const revokedChallenge = await revoked.expect('mmo.challenge');
    revoked.send('mmo.auth', {
      response: hmacHex(REVOKED_KEY, revokedChallenge.nonce),
    });
    const revokedRefusal = await revoked.expect('mmo.error');
    revoked.close();

    ok(wrongRefusal.message === expiredRefusal.message,
      'a wrong code and an expired code produce the identical refusal sentence');
    ok(wrongRefusal.message === revokedRefusal.message,
      'a wrong code and a revoked code produce the identical refusal sentence');
    ok(typeof wrongRefusal.message === 'string' && wrongRefusal.message.length > 0,
      'the shared refusal sentence is not empty');

    // ---- replay: a captured (nonce, response) pair is worthless elsewhere
    const capture = new Client(port);
    await capture.ready();
    capture.send('mmo.hello', { proto: 2, name: 'CAPTURE' });
    const capturedChallenge = await capture.expect('mmo.challenge');
    const capturedResponse = hmacHex(PRIMARY_KEY, capturedChallenge.nonce);
    capture.close(); // never finishes its own handshake

    const replay = new Client(port);
    await replay.ready();
    replay.send('mmo.hello', { proto: 2, name: 'REPLAY' });
    const replayChallenge = await replay.expect('mmo.challenge');
    ok(replayChallenge.nonce !== capturedChallenge.nonce,
      'each connection is issued its own nonce');
    replay.send('mmo.auth', { response: capturedResponse });
    await replay.expect('mmo.error');
    ok(true, 'a captured response fails against a fresh connection\'s nonce');
    replay.close();

    // ---- a second mmo.auth on the same connection, after one was consumed
    const twice = new Client(port);
    await twice.ready();
    twice.send('mmo.hello', { proto: 2, name: 'TWICE' });
    const twiceChallenge = await twice.expect('mmo.challenge');
    const twiceResponse = hmacHex(PRIMARY_KEY, twiceChallenge.nonce);
    twice.send('mmo.auth', { response: twiceResponse });
    await twice.expect('mmo.welcome');
    // the nonce was already consumed by the line above; a second mmo.auth
    // must not be answered at all, success or failure
    twice.send('mmo.auth', { response: twiceResponse });
    await twice.expectSilence('mmo.welcome', 300);
    await twice.expectSilence('mmo.error', 50);
    ok(true, 'a second mmo.auth after the challenge was consumed draws no reply');
    twice.close();

    // ---- mmo.auth with no outstanding challenge at all
    const unsolicited = new Client(port);
    await unsolicited.ready();
    unsolicited.send('mmo.auth', { response: hmacHex(PRIMARY_KEY, '00'.repeat(16)) });
    await unsolicited.expectSilence('mmo.error', 300);
    await unsolicited.expectSilence('mmo.welcome', 50);
    // and the connection is still usable afterwards -- ignored, not spent
    unsolicited.send('mmo.hello', { proto: 2, name: 'LATER' });
    const laterChallenge = await unsolicited.expect('mmo.challenge');
    unsolicited.send('mmo.auth', {
      response: hmacHex(PRIMARY_KEY, laterChallenge.nonce),
    });
    await unsolicited.expect('mmo.welcome');
    ok(true, 'an unsolicited mmo.auth is ignored, not treated as a fatal error');
    unsolicited.close();
  } finally {
    await handle.close();
  }
}

// ------- auth off: byte-identical to the legacy no-auth handshake

async function authOffTest() {
  const handle = await startServer({ auth: { required: false, credentials: [] } });
  try {
    const client = new Client(handle.port);
    await client.ready();
    client.send('mmo.hello', { proto: 2, name: 'OPEN' });
    const welcome = await client.expect('mmo.welcome');
    ok(typeof welcome.id === 'string', 'auth off: hello leads straight to welcome');
    ok(Array.isArray(welcome.players), 'the welcome still carries a roster');
    ok(!client.inbox.some((m) => m.type === 'mmo.challenge'),
      'no challenge was ever sent when auth is off');
    client.close();
  } finally {
    await handle.close();
  }
}

// ------- the §3.6 regression: ungreeted sockets cannot lock out a real player

async function silentSocketsDoNotLockOutTest() {
  // perIpConnections defaults to maxPlayers (4), and every socket here comes
  // from the same loopback address -- raised so the scenario under test is
  // the seat-at-hello fix, not an incidental collision with the per-IP cap
  // (exercised on its own in perIpCapTest).
  const handle = await startServer({ maxPlayers: 4, limits: { perIpConnections: 10 } });
  const port = handle.port;
  const ghosts = [];
  try {
    // Fill exactly maxPlayers worth of connections that never say hello.
    // Before the §3.6 fix, hub.js charged a seat at accept, so four silent
    // sockets on a four-player hub locked out everyone else for
    // TIMEOUT_MS (45s). The fix charges a seat at hello instead.
    for (let i = 0; i < 4; i++) {
      ghosts.push(await rawConnect(port));
    }

    const late = new Client(port);
    await late.ready();
    late.send('mmo.hello', { proto: 2, name: 'LATE' });
    const welcome = await late.expect('mmo.welcome', 3000);
    ok(typeof welcome.id === 'string',
      'a real player still gets in with the cap full of silent sockets');
    ok(welcome.players.length === 0,
      'the silent sockets never appear as players either');
    late.close();
  } finally {
    for (const g of ghosts) g.destroy();
    await handle.close();
  }
}

// ------- the converse: a cap filled by *greeted* players refuses promptly

async function capFilledByGreetedPlayersTest() {
  // Five connections from the same loopback address; raised past the
  // default perIpConnections (4) so the refusal under test is the player
  // cap, not the per-IP cap (exercised on its own in perIpCapTest).
  const handle = await startServer({ maxPlayers: 4, limits: { perIpConnections: 10 } });
  const port = handle.port;
  const players = [];
  try {
    for (let i = 0; i < 4; i++) {
      const client = new Client(port);
      await client.ready();
      client.send('mmo.hello', { proto: 2, name: 'P' + i });
      await client.expect('mmo.welcome');
      players.push(client);
    }
    ok(players.length === 4, 'four players fill the default-sized hub');

    const fifth = new Client(port);
    await fifth.ready();
    const startedAt = Date.now();
    const refused = await fifth.expect('mmo.error', 2000);
    const elapsedMs = Date.now() - startedAt;
    ok(/full/i.test(refused.message), 'a full hub names itself full');
    ok(/4/.test(refused.message), 'and names the limit');
    ok(elapsedMs < 1000,
      'a hub already full of greeted players refuses immediately, not after a timeout');
    fifth.close();
  } finally {
    for (const p of players) p.close();
    await handle.close();
  }
}

// ------- per-IP cap

async function perIpCapTest() {
  const handle = await startServer({ limits: { perIpConnections: 2 } });
  const port = handle.port;
  const sockets = [];
  try {
    for (let i = 0; i < 2; i++) {
      sockets.push(await rawConnect(port));
    }
    const third = new Client(port);
    await third.ready();
    const refused = await third.expect('mmo.error');
    ok(/too many connections/i.test(refused.message),
      'a connection over the per-IP cap gets a message, not silence');
    ok(/2/.test(refused.message), 'and the message names the configured limit');
    third.close();
  } finally {
    for (const s of sockets) s.destroy();
    await handle.close();
  }
}

// ------- ban

async function banTest() {
  const handle = await startServer({});
  const port = handle.port;
  try {
    // admitted before the ban exists
    const before = new Client(port);
    await before.ready();
    before.send('mmo.hello', { proto: 2, name: 'BEFORE' });
    await before.expect('mmo.welcome');

    // setBans affects new admissions only -- ban after this one is already in
    handle.limits.setBans(['127.0.0.1']);

    const after = new Client(port);
    await after.ready();
    after.send('mmo.hello', { proto: 2, name: 'AFTER' });
    await after.expectSilence('mmo.welcome', 500);
    ok(true, 'a newly-banned address cannot join');

    // the connection admitted before the ban is untouched
    before.send('mmo.ping', {});
    await before.expect('mmo.pong');
    ok(true, 'setBans does not retroactively drop an already-admitted connection');

    before.close();
    after.close();
  } finally {
    await handle.close();
  }
}

// ------- handshake timeout

async function handshakeTimeoutTest() {
  const handle = await startServer({ limits: { handshakeTimeoutMs: 1000 } });
  const port = handle.port;
  const raw = await rawConnect(port);
  try {
    const closed = await new Promise((resolve) => {
      const timer = setTimeout(() => resolve(false), 3000);
      raw.once('close', () => { clearTimeout(timer); resolve(true); });
    });
    ok(closed, 'a connection that never speaks is dropped after handshakeTimeoutMs');
  } finally {
    raw.destroy();
    await handle.close();
  }
}

// ------- invite --uses: admits exactly maxUses clients, persists the count

async function inviteUsesPersistTest() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'rby-mmo-server-test-'));
  const configPath = path.join(dir, 'config.json');
  const code = 'JKMN-PQRS-TVWX-YZ23';
  const key = code.replace(/-/g, '');

  const cfg = baseConfig({
    auth: {
      required: true,
      credentials: [{
        id: 'limited', label: 'One use', secret: code,
        createdAt: new Date().toISOString(), expiresAt: null,
        maxUses: 1, uses: 0, revoked: false,
      }],
    },
  });
  fs.writeFileSync(configPath, JSON.stringify(cfg, null, 2), { mode: 0o600 });

  try {
    const handle = await start({
      config: cfg, log: NULL_LOG, configPath, handleSignals: false,
    });
    const port = handle.port;
    try {
      const first = new Client(port);
      await first.ready();
      first.send('mmo.hello', { proto: 2, name: 'FIRST' });
      const firstChallenge = await first.expect('mmo.challenge');
      first.send('mmo.auth', { response: hmacHex(key, firstChallenge.nonce) });
      await first.expect('mmo.welcome');

      const second = new Client(port);
      await second.ready();
      second.send('mmo.hello', { proto: 2, name: 'SECOND' });
      const secondChallenge = await second.expect('mmo.challenge');
      second.send('mmo.auth', { response: hmacHex(key, secondChallenge.nonce) });
      await second.expect('mmo.error');
      ok(true, 'a maxUses:1 credential admits exactly one client');
      second.close();

      // the write is coalesced on a ~1s timer -- poll rather than assert
      // instantly
      const persisted = await waitFor(() => {
        try {
          const onDisk = JSON.parse(fs.readFileSync(configPath, 'utf8'));
          return onDisk.auth.credentials[0].uses === 1;
        } catch (err) {
          return false;
        }
      }, 3000);
      ok(persisted, 'the use count reaches disk within the coalescing window');

      first.close();
    } finally {
      await handle.close();
    }
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

// ------- and the converse: no configPath, no write, ever

async function inviteUsesNoWriteWithoutConfigPathTest() {
  const code = 'PQRS-TVWX-YZ23-4567';
  const key = code.replace(/-/g, '');
  const cfg = baseConfig({
    auth: {
      required: true,
      credentials: [{
        id: 'ephemeral', label: 'No file', secret: code,
        createdAt: new Date().toISOString(), expiresAt: null,
        maxUses: null, uses: 0, revoked: false,
      }],
    },
  });

  // No configPath is passed to start() below -- this is the hub.js shim's
  // world (no config, nothing that outlives the process). Spy on
  // fs.writeFileSync for the duration to prove nothing tries to persist.
  const originalWrite = fs.writeFileSync;
  let writeCalls = 0;
  fs.writeFileSync = function spy(...args) {
    writeCalls += 1;
    return originalWrite.apply(fs, args);
  };

  try {
    const handle = await start({ config: cfg, log: NULL_LOG, handleSignals: false });
    try {
      const client = new Client(handle.port);
      await client.ready();
      client.send('mmo.hello', { proto: 2, name: 'EPHEMERAL' });
      const challenge = await client.expect('mmo.challenge');
      client.send('mmo.auth', { response: hmacHex(key, challenge.nonce) });
      await client.expect('mmo.welcome');
      // past the ~1s coalescing window a persisted write would have used
      await sleep(1300);
      ok(writeCalls === 0,
        'with no configPath, a credential use is never written to disk');
      client.close();
    } finally {
      await handle.close();
    }
  } finally {
    fs.writeFileSync = originalWrite;
  }
}

// ------- graceful shutdown: in-process close()

async function gracefulShutdownInProcessTest() {
  const handle = await startServer({});
  const client = new Client(handle.port);
  try {
    await client.ready();
    client.send('mmo.hello', { proto: 2, name: 'LEAVER' });
    await client.expect('mmo.welcome');

    const closing = handle.close();
    const goodbye = await client.expect('mmo.error', 2000);
    ok(/shutting down/i.test(goodbye.message),
      'a connected client is told the hub is shutting down');
    await closing;
  } finally {
    client.close();
  }
}

// ------- graceful shutdown: SIGTERM against a real child process
//
// The only honest way to exercise signal handling: an in-process start()
// with handleSignals left at its default (true) so the harness's own
// SIGTERM/SIGINT are not the ones under test.

function childHubScript(port) {
  const serverPath = JSON.stringify(SERVER_JS_PATH);
  return [
    "'use strict';",
    `const { start } = require(${serverPath});`,
    'start({',
    '  config: {',
    `    listen: { host: '127.0.0.1', port: ${port} },`,
    '    maxPlayers: 4,',
    '    auth: { required: false, credentials: [] },',
    '    limits: {},',
    '    bans: [],',
    '    allowlist: [],',
    '  },',
    '  log: { debug(){}, info(){}, warn(){}, error(){} },',
    '}).then(() => {',
    "  process.stdout.write('listening\\n');",
    '}).catch((err) => {',
    "  process.stderr.write('start failed: ' + err.message + '\\n');",
    '  process.exit(1);',
    '});',
  ].join('\n');
}

function waitForListening(child, timeoutMs = 5000) {
  return new Promise((resolve, reject) => {
    let settled = false;
    const cleanup = () => {
      clearTimeout(timer);
      child.stdout.removeListener('data', onData);
      child.removeListener('exit', onExit);
    };
    const onData = (chunk) => {
      if (settled || !String(chunk).includes('listening')) return;
      settled = true;
      cleanup();
      resolve();
    };
    const onExit = (code) => {
      if (settled) return;
      settled = true;
      cleanup();
      reject(new Error(`child hub exited early (code ${code})`));
    };
    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      cleanup();
      reject(new Error('child hub never printed "listening"'));
    }, timeoutMs);
    child.stdout.on('data', onData);
    child.once('exit', onExit);
  });
}

async function gracefulShutdownSigtermTest() {
  const child = spawn(process.execPath, ['-e', childHubScript(CHILD_PORT)],
    { stdio: 'pipe' });
  const stderrChunks = [];
  child.stderr.on('data', (d) => stderrChunks.push(d));

  try {
    await waitForListening(child);

    const client = new Client(CHILD_PORT);
    await client.ready();
    client.send('mmo.hello', { proto: 2, name: 'SIGTERMEE' });
    await client.expect('mmo.welcome');

    const exitPromise = new Promise((resolve) => child.once('exit', resolve));
    child.kill('SIGTERM');

    const goodbye = await client.expect('mmo.error', 3000);
    ok(/shutting down/i.test(goodbye.message),
      'SIGTERM produces the same goodbye as an in-process close()');

    const exitCode = await exitPromise;
    ok(exitCode === 0,
      'the process exits cleanly (code 0) after handling SIGTERM: ' +
      Buffer.concat(stderrChunks).toString());

    client.close();
  } finally {
    if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL');
  }
}

// =========================================================================
// driver
// =========================================================================

async function main() {
  await authHandshakeTest();
  await authOffTest();
  await silentSocketsDoNotLockOutTest();
  await capFilledByGreetedPlayersTest();
  await perIpCapTest();
  await banTest();
  await handshakeTimeoutTest();
  await inviteUsesPersistTest();
  await inviteUsesNoWriteWithoutConfigPathTest();
  await gracefulShutdownInProcessTest();
  await gracefulShutdownSigtermTest();

  console.log(`\n  ${passed}/${passed} checks passed  (server)\n`);
}

main().catch((err) => {
  console.error('\n  ' + (err && err.stack || err) + '\n');
  process.exit(1);
});
