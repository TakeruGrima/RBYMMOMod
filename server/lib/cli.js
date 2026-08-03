'use strict';

/*
 * The hosting software: the one place a host configures anything.
 *
 * The rule this file exists to keep is simple and absolute -- **no setting is
 * reachable only by hand-editing JSON**. Every knob in config.js has a verb
 * here, every list has an add and a remove, and the two things that must never
 * be edited as text (join codes, bans) have verbs that normalise them properly
 * on the way in. A host who opens the config file at all should be doing it out
 * of curiosity, never out of necessity.
 *
 * Three structural decisions, none of them cosmetic:
 *
 *  - `run(argv, io)` returns an exit code and **never calls process.exit**, and
 *    never writes to process.stdout directly. Everything goes through the
 *    injected streams. That is what lets a test suite drive every verb
 *    in-process, without spawning a shell, and assert on the exact bytes a host
 *    would see.
 *  - Nothing here reimplements config merging, clamping, code generation or IP
 *    normalisation. config.js, auth.js and limits.js own those; this file is
 *    the front door to them, and a second implementation of any of them would
 *    be a second set of rules to drift apart.
 *  - `lib/server.js` is required lazily, inside the verb that needs it. It is
 *    written in parallel with this file, so a `require` at module scope would
 *    take every other verb down with it if it were missing or momentarily
 *    broken. `start` reports that clearly instead.
 *
 * Secrets discipline: a join code is printed by exactly three things -- `init`,
 * `invite`, and `invite list --reveal`. It never goes through the logger (log
 * lines get piped into files, journals and, in a container, into whatever the
 * orchestrator collects), never appears in `status` or `doctor`, and never
 * appears in an error message. `status` and `invite list` mask through
 * config.redact so a host can screen-share either one.
 *
 * Exit codes: 0 success, 1 runtime error, 2 usage error.
 *
 * No dependencies: node:fs, node:path, node:readline/promises.
 */

const fs = require('node:fs');
const path = require('node:path');
const readline = require('node:readline/promises');

const config = require('./config.js');
const auth = require('./auth.js');
const limits = require('./limits.js');
const log = require('./log.js');
const reachability = require('./reachability.js');
const upnp = require('./upnp.js');

const OK = 0;
const ERROR = 1;
const USAGE = 2;

const PROGRAM = 'rby-mmo-hub';
const FALLBACK_VERSION = '0.0.0-dev';

// Flags that are switches, so `--yes start` does not eat `start` as a value.
const SWITCHES = new Set([
  'yes', 'force', 'reveal', 'clear', 'help', 'version', 'quiet', 'insecureConfig',
]);

/*
 * How long `start` will wait for the router to acknowledge the removal of its
 * port mapping before giving up and shutting down anyway. SSDP discovery plus
 * a SOAP POST is a real network round trip, and a router that has gone away
 * (or gone to sleep) must never be the reason a host cannot stop their hub:
 * an unremoved mapping expires with its lease, a wedged shutdown does not
 * expire at all.
 *
 * Deliberately *inside* server.js's own SHUTDOWN_HOOK_MS (2000). That one is
 * the real ceiling on the Ctrl-C path -- close() abandons the hook when it
 * elapses -- so a longer budget here would only mean the host never gets told
 * why the mapping is still up.
 */
const UNMAP_TIMEOUT_MS = 1500;

const TIMED_OUT = Symbol('timed out');

function withDeadline(promise, ms) {
  let timer = null;
  const deadline = new Promise((resolve) => {
    timer = setTimeout(() => resolve(TIMED_OUT), ms);
    // Never a reason for the process to stay up on its own account.
    if (timer && typeof timer.unref === 'function') timer.unref();
  });
  return Promise.race([Promise.resolve(promise), deadline])
    .then((value) => { if (timer) clearTimeout(timer); return value; },
      (err) => { if (timer) clearTimeout(timer); throw err; });
}

// --------------------------------------------------------------- arguments

function camel(name) {
  // A dotted name is a config path (`--limits.maxPending 12`) and must survive
  // verbatim; config.js accepts those directly, which is what keeps every leaf
  // settable without a hand-written flag per knob.
  if (name.includes('.')) return name;
  return name.replace(/-([a-z0-9])/gi, (match, char) => char.toUpperCase());
}

/**
 * A small, predictable parser: `--flag`, `--flag value`, `--flag=value`,
 * `--no-flag`, and `--` to stop. No short options -- this is a tool a host
 * types a handful of times, and unambiguous beats terse.
 */
function parseArgs(argv) {
  const positional = [];
  const flags = {};

  for (let i = 0; i < argv.length; i += 1) {
    const arg = String(argv[i]);

    if (arg === '--') {
      positional.push(...argv.slice(i + 1).map(String));
      break;
    }
    if (!arg.startsWith('--')) {
      positional.push(arg);
      continue;
    }

    let name = arg.slice(2);
    let value;
    const equals = name.indexOf('=');
    if (equals >= 0) {
      value = name.slice(equals + 1);
      name = name.slice(0, equals);
    }

    let negated = false;
    if (name.startsWith('no-')) {
      negated = true;
      name = name.slice(3);
    }
    if (!name) continue;

    const key = camel(name);
    if (negated) {
      flags[key] = false;
      continue;
    }
    if (value !== undefined) {
      flags[key] = value;
      continue;
    }

    const next = argv[i + 1];
    if (SWITCHES.has(key) || next === undefined || String(next).startsWith('--')) {
      flags[key] = true;
    } else {
      flags[key] = String(next);
      i += 1;
    }
  }

  return { positional, flags };
}

/**
 * The subset of the parsed flags that config.js understands. Passing the rest
 * (`--yes`, `--reveal`) would earn an "unknown option" warning per invocation,
 * which trains a host to ignore warnings -- the opposite of what they are for.
 */
function configFlags(flags) {
  const out = {};
  for (const [key, value] of Object.entries(flags)) {
    if (key in config.FLAG_MAP || config.LEAF_PATHS.includes(key)) out[key] = value;
  }
  return out;
}

function parseDuration(text) {
  const match = /^(\d{1,7})\s*([mhd])$/i.exec(String(text).trim());
  if (!match) return null;
  const amount = Number(match[1]);
  if (!Number.isFinite(amount) || amount < 1) return null;
  const unit = match[2].toLowerCase();
  const ms = unit === 'm' ? 60000 : unit === 'h' ? 3600000 : 86400000;
  return amount * ms;
}

// ------------------------------------------------------------------- output

/*
 * `rby-mmo-hub invite | head -1` closes the pipe under us mid-write, and on a
 * socket-backed stdout the resulting EPIPE arrives *asynchronously*, as an
 * 'error' event -- so a try/catch around write() never sees it and Node kills
 * the process over an unhandled event. Silencing the stream's error event is
 * the only thing that actually stops that, and losing output that nobody is
 * reading any more is the correct outcome. Marked so repeated runs in one
 * process (the test suite) do not stack listeners.
 */
const QUIET = Symbol.for('rby_mmo.cli.quietStream');

function quiet(stream) {
  if (!stream || typeof stream.on !== 'function' || stream[QUIET]) return;
  try {
    stream[QUIET] = true;
    stream.on('error', () => {});
  } catch (err) {
    /* a frozen or fake stream: nothing to silence */
  }
}

function makeIo(io) {
  const streams = io || {};
  const stdout = streams.stdout || process.stdout;
  const stderr = streams.stderr || process.stderr;
  quiet(stdout);
  quiet(stderr);

  const push = (stream, text) => {
    // The synchronous half of the same problem: a stream already destroyed
    // throws from write() rather than emitting.
    try {
      stream.write(text);
    } catch (err) {
      /* nothing useful can be printed about a broken output stream */
    }
  };

  return {
    stdout,
    stderr,
    stdin: streams.stdin || process.stdin,
    env: streams.env || process.env,
    cwd: streams.cwd || process.cwd(),
    say: (line) => push(stdout, `${line === undefined ? '' : line}\n`),
    warn: (line) => push(stderr, `${line === undefined ? '' : line}\n`),
  };
}

