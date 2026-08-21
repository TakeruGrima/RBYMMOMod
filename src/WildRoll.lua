-- The other monsters in a party encounter, and the rule that says there are none.
--
-- Two players walking the same grass used to meet **one** wild monster and
-- fight it together.  They now meet one each -- except where the encounter was
-- never a roll in the first place: a legendary, Snorlax asleep on the road, the
-- Marowak ghost, the Safari, the old man's demonstration.  Those stay exactly
-- as they were, one monster in front of both players.
--
-- **The rule and the roll are the same question asked once.** A random
-- encounter is, by definition, a species drawn from the list this map keeps for
-- the terrain the player is standing on.  So: find the list that contains the
-- monster the engine just rolled, and draw another one from it.  A species that
-- is in no list on this map was not drawn from any -- it was placed there by a
-- script -- and the same lookup that would have produced a sibling answers nil
-- instead.  There is no separate "is this a legendary" table to keep current,
-- and a species added to a map by another mod is handled by having asked the
-- map rather than a list of names.
--
-- Two cheaper checks sit above it, and one below:
--
--   * the option, first, because a player who turned this off is owed nothing;
--   * the engine's own "this is a special battle" flags (Safari, ghost, demo,
--     and Gold's contest / tutorial / roaming / forced-shiny battle types),
--     read through SoloBattle.refused so there is one list of them in this mod
--     and not two;
--   * and a small denylist of species that are static everywhere, as the net
--     under the lookup.  It exists for the case where the map read fails or a
--     table turns out to name a legendary for reasons of its own -- duplicating
--     Mewtwo is the one failure here that a player could not undo.
--
-- **Every failure answers nil, and nil means "the encounter this mod already
-- knew how to run".** A map with no record, a registry shaped differently than
-- this reads, an engine that will not build a monster: all of them land on the
-- 2v1 that shipped in Party vs Wild rather than on an error inside a
-- `screen.pushed` listener.  That is also why the reader below is written to
-- accept several shapes rather than one: it is guessing at a schema this mod
-- has never had to read before, and the cost of guessing wrong is a feature
-- that quietly does not happen, not a broken encounter.
--
-- Nothing here draws from a BattleSim generator.  These rolls happen on one
-- client, before any fight exists, and the sim's streams have to stay
-- reproducible from their own seed alone.

local need, mod = ...
local Config = need("Config")
local Gen = need("Gen")

local M = {}

-- The manager row that turns this off.  Spelled here rather than in Client.lua
-- for the reason SoloBattle spells its own: the file that defines the row and
-- the file that reads it are the only two that have to agree, and this way they
-- agree by construction.
M.OPTION = "wildeach"
M.OPTION_LABEL = "WILD EACH"

-- On unless the player says otherwise, which is the opposite of SOLO BATTLES
-- and deliberate.  That row changes something the game already did; this one
-- changes something *this mod* added -- a party encounter is already a co-op
-- fight that vanilla has no opinion about, and one monster for two players was
-- never the interesting answer.
function M.isOn()
  local options = mod.options
  if not options then return Config.WILD_EACH_DEFAULT end
  local ok, value = pcall(options.get, options, M.OPTION)
  if not ok or value == nil then return Config.WILD_EACH_DEFAULT end
  return value ~= false
end

-- ------------------------------------------------------------------
-- names
-- ------------------------------------------------------------------

-- Compared loosely, because the same monster is spelled three ways depending on
-- which layer is holding it: a registry id (`NIDORAN_M`), the prose a fight is
-- narrated under (`NIDORAN M`), and whatever a table happens to use.  Case and
-- the separators are the only differences any of them have ever had.
local function key(species)
  if type(species) ~= "string" then return nil end
  local out = species:upper():gsub("[^A-Z0-9]", "")
  if out == "" then return nil end
  return out
end

-- ------------------------------------------------------------------
-- the map's own lists
-- ------------------------------------------------------------------

