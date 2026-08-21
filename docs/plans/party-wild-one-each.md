# Plan — One wild each (`coop_wild`, N seats on side b)

| Field | Value |
| --- | --- |
| Date | 2026-08-20 |
| Source | owner conversation — "plusieurs pokémons au lieu d'un seul, sauf les rencontres scriptées" |
| Branch | `feat/party-wild-one-each` (proposed) |
| Base SHA | `27db475` (`fix: draw the trainer, and our own POKéMON's front pic, in a solo battle`) |
| Supersedes | nothing; **extends** [`party-wild-encounter.md`](party-wild-encounter.md) |

## 1. Objective & success criteria

Today a partied pair that steps on grass fights **one** wild monster together
(`coop_wild`, 2v1). This plan makes an ordinary grass encounter put **one wild
monster on the field per player** — two today, since `Config.PARTY_MAX` is 2 —
while a **scripted** encounter (a legendary, Snorlax, the Marowak ghost, the
Safari, the old man's demonstration) keeps the 2v1 it has now.

Success when all of the following hold:

1. **A random encounter diverted into `coop_wild` seats one wild per human.**
   Two players on the same map, both free, ordinary grass/water/fishing: two
   wild monsters, one field, four battlers.
2. **A scripted encounter still opens the 2v1 it opens today.** No new branch
   is written for it: the host uploads a single monster and the hub's existing
   spare-seat drop (`Hub:fillBattleParty`) collapses the field to 2v1.
3. **A catch removes that monster and the fight continues** while another wild
   is still standing. Both players can go home with one; the balls are
   first-come-first-served, with **no per-player quota**.
4. **The second wild is a fresh roll from the map's own encounter list** — the
   two players can meet two different species.
5. **An option row, default ON**, turns the whole thing off; off means exactly
   today's 2v1.
6. **PROTOCOL bump** so an older hub or client refuses the fight instead of
   mis-seating it or dropping an event it cannot read.
7. **Tests:** BattleSim x2 generations + both Node twins + parity fixtures,
   hub seating, Coop/CoopBattle units, and an e2e.

Non-goals: parties larger than two (`PARTY_MAX` is 2 and the sim's
`FIGHTERS_PER_SIDE` is `Config.COOP_SIDE` = `PARTY_MAX`; the code below scales
with it but nothing here raises it), trainer battles, and the solo `wild` mode's
overworld behaviour (it still has no divert).

## 2. Context & constraints

### Ground truth (verified in this tree, 2026-08-20)

Four mechanisms this feature needs **already exist and are exercised**:

| Need | Where it already lives |
| --- | --- |
| A side that holds two fighters | `coop_npc` is 2v2. `Turn.lua:135-143` `maxFighters()` brands side `b` at 1 **only** for `coop_wild`; every other mode gets `FIGHTERS_PER_SIDE` |
| Dealing one upload across N seats | `Hub:fillBattleParty` (`src/Hub.lua:1394-1440`) deals a side-`b` party alternately over `record.npcIds` **and drops the seats it could not fill** — a one-monster upload already becomes a 2-on-1 |
| Aiming at one of several foes | `choice.target` is a 0..3 field slot and is already normalised (`Turn.lua:1004-1031`); `_autoTarget` (`Turn.lua:711-719`) already spreads unchosen aim over living foes, off `self.aim`, not `self.rng` |
| Building a second wild monster | Gen 1 `BattleState.newWild(game, species, level)` and Gen 2 `Mon.new(data, species, level)` — both driven from `tests/drivers/mmo_util.lua:1918-1946` |

What is genuinely in the way:

- **The ball has no aim.** `Turn.lua:1786-1812`: *"Wild modes seat exactly one
  monster on side b, so 'the first living foe' and 'the only foe' are the same
  seat -- no aim to spread."* It throws at `_firstLivingFoe`.
- **A catch ends the whole fight.** The same block calls
  `_finish("win", …, "catch")` and hangs the sheet on the outcome
  (`finish.caught`, `finish.catcher`). There is no way to say "this one is
  caught, the other is still up".
- **Clients are driven by events, not by snapshots.** `Turn.lua:3143-3149`
  states it outright: *"For tests and for a log line, not for a client: a
  client is sent events."* A monster leaving the field because it was caught
  therefore needs an event of its own; `M.KINDS` (`BattleSim/events.lua:68-72`)
  is a **closed set** with a validator that refuses an unknown kind (`:248`,
  `:268`).
- **…and an event is flat scalars, on purpose.** `Wire.battleEvent`
  (`src/Wire.lua:1682-1730`) rebuilds every event from a whitelist of scalars
  (`text`, `amount`, `slot`, `hp`, `species`, `speciesId`, `level`,
  `participants`, `mon`) and says why: *"Unknown keys are dropped by
  construction … whereas passing an opaque blob through would be handing a
  screen fields nothing had checked."* **A caught monster's sheet cannot ride
  an event.** `exp` is the precedent to copy: the event states facts, the
  client does the work.
- **The hub writes the 2v1 contract down twice.** `Hub.lua:1291`
  (`if mode == "coop_wild" and #memberIds ~= 2 then return nil end`) and
  `:1299-1302` mint exactly one npc seat; `server/lib/relay.js:2507-2519` is
  the twin.
- **There are four sims, not two.** `src/BattleSim/Turn.lua`,
  `src/BattleSim2/Turn.lua` (Gen 2), `server/lib/battle/Turn.js`,
  `server/lib/battle2/Turn.js` — `coop_wild` and `maxFighters` appear in all
  four, at `:129-141` in the Gen 2 Lua.
- **Nothing in this mod has ever read the `encounters` registry.** Rolling a
  second species is the only genuinely new capability, and its record schema is
  unverified from this checkout (see §8 / T0).

### Locked owner decisions

| # | Decision |
| --- | --- |
| Count | One wild **per player** (two today) |
| Catch | Removes that monster; the fight continues while another stands |
| Ball quota | **None** — first come, first served; one player may take both |
| Second monster | **Fresh roll** from the map's own encounter list |
| Scripted encounters | Legendary / Snorlax / ghost / Safari / old man → **the 2v1 it is today** |
| Option | A row in the mod manager, **default ON** |

### Assumptions (stated, not asked)

1. **A caught monster pays experience**, through the same `pendingExp` path a
   faint uses (`Turn.lua:2869`). Vanilla Gen 1 pays on a catch; today's
   mediated catch pays nothing only because the fight ends on the spot. This
   makes the two endings consistent — say so if it should not.
2. **RUN is unchanged**: either player flees and the fight ends for both, wild
   semantics, no consent (`_concedeRun`, `Turn.lua:2173`).
3. **The wait label and the battle key are still built from the host's own
   rolled monster** (`Coop.battleKey`). The partner has joined before the
   second monster is ever named.
4. **`Effects.isWildMode` and `isWildSeat` are untouched.** Both side-`b` seats
   are wild seats; neither carries a bag; neither can be handed an item.
5. **The option is read at the encounter**, not at install — the same way
   `SOLO BATTLES` is (`Client.lua:2494-2498`), so flipping it takes on the next
   step in the grass.

## 3. Approach & key decisions

**No new mode token.** `coop_wild` gains a side-`b` ceiling of
`Config.COOP_SIDE` instead of a hard 1. A one-monster upload is still a legal
`coop_wild` — which is exactly what makes the scripted case free.

| Concern | Choice | Why |
| --- | --- | --- |
| Mode | Keep `coop_wild`; raise `maxFighters(mode, "b")` to `FIGHTERS_PER_SIDE` | `Effects.isWildMode` keeps working; the scripted 2v1 and the 2v2 are the same fight with a different roster, not two modes to keep in step |
| Seats | Hub mints `#memberIds` npc seats (capped at `COOP_SIDE`), host uploads N monsters, `fillBattleParty` deals them | The dealing and the spare-seat drop are already written and already tested by `coop_npc` |
| Catch, on screen | A new `caught` **event**, flat scalars only (`slot`, `side`, `text`, `speciesId`, `level`): that seat leaves the field, then `_checkOver` decides whether anything is left | The client is event-driven, and an event is the only thing that can empty a seat mid-fight |
| Catch, in the save | The **sheets stay on the outcome**, as a `catches` list (`{ caught, catcher }`), delivered whatever ends the fight | `Wire.battleEvent` is a scalar whitelist by design; `Wire.battleOutcome` already carries exactly this sheet (`Wire.lua:1845-1851`). One list where there was one field |
| Grant | At the outcome, looping the list, keyed for idempotence; the naming prompts queue behind each other (`CoopBattle.lua:1704` already owes one) | Where the grant already happens today — nothing about *when* a monster reaches a save changes, only how many |
| Ball aim | `choice.target` honoured on a ball exactly as on a move; unaimed default stays `_firstLivingFoe` (predictable, never a die roll — `Turn.lua:1019-1023`) | One rule for aim in the whole sim |
| Second monster | `src/WildRoll.lua`: find the map list that contains the host's species, roll another slot from **that** list | The same question answers "is this scripted?" — a species that is in no list on this map was not rolled by the grass |
| Scripted detection | Three layers: `Config.SOLO_REFUSED` flags → species-not-in-any-list → a small static denylist in `Config` | Layer 2 is the real rule; 1 and 3 are the net under it |
| Option | `toggle`, default `true`, read per encounter | Owner decision |
| Protocol | 22 → **23** | New event kind + a hub that seats `coop_wild` differently; an older peer must refuse, not improvise |

**Alternatives rejected:**

- *A new mode (`coop_wild2`, `coop_swarm`).* Doubles every `coop_wild` branch
  in four sims, two hubs and the client, and buys nothing: the roster already
  says how many wilds there are.
- *Reuse the `faint` event to remove a caught monster.* Free — no vocabulary
  change, no PROTOCOL bump — and a lie in the one place this codebase is least
  willing to tell one. A client suppressing "…fainted!" because the previous
  event happened to be a ball is a rule nobody will find again in a year.
- *Keep "the first catch ends the fight" and just field two monsters.* Cheapest
  of all, and it defeats the point: the second player watches the first one
  take a ball and the encounter closes.
- *Nest the caught sheet on the `caught` event and grant mid-fight.* It reads
  well and it fights the wire: `Wire.battleEvent` would have to grow its first
  nested table, and `sanitize.js` its twin, against a file that argues at
  length for the flat whitelist. `exp` already showed the way — the event
  states the fact, the sheet arrives with the outcome the grant already used.
- *Both players' clients roll their own wild.* Two rolls, two truths, and the
  hub would have to pick. The host already owns the encounter; it owns both.

## 4. Work breakdown — implementation tasks

### T0 — Spike: the encounter registry and the cheapest wild factory
**Owns:** nothing in the tree (findings go into T4's header comment).
**Does:** against a real engine checkout, answer three questions:
(a) what `mod.content.encounters:get(mapId)` returns — list shape, per-slot
fields (species, level, rate), and whether grass / water / fishing are separate
records or separate lists inside one; (b) whether a monster can be built without
constructing a whole `BattleState` (`newWild` starts a battle object; the test
drivers push it — a factory such as `Mon.new` is preferred if Gen 1 exposes
one); (c) whether a grass encounter can ever be pushed from inside a running
script (if it cannot, `script.started`/`script.ended` becomes a fourth, cheap
scripted detector worth adding).
**Deps:** none. **Blocks:** T4 only.
**Accept:** the three answers written down; T4's ladder confirmed or amended.

### T1 — Vocabulary: the `caught` event, the `catches` list, PROTOCOL 23
**Owns:** `src/BattleSim/events.lua`, `src/BattleSim2/events.lua`,
`server/lib/battle/events.js`, `server/lib/battle2/events.js`,
`src/Wire.lua` (`BATTLE_EVENTS` **and** `battleOutcome`),
`server/lib/sanitize.js` (both twins), `src/Config.lua` (PROTOCOL + comment),
`server/lib/relay.js` (PROTOCOL + comment block ~`:109-136`), `CHANGELOG.md`,
`server/twin_parity.test.js` if it asserts the kind set.
**Does:** two additions, in six vocabularies.
- Event kind `caught`, **flat scalars only**: `slot`, `side`, `text` (the
  species, as `faint` carries it), `speciesId`, `level`. It says one thing —
  *that seat is gone, and not because it fainted* — and nothing a client has to
  store.
- Outcome field `catches`: an ordered list of `{ caught = <sheet>, catcher =
  <player id> }`, sanitised with the **same** helpers the singular
  `caught` / `catcher` already use (`Wire.lua:1845-1851`), bounded at
  `Config.COOP_SIDE`. The singular pair stays, unchanged, for mode `wild`.
Then bump 22 → 23 on both sides with the sentence that says why.
**Deps:** none. **Accept:** the six vocabularies agree; a pre-23 peer is
refused with the version sentence rather than dropping the event; a `wild`
outcome is byte-identical to today's.

### T2 — Hub seating twins
**Owns:** `src/Hub.lua` (`openMediatedBattle`, and the `isWildSeat` /
`battleSeat` comments that state "one seat"), `server/lib/relay.js` (twin).
**Does:** for `coop_wild`, mint `min(#memberIds, Config.COOP_SIDE)` npc seats
instead of one; keep the "exactly two humans" contract; leave `wild` (solo,
one seat) alone. `fillBattleParty` needs **no change** — it already deals and
already drops the seats an upload could not fill.
**Deps:** T1 (PROTOCOL). **Accept:** a two-monster upload seats two wilds; a
one-monster upload seats one and the record's `npcIds` shrinks to it; `wild`
and `coop_npc` records are byte-identical to before.

### T3 — Sim: seat cap, ball aim, catch-as-removal (x4)
**Owns:** `src/BattleSim/Turn.lua`, `src/BattleSim2/Turn.lua`,
`server/lib/battle/Turn.js`, `server/lib/battle2/Turn.js`.
**Does:**
- `maxFighters("coop_wild", "b")` → `FIGHTERS_PER_SIDE`.
- `_resolveItems` ball branch: honour `choice.target` through `_retarget`,
  defaulting to `_firstLivingFoe` when the thrower named none.
- On a successful catch: emit the ball chain and "Gotcha" as today, emit
  `caught`, take the monster off the field through the **same** path a faint
  uses — `_unfield` for the participation sets, then the seat's active cleared;
  a wild seat's party is one monster, so the seat is simply out, exactly like a
  one-monster trainer.
- Append `{ caught = Effects.caughtSheet(target), catcher = fighter.playerId }`
  to `self.catches`, and have **`_finish` attach that list to every outcome it
  builds, whatever the reason** — a catch followed by a RUN, a blackout or a
  disconnect must still deliver the monster somebody already saw land.
- Owe the experience (`pendingExp`) as a faint does — see §2 assumption 1.
- Then `_checkOver()`: side `b` still alive → the turn carries on; side `b`
  empty → `_finish("win", …, "catch")`, which still fills the singular
  `caught` / `catcher` for the monster that ended it, so nothing already on the
  wire disappears and mode `wild` never notices any of this.
- Unchanged: `isWildSeat`, `Effects.isWildMode`, `_concedeRun`, `EXP_MODES`.
**Deps:** T1. **Accept:** two balls in one turn resolve in speed order, the
first success removes its own target only, the second throw still resolves; a
catch with one wild left standing does **not** finish the battle; a catch that
empties side `b` finishes it with reason `catch`; single-wild `coop_wild` and
`wild` replay identically (`self.aim` is not drawn with one living foe).

### T4 — `src/WildRoll.lua`: the second monster, and the scripted rule
**Owns:** new `src/WildRoll.lua`, `src/Config.lua` (option key/default, static
denylist), `src/Gen.lua` if the per-generation factory belongs there.
**Does:** `WildRoll.second(game, mapId, hostMon)` → a monster, or `nil` meaning
*"one wild, the way it is today"*. The ladder, in order, first `nil` wins:
1. the option is off → `nil`;
2. `SoloBattle.refused(state)`-shaped flags (`Config.SOLO_REFUSED`) → `nil`;
3. the host's species is on `Config.WILD_STATIC_SPECIES` → `nil`;
4. the map has no encounter record, or **no list on it contains the host's
   species** → `nil` — this is the scripted rule, and it is the same read as
   the roll;
5. otherwise roll another slot from *that* list and build the monster
   (Gen 1 / Gen 2 split behind one function).
Rolls with `love.math.random` seeded the way `SoloBattle:_seed` does
(`SoloBattle.lua:448-460`); nothing here feeds the sim's parity RNG.
**Deps:** T0. **Accept:** a grass species rolls a sibling; a legendary, a
Safari, a ghost and an unknown map each answer `nil`; every failure answers
`nil` rather than throwing.

### T5 — Divert + upload
**Owns:** `src/Coop.lua` (`onWildEncounter`, `beginWildCoop`),
`src/CoopBattle.lua` (`wildMons`, `uploadMediated`'s `coop_wild` branch
~`:8347-8360`).
**Does:** on divert, ask `WildRoll` for one extra monster per **other** party
member and stash them beside `wildCatchMon`; `wildMons()` returns the host's
monster first and the rolled ones after, so the deal in `fillBattleParty` puts
the host's own encounter on seat 1. Everything else about the divert — the
gates, the wait, the auto-join, the label, the key — is untouched.
**Deps:** T2, T4. **Accept:** the wait and the join are wire-identical to
today; the upload carries N monsters; with the option off, exactly one.

### T6 — Client: the fight, the aim, the grant
**Owns:** `src/CoopBattle.lua` (foe seats, ball aim, `grantCatch` /
`MED_REASONS` ~`:8451`, `:9033-9110`), `src/MediatedBattle.lua` (`grantCatch`
`:3231`, its call site `:3392`), `src/Battlefield.lua` if the two-foe layout
needs anything the `coop_npc` path does not already draw.
**Does:** draw two wild pics (the `coop_npc` layout); take the `caught` event as
"empty that seat, and do not say *fainted*"; offer the existing aim widget on a
ball when more than one foe is standing; grant by walking `outcome.catches` and
keeping only the entries whose `catcher` is this client, keyed so the singular
`caught` / `catcher` on the same outcome cannot grant the last one twice; queue
a second owed naming prompt behind the first.
**Deps:** T1, T3. **Accept:** the catcher's save gains exactly one monster per
entry addressed to them and the partner's gains none; a catch followed by a RUN
still grants; two catches in one fight produce two prompts, in order, after the
battle.

### T7 — The option row
**Owns:** `src/Client.lua` (the `mod.options:define` block ~`:2435-2499`),
`src/Config.lua`, `README.md` (the options table ~`:857`), `mod.card` if it
lists options.
**Does:** `{ key = …, label = "WILD EACH", type = "toggle", default = true }`,
key and label spelled in the module that reads them (the `SoloBattle.OPTION`
pattern), with a header comment saying why this one is **on** by default where
`SOLO BATTLES` is off: it changes something *this mod* added, not something the
game already did.
**Deps:** T4 (which reads it). **Accept:** off ⇒ today's 2v1, byte for byte.

### T8 — Docs
**Owns:** `docs/plans/README.md` (Living table), `CHANGELOG.md`.
**Deps:** none.

## 5. Work breakdown — test tasks

### TT1 — Sim + parity, both generations
**Owns:** `tests/battle_sim_turn.lua`, `tests/battle_sim2_turn.lua`,
`server/battle_turn.test.js`, `server/battle2_turn.test.js`, and the
regenerated `tests/fixtures/battle_turn_parity.json` /
`battle_sim_vectors.json` + their drivers.
**Covers:** T3. Two wilds seated; ball aim; catch removes one and the fight
goes on; catch that empties side `b` finishes with `catch`; exp on a catch;
`catches` delivered on **every** ending (catch, ko, run, forfeit);
**single-wild vectors unchanged** (the regression that matters most).

### TT2 — Hub seating + twin parity
**Owns:** `tests/hub_battle.lua`, `server/hub_battle.test.js`,
`server/twin_parity.test.js`, `tests/fixtures/hub_protocol_parity.json` +
`tests/drivers/hub_protocol_parity.lua` / its Node twin.
**Covers:** T1, T2. Two npc seats; one-monster upload collapsing to 2v1;
PROTOCOL 23 refusal sentence.

### TT3 — Roll + scripted rule
**Owns:** `tests/rby_mmo_test.lua` (a `WildRoll` section), fixtures for a fake
encounter record.
**Covers:** T4, T7. Each rung of the ladder, including "every failure is `nil`".

### TT4 — Divert, upload, grant
**Owns:** `tests/coop_mediated.lua`, `tests/rby_mmo_test.lua`.
**Covers:** T5, T6. Upload order; grant only for the catcher; no double grant
when the outcome repeats the last catch; two owed prompts.

### TT5 — e2e
**Owns:** `tests/drivers/run-party-wild-e2e.sh` (or the sibling it grew from) +
`tests/drivers/mmo_util.lua` barriers.
**Covers:** the stack. Two LÖVE clients, a party, the same map, a staged
encounter: two wilds appear, each player catches one, both saves gained one.
**Requires a machine with the engine checkout and a ROM** — see §7.

## 6. Execution waves

| Wave | Tasks | Barrier |
| --- | --- | --- |
| 0 | **T0** ‖ **T8** | The registry's shape is known |
| 1 | **T1** | Vocabulary + PROTOCOL, everything else keys off it |
| 2 | **T2** ‖ **T3** ‖ **T4** | Hub, sims and the roll are disjoint files |
| 3 | **T5** ‖ **T7** | Divert uses the roll and the option |
| 4 | **T6** | The screen and the grant |
| 5 | **TT1** ‖ **TT2** ‖ **TT3** ‖ **TT4** | Units and parity |
| 6 | **TT5** | e2e last |

Checkpoint commit after each wave.

## 7. Blast radius & risks

| Risk | Mitigation |
| --- | --- |
| **Parity drift across four sims** — the same catch has to remove the same seat at the same point in two languages and two generations | One task owns all four files (T3); the vector fixtures are regenerated in TT1 and are the only proof that counts |
| **`self.aim` now draws where it never did** — a second living foe consumes an aim byte | Deliberate, and already the design (`Turn.lua:691-710`). The guarantee that must hold is the *single*-wild replay: one living foe still draws nothing. Asserted in TT1 |
| **The same monster is granted twice** — once from `catches`, once from the singular `caught` that ended the fight | One reader: `catches` when it is present, the singular pair only when it is not (mode `wild`). Idempotence key on top, asserted in TT4 |
| **A catch is lost because the fight ended some other way** (RUN, blackout, a disconnect forfeit) | `_finish` attaches `catches` on **every** path, not only `reason == "catch"`. One test per ending in TT1 |
| **`encounters` schema is guessed** | T0 blocks T4; every failure in the ladder answers `nil`, so a wrong guess degrades to today's 2v1 rather than throwing inside `screen.pushed` |
| **`BattleState.newWild` has side effects** when used as a factory (music, sprites) | T0 looks for a lower-level factory; if there is none, build it and never push it, and say so in the header |
| **A legendary slips through the net** and gets duplicated | Three independent layers, and the species denylist is the one that needs no engine knowledge to be right |
| **Mixed-version parties** | PROTOCOL 23 refuses with the version sentence; the rollback is the bump plus the seat cap |
| **This machine cannot run the engine suites** (`~/Projects/alamops/gen1recomp` absent, no `luajit` on PATH) | Node suites and parity twins run here; `modkit validate`, the Lua suite and TT5 run on the owner's engine box — flagged before, not after, the work |

Rollback: revert the seat cap and the PROTOCOL bump; `coop_wild` is a 2v1 again
and the option row disappears.

## 8. Open questions

1. **Experience on a catch** — §2 assumption 1 says yes (vanilla pays, and the
   `pendingExp` path is already there). It is a gameplay change to today's
   single-wild catch as well; say if it should stay unpaid.
2. **Option label** — `WILD EACH` is a placeholder; the manager's rows are
   short and uppercase.
3. **A fourth scripted detector** (`script.started` / `script.ended`) — worth
   adding only if T0 finds that grass never pushes from inside a script.

---

**Approval gate:** no production code until this is confirmed or amended.
