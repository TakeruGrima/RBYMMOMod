-- src/WildRoll.lua: the second wild monster, and the rule that says there is none.
--
-- Run: luajit tests/wild_roll.lua               (from this folder's root)
--   or luajit mods/rby_mmo/tests/wild_roll.lua  (from the engine)
--
-- Standalone, for the reason tests/solo_battle.lua is, and `package.path` is
-- blanked for the same one: every engine reach in this graph is a lazy
-- `pcall(require, ...)`, and a suite that answered differently depending on
-- which directory it was started in would be two suites. Here it also proves
-- something this file cares about directly -- with the engine unreachable,
-- `M.buildMon` fails, and the ladder has to answer nil rather than throw.
--
-- What is actually under test is the decision: given a map, a monster and a
-- screen, is this an ordinary encounter that should put a second monster on the
-- field, or is it one of the ones that must not? The build itself is the one
-- line that needs an engine, and it is stood in for.
--
-- Legal: every species and map id below is invented for this file, except the
-- names Config.WILD_STATIC_SPECIES already carries -- which are ids this mod
-- writes down anyway, and no data about them appears here.

package.path = ""

local ROOT = "."
do
  local invoked = arg and arg[0]
  local dir = invoked and invoked:match("^(.*)[/\\]tests[/\\][^/\\]+$")
  if dir and dir ~= "" then ROOT = dir end
end

local function slurp(path)
  local handle = io.open(path, "rb")
  if not handle then return nil end
  local body = handle:read("*a")
  handle:close()
  return body
end

local optionValue = nil          -- what mod.options:get answers

local stubMod = {
  id = "rby_mmo",
  path = ROOT,
  log = {
    info = function() end,
    warn = function() end,
    error = function() end,
  },
  options = { get = function(_, _) return optionValue end },
  content = nil,                 -- set per test when a registry is in play
}

local loadstr = loadstring or load
local cache = {}
local function need(name)
  if cache[name] ~= nil then return cache[name] end
  local path = ROOT .. "/src/" .. name .. ".lua"
  local body = slurp(path)
  if not body then error("missing " .. path, 0) end
  local chunk, err = loadstr(body, "@" .. name .. ".lua")
  if not chunk then error(tostring(err), 0) end
  cache[name] = chunk(need, stubMod)
  return cache[name]
end

local Config = need("Config")
local Wild = need("WildRoll")

-- ------------------------------------------------------------------
-- assertions
-- ------------------------------------------------------------------

local passed, failed = 0, 0

local function ok(condition, what)
  if condition then
    passed = passed + 1
  else
    failed = failed + 1
    io.stderr:write("FAIL " .. tostring(what) .. "\n")
  end
end

local function eq(actual, expected, what)
  if actual == expected then
    passed = passed + 1
  else
    failed = failed + 1
    io.stderr:write(string.format("FAIL %s: expected %s, got %s\n",
      tostring(what), tostring(expected), tostring(actual)))
  end
end

-- ------------------------------------------------------------------
-- fixtures
-- ------------------------------------------------------------------

-- A map with two terrains, spelled the ten-slot way Gen 1 spells them: repeats
-- are the distribution and there are no weights.
local ROUTE = {
  id = "ROUTE_TEST",
  grass = {
    { species = "ALPHA", level = 3 },
    { species = "ALPHA", level = 4 },
    { species = "BETA", level = 5 },
  },
  water = {
    { species = "GAMMA", level = 10, maxLevel = 12 },
  },
}

local function game(extra)
  local g = { data = { encounters = { ROUTE_TEST = ROUTE } } }
  for key, value in pairs(extra or {}) do g[key] = value end
  return g
end

local function wildState(fields)
  local state = { kind = "wild" }
  for key, value in pairs(fields or {}) do state[key] = value end
  return state
end

-- The engine's one line, stood in for: it records what it was asked to build
-- and hands back something shaped like a monster.
local built = {}
Wild.buildMon = function(_, species, level)
  built[#built + 1] = { species = species, level = level }
  return { species = species, level = level, stub = true }
end

local function reset()
  built = {}
  optionValue = nil
  stubMod.content = nil
end

-- ------------------------------------------------------------------
-- 1. the option
-- ------------------------------------------------------------------

do
  reset()
  eq(Config.WILD_EACH_DEFAULT, true, "one wild each is on out of the box")
  ok(Wild.isOn(), "and an unset option reads as the default")

  optionValue = false
  ok(not Wild.isOn(), "the row turns it off")
  eq(Wild.second(game(), "ROUTE_TEST", wildState(), { species = "ALPHA" }), nil,
     "and off means no second monster at all")

  optionValue = true
  ok(Wild.isOn(), "and back on again")
end

-- ------------------------------------------------------------------
-- 2. an ordinary grass encounter rolls a sibling
-- ------------------------------------------------------------------

do
  reset()
  local mon = Wild.second(game(), "ROUTE_TEST", wildState(), { species = "ALPHA" })
  ok(mon ~= nil, "an ordinary encounter answers a second monster")
  eq(#built, 1, "built exactly once")
  local drawn = built[1] and built[1].species
  ok(drawn == "ALPHA" or drawn == "BETA",
     "and drew it from the list the engine's own roll came out of: "
     .. tostring(drawn))

  -- The other terrain is a different list, and its levels are a range.
  reset()
  Wild.second(game(), "ROUTE_TEST", wildState(), { species = "GAMMA" })
  eq(built[1] and built[1].species, "GAMMA", "a water roll stays in the water")
  local level = built[1] and built[1].level
  ok(level and level >= 10 and level <= 12,
     "and lands inside the slot's level range: " .. tostring(level))
end

-- ------------------------------------------------------------------
-- 3. the scripted rule: a species no list on this map names
-- ------------------------------------------------------------------

do
  reset()
  eq(Wild.second(game(), "ROUTE_TEST", wildState(), { species = "DELTA" }), nil,
     "a species this map never rolls is a scripted encounter")
  eq(#built, 0, "so nothing was built")

  reset()
  eq(Wild.second(game(), "NOWHERE", wildState(), { species = "ALPHA" }), nil,
     "a map with no encounter record answers nil rather than guessing")

  reset()
  eq(Wild.second({}, "ROUTE_TEST", wildState(), { species = "ALPHA" }), nil,
     "and so does a game with no data at all")
end

-- ------------------------------------------------------------------
-- 4. the two nets: special battle flags, and the static list
-- ------------------------------------------------------------------

do
  reset()
  -- Safari / ghost / demo, and Gold's numbered battle types. Named through
  -- Config so this suite asserts the list the mod actually reads.
  for _, field in ipairs(Config.SOLO_REFUSED) do
    reset()
    eq(Wild.second(game(), "ROUTE_TEST", wildState({ [field] = true }),
       { species = "ALPHA" }), nil,
       "a " .. field .. " battle never doubles")
  end

  for battleType in pairs(Config.SOLO_REFUSED_BATTLE_TYPES) do
    reset()
    eq(Wild.second(game(), "ROUTE_TEST", wildState({ battleType = battleType }),
       { species = "ALPHA" }), nil,
       "battle type " .. tostring(battleType) .. " never doubles")
  end

  -- ...and the denylist, which has to win even when the map is lying.
  reset()
  local lake = { grass = { { species = "MEWTWO", level = 70 } } }
  local g = { data = { encounters = { CAVE = lake } } }
  eq(Wild.second(g, "CAVE", wildState(), { species = "MEWTWO" }), nil,
     "a static species is refused even by a map that lists it")
  eq(#built, 0, "and nothing was built for it")

  -- The spelling is loose on purpose: a registry id, the prose a fight is
  -- narrated under, and a table's own spelling are the same monster.
  reset()
  local g2 = { data = { encounters = { CAVE = { grass = {
    { species = "HO_OH", level = 70 }, { species = "ALPHA", level = 5 },
  } } } } }
  eq(Wild.second(g2, "CAVE", wildState(), { species = "HO OH" }), nil,
     "and the denylist matches across separators and case")
end

-- ------------------------------------------------------------------
-- 5. the registry accessor is preferred, when there is one
-- ------------------------------------------------------------------

do
  reset()
  local asked = nil
  stubMod.content = {
    encounters = {
      get = function(_, mapId)
        asked = mapId
        return { grass = { { species = "OMEGA", level = 9 } } }
      end,
    },
  }
  local mon = Wild.second(game(), "ROUTE_TEST", wildState(), { species = "OMEGA" })
  eq(asked, "ROUTE_TEST", "the registry is asked for the map by id")
  ok(mon ~= nil, "and what it answers is what gets rolled from")
  eq(built[1] and built[1].species, "OMEGA", "the registry's list, not game.data's")

  -- A registry that throws is a registry that answers nothing.
  reset()
  stubMod.content = { encounters = { get = function() error("boom", 0) end } }
  local fallback = Wild.second(game(), "ROUTE_TEST", wildState(),
    { species = "ALPHA" })
  ok(fallback ~= nil, "a throwing registry falls through to game.data")
end

-- ------------------------------------------------------------------
-- 6. every failure is nil, never a throw
-- ------------------------------------------------------------------

do
  reset()
  eq(Wild.second(game(), "ROUTE_TEST", wildState(), nil), nil,
     "no monster to match answers nil")
  eq(Wild.second(game(), nil, wildState(), { species = "ALPHA" }), nil,
     "no map answers nil")
  -- A missing screen is survivable rather than refused: there are no special
  -- flags to read off nothing, and the map lookup below it is the real rule.
  local safe, mon = pcall(Wild.second, game(), "ROUTE_TEST", nil,
    { species = "ALPHA" })
  ok(safe, "a missing screen does not throw")
  ok(mon ~= nil, "and still rolls, because the map is what decides")
  eq(Wild.second(game(), "ROUTE_TEST", wildState(), { species = 42 }), nil,
     "a species that is not a name answers nil")

  -- A table that points at itself must not send the walk spinning.
  reset()
  local loop = { grass = { { species = "ALPHA", level = 3 } } }
  loop.self = loop
  local g = { data = { encounters = { LOOP = loop } } }
  ok(Wild.second(g, "LOOP", wildState(), { species = "ALPHA" }) ~= nil,
     "a self-referential record is still read")

  -- The engine reach failing is the case this suite runs in by default.
  reset()
  Wild.buildMon = function() return nil end
  eq(Wild.second(game(), "ROUTE_TEST", wildState(), { species = "ALPHA" }), nil,
     "an engine that will not build a monster answers nil, not an error")
  Wild.buildMon = function(_, species, level)
    built[#built + 1] = { species = species, level = level }
    return { species = species, level = level, stub = true }
  end
end

-- ------------------------------------------------------------------
-- 7. extras: one per other player, never more than the field seats
-- ------------------------------------------------------------------

do
  reset()
  local list = Wild.extras(game(), "ROUTE_TEST", wildState(),
    { species = "ALPHA" }, 1)
  eq(#list, 1, "a two-player party asks for one more monster")

  reset()
  local capped = Wild.extras(game(), "ROUTE_TEST", wildState(),
    { species = "ALPHA" }, 99)
  eq(#capped, Config.COOP_SIDE - 1,
     "and a count larger than the field stops at the seats there are")

  reset()
  eq(#Wild.extras(game(), "ROUTE_TEST", wildState(), { species = "DELTA" }, 1), 0,
     "a scripted encounter asks for none and gets none")
  eq(#Wild.extras(game(), "ROUTE_TEST", wildState(), { species = "ALPHA" }, 0), 0,
     "and a party of one asks for none")
end

io.write(string.format("wild_roll: %d passed, %d failed\n", passed, failed))
if failed > 0 then os.exit(1) end
