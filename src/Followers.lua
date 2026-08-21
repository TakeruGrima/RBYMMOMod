-- The POKéMON walking behind every remote trainer.
--
-- One runtime NPC per remote player who has a follower out, spawned one cell
-- behind their avatar and walked into the cell that avatar has just left.
-- Avatars.lua explains why a remote character is an NPC at all and why the
-- five movement fields are written straight onto it rather than through
-- Handle:scriptMove; all of that applies here unchanged and is not repeated.
--
-- What is new is the sheet. A follower's species is chosen at runtime, and
-- **the mod API cannot introduce a sprite after load**: content registries
-- freeze after the boot merge (`Registry:append` raises "content is frozen
-- after load"), `NPC.new` resolves `data.sprites[objDef.sprite]` and asserts
-- on a miss so a def table is not accepted, `Handle` has no sprite setter,
-- and no hook draws into the overworld's depth order. The one path left is
-- an entity-local rebind -- replace the renderer on this one NPC, leaving
-- the registry untouched -- which is what `engine_internals` buys and what
-- Wilds of Kanto itself does for the local player's follower.
--
-- **The art is never ours.** Wilds of Kanto ships the follower sheets and is
-- asked for one through the sanctioned cross-mod seam, `mod.find` +
-- `mod.exports`. Without it installed this feature is not degraded, it is
-- absent: nothing is emitted, nothing is spawned, and the missing dependency
-- is named once rather than once per tick. That is also why no ROM-derived
-- byte can enter this repository through this feature -- the pixels stay in
-- the player's own copy of somebody else's mod.
--
-- Every failure answers nil and nil means "the avatar walks alone", which is
-- the behaviour that already shipped. A mod callback never raises.

local need, mod = ...
local Config = need("Config")
local Gen = need("Gen")
-- stepToward: one tile at a time, one axis first, so a follower that has
-- fallen behind walks the gap instead of crossing it in a single step.
local Avatars = need("Avatars")

local M = {}
M.__index = M

-- The engine reach, behind a named seam rather than a require at the top of
-- the file.
--
-- Two reasons it is a function and not an upvalue. The suite pins
-- `package.path = ""` for the reason tests/solo_battle.lua does, so the real
-- SpriteRenderer is unreachable from it by construction -- a bare top-level
-- require would make this module untestable outside an engine checkout, and
-- the whole spawn/swap/trail contract is what there is to test. And a build
-- where the module moved has to answer nil rather than raise at load: this is
-- the single line in the mod that reaches somewhere the mod API does not
-- promise, so it is the single line most likely to be wrong on some future
-- engine.
--
-- Memoised on the module rather than re-required per spawn, because this runs
-- once per remote player per map change.
local rendererProbed, renderer = false, nil
function M.newSprite(def, npcId)
  if not rendererProbed then
    rendererProbed = true
    local ok, mod_ = pcall(require, "src.render.SpriteRenderer")
    renderer = ok and type(mod_) == "table" and mod_ or nil
  end
  if not renderer or type(renderer.new) ~= "function" then return nil end
  local ok, sprite = pcall(renderer.new, def, npcId)
  if not ok then return nil end
  return sprite
end

local DELTA = {
  up    = { 0, -1 },
  down  = { 0, 1 },
  left  = { -1, 0 },
  right = { 1, 0 },
}

function M.new()
  return setmetatable({
    spawned = {},        -- playerId -> { npcId, name, id, x, y, mon, shiny, npc }
    mapId = nil,
    wildsWarned = false,
    rendererWarned = false,
  }, M)
end

-- Wilds of Kanto, or nil, having said so once.
--
-- The peer is optional at runtime *always*, and the check is on the function
-- rather than on the mod: a copy one version older is installed, loaded, and
-- missing the call this needs. `dependencies` would have turned that into a
-- mod that does not load; `optional_dependencies` plus this is the pair that
-- degrades instead.
function M:wilds()
  local ok, peer = pcall(mod.find, Config.WILDS_MOD_ID)
  local api = ok and type(peer) == "table" and peer.exports or nil
  if type(api) ~= "table"
     or type(api.resolveFollowerSprite) ~= "function" then
    if not self.wildsWarned then
      self.wildsWarned = true
      mod.log:warn("no follower art: %s is not installed or is too old, so "
        .. "other players' POKéMON are not drawn. Install Wilds of Kanto "
        .. "%s or later, or turn %s off to stop asking.",
        tostring(Config.WILDS_MOD_ID), tostring(Config.WILDS_MIN_VERSION),
        tostring(Config.FOLLOWERS_OPTION))
    end
    return nil
  end
  return api
end

-- The draw-ready sheet for the POKéMON this player is showing, or nil.
--
-- The species arrived over the wire shape-checked but not registry-checked --
-- Wire runs on the hub too, and a hub has no registry -- so this is where an
-- id nobody has art for is settled: Wilds answers with no sheet and the
-- avatar walks alone, which is the same outcome as never having sent it.
--
-- `surface` is "land" unconditionally in v1. Presence carries no surf state,
-- so a trainer crossing water has their POKéMON walk on it. That is a known
-- gap rather than a silent one: closing it is a third presence field and a
-- second protocol bump, and it is written down in the plan.
function M:monFor(player)
  if type(player) ~= "table" or type(player.mon) ~= "string" then return nil end
  local api = self:wilds()
  if not api then return nil end
  local ok, def = pcall(api.resolveFollowerSprite, {
    species = player.mon,
    shiny = player.shiny == true,
    surface = "land",
    role = "primary",
    game = mod.game,
  })
  if not ok or type(def) ~= "table" then return nil end
  return def
end

-- The species the local player is showing, for their own presence.
--
-- Silent where monFor warns, and the asymmetry is deliberate: a player with
-- no Wilds of Kanto installed is not failing at anything -- they simply have
-- no follower to announce -- while a player who *is* being sent somebody
-- else's POKéMON and cannot draw it has something worth being told once.
--
-- The return shape of getActiveFollowerMon is a private-ish contract on a
-- third-party mod, so every field read is a guess with a fallback and the
-- cost of guessing wrong is no follower rather than an error.
function M:localMon()
  local ok, peer = pcall(mod.find, Config.WILDS_MOD_ID)
  local api = ok and type(peer) == "table" and peer.exports or nil
  if type(api) ~= "table"
     or type(api.getActiveFollowerMon) ~= "function" then
    return nil, false
  end
  local got, rec = pcall(api.getActiveFollowerMon, mod.game)
  if not got or type(rec) ~= "table" then return nil, false end
  local species = rec.species or rec.speciesId or rec.id
  if type(species) ~= "string" then return nil, false end
  return species, rec.shiny == true
end

function M:enabled()
  if not (mod.options and type(mod.options.get) == "function") then return true end
  local ok, value = pcall(mod.options.get, mod.options, Config.FOLLOWERS_OPTION)
  if not ok then return true end
  return value ~= false
end

-- Gen 2 WorldAPI:npc matches def.name / def.index only; same ladder as
-- Avatars:handle, and same reason.
function M:handle(av)
  if not (av and self.mapId and mod.world) then return nil end
  if av.name then
    local handle = mod.world:npc(self.mapId, av.name)
    if handle then return handle end
  end
  if av.npcId then
    local handle = mod.world:npc(self.mapId, av.npcId)
    if handle then return handle end
    local index = tostring(av.npcId):match("_obj_(%d+)$")
    if index then
      handle = mod.world:npc(self.mapId, tonumber(index))
      if handle then return handle end
    end
  end
  return nil
end

-- The cell one step behind a trainer, which is where a follower stands.
local function behind(player)
  local delta = DELTA[player.facing or "down"] or DELTA.down
  return player.x - delta[1], player.y - delta[2]
end

local function dirFrom(fromX, fromY, toX, toY)
  if fromX == nil or fromY == nil then return nil end
  local dx, dy = toX - fromX, toY - fromY
  if dx == 0 and dy == 0 then return nil end
  if math.abs(dx) >= math.abs(dy) then
    return dx > 0 and "right" or "left"
  end
  return dy > 0 and "down" or "up"
end

-- Passable, and beneath its own trainer.
--
-- `passable` for the reason Avatars sets it: Collision.occupied skips any
-- entity carrying it, and a follower standing in a doorway would otherwise
-- be a wall no player could see a reason for.
--
-- Depth is the half that is specific here. The overworld sorts entities on
-- py and the sort is unstable, so a follower and its trainer standing on
-- neighbouring cells trade places from frame to frame. An avatar already
-- lifts itself by AVATAR_DEPTH_NUDGE to lose every tie against the local
-- player; a follower has to lose against its *own* avatar as well, so it
-- takes twice the lift. Without it a POKéMON standing north of its trainer
-- occludes them, which is the one artefact this whole entity-local rebind
-- exists to avoid.
--
-- The write is unconditional, and the method wrapping is not: the engine
-- recomputes py mid-step and only while `moving`, so a value written from
-- the pump alone is overwritten before the frame is drawn. Wrapping needs
-- both class methods in hand -- a headless NPC has neither -- while
-- `passable` and a one-shot bias are correct on their own and are what a
-- standing follower needs.
local function biased(self, ...)
  local py = self.py
  if py and py % 1 == 0 then
    self.py = py - Config.FOLLOWER_DEPTH_NUDGE
  end
  return ...
end

function M.decorate(npc)
  if type(npc) ~= "table" then return end

  npc.passable = true
  if npc.py and npc.py % 1 == 0 then
    npc.py = npc.py - Config.FOLLOWER_DEPTH_NUDGE
  end

  if npc.mmoFollower then return end
  local baseUpdate, basePose = npc.update, npc.pose
  if type(baseUpdate) ~= "function" or type(basePose) ~= "function" then
    return
  end

  npc.mmoPrevUpdate = rawget(npc, "update")
  npc.mmoPrevPose = rawget(npc, "pose")
  npc.mmoFollower = true

  rawset(npc, "update", function(self, ...)
    return biased(self, baseUpdate(self, ...))
  end)

  rawset(npc, "pose", function(self, ...)
    local sprite, px, py, facing, phase, flip, hop = basePose(self, ...)
    if py then py = py + Config.FOLLOWER_DEPTH_NUDGE end
    return sprite, px, py, facing, phase, flip, hop
  end)
end

-- Leaves the table indistinguishable from a vanilla one: the engine pools
-- NPC tables, and a leftover `passable` would be born again on some later
-- ordinary NPC and quietly let the player walk through it.
function M.undecorate(npc)
  if type(npc) ~= "table" then return end
  npc.passable = nil
  if not npc.mmoFollower then return end
  local prevUpdate, prevPose = npc.mmoPrevUpdate, npc.mmoPrevPose
  npc.mmoFollower = nil
  npc.mmoPrevUpdate = nil
  npc.mmoPrevPose = nil
  rawset(npc, "update", prevUpdate)
  rawset(npc, "pose", prevPose)
end

-- Hands the live NPC the sheet Wilds resolved.
--
-- `spriteDef` as well as `sprite` because Gen 2 reads the def back off the
-- entity rather than off the renderer; writing only one of the two leaves a
-- follower correct on Red and a placeholder on Gold.
function M:dress(av, npc, def)
  local sprite = M.newSprite(def, av.npcId)
  if not sprite then
    if not self.rendererWarned then
      self.rendererWarned = true
      mod.log:warn("cannot build a follower sheet on this build, so other "
        .. "players' POKéMON stay hidden; everything else is unaffected. "
        .. "Report the engine version -- src.render.SpriteRenderer is what "
        .. "moved.")
    end
    return false
  end
  npc.sprite = sprite
  npc.spriteDef = def
  M.decorate(npc)
  av.dressed = true
  return true
end

function M:spawn(player)
  if not (player.map and player.x and player.y) then return nil end

  local def = self:monFor(player)
  if not def then return nil end

  local cellX, cellY = behind(player)
  -- Spawned wearing the sprite id Wilds registers at load, so the frame
  -- between spawnNpc and the rebind shows a POKéMON rather than a trainer.
  local objDef = Gen.spawnObjDef({
    id = "pet_" .. tostring(player.id),
    x = cellX, y = cellY, facing = player.facing,
  }, Config.FOLLOWER_SPRITE, mod.game)

  local npcId = mod.world:spawnNpc(player.map, objDef)
  if not npcId then return nil end

  local av = {
    npcId = npcId,
    name = objDef.name,
    id = player.id,
    x = player.x,
    y = player.y,
    facing = player.facing,
    -- Its own cell, so it stands where it was put until the trainer actually
    -- moves. Left nil, the first goal would fall back to the trainer's
    -- current cell and the POKéMON would take one step onto its own trainer
    -- before the trail had anything in it.
    goalX = cellX,
    goalY = cellY,
    mon = player.mon,
    shiny = player.shiny == true,
    dressed = false,
  }

  self.spawned[player.id] = av
  local handle = self:handle(av)
  local npc = handle and handle.npc
  av.npc = npc

  if npc and not self:dress(av, npc, def) then
    -- The renderer is gone. A follower that cannot wear its species is not a
    -- degraded follower, it is the wrong POKéMON in front of everyone -- so
    -- nothing half-spawned is left holding an NPC.
    self.spawned[player.id] = nil
    mod.world:removeNpc(npcId)
    return nil
  end

  -- A handle the engine will not hand over yet is not a failed spawn; the
  -- next advance dresses it. It is already wearing WoK's own follower sprite
  -- in the meantime.
  av.def = def
  return npcId
end

function M:despawn(playerId)
  local av = self.spawned[playerId]
  if not av then return false end
  self.spawned[playerId] = nil
  local npc = av.npc
  if not npc then
    local handle = self:handle(av)
    npc = handle and handle.npc
  end
  M.undecorate(npc)
  av.npc = nil
  mod.world:removeNpc(av.npcId)
  return true
end

function M:clear()
  for id in pairs(self.spawned) do self:despawn(id) end
  self.spawned = {}
end

-- Walk into the cell the trainer has just left.
--
-- `player` is the roster entry as it stands *now*; av.x/av.y is where that
-- trainer was when we last looked, which is exactly the cell they vacated
-- and exactly where the follower belongs. One cell of history is the whole
-- state a single follower needs.
function M:advance(playerId, player)
  local av = self.spawned[playerId]
  if not av or type(player) ~= "table" then return nil end

  local handle = self:handle(av)
  local npc = handle and handle.npc
  if not npc then return nil end
  av.npc = npc

  -- Heals a follower the engine rebuilt under us, and dresses one whose
  -- handle was not ready at spawn.
  if not av.dressed and av.def then
    self:dress(av, npc, av.def)
  else
    M.decorate(npc)
  end

  -- The goal is the cell the trainer has just left, and it only moves when
  -- they do.
  --
  -- **A goal, never a target.** Presence arrives at 8Hz and a step takes 16
  -- frames, so the follower is behind for most of an ordinary walk -- that
  -- is the normal state, not an error state. NPC:update interpolates px/py
  -- from the current cell to targetX/targetY over stepFrames *regardless of
  -- how far apart they are*, so writing the goal straight into the target
  -- crosses the whole gap in one step. That is what reads as a teleport, and
  -- it is why the step below is one tile toward the goal rather than the
  -- goal itself -- the same rule Avatars.stepToward applies to the trainer.
  if player.x ~= av.x or player.y ~= av.y then
    if av.x ~= nil then av.goalX, av.goalY = av.x, av.y end
    av.x, av.y = player.x, player.y
  end

  -- Set every tick rather than per step: NPC:update reads `stepFrames or 16`
  -- fresh every frame, so a trainer who breaks into a sprint mid-step takes
  -- their POKéMON with them instead of stretching the lead by a tile.
  npc.stepFrames = player.fast and Config.FAST_STEP_FRAMES or nil

  -- mid-step: let NPC:update finish it. Interrupting strands px/py between
  -- two cells.
  if npc.moving then return true end

  local goalX = av.goalX or av.x
  local goalY = av.goalY or av.y
  if goalX == nil or goalY == nil or npc.cellX == nil then return true end

  -- Too far behind to walk back -- a warp we never saw, a long stall -- so
  -- rebuild it behind the trainer rather than march it across the map. The
  -- same bound and the same reasoning as Avatars:advance.
  if math.max(math.abs(goalX - npc.cellX), math.abs(goalY - npc.cellY))
       > Config.RESYNC_DISTANCE then
    return self:resync(player)
  end

  local dir, tx, ty = Avatars.stepToward(npc.cellX, npc.cellY, goalX, goalY)
  if not dir then
    -- Standing on the goal: face the way its trainer is facing, so a
    -- follower waiting behind a stopped player looks at them rather than
    -- keeping whatever heading its last step left it with.
    if player.facing and npc.facing ~= player.facing then
      npc.facing = player.facing
      av.facing = player.facing
    end
    return true
  end

  npc.facing = dir
  npc.targetX, npc.targetY = tx, ty
  npc.moving = true
  npc.marching = false
  npc.progress = 0
  av.facing = dir
  return true
end

-- Despawn and spawn, which is the only way to move a follower without
-- walking it: the sheet is baked into the NPC at creation.
function M:resync(player)
  self:despawn(player.id)
  return self:spawn(player)
end

-- One pass per tick, over the same roster Avatars walks.
--
-- `roster` is a plain array of presence records -- the ones already on this
-- map. A follower is only ever synced for a player who has an avatar to
-- trail, which is what makes "no cell" (a battle, a menu) remove the
-- follower without a second rule for it.
function M:sync(roster, mapId)
  if not mod.world then return end

  if not self:enabled() then
    if next(self.spawned) then self:clear() end
    self.mapId = mapId
    return
  end

  if not mapId then
    if next(self.spawned) then self:clear() end
    self.mapId = nil
    return
  end

  if mapId ~= self.mapId then
    self:clear()
    self.mapId = mapId
  end

  local seen = {}
  for _, player in ipairs(roster or {}) do
    if type(player) == "table" and player.id ~= nil
       and player.map == mapId and player.x and player.y then
      local av = self.spawned[player.id]
      if type(player.mon) ~= "string" then
        -- Put the POKéMON away and everyone else sees it put away.
        if av then self:despawn(player.id) end
      elseif av and av.mon == player.mon and av.shiny == (player.shiny == true) then
        seen[player.id] = true
        self:advance(player.id, player)
      else
        -- A different species, or the shiny sheet: the sheet is baked into
        -- the NPC at creation, so the only way to re-render is a new one.
        if av then self:despawn(player.id) end
        if self:spawn(player) then seen[player.id] = true end
      end
    end
  end

  for id in pairs(self.spawned) do
    if not seen[id] then self:despawn(id) end
  end
end

M.DELTA = DELTA

return M
