'use strict';

/*
 * Connection-level limits for the hub.
 *
 * This is the difference between a relay for friends and something that can
 * be left listening on a public address. `hub.js` today has exactly one
 * limit -- a global player cap -- so a single address can take every seat,
 * an unlimited number of connections can be attempted per second, and one
 * `socket.setTimeout(45000)` doubles as both the handshake budget and the
 * idle timeout. All of that is closed here.
 *
 * **No sockets appear anywhere below, and no timers.** Everything is pure
 * bookkeeping over an injected clock, driven by the caller: `admit` before a
 * client record exists, `register`/`markGreeted`/`noteActivity`/`release`
 * across the connection's life, and `sweep` on whatever tick the server
 * already runs. That is the same split `src/Hub.lua` uses for the relay
 * itself, and for the same reason: it makes every rule testable under a
 * plain unit test with no port opened and no wall clock waited on.
 *
 * The caller owns the sockets. Nothing here destroys anything; `sweep`
 * reports who should go and `writeAllowed` reports who has stopped reading,
 * and closing those connections calls back into `release`.
 */

// ------------------------------------------------------------------- bounds
//
// Every numeric option is clamped, in the spirit of `clampPlayers` in
// hub.js: an out-of-range value is pulled to the nearest sane end, never
// obeyed and never rejected. The caller (the CLI, the config loader) has
// already validated its input -- this is the second wall, for the case where
// a config file was hand-edited or an env var was typed wrong. Refusing to
// start over a bad number would be worse than quietly running safe.
//
// The bounds themselves are picked so that both ends are survivable:
//
//   perIpConnections    1 .. 256      1 is "one connection per address";
//                                     256 is past any honest NAT.
//   connectBurst        1 .. 1000     a bucket that cannot hold a token is
//                                     a bucket that admits nobody.
//   connectPerMinute    1 .. 60000    60000/min is 1000/s, i.e. off.
//   maxPending          1 .. 1024     must be >= 1 or no one can ever
//                                     complete a handshake.
//   handshakeTimeoutMs  1000 .. 300000   under a second would reap players
//                                     on a slow link; 5 min is "disabled".
//   idleTimeoutMs       5000 .. 3600000  the client has no auto-reconnect
//                                     (src/Transport.lua:163), so the floor
//                                     is deliberately well above the mod's
//                                     own heartbeat interval.
//   partialLineTimeoutMs 1000 .. 300000  same reasoning as the handshake.
//   maxWriteBufferBytes 4096 .. 67108864  the floor is above one max-size
//                                     line (hub.js MAX_LINE is 64 KiB) so
//                                     the guard cannot fire on a legitimate
//                                     single message.
const BOUNDS = Object.freeze({
  perIpConnections: [1, 256],
  connectBurst: [1, 1000],
  connectPerMinute: [1, 60000],
  maxPending: [1, 1024],
  handshakeTimeoutMs: [1000, 300000],
  idleTimeoutMs: [5000, 3600000],
  partialLineTimeoutMs: [1000, 300000],
  maxWriteBufferBytes: [4096, 67108864],
});

const DEFAULTS = Object.freeze({
  perIpConnections: 4,
  connectBurst: 10,
  connectPerMinute: 60,
  maxPending: 8,
  handshakeTimeoutMs: 10000,
  idleTimeoutMs: 45000,
  partialLineTimeoutMs: 10000,
  maxWriteBufferBytes: 262144,
});

function clamp(name, value) {
  const [min, max] = BOUNDS[name];
  const n = Math.floor(Number(value));
  if (!Number.isFinite(n)) return DEFAULTS[name];
  return Math.min(max, Math.max(min, n));
}

// How many rate buckets may exist at once, and how often the sweep for dead
// ones is allowed to run. Both are internal: a host has no reason to tune
// the shape of a memory guard, and exposing them would only widen the
// surface a bad config can damage.
const MAX_BUCKETS = 4096;
const PRUNE_INTERVAL_MS = 30000;

// ------------------------------------------------------------- address keys
//
// Node hands back `::ffff:203.0.113.7` for an IPv4 client on a dual-stack
// listener, and the bare dotted quad for the same client on an IPv4-only
// one. Keying, banning or counting without folding those together means the
// per-IP cap and the ban list both silently miss half the time -- the worst
// kind of failure, because everything still looks like it is working.
//
// The mapped form also has a hex spelling (`::ffff:cb00:7107`) that some
// stacks produce, and addresses can arrive with a `[...]` wrapper or a
// `%iface` zone index. All of it is folded to one canonical string. Zone
// indices are dropped rather than kept: a human writing a ban list writes
// `fe80::1`, not `fe80::1%en0`, and a ban that misses because of an
// interface name is a ban that did not happen.
const V4 = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/;

