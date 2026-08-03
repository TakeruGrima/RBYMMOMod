'use strict';

/*
 * The socket layer, and only the socket layer.
 *
 * Everything that decides *anything* already lives somewhere else: the
 * protocol in lib/relay.js, the hardening in lib/limits.js, the crypto in
 * lib/auth.js, the file in lib/config.js. This module owns the one thing
 * none of them may touch -- a real net.Server -- and hands them the bytes.
 *
 * Keeping the split that strict is what makes the hub testable at all. The
 * relay is driven by peer handles, so a suite can pair two of them in memory
 * and never bind a port; the limits are pure bookkeeping over an injected
 * clock, so an hour of idleness costs a test nothing. Reintroducing a policy
 * decision down here would quietly move it back out of reach of both.
 *
 * Three behaviours below are deliberate and easy to mistake for oversights:
 *
 *  - **A seat is charged at hello, not at accept** (plan §3.6). Ungreeted
 *    sockets are bounded by limits.maxPending and reaped by
 *    limits.handshakeTimeoutMs instead, so four silent sockets can no longer
 *    lock everyone out of a four-player hub the way hub.js:369 allowed. The
 *    one courtesy exception is spelled out at its call site.
 *  - **There is exactly one timer**, a ~1 s sweep, plus the one-second
 *    forced-close budget on shutdown. Per-socket timers were how the old
 *    hub conflated "has not finished its handshake" with "has said nothing
 *    for a while", which are different failures with different budgets.
 *  - **A rejected connection is destroyed without a reply when the rejection
 *    is a flood signal**, and answered in one sentence when it is not. Bytes
 *    spent on a flooder are the attack; bytes spent on an honest friend
 *    behind the same NAT are the whole point of having a message at all.
 *
 * No dependencies: node:net plus this directory.
 */

const net = require('node:net');
const process = require('node:process');

const { Relay, parseLine } = require('./relay.js');
const { Limits, normalizeIp } = require('./limits.js');
const auth = require('./auth.js');
const { createLog, safe } = require('./log.js');

// The ceiling on a single unterminated line, unchanged from hub.js:34. A
// peer that buffers more than this without a newline is not sending a
// message, and the buffer is charged to the host's memory either way.
const MAX_LINE = 64 * 1024;

// How often the sweep asks limits.js who has run out of time. A second is
// far finer than any of the budgets it enforces (the shortest is ten
// seconds) and coarse enough that an idle hub does no measurable work.
const SWEEP_INTERVAL_MS = 1000;

// How long a goodbye gets to reach the wire before the socket is taken away.
// A peer that never closes its own half would otherwise leave server.close()
// waiting forever; hub.js:459 has always drawn that line at one second.
const FORCE_CLOSE_MS = 1000;

// Headroom over the app-level caps for the libuv-level backstop: sockets
// mid-refusal, and the gap between a peer disappearing and the close event
// arriving, are both real and neither should be able to make the backstop
// fire before the checks that produce a sentence do.
const CONNECTION_SLACK = 8;

// A rejection that is a flood signal costs the sender nothing but the
// SYN. A rejection an honest player could plausibly hit gets a sentence,
// because the client already renders mmo.error (src/Client.lua:463-467) and
// a friend behind the same NAT as three other friends deserves to know why.
function refusalFor(reason, limits) {
  switch (reason) {
    case 'per_ip':
      return `Too many connections from your address ` +
        `(${limits.perIpConnections}).`;
    case 'pending':
      return 'This hub is busy letting other players in; try again in a moment.';
    case 'not_allowed':
      // Not silent, unlike a ban: the common case is not a stranger but a
      // friend whose address moved, and a scanner learns nothing here it
      // did not already learn by finding the port open.
      return 'This hub only accepts connections from addresses its host has allowed.';
    default:
      return null; // 'banned', 'rate' -- answered with silence
  }
}

