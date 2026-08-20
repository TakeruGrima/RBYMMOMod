-- Which catch is the monster this client is already holding.
--
-- Run: luajit tests/coop_wild_field.lua               (from this folder's root)
--   or luajit mods/rby_mmo/tests/coop_wild_field.lua  (from the engine)
--
-- Standalone, and `package.path` is blanked for the reason tests/solo_battle.lua
-- blanks it: every engine reach in this graph is a lazy `pcall(require, ...)`,
-- and a suite that answered differently depending on the directory it was
-- started in would be two suites.
--
-- **A narrow suite on purpose.** The client half of one-wild-per-player is
-- mostly things that need an engine to mean anything -- packing a party for the
-- upload goes through the link Protocol, the grant writes into a save, the
-- field description is drawn -- and those belong to tests/coop_mediated.lua and
-- the e2e drivers, which run against a checkout. What is left is one decision
-- that is pure, and it is the one that can lose a monster:
--
--   `CoopBattle.sheetNamesMon` -- is the engine monster this screen has held
--   since the divert the one *this* catch is about?
--
-- The host is standing in front of a real encounter, so one of the monsters on
-- the field is an engine `Mon` with the DVs their own game rolled, and the
-- others were never in this process. There is exactly one of it. Handing it to
-- a second catch would grant the same creature twice and silently drop the one
-- that was actually caught, which is the arithmetic this file exists to pin.
--
-- Legal: every species below is invented for this file.

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

local stubMod = {
  id = "rby_mmo",
  path = ROOT,
  log = { info = function() end, warn = function() end, error = function() end },
  options = { get = function() return nil end },
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

local CoopBattle = need("CoopBattle")

local passed, failed = 0, 0

local function ok(condition, what)
  if condition then
    passed = passed + 1
  else
    failed = failed + 1
    io.stderr:write("FAIL " .. tostring(what) .. "\n")
  end
end

local function mon(o)
  o = o or {}
  return {
    species = o.species or "ALPHA",
    level = o.level or 7,
    hp = o.hp or 40,
    moves = { { id = "THUMP", pp = 20 } },
  }
end

-- ------------------------------------------------------------------
-- the same monster, spelled by two layers
-- ------------------------------------------------------------------

do
  local held = mon({ species = "NIDORAN_M", level = 9 })

  ok(CoopBattle.sheetNamesMon({ species = "NIDORAN M", level = 9 }, held),
     "the narration token and the registry id are the same monster")
  ok(CoopBattle.sheetNamesMon({ speciesId = "NIDORAN_M", level = 9 }, held),
     "and so is the id the referee states outright (PROTOCOL 22)")
  ok(CoopBattle.sheetNamesMon({ species = "nidoran-m", level = 9 }, held),
     "case and separators are the only differences either has ever had")
end

-- ------------------------------------------------------------------
-- ...and the ones that are not
-- ------------------------------------------------------------------

do
  local held = mon({ species = "NIDORAN_M", level = 9 })

  ok(not CoopBattle.sheetNamesMon({ species = "NIDORAN F", level = 9 }, held),
     "a different species is not the monster this screen is holding")
  ok(not CoopBattle.sheetNamesMon({ species = "NIDORAN M", level = 8 }, held),
     "and neither is the same species at another level -- two of a kind in one "
     .. "encounter is exactly the case this has to get right")
  ok(not CoopBattle.sheetNamesMon(nil, held), "a missing sheet names nothing")
  ok(not CoopBattle.sheetNamesMon({ species = "NIDORAN M" }, nil),
     "and neither does a missing monster")
  ok(not CoopBattle.sheetNamesMon({ level = 9 }, held),
     "a sheet with no name at all names nothing either")
end

do
  -- A sheet with no level still matches on the name: an older referee states
  -- none, and refusing over an absent field would rebuild a monster this client
  -- is already holding a better copy of.
  local held = mon({ species = "ALPHA", level = 5 })
  ok(CoopBattle.sheetNamesMon({ species = "ALPHA" }, held),
     "a sheet with no level matches on the name alone")
end

io.write(string.format("coop_wild_field: %d passed, %d failed\n", passed, failed))
if failed > 0 then os.exit(1) end