function normalizeIp(value) {
  if (typeof value !== 'string') return '';
  let ip = value.trim();
  if (!ip) return '';

  if (ip.startsWith('[')) {
    const close = ip.indexOf(']');
    if (close > 0) ip = ip.slice(1, close);
  }
  const zone = ip.indexOf('%');
  if (zone >= 0) ip = ip.slice(0, zone);

  // IPv6 is case-insensitive; IPv4 has no letters. One lowercase pass makes
  // both halves comparable without needing to know which one this is.
  ip = ip.toLowerCase();

  // Dotted-quad tail: ::ffff:1.2.3.4 (mapped) and ::1.2.3.4 (the deprecated
  // compatible form, which some proxies still emit).
  let tail = null;
  if (ip.startsWith('::ffff:')) tail = ip.slice(7);
  else if (ip.startsWith('::') && ip.indexOf('.') > 0) tail = ip.slice(2);

  if (tail !== null) {
    const quad = V4.exec(tail);
    if (quad) {
      const parts = [quad[1], quad[2], quad[3], quad[4]].map(Number);
      if (parts.every((n) => n <= 255)) return parts.join('.');
    }
    const hex = /^([0-9a-f]{1,4}):([0-9a-f]{1,4})$/.exec(tail);
    if (hex && ip.startsWith('::ffff:')) {
      const hi = parseInt(hex[1], 16);
      const lo = parseInt(hex[2], 16);
      return `${hi >> 8}.${hi & 255}.${lo >> 8}.${lo & 255}`;
    }
  }
  return ip;
}

function toIpSet(list) {
  const set = new Set();
  if (!Array.isArray(list)) return set;
  for (const entry of list) {
    const ip = normalizeIp(entry);
    if (ip) set.add(ip);
  }
  return set;
}

// ------------------------------------------------------------------ verdicts
//
// A rejected connection must cost nothing but the bucket update -- otherwise
// a flooder gets to allocate on the hub's heap once per SYN, which is the
// thing this module exists to prevent. So every verdict is a frozen
// singleton handed back by reference, not a fresh object. Callers read
// `.ok`/`.reason` and must not write to them.
const OK = Object.freeze({ ok: true });
const REJECT = Object.freeze({
  banned: Object.freeze({ ok: false, reason: 'banned' }),
  not_allowed: Object.freeze({ ok: false, reason: 'not_allowed' }),
  per_ip: Object.freeze({ ok: false, reason: 'per_ip' }),
  rate: Object.freeze({ ok: false, reason: 'rate' }),
  pending: Object.freeze({ ok: false, reason: 'pending' }),
});

// -------------------------------------------------------------------- Limits

class Limits {
  constructor(options = {}) {
    const opts = options || {};
    this.perIpConnections = clamp('perIpConnections', opts.perIpConnections);
    this.connectBurst = clamp('connectBurst', opts.connectBurst);
    this.connectPerMinute = clamp('connectPerMinute', opts.connectPerMinute);
    this.maxPending = clamp('maxPending', opts.maxPending);
    this.handshakeTimeoutMs = clamp('handshakeTimeoutMs', opts.handshakeTimeoutMs);
    this.idleTimeoutMs = clamp('idleTimeoutMs', opts.idleTimeoutMs);
    this.partialLineTimeoutMs =
      clamp('partialLineTimeoutMs', opts.partialLineTimeoutMs);
    this.maxWriteBufferBytes =
      clamp('maxWriteBufferBytes', opts.maxWriteBufferBytes);

    // The clock is injected so a test can advance time by an hour without
    // waiting one. Anything that is not callable falls back to the real one
    // rather than throwing -- a hub that will not start because of a bad
    // clock argument is a worse outcome than one that ignores it.
    this.now = typeof opts.now === 'function' ? opts.now : Date.now;

    this._tokensPerMs = this.connectPerMinute / 60000;

    /** key -> { ip, at, greeted, lastActivity, partialSince } */
    this._conns = new Map();
    /** ip -> live connection count */
    this._perIp = new Map();
    /** ip -> { tokens, last } */
    this._buckets = new Map();

    this._pending = 0;
    this._prunedAt = -Infinity;

    this._bans = new Set();
    this._allow = new Set();
  }

  // ------------------------------------------------------------ admission

