# Changelog

All notable changes to this mod are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the version
here must match `manifest.version`.

## [0.2.0] - 2026-08-02

Hosting software for the standalone hub, and a join code that keeps strangers
out of it. **The protocol moved from 1 to 2, so this mod and its hub have to
ship together** — an older copy of the mod cannot join a 0.2.0 hub, and is
told so in a sentence the game already renders rather than failing silently.

### Added

- **A hosting CLI, `server/bin/rby-mmo-hub.js`** — the one place a host
  configures anything. `init` is a four-question wizard that writes
  `config.json` at mode 0600 and prints a join code once; `start`, `status`,
  `config list|get|set`, `invite`, `invite list`, `revoke`, `ban`, `unban`,
  `allow`, `doctor` and `upnp enable|disable|status` cover the rest. Every
  setting is reachable from a verb — nothing requires hand-editing JSON —
  and the two that are not (`auth.credentials`, `version`) have verbs of
  their own for a reason. Exit codes: 0 success, 1 error, 2 usage.
- **A join code, and the handshake that proves one.** The hub sends a
  per-connection nonce; the client answers `HMAC-SHA256(joinCode, nonce)`, so
  the code never crosses the wire and a captured answer cannot be replayed.
  Codes are 16 characters of a 32-symbol alphabet (80 bits) with `I L O U`
  dropped, every one of them typeable on the mod's own naming grid. Codes are
  a list, not a single secret: invites carry an optional expiry, a use budget
  and a revocation, so withdrawing one does not rotate everybody's.
- **Join-code entry in game** — `START > MMO > JOIN CODE`, or offered
  automatically when a hub asks for one this copy does not have. Stored per
  hub address.
- **`src/Sha256.lua`**, a pure-Lua SHA-256 / HMAC-SHA256 with a constant-time
  compare, written because `love.data.hash` is not available to the headless
  suite — so the game and the suite run byte-identical code. It uses LuaJIT's
  `bit` library when present and arithmetic peeling when it is not.
- **The in-game hub can require a join code too** — `src/Hub.lua` issues the
  same challenge and `HostServer:start` takes an optional code, byte-compatible
  with the standalone hub. It is off by default, and the `HOST GAME` screen
  does not yet offer one, so hosting from inside the game is still open on the
  LAN exactly as it was.
- **Docker as a first-class path.** `docker compose up` in `server/` builds a
  `node:24-alpine` image running as UID 10001 on a read-only rootfs with all
  capabilities dropped, persists `config.json` on a named volume at `/data`,
  and mints a join code on the first run so an open world cannot be published
  by forgetting a step. TCP healthcheck written against Node's own `net`; no
  `curl` or `nc` added to the image.
- **Configuration with one precedence order**, honoured everywhere: CLI flag >
  `RBY_MMO_*` env var > config file > built-in default. `status` prints which
  of the four each setting came from.
- **Reachability reporting** in `start` and `doctor`: every interface
  classified (loopback, private, CGNAT/overlay, public), the address to hand
  out, or a flat statement that friends outside the network will not reach the
  port and the three ways to fix it. No third-party network calls, ever — no
  STUN, no "what is my IP", no port-check service.
- **Opt-in UPnP** (`upnp enable`), off by default, leased, removed on clean
  shutdown, and printing its full warning before a single packet: most home
  routers accept these requests with no authentication at all.

### Changed

- **Protocol 1 → 2** (`server/lib/relay.js`, `src/Config.lua`), for the two
  new message types `mmo.challenge` and `mmo.auth`. The hub's existing
  exact-match refusal is unchanged, so a mismatched client is told which
  version each side speaks.
- **`PROTOCOL` moved out of `server/hub.js` into `server/lib/relay.js`**,
  along with the whole protocol core — `hub.js` is now a thin shim over
  `lib/server.js`. `node hub.js`, `node hub.js 9000` and
  `RBY_MMO_MAX=8 node hub.js` behave exactly as before.
- **`node hub.js` warns at startup** that it is unauthenticated and has no
  per-address or connection-rate limits, and names the CLI that has both. It
  is still the right thing for a LAN game or a quick test.
- **Connection hardening, on by default under the CLI**: per-address
  connection caps, a token-bucket connect-rate limit, a handshake timeout
  separate from the idle timeout, a slowloris sweep for a peer that never
  finishes a line, a write-backpressure ceiling, bans and an exclusive
  allowlist. Every one of them is tunable, and the defaults are deliberately
  generous because the client has no auto-reconnect.
- **Log lines cannot be forged by a peer.** Every untrusted value is escaped,
  bounded and quoted, so a trainer name carrying a newline or an ANSI escape
  can no longer write into the host's terminal.
- `server/README.md` rewritten around the host who is not a developer: quick
  start, CLI reference, the full configuration table, the security posture
  including what the join code does *not* protect, connectivity, and Docker.

### Fixed

- **Silent sockets could lock everyone out of the hub.** `hub.js` registered a
  connection in its client table on accept, so the player cap counted peers
  that had never said `hello` — four of them held a four-player hub shut for
  45 seconds at a time. Seats are charged at `hello` now; ungreeted sockets are
  bounded separately by `limits.maxPending` and reaped by
  `limits.handshakeTimeoutMs`. `server/README.md` had claimed this was already
  true; it is true now.
- **A peer that never read grew the hub's memory without bound.** `send()`
  discarded `socket.write()`'s backpressure signal; the queue is now judged
  against `limits.maxWriteBufferBytes` and a peer past it is dropped.
