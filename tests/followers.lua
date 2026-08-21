-- src/Followers.lua: the POKéMON walking behind every remote trainer.
--
-- Run: luajit tests/followers.lua                 (from this folder's root)
--   or luajit mods/rby_mmo/tests/followers.lua    (from the engine)
--
-- Standalone, for the reason tests/solo_battle.lua is: the claim this feature
-- makes is about arithmetic and seams, not about the engine. A follower is a
-- runtime NPC one cell behind an avatar, wearing a sheet Wilds of Kanto handed
-- over -- so the suite loads the shipped files through the same `need`-shaped
-- resolver main.lua uses, stubs the facade, stubs Wilds, and drives the whole
-- thing with no love, no display and no engine.
--
-- `package.path` is pinned empty for the same reason solo_battle pins it: the
-- one engine reach in this graph is `require("src.render.SpriteRenderer")`, and
-- a suite that resolved it from the engine checkout and not from here would be
-- two different suites wearing one name. Blanked, it fails identically in both
-- places -- which is also how the "no renderer, feature dark" contract below
-- gets tested at all.
--
-- Legal: every species id below is invented. No ROM-derived name appears here.

package.path = ""

-- ------------------------------------------------------------------
-- where we are
-- ------------------------------------------------------------------

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

-- ------------------------------------------------------------------
-- the mod facade, and the module graph resolved through it
-- ------------------------------------------------------------------

local warns = {}

-- What the stub Wilds of Kanto answers. Reassigned per section: `nil` is the
-- mod not being installed at all, which is the ordinary case for most players
-- and the one the feature has to cost nothing in.
local wilds = nil

-- Every NPC the stub world has handed out, by id, so assertions can look at
-- the live table the way Avatars does through `handle.npc`.
local spawnedNpcs = {}
local removed = {}
local nextNpcId = 0

local stubMod = {
  id = "rby_mmo",
  path = ROOT,
  log = {
    info = function() end,
    warn = function(_, fmt, ...)
      local ok, line = pcall(string.format, fmt, ...)
      warns[#warns + 1] = ok and line or tostring(fmt)
    end,
    error = function() end,
  },
  options = { get = function() return true end },
  -- The cross-mod seam. CLAUDE.md names `mod.find` + `mod.exports` as the only
  -- sanctioned way one mod calls another, so that is the only door this suite
  -- opens -- never a require of Wilds' own files.
  find = function(id)
    if id == "overworld_wild_spawns" and wilds then return wilds end
    return nil
  end,
  world = {
    spawnNpc = function(_, mapId, objDef)
      nextNpcId = nextNpcId + 1
      local id = "npc_" .. nextNpcId
      spawnedNpcs[id] = {
        id = id,
        mapId = mapId,
        objDef = objDef,
        cellX = objDef and objDef.x,
        cellY = objDef and objDef.y,
        px = (objDef and objDef.x or 0) * 16,
        py = (objDef and objDef.y or 0) * 16,
        facing = "down",
        moving = false,
        progress = 0,
      }
      return id
    end,
    removeNpc = function(_, id)
      removed[#removed + 1] = id
      spawnedNpcs[id] = nil
      return true
    end,
    npc = function(_, _, key)
      for id, npc in pairs(spawnedNpcs) do
        if id == key or (npc.objDef and npc.objDef.name == key) then
          return { npc = npc }
        end
      end
      return nil
    end,
  },
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

-- ------------------------------------------------------------------
-- assertions
-- ------------------------------------------------------------------

-- how far behind a follower may legitimately be before the module
-- rebuilds it rather than walking it back (Config.RESYNC_DISTANCE)
local Config_RESYNC_MAX = 6

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

-- A section that cannot even load its subject should say so once and let the
-- rest of the suite report, rather than taking the whole file down with it.
local function section(name, body)
  local run, err = pcall(body)
  if not run then
    failed = failed + 1
    io.stderr:write(string.format("FAIL %s: %s\n", name, tostring(err)))
  end
end

-- ------------------------------------------------------------------
-- a stub Wilds of Kanto
-- ------------------------------------------------------------------
--
-- Only the two exports this feature reads, shaped the way 2.1.8 shapes them:
-- `getActiveFollowerMon` answers with the mon it is drawing behind the local
-- player, and `resolveFollowerSprite` answers with a draw-ready def carrying
-- True Size geometry. The def's `image` is a sentinel string -- nothing in the
-- mod may inspect it, it only ever travels to the renderer.

local function fakeWilds(mon)
  local calls = { resolve = {} }
  return {
    exports = {
      getActiveFollowerMon = function() return mon end,
      resolveFollowerSprite = function(opts)
        calls.resolve[#calls.resolve + 1] = opts
        return {
          id = "SPRITE_WILDS_FOLLOWER_MON",
          image = "sheet:" .. tostring(opts and opts.species),
          frames = 6,
          walker = true,
          trueColor = true,
          frameWidth = 24,
          frameHeight = 24,
          anchorX = 12,
          anchorY = 22,
        }
      end,
    },
    calls = calls,
  }
end

-- ------------------------------------------------------------------
-- 1. Wire.species -- shape, not registry
-- ------------------------------------------------------------------
--
-- Wire runs on the hub as well as in the client, and a hub has no content
-- registry to check a species against -- src/Hub.lua and server/lib/relay.js
-- both re-derive presence from these same bytes. So `mon` is validated the way
-- `spriteId` is (`Wire.lua:390`): a shape and a length cap, nothing more. The
-- registry question is the client's, at the moment it asks Wilds for a sheet,
-- and an id nobody has art for simply draws no follower.

section("Wire.species", function()
  local Wire = need("Wire")

  ok(type(Wire.species) == "function", "Wire exposes a species sanitiser")
  if type(Wire.species) ~= "function" then return end

  eq(Wire.species("BULBASAUR_X"), "BULBASAUR_X", "an id-shaped species passes")
  eq(Wire.species("MON9"), "MON9", "digits are id characters")
  eq(Wire.species(""), nil, "the empty string is not a species")
  eq(Wire.species("A B"), nil, "a space is not an id character")
  eq(Wire.species("MON-X"), nil, "nor is a dash, exactly as spriteId refuses it")
  eq(Wire.species(42), nil, "a number is not a species")
  eq(Wire.species(nil), nil, "and absent stays absent")
  eq(Wire.species(string.rep("A", 41)), nil, "over the 40-character cap it is refused")
end)

-- ------------------------------------------------------------------
-- 2. Wire.presence carries the follower
-- ------------------------------------------------------------------

section("Wire.presence", function()
  local Wire = need("Wire")

  local base = {
    id = "aaaa", name = "TRAINER", map = "MAP_1", x = 3, y = 4, facing = "up",
  }

  local function presenceWith(extra)
    local raw = {}
    for k, v in pairs(base) do raw[k] = v end
    for k, v in pairs(extra or {}) do raw[k] = v end
    return Wire.presence(raw)
  end

  local carried = presenceWith({ mon = "MONSTER_A", shiny = true })
  ok(carried ~= nil, "a presence with a follower still sanitises")
  if carried then
    eq(carried.mon, "MONSTER_A", "the follower species rides along")
    eq(carried.shiny, true, "and so does its shiny flag")
  end

  local plain = presenceWith({})
  ok(plain ~= nil, "a presence with no follower still sanitises")
  if plain then
    eq(plain.mon, nil, "no follower means no species on the wire")
    eq(plain.shiny, false, "and shiny is a boolean, never nil, like busy and party")
  end

  local junk = presenceWith({ mon = "not a species", shiny = true })
  if junk then
    eq(junk.mon, nil, "a malformed species is dropped, not repaired")
  end

  -- Strict, for the reason already written above `fast` in Wire.lua: both hubs
  -- re-derive this from the same bytes, and a 0 or an empty string would be
  -- true in Lua and false in JS. Only a literal true is shiny.
  for _, truthy in ipairs({ 0, 1, "", "yes" }) do
    local loose = presenceWith({ mon = "MONSTER_A", shiny = truthy })
    if loose then
      eq(loose.shiny, false,
         "shiny is strict: " .. tostring(truthy) .. " is not true")
    end
  end
end)

-- ------------------------------------------------------------------
-- 3. Without Wilds of Kanto, the feature costs nothing
-- ------------------------------------------------------------------

section("no wilds", function()
  wilds = nil
  local Followers = need("Followers")
  local f = Followers.new()

  eq(f:monFor({ id = "a", mon = "MONSTER_A" }), nil,
     "with Wilds absent there is no sheet to draw, so no follower is claimed")

  local before = #warns
  f:sync({ { id = "a", map = "MAP_1", x = 1, y = 1, mon = "MONSTER_A" } }, "MAP_1")
  f:sync({ { id = "a", map = "MAP_1", x = 1, y = 1, mon = "MONSTER_A" } }, "MAP_1")
  f:sync({ { id = "a", map = "MAP_1", x = 1, y = 1, mon = "MONSTER_A" } }, "MAP_1")

  eq(next(f.spawned), nil, "nothing is spawned")
  ok(#warns - before <= 1,
     "and the missing dependency is named once, not once per tick")
end)

-- ------------------------------------------------------------------
-- 4. With Wilds, a follower is spawned and wears its sheet
-- ------------------------------------------------------------------

section("spawn", function()
  wilds = fakeWilds({ species = "MONSTER_A", shiny = false })
  spawnedNpcs, removed, nextNpcId = {}, {}, 0

  local Followers = need("Followers")
  local f = Followers.new()

  -- The one engine reach, replaced. With package.path blank the real
  -- SpriteRenderer is unreachable here, which is exactly why the module has to
  -- resolve it through a seam rather than a bare require at the top.
  local built = {}
  Followers.newSprite = function(def, npcId)
    built[#built + 1] = { def = def, npcId = npcId }
    return { def = def }
  end

  f:sync({ { id = "a", map = "MAP_1", x = 5, y = 7, facing = "down",
             mon = "MONSTER_A", shiny = false } }, "MAP_1")

  local av = f.spawned["a"]
  ok(av ~= nil, "a player carrying a follower gets one")
  if not av then return end

  local npc = spawnedNpcs[av.npcId]
  ok(npc ~= nil, "and it is a real runtime NPC")
  if not npc then return end

  eq(npc.passable, true,
     "passable, the escape hatch avatars already use so nobody blocks a door")

  eq(#built, 1, "its sheet is built once, at spawn")
  if built[1] then
    eq(built[1].def.image, "sheet:MONSTER_A", "from the sheet Wilds handed over")
    eq(built[1].def.frameWidth, 24,
       "carrying True Size geometry, or a big species draws at a small one's size")
    eq(built[1].def.anchorY, 22, "anchor included, for the same reason")
  end

  local asked = wilds.calls.resolve[1]
  ok(asked ~= nil, "Wilds was asked for the sheet")
  if asked then
    eq(asked.species, "MONSTER_A", "for the species the wire named")
    eq(asked.surface, "land", "on land -- surfing is a known gap, not a silent one")
  end

  -- Drawn under its trainer, not over: two entities on neighbouring cells sort
  -- by py, and a follower that won the tie would occlude the player it belongs
  -- to every time it stood north of them.
  ok((npc.py % 1) ~= 0,
     "its py carries a sub-pixel bias so the sort is deterministic")
end)

-- ------------------------------------------------------------------
-- 5. A follower swap is a respawn, because the sheet is baked at creation
-- ------------------------------------------------------------------

section("swap", function()
  wilds = fakeWilds({ species = "MONSTER_A", shiny = false })
  spawnedNpcs, removed, nextNpcId = {}, {}, 0

  local Followers = need("Followers")
  local f = Followers.new()
  Followers.newSprite = function(def) return { def = def } end

  local roster = { { id = "a", map = "MAP_1", x = 5, y = 7, mon = "MONSTER_A" } }
  f:sync(roster, "MAP_1")
  local first = f.spawned["a"] and f.spawned["a"].npcId

  f:sync(roster, "MAP_1")
  eq(f.spawned["a"] and f.spawned["a"].npcId, first,
     "an unchanged follower is left alone -- no respawn churn per tick")

  roster[1].mon = "MONSTER_B"
  f:sync(roster, "MAP_1")
  local second = f.spawned["a"] and f.spawned["a"].npcId
  ok(second ~= nil and second ~= first,
     "a new species is a new NPC: NPC.new bakes the sheet at creation")
  eq(#removed, 1, "and the old one is taken off the map, not leaked")

  roster[1].shiny = true
  f:sync(roster, "MAP_1")
  ok(f.spawned["a"] and f.spawned["a"].npcId ~= second,
     "shiny is a different sheet, so it respawns too")
end)

-- ------------------------------------------------------------------
-- 6. The follower walks into the cell its trainer has just left
-- ------------------------------------------------------------------
--
-- The five fields Avatars writes are the whole animation contract: NPC:update
-- interpolates px/py over `stepFrames` given facing, targetX/targetY, moving
-- and progress. Placing the follower without them leaves it sliding between
-- tiles without a walk cycle, which is the bug Avatars.lua documents.

section("trail", function()
  wilds = fakeWilds({ species = "MONSTER_A" })
  spawnedNpcs, removed, nextNpcId = {}, {}, 0

  local Followers = need("Followers")
  local f = Followers.new()
  Followers.newSprite = function(def) return { def = def } end

  f:sync({ { id = "a", map = "MAP_1", x = 5, y = 7, facing = "down",
             mon = "MONSTER_A" } }, "MAP_1")
  local av = f.spawned["a"]
  ok(av ~= nil, "a follower to walk")
  if not av then return end

  -- The trainer steps south, 7 -> 8. The follower's target is the cell they
  -- vacated, never the one they are standing in.
  f:advance("a", { x = 5, y = 8, facing = "down" })

  local npc = spawnedNpcs[av.npcId]
  if not npc then return end
  eq(npc.targetX, 5, "the follower aims at the vacated column")
  eq(npc.targetY, 7, "and the vacated row -- one cell behind, never on top")
  eq(npc.moving, true, "with a real step started, not a teleport")
  eq(npc.facing, "down", "facing the way it is walking")

  -- A sprinting or cycling trainer costs 8 frames a tile rather than 16, and
  -- NPC:update reads `stepFrames or 16` fresh every frame. A follower left at
  -- the default would shed ground until it had to be respawned.
  f:advance("a", { x = 5, y = 9, facing = "down", fast = true })
  eq(npc.stepFrames, 8, "a fast trainer's follower runs too")

  f:advance("a", { x = 5, y = 10, facing = "down", fast = false })
  eq(npc.stepFrames, nil, "and back to the engine's own default when they walk")
end)

-- ------------------------------------------------------------------
-- 7. Leaving takes the follower with it
-- ------------------------------------------------------------------

section("despawn", function()
  wilds = fakeWilds({ species = "MONSTER_A" })
  spawnedNpcs, removed, nextNpcId = {}, {}, 0

  local Followers = need("Followers")
  local f = Followers.new()
  Followers.newSprite = function(def) return { def = def } end

  f:sync({ { id = "a", map = "MAP_1", x = 1, y = 1, mon = "MONSTER_A" },
           { id = "b", map = "MAP_1", x = 2, y = 2, mon = "MONSTER_A" } }, "MAP_1")

  -- A player who walks into a battle or a menu keeps their roster row but
  -- loses their cell, so their avatar goes -- and a follower with nobody to
  -- follow has to go with it.
  f:sync({ { id = "a", map = "MAP_1", x = 1, y = 1, mon = "MONSTER_A" } }, "MAP_1")
  eq(f.spawned["b"], nil, "a player who left the world loses their follower")

  -- Dropping the follower without leaving is the same removal.
  f:sync({ { id = "a", map = "MAP_1", x = 1, y = 1 } }, "MAP_1")
  eq(f.spawned["a"], nil, "putting the POKéMON away removes it")

  f:sync({ { id = "a", map = "MAP_1", x = 1, y = 1, mon = "MONSTER_A" } }, "MAP_1")
  f:clear()
  eq(next(f.spawned), nil, "and a map change clears the lot")
  eq(next(spawnedNpcs), nil, "leaving no runtime NPC behind on the engine's side")
end)

-- ------------------------------------------------------------------
-- 8. No renderer, no crash
-- ------------------------------------------------------------------
--
-- The loader's rule: a mod callback never raises. An unreachable
-- SpriteRenderer is a feature that stays dark and says why once.

section("dark", function()
  wilds = fakeWilds({ species = "MONSTER_A" })
  spawnedNpcs, removed, nextNpcId = {}, {}, 0

  local Followers = need("Followers")
  local f = Followers.new()
  Followers.newSprite = function() return nil end

  local before = #warns
  local ran = pcall(function()
    f:sync({ { id = "a", map = "MAP_1", x = 1, y = 1, mon = "MONSTER_A" } }, "MAP_1")
    f:sync({ { id = "a", map = "MAP_1", x = 1, y = 1, mon = "MONSTER_A" } }, "MAP_1")
  end)

  ok(ran, "a missing renderer never raises out of a mod callback")
  eq(next(f.spawned), nil, "nothing half-spawned is left holding an NPC")
  ok(#warns - before <= 1, "and it says why once, not every tick")
end)

-- ------------------------------------------------------------------
-- 9. A follower walks the gap; it never jumps it
-- ------------------------------------------------------------------
--
-- The failure this pins was reported from a live game as "the POK\u00e9MON
-- teleports". Presence arrives at 8Hz and a step takes 16 frames, so a
-- trainer walking at an ordinary pace is *always* further along than their
-- follower has finished walking to -- being behind is the normal state, not
-- an error state.
--
-- What turns that into a teleport is writing the goal straight into
-- targetX/targetY. NPC:update interpolates px/py from the current cell to
-- the target over stepFrames regardless of how far apart they are, so a goal
-- four tiles away is four tiles crossed in one step. The target has to be
-- one tile toward the goal, which is the same rule Avatars.stepToward
-- already applies for the trainer itself.

section("no teleport", function()
  wilds = fakeWilds({ species = "MONSTER_A" })
  spawnedNpcs, removed, nextNpcId = {}, {}, 0

  local Followers = need("Followers")
  local f = Followers.new()
  Followers.newSprite = function(def) return { def = def } end

  f:sync({ { id = "a", map = "MAP_1", x = 5, y = 7, facing = "down",
             mon = "MONSTER_A" } }, "MAP_1")
  local av = f.spawned["a"]
  ok(av ~= nil, "a follower to walk")
  if not av then return end
  local jumps, steps, rebuilds = 0, 0, 0
  local wasMoving = false
  local y = 7

  -- The NPC is re-read every tick rather than held: past RESYNC_DISTANCE the
  -- module rebuilds the follower behind its trainer instead of marching it
  -- back, and that is a *new* NPC. Holding the old table would be testing a
  -- follower nobody is updating any more.
  local function live()
    local rec = f.spawned["a"]
    return rec and spawnedNpcs[rec.npcId] or nil
  end

  -- The trainer takes a tile per tick and the engine lands the follower's
  -- step every third one. That 3:1 is not a contrived ratio: presence
  -- arrives every 0.125s while a walking step costs 16 frames, so a trainer
  -- who is running -- 8 frames a tile -- outpaces a follower that has not
  -- picked the pace up yet, and being behind is the ordinary condition this
  -- has to survive.
  for tick = 1, 15 do
    y = y + 1
    local before = f.spawned["a"] and f.spawned["a"].npcId
    -- the same record shape sync hands it, map included: a rebuild needs a
    -- map to spawn onto
    f:advance("a", { id = "a", map = "MAP_1", x = 5, y = y, facing = "down",
                     mon = "MONSTER_A" })
    local npc = live()
    if not npc then break end
    if f.spawned["a"].npcId ~= before then
      rebuilds = rebuilds + 1
      wasMoving = false
    end

    if npc.moving and not wasMoving then
      steps = steps + 1
      local dx = math.abs((npc.targetX or npc.cellX) - npc.cellX)
      local dy = math.abs((npc.targetY or npc.cellY) - npc.cellY)
      if dx + dy > 1 then jumps = jumps + 1 end
    end
    wasMoving = npc.moving

    if npc.moving and tick % 3 == 0 then
      npc.cellX, npc.cellY = npc.targetX, npc.targetY
      npc.px, npc.py = npc.cellX * 16, npc.cellY * 16
      npc.moving = false
      wasMoving = false
    end
  end

  ok(steps > 0, "the follower actually took steps")
  eq(jumps, 0,
     "every step is one tile: a multi-tile target is what reads as a teleport")

  -- And it is still trailing rather than stranded: a follower that answered
  -- the bug by never moving would pass the check above and be just as wrong.
  local npc = live()
  ok(npc ~= nil and math.abs(npc.cellY - y) <= Config_RESYNC_MAX,
     "and it is still within reach of its trainer, not left behind")

  -- Falling behind is walked back where it can be and rebuilt where it
  -- cannot, but a rebuild every step would be the teleport wearing a
  -- different hat.
  ok(rebuilds <= 2,
     "and it is rebuilt rarely, not once a step: got " .. tostring(rebuilds))
end)

-- ------------------------------------------------------------------

io.write(string.format("followers: %d passed, %d failed\n", passed, failed))
os.exit(failed == 0 and 0 or 1)