  /*
   * Called before a single byte of client state is allocated.
   *
   * The order is cheapest-and-most-decisive first: a banned address is a
   * settled question and costs a set lookup; an allowlist miss likewise. The
   * rate bucket comes next because it is the only check that must run even
   * on a doomed connection -- a rejected attempt still spends a token, or a
   * flooder who is over the per-IP cap gets unlimited free retries and the
   * cap becomes a busy-loop rather than a limit. Bans deliberately sit
   * *before* the bucket so a banned address never causes a bucket to be
   * created: that is the one attacker who must not be able to allocate.
   *
   * Bans always beat the allowlist. An empty allowlist means "everyone",
   * which is what a hub with no allowlist configured wants.
   */
  admit(ip) {
    const addr = normalizeIp(ip);
    if (this._bans.has(addr)) return REJECT.banned;
    if (this._allow.size > 0 && !this._allow.has(addr)) return REJECT.not_allowed;

    const now = this.now();
    this._prune(now);
    if (!this._spendToken(addr, now)) return REJECT.rate;

    if ((this._perIp.get(addr) || 0) >= this.perIpConnections) {
      return REJECT.per_ip;
    }
    if (this._pending >= this.maxPending) return REJECT.pending;
    return OK;
  }

  // ------------------------------------------------------ connection life

  /*
   * Record an admitted connection. The key is opaque and chosen by the
   * caller (a socket id, the client id, the socket object itself) so this
   * module never needs to know what a connection actually is.
   *
   * Registering a key twice is a caller bug, not a security event, so it is
   * absorbed: the second call is a no-op rather than a second seat charged
   * against the address.
   */
  register(key, ip) {
    if (this._conns.has(key)) return;
    const addr = normalizeIp(ip);
    const now = this.now();
    this._conns.set(key, {
      ip: addr,
      at: now,
      greeted: false,
      lastActivity: now,
      partialSince: null,
    });
    this._perIp.set(addr, (this._perIp.get(addr) || 0) + 1);
    this._pending += 1;
  }

  /*
   * The connection is gone. Deleting from `_conns` first is what makes this
   * idempotent: a socket that emits both `error` and `close` -- which is the
   * normal case, not the exotic one -- calls this twice, and a per-IP
   * counter that went down twice would eventually go negative and hand that
   * address an unlimited cap.
   */
  release(key) {
    const rec = this._conns.get(key);
    if (!rec) return false;
    this._conns.delete(key);
    if (!rec.greeted) this._pending -= 1;

    const left = (this._perIp.get(rec.ip) || 1) - 1;
    if (left > 0) this._perIp.set(rec.ip, left);
    else this._perIp.delete(rec.ip);
    return true;
  }

  /*
   * Handshake complete. This is the moment the connection stops being a
   * pending slot and starts being judged on idleness instead -- the two
   * clocks that `socket.setTimeout(45000)` used to conflate, which is how a
   * silent socket held a slot for 45 seconds.
   */
  markGreeted(key) {
    const rec = this._conns.get(key);
    if (!rec || rec.greeted) return false;
    rec.greeted = true;
    rec.lastActivity = this.now();
    this._pending -= 1;
    return true;
  }

  /*
   * Called on every inbound chunk.
   *
   * Two separate facts are tracked, because they answer different questions.
   * `lastActivity` answers "is this peer alive". `partialSince` answers "has
   * this peer produced a complete line since it started buffering" -- which
   * is what catches the client dribbling one byte a minute, forever, under
   * the 64 KiB buffer cap and under any idle timeout.
   *
   * `completedLine` wins over `bytes` when both are set: a chunk that closed
   * a line has proved the peer can finish a sentence, and the leftover tail
   * gets its own clock from the next chunk that arrives without one.
   */
  noteActivity(key, info) {
    const rec = this._conns.get(key);
    if (!rec) return false;
    const now = this.now();
    rec.lastActivity = now;

    const opts = info || {};
    if (opts.completedLine) {
      rec.partialSince = null;
    } else if (Number(opts.bytes) > 0 && rec.partialSince === null) {
      rec.partialSince = now;
    }
    return true;
  }

  // ----------------------------------------------------------------- sweep

  /*
   * Who should be destroyed right now, and why.
   *
   * Pure by design: it reads the clock, returns a list, and releases
   * nothing. The caller closes the sockets, and closing them calls
   * `release` through the normal `close` handler -- so there is exactly one
   * path out of this table and no way for the two to disagree.
   *
   * Reasons are ordered most-specific-first. A connection that has not
   * greeted is judged only on its handshake budget, because "silent" and
   * "dribbling" are the same failure before hello and the handshake budget
   * is the tighter of the two. After hello, a stalled partial line is a
   * more precise diagnosis than plain idleness, and its clock is shorter,
   * so it is reported in preference.
   */
  sweep() {
    const now = this.now();
    this._prune(now);

    const doomed = [];
    for (const [key, rec] of this._conns) {
      if (!rec.greeted) {
        if (now - rec.at > this.handshakeTimeoutMs) {
          doomed.push({ key, reason: 'handshake_timeout' });
        }
        continue;
      }
      if (rec.partialSince !== null &&
          now - rec.partialSince > this.partialLineTimeoutMs) {
        doomed.push({ key, reason: 'slowloris' });
        continue;
      }
      if (now - rec.lastActivity > this.idleTimeoutMs) {
        doomed.push({ key, reason: 'idle_timeout' });
      }
    }
    return doomed;
  }