/*
 * The auth port the relay expects: null, or exactly newNonce() and
 * verify(nonce, response). The relay knows the shape of the handshake and
 * nothing about the cryptography behind it, which is what lets a suite drive
 * the challenge with a stub.
 *
 * Null when auth is off, rather than a port that admits everyone -- with no
 * port at all the exchange is byte-identical to the one hub.js has always
 * spoken, so a LAN game gains no round trip it did not ask for.
 */
function authPort(config) {
  const settings = (config && config.auth) || {};
  if (!settings.required) return null;
  const credentials = Array.isArray(settings.credentials)
    ? settings.credentials : [];
  return {
    newNonce() {
      return auth.newNonce();
    },
    verify(nonce, response) {
      return auth.verify(nonce, response, credentials);
    },
  };
}

// config.js accepts 'silent' as a log level; log.js knows four levels and
// reads anything else as 'info'. Rather than let a host who asked for
// silence get chatter, silence is spelled here as a stream that discards --
// the level vocabulary belongs to config.js and the writing to log.js, and
// neither should have to learn the other's spelling.
const NULL_STREAM = { write() {} };

function logFor(config) {
  const level = (config && config.log && config.log.level) || 'info';
  if (level === 'silent') return createLog({ level: 'error', stream: NULL_STREAM });
  return createLog({ level });
}

/**
 * Bind a hub to a port.
 *
 * Resolves to { port, host, close(), relay, limits, stats() } once the
 * listener is up, and rejects if it never comes up -- so a caller can report
 * "address already in use" as the one thing that actually went wrong rather
 * than as a stack trace.
 *
 * `handleSignals` defaults to true, which is what a process whose whole job
 * is the hub wants. An embedded caller -- a suite starting three hubs in one
 * process -- passes false, so stopping one of them does not hijack SIGINT
 * for the rest.
 */
