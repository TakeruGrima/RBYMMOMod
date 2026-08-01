# Changelog

All notable changes to this mod are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the version
here must match `manifest.version`.

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
