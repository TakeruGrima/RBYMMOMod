#!/usr/bin/env node
'use strict';

/*
 * Test for the hosting CLI -- the one place a host is supposed to be able to
 * configure anything (`server/lib/cli.js`). This is the suite that has to
 * prove the central claim: every setting is reachable through the software,
 * and secrets are handled carefully.
 *
 * `run(argv, io)` never touches process.exit or process.stdout directly, so
 * everything here drives it in-process with captured streams pointed at a
 * scratch directory -- no shell, no real config.json, no real terminal.
 * `server/bin/rby-mmo-hub.js` is spawned exactly once, at the bottom, purely
 * to prove the shim maps the code `run()` returns onto the real process exit
 * status; every other assertion goes through `cli.run()` directly.
 *
 * Same idiom as server/hub.test.js: no test framework, no dependencies, a
 * throwing ok(), scenario functions, a final pass count. Works both as
 * `node server/cli.test.js` and under `node --test` (server/package.json's
 * `test` script), which discovers *.test.js siblings and runs each as its
 * own process.
 *
 * Run: node server/cli.test.js
 */

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { Readable } = require('node:stream');
const { spawn } = require('node:child_process');

const cli = require('./lib/cli.js');
const config = require('./lib/config.js');
const auth = require('./lib/auth.js');
const limits = require('./lib/limits.js');

const BIN = path.join(__dirname, 'bin', 'rby-mmo-hub.js');

let passed = 0;
const ok = (cond, label) => {
  if (!cond) throw new Error('FAIL: ' + label);
  passed++;
};

// A code in its printed, dashed form: ABCD-EFGH-JKMN-PQRS.
const CODE_RE = /[0-9A-Z]{4}-[0-9A-Z]{4}-[0-9A-Z]{4}-[0-9A-Z]{4}/;

const EXCEPT_PATHS = new Set(['auth.credentials', 'version']);

// ------------------------------------------------------------- scratch area

const ROOT = fs.mkdtempSync(path.join(os.tmpdir(), 'rby-mmo-cli-test-'));
let scratchCount = 0;
function scratchDir(label) {
  const dir = path.join(ROOT, `${String(++scratchCount).padStart(2, '0')}-${label}`);
  fs.mkdirSync(dir, { recursive: true });
  return dir;
}

function cleanEnv() {
  // A real shell may already export RBY_MMO_* variables; scrub them so every
  // scenario starts from a known, empty environment and opts in explicitly.
  const env = {};
  for (const [key, value] of Object.entries(process.env)) {
    if (key.startsWith('RBY_MMO_')) continue;
    env[key] = value;
  }
  return env;
}

// A minimal writable sink: not a real stream, just something with a
// synchronous write() and a no-op on()/once() so cli.js's quiet(stream) call
// (`stream.on('error', ...)`) has something harmless to call.
function makeSink() {
  let text = '';
  const stream = {
    write(chunk) { text += String(chunk); return true; },
    on() { return stream; },
    once() { return stream; },
  };
  return { stream, read: () => text };
}

// Used whenever a scenario does not care about stdin (--yes, or any verb
// that never opens readline). Real interactivity is exercised separately,
// against a real stream, in the "scriptable init" scenario below.
const FAKE_STDIN = { on() {}, once() {}, pause() {}, resume() {}, removeListener() {} };

// A stdin that is already at EOF -- the shape `docker run` (without -t) and
// CI hand a process: readable, but with nothing coming and nothing to wait
// for.
function endedStdin() {
  const r = new Readable({ read() {} });
  r.push(null);
  return r;
}

async function runCli(argv, opts = {}) {
  const outSink = makeSink();
  const errSink = makeSink();
  const io = {
    stdout: outSink.stream,
    stderr: errSink.stream,
    stdin: opts.stdin || FAKE_STDIN,
    env: opts.env || cleanEnv(),
    cwd: opts.cwd || ROOT,
  };
  const code = await cli.run(argv, io);
  return { code, stdout: outSink.read(), stderr: errSink.read() };
}

function withTimeout(promise, ms, label) {
  let timer;
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error(`timed out after ${ms}ms waiting for: ${label}`)), ms);
  });
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timer));
}

function readConfigFile(file) {
  return JSON.parse(fs.readFileSync(file, 'utf8'));
}

function fileMode(file) {
  return fs.statSync(file).mode & 0o777;
}

function countMatches(haystack, re) {
  const matches = haystack.match(new RegExp(re.source, 'gm'));
  return matches ? matches.length : 0;
}

