# Plan — MMO followers: the POKéMON walking behind every remote trainer

| Field | Value |
| --- | --- |
| Date | 2026-08-20 |
| Source | "tu peux faire en sorte en utilisant Wilds of Kanto qu'on voit le pokemon derrière le dresseur en multi ?" |
| Branch | `worktree-mmo-followers` |
| Base SHA | `27db475889de30112604fbbd6e347aabe3f93fbb` |
| Wire | PROTOCOL **22 → 23** |
| Depends on | Wilds of Kanto (`overworld_wild_spawns`) **2.1.8**, optional dependency |

> **Engine anchors in this file were read from the packaged `gen1recomp-0.2.12.love`**,
> not from a `dev` checkout — there is no engine checkout on the machine this was
> written on. Re-verify line numbers against `dev` before trusting them.

## 1. Objective & success criteria

Every remote player standing on your map is drawn with **one POKéMON walking one tile
behind them**, and it is the same POKéMON Wilds of Kanto is showing behind that player
on their own screen.

Done means:

- A remote player with a WoK follower active is followed by that species, shiny variant
  included, at the right True Size.
- The follower walks — real animated steps into the cell its trainer just left — and
  keeps pace when that trainer sprints or cycles.
- It never blocks the local player, and it draws **under** its own trainer.
- Swapping follower is visible to everyone else without waiting for the trainer to move.
- With WoK absent, or the option off, nothing is emitted, nothing is drawn, and nothing
  is allocated.
- Node suites green; the Lua suite green (see §9 for what cannot be run here).

## 2. Context & constraints (investigated, with anchors)

**What the mod does today.** `src/Avatars.lua` spawns one runtime NPC per remote player
via `mod.world:spawnNpc`, then animates it by writing five engine fields on the live NPC
directly — `facing / targetX / targetY / moving / progress` — plus `stepFrames` for the
fast pace. That reach past the `WorldAPI` facade is deliberate and documented in the
file's own header: `Handle:scriptMove` cannot be used because `OverworldController`
gates the *local* player's input on `#self.scriptMoves > 0`, so driving avatars through
it would lock your own controls every time anyone else took a step.

**What the presence carries today.** `Wire.presence` (`src/Wire.lua:889`) yields
`id, name, sprite, map, x, y, facing, busy, party, fast, profile, points`. Nothing about
the party. Presence reaches the client on **three** paths, and they do not share a
sanitiser: the welcome roster and the join echo both go through `Wire.presence`
(`src/Client.lua:1897`, `:1982`), while `handlers[Wire.MOVE]` (`:2017-2037`) sanitises
field by field inline.

**Wilds of Kanto already owns the hard half.** It ships 502 follower sheets
(`assets/enhanced_overworld/poke_followers/`, 251 species × normal/shiny) and a 7 000-line
follower subsystem under `lib/follower/`. It publishes a usable surface on `mod.exports`
(`main.lua:529-600`), reachable through the sanctioned cross-mod path (`mod.find` +
`mod.exports`):

| Export | Yields |
| --- | --- |
| `resolveFollowerSprite{species, shiny, form, surface, role, style, game}` | a draw-ready def: `image`, `frames`, `walker`, `trueColor`, `frameWidth/Height`, `anchorX/Y` (`lib/follower/sprite_service.lua:91`) |
| `getActiveFollowerMon(game, needHealthy)` | the mon WoK is drawing behind *this* player |
| `followerSnapshot()`, `followerCount()`, `controlMode()` | selection state |

**Why no sprite can be chosen at runtime through the mod API.** Four doors, all shut:

1. `Registry:append` errors on a frozen registry — `error(name .. ": content is frozen
   after load")` (`src/mods/Registry.lua:31`), and `Loader.lua:1725` freezes every
   registry after the boot merge. Runtime `register`/`patch` is out.
2. `NPC.new` resolves the sprite as a **string key**: `local spriteDef =
   data.sprites[objDef.sprite]; assert(spriteDef, "unknown sprite " ..
   tostring(objDef.sprite))` (`src/world/NPC.lua:27-29`). A def table is not accepted, and
   that assert fires inside the engine's own spawn path — the failure mode `Avatars.lua`
   already guards against in `spriteFor`.
3. `Handle` has no sprite setter. Its whole surface is `scriptMove`, `marchInPlace`,
   `face`, `position` (`src/world/WorldAPI.lua:391-410`).
