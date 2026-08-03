#!/usr/bin/env node
'use strict';

/*
 * Pin the configuration store in server/lib/config.js.
 *
 * Covers the precedence chain (flag > env > file > default), the legacy
 * RBY_MMO_* env vars hub.js has always read, clamping driven mechanically
 * from BOUNDS, the nesting of config.js's BOUNDS inside limits.js's BOUNDS,
 * the load()-never-throws contract, atomic/mode-0600 save(), permission
 * checking, redaction, migration and the manifest/package version-parity
 * guard.
 *
 * Same bespoke idiom as server/hub.test.js and server/auth.test.js: a
 * throwing ok(cond, label) helper, plain scenario functions, a final
 * console.log of the pass count. No test framework, no dependencies beyond
 * node core. Everything that touches the filesystem writes to a scratch
 * directory under os.tmpdir(), cleaned up in a finally.
 *
 * Run: node server/config.test.js
 * Also runs under `npm test` (node --test) the same way hub.test.js and
 * auth.test.js do: no node:test imports, so the whole script is one
 * implicit test that passes as long as it exits 0.
 */

const fs = require('fs');
const os = require('os');
const path = require('path');
const config = require('./lib/config.js');
const limits = require('./lib/limits.js');

let passed = 0;
const ok = (cond, label) => {
  if (!cond) throw new Error('FAIL: ' + label);
  passed++;
};

// ------------------------------------------------------------------ helpers

function writeConfig(file, object, mode) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, JSON.stringify(object), { mode: mode || 0o600 });
}

function cloneDefaults() {
  return JSON.parse(JSON.stringify(config.DEFAULTS));
}

// --------------------------------------------------------------- precedence

function testPrecedence(tmp) {
  const file = path.join(tmp, 'precedence.json');
  writeConfig(file, { version: 1, listen: { port: 1111 } });

  // All four sources supply the same key; the flag must win.
  const all = config.load({ path: file, env: { RBY_MMO_PORT: '2222' }, flags: { port: 3333 } });
  ok(all.config.listen.port === 3333, 'a flag beats env, file and default for the same key');
  ok(all.sources['listen.port'] === 'flag', 'sources reports "flag" for a flag-supplied leaf');

  const envOverFile = config.load({ path: file, env: { RBY_MMO_PORT: '2222' }, flags: {} });
  ok(envOverFile.config.listen.port === 2222, 'env beats file when no flag is given');
  ok(envOverFile.sources['listen.port'] === 'env', 'sources reports "env"');

  const fileOverDefault = config.load({ path: file, env: {}, flags: {} });
  ok(fileOverDefault.config.listen.port === 1111, 'the file beats the built-in default');
  ok(fileOverDefault.sources['listen.port'] === 'file', 'sources reports "file"');

  const missing = path.join(tmp, 'does-not-exist.json');
  const defaults = config.load({ path: missing, env: {}, flags: {} });
  ok(defaults.config.listen.port === config.DEFAULTS.listen.port,
    'the built-in default applies when nothing else supplies the key');
  ok(defaults.sources['listen.port'] === 'default', 'sources reports "default"');
}

// -------------------------------------------------------------- legacy envs

function testLegacyEnvVars(tmp) {
  const missing = path.join(tmp, 'legacy-does-not-exist.json');
  const result = config.load({
    path: missing,
    env: { RBY_MMO_PORT: '9001', RBY_MMO_HOST: '10.0.0.5', RBY_MMO_MAX: '12' },
    flags: {},
  });
  ok(result.config.listen.port === 9001, 'RBY_MMO_PORT still sets listen.port');
  ok(result.config.listen.host === '10.0.0.5', 'RBY_MMO_HOST still sets listen.host');
  ok(result.config.maxPlayers === 12, 'RBY_MMO_MAX still sets maxPlayers');
}

// ------------------------------------------------------------------ clamping

