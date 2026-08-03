# RBY MMO hub (standalone)

**You may not need this.** A player can host from inside the game —
`START > MMO > HOST GAME` — and that is the normal way to play. Reach for
this when you want a hub that stays up when nobody is playing, one on a box
with a public address so nobody has to forward a port, or one you can hand a
join code out for.

It is the same protocol and the same 2–64 player bounds as the in-game host
(`src/Hub.lua`); the two are interchangeable and a joining client cannot tell
them apart.

Node 22+, no dependencies. Everything below is Node core.

---

## Quick start

Two paths to the same thing: a hub that is running, requires a join code, and
has printed that code once.

### Docker

```sh
cd server/
docker compose up -d
docker compose logs hub        # your join code is in here, printed once
```

The first `up` on an empty volume runs `rby-mmo-hub init --yes` for you, so
the hub comes up *requiring* a join code — you cannot publish an open world by
forgetting a step. Every later start re-uses the same config and the same
code.

### Bare Node

```sh
cd server/
node bin/rby-mmo-hub.js init      # four questions; --yes takes the defaults
node bin/rby-mmo-hub.js doctor    # what would stop friends connecting
node bin/rby-mmo-hub.js start     # run it
```

`init` writes `config.json` (mode 0600) and prints the code once:

```
Configuration written to /srv/hub/config.json (mode 0600, readable only by you).

  listening on   0.0.0.0:7788
  players        up to 4
  join code      required
  log level      info

Your join code

  ------------------------------------------------------------

      PQZX-Q1YP-FSXV-7J31

  ------------------------------------------------------------

  Give that to the friends you want in your world. …
```

To see it again: `rby-mmo-hub invite list --reveal`.

### Where a friend types it

In game, before joining: `START > MMO > JOIN CODE`, type the sixteen
characters (dashes and case do not matter — the code is normalised on both
ends), then `JOIN GAME` and the hub's `host:port`. If they skip the code and
the hub asks for one, the game says *"This game needs a join code."* and puts
them on the entry screen; saving it there dials again.

Every character in a code is on the mod's own naming grid, and **SELECT**
flips it between letters and digits — the vanilla grid has no digits at all.

---

## What it is, and what it deliberately is not

It is a **relay**. It owns who is connected, where they last said they were,
and which two players are currently paired. It forwards bytes.

It does **not** simulate anything. Trades and battles run inside the two game
clients on the engine's own link code, with the hub passing opaque payloads
between them. A hub that refereed battles would be a second, worse
implementation of Gen 1's rules that could disagree with the clients — so
`mmo.relay` payloads are never parsed here.

It is also not a public server, and not an account system. There is no
identity beyond "holds a working join code"; two friends can be online under
the same name.

Wire format is newline-delimited JSON, the same framing `src/link/Net.lua`'s
relay backend already speaks, which is why the mod can reuse the engine's
transport instead of shipping its own socket code.

---

## The CLI

`node bin/rby-mmo-hub.js <command>` — or just `rby-mmo-hub` inside the
container, where it is on `PATH`.