4. No hook draws into the overworld's depth order. `render.zones` is the palette pass
   pre-blit — weather, lighting, colorization (`src/core/Game.lua:667-670`) — and
   `render.hud` is screen space **over the finished frame** (`:685-686`).

That is exactly why WoK took `engine_internals` and rebinds entity-locally:
`npc.sprite = SpriteRenderer.new(def, npc.id)` (`lib/follower/control_engine.lua:1486-1496`),
with `npc.spriteDef = def` as well on Gen 2 (`:1473`). Its own comment says as much —
"live species is applied via entity-local rebind, not global mutation"
(`lib/follower/sprite_service.lua:482`).

**What declaring `engine_internals` actually costs.** Less than it sounds in two places,
more in one:

- The **sandbox does not block** `src.render.SpriteRenderer`. `Sandbox.moduleDenial`
  (`src/mods/Sandbox.lua:49-64`) refuses only `io`, `os`, `debug`, `package`, `ffi`,
  `love.*`/`jit.*` submodules, and the network roots without `network`. `src.*` passes
  either way.
- The **tripwire is a warning**, not a gate (`src/mods/Loader.lua:176-181`,
  `warnOnce("engine_internals")`), and declaring the permission silences it.
- The **visible cost**: `ManagerState.lua:49` maps `engine_internals` to glyph `!` and
  the label **"PATCHES ENGINE CODE"**. The mod manager will show that badge on RBY MMO
  for every player, including those who never install WoK. Accepted deliberately.

## 3. Decisions

| Question | Decision | Consequence |
| --- | --- | --- |
| Which mon? | WoK's active follower (`getActiveFollowerMon`) | Sender *and* viewer both need WoK. A player without it emits nothing and appears alone. Chosen so what others see behind you is exactly what you see. |
| How many? | **One** — the primary | One extra NPC per avatar. Trailers (WoK does up to 6) would be 6× the NPCs and 6× the presence traffic. |
| Exposure | One option, **ON by default** | Cuts emission *and* display. |
| Rendering | `engine_internals` + entity-local rebind | Perfect depth sort, occlusion, palette, walk cycle. Costs the badge above and a `CLAUDE.md` amendment (§7). |

## 4. The wire — the half that cannot be changed later

`Config.PROTOCOL` **22 → 23**. Two optional fields on presence:

- **`mon`** — species **id** (string), sanitised against the `pokemon` registry the way
  `sprite` is sanitised against `sprites`. Absent means no follower. An id rather than a
  dex number because the rest of the mod speaks ids (`spriteId`, `mapId`) and an id
  validates against a registry.
- **`shiny`** — boolean, **strict** (`raw.shiny == true`). Same reason already written
  above `fast` in `Wire.lua`: both hubs re-derive presence from the same bytes, and a `0`
  or `""` would be true in Lua and false in JS.

No `form`: Gen 1/2 has none, so there is nothing to hand `resolveFollowerSprite`.

**Every path, not just one.** Three edits, because the three inbound paths do not share a
sanitiser:

1. `Wire.presence` (`src/Wire.lua:889`) — welcome roster and join.
2. `handlers[Wire.MOVE]` (`src/Client.lua:2017`) — inline, with a new `Wire.species`
   helper and `msg.shiny == true`.
3. `src/Roster.lua` — carry `mon`/`shiny` per player.

**Emission** (`pushPresence`, `src/Client.lua:1760-1782`): read
`getActiveFollowerMon(game)` and put `mon`/`shiny` in the `Wire.MOVE` payload and in
`lastSent`. **`presenceChanged` (`:1741`) must compare them too** — otherwise a player
who swaps follower while standing still is not re-sent until their next step.

**Twin parity.** `src/Hub.lua` and `server/lib/relay.js` both re-derive presence and both
gain the two fields with identical reject rules. Extend
`tests/fixtures/hub_protocol_parity.json`, `server/hub_protocol_parity.test.js` and
`server/twin_parity.test.js`. Process: `docs/plans/hub-twin-parity.md`. **Do not codegen
Lua↔JS.**

## 5. `src/Followers.lua` — new module

Its own file, beside `Avatars.lua` (already 19 KB and not in need of growth). Same shape:
`new()`, `sync(roster, mapId)`, `spawn(player)`, `advance(av)`, `despawn(id)`, `clear()`.