function testClamping() {
  for (const dotted of Object.keys(config.BOUNDS)) {
    const [min, max] = config.BOUNDS[dotted];

    const belowDefaults = cloneDefaults();
    config.setPath(belowDefaults, dotted, min - 1);
    const below = config.validate(belowDefaults);
    ok(config.getPath(below.config, dotted) === min,
      `${dotted}: a value below the minimum (${min - 1}) is raised to ${min}`);
    ok(below.warnings.some((w) => w.startsWith(dotted + ':')),
      `${dotted}: clamping down produces a warning naming the setting`);

    const aboveDefaults = cloneDefaults();
    config.setPath(aboveDefaults, dotted, max + 1);
    const above = config.validate(aboveDefaults);
    ok(config.getPath(above.config, dotted) === max,
      `${dotted}: a value above the maximum (${max + 1}) is lowered to ${max}`);
    ok(above.warnings.some((w) => w.startsWith(dotted + ':')),
      `${dotted}: clamping up produces a warning naming the setting`);
  }

  // This is the exact behaviour server/hub.test.js's clampTest scenario
  // depends on: a sub-floor RBY_MMO_MAX is raised to 2, not obeyed.
  const [maxPlayersMin, maxPlayersMax] = config.BOUNDS.maxPlayers;
  ok(maxPlayersMin === 2 && maxPlayersMax === 64, 'maxPlayers keeps its 2..64 bounds');
}

// ------------------------------------------------------------- bounds nesting

function testBoundsNesting() {
  // Driven from limits.js's BOUNDS, not config.js's: config.js's "limits."
  // namespace also carries chatIntervalMs, which is a flood-gate setting
  // consumed directly by lib/relay.js and never passed through the Limits
  // class (see lib/server.js:179, lib/relay.js:288-289) -- it has no
  // counterpart to nest inside and is correctly absent from limits.BOUNDS.
  // Every knob limits.js *does* bound must both exist in config.BOUNDS and
  // nest inside it, which is the actual "never silently re-clamped
  // downstream" guarantee this test exists to pin.
  let checked = 0;
  for (const bareKey of Object.keys(limits.BOUNDS)) {
    const dotted = 'limits.' + bareKey;
    const configRange = config.BOUNDS[dotted];
    ok(Array.isArray(configRange), `config.BOUNDS has a matching entry for ${dotted}`);
    const [cMin, cMax] = configRange;
    const [lMin, lMax] = limits.BOUNDS[bareKey];
    ok(cMin >= lMin && cMax <= lMax,
      `${dotted}: config's [${cMin}, ${cMax}] is a subset of limits.js's [${lMin}, ${lMax}]`);
    checked += 1;
  }
  ok(checked === Object.keys(limits.BOUNDS).length,
    'every knob limits.js bounds was checked for nesting inside config.js');
}

// ----------------------------------------------------------- load never throws

function testLoadNeverThrows(tmp) {
  const badJson = path.join(tmp, 'bad.json');
  fs.writeFileSync(badJson, '{ this is not json', { mode: 0o600 });
  const malformed = config.load({ path: badJson, env: {}, flags: {} });
  ok(malformed.config.listen.port === config.DEFAULTS.listen.port,
    'malformed JSON falls back to defaults instead of throwing');
  ok(malformed.warnings.some((w) => /not valid JSON/.test(w)), 'and warns about it');

  const notObject = path.join(tmp, 'not-object.json');
  fs.writeFileSync(notObject, JSON.stringify([1, 2, 3]), { mode: 0o600 });
  const arrayResult = config.load({ path: notObject, env: {}, flags: {} });
  ok(arrayResult.config.listen.port === config.DEFAULTS.listen.port,
    'a JSON file that is not an object falls back to defaults');
  ok(arrayResult.warnings.some((w) => /not a JSON object/.test(w)), 'and warns about it');

  const canSimulateUnreadable =
    process.platform !== 'win32' && !(process.getuid && process.getuid() === 0);
  if (canSimulateUnreadable) {
    const unreadable = path.join(tmp, 'unreadable.json');
    fs.writeFileSync(unreadable, JSON.stringify(config.DEFAULTS), { mode: 0o600 });
    fs.chmodSync(unreadable, 0o000);
    try {
      const result = config.load({ path: unreadable, env: {}, flags: {} });
      ok(result.config.listen.port === config.DEFAULTS.listen.port,
        'an unreadable path falls back to defaults');
      ok(result.warnings.some((w) => /could not read/.test(w)), 'and warns about it');
    } finally {
      fs.chmodSync(unreadable, 0o600);
    }
  } else {
    console.log('  (skipped: unreadable-path check needs a non-root POSIX user)');
  }
}

// -------------------------------------------------------------- save/round-trip