| Command | What it does | Its own options |
| --- | --- | --- |
| `init` | first-run wizard: writes `config.json` at mode 0600 and prints a join code once. Refuses to overwrite an existing file. | `--yes` (ask nothing, take flags and defaults), `--force` (replace an existing config), `--no-auth` (do not require a join code), plus any config flag below |
| `start` | loads the config, prints who can reach this machine, runs the hub until stopped | any config flag; `--limits.maxPending 12` works as well as `--max 8` |
| `status` | every effective setting, its value, and where that value came from (`flag` / `env` / `file` / `default`). Codes masked. | — |
| `config list` | every setting, its current value, and its clamp range | — |
| `config get <path>` | one setting, e.g. `limits.maxPending` | — |
| `config set <path> <value>` | change one setting: clamped, reported, then saved | — |
| `invite` | mint a join code and print it once | `--label TEXT`, `--expires 30m\|24h\|7d`, `--uses N` |
| `invite list` | every code: id, label, created, expires, uses, status. Masked by default. | `--reveal` (print them in full) |
| `revoke <id>` | revoke one code. Ids come from `invite list`; a unique prefix is enough. | — |
| `ban <ip>` | refuse an address. Normalised first, so `::ffff:203.0.113.7` and `203.0.113.7` are one ban. | `--reason TEXT` (printed, **not** stored — the ban list holds addresses only) |
| `unban <ip>` | stop refusing an address | — |
| `allow [<ip>]` | with no argument, print the allowlist; with one, add to it. **An allowlist with entries is exclusive**: only those addresses may connect. | `--clear` (empty it) |
| `doctor` | configuration sanity plus a reachability report | — |
| `upnp enable\|disable\|status` | ask the router to forward the port. Off by default; `enable` prints the full risk note before it sends a packet. | — |
| `help [command]` | this table, or one command's own text | — |
| `version` / `--version` | print the version | — |

Global options, valid on every command:

- `--config <file>` — which config file to use.
- `--help` — the command's own help instead of running it.

Flags are long-form only: `--flag`, `--flag value`, `--flag=value`,
`--no-flag`, and `--` to stop parsing. There are no short options.

Short spellings for the settings a host actually types: `--host`, `--port`,
`--max` (or `--max-players`), `--auth`, `--per-ip`, `--connect-burst`,
`--connect-per-minute`, `--handshake-timeout`, `--idle-timeout`,
`--partial-line-timeout`, `--max-pending`, `--max-write-buffer`,
`--chat-interval`, `--upnp`, `--upnp-lease`, `--log-level`. Any dotted config
path is also accepted verbatim, so nothing needs a hand-written flag.

**Exit codes:** `0` success, `1` runtime error, `2` wrong usage. `doctor`
returns `1` when something would stop players connecting, `0` when only
warnings.

Join codes are printed by exactly three things — `init`, `invite`, and
`invite list --reveal`. They never go through the logger, and never appear in
`status`, `doctor` or an error message, so any of those is safe to
screen-share or paste into a forum thread.

---

## Configuration

One file, `config.json`, written at mode `0600` because it holds join codes in
plaintext (the hub needs them to compute an HMAC). It is looked for in this
order:

1. `--config <file>`
2. `$RBY_MMO_CONFIG`
3. `./config.json` next to where you ran the command
4. `/data/config.json`, when `/data` exists — the container's volume

Precedence, everywhere, without exception:

> **command-line flag > `RBY_MMO_*` env var > config file > built-in default**

`status` prints which of the four each setting came from, which is the answer
to "why is it still 4 players".

Loading never fails. A stray comma, an unknown key or an out-of-range number
costs a warning, not an outage: out-of-range values are pulled to the nearest
end and reported, never obeyed.