function pad(text, width) {
  const value = String(text);
  return value.length >= width ? value : value + ' '.repeat(width - value.length);
}

function printLines(ctx, lines) {
  for (const line of lines) ctx.say(line);
}

/**
 * `silent` is a level config.js accepts and log.js does not know about (its
 * ladder stops at `error`), so it is honoured here rather than being quietly
 * downgraded to `info` -- a host who asked for silence and got chatter would
 * reasonably conclude the setting does nothing.
 */
function makeLog(cfg, stream) {
  const level = cfg && cfg.log ? cfg.log.level : 'info';
  if (level === 'silent') {
    const nothing = () => {};
    return { level: 'silent', error: nothing, warn: nothing, info: nothing, debug: nothing };
  }
  return log.createLog({ level, stream });
}

function version() {
  // T10 writes server/package.json. Until it does -- and if it is ever removed
  // from a packed archive -- a missing file reports a placeholder rather than
  // taking `--version` down.
  try {
    const parsed = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'package.json'), 'utf8'));
    if (parsed && typeof parsed.version === 'string' && parsed.version) return parsed.version;
  } catch (err) {
    /* no package.json here: fall through */
  }
  return FALLBACK_VERSION;
}

// --------------------------------------------------------------------- help

const HELP = {
  '': [
    `${PROGRAM} -- run and configure an RBY MMO hub`,
    '',
    `Usage: ${PROGRAM} <command> [options]`,
    '',
    'Getting started',
    '  init                        first-run wizard: writes the config file and',
    '                              prints a join code (once)',
    '  start                       run the hub',
    '  doctor                      check the configuration and report who can',
    '                              reach this machine',
    '',
    'Configuration',
    '  status                      the effective settings, and where each one',
    '                              came from (flag / env / file / default)',
    '  config list                 every setting and its current value',
    '  config get <path>           one setting, e.g. limits.maxPending',
    '  config set <path> <value>   change one setting (clamped, then saved)',
    '',
    'Who may join',
    '  invite [options]            mint a new join code and print it once',
    '  invite list [--reveal]      list join codes; masked unless --reveal',
    '  revoke <id>                 revoke one join code',
    '  ban <ip> [--reason X]       refuse an address',
    '  unban <ip>                  stop refusing an address',
    '  allow [<ip>|--clear]        allowlist: when it has entries, ONLY those',
    '                              addresses may connect',
    '',
    'Router',
    '  upnp enable|disable|status  ask the router to forward the port (off by',
    '                              default; read the warning first)',
    '',
    'Other',
    '  help [command]              this text, or a command\'s own',
    '  --version                   print the version',
    '',
    'Global options',
    '  --config <file>   which config file to use. Default: $RBY_MMO_CONFIG,',
    '                    then ./config.json, then /data/config.json in a container.',
    '',
    'Precedence, everywhere: command-line flag > RBY_MMO_* env var > config file',
    '> built-in default.',
    '',
    'Exit codes: 0 success, 1 error, 2 wrong usage.',
  ],
  init: [
    `Usage: ${PROGRAM} init [--force] [--yes] [--port N] [--max N] [--no-auth]`,
    '                       [--log-level debug|info|warn|error|silent]',
    '',
    'Asks four questions, writes the config file with mode 0600, and prints a',
    'join code once. Refuses to overwrite an existing config without --force.',
    '',
    '  --yes         do not ask; take the flags and the defaults. This is the',
    '                path a Dockerfile or a test suite uses.',
    '  --force       replace an existing config file.',
    '  --no-auth     do not require a join code (anyone who reaches the port',
    '                can join). Authentication is on by default.',
  ],
  start: [
    `Usage: ${PROGRAM} start [--port N] [--host ADDR] [--max N] [...]`,
    '                        [--insecure-config]',
    '',
    'Loads the configuration, prints who can reach this machine, and runs the',
    'hub until it is stopped. Any config path may be overridden for this run',
    'with a flag -- `--limits.maxPending 12` works as well as `--max 8`.',
    '',
    'The config file holds every join code in plaintext, so `start` refuses to',
    'run when it is readable by the group or by everyone else on the machine.',
    'The fix it prints is `chmod 600 <file>`.',
    '',
    '  --insecure-config   start anyway on a group- or world-readable config.',
    '                      For a host who genuinely has an unusual setup; it',
    '                      prints exactly what is being accepted.',
  ],
  status: [
    `Usage: ${PROGRAM} status`,
    '',
    'Prints every setting with the value in force and where it came from, so',
    '"why is it still 4 players" has an answer. Join codes are masked.',
  ],
  config: [
    `Usage: ${PROGRAM} config list`,
    `       ${PROGRAM} config get <path>`,
    `       ${PROGRAM} config set <path> <value>`,
    '',
    'Paths are dotted, e.g. listen.port, maxPlayers, limits.maxPending,',
    'network.upnp.leaseSeconds, log.level.',
    '',
    'Out-of-range numbers are pulled to the nearest end and reported before',
    'anything is written. Join codes are not settable here -- use `invite` and',
    '`revoke`, which generate and normalise them properly.',
  ],
  invite: [
    `Usage: ${PROGRAM} invite [--label TEXT] [--expires 30m|24h|7d] [--uses N]`,
    `       ${PROGRAM} invite list [--reveal]`,
    '',
    'Mints a join code and prints it once. Codes are masked in `invite list`',
    'unless --reveal is given, so the list is safe to screen-share.',
    '',
    '  --expires   30m, 24h, 7d -- minutes, hours or days. Nothing else.',
    '  --uses N    how many times it may be used before it stops working.',
  ],
  revoke: [
    `Usage: ${PROGRAM} revoke <id>`,
    '',
    'Ids come from `invite list`. A unique prefix is enough.',
  ],
  ban: [
    `Usage: ${PROGRAM} ban <ip> [--reason TEXT]`,
    '',
    'Addresses are normalised first, so ::ffff:203.0.113.7 and 203.0.113.7 are',
    'the same ban and a dual-stack client cannot slip past it.',
  ],
  unban: [`Usage: ${PROGRAM} unban <ip>`],
  allow: [
    `Usage: ${PROGRAM} allow [<ip>] [--clear]`,
    '',
    'With no argument, prints the allowlist. An allowlist with entries is',
    'exclusive: only those addresses may connect. --clear empties it.',
  ],
  doctor: [
    `Usage: ${PROGRAM} doctor`,
    '',
    'Configuration sanity plus a reachability report. Exit code 1 if something',
    'would stop players connecting; 0 if only warnings.',
  ],
  upnp: [
    `Usage: ${PROGRAM} upnp enable|disable|status`,
    '',
    'Automatic port forwarding, off by default. `enable` prints the full risk',
    'note before it does anything.',
  ],
};

function help(ctx, verb) {
  const lines = HELP[verb] || HELP[''];
  printLines(ctx, lines);
  return OK;
}

// ---------------------------------------------------------------- config i/o

function resolveConfigPath(ctx) {
  return config.resolvePath({ flag: ctx.flags.config, env: ctx.env, cwd: ctx.cwd });
}

/** Full precedence: flag > env > file > default. What the hub will actually run with. */
function loadEffective(ctx) {
  return config.load({
    path: ctx.file,
    env: ctx.env,
    flags: configFlags(ctx.flags),
    cwd: ctx.cwd,
  });
}

/**
 * The file, plus defaults, and nothing else -- deliberately env-free and
 * flag-free.
 *
 * Every verb that *writes* uses this. Editing through the effective config
 * would freeze the host's shell into the file: `RBY_MMO_PORT=9000` in one
 * terminal, an unrelated `config set log.level debug`, and the port is silently
 * pinned at 9000 for everyone forever after.
 */