-- What a slot in an encounter list calls its monster and its level.
--
-- Field names are guessed generously and the guesses are cheap: a slot that
-- answers neither question is skipped, and a list of skipped slots is a list
-- this cannot roll from, which lands on nil like everything else here.
local function slotSpecies(slot)
  if type(slot) ~= "table" then return nil end
  return key(slot.species or slot.id or slot.name or slot.mon or slot.pokemon)
end

local function slotLevel(slot)
  if type(slot) ~= "table" then return nil end
  local low = tonumber(slot.level or slot.lvl or slot.minLevel or slot.min)
  local high = tonumber(slot.maxLevel or slot.max) or low
  if not low then return nil end
  low, high = math.floor(low), math.floor(high or low)
  if high < low then low, high = high, low end
  return low, high
end

-- How likely this slot is, when the table says so.
--
-- Gen 1 tables are ten entries with repeats and no weights at all -- the
-- repetition *is* the distribution -- so a uniform draw over the entries
-- reproduces it exactly.  A table that has been collapsed to one entry per
-- species has to carry the weight somewhere instead, and this reads it if it
-- is there.  Absent, every slot weighs the same, which is the ten-entry case.
local function slotWeight(slot)
  local n = tonumber(slot.rate or slot.chance or slot.weight or slot.probability)
  if not n or n <= 0 then return 1 end
  return n
end

-- Is this an array of encounter slots?
local function isSlotList(value)
  if type(value) ~= "table" then return false end
  local n = #value
  if n == 0 then return false end
  for i = 1, n do
    if not (slotSpecies(value[i]) and slotLevel(value[i])) then return false end
  end
  return true
end