| Setting | Default | Range | Env var | Meaning |
| --- | --- | --- | --- | --- |
| `version` | `1` | — | — | the config file's schema version. Maintained by this software, not a setting |
| `listen.host` | `0.0.0.0` | — | `RBY_MMO_HOST` | address to bind. `0.0.0.0` accepts on every address this machine has |
| `listen.port` | `7788` | 1–65535 | `RBY_MMO_PORT` | TCP port to listen on |
| `maxPlayers` | `4` | 2–64 | `RBY_MMO_MAX` | greeted players before new ones are refused |
| `auth.required` | `true` | — | `RBY_MMO_AUTH_REQUIRED` | whether a join code is demanded. `false` means anyone who reaches the port can join |
| `auth.credentials` | `[]` | — | — | the join codes. Managed with `invite` / `revoke` |
| `limits.perIpConnections` | `4` | 1–64 | `RBY_MMO_PER_IP` | connections one address may hold at once |
| `limits.connectBurst` | `10` | 1–1000 | `RBY_MMO_CONNECT_BURST` | depth of the per-address connect-rate bucket |
| `limits.connectPerMinute` | `60` | 1–6000 | `RBY_MMO_CONNECT_PER_MINUTE` | how fast that bucket refills |
| `limits.handshakeTimeoutMs` | `10000` | 1000–120000 | `RBY_MMO_HANDSHAKE_TIMEOUT_MS` | how long a connection has to finish `hello` (and `auth`, when required) |
| `limits.idleTimeoutMs` | `45000` | 5000–600000 | `RBY_MMO_IDLE_TIMEOUT_MS` | how long a greeted player may say nothing. The client has no auto-reconnect, so do not tighten this casually |
| `limits.partialLineTimeoutMs` | `10000` | 1000–300000 | `RBY_MMO_PARTIAL_LINE_TIMEOUT_MS` | how long a peer may sit on an unfinished line — the slowloris budget |
| `limits.maxPending` | `8` | 1–256 | `RBY_MMO_MAX_PENDING` | connections that have not said `hello` yet, in total |
| `limits.maxWriteBufferBytes` | `262144` | 16384–16777216 | `RBY_MMO_MAX_WRITE_BUFFER_BYTES` | queued bytes for one peer before it is dropped for not reading |
| `limits.chatIntervalMs` | `500` | 0–60000 | `RBY_MMO_CHAT_INTERVAL_MS` | minimum gap between one sender's chat messages. `0` turns the flood gate off |
| `bans` | `[]` | — | — | addresses refused outright. Managed with `ban` / `unban` |
| `allowlist` | `[]` | — | — | when non-empty, the **only** addresses that may connect. Managed with `allow` |
| `network.upnp.enabled` | `false` | — | `RBY_MMO_UPNP` | whether `start` asks the router to forward the port |
| `network.upnp.leaseSeconds` | `3600` | 60–604800 | `RBY_MMO_UPNP_LEASE_SECONDS` | how long that mapping lasts before it expires on its own |
| `log.level` | `info` | `debug` `info` `warn` `error` `silent` | `RBY_MMO_LOG_LEVEL` | how much the hub says |

`RBY_MMO_CONFIG` is the odd one out: it names *where the file is*, not a value
inside it.

**`config set` reaches every setting in that table but two.**

- `auth.credentials` — join codes are not edited as text. A mistyped one locks
  everybody out silently, so `invite` mints them and `revoke` withdraws them,
  both normalising properly on the way in.
- `version` — the file's schema version, maintained so older files keep
  loading. It is not a knob.

Nothing else needs the file opened by hand. If you do open it, that should be
curiosity rather than necessity.

---

## Security posture

Be clear-eyed about this before you expose a port.

### The join code

The hub sends a fresh random nonce; the client answers
`HMAC-SHA256(joinCode, nonce)`. **The join code itself never crosses the
wire.** Codes are sixteen characters from a 32-symbol alphabet with `I L O U`
removed — 80 bits, and nothing that can be misread off a screenshot.

- A passive eavesdropper cannot recover the code (HMAC is one-way) and cannot
  replay a captured answer: the nonce is per-connection and single-use, spent
  the moment it is consumed, pass or fail.
- Digests are compared in constant time (`crypto.timingSafeEqual` here, an
  accumulate-then-compare in the Lua client).
- Every credential is tried, with no early exit, so the refusal does not leak
  which code matched or how many the hub holds. A wrong code, an expired
  invite and a revoked one are one sentence: *"That join code was not
  accepted."*
- Credentials are a list. Each can carry an expiry (`--expires`), a use budget
  (`--uses`) and a revocation, so withdrawing one friend's invite does not
  rotate everybody's code.
- `config.json` holds the codes in plaintext, at mode 0600. A group- or
  world-readable file is warned about on every load and is a `[fail]` in
  `doctor`.

### What that buys, and what it does not

It stops internet scanners and anyone who merely finds the port. That is the
whole of what it is for, and it does it.