function start(options = {}) {
  const opts = options || {};
  const config = opts.config || {};
  const listen = config.listen || {};
  const log = opts.log || logFor(config);
  const configPath = opts.configPath || null;
  const handleSignals = opts.handleSignals !== false;

  const limits = new Limits(config.limits || {});
  limits.setBans(config.bans);
  limits.setAllowlist(config.allowlist);

  const relay = new Relay({
    maxPlayers: config.maxPlayers,
    chatIntervalMs: config.limits && config.limits.chatIntervalMs,
    protocol: config.protocol,
    auth: authPort(config),
    log,
  });

  /** Registered sockets, so shutdown can reach the ones that will not leave. */
  const sockets = new Set();
  /*
   * Sockets refused before they were ever registered. They are invisible to
   * limits.js by design -- charging a refusal would let a flooder fill the
   * table it was just refused by -- so they are parked here and destroyed on
   * the next sweep. One second is long past enough to have flushed one short
   * line, and it keeps this file to a single timer.
   */
  const farewells = new Set();

  const startedAt = Date.now();
  let closePromise = null;
  let stopping = false;

  // ------------------------------------------------------------ refusals

  function farewell(socket, message) {
    // A peer can vanish between accept and this write; that is its problem,
    // not the hub's, and it must not reach the connection listener as a throw.
    socket.on('error', () => {});
    socket.on('close', () => farewells.delete(socket));
    try {
      socket.end(JSON.stringify({ type: 'mmo.error', message }) + '\n');
      farewells.add(socket);
    } catch (err) {
      socket.destroy();
    }
  }

  // ---------------------------------------------------------- connections

  function onConnection(socket) {
    const ip = normalizeIp(socket.remoteAddress);

    const verdict = limits.admit(ip);
    if (!verdict.ok) {
      const message = refusalFor(verdict.reason, limits);
      log.debug(`refused ${safe(ip)}: ${verdict.reason}`);
      if (message === null) return socket.destroy();
      return farewell(socket, message);
    }

    /*
     * The one place a connection is turned away before it has said anything.
     *
     * This is safe precisely because isFull() counts *greeted players*: a
     * silent socket is not a player and cannot make this true, so the
     * lock-out §3.6 exists to fix cannot happen through it. What it buys is
     * that someone arriving at a genuinely full hub is told so now instead
     * of after a handshake nobody has room for -- which is both the better
     * experience and the sentence hub.js has always sent here.
     */
    if (relay.isFull()) {
      return farewell(socket, `This hub is full (${relay.maxPlayers} players).`);
    }

    limits.register(socket, ip);
    sockets.add(socket);

    socket.setNoDelay(true);
    socket.setEncoding('utf8');

    const peer = {
      remoteAddress: ip,
      send(message) {
        if (socket.destroyed) return;
        /*
         * hub.js:130 called socket.write() and discarded the boolean, so a
         * peer that connected and never read grew the hub's write buffer
         * without bound while looking, from outside, like a healthy player.
         * The buffer is the hazard, so the buffer is what is judged.
         */
        if (!limits.writeAllowed(socket, socket.writableLength)) {
          log.warn(`dropping ${safe(ip)}: ${socket.writableLength} bytes queued, ` +
            `over the ${limits.maxWriteBufferBytes} byte ceiling`);
          socket.destroy();
          return;
        }
        // May throw on a message that will not serialise; the relay catches
        // that and spends the connection rather than the hub.
        socket.write(JSON.stringify(message) + '\n');
      },
      close() {
        socket.end();
      },
    };

    const id = relay.accept(peer);
    let greeted = false;
    let buffer = '';

    socket.on('data', (chunk) => {
      buffer += chunk;
      const completedLine = buffer.indexOf('\n') >= 0;
      // Two clocks, not one: "is this peer alive" and "has it finished a
      // sentence since it started one". The second is what catches a client
      // dribbling a byte a minute under both the buffer cap and the idle
      // timeout.
      limits.noteActivity(socket, { bytes: chunk.length, completedLine });

      if (buffer.length > MAX_LINE) {
        const client = relay.get(id);
        if (client) relay.refuse(client, 'Message too long.');
        else socket.destroy();
        return;
      }

      let index;
      while ((index = buffer.indexOf('\n')) >= 0) {
        const line = buffer.slice(0, index);
        buffer = buffer.slice(index + 1);
        if (!line) continue;

        const msg = parseLine(line);
        if (!msg) continue; // a malformed line is dropped, never fatal
        relay.handle(id, msg);

        /*
         * The seam for "the handshake is over". relay.js exposes no event
         * for it and should not grow one for the socket layer's benefit --
         * greeted(id) is the same fact, asked rather than announced, and it
         * covers both doors into ready: straight from hello on an open hub,
         * and from a passing mmo.auth on one that challenges.
         */
        if (!greeted && relay.greeted(id)) {
          greeted = true;
          limits.markGreeted(socket);
        }
      }
    });

    // Both fire for a socket that errors, which is the normal case rather
    // than the exotic one; both sides of this are idempotent for exactly
    // that reason.
    const done = () => {
      sockets.delete(socket);
      limits.release(socket);
      relay.drop(id);
    };
    socket.on('error', done);
    socket.on('close', done);
  }

  const server = net.createServer(onConnection);

  // The libuv-level backstop, underneath every check above. It cannot
  // produce a sentence, so it is set high enough that the checks that can
  // are always the ones that fire first.
  server.maxConnections = relay.maxPlayers + limits.maxPending + CONNECTION_SLACK;

  // ---------------------------------------------------------------- sweep

  const sweeper = setInterval(() => {
    for (const doomed of limits.sweep()) {
      log.debug(`closing a connection: ${doomed.reason}`);
      doomed.key.destroy();
    }
    for (const socket of farewells) socket.destroy();
    farewells.clear();
  }, SWEEP_INTERVAL_MS);
  // An unref'd interval never keeps the process alive on its own account,
  // so the hub still exits the moment the listener and its sockets are gone.
  sweeper.unref();

  // ------------------------------------------------------------- shutdown

  function close() {
    if (closePromise) return closePromise;
    clearInterval(sweeper);
    detach();

    closePromise = new Promise((resolve) => {
      let forced = null;
      let settled = false;
      const finish = () => {
        if (settled) return;
        settled = true;
        if (forced) clearTimeout(forced);
        resolve();
      };

      // Stop accepting first, so nobody joins a hub that is leaving, and
      // only then say goodbye -- in that order the players still on the wire
      // actually receive it. There is no host migration, so saying so is the
      // honest thing rather than leaving clients talking to a dead listener.
      server.close(finish);
      relay.shutdown();
      for (const socket of farewells) socket.destroy();
      farewells.clear();

      forced = setTimeout(() => {
        for (const socket of sockets) socket.destroy();
        sockets.clear();
        finish();
      }, FORCE_CLOSE_MS);
      forced.unref();
    });
    return closePromise;
  }

  // ---------------------------------------------------- process handlers

  const onSignal = () => {
    if (stopping) return; // a second ^C must not race the first one's exit
    stopping = true;
    log.info('shutting down');
    const exit = () => process.exit(0);
    close().then(exit, exit);
  };

  /*
   * One bad code path must not end everyone's session. A hub is a thing
   * friends are in the middle of using; a crash costs them a battle, a trade
   * and a reconnect the client cannot even do for them
   * (src/Transport.lua:163). Logging and carrying on is strictly better than
   * dying, and every path that can actually corrupt state already spends its
   * own connection rather than the process.
   */
  const onUncaught = (err) => {
    log.error(`uncaught error, continuing: ${safe(err && err.message ? err.message : err)}`);
  };
  const onUnhandled = (reason) => {
    log.error(`unhandled rejection, continuing: ` +
      `${safe(reason && reason.message ? reason.message : reason)}`);
  };

  function attach() {
    if (!handleSignals) return;
    process.on('SIGINT', onSignal);
    process.on('SIGTERM', onSignal);
    process.on('uncaughtException', onUncaught);
    process.on('unhandledRejection', onUnhandled);
  }

  function detach() {
    if (!handleSignals) return;
    process.removeListener('SIGINT', onSignal);
    process.removeListener('SIGTERM', onSignal);
    process.removeListener('uncaughtException', onUncaught);
    process.removeListener('unhandledRejection', onUnhandled);
  }

  // --------------------------------------------------------------- listen

  const host = typeof listen.host === 'string' && listen.host
    ? listen.host : '0.0.0.0';
  const port = Number(listen.port);

  return new Promise((resolve, reject) => {
    const onListenError = (err) => {
      clearInterval(sweeper);
      detach();
      reject(err);
    };
    server.once('error', onListenError);

    server.listen(port, host, () => {
      server.removeListener('error', onListenError);
      // After the bind, an error is something that happened to one accept
      // (EMFILE, ECONNABORTED), not a reason to take the hub away from the
      // players already on it.
      server.on('error', (err) => log.error(`listener error: ${safe(err.message)}`));

      const address = server.address();
      const boundHost = address && address.address ? address.address : host;
      const boundPort = address && address.port ? address.port : port;

      attach();
      log.info(`RBY MMO hub listening on ${boundHost}:${boundPort} ` +
        `(protocol ${relay.protocol})`);

      resolve({
        host: boundHost,
        port: boundPort,
        configPath,
        relay,
        limits,
        close,
        // The shape the CLI's `status` verb prints. Derived on every call so
        // it can never be a stale copy of the thing it is describing.
        stats() {
          const counts = limits.stats();
          return {
            host: boundHost,
            port: boundPort,
            protocol: relay.protocol,
            maxPlayers: relay.maxPlayers,
            players: relay.playerCount,
            pending: relay.pendingCount,
            connections: counts.connections,
            perIp: counts.perIp,
            authRequired: Boolean(relay.auth),
            startedAt,
            uptimeMs: Date.now() - startedAt,
          };
        },
      });
    });
  });
}

module.exports = { start, MAX_LINE, SWEEP_INTERVAL_MS };