function same(a, b) {
  return JSON.stringify(a) === JSON.stringify(b);
}

function spawnCli(args, opts = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [BIN, ...args], {
      stdio: 'ignore',
      env: opts.env || cleanEnv(),
      cwd: opts.cwd || ROOT,
    });
    child.on('error', reject);
    child.on('close', (code) => resolve(code));
  });
}

// =====================================================================
// init
// =====================================================================

async function initScenarios() {
  const dir = scratchDir('init');
  const file = path.join(dir, 'config.json');

  // --- writes the file at mode 0600, prints a join code exactly once, and
  //     the printed code round-trips against what is stored on disk
  const first = await runCli(['init', '--yes', '--config', file], { cwd: dir });
  ok(first.code === cli.OK, 'init --yes succeeds');
  ok(fs.existsSync(file), 'and writes the config file');
  ok(fileMode(file) === 0o600, 'the config file is written mode 0600');

  const printedCount = countMatches(first.stdout, CODE_RE);
  ok(printedCount === 1, `the join code is printed exactly once (saw ${printedCount})`);
  const printedCode = first.stdout.match(CODE_RE)[0];

  const onDisk = readConfigFile(file);
  ok(onDisk.auth.credentials.length === 1, 'a primary credential is written');
  ok(onDisk.auth.credentials[0].id === 'primary', 'the first credential is named primary');
  ok(auth.normalizeCode(printedCode) === auth.normalizeCode(onDisk.auth.credentials[0].secret),
    'the printed code normalises to the same key as the credential stored in the file');

  // --- re-running without --force refuses and names the file
  const again = await runCli(['init', '--yes', '--config', file], { cwd: dir });
  ok(again.code === cli.ERROR, 'init without --force on an existing config is a runtime error');
  ok(again.stderr.includes(file), 'the refusal names the config file');
  ok(/--force/.test(again.stderr), 'and names the escape hatch');
  ok(readConfigFile(file).auth.credentials[0].secret === onDisk.auth.credentials[0].secret,
    'the existing config is untouched by the refused run');

  // --- with --force it overwrites (and actually rotates the code)
  const forced = await runCli(['init', '--yes', '--force', '--config', file], { cwd: dir });
  ok(forced.code === cli.OK, 'init --force overwrites');
  ok(countMatches(forced.stdout, CODE_RE) === 1, 'the forced run also prints exactly one code');
  const secondOnDisk = readConfigFile(file);
  ok(secondOnDisk.auth.credentials[0].secret !== onDisk.auth.credentials[0].secret,
    '--force writes a fresh join code, not the old one');

  // --- the default is auth ON (so a careless first run is not an open hub)
  ok(config.DEFAULTS.auth.required === true, 'the built-in default requires a join code');
  ok(secondOnDisk.auth.required === true, 'a plain init --yes leaves auth on');

  // --- --no-auth turns it off, explicitly
  const noAuthFile = path.join(dir, 'config-no-auth.json');
  const noAuth = await runCli(['init', '--yes', '--no-auth', '--config', noAuthFile], { cwd: dir });
  ok(noAuth.code === cli.OK, 'init --yes --no-auth succeeds');
  const noAuthOnDisk = readConfigFile(noAuthFile);
  ok(noAuthOnDisk.auth.required === false, '--no-auth writes auth.required: false');
  ok(noAuthOnDisk.auth.credentials.length === 0, 'and mints no credential for it');

  // --- init is scriptable: no TTY, no stdin (docker run without -t, CI) --
  //     it must terminate, not hang forever on rl.question()
  const scriptedFile = path.join(dir, 'config-scripted.json');
  const scripted = await withTimeout(
    runCli(['init', '--config', scriptedFile], { cwd: dir, stdin: endedStdin() }),
    5000,
    'init with a closed stdin');
  ok(scripted.code === cli.OK, 'init on a closed stdin still terminates and succeeds');
  ok(fs.existsSync(scriptedFile), 'and still writes a config file, on the defaults');
  ok(/input ended/i.test(scripted.stderr),
    'and says plainly that it took defaults because the input ended');
}

// =====================================================================
// every LEAF_PATHS entry is reachable through config set / config get
// =====================================================================