**The link is not encrypted.** Gameplay traffic — names, chat, positions,
trade and battle payloads — is readable by anyone on the path, and an active
man-in-the-middle can proxy the entire session. There is no TLS on the game
port because the client cannot speak it: LÖVE ships luasocket, not luasec, and
the engine opens a plain `socket.tcp()`. Putting everyone on an encrypted
overlay network (WireGuard, Tailscale, ZeroTier) and sharing the overlay
address is the only thing that closes that gap.

### Connection hardening

All of it is on by default under `rby-mmo-hub`, and all of it is tunable.

- **Seats are charged at `hello`, not at accept.** A connection that has not
  identified itself does not hold a player seat. Ungreeted sockets are bounded
  separately by `limits.maxPending` (8) and reaped by
  `limits.handshakeTimeoutMs` (10 s). *This was not true before: the old hub
  registered a socket in its client table on accept, so four silent sockets
  could lock everyone out of a four-player hub for 45 seconds at a time.*
- **Per-address connection cap** (`limits.perIpConnections`, 4) and a
  **token-bucket connect-rate limit** (`limits.connectBurst` 10,
  `limits.connectPerMinute` 60). A rejected attempt still spends a token, so
  being over the cap does not buy a flooder free retries.
- **A handshake budget separate from the idle timeout**, which the old single
  `socket.setTimeout(45000)` conflated.
- **Slowloris sweep**: a peer that starts a line and never finishes one is
  closed after `limits.partialLineTimeoutMs`, under both the 64 KiB line cap
  and the idle timeout.
- **Write backpressure**: a peer whose queued bytes pass
  `limits.maxWriteBufferBytes` is dropped. A client that connects and never
  reads used to grow the hub's memory without bound while looking healthy.
- **Bans and an allowlist.** Addresses are normalised first, so a dual-stack
  client cannot slip past a ban written in the other spelling. An allowlist
  with entries is exclusive.
- A rejection that is a flood signal (banned, rate-limited) costs the sender
  nothing but the SYN; one an honest player could plausibly hit gets a
  sentence, because the game renders it.

### Everything else that is still true

- Every inbound field is re-derived through a sanitiser; nothing arrives
  trusted, and a malformed line is dropped rather than being fatal.
- Every untrusted value in a log line is escaped, bounded and quoted, so a
  trainer name cannot forge a log line or repaint the host's terminal with
  ANSI escapes.
- Relay payloads are forwarded unread, but their *shape* is bounded — the
  decoder tolerates input deeper than the encoder can re-emit, and a deeply
  nested payload used to throw while being forwarded and take the hub with it.
- A message that will not serialise costs its own connection and nothing else.
  An uncaught error is logged and the hub carries on: a crash costs everybody
  a trade, a battle, and a reconnect the client cannot do for them.
- **Position is self-reported**, so a modified client can claim to be
  anywhere. That is unavoidable in a relay design and harmless for presence,
  but it does mean the `local` chat radius is not an enforceable boundary.

### The in-game host is not the hardened one

`src/Hub.lua` can ask for a join code too, and the exchange is byte-compatible
with this one — though the `HOST GAME` screen does not currently set one, so a
game hosted from inside the game admits anyone who reaches the port. And when
it does ask, its nonce is derived from what pure Lua can reach — heap size, a
table's address, `os.time`, `os.clock` — hashed with SHA-256. That is not a
cryptographic random source and the code says so. It is fine for a LAN game
among people in the same room.

**A hub exposed to the open internet should be this one.**

Run one for people you know. It is not built to be a public server.

---

## Getting friends connected

`start` and `doctor` classify every address this machine holds — loopback,
private, CGNAT/overlay (`100.64.0.0/10`), public — and print the one to hand
out. There is **no phone-home**: every fact comes from this machine describing
itself, or, when you have turned UPnP on, from your own router. No STUN, no
"what is my IP" service, no port check, no telemetry.

The cost of that is honest, and `doctor` says it rather than guessing: local
interfaces cannot tell you whether a router in front of the machine forwards
the port. **"This machine has no public IPv4 address, so friends outside this
network will NOT reach this port"** means exactly that — nothing checked the
path, because checking it would mean asking a stranger. Conversely, an address
reported as public means it is publicly *routable*; a firewall on this machine
or in front of it can still block the port.

