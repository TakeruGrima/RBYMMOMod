# Plan — Classic battle UI, with level, gender and species icons

| Field | Value |
| --- | --- |
| Date | 2026-08-20 |
| Source | Owner request: "l'UI des combats utilise un aspect visuel moderne, je veux l'aspect classique du jeu original (avec une option pour la toggle) ; quand on choisit d'envoyer un autre POKéMON je ne vois pas son niveau ; j'aimerais voir les icônes du mod Unique Menu Icons ; je ne vois pas le gender (à vérifier avec gender mod). Par aspect classique j'entends un texte un peu plus gros sur le fond blanc classique — l'UI actuelle n'est pas très lisible et le texte est trop petit." |
| Config | AGENTS_CONFIG.yml (quality preset, host `claude_code`) |
| Flags | none |
| Branch | `ClassicUI` |
| Base SHA | 27db475 |

## 1. Objective & success criteria

Give the mod's battle screens a **classic Game Boy chrome** — white bordered boxes, the
engine's tile font, the stair-step HP bar — behind one option row, **default ON**. The
top-down arena itself is **kept**: only the menu band and the field plates change skin.

At the same time, fix three pieces of information the battle UI never showed, **in both
skins**: the **level** of a benched POKéMON at switch time, its **gender**, and its
**species icon** (which is whatever mod owns the icon registry — `unique_menu_icons` when
installed).

Done means:

1. A `CLASSIC BATTLE UI` toggle exists in the F10 mod manager, defaults **ON**, and
   flipping it takes effect on the next battle with no relaunch.
2. With it ON, the bottom menu band and every field plate draw as GB chrome: white box,
   tile border, tile font at ×2, `HudTiles` HP bar, `Font.drawCode(0xED)` cursor.
3. With it OFF, the current modern band and plates draw **byte-identically to today**.
4. The PKMN / switch list, the item-on-POKéMON list and the post-faint replacement list
   each show, per row: **species icon, name (nickname preferred), gender symbol, level,
   HP** — in **both** skins.
5. Field plates show the species icon beside the name — in **both** skins.
6. Gender resolves for **your own party** (real save DVs) **and for an MMO opponent**
   (`ivs.atk` off the wire sheet). No `gender_mod` installed → no symbol, no error.
7. Nothing on the wire moves: no `Config.PROTOCOL` bump, no `Wire` vocabulary change, no
   `server/` change. `affects_link` stays `false`.
8. Gen 1 (Red/Blue/Yellow) and Gen 2 (Gold) both.

Non-goals: the arena art, seat layout, ball throws, fx and exp sequencing are untouched;
the dormant 160×144 `CoopBattle` stage is **not** revived; the persistent 6-ball team row
keeps its balls.

## 2. Context & constraints (grounded)

Every claim below was read out of the tree at `27db475`, not assumed.

- **There is exactly one switch between skins today, and it is generation-shaped.**
  `Battlefield.enabled(game)` (`src/Battlefield.lua:317`) reads
  `THEATRE_GENERATIONS = {[1]=true,[2]=true}`, so it is `true` everywhere.
  `MediatedBattle:usesBattlefield` (`:1311`) and `CoopBattle:usesBattlefield` (`:5021`)
  are one-liners over it, and `uiSize` / `wantsFillScale` / `isWideBattleLayout` hang off
  those. **The dormant classic path is therefore unreachable, not merely unused** — and
  has been since `c9075ff` moved Gen 2 onto the arena. It is not to be trusted as a
  starting point; see §3.
- **The menu chrome is five functions in one file.** `drawBandBackdrop` (`:2612`),
  `drawMessagePanel` (`:2627`), `drawCommandGrid` (`:2674`), `drawListPanel` (`:2722`),
  and the plate painter `drawPlate` (`:2150`). Both battle screens reach the band only
  through the first four; nothing else paints menu chrome on the arena.