function testValueFor(dotted) {
  if (dotted in config.BOUNDS) {
    const [min, max] = config.BOUNDS[dotted];
    const value = Math.min(max, min + 1);
    return { raw: String(value), expected: value };
  }
  switch (dotted) {
    case 'listen.host': return { raw: '127.0.0.2', expected: '127.0.0.2' };
    case 'auth.required': return { raw: 'false', expected: false };
    case 'network.upnp.enabled': return { raw: 'true', expected: true };
    case 'log.level': return { raw: 'debug', expected: 'debug' };
    case 'bans': return { raw: '203.0.113.9', expected: [limits.normalizeIp('203.0.113.9')] };
    case 'allowlist': return { raw: '198.51.100.4', expected: [limits.normalizeIp('198.51.100.4')] };
    default: return null;
  }
}

async function configLeafPathScenario() {
  const dir = scratchDir('leaf-paths');
  const file = path.join(dir, 'config.json');
  const init = await runCli(['init', '--yes', '--config', file], { cwd: dir });
  ok(init.code === cli.OK, 'a config exists to drive config set against');

  const driven = [];
  const refused = [];
  const cannotSet = [];

  for (const dotted of config.LEAF_PATHS) {
    if (EXCEPT_PATHS.has(dotted)) {
      const result = await runCli(['config', 'set', dotted, 'x', '--config', file], { cwd: dir });
      ok(result.code === cli.USAGE, `config set ${dotted} is refused with a usage exit code`);
      ok(result.stderr.trim().length > 0, `config set ${dotted} explains why it is refused`);
      refused.push(dotted);
      continue;
    }

    const tv = testValueFor(dotted);
    if (!tv) {
      cannotSet.push({ dotted, reason: 'no test value mapped for this leaf in this suite' });
      continue;
    }

    const setResult = await runCli(['config', 'set', dotted, tv.raw, '--config', file], { cwd: dir });
    ok(setResult.code === cli.OK, `config set ${dotted} ${tv.raw} succeeds`);

    const getResult = await runCli(['config', 'get', dotted, '--config', file], { cwd: dir });
    ok(getResult.code === cli.OK, `config get ${dotted} succeeds`);

    const printed = getResult.stdout.trim();
    const gotFromCli = Array.isArray(tv.expected) ? JSON.parse(printed) : printed;
    const expectedForCompare = Array.isArray(tv.expected) ? tv.expected : String(tv.expected);
    ok(same(gotFromCli, expectedForCompare),
      `config get ${dotted} reads back what was just set (got ${printed}, wanted ${JSON.stringify(expectedForCompare)})`);

    const onDiskValue = config.getPath(readConfigFile(file), dotted);
    ok(same(onDiskValue, tv.expected), `${dotted} is really on disk as ${JSON.stringify(tv.expected)}`);

    driven.push(dotted);
  }

  ok(driven.length + refused.length + cannotSet.length === config.LEAF_PATHS.length,
    'every LEAF_PATHS entry was accounted for (driven, refused-by-design, or reported as uncovered)');

  console.log(`\n  LEAF_PATHS driven (${driven.length}): ${driven.join(', ')}`);
  console.log(`  LEAF_PATHS refused by design (${refused.length}): ${refused.join(', ')}`);
  if (cannotSet.length) {
    console.log(`  LEAF_PATHS NOT covered (${cannotSet.length}):`);
    for (const { dotted, reason } of cannotSet) console.log(`    ${dotted}: ${reason}`);
  }
}

// =====================================================================
// config set reports clamping before saving
// =====================================================================

async function clampReportScenario() {
  const dir = scratchDir('clamp');
  const file = path.join(dir, 'config.json');
  await runCli(['init', '--yes', '--config', file], { cwd: dir });

  const result = await runCli(['config', 'set', 'maxPlayers', '9999', '--config', file], { cwd: dir });
  ok(result.code === cli.OK, 'an out-of-range value is accepted, not refused');
  ok(/adjusted:.*maxPlayers.*9999.*lowered to 64/.test(result.stdout),
    'the clamp is reported: the host is told what the value became');

  const adjustedAt = result.stdout.indexOf('adjusted:');
  const reportedAt = result.stdout.indexOf('maxPlayers = 64');
  ok(adjustedAt >= 0 && reportedAt > adjustedAt, 'the clamp note prints before the final value line');

  ok(readConfigFile(file).maxPlayers === 64, 'the clamped value, not the raw one, is what gets saved');
}

// =====================================================================
// status shows where each value came from, and env outranks file
// =====================================================================