- **Spawn** — `mod.world:spawnNpc`, then rebind at once:
  `npc.sprite = SpriteRenderer.new(def, npc.id)`, plus `npc.spriteDef = def` on Gen 2.
  Spawn with the sprite id **`SPRITE_WILDS_FOLLOWER_MON`**, which WoK registers at load
  (`sprite_service.lua:532-540`): if the handle is not handed over on the same tick — the
  case `Avatars.lua:spawn` already documents — the waiting frame shows a POKéMON rather
  than a trainer.
- **Walk** — the follower steps into the cell its trainer has just **left**. The same
  five-field write, and the same `stepFrames`, so it runs when its trainer sprints or
  cycles. A one-cell trail is the whole state a single follower needs.
- **`passable = true`** — as avatars are; `tests/rby_mmo_test.lua:3221` already asserts
  this for avatars, and the follower gets the same assertion.
- **Sort** — a sub-pixel `py` bias, WoK's `_wildsDrawBias` idea
  (`control_engine.lua:1446-1450`), signed so the follower lands **under** its trainer.
  `Config.AVATAR_DEPTH_NUDGE` is the existing precedent.
- **Respawn on species/shiny change** — the sheet is baked at NPC creation, as
  `Avatars.lua` notes for avatar sprites. Despawn and respawn rather than mutate.
- **Despawn** with its avatar, on map change, and on the option going off.

**Wiring.** `src/Client.lua` owns it, as `ctx.followers` beside `ctx.avatars`, driven from
the same call sites that already drive avatars — `world.stepped`, `map.entered`,
`player.warped` — and torn down everywhere `ctx.avatars:clear()` is called. A follower is
never synced for a player who has no avatar: the avatar is the thing it trails.

## 6. The sprite

`resolveFollowerSprite{species, shiny, surface = "land", role = "primary", game}`, def
passed through **with its True Size geometry** (`frameWidth/Height`, `anchorX/Y`) — that
is what keeps an ONIX from drawing at RATTATA's size.

`require("src.render.SpriteRenderer")` in a memoised `pcall`. On failure: one
`mod.log:warn` naming the remediation and the feature stays dark. Never `error()` — the
loader's rule for mod callbacks.

## 7. Manifest & posture

- `permissions: ["network", "engine_internals"]`
- `optional_dependencies: ["overworld_wild_spawns"]`
- **`affects_link` stays `false`.** Nothing here writes a `LINK_REGISTRIES` member
  (`pokemon`, `moves`, `type_chart`, `statuses`, `move_effects`), so the byte-identical
  link-surface assertion holds.
- **`CLAUDE.md` must be amended in the same commit.** It currently states the opposite
  posture — "the honest path is an upstream RFC — not an `engine_internals`
  reach-around". Leaving it contradicting the manifest guarantees the next session
  relitigates this.
- **`.gitignore` gains `.claude/worktrees/`.** It is untracked but not ignored today, so
  a `git add -A` would commit an entire worktree into the repo.
- **`manifest.json` version bump + `CHANGELOG.md` entry**, keep-a-changelog, heading
  matching the new `manifest.version` — the repo's standing rule. The entry names the
  PROTOCOL bump, the new permission, and the WoK optional dependency, because all three
  are things a player upgrading needs told.
- **`mod.card`** gains the WoK compatibility note: the feature is invisible without it.

## 8. Option & degradation

One option — "see other players' POKéMON", **ON by default** — cutting emission *and*
display, removing live followers on `mod.options_changed`.

| Situation | Behaviour |
| --- | --- |
| WoK absent, or no follower selected | Nothing emitted, nothing drawn, nothing allocated |
| Species not in the `pokemon` registry | Field rejected inbound; the avatar walks alone |
| `SpriteRenderer` unavailable | One warn, feature dark |
| Trainer is surfing | v1 sends no surface, so `surface = "land"` — **the mon walks on water.** Known gap: presence carries no surf state, and adding it is a third field and a second bump |
| Trainer `busy` (battle, menu) | No cell → no avatar → no follower |
| Follower species changes | Despawn + respawn on the next sync |

## 9. Tests, and what cannot be verified here

Headless Lua suite (`tests/rby_mmo_test.lua`, which runs **without** WoK):