- **One address could take every seat.** The player cap was the only limit
  there was.

### Notes

- The join code protects against scanners and anyone who merely finds the
  port, and a passive eavesdropper can recover neither the code nor a reusable
  answer. It does **not** encrypt anything: gameplay traffic is readable on the
  path and an active man-in-the-middle can proxy a whole session. There is no
  TLS because the client cannot speak it — LÖVE ships luasocket, not luasec.
  An encrypted overlay network is the only thing that closes that gap, and
  `server/README.md` says so in those words.
- `affects_link` stays `false`; no link registry is touched, so two players
  running this mod still fingerprint as vanilla.

## [0.1.0] - 2026-07-31

First working version. Ships disabled (`experimental: true`) — installing it
must not be what starts a network connection.

### Added

- **Shared overworld presence.** Other players on your map appear as real
  overworld NPCs, spawned through `mod.world`, walking tile to tile with the
  engine's own scripted-step timing.
- **Nicknames and speech bubbles** drawn over remote players from the
  `render.hud` hook.
- **Chat** in three scopes — global, nearby (same map, within 12 tiles) and
  private — composed on the engine's naming grid, with a scrollback screen.
- **Trade and battle requests** from anywhere in the world, reachable from
  the START > MMO menu or by facing another player and pressing A. Both run
  on the engine's own `Protocol.TradeSession` and `LinkBattle` over a
  `SessionNet` shim, so trade evolutions, OT bookkeeping and lockstep battle
  behave exactly as they do over a direct link.
- **Hosting from inside the game.** `START > MMO > HOST GAME` picks a player
  limit (2–64, host included) and starts a listener; `JOIN GAME` connects to
  someone else's. No separate process to install. The host's own client
  attaches over loopback, so from the client's perspective hosting and
  joining are the same thing.
  - `src/Hub.lua` is the relay as pure logic — no sockets — so the cap,
    chat scope routing and session pairing are testable headlessly.
  - `src/HostServer.lua` is the luasocket binding: non-blocking accept,
    newline-JSON framing, pumped from `input.step`.
- **A number page on this mod's naming screens.** The vanilla Game Boy grid
  carries no digits, so an address was literally untypeable. SELECT flips
  `ABC`/`123`; scoped by title, so every other naming screen is untouched.
- **A hub server** (`server/hub.js`) for a dedicated always-on relay: Node,
  no dependencies, same protocol and same 2–64 bounds. It relays; it never
  simulates.
- Mod options for the hub address, your avatar sprite, and whether bubbles
  draw.
- Inter-mod exports: `isConnected()`, `players()`, `say(scope, text, to)`.

### Fixed during end-to-end bring-up

Found by running two real LÖVE instances against each other; none of these
were visible to the headless suites.

- **Remote avatars never moved.** They were driven with `scriptMove`, the
  engine's cutscene primitive — which also gates the *local* player's input
  on the queue being empty, so it would have frozen your controls every time
  anyone else took a step. Avatars now start a step directly on the NPC
  (facing, target, moving, progress), which `NPC:update` animates over its
  own 16 frames: the full walk cycle, none of the input lock.
- **`SPRITE_RED` arrived as `SPRITERED`**: sprite ids were sanitised with the
  chat-text sanitiser, which strips underscores, so every remote player
  silently fell back to the default sprite.
- **A modal "Connected." box** sat over the world for the whole session. Routine
  status is a log line now; only things worth interrupting for get a box.
- **Wrapped chat lines had a ragged left edge.** The wrapper took its indent
  as the seed for the first line, so the opening row joined indent and first
  word with a space and sat one column right of every row beneath it. Only
  messages long enough to wrap showed it, which is why it took rendering the
  screen at size to notice.

### Distribution

- **Releases are built by CI, not by hand.** A push to `main` resolves the
  version, packs `rby_mmo-<version>.zip` with `manifest.json` at the archive
  root, and publishes it with `sha256sums.txt`. The version that wins is
  written into the packed manifest, so an installed copy cannot report a
  version its release does not have; an existing tag is refused rather than
  overwritten.
- **`manifest.github` points at this repo**, which is what turns on the
  launcher's update check — absent, it never looks. The archive is named
  `<id>-<version>.zip` because that is the name the check prefers.
- **The archive's contents come from `.modkitignore`**, read by the release
  job rather than duplicated in it, so a published release and `modkit pack`
  hand over the same files. Tests, drivers, dev tooling and `docs/` are
  excluded — `docs/` holds screenshots composited from ROM-decoded tiles,
  sprites and glyphs, which this project does not put in an archive it
  distributes.

### Proven end to end

Two real LÖVE instances, a real socket, driven through the game's own menus
(`tests/drivers/run-mmo-e2e.sh`):

- **A trade completes.** Host `CHARIZARD` → `PIKACHU`, guest `PIKACHU` →
  `CHARIZARD`. That is the engine's own `Protocol.TradeSession` running over
  this mod's hub, including `apply()` filing the received mon.
- **A link battle runs to a decision** with `battle.started`,
  `battle.ended` and **zero `link.desync`** on both sides — the lockstep
  simulation stayed in agreement across two processes.
- Map transitions, host↔guest movement, chat both ways, and the interact
  menu offering TRADE and BATTLE.

### Notes

- `affects_link` is `false` and the suite asserts the link surface is
  byte-identical with the mod installed, so two players running this mod
  still fingerprint the same as vanilla and can link normally.