- **The "text too small" complaint is mechanical.** The band and plates draw with
  `M.FONT_MESSAGE = 14`, `FONT_PRIMARY = 13`, `FONT_SECONDARY = 11`, `FONT_MICRO = 10`
  (`:183-186`) on a **640×360** canvas, in white-on-translucent-dark
  (`PANEL_BG = {0.078,0.094,0.125,0.85}`, `:194`). The GB path draws 8px tiles in
  black-on-white on **160×144**, which the presenter scales up ~×4.
- **The level is available and simply never printed.** `MediatedBattle:partyRows`
  (`:3568`) builds `{ index, label = tostring(mon.species), fainted, active }` — so it
  drops the **nickname** as well as the level. `bandPartyRows` (`:5594`) then fills only
  `entry.right = "%d/%d" hp/maxHp`. The classic twin is worse: `CoopBattle:drawSwitch`
  (`:9363`) and `:drawReplace` (`:9352`) compose the name alone.
- **`drawListPanel` already accepts structured rows** — `{ label, right, dim }`
  (`:2760-2766`) — so a row model is an extension of a shape that exists, not a new one.
- **Gender needs the Attack DV, and the Attack DV already travels end to end.** This was
  the one assumed blocker and it is false:
  `MediatedBattle:631` sends `ivs = sheetOf(mon.dvs, 0, 15, generation)`;
  `Wire.lua:1274 statsOf` sanitises it against `STAT_KEYS_GEN1 = {"atk","def","spd","spc"}`
  (`:1254`) with range 0..15 (`:1359`); `server/lib/sanitize.js:908-911` passes it through
  the hub. **No protocol work is required for an MMO opponent's gender.** Only a key
  translation: the wire spells it `ivs.atk`, `gender_mod` reads `dvs.attack`.
- **`gender_mod` 0.3.5 exposes a real interop surface** (`main.lua:454-477`):
  `genderOf(mon)`, `genderOfSpecies(speciesId, dvs)`, `symbol`, `word`, `tile`, `palette`,
  `state`, plus HUD placement helpers `beforeLevelX(lvX, level)` / `afterLevelX`.
  `Gender.ofEntry(entry, dvs)` (`gender.lua:30-44`) is the resolver: species ratio kind,
  then `dvs.attack <= entry.femaleAtkMax` → `"F"` else `"M"`; `nil` means genderless or
  unknown. Its manifest carries **no `games` field**, which means gen 1 only
  (`ModTargets.legacy()`) — so on Gold the mod is simply absent and the symbol is absent
  with it. That is the correct behaviour, not a gap to paper over.
- **`unique_menu_icons` 1.5.0 writes the icon registry, it does not export icons.** Its
  only export is `ownsPartyIcons = true` (`main.lua:387`); the icons land via
  `mod.content.icons:override(name, …)` (`:440`, `:444`). The consequence for us is the
  whole integration design: **read `mod.content.icons` at draw time**, and whatever mod
  wrote last is what we paint. No dependency, no load-order assumption, no export contract
  to keep in sync.
- **Scaled transforms are already an established, guarded pattern in this file.**
  `Battlefield.lua:2251-2255` does `pcall(gfx.push)` / `gfx.scale` / restore. The engine
  tile font and the classic HP bar are reachable the way `CoopBattle:loadEngine` reaches
  them — `require("src.render.Font")` and `require("src.render.HudTiles")`
  (`CoopBattle.lua:112-113`), under the `engine_internals` permission the manifest already
  declares.
- **This machine cannot run the Lua suite.** No `luajit`, no `lua`, no `love`, and no
  `gen1recomp` checkout are present; only `node`. `node server/hub.test.js` runs here;
  `luajit tests/rby_mmo_test.lua`, `luajit tests/run_modkit.lua` and
  `python3 tools/modkit.py validate` must be run by the owner on the machine that has the
  checkout. **Nothing in this plan is to be reported green without that output.**

## 3. Approach & key decisions