  /*
   * Backpressure. `socket.write()` returns false once the kernel buffer is
   * full and Node starts queueing in userland; hub.js discards that boolean,
   * so a peer that connects and never reads makes the hub's memory grow
   * without bound while looking, from the outside, like a healthy player.
   *
   * The caller passes `socket.writableLength` and destroys the connection on
   * false. Deliberately not keyed on any stored state -- an unknown key is
   * still judged on its buffer, because the buffer is the actual hazard.
   */
  writeAllowed(key, writableLength) {
    const n = Number(writableLength);
    if (!Number.isFinite(n)) return true;
    return n <= this.maxWriteBufferBytes;
  }

  // ------------------------------------------------------------- policy

  setBans(list) {
    this._bans = toIpSet(list);
  }

  setAllowlist(list) {
    this._allow = toIpSet(list);
  }

  // ------------------------------------------------------------ reporting

  get pendingCount() {
    return this._pending;
  }

  connectionsFrom(ip) {
    return this._perIp.get(normalizeIp(ip)) || 0;
  }

  /** The shape the CLI's `status` verb prints. */
  stats() {
    const perIp = {};
    for (const [ip, count] of this._perIp) perIp[ip] = count;
    return { connections: this._conns.size, pending: this._pending, perIp };
  }

  // ------------------------------------------------------------- internals

  /*
   * A token bucket per address: `connectBurst` capacity, refilled at
   * `connectPerMinute`. A fresh address starts full, so the first
   * connection from anyone is never rate-limited.
   */
  _spendToken(ip, now) {
    let bucket = this._buckets.get(ip);
    if (!bucket) {
      bucket = { tokens: this.connectBurst, last: now };
      this._buckets.set(ip, bucket);
    } else {
      // `Math.max(0, ...)` because the clock is injected and an injected
      // clock can run backwards -- as can the real one, across an NTP step.
      // Negative elapsed time would drain a bucket nobody touched.
      const elapsed = Math.max(0, now - bucket.last);
      bucket.tokens = Math.min(
        this.connectBurst, bucket.tokens + elapsed * this._tokensPerMs);
      bucket.last = now;
    }
    if (bucket.tokens < 1) return false;
    bucket.tokens -= 1;
    return true;
  }

  /*
   * Buckets are keyed by address and a flooder can cycle addresses, so
   * without this the rate limiter is itself a memory leak -- an unbounded
   * Map written to once per hostile connect.
   *
   * The rule that makes pruning safe is that **a full bucket carries no
   * information**: an address whose bucket has refilled to capacity is
   * indistinguishable from an address that has never connected, because a
   * fresh bucket starts full. Deleting it grants the attacker nothing.
   *
   * Doing that scan on every `admit` would make admission O(buckets), which
   * hands the flooder a different lever, so it is interval-gated and forced
   * only when the map is over its hard cap. No timer: the caller's own
   * traffic drives it, which means an idle hub does no work at all.
   */
  _prune(now, force) {
    const over = this._buckets.size > MAX_BUCKETS;
    if (!force && !over && now - this._prunedAt < PRUNE_INTERVAL_MS) return;
    this._prunedAt = now;

    for (const [ip, bucket] of this._buckets) {
      const elapsed = Math.max(0, now - bucket.last);
      if (bucket.tokens + elapsed * this._tokensPerMs >= this.connectBurst) {
        this._buckets.delete(ip);
      }
    }
    if (this._buckets.size <= MAX_BUCKETS) return;

    // Still over the cap means there really are that many addresses mid-
    // flood. Memory has to win, so the fullest buckets go first: they are
    // the closest to being free to drop, and the furthest from the
    // attackers actually being throttled.
    const ranked = [...this._buckets.entries()]
      .sort((a, b) => b[1].tokens - a[1].tokens);
    const target = Math.floor(MAX_BUCKETS * 0.9);
    for (let i = 0; i < ranked.length && this._buckets.size > target; i += 1) {
      this._buckets.delete(ranked[i][0]);
    }
  }
}

module.exports = { Limits, normalizeIp, DEFAULTS, BOUNDS };
