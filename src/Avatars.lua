-- Remote players as overworld NPCs.
--
-- Every other player on the local player's current map gets one runtime NPC
-- spawned through mod.world.  That is deliberately the whole trick: an NPC
-- already draws with the right sprite, sorts against the player by depth,
-- takes the map's palette, and animates a walk cycle.  Drawing avatars
-- ourselves would mean reimplementing all of it against engine internals
-- the mod API does not expose.
--
-- Movement places the avatar on its cell directly, and this is the one
-- place the mod reaches past the WorldAPI facade -- deliberately, after the
-- supported route proved unusable.
--
-- The obvious primitive is Handle:scriptMove, the engine's scripted-step
-- move. It cannot be used here: OverworldController gates the player's own
-- controls on `#self.scriptMoves > 0` (see the `scripted` guard around
-- handleInput), because that queue exists for cutscenes, where freezing the
-- player is the *point*. Driving avatars through it means every step a
-- remote player takes locks the local player's input -- on a busy map,
-- permanently. The end-to-end run caught exactly that.
--
-- So the avatar's cell, pixel position and facing are set on the NPC. The
-- cost is losing the tween between tiles: a remote player steps rather than
-- glides. The walk-cycle frame is flipped per step so it still reads as
-- walking. What the mod API is missing is a "place this NPC" primitive on
-- Handle -- an upstream RFC, not something to fake with a cutscene queue.
--
-- When the avatar is further out than RESYNC_DISTANCE (a warp we never saw,
-- a long stall), it is respawned rather than walked.

local need, mod = ...
local Config = need("Config")

local M = {}
M.__index = M

-- set by the end-to-end driver via the debug export; off in normal play
M.TRACE = false

local DELTA = {
  up    = { 0, -1 },
  down  = { 0, 1 },
  left  = { -1, 0 },
  right = { 1, 0 },
}

local RANGE_OF = {
  up = "UP", down = "DOWN", left = "LEFT", right = "RIGHT",
}

function M.new()
  return setmetatable({
    spawned = {},   -- playerId -> { npcId, x, y, facing }
    mapId = nil,
    spriteWarned = {},
  }, M)
end

-- NPC.new asserts on a sprite the data catalog does not carry, and that
-- assert would fire inside the engine's own spawn path where this mod
-- cannot catch it.  Checking first turns an unknown sprite into a
-- documented fallback instead of a crash attributed to the overworld.
function M:spriteFor(requested)
  local sprites = mod.content.sprites
  if sprites and requested and sprites:get(requested) then return requested end
  if requested and not self.spriteWarned[requested] then
    self.spriteWarned[requested] = true
    mod.log:warn("sprite %s is not in this game's catalog; drawing that "
      .. "player as %s instead", tostring(requested), Config.DEFAULT_SPRITE)
  end
  if sprites and sprites:get(Config.DEFAULT_SPRITE) then
    return Config.DEFAULT_SPRITE
  end
  return nil
end

function M:handle(av)
  if not (av and av.npcId and self.mapId) then return nil end
  local handle = mod.world:npc(self.mapId, av.npcId)
  return handle
end

function M:spawn(player)
  if not (player.map and player.x and player.y) then return nil end
  local sprite = self:spriteFor(player.sprite)
  if not sprite then
    -- no usable sprite at all: stay silent per player, the warn above
    -- already named the cause once
    return nil
  end

  local npcId = mod.world:spawnNpc(player.map, {
    sprite = sprite,
    x = player.x,
    y = player.y,
    movement = "STAY",           -- never wander; the network is the authority
    range = RANGE_OF[player.facing] or "DOWN",
    name = "mmo_" .. player.id,
  })
  if not npcId then return nil end

  self.spawned[player.id] = {
    npcId = npcId,
    x = player.x,
    y = player.y,
    facing = player.facing,
  }
  return npcId
end

function M:despawn(playerId)
  local av = self.spawned[playerId]
  if not av then return false end
  self.spawned[playerId] = nil
  mod.world:removeNpc(av.npcId)
  return true
end

function M:clear()
  for id in pairs(self.spawned) do self:despawn(id) end
  self.spawned = {}
end

-- where an avatar actually is right now, for the overlay's nameplate.  The
-- live NPC is the authority mid-step: self.spawned holds the cell the
-- network last confirmed, which is where the avatar is *going*.
function M:cellOf(playerId)
  local av = self.spawned[playerId]
  if not av then return nil end
  local handle = self:handle(av)
  if handle then
    local x, y = handle:position()
    if x and y then return x, y end
  end
  return av.x, av.y
end

function M:resync(player)
  self:despawn(player.id)
  return self:spawn(player)
end

-- Put the avatar on a cell now.  Clears any in-flight step so the NPC's own
-- update does not keep tweening toward a target that is no longer where the
-- network says the player is.
function M:place(av, player)
  local handle = self:handle(av)
  local npc = handle and handle.npc
  if not npc then return self:resync(player) end

  npc.cellX, npc.cellY = player.x, player.y
  npc.px, npc.py = player.x * 16, player.y * 16
  npc.targetX, npc.targetY = nil, nil
  npc.moving, npc.marching, npc.progress = false, false, 0
  if player.facing then npc.facing = player.facing end
  -- alternate the walk-cycle frame per step, so a moving avatar reads as
  -- walking rather than sliding
  npc.stepFlip = not npc.stepFlip

  av.x, av.y, av.facing = player.x, player.y, npc.facing
  return true
end

function M:advance(av, player)
  local dx, dy = player.x - av.x, player.y - av.y

  if dx == 0 and dy == 0 then
    if player.facing ~= av.facing then
      local handle = self:handle(av)
      if handle then
        handle:face(player.facing)
        av.facing = player.facing
      end
    end
    return
  end

  if M.TRACE then
    mod.log:info("advance %s d=(%d,%d) av=(%s,%s) -> (%s,%s)", tostring(player.id),
      dx, dy, tostring(av.x), tostring(av.y),
      tostring(player.x), tostring(player.y))
  end

  -- Far out of step (a warp we never saw, a long stall): rebuild rather
  -- than place, so the avatar cannot appear to teleport across a map.
  if math.max(math.abs(dx), math.abs(dy)) > Config.RESYNC_DISTANCE then
    return self:resync(player)
  end

  return self:place(av, player)
end

-- One pass per tick.  `current` is mod.world:current() -- nil whenever
-- there is no overworld up (title screen, a battle), in which case every
-- avatar is dropped and rebuilt on the way back.
function M:sync(roster, current)
  -- mod.world materialises on first touch and answers nil until a Game
  -- exists; every method below goes through it, so this is the one gate
  if not mod.world then return end

  if not current or not current.mapId then
    if next(self.spawned) then self:clear() end
    self.mapId = nil
    return
  end

  -- A map change rebuilds from scratch: runtime objects belong to the map
  -- they were spawned on, and the engine only instantiates them while that
  -- map is the active one.
  if current.mapId ~= self.mapId then
    self:clear()
    self.mapId = current.mapId
  end

  local seen = {}
  for _, player in ipairs(roster:onMap(current.mapId)) do
    seen[player.id] = true
    local av = self.spawned[player.id]
    if av then self:advance(av, player) else self:spawn(player) end
  end

  for id in pairs(self.spawned) do
    if not seen[id] then self:despawn(id) end
  end
end

M.DELTA = DELTA

return M