- `Wire.presence` and the `MOVE` path accept/reject `mon`/`shiny` — unknown species,
  non-strict `shiny`, absent fields.
- `Followers` with no WoK: spawns nothing, warns once rather than per tick.
- `Followers` with a **stubbed WoK** (`mod.find` returning fake `getActiveFollowerMon` /
  `resolveFollowerSprite`): spawn, respawn on species change, despawn with the avatar,
  `passable == true`.
- Trail: after the avatar completes a step, the follower targets the vacated cell.
- `presenceChanged` re-sends on a follower swap with no movement.

Node: parity fixtures extended; `hub_protocol_parity.test.js`, `twin_parity.test.js`,
`hub.test.js` green.

**What runs on this machine.** No `luajit` is on PATH — but **LÖVE 11.5 is installed**
(`C:\Program Files\LOVE\`), and it ships `lovec.exe` plus `lua51.dll`, i.e. an embedded
LuaJIT. A headless LÖVE shell (every module off, `loadfile` the script, quit) turns it
into a plain Lua runner, and the repo's standalone drivers say exactly what they need:
"Standalone: no love, no engine, no mod facade"
(`tests/drivers/hub_protocol_parity.lua:18`).

Measured at the base SHA through that runner:

| Suite | Result |
| --- | --- |
| `server/hub.test.js` | 148/148 |
| `server/twin_parity.test.js` | 9/9 |
| `server/hub_protocol_parity.test.js` | 13 passed, 2 skipped (both want `luajit` on PATH) |
| `tests/hub_battle.lua` | 170 passed, 0 failed |
| `tests/solo_battle.lua` | 152 passed, 0 failed |
| `tests/battle_sim_turn.lua` | 509 passed, 0 failed |
| `tests/drivers/hub_protocol_parity.lua` | regenerates the committed fixture **byte-identically** |

That last row is the one that matters for a PROTOCOL bump: the Lua half of hub parity is
**verifiable here, not hand-authored**. Windows appends a CRLF, so pipe a regenerated
fixture through `tr -d '\r'` before committing it.

**Still needs a real gen1recomp checkout.** Everything requiring `tests.modkit` — the
engine's test helper, which the packaged `.love` does not ship — namely
`rby_mmo_test.lua`, `trade2.lua`, `coop_mediated.lua`, `mediated_battle_client.lua`,
`battle_sim{,2}_vectors.lua`; plus `solo_brain.lua` (wants the engine's `TrainerAI`),
`modkit validate/lint/pack`, and the e2e drivers. **`rby_mmo_test.lua` is where the
`Wire.presence` and `Followers` tests of this plan belong**, so that half of §9 is written
blind until the engine is on disk.

Rendering is not verifiable by any suite — `SpriteRenderer` needs a live LÖVE game. Two
instances, by hand.

## 10. Rejected alternatives

- **Register a pool of sprite ids at load and patch them at runtime** — impossible;
  registries freeze after the boot merge (§2).
- **Draw the follower in `render.hud`** — `Overlay.lua` already maps world to screen, so
  it is cheap; but `render.hud` composites over the finished frame, so the mon would draw
  over trees and buildings and, worse, over the *local player* whenever the remote
  trainer stands north of them. Rejected on the visible artefact, kept on file as the
  zero-permission fallback.
- **Ask WoK for an `attachFollowerSpriteTo(npc, opts)` export** — ~15 additive lines in a
  mod that already does exactly this internally, and it would need no permission change
  here. Rejected only because it blocks delivery on a third party
  (`YoDrehDenSwagAuf/overworld-spawn-mod`). Still the right upstream ask.
- **Replicate WoK's full trailer stack** — 6× the NPCs and traffic (§3).

## 11. Open risks

1. **A second missing seam.** `Avatars.lua` already carries a note that the mod API lacks
   a "step this NPC" primitive on `Handle`. This adds a second: no way to give a runtime
   NPC a sprite chosen after load. Both belong in one upstream RFC.
2. **NPC budget.** `Avatars:spawn` caps nothing and `MAX_PLAYERS` is 64; followers double
   the runtime NPCs on a crowded map. Measure before adding trailers, ever.
3. **WoK is a moving target.** `resolveFollowerSprite`'s return shape is a private-ish
   contract on a third-party mod at 2.1.8. Guard every field read, and fail dark.