function testSaveAndRoundTrip(tmp) {
  const validated = config.validate(config.DEFAULTS).config;
  const file = path.join(tmp, 'nested', 'dir', 'config.json');

  ok(!fs.existsSync(path.dirname(file)), 'the parent directory does not exist yet');
  config.save(file, validated);
  ok(fs.existsSync(path.dirname(file)), 'save() creates a missing parent directory');
  ok(fs.existsSync(file), 'save() writes the file');
  ok(!fs.existsSync(file + '.tmp'), 'save() leaves no .tmp file behind on success');

  if (process.platform !== 'win32') {
    const mode = fs.statSync(file).mode & 0o777;
    ok(mode === 0o600, 'save() writes the file at mode 0600');
  }

  const reloaded = config.load({ path: file, env: {}, flags: {} });
  ok(JSON.stringify(reloaded.config) === JSON.stringify(validated),
    'a saved config reloads identically (round-trip)');
}

// ------------------------------------------------------------- checkPermissions

function testCheckPermissions(tmp) {
  if (process.platform === 'win32') {
    console.log('  (skipped: checkPermissions is a no-op on win32)');
    return;
  }
  const file = path.join(tmp, 'perm.json');
  fs.writeFileSync(file, '{}', { mode: 0o644 });
  fs.chmodSync(file, 0o644); // writeFileSync's mode is subject to umask; force it
  const warned = config.checkPermissions(file);
  ok(typeof warned === 'string' && warned.length > 0, 'a 0644 file gets a warning');

  fs.chmodSync(file, 0o600);
  const clean = config.checkPermissions(file);
  ok(clean === null, 'a 0600 file gets no warning');
}

// ------------------------------------------------------------------- redact

function testRedact() {
  const original = config.validate(config.DEFAULTS).config;
  original.auth.credentials = [
    { id: 'a', label: 'A', secret: 'ABCD-EFGH-JKMN-PQRS', createdAt: null,
      expiresAt: null, maxUses: null, uses: 0, revoked: false },
    { id: 'b', label: 'B', secret: 'WXYZ-2345-6789-CDEF', createdAt: null,
      expiresAt: null, maxUses: null, uses: 0, revoked: false },
  ];
  const snapshot = JSON.stringify(original);

  const redacted = config.redact(original);
  ok(JSON.stringify(original) === snapshot, 'redact() does not mutate its input');
  ok(redacted !== original, 'redact() returns a distinct object');

  for (let i = 0; i < original.auth.credentials.length; i++) {
    const real = original.auth.credentials[i].secret;
    const masked = redacted.auth.credentials[i].secret;
    ok(masked !== real, `credential ${i}'s secret is masked`);
    ok(!masked.includes(real), `credential ${i}'s masked form does not contain the full secret`);
  }
}

// ------------------------------------------------------------------- migrate

function testMigrate() {
  const versionless = config.migrate({});
  ok(versionless.raw.version === config.SCHEMA_VERSION,
    'a versionless object is stamped with the current schema version');

  const nonObject = config.migrate(null);
  ok(nonObject.raw.version === config.SCHEMA_VERSION,
    'a non-object input is also stamped with the current schema version');
}

// -------------------------------------------------------------- version parity

function testVersionParity() {
  const manifestPath = path.join(__dirname, '..', 'manifest.json');
  if (!fs.existsSync(manifestPath)) {
    // manifest.json lives outside server/ and is absent in a standalone
    // server install -- skip rather than fail, per the plan.
    console.log('  (skipped: manifest.json not found -- standalone server install)');
    return;
  }
  const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
  const pkg = JSON.parse(fs.readFileSync(path.join(__dirname, 'package.json'), 'utf8'));
  ok(pkg.version === manifest.version,
    `server/package.json (${pkg.version}) matches manifest.json (${manifest.version})`);
}

// --------------------------------------------------------------------- main

function main() {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'rby-mmo-config-test-'));
  try {
    testPrecedence(tmp);
    testLegacyEnvVars(tmp);
    testClamping();
    testBoundsNesting();
    testLoadNeverThrows(tmp);
    testSaveAndRoundTrip(tmp);
    testCheckPermissions(tmp);
    testRedact();
    testMigrate();
    testVersionParity();
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
  console.log(`\n  ${passed}/${passed} checks passed  (config)\n`);
}

try {
  main();
} catch (err) {
  console.error('\n  ' + err.message + '\n');
  process.exit(1);
}