function loadForEdit(ctx) {
  return config.load({ path: ctx.file, env: {}, flags: {}, cwd: ctx.cwd });
}

function requireExistingConfig(ctx) {
  const loaded = loadForEdit(ctx);
  if (!loaded.exists) {
    ctx.warn(`No configuration at ${ctx.file}.`);
    ctx.warn(`Run \`${PROGRAM} init\` first, or point at another file with --config.`);
    return null;
  }
  return loaded;
}

function reportWarnings(ctx, warnings, prefix) {
  for (const warning of warnings || []) ctx.warn(`${prefix || 'note'}: ${warning}`);
}

/**
 * config.load already folds the file-permission complaint into its warnings.
 * Every verb that also reports permissions in its own voice pulls it back out
 * here, so a host is told once rather than twice -- a report that repeats
 * itself reads as a report that is not sure.
 */
function splitWarnings(loaded) {
  const permission = config.checkPermissions(loaded.path);
  return {
    permission,
    warnings: permission
      ? loaded.warnings.filter((warning) => warning !== permission)
      : loaded.warnings,
  };
}

function saveConfig(ctx, cfg) {
  try {
    config.save(ctx.file, cfg);
    return true;
  } catch (err) {
    ctx.warn(`Could not write ${ctx.file}: ${err.message}`);
    return false;
  }
}

/** Masked copies, via the same masking `status` uses. */
function maskedCredentials(credentials) {
  const copy = config.redact({ auth: { credentials } });
  return (copy && copy.auth && copy.auth.credentials) || [];
}

// -------------------------------------------------------------------- init

function joinCodeBlock(ctx, code, extra) {
  ctx.say('');
  ctx.say('  ------------------------------------------------------------');
  ctx.say('');
  ctx.say(`      ${code}`);
  ctx.say('');
  ctx.say('  ------------------------------------------------------------');
  ctx.say('');
  ctx.say('  Give that to the friends you want in your world. They type it once,');
  ctx.say('  in game, on the screen where they enter this hub\'s address. Anyone');
  ctx.say('  without it is refused, in one sentence, and cannot get in.');
  for (const line of extra || []) ctx.say(`  ${line}`);
  ctx.say('');
  ctx.say('  This is the only time it is printed in full. To see it again:');
  ctx.say(`      ${PROGRAM} invite list --reveal`);
  ctx.say('');
}

/**
 * A question that always finishes.
 *
 * `rl.question()` on a stream that has already ended returns a promise that
 * never settles -- so a wizard built on it hangs forever the moment stdin is a
 * pipe rather than a terminal, which is exactly what `docker run` without `-t`,
 * a CI job and `printf ... | rby-mmo-hub init` all are. Racing each question
 * against the interface's own close event turns that hang into "take the
 * default and move on", which is what a host who pressed Ctrl-D meant anyway.
 */
function makePrompter(rl) {
  const state = { closed: false, truncated: false };
  rl.on('close', () => { state.closed = true; });

  const ask = async (question, fallback) => {
    if (state.closed) {
      state.truncated = true;
      return fallback;
    }
    try {
      const ended = new Promise((resolve) => {
        rl.once('close', () => resolve(undefined));
      });
      const answer = await Promise.race([rl.question(question), ended]);
      if (answer === undefined) {
        state.truncated = true;
        return fallback;
      }
      const text = String(answer).trim();
      return text === '' ? fallback : text;
    } catch (err) {
      state.truncated = true;
      return fallback;
    }
  };

  ask.state = state;
  return ask;
}

async function verbInit(ctx) {
  if (fs.existsSync(ctx.file) && ctx.flags.force !== true) {
    ctx.warn(`There is already a configuration at ${ctx.file}.`);
    ctx.warn('Re-run with --force to replace it -- that writes a new join code and');
    ctx.warn('everyone using the old one stops being able to join. To change one');
    ctx.warn(`setting instead, use \`${PROGRAM} config set\`.`);
    return ERROR;
  }

  // Start from what this hub would actually run with, so a container that sets
  // RBY_MMO_PORT gets that port written into the file it just created rather
  // than a default that only looks wrong.
  const loaded = loadEffective(ctx);
  const cfg = loaded.config;
  reportWarnings(ctx, loaded.warnings, 'config');

  let requireAuth = cfg.auth.required;

  if (ctx.flags.yes !== true) {
    ctx.say(`${PROGRAM} -- first-run setup`);
    ctx.say('');
    ctx.say('Four questions. Everything stays on this machine; nothing is sent');
    ctx.say('anywhere, now or later.');
    ctx.say('');

    const rl = readline.createInterface({ input: ctx.stdin, output: ctx.stdout });
    const ask = makePrompter(rl);
    try {
      cfg.listen.port = await ask(`  Port to listen on [${cfg.listen.port}]: `, cfg.listen.port);
      cfg.maxPlayers = await ask(`  How many players at once, 2-64 [${cfg.maxPlayers}]: `, cfg.maxPlayers);

      const authDefault = requireAuth ? 'Y/n' : 'y/N';
      const answer = await ask(`  Require a join code to connect? [${authDefault}]: `,
        requireAuth ? 'y' : 'n');
      requireAuth = /^(y|yes|true|1|on)$/i.test(String(answer).trim());
      cfg.auth.required = requireAuth;

      cfg.log.level = await ask(
        `  Log level -- debug, info, warn, error, silent [${cfg.log.level}]: `, cfg.log.level);
    } finally {
      try { rl.close(); } catch (err) { /* already closed */ }
      // readline resumes stdin; leave it paused so the process can exit on its
      // own when this verb returns.
      if (ctx.stdin && typeof ctx.stdin.pause === 'function') {
        try { ctx.stdin.pause(); } catch (err) { /* not a real tty */ }
      }
    }
    ctx.say('');

    if (ask.state.truncated) {
      // Node's readline throws away whatever else was buffered once the input
      // stream ends, so piping four answers in one go answers one question and
      // silently defaults the rest. Saying so beats a config that looks like it
      // took input it did not.
      ctx.warn('note: the input ended before every question was answered, so the');
      ctx.warn('      rest took their defaults. For a scripted run use the flags:');
      ctx.warn(`      ${PROGRAM} init --yes --port N --max N [--no-auth] [--log-level L]`);
    }
  }

  const checked = config.validate(cfg);
  reportWarnings(ctx, checked.warnings, 'adjusted');
  const final = checked.config;
  requireAuth = final.auth.required;

  let credential = null;
  if (requireAuth) {
    credential = auth.newCredential({ label: 'Primary join code' });
    // A stable, memorable id for the one credential a host will most often
    // name, matching the shape the plan documents (§3.5). Invites get random
    // ids; there is only ever one primary.
    credential.id = 'primary';
    final.auth.credentials = [credential];
  } else {
    final.auth.credentials = [];
  }

  if (!saveConfig(ctx, final)) return ERROR;

  ctx.say(`Configuration written to ${ctx.file} (mode 0600, readable only by you).`);
  ctx.say('');
  ctx.say(`  listening on   ${final.listen.host}:${final.listen.port}`);
  ctx.say(`  players        up to ${final.maxPlayers}`);
  ctx.say(`  join code      ${requireAuth ? 'required' : 'NOT required'}`);
  ctx.say(`  log level      ${final.log.level}`);

  if (credential) {
    ctx.say('');
    ctx.say('Your join code');
    joinCodeBlock(ctx, credential.secret);
  } else {
    ctx.say('');
    ctx.say('This hub does not require a join code, so anyone who can reach the');
    ctx.say('port can join it. That is fine on a LAN and a bad idea on the open');
    ctx.say(`internet. Turn it on later with \`${PROGRAM} config set auth.required true\``);
    ctx.say(`followed by \`${PROGRAM} invite\`.`);
  }

  ctx.say('Next:');
  ctx.say(`  ${PROGRAM} doctor      -- check the configuration and who can reach you`);
  ctx.say(`  ${PROGRAM} start       -- run the hub`);
  return OK;
}