async function statusPrecedenceScenario() {
  const dir = scratchDir('status');
  const file = path.join(dir, 'config.json');
  await runCli(['init', '--yes', '--config', file], { cwd: dir });
  await runCli(['config', 'set', 'maxPlayers', '5', '--config', file], { cwd: dir });

  const env = Object.assign(cleanEnv(), { RBY_MMO_MAX: '10' });
  const result = await runCli(['status', '--config', file], { cwd: dir, env });
  ok(result.code === cli.OK, 'status succeeds');
  ok(/^maxPlayers\s+10\s+env\b/m.test(result.stdout),
    'maxPlayers is set both by file (5) and env (10); status reports env as the winner, with its value');
}

// =====================================================================
// secrets discipline
// =====================================================================

async function secretsDisciplineScenario() {
  const dir = scratchDir('secrets');
  const file = path.join(dir, 'config.json');
  const init = await runCli(['init', '--yes', '--config', file], { cwd: dir });
  const printedCode = init.stdout.match(CODE_RE)[0];
  ok(!!printedCode, 'a known join code exists to test secrecy against');

  const status = await runCli(['status', '--config', file], { cwd: dir });
  const doctor = await runCli(['doctor', '--config', file], { cwd: dir });
  const listMasked = await runCli(['invite', 'list', '--config', file], { cwd: dir });

  for (const [label, result] of [['status', status], ['doctor', doctor], ['invite list', listMasked]]) {
    ok(!result.stdout.includes(printedCode) && !result.stderr.includes(printedCode),
      `${label} never prints the full join code`);
  }

  const listRevealed = await runCli(['invite', 'list', '--reveal', '--config', file], { cwd: dir });
  ok(listRevealed.stdout.includes(printedCode), 'invite list --reveal does print it in full');
}

// =====================================================================
// invite
// =====================================================================