Three ways to be reachable, which is what `doctor` prints:

1. **Forward TCP 7788** on the router to this machine. By hand in the router's
   admin page, or with `upnp enable` below.
2. **Run the hub on a machine that already has a public address.** Any small
   VPS will do; it relays JSON lines and need not be powerful.
3. **Put everyone on an overlay network** (Tailscale, WireGuard, ZeroTier) and
   share the overlay address. This is also the only option that encrypts the
   traffic.

A public IPv6 address is reported too, but it needs a friend whose own network
has IPv6, and most routers firewall inbound IPv6 by default, so it usually
still wants a pinhole.

### UPnP

```sh
rby-mmo-hub upnp enable    # prints the full warning first, then asks the router
rby-mmo-hub upnp status    # what the router says is mapped right now
rby-mmo-hub upnp disable   # removes the mapping
```

Off by default, and only ever turned on by that verb. Read the warning it
prints, because it is the real risk:

> Most home routers accept these requests from **any** device on the network,
> with no authentication at all. That is not a flaw in this software — it is
> how UPnP works on most consumer hardware. The same door that lets this hub
> open a port lets a smart plug, a games console or a guest laptop open one,
> without asking you.

What it does: asks the router to forward one TCP port to this machine, on a
lease (`network.upnp.leaseSeconds`, default an hour) so a mapping outlives a
`kill -9` by at most that long, and removes it on clean shutdown and on `upnp
disable`. It contacts nothing except your own router, discovered by multicast
on the local link. Some routers refuse leases and only accept permanent
mappings; when that happens it is said out loud, and `upnp disable` is the way
back.

With UPnP on, `doctor` also asks the router for its own external address —
still local, still no third party.

---

## Docker

```sh
cd server/
docker compose up -d                              # build and start
docker compose logs hub                           # the join code, once
docker compose exec hub rby-mmo-hub invite        # another code, for a friend
docker compose exec hub rby-mmo-hub doctor        # what can reach you
docker compose exec hub rby-mmo-hub config set maxPlayers 8
docker compose down                               # stop; volume and code remain
```

`docker compose exec` bypasses the entrypoint, which is why every other verb
is reachable that way — `rby-mmo-hub` is on `PATH` in the image.

What compose sets up:

- **`node:24-alpine`, non-root UID/GID `10001`**, fixed so a rebuild does not
  find `/data` owned by a different number. Alpine rather than distroless on
  purpose: the host who needs to shell in and read a code back out is exactly
  the audience.
- **A named volume at `/data`**, holding `config.json` — the join code, the
  bans, the allowlist. Losing the volume loses the code your friends saved.
- **`read_only: true`, `cap_drop: [ALL]`, `no-new-privileges`,
  `tmpfs: [/tmp]`.** The hub binds 7788, above 1024, so it needs no capability
  at all.
  **`read_only: true` works only because `/data` is a volume** — volume mounts
  stay writable through a read-only rootfs. Delete the `volumes:` block and
  keep `read_only`, and the first run dies with `EROFS` writing
  `/data/config.json`, which reads like a bug in the hub and is not.
- **`init: true` and tini in the image.** Without a real PID 1, SIGTERM does
  not reliably reach the hub and the goodbye it sends to connected players
  never goes out. `stop_grace_period: 15s` leaves room for the drain.
- **A TCP healthcheck written against Node's own `net`** — connect to
  `127.0.0.1:$RBY_MMO_PORT`, close, exit. No `curl` or `nc` is added to the
  image just to look at it. Two honest limits: it reads `RBY_MMO_PORT`
  (default 7788), so a port set only in `config.json` needs that variable set
  to match; and it dials loopback, so a `listen.host` bound to one specific
  non-loopback address reads as unhealthy.

`ports: - "7788:7788"` is the most-edited line in `compose.yml`; the left
number is the one on this machine and the one friends type.
`127.0.0.1:7788:7788` keeps it local while you test.