// -------------------------------------------------------------------- start

async function verbStart(ctx) {
  const loaded = loadEffective(ctx);
  const cfg = loaded.config;
  const split = splitWarnings(loaded);
  reportWarnings(ctx, split.warnings, 'config');

  if (!loaded.exists) {
    ctx.warn(`No configuration at ${ctx.file}; running on defaults. \`${PROGRAM} init\` writes one.`);
  }
  /*
   * A group- or world-readable config file stops the hub, it does not merely
   * annoy it.
   *
   * This file is the hub's entire door: every join code is in it, in plaintext,
   * and anyone on this machine who can read it can walk in. Warning and
   * starting anyway would leave the exposure in place for as long as the hub
   * runs -- which is the whole time it matters. `doctor` already calls this a
   * [fail], the plan (§3.5) says the CLI refuses, and server/Dockerfile leans on
   * that promise as the reason /data may be 0700; all three now agree.
   *
   * The escape hatch is deliberately spelled for what it is rather than
   * `--force`: a host who types it is not forcing a step through, they are
   * accepting an insecure config file.
   */
  if (split.permission) {
    if (ctx.flags.insecureConfig !== true) {
      ctx.warn('');
      ctx.warn(`Refusing to start: ${split.permission}`);
      ctx.warn('');
      ctx.warn(`      chmod 600 ${loaded.path}`);
      ctx.warn('');
      ctx.warn(`  then run \`${PROGRAM} start\` again. Until then, anyone else on this`);
      ctx.warn('  machine can read a join code out of that file and walk in.');
      ctx.warn('');
      ctx.warn('  If this machine genuinely needs a looser mode, start with');
      ctx.warn('  --insecure-config and the hub will run on it.');
      ctx.warn('');
      return ERROR;
    }
    ctx.warn('');
    ctx.warn(`warning: --insecure-config. ${split.permission}`);
    ctx.warn('         Starting anyway, on your say-so. What you are accepting: every');
    ctx.warn('         join code in that file is readable by other users of this');
    ctx.warn('         machine, and anyone who reads one can join this hub as a player.');
    ctx.warn(`         \`chmod 600 ${loaded.path}\` ends that at any time.`);
    ctx.warn('');
  }

  const active = auth.activeCredentials(cfg.auth.credentials);
  if (cfg.auth.required && active.length === 0) {
    // Worth stopping for a moment: this configuration cannot admit anybody,
    // and the symptom a host would otherwise see is every friend being refused
    // for no visible reason.
    ctx.warn('');
    ctx.warn('warning: this hub requires a join code and has no usable one, so');
    ctx.warn(`         nobody can join it. Run \`${PROGRAM} invite\` to mint one, or`);
    ctx.warn(`         \`${PROGRAM} config set auth.required false\` to drop the requirement.`);
    ctx.warn('');
  }
  if (!cfg.auth.required) {
    ctx.warn('warning: authentication is off -- anyone who can reach this port can join.');
  }
  if (Array.isArray(cfg.allowlist) && cfg.allowlist.length > 0) {
    ctx.say(`Allowlist is active: only ${cfg.allowlist.length} address(es) may connect.`);
  }

  printLines(ctx, reachability.summary({
    port: cfg.listen.port,
    host: cfg.listen.host,
  }));
  ctx.say('');

  const logger = makeLog(cfg, ctx.stdout);

  let mapping = null;
  if (cfg.network.upnp.enabled) {
    ctx.say('UPnP is enabled; asking the router to forward the port...');
    const result = await upnp.addMapping({
      port: cfg.listen.port,
      leaseSeconds: cfg.network.upnp.leaseSeconds,
      description: 'RBY MMO hub',
    });
    if (result.ok) {
      mapping = result;
      ctx.say(`  forwarded TCP ${result.port} to ${result.internalAddress}` +
        (result.permanent
          ? ' with a permanent mapping (this router refuses leases; `upnp disable` removes it)'
          : ` for ${result.leaseSeconds}s, renewed by the router until this hub stops`));
    } else {
      ctx.warn(`  UPnP failed: ${result.error}`);
      ctx.warn('  The hub still starts; friends outside this network may not reach it.');
    }
    ctx.say('');
  }

  /*
   * Give the port back before the process goes.
   *
   * This used to be registered on SIGINT/SIGTERM here and fired
   * fire-and-forget, which never actually worked: removeMapping needs an SSDP
   * discovery *and* a SOAP POST, while server.js's own signal handler calls
   * process.exit(0) the moment close() settles -- so the removal was torn down
   * mid-flight, and process.exit does not fire 'beforeExit' either, so that
   * fallback never ran. The port stayed forwarded on the router after every
   * Ctrl-C and every `docker stop`, which is exactly the residual exposure the
   * removal exists to bound (plan §3.7) and exactly what `upnp enable` promises
   * does not happen.
   *
   * So it is handed to server.js's `onShutdown` hook instead: close() awaits it
   * before resolving, and the signal handler exits only after close() resolves.
   * One place, awaited, ahead of the exit.
   *
   * Bounded, and never fatal: an unreachable router costs a line of output and
   * the mapping's own lease cleans up after it. A hub that will not stop would
   * be the worse bug.
   */
  let unmapped = false;
  const dropMapping = async () => {
    if (unmapped || !mapping) return;
    unmapped = true; // once, whichever path gets here first
    const { port, device } = mapping;
    mapping = null;

    ctx.say(`Removing the UPnP mapping for TCP ${port}...`);
    try {
      const result = await withDeadline(upnp.removeMapping({ port, device }), UNMAP_TIMEOUT_MS);
      if (result === TIMED_OUT) {
        ctx.warn(`  the router did not answer within ${UNMAP_TIMEOUT_MS}ms; stopping ` +
          'anyway. A leased mapping expires on its own; `upnp disable` removes a permanent one.');
      } else if (result && result.ok) {
        ctx.say(result.alreadyGone ? '  there was no mapping left to remove' : '  removed');
      } else {
        ctx.warn(`  could not remove it: ${result && result.error ? result.error : 'unknown error'}`);
        ctx.warn(`  \`${PROGRAM} upnp disable\` tries again; a leased mapping expires on its own.`);
      }
    } catch (err) {
      ctx.warn(`  could not remove it: ${err && err.message ? err.message : err}`);
    }
  };

  let server;
  try {
    // Lazily required: see the header. Everything else in this CLI has to keep
    // working when this module is missing or mid-rewrite.
    server = require('./server.js');
  } catch (err) {
    ctx.warn(`Could not start: the server module is not available (${err.message}).`);
    ctx.warn('Every other command still works; this is the one that needs it.');
    return ERROR;
  }
  if (!server || typeof server.start !== 'function') {
    ctx.warn('Could not start: lib/server.js does not export start().');
    return ERROR;
  }

  let handle;
  try {
    handle = await server.start({
      config: cfg,
      log: logger,
      configPath: ctx.file,
      // Awaited by close(), bounded by server.js's own shutdown budget on top
      // of this one's. See dropMapping above for why it cannot live on a
      // signal handler here.
      onShutdown: dropMapping,
    });
  } catch (err) {
    ctx.warn(`The hub failed to start: ${err && err.message ? err.message : err}`);
    return ERROR;
  }

  // The handle's shape belongs to server.js, not here. Wait on whichever of
  // the usual spellings it offers; if it offers none, the listening socket is
  // holding the event loop open and this process ends when the hub does.
  try {
    if (handle && typeof handle.closed === 'object' && handle.closed &&
        typeof handle.closed.then === 'function') {
      await handle.closed;
    } else if (handle && typeof handle.wait === 'function') {
      await handle.wait();
    } else if (handle && typeof handle.done === 'object' && handle.done &&
        typeof handle.done.then === 'function') {
      await handle.done;
    } else {
      await new Promise(() => {});
    }
  } catch (err) {
    ctx.warn(`The hub stopped with an error: ${err && err.message ? err.message : err}`);
    return ERROR;
  }

  // Belt and braces for the path that never goes through close() -- a hub that
  // ended on its own. A no-op when onShutdown already ran.
  await dropMapping();
  return OK;
}