async function inviteScenario() {
  const dir = scratchDir('invite');
  const file = path.join(dir, 'config.json');
  await runCli(['init', '--yes', '--config', file], { cwd: dir });

  const badExpiry = await runCli(['invite', '--expires', 'soon', '--config', file], { cwd: dir });
  ok(badExpiry.code === cli.USAGE, 'an unrecognised --expires duration is a usage error');
  ok(/30m/.test(badExpiry.stderr) && /24h/.test(badExpiry.stderr) && /7d/.test(badExpiry.stderr),
    'the accepted forms (30m/24h/7d) are named in the refusal');

  const good = await runCli(
    ['invite', '--expires', '24h', '--uses', '3', '--label', 'Friend', '--config', file], { cwd: dir });
  ok(good.code === cli.OK, 'a well-formed invite succeeds');
  const idMatch = /\(id ([0-9a-f]+),/.exec(good.stdout);
  ok(!!idMatch, 'the new credential id is printed');
  const id = idMatch[1];

  const list = await runCli(['invite', 'list', '--reveal', '--config', file], { cwd: dir });
  ok(list.code === cli.OK, 'invite list succeeds');
  ok(list.stdout.includes(id), 'the new credential appears in invite list');

  const stored = readConfigFile(file).auth.credentials.find((c) => c.id === id);
  ok(!!stored, 'the credential is on disk');
  ok(stored.maxUses === 3, '--uses is stored');
  ok(!!stored.expiresAt, '--expires is stored');
}

// =====================================================================
// revoke
// =====================================================================

async function revokeScenario() {
  const dir = scratchDir('revoke');
  const file = path.join(dir, 'config.json');
  await runCli(['init', '--yes', '--config', file], { cwd: dir });
  const primaryId = readConfigFile(file).auth.credentials[0].id;

  const badId = await runCli(['revoke', 'this-id-does-not-exist', '--config', file], { cwd: dir });
  ok(badId.code === cli.ERROR, 'revoking an unknown id is an error');
  ok(/No join code/.test(badId.stderr), 'and says so');

  const revoke = await runCli(['revoke', primaryId, '--config', file], { cwd: dir });
  ok(revoke.code === cli.OK, 'revoking the last active credential still succeeds');
  ok(/last usable join code/.test(revoke.stderr), 'but warns that nobody can join now');
  ok(readConfigFile(file).auth.credentials[0].revoked === true,
    'the credential is marked revoked on disk');
}

// =====================================================================
// ban / unban / allow
// =====================================================================

async function banAllowScenario() {
  const dir = scratchDir('ban-allow');
  const file = path.join(dir, 'config.json');
  await runCli(['init', '--yes', '--config', file], { cwd: dir });

  const dualStack = '::ffff:203.0.113.7';
  const plain = limits.normalizeIp(dualStack);

  const ban = await runCli(['ban', dualStack, '--config', file], { cwd: dir });
  ok(ban.code === cli.OK, 'ban succeeds');
  let onDisk = readConfigFile(file);
  ok(onDisk.bans.includes(plain), `the address lands normalised on disk (${plain})`);
  ok(!onDisk.bans.includes(dualStack), 'not in its raw dual-stack spelling');

  const unban = await runCli(['unban', plain, '--config', file], { cwd: dir });
  ok(unban.code === cli.OK, 'unban succeeds');
  onDisk = readConfigFile(file);
  ok(!onDisk.bans.includes(plain), 'the address is gone from the file');

  const allow1 = await runCli(['allow', '203.0.113.9', '--config', file], { cwd: dir });
  ok(allow1.code === cli.OK, 'the first allow succeeds');
  ok(/ONLY the addresses below may connect/.test(allow1.stdout),
    'adding the first allowlist entry warns that it locks out everyone else');
  onDisk = readConfigFile(file);
  ok(onDisk.allowlist.length === 1, 'and the entry actually lands');

  const allowClear = await runCli(['allow', '--clear', '--config', file], { cwd: dir });
  ok(allowClear.code === cli.OK, 'allow --clear succeeds');
  ok(readConfigFile(file).allowlist.length === 0, 'the allowlist is empty again');
}

// =====================================================================
// doctor
// =====================================================================

async function doctorScenario() {
  const dir = scratchDir('doctor');
  const file = path.join(dir, 'config.json');
  await runCli(['init', '--yes', '--config', file], { cwd: dir });

  const healthy = await runCli(['doctor', '--config', file], { cwd: dir });
  ok(healthy.code === cli.OK, 'doctor exits zero on a healthy, freshly-initialised config');

  fs.chmodSync(file, 0o644);
  const broken = await runCli(['doctor', '--config', file], { cwd: dir });
  ok(broken.code === cli.ERROR, 'doctor exits non-zero when the config file is world-readable');
  ok(/\[fail\]/.test(broken.stdout), 'and marks it a failure rather than a warning');
  fs.chmodSync(file, 0o600);
}

// =====================================================================
// exit codes, unknown verb, bare invocation, --version
// =====================================================================

async function exitCodesScenario() {
  const dir = scratchDir('exit-codes');

  const bare = await runCli([], { cwd: dir });
  ok(bare.code === cli.OK, 'a bare invocation is not an error (exit 0)');
  ok(/Usage:/.test(bare.stdout), 'and it prints help');

  const unknown = await runCli(['bogus-verb'], { cwd: dir });
  ok(unknown.code === cli.USAGE, 'an unknown command is a usage error (exit 2)');

  const usageErr = await runCli(['config', 'set'], { cwd: dir });
  ok(usageErr.code === cli.USAGE, 'config set with no arguments is a usage error (exit 2)');

  const missingConfig = path.join(dir, 'no-such-config.json');
  const runtimeErr = await runCli(['revoke', 'anything', '--config', missingConfig], { cwd: dir });
  ok(runtimeErr.code === cli.ERROR, 'acting against a config that does not exist is a runtime error (exit 1)');

  const version = await runCli(['--version'], { cwd: dir });
  ok(version.code === cli.OK, '--version succeeds (exit 0)');
  const pkgVersion = JSON.parse(fs.readFileSync(path.join(__dirname, 'package.json'), 'utf8')).version;
  ok(version.stdout.trim() === `rby-mmo-hub ${pkgVersion}`,
    '--version prints the version from package.json');
}

// =====================================================================
// the shim: proving the real process exit status matches run()'s code
// =====================================================================

async function spawnExitCodeScenario() {
  const okCode = await spawnCli(['--version']);
  ok(okCode === 0, 'the spawned process exits 0 when run() resolves OK');

  const usageCode = await spawnCli(['bogus-verb']);
  ok(usageCode === 2, 'the spawned process exits 2 when run() resolves USAGE -- the shim maps it through');
}

// ------------------------------------------------------------------- runner

async function main() {
  try {
    await initScenarios();
    await configLeafPathScenario();
    await clampReportScenario();
    await statusPrecedenceScenario();
    await secretsDisciplineScenario();
    await inviteScenario();
    await revokeScenario();
    await banAllowScenario();
    await doctorScenario();
    await exitCodesScenario();
    await spawnExitCodeScenario();
  } finally {
    fs.rmSync(ROOT, { recursive: true, force: true });
  }
  console.log(`\n  ${passed}/${passed} checks passed  (cli)\n`);
}

main().catch((err) => {
  console.error('\n  ' + err.message + '\n');
  process.exit(1);
});