**Model and paint are separated.** A pure module computes what a row or a plate *says*;
two painters render it. This is what makes "both skins" free rather than doubled: the
level, gender and icon are produced **above** the fork, so the two looks cannot disagree
about the facts.

```
                    BattleRows (pure, no love)
                    rowsFor(party, opts) -> { icon, name, gender, level, hp, maxHp, dim }
                    plateFor(seat, opts) -> { icon, name, gender, level, frac, … }
                              |
                    Battlefield.skin()   -- reads the option
                       /              \
      ClassicChrome (GB)            existing Battlefield painters (modern)
      Font.drawBox / drawCode        panel() / uiFont() / drawBar()
      HudTiles bar, transform x2     unchanged
```

Decisions, and why:

1. **The arena stays; only the band and the plates change skin.** Owner's call. It keeps
   the 2v2 seats, the ball throws and the exp sequencing, all of which exist only on the
   arena side.
2. **The dormant `CoopBattle` GB stage is not revived.** It draws in 160×144 while the
   arena canvas is 640×360, so reusing it means re-projecting — **the exact stretch the
   owner review already rejected**, recorded verbatim at `Battlefield.lua:2566-2569`
   ("4× horizontally against 1.67× vertically"). It is also method-bound to the
   `CoopBattle` instance, so `MediatedBattle` could not call it, and it has been
   unreachable and therefore untested since `c9075ff`.
3. **A ×2 tile scale, because the geometry lands exactly on it.**
   - Plate `PLATE_W × PLATE_H = 176 × 48` (`:137-138`) is **11 × 3 tiles at ×2**. Exact
     fit, so **no placement constant moves** — seats, the plate dodge and the pitch rules
     all stay as measured.
   - **CORRECTED DURING IMPLEMENTATION.** This section first claimed a 38 x 4 tile box
     inside the band, and that arithmetic confused *box height* with *content rows*: a
     bordered box spends two of its tile rows on the border, so a 4-tall box holds **two**
     lines of text, not four. Confined to the 80px band, x2 tops out at three content rows
     against the modern list's five.
     **What shipped instead:** the box is **not confined to the band**. It is
     **40 x 7 tiles at x2 (640 x 112), bottom-anchored, overhanging upward over the
     arena** - the way the original's message box overlays the scene. That is **five
     content rows**, the same count the modern list shows, at 16px instead of 11px. It
     costs nothing in layout: the field, the seats and the plate stacks are placed against
     `FIELD_BOTTOM` and never consult the box, so covering 32 more pixels of grass moves
     no constant. Pinned by test (`Classic.BOX_H > Bf.MENU_BAND`).
   - The **plate is drawn unboxed**, deliberately and for the same reason: the original's
     battle HUD has no border either - the engine's own GB path at
     `MediatedBattle:5409-5441` draws name, level and bar straight onto the background.
     Boxing it would have spent two of the plate's three tile rows on a border it never
     had.
   - Text cells go **10-13px -> 16px**, black on white instead of white on translucent
     dark. That is the readability fix.
   - Icons are 16x16 sources drawn **1:1**, and therefore **outside** the x2 transform -
     inside it they would land at 32px and swamp a 16px row. Never stretched, which is the
     trap `Battlefield.lua:29-31` already documents for 16xN sheets. In the *modern* skin
     they force the row height up to 16px, which costs that list its fifth row.