// ------------------------------------------------------------------- status

function describeValue(dotted, value) {
  if (dotted === 'auth.credentials') {
    const count = Array.isArray(value) ? value.length : 0;
    const active = auth.activeCredentials(value).length;
    return `${count} code(s), ${active} usable  (invite / revoke / invite list)`;
  }
  if (Array.isArray(value)) {
    return value.length === 0 ? '(empty)' : value.join(', ');
  }
  return String(value);
}

function verbStatus(ctx) {
  const loaded = loadEffective(ctx);
  const split = splitWarnings(loaded);
  reportWarnings(ctx, split.warnings, 'config');

  // Redacted, always. `status` is the command a host runs while somebody is
  // watching their screen.
  const shown = config.redact(loaded.config);

  ctx.say(`Configuration file: ${loaded.path}${loaded.exists ? '' : '  (does not exist yet)'}`);
  if (split.permission) ctx.say(`  warning: ${split.permission}`);
  ctx.say('');

  const rows = config.LEAF_PATHS.map((dotted) => [
    dotted,
    describeValue(dotted, config.getPath(shown, dotted)),
    loaded.sources[dotted] || 'default',
  ]);

  const nameWidth = Math.max(...rows.map((row) => row[0].length), 'SETTING'.length);
  const valueWidth = Math.max(...rows.map((row) => row[1].length), 'VALUE'.length);

  ctx.say(`${pad('SETTING', nameWidth)}  ${pad('VALUE', valueWidth)}  FROM`);
  for (const [name, value, source] of rows) {
    ctx.say(`${pad(name, nameWidth)}  ${pad(value, valueWidth)}  ${source}`);
  }

  ctx.say('');
  ctx.say('FROM: flag = this command line, env = an RBY_MMO_* variable,');
  ctx.say('      file = the configuration file, default = built in.');
  ctx.say('Join codes are masked here. `invite list --reveal` prints them.');
  return OK;
}

// ------------------------------------------------------------------- config

const UNSETTABLE = {
  'auth.credentials':
    'Join codes are not edited as text -- a mistyped one locks everybody out ' +
    `silently. Use \`${PROGRAM} invite\` to mint one and \`${PROGRAM} revoke <id>\` ` +
    'to withdraw it.',
};

function verbConfig(ctx, rest) {
  const action = rest[0];

  if (!action || action === 'list') {
    const loaded = loadEffective(ctx);
    reportWarnings(ctx, loaded.warnings, 'config');
    const shown = config.redact(loaded.config);
    const width = Math.max(...config.LEAF_PATHS.map((p) => p.length));
    for (const dotted of config.LEAF_PATHS) {
      const bounds = config.BOUNDS[dotted];
      const range = bounds ? `   (${bounds[0]}-${bounds[1]})` : '';
      ctx.say(`${pad(dotted, width)}  ${describeValue(dotted, config.getPath(shown, dotted))}${range}`);
    }
    return OK;
  }

  if (action === 'get') {
    const dotted = rest[1];
    if (!dotted) {
      ctx.warn(`Usage: ${PROGRAM} config get <path>`);
      return USAGE;
    }
    if (!config.LEAF_PATHS.includes(dotted)) {
      ctx.warn(`Unknown setting "${dotted}". \`${PROGRAM} config list\` prints every one.`);
      return USAGE;
    }
    const loaded = loadEffective(ctx);
    const shown = config.redact(loaded.config);
    const value = config.getPath(shown, dotted);
    ctx.say(typeof value === 'object' ? JSON.stringify(value, null, 2) : String(value));
    return OK;
  }

  if (action === 'set') {
    const dotted = rest[1];
    const raw = rest.length > 2 ? rest.slice(2).join(' ') : undefined;
    if (!dotted || raw === undefined) {
      ctx.warn(`Usage: ${PROGRAM} config set <path> <value>`);
      return USAGE;
    }
    if (UNSETTABLE[dotted] || dotted.startsWith('auth.credentials')) {
      ctx.warn(UNSETTABLE['auth.credentials']);
      return USAGE;
    }
    if (!config.LEAF_PATHS.includes(dotted)) {
      ctx.warn(`Unknown setting "${dotted}". \`${PROGRAM} config list\` prints every one.`);
      return USAGE;
    }
    if (dotted === 'version') {
      ctx.warn('version is the config file\'s schema version, not a setting. It is');
      ctx.warn('maintained by this software so older files keep loading.');
      return USAGE;
    }

    const loaded = requireExistingConfig(ctx);
    if (!loaded) return ERROR;
    const cfg = loaded.config;

    let value = raw;
    if (dotted === 'bans' || dotted === 'allowlist') {
      // Lists go through the same normaliser the ban verb uses, so a value set
      // this way cannot end up in a shape the limiter will not match.
      const entries = [];
      for (const piece of String(raw).split(/[\s,]+/)) {
        if (!piece) continue;
        const ip = limits.normalizeIp(piece);
        if (!ip) {
          ctx.warn(`"${piece}" is not an address this can normalise.`);
          return USAGE;
        }
        entries.push(ip);
      }
      value = entries;
    }

    const before = JSON.stringify(config.getPath(cfg, dotted));
    config.setPath(cfg, dotted, value);

    // Validate *before* saving and report every adjustment, so a host who
    // typed 9999 is told it became 64 now, rather than discovering it later
    // from a log line they were not reading.
    const checked = config.validate(cfg);
    const after = config.getPath(checked.config, dotted);
    for (const warning of checked.warnings) ctx.say(`adjusted: ${warning}`);

    if (!saveConfig(ctx, checked.config)) return ERROR;

    ctx.say(`${dotted} = ${describeValue(dotted, after)}`);
    if (JSON.stringify(after) === before) {
      ctx.say('(unchanged -- it was already that)');
    }
    if (config.ENV_MAP && Object.values(config.ENV_MAP).includes(dotted)) {
      const name = Object.keys(config.ENV_MAP).find((key) => config.ENV_MAP[key] === dotted);
      if (ctx.env && ctx.env[name] !== undefined && ctx.env[name] !== '') {
        ctx.say(`note: ${name} is set in this environment and outranks the file,`);
        ctx.say(`      so the hub will still use ${ctx.env[name]} until it is unset.`);
      }
    }
    ctx.say('Restart the hub for this to take effect.');
    return OK;
  }

  ctx.warn(`Unknown config command "${action}".`);
  printLines(ctx, HELP.config);
  return USAGE;
}

// ------------------------------------------------------------------ invites

function credentialState(credential, now) {
  if (credential.revoked) return 'revoked';
  if (credential.expiresAt) {
    const at = Date.parse(credential.expiresAt);
    if (!Number.isFinite(at)) return 'unreadable expiry';
    if (at <= now) return 'expired';
  }
  if (credential.maxUses !== null && credential.maxUses !== undefined &&
      Number(credential.uses || 0) >= Number(credential.maxUses)) {
    return 'used up';
  }
  return auth.isActive(credential, now) ? 'active' : 'unusable';
}

function shortDate(value) {
  if (!value) return '-';
  const at = Date.parse(value);
  if (!Number.isFinite(at)) return String(value).slice(0, 19);
  return new Date(at).toISOString().replace('T', ' ').slice(0, 16);
}