-- Every list of slots hanging off a map's record, whatever it calls them.
--
-- Walked rather than named because the shape is not known here: grass, water,
-- fishing (which is usually three lists of its own, one per rod) and whatever a
-- generation or a mod adds are all "a list of slots somewhere under this
-- record".  Depth is small and fixed: an encounter record is a handful of
-- named groups, not a tree, and a bounded walk cannot be sent spinning by a
-- table that points at itself.
local function collectLists(record, depth, out, seen)
  out, seen, depth = out or {}, seen or {}, depth or 0
  if type(record) ~= "table" or depth > 3 or seen[record] then return out end
  seen[record] = true
  if isSlotList(record) then
    out[#out + 1] = record
    return out
  end
  for _, value in pairs(record) do
    if type(value) == "table" then collectLists(value, depth + 1, out, seen) end
  end
  return out
end

-- The map's encounter record, from wherever this build keeps it.
--
-- Three readings, first hit wins.  The registry accessor is the documented one
-- and is tried first; `game.data` is where every other table this mod reads
-- actually lives (moves, landmarks, constants), so it is tried next by key and
-- then by walking for a record that names the map itself.
function M.recordFor(game, mapId)
  if type(mapId) ~= "string" or mapId == "" then return nil end

  local content = mod.content
  local registry = content and content.encounters
  if registry and type(registry.get) == "function" then
    local ok, record = pcall(registry.get, registry, mapId)
    if ok and type(record) == "table" then return record end
  end

  local data = game and game.data
  local table_ = data and data.encounters
  if type(table_) == "table" then
    local direct = table_[mapId]
    if type(direct) == "table" then return direct end
    for _, record in pairs(table_) do
      if type(record) == "table"
         and (record.id == mapId or record.map == mapId or record.mapId == mapId) then
        return record
      end
    end
  end
  return nil
end

-- The list this map keeps that the engine's own roll came out of.
--
-- **This is the scripted-encounter rule.** Nil here is the answer for a
-- legendary, for a monster a script placed, and for a map whose lists could not
-- be read -- three different facts with one correct consequence.
function M.listFor(record, species)
  local want = key(species)
  if not want then return nil end
  for _, list in ipairs(collectLists(record)) do
    for i = 1, #list do
      if slotSpecies(list[i]) == want then return list end
    end
  end
  return nil
end

-- ------------------------------------------------------------------
-- the draw
-- ------------------------------------------------------------------

local function random(lo, hi)
  local love_ = rawget(_G, "love")
  local roll = love_ and love_.math and love_.math.random or math.random
  local ok, value = pcall(roll, lo, hi)
  if ok and tonumber(value) then return math.floor(value) end
  return lo
end

-- One slot out of the list, by weight.
local function pick(list)
  local total = 0
  for i = 1, #list do total = total + slotWeight(list[i]) end
  if total <= 0 then return nil end
  local roll = random(1, total)
  local seen = 0
  for i = 1, #list do
    seen = seen + slotWeight(list[i])
    if roll <= seen then return list[i] end
  end
  return list[#list]
end

-- ------------------------------------------------------------------
-- building the monster
-- ------------------------------------------------------------------

-- The engine builds it, always, and this mod never describes a monster itself.
--
-- Gen 2 has a factory that makes exactly one monster.  Gen 1's cheapest reach
-- is `BattleState.newWild`, which builds a whole battle around it -- more than
-- is wanted, but it is the engine's own construction, DVs, moves, stats and
-- all, and the alternative is this mod writing a second one that would drift
-- from it.  The BattleState is dropped on the floor: it is never pushed, so
-- nothing it built is ever drawn or heard.
-- A module field rather than a local, and the only one here: it is the single
-- line in this file that reaches the engine, so it is the single line a
-- headless suite has to stand in for.  Everything above it -- the option, the
-- refusals, the map lookup, the draw -- is then testable without a ROM.
function M.buildMon(game, species, level)
  if Gen.generation(game) == 2 then
    local ok, Mon = pcall(require, "src.battle.gen2.Mon")
    if not (ok and Mon and type(Mon.new) == "function") then return nil end
    local built, mon = pcall(Mon.new, (game and game.data) or {}, species, level)
    if built and type(mon) == "table" then return mon end
    return nil
  end

  local ok, BattleState = pcall(require, "src.battle.BattleState")
  if not (ok and BattleState and type(BattleState.newWild) == "function") then
    return nil
  end
  local built, battle = pcall(BattleState.newWild, game, species, level)
  if not (built and type(battle) == "table") or battle.dead then return nil end
  local mon = battle.enemy and battle.enemy.mon
  if type(mon) == "table" then return mon end
  return nil
end

-- ------------------------------------------------------------------
-- the ladder
-- ------------------------------------------------------------------

-- One more wild monster for this encounter, or nil for "one is the answer".
--
-- `state` is the engine's just-pushed battle screen, read only for its special
-- battle flags; `hostMon` is the monster it rolled.
function M.second(game, mapId, state, hostMon)
  if not M.isOn() then return nil end
  if type(hostMon) ~= "table" then return nil end

  -- The battles the engine spells as encounters and then turns into something
  -- else.  SoloBattle already keeps this list because its referee models none
  -- of them either; a second copy here would be a second thing to update.
  local SoloBattle = need("SoloBattle")
  if SoloBattle and type(SoloBattle.refused) == "function" then
    local ok, refused = pcall(SoloBattle.refused, state)
    if ok and refused then return nil end
  end

  local species = hostMon.speciesId or hostMon.species
  local named = key(species)
  if not named then return nil end
  if Config.WILD_STATIC_SPECIES[named] then return nil end

  local list = M.listFor(M.recordFor(game, mapId), species)
  if not list then return nil end

  local slot = pick(list)
  if not slot then return nil end
  local low, high = slotLevel(slot)
  if not low then return nil end

  local mon = M.buildMon(game, slot.species or slot.id or slot.name,
    high > low and random(low, high) or low)
  return mon
end

-- `count` more of them, for a party bigger than two.  Independent draws, the
-- way two players walking into the same grass separately would have been.
function M.extras(game, mapId, state, hostMon, count)
  local out = {}
  local wanted = math.min(math.max(0, math.floor(tonumber(count) or 0)),
    Config.COOP_SIDE - 1)
  for _ = 1, wanted do
    local mon = M.second(game, mapId, state, hostMon)
    if not mon then break end
    out[#out + 1] = mon
  end
  return out
end

return M