---

## `node hub.js` — the old front door, still open

```sh
node hub.js              # port 7788, 4 players
node hub.js 9000         # or pick a port
RBY_MMO_MAX=8 node hub.js
```

Unchanged, on purpose: no config file, no join code, no arguments but a port,
and the same three environment variables (`RBY_MMO_PORT`, `RBY_MMO_HOST`,
`RBY_MMO_MAX`, the last clamped to 2–64). Every command that ever worked here
still works.

It is **unauthenticated and has no per-address or connection-rate limits**,
and it now says so at startup:

```
2026-08-03T03:02:39.208Z INFO RBY MMO hub listening on 0.0.0.0:7992 (protocol 2)
2026-08-03T03:02:39.209Z WARN This entry point is unauthenticated and has no per-address or connection-rate limits; run bin/rby-mmo-hub.js for a hub with a join code and the limits turned on.
```

Right for a LAN game, a quick test, or a hub only reachable over a VPN. Wrong
for anything with a port published to the internet — that wants
`bin/rby-mmo-hub.js`.

---

## Protocol

Every type is prefixed `mmo.` so it can never collide with the four control
types (`hosted`, `paired`, `join_error`, `peer_gone`) that `Net.lua` intercepts
on a relay connection.

**Client → hub**

| Type | Payload |
| --- | --- |
| `mmo.hello` | `proto, name, sprite, profile, map, x, y, facing` |
| `mmo.auth` | `response` — 64 lowercase hex chars, `HMAC-SHA256(joinCode, nonce)` |
| `mmo.move` | `map, x, y, facing, busy` — an absent cell means "not in the world" |
| `mmo.chat` | `scope, to, text` |
| `mmo.request` | `to, kind` (`trade` \| `battle`) |
| `mmo.respond` | `to, kind, accept` |
| `mmo.relay` | `to, payload` — opaque |
| `mmo.session_leave` | — |
| `mmo.ping` | — |

**Hub → client**

| Type | Payload |
| --- | --- |
| `mmo.challenge` | `nonce` — 32 lowercase hex chars, per-connection, single-use. **Only sent when a join code is required** |
| `mmo.welcome` | `id, players[]` |
| `mmo.join` / `mmo.part` | `player` / `id` |
| `mmo.move` | a presence record |
| `mmo.chat` | `from, name, scope, text` |
| `mmo.request` / `mmo.decline` | `from, name, kind` / `name, kind` |
| `mmo.session` | `peer, peerName, kind, role, id` — the asker hosts |
| `mmo.relay` | `from, payload` |
| `mmo.session_end` | `reason` |
| `mmo.error` | `message` — always fatal to the connection |
| `mmo.pong` | — |

The handshake, in full:

```
client → hub    mmo.hello      { proto: 2, name, sprite, profile, map, x, y, facing }
hub    → client mmo.challenge  { nonce }        ← only when a code is required
client → hub    mmo.auth       { response }
hub    → client mmo.welcome    { id, players[] }   ← or mmo.error, which the game shows
```

When no code is required the exchange is byte-identical to what it has always
been: `hello`, then `welcome`.

**`PROTOCOL` is 2**, and it lives in **`lib/relay.js`** (not `hub.js` any
more) and in **`src/Config.lua`**. Bump both together on any incompatible
change. The hub refuses a mismatched client by name and version — *"This hub
speaks protocol 2; your mod speaks 1."* — rather than letting two dialects
talk past each other, and the game renders that sentence.

---

## Tests

```sh
node hub.test.js     # from this folder
npm test             # the same file, through node --test
```

Starts the hub on a scratch port and drives it over real sockets: framing, the
protocol gate, scope routing, the flood gate, session pairing, relay isolation
between non-paired players, and teardown on a dropped socket.

The mod's own Lua suite runs from the engine checkout:

```sh
luajit mods/rby_mmo/tests/rby_mmo_test.lua
```