function verbInviteList(ctx) {
  const loaded = loadEffective(ctx);
  reportWarnings(ctx, loaded.warnings, 'config');

  const credentials = loaded.config.auth.credentials;
  if (!credentials.length) {
    ctx.say('No join codes.');
    if (loaded.config.auth.required) {
      ctx.say(`This hub requires one, so nobody can join. \`${PROGRAM} invite\` mints one.`);
    }
    return OK;
  }

  const reveal = ctx.flags.reveal === true;
  const shown = reveal ? credentials : maskedCredentials(credentials);
  const now = Date.now();

  const rows = credentials.map((credential, index) => [
    credential.id || '-',
    credential.label || '-',
    shortDate(credential.createdAt),
    credential.expiresAt ? shortDate(credential.expiresAt) : 'never',
    credential.maxUses ? `${credential.uses || 0}/${credential.maxUses}` : String(credential.uses || 0),
    credentialState(credential, now),
    shown[index] ? shown[index].secret : '-',
  ]);

  const headers = ['ID', 'LABEL', 'CREATED', 'EXPIRES', 'USES', 'STATUS', 'CODE'];
  const widths = headers.map((header, column) =>
    Math.max(header.length, ...rows.map((row) => String(row[column]).length)));

  ctx.say(headers.map((header, column) => pad(header, widths[column])).join('  ').trimEnd());
  for (const row of rows) {
    ctx.say(row.map((cell, column) => pad(cell, widths[column])).join('  ').trimEnd());
  }

  ctx.say('');
  if (reveal) {
    ctx.say('Codes are shown in full because --reveal was given. Anything that');
    ctx.say('records this terminal now holds them.');
  } else {
    ctx.say('Codes are masked. --reveal prints them in full.');
  }
  return OK;
}

function verbInvite(ctx, rest) {
  if (rest[0] === 'list') return verbInviteList(ctx);
  if (rest[0]) {
    ctx.warn(`Unknown invite command "${rest[0]}".`);
    printLines(ctx, HELP.invite);
    return USAGE;
  }

  let expiresAt = null;
  if (ctx.flags.expires !== undefined && ctx.flags.expires !== false) {
    const ms = parseDuration(ctx.flags.expires);
    if (ms === null) {
      ctx.warn(`--expires "${ctx.flags.expires}" is not a duration this understands.`);
      ctx.warn('Accepted forms: 30m (minutes), 24h (hours), 7d (days).');
      return USAGE;
    }
    expiresAt = new Date(Date.now() + ms).toISOString();
  }

  let maxUses = null;
  if (ctx.flags.uses !== undefined && ctx.flags.uses !== false) {
    const n = Math.floor(Number(ctx.flags.uses));
    if (!Number.isFinite(n) || n < 1) {
      ctx.warn(`--uses "${ctx.flags.uses}" is not a positive whole number.`);
      return USAGE;
    }
    maxUses = n;
  }

  const label = typeof ctx.flags.label === 'string' && ctx.flags.label
    ? ctx.flags.label
    : 'Invite';

  const loaded = requireExistingConfig(ctx);
  if (!loaded) return ERROR;
  const cfg = loaded.config;

  let credential;
  try {
    credential = auth.newCredential({ label, expiresAt, maxUses });
  } catch (err) {
    ctx.warn(`Could not mint a join code: ${err.message}`);
    return ERROR;
  }

  cfg.auth.credentials.push(credential);
  if (!saveConfig(ctx, cfg)) return ERROR;

  const notes = [];
  if (expiresAt) notes.push(`It stops working at ${shortDate(expiresAt)} UTC.`);
  if (maxUses) notes.push(`It can be used ${maxUses} time(s).`);

  ctx.say(`New join code (id ${credential.id}, ${credential.label})`);
  joinCodeBlock(ctx, credential.secret, notes);

  if (!cfg.auth.required) {
    ctx.say('note: this hub does not currently require a join code, so this one');
    ctx.say(`      is not needed to join. \`${PROGRAM} config set auth.required true\``);
    ctx.say('      makes it matter.');
  }
  ctx.say('Restart the hub for this code to be accepted.');
  return OK;
}

function verbRevoke(ctx, rest) {
  const id = rest[0];
  if (!id) {
    ctx.warn(`Usage: ${PROGRAM} revoke <id>   (ids come from \`${PROGRAM} invite list\`)`);
    return USAGE;
  }

  const loaded = requireExistingConfig(ctx);
  if (!loaded) return ERROR;
  const cfg = loaded.config;

  const exact = cfg.auth.credentials.filter((credential) => credential.id === id);
  const prefixed = cfg.auth.credentials.filter((credential) =>
    typeof credential.id === 'string' && credential.id.startsWith(id));
  const matches = exact.length ? exact : prefixed;

  if (matches.length === 0) {
    ctx.warn(`No join code with id "${id}". \`${PROGRAM} invite list\` shows them.`);
    return ERROR;
  }
  if (matches.length > 1) {
    ctx.warn(`"${id}" matches ${matches.length} join codes: ` +
      `${matches.map((credential) => credential.id).join(', ')}. Give a longer id.`);
    return ERROR;
  }

  const credential = matches[0];
  if (credential.revoked) {
    ctx.say(`${credential.id} was already revoked.`);
    return OK;
  }
  credential.revoked = true;
  if (!saveConfig(ctx, cfg)) return ERROR;

  ctx.say(`Revoked ${credential.id} (${credential.label}). Anyone holding that code`);
  ctx.say('is refused from the next restart onwards.');

  // A warning, not a refusal: locking yourself out is sometimes exactly what
  // you meant to do, and the software should not argue with a deliberate act.
  const remaining = auth.activeCredentials(cfg.auth.credentials).length;
  if (remaining === 0 && cfg.auth.required) {
    ctx.warn('');
    ctx.warn('warning: that was the last usable join code. This hub requires one,');
    ctx.warn(`         so nobody can join until you run \`${PROGRAM} invite\`.`);
  }
  return OK;
}

// ------------------------------------------------------------ bans, allowlist

function printList(ctx, title, entries) {
  if (!entries.length) {
    ctx.say(`${title}: (empty)`);
    return;
  }
  ctx.say(`${title}:`);
  for (const entry of entries) ctx.say(`  ${entry}`);
}

function verbBan(ctx, rest) {
  const given = rest[0];
  if (!given) {
    ctx.warn(`Usage: ${PROGRAM} ban <ip> [--reason TEXT]`);
    return USAGE;
  }
  // Normalised first, always: ::ffff:203.0.113.7 and 203.0.113.7 are the same
  // peer, and a ban stored in one spelling silently misses the other.
  const ip = limits.normalizeIp(given);
  if (!ip) {
    ctx.warn(`"${given}" is not an address this can normalise.`);
    return USAGE;
  }

  const loaded = requireExistingConfig(ctx);
  if (!loaded) return ERROR;
  const cfg = loaded.config;

  if (cfg.bans.includes(ip)) {
    ctx.say(`${ip} was already banned.`);
  } else {
    cfg.bans.push(ip);
    if (!saveConfig(ctx, cfg)) return ERROR;
    ctx.say(`Banned ${ip}.`);
  }
  if (typeof ctx.flags.reason === 'string' && ctx.flags.reason) {
    // Honest about the schema: the ban list holds addresses, so the reason is
    // for this terminal only. Storing it inline would break the normalised
    // comparison the limiter does.
    ctx.say(`Reason (not stored -- the ban list holds addresses only): ${ctx.flags.reason}`);
  }
  printList(ctx, 'Banned addresses', cfg.bans);
  ctx.say('Restart the hub to apply it to connections already open.');
  return OK;
}