4. **Plates keep every fact they show today** (owner's call): exp strip, numeric HP on your
   own side per `plate.numbers`, and status — all redrawn in GB rather than dropped.
   Status becomes the tile sigil (`SLP`, `PSN`, …) instead of a coloured chip.
5. **Cross-mod reads are late and optional.** `mod.find("gender_mod")` and the icon
   registry are read at draw time and every failure degrades to "no ornament". Neither
   becomes a manifest dependency; declaring one would make this mod refuse to load without
   them.
6. **One toggle, not three states.** `CLASSIC BATTLE UI`, default ON. Read once and
   refreshed on `mod.options_changed` rather than polled per frame.

## 4. Work breakdown — implementation tasks

| # | Task | Files |
| --- | --- | --- |
| I1 | `BattleRows.lua`: pure row/plate model — nickname preferred over species, level, HP, `dim` on faint | `src/BattleRows.lua` (new) |
| I2 | `BattleRows`: gender resolution via `mod.find("gender_mod")`, incl. the `ivs.atk` → `dvs.attack` translation for wire sheets | `src/BattleRows.lua` |
| I3 | `BattleRows`: species-icon lookup against `mod.content.icons`, resolved at draw time, `nil`-tolerant | `src/BattleRows.lua` |
| I4 | `ClassicChrome.lua`: engine `Font` / `HudTiles` grab (in-body require), ×2 transform helper, GB box / text / cursor primitives | `src/ClassicChrome.lua` (new) |
| I5 | `ClassicChrome`: the five widgets — backdrop, message, command grid, list panel, plate | `src/ClassicChrome.lua` |
| I6 | `Battlefield.skin()` dispatcher; the five exported widgets forward to the active skin, preserving the `false` contract | `src/Battlefield.lua` |
| I7 | Feed the model into the **modern** painters too (icon on rows and plates, gender, level) | `src/Battlefield.lua` |
| I8 | Replace `partyRows` / `bandPartyRows` row composition with `BattleRows` | `src/MediatedBattle.lua` |
| I9 | Same for the co-op screen's list and replacement paths | `src/CoopBattle.lua` |
| I10 | The option row, its default, and the `mod.options_changed` refresh | `src/Client.lua`, `src/Config.lua` |
| I11 | `mod.card` / `README.md` / `CHANGELOG.md`: the option, and the two mods it plays well with | docs |

## 5. Work breakdown — test tasks

| # | Task | Where |
| --- | --- | --- |
| T1 | `BattleRows` rows: level present; nickname beats species; `dim` on 0 HP; active excluded from switch but present for items | `tests/rby_mmo_test.lua` |
| T2 | Gender: `ivs.atk` below `femaleAtkMax` → F, above → M, genderless → none, `gender_mod` absent → none, malformed DVs → none and no throw | `tests/rby_mmo_test.lua` |
| T3 | Icon: registry hit returns a handle, miss returns `nil`, and a `nil` icon still yields a complete row | `tests/rby_mmo_test.lua` |
| T4 | Geometry: the 11×3 plate and 38×4 band boxes fit `PLATE_W/H` and `bandRect` at ×2 | `tests/rby_mmo_test.lua` |
| T5 | Dispatch: option ON routes to `ClassicChrome`, OFF routes to the existing painters; an unavailable skin returns `false` so the caller's fallback fires | `tests/rby_mmo_test.lua` |
| T6 | Regression: with the option OFF, the modern widgets' inputs are unchanged | `tests/rby_mmo_test.lua` |
| T7 | Owner-run: `luajit tests/rby_mmo_test.lua`, `luajit tests/run_modkit.lua`, `modkit validate/lint/pack`, and a real two-instance `run-mmo-e2e.sh` | manual, owner's machine |

## 6. Execution waves

1. **W1 — model.** I1–I3 with T1–T3. Pure and headless-testable; nothing on screen moves.
2. **W2 — classic painter.** I4–I5 with T4. Draws nothing until W3 wires it.
3. **W3 — dispatch and option.** I6, I10 with T5–T6. First visible change.
4. **W4 — consumers.** I7–I9. The three information fixes reach both skins.
5. **W5 — docs and owner validation.** I11, T7.

## 7. Blast radius & risks

- **`Battlefield.lua` is the highest-traffic file in the battle path** and both battle
  screens draw through it. Mitigation: the modern painters are not rewritten — the
  dispatcher is added around them, and T6 pins their inputs.
- **A `require` at file scope kills the whole mod silently.** `ClassicChrome` must grab
  `src.render.Font` / `src.render.HudTiles` **inside** the draw body, memoised, exactly as
  `CoopBattle:loadEngine` does. This is the single most likely way to ship a mod that
  simply does not appear.
- **The plate is the tightest surface in the plan.** It keeps everything it shows today
  (§3.4) *and* gains an icon, inside 11 × 3 tiles. Name is already truncated to 10
  characters (`plateModel`, `:502`). If the row will not hold name + icon + level at ×2,
  the **icon yields first** — it is the ornament, the name is the fact. Decide it against
  a real frame, not in review.
- **`gender_mod` is gen 1 only** (no `games` field). Gold shows no gender. Stated, not
  worked around.
- **Icon registry contents are another mod's data.** Anything drawn from it is
  `pcall`-guarded and a miss degrades to no icon.
- **`affects_link` must stay `false`** — none of this writes a link registry, and the
  suite asserts the link surface is byte-identical.

## 8. What was actually verified, and where

§2 claimed this machine could not run the Lua suite. That was **half wrong and worth
correcting**: there is no `luajit` binary and no engine checkout, but `lupa` 2.8 is
installed and ships a **LuaJIT 2.1** runtime — the engine's own. So everything that does
not need LÖVE or the engine's modules was run here, for real.

| Check | Result |
| --- | --- |
| Every `src/` and `tests/` file compiled under LuaJIT 2.1 | **69 files, 0 syntax errors** |
| Whole module graph initialised through a stub facade (`Client` included) | **10/10, no cycle** |
| `BattleRows` model driven directly (level, nickname, gender, icons, degradation) | **32/32** |
| `ClassicChrome` geometry + `fit`/`wrap`, and the skin dispatch | **27/27** |
| The new suite section, extracted from `tests/rby_mmo_test.lua` and executed | **58/58** |
| `node server/hub.test.js` | **148/148** |

**Two real bugs were caught by running it rather than reading it**, both in the same
place and both silent:

1. `attackDv` walked `ipairs({ mon.dvs, mon.ivs })`. A mediated sheet carries no `dvs`, so
   that list is `{ nil, ivs }` — a table with a hole at index 1 — and `ipairs` stops before
   it ever reaches the ivs. Gender therefore resolved for your own party and **never once
   for an MMO opponent**, with no error anywhere. Fixed, and pinned by the wire cases in
   T2.
2. A `"\u{2640}"` escape written into `BattleRows`. That syntax is **Lua 5.3**; LuaJIT
   refuses to parse it, which purges the entire mod at load with one line in a log nobody
   reads. Replaced with raw UTF-8 bytes, and the compile sweep is what would catch a
   recurrence.

**Still owed by the owner, on the machine with the checkout** (nothing below can run
here): the full `luajit tests/rby_mmo_test.lua`, `luajit tests/run_modkit.lua`,
`modkit validate/lint/pack`, and a real two-instance `run-mmo-e2e.sh`. Everything that
touches LÖVE — that the box actually paints, that icons land where the layout says, that
the tile font is legible at ×2 — is unproven until a human looks at a frame.

## 9. Open questions / assumptions

1. **Assumed:** `gender_mod`'s absence of a `games` field means gen 1 only, per
   `ModTargets.legacy()`. To be confirmed at runtime on Gold rather than blocking.
2. **Assumed:** the engine's icon registry entry resolves to something drawable at 16×16
   for both the Gen 1 table form and the Gen 2 id form `unique_menu_icons` writes
   (`main.lua:440` vs `:444`). Both are reached through the engine's own
   `PartyMenu.drawIcon` rather than read directly, which is what makes the two forms the
   engine's problem and not this mod's — but only a real frame proves it.
3. **Resolved:** the 4-versus-6 row question is moot. The overhanging box (§3.3) gives
   **five** content rows at ×2, matching the modern list, so nothing was traded away.
4. **Open, and only a frame can answer it:** whether the plate holds name + icon + level
   inside 11 × 3 tiles. The code already yields the icon when the remaining name budget
   drops below 48px, so the failure mode is "no icon", never a clipped name.