function verbUnban(ctx, rest) {
  const given = rest[0];
  if (!given) {
    ctx.warn(`Usage: ${PROGRAM} unban <ip>`);
    return USAGE;
  }
  const ip = limits.normalizeIp(given);
  if (!ip) {
    ctx.warn(`"${given}" is not an address this can normalise.`);
    return USAGE;
  }

  const loaded = requireExistingConfig(ctx);
  if (!loaded) return ERROR;
  const cfg = loaded.config;

  const before = cfg.bans.length;
  cfg.bans = cfg.bans.filter((entry) => limits.normalizeIp(entry) !== ip);
  if (cfg.bans.length === before) {
    ctx.say(`${ip} was not banned; nothing to do.`);
    printList(ctx, 'Banned addresses', cfg.bans);
    return OK;
  }
  if (!saveConfig(ctx, cfg)) return ERROR;
  ctx.say(`Unbanned ${ip}.`);
  printList(ctx, 'Banned addresses', cfg.bans);
  return OK;
}

function verbAllow(ctx, rest) {
  const given = rest[0];

  if (!given && ctx.flags.clear !== true) {
    const loaded = loadEffective(ctx);
    reportWarnings(ctx, loaded.warnings, 'config');
    printList(ctx, 'Allowlist', loaded.config.allowlist);
    if (loaded.config.allowlist.length) {
      ctx.say('');
      ctx.say('The allowlist has entries, so ONLY those addresses may connect.');
    } else {
      ctx.say('');
      ctx.say('Empty, so any address may connect (subject to the join code and bans).');
    }
    return OK;
  }

  const loaded = requireExistingConfig(ctx);
  if (!loaded) return ERROR;
  const cfg = loaded.config;

  if (ctx.flags.clear === true) {
    cfg.allowlist = [];
    if (!saveConfig(ctx, cfg)) return ERROR;
    ctx.say('Allowlist cleared. Any address may connect again.');
    printList(ctx, 'Allowlist', cfg.allowlist);
    return OK;
  }

  const ip = limits.normalizeIp(given);
  if (!ip) {
    ctx.warn(`"${given}" is not an address this can normalise.`);
    return USAGE;
  }

  const wasEmpty = cfg.allowlist.length === 0;
  if (cfg.allowlist.includes(ip)) {
    ctx.say(`${ip} was already on the allowlist.`);
  } else {
    if (wasEmpty) {
      // Said before the change lands, plainly, because this is the one command
      // here that can lock a host out of their own hub from a friend's phone.
      ctx.say('This is the first allowlist entry. An allowlist with entries is');
      ctx.say('exclusive: from now on ONLY the addresses below may connect, and');
      ctx.say(`everyone else is refused. \`${PROGRAM} allow --clear\` undoes that.`);
      ctx.say('');
    }
    cfg.allowlist.push(ip);
    if (!saveConfig(ctx, cfg)) return ERROR;
    ctx.say(`Allowed ${ip}.`);
  }
  printList(ctx, 'Allowlist', cfg.allowlist);
  return OK;
}

// ------------------------------------------------------------------- doctor

function mark(ctx, level, line) {
  const tags = { ok: '[ ok ]', warn: '[warn]', fail: '[fail]' };
  ctx.say(`  ${tags[level]} ${line}`);
}

async function verbDoctor(ctx) {
  const loaded = loadEffective(ctx);
  const cfg = loaded.config;
  let failed = false;

  ctx.say(`${PROGRAM} doctor`);
  ctx.say('');
  ctx.say('Configuration');

  if (loaded.exists) {
    mark(ctx, 'ok', `${loaded.path}`);
  } else {
    mark(ctx, 'warn', `no file at ${loaded.path}; running on defaults ` +
      `(\`${PROGRAM} init\` writes one)`);
  }
  const split = splitWarnings(loaded);
  for (const warning of split.warnings) mark(ctx, 'warn', warning);

  if (split.permission) {
    failed = true;
    mark(ctx, 'fail', split.permission);
  } else if (loaded.exists) {
    mark(ctx, 'ok', 'the file is readable only by its owner');
  }

  // Auth. Deliberately counts, never codes -- doctor output is the thing a
  // host pastes into a forum thread when asking for help.
  const credentials = cfg.auth.credentials;
  const active = auth.activeCredentials(credentials);
  if (!cfg.auth.required) {
    mark(ctx, 'warn', 'auth.required is false: anyone who reaches the port can join');
  } else if (active.length === 0) {
    failed = true;
    mark(ctx, 'fail', 'a join code is required and none is usable, so nobody can ' +
      `join -- run \`${PROGRAM} invite\``);
  } else {
    mark(ctx, 'ok', `a join code is required; ${active.length} usable of ${credentials.length}`);
  }

  const now = Date.now();
  const stale = credentials.filter((credential) => {
    const state = credentialState(credential, now);
    return state === 'expired' || state === 'used up' || state === 'unreadable expiry';
  });
  if (stale.length) {
    mark(ctx, 'warn', `${stale.length} join code(s) no longer work ` +
      `(${stale.map((credential) => `${credential.id}: ${credentialState(credential, now)}`).join(', ')})`);
  }

  // Port and bind address.
  const port = cfg.listen.port;
  if (port < 1024) {
    mark(ctx, 'warn', `port ${port} is privileged: on Linux and macOS the hub has ` +
      'to run as root or hold CAP_NET_BIND_SERVICE to bind it');
  } else {
    mark(ctx, 'ok', `port ${port} is in the unprivileged range`);
  }

  const host = cfg.listen.host;
  if (host === '0.0.0.0' || host === '::') {
    mark(ctx, 'ok', `bound to ${host}: every address on this machine accepts connections`);
  } else if (reachability.classifyAddress(host, host.includes(':') ? 'IPv6' : 'IPv4') ===
      reachability.LOOPBACK) {
    failed = true;
    mark(ctx, 'fail', `bound to ${host}, which is this machine talking to itself: ` +
      'no friend can connect. Set listen.host to 0.0.0.0');
  } else {
    mark(ctx, 'warn', `bound to ${host} only; connections to this machine's other ` +
      'addresses are refused');
  }

  // Limits worth a second look.
  if (cfg.limits.perIpConnections >= cfg.maxPlayers) {
    mark(ctx, 'warn', `limits.perIpConnections (${cfg.limits.perIpConnections}) is not ` +
      `below maxPlayers (${cfg.maxPlayers}), so one address could take every seat`);
  }
  if (cfg.limits.idleTimeoutMs <= cfg.limits.handshakeTimeoutMs) {
    mark(ctx, 'warn', 'limits.idleTimeoutMs is not greater than ' +
      'limits.handshakeTimeoutMs, which makes the handshake budget meaningless');
  }
  if (cfg.limits.chatIntervalMs === 0) {
    mark(ctx, 'warn', 'limits.chatIntervalMs is 0: the chat flood gate is off');
  }
  if (cfg.allowlist.length) {
    mark(ctx, 'warn', `the allowlist has ${cfg.allowlist.length} entr(y/ies), so ONLY ` +
      'those addresses may connect');
  }
  if (cfg.bans.length) {
    mark(ctx, 'ok', `${cfg.bans.length} address(es) banned`);
  }

  // Router. Only asked when the host turned UPnP on -- see upnp.js's header.
  ctx.say('');
  ctx.say('Router');
  let external = null;
  if (cfg.network.upnp.enabled) {
    const found = await upnp.discover({ timeoutMs: 3000 });
    if (!found.ok) {
      mark(ctx, 'warn', `UPnP is enabled but no router answered: ${found.error}`);
    } else {
      mark(ctx, 'ok', `router at ${found.router} speaks UPnP`);
      const mapping = await upnp.getMapping({ port, device: found });
      if (mapping.ok && mapping.mapped) {
        mark(ctx, 'ok', `TCP ${port} is forwarded to ${mapping.internalAddress}:` +
          `${mapping.internalPort}` +
          (mapping.leaseSeconds ? ` (lease ${mapping.leaseSeconds}s)` : ' (permanent)'));
      } else if (mapping.ok) {
        mark(ctx, 'warn', `TCP ${port} is not currently forwarded; \`${PROGRAM} start\` ` +
          'asks for it, or `upnp enable` asks now');
      } else {
        mark(ctx, 'warn', `could not read the mapping: ${mapping.error}`);
      }
      const ip = await upnp.externalIp({ device: found });
      if (ip.ok && ip.up) {
        external = ip.address;
        mark(ctx, 'ok', `the router's external address is ${ip.address}`);
      } else if (ip.ok) {
        mark(ctx, 'warn', 'the router reports no external address; its own uplink may be down');
      } else {
        mark(ctx, 'warn', `could not ask the router for its address: ${ip.error}`);
      }
    }
  } else {
    mark(ctx, 'ok', 'UPnP is off. Nothing on this machine asks the router for ' +
      `anything (\`${PROGRAM} upnp enable\` changes that)`);
  }

  ctx.say('');
  printLines(ctx, reachability.summary({ port, host, external }));

  ctx.say('');
  ctx.say(failed
    ? 'Something above would stop players connecting. Fix the [fail] lines.'
    : 'Nothing here would stop players connecting.');
  return failed ? ERROR : OK;
}

// --------------------------------------------------------------------- upnp

async function verbUpnp(ctx, rest) {
  const action = rest[0];
  if (!action || !['enable', 'disable', 'status'].includes(action)) {
    ctx.warn(`Usage: ${PROGRAM} upnp enable|disable|status`);
    return USAGE;
  }

  const loaded = action === 'status' ? loadEffective(ctx) : requireExistingConfig(ctx);
  if (!loaded) return ERROR;
  const cfg = loaded.config;
  const port = cfg.listen.port;

  if (action === 'status') {
    ctx.say(`UPnP is ${cfg.network.upnp.enabled ? 'enabled' : 'disabled'} in the ` +
      `configuration (lease ${cfg.network.upnp.leaseSeconds}s).`);
    ctx.say('Asking the router...');
    const found = await upnp.discover({ timeoutMs: 3000 });
    if (!found.ok) {
      ctx.say(`  ${found.error}`);
      return OK;
    }
    ctx.say(`  router: ${found.router} (${found.serviceType})`);
    const mapping = await upnp.getMapping({ port, device: found });
    if (mapping.ok && mapping.mapped) {
      ctx.say(`  mapping: TCP ${port} -> ${mapping.internalAddress}:${mapping.internalPort}` +
        (mapping.description ? `  "${mapping.description}"` : '') +
        (mapping.leaseSeconds ? `  lease ${mapping.leaseSeconds}s` : '  permanent'));
    } else if (mapping.ok) {
      ctx.say(`  mapping: none for TCP ${port}`);
    } else {
      ctx.say(`  mapping: could not be read (${mapping.error})`);
    }
    const ip = await upnp.externalIp({ device: found });
    if (ip.ok) {
      ctx.say(`  external address: ${ip.address}${ip.up ? '' : '  (the uplink looks down)'}`);
    } else {
      ctx.say(`  external address: unknown (${ip.error})`);
    }
    return OK;
  }

  if (action === 'enable') {
    // The warning comes first and in full, before a single packet is sent.
    printLines(ctx, upnp.ENABLE_WARNING);
    ctx.say('');
    ctx.say(`Asking the router to forward TCP ${port}...`);

    const result = await upnp.addMapping({
      port,
      leaseSeconds: cfg.network.upnp.leaseSeconds,
      description: 'RBY MMO hub',
    });
    if (!result.ok) {
      ctx.warn(`  failed: ${result.error}`);
      ctx.warn('  UPnP has been left disabled in the configuration. Forward TCP');
      ctx.warn(`  ${port} on the router by hand instead -- the hub does not care`);
      ctx.warn('  which way the port got opened.');
      return ERROR;
    }

    ctx.say(`  forwarded TCP ${result.port} to ${result.internalAddress}` +
      (result.permanent
        ? ' as a PERMANENT mapping -- this router refuses leases, so it will'
        : ` on a ${result.leaseSeconds}s lease`));
    if (result.permanent) {
      ctx.say('  outlive this process. `upnp disable` removes it.');
    }

    cfg.network.upnp.enabled = true;
    if (!saveConfig(ctx, cfg)) return ERROR;
    ctx.say(`UPnP enabled. \`${PROGRAM} start\` will renew the mapping and remove it`);
    ctx.say('on a clean shutdown.');
    return OK;
  }

  // disable
  ctx.say(`Removing any mapping for TCP ${port}...`);
  const removed = await upnp.removeMapping({ port });
  if (removed.ok) {
    ctx.say(removed.alreadyGone ? '  there was no mapping to remove' : '  removed');
  } else {
    ctx.say(`  could not remove it: ${removed.error}`);
    ctx.say('  A leased mapping expires on its own; a permanent one has to be');
    ctx.say('  removed on the router.');
  }
  cfg.network.upnp.enabled = false;
  if (!saveConfig(ctx, cfg)) return ERROR;
  ctx.say('UPnP disabled. Nothing here will ask the router for anything again.');
  return OK;
}

// ---------------------------------------------------------------- the runner

/**
 * @param {string[]} argv  arguments after the program name
 * @param {object} io      { stdout, stderr, stdin, env?, cwd? }
 * @returns {Promise<number>} 0 success, 1 runtime error, 2 usage error
 */
async function run(argv, io) {
  const base = makeIo(io);
  const { positional, flags } = parseArgs(Array.isArray(argv) ? argv : []);

  const ctx = Object.assign({}, base, { flags, positional, file: null });

  if (flags.version === true) {
    ctx.say(`${PROGRAM} ${version()}`);
    return OK;
  }

  const verb = positional[0];
  const rest = positional.slice(1);

  if (!verb) {
    // A bare invocation is somebody looking for the manual, not an error.
    return help(ctx, '');
  }
  if (verb === 'help') return help(ctx, rest[0] || '');
  if (flags.help === true) return help(ctx, verb);

  try {
    ctx.file = resolveConfigPath(ctx);
  } catch (err) {
    ctx.warn(`Could not work out which config file to use: ${err.message}`);
    return ERROR;
  }

  try {
    switch (verb) {
      case 'init': return await verbInit(ctx);
      case 'start': return await verbStart(ctx);
      case 'status': return verbStatus(ctx);
      case 'config': return verbConfig(ctx, rest);
      case 'invite': return verbInvite(ctx, rest);
      case 'revoke': return verbRevoke(ctx, rest);
      case 'ban': return verbBan(ctx, rest);
      case 'unban': return verbUnban(ctx, rest);
      case 'allow': return verbAllow(ctx, rest);
      case 'doctor': return await verbDoctor(ctx);
      case 'upnp': return await verbUpnp(ctx, rest);
      case 'version': ctx.say(`${PROGRAM} ${version()}`); return OK;
      default:
        ctx.warn(`Unknown command "${verb}".`);
        ctx.warn(`\`${PROGRAM} help\` lists them.`);
        return USAGE;
    }
  } catch (err) {
    // The last wall. A verb that throws is a bug in this software, not the
    // host's fault, so it reports a sentence rather than a stack trace -- and
    // it reports it on stderr, so a piped `config get` stays machine-readable.
    ctx.warn(`${PROGRAM} ${verb} failed: ${err && err.message ? err.message : String(err)}`);
    if (ctx.env && ctx.env.RBY_MMO_DEBUG && err && err.stack) ctx.warn(err.stack);
    return ERROR;
  }
}

module.exports = {
  run,
  // exported for the test suite, which drives the parser directly rather than
  // inferring its behaviour from a verb's output
  parseArgs,
  parseDuration,
  version,
  OK,
  ERROR,
  USAGE,
};
