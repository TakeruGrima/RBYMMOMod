-- Nicknames and speech bubbles over remote players' heads.
--
-- This draws from the render.hud hook, which runs after the frame is
-- composited and before touch controls, and receives a window-space
-- viewport (gameX/gameY/gameWidth/gameHeight/scale).  Pushing that
-- transform puts drawing back into the game's own 160x144 space, so the
-- engine's font renders at its native size instead of one window pixel per
-- glyph pixel.
--
-- Positioning note, and the one real limitation here.  The mod API exposes
-- where the player and each avatar *are* (World.current(), and the NPC
-- handle's :position()), but not where the camera is.  So a remote player's
-- screen position is derived from its tile offset to the local player,
-- which assumes the player is drawn at the centre of the view.  That holds
-- while the camera is following normally and goes wrong by exactly the
-- camera's clamp when the player walks into a map edge smaller than the
-- screen, where the view stops scrolling but the player keeps moving.  A
-- label can sit a tile or two off in those corners.  Fixing it properly
-- needs a camera-position seam the mod API does not have yet, which is an
-- upstream RFC, not something to paper over with a private require.

local need, mod = ...
local Config = need("Config")
local World = need("World")

local M = {}
M.__index = M

-- Game Boy overworld geometry: a 160x144 view, 16px cells, and a 16px
-- player sprite parked in the middle of it.
local VIEW_W, VIEW_H = 160, 144
local CELL = 16
local ANCHOR_X = (VIEW_W - CELL) / 2
local ANCHOR_Y = (VIEW_H - CELL) / 2

function M.new(ctx)
  return setmetatable({ ctx = ctx }, M)
end

-- Is the world still being drawn with the flat 2D projection this overlay
-- assumes -- player centred, sixteen pixels to a tile?
--
-- It is not, whenever another mod owns the world pass. DramaticShapeVoxelMod
-- registers a "voxel" pipeline with drawWorld that replaces the overworld
-- with a 3D diorama; under it a nameplate placed by tile offset would float
-- somewhere unrelated to the character it names, which looks far worse than
-- no nameplate at all.
--
-- The registry says which pipelines replace the world (drawWorld); the
-- engine says which are switched on.
--
-- The level is read from src/render/Pipelines, not from
-- save.options.pipelines, because the options bucket is only written when
-- something syncs it -- Pipelines.setLevel alone does not. Reading the
-- bucket looked permission-free and self-evidently correct, and it was
-- neither: with the voxel pipeline genuinely on, the stale bucket still
-- said "flat" and the fallback never engaged. The save bucket is kept as a
-- second source for builds where the module cannot be reached at all.
--
-- This is why the manifest declares engine_internals: a read-only question
-- about how the world is being drawn, which the mod API has no other way
-- to answer.
local pipelinesModule, pipelinesTried

local function enginePipelines()
  if pipelinesTried then return pipelinesModule end
  pipelinesTried = true
  local ok, module = pcall(require, "src.render.Pipelines")
  if ok and type(module) == "table" and module.level then
    pipelinesModule = module
  end
  return pipelinesModule
end

function M:worldIsFlat(game)
  local registry = mod.content and mod.content.render_pipelines
  if not registry then return true end

  local Pipelines = enginePipelines()
  local levels = game and game.save and game.save.options
    and game.save.options.pipelines

  local ok, flat = pcall(function()
    for id, def in registry:each() do
      if type(def) == "table" and def.drawWorld then
        -- Either source saying "on" is enough. The engine's level is the
        -- live truth; the saved bucket can be stale in one direction only
        -- (it lags a change), so trusting whichever says the world is not
        -- flat costs at most the fallback rendering, while trusting only
        -- one of them can miss the case entirely.
        local level = 0
        if Pipelines then
          level = math.max(level, tonumber(Pipelines.level(id)) or 0)
        end
        if type(levels) == "table" then
          level = math.max(level, tonumber(levels[id]) or 0)
        end
        if level > 0 then return false end
      end
    end
    return true
  end)
  -- an unreadable registry means "assume vanilla", which is the case that
  -- draws correctly
  if not ok then return true end
  return flat
end

-- The fallback for a world this overlay cannot project into: name the
-- players on this map in a fixed corner list instead of floating a label
-- over each one. Their avatars are still drawn by whatever owns the world
-- -- the voxel mod draws them as voxel characters -- so what is missing is
-- only the labelling, and a corner list restores that without inventing
-- positions it cannot compute.
function M:drawRoster(Font, here)
  local y = 2
  for index, player in ipairs(here) do
    if index > 4 then break end
    local bubble = self.ctx.chat:bubbleFor(player.id)
    local text = bubble and (player.name .. ": " .. bubble) or player.name
    if #text > 19 then text = text:sub(1, 19) end
    local width = Font.width(text)
    love.graphics.setColor(0, 0, 0, 0.65)
    love.graphics.rectangle("fill", 1, y - 1, width + 4, 10)
    love.graphics.setColor(1, 1, 1, 1)
    Font.draw(text, 3, y)
    y = y + 10
  end
end

-- A label is only drawn when it is fully on screen; a half-clipped name at
-- the edge of the playfield reads as a rendering bug.
local function onScreen(x, y, width)
  return x >= 0 and y >= 0 and (x + width) <= VIEW_W and y + 8 <= VIEW_H
end

function M:drawLabel(Font, text, centreX, topY)
  local width = Font.width(text)
  local x = math.floor(centreX - width / 2)
  local y = math.floor(topY)
  if not onScreen(x, y, width) then return end

  -- a one-pixel dark plate behind the glyphs: the font is drawn in the
  -- text colour and would vanish over a dark tile without it
  love.graphics.setColor(0, 0, 0, 0.65)
  love.graphics.rectangle("fill", x - 2, y - 1, width + 4, 10)
  love.graphics.setColor(1, 1, 1, 1)
  Font.draw(text, x, y)
end

-- what the last draw decided, so a driver can ask why nothing appeared
-- instead of inferring it from a screenshot
function M:state()
  return self.last or { reached = "never" }
end

function M:draw(game, viewport)
  local ctx = self.ctx
  self.last = { reached = "entered" }
  local last = self.last
  if not (ctx.client and ctx.client:isConnected()) then last.reached = "not-connected" return end
  -- Derive the letterbox when the viewport does not carry a usable one.
  --
  -- render.hud is documented as receiving gameX/gameY/scale, and under the
  -- vanilla renderer it does. With DramaticShapeVoxelMod's pipeline owning
  -- the frame it arrived without a usable scale, and bailing on that meant
  -- the overlay silently drew nothing at all in voxel mode -- which looked
  -- like a positioning bug and was actually a missing guard. Falling back
  -- to the window's own dimensions keeps this working whoever draws the
  -- world.
  local scale = viewport and tonumber(viewport.scale) or nil
  local gameX = viewport and tonumber(viewport.gameX) or 0
  local gameY = viewport and tonumber(viewport.gameY) or 0
  if not scale or scale <= 0 then
    local w, h = love.graphics.getDimensions()
    scale = math.max(1, math.floor(math.min(w / VIEW_W, h / VIEW_H)))
    gameX = math.floor((w - VIEW_W * scale) / 2)
    gameY = math.floor((h - VIEW_H * scale) / 2)
    last.derived = true
  end
  last.scale, last.gameX, last.gameY = scale, gameX, gameY

  -- render.hud composites over the *finished* frame -- menus and text boxes
  -- included -- so a nameplate drawn unconditionally lands on top of
  -- whatever UI is open. These labels annotate the world, so they are drawn
  -- only while the world is what the player is actually looking at.
  local top = game and game.stack and game.stack:top()
  local overworld = mod.world and mod.world:overworld()
  if not (top and overworld and top == overworld) then
    last.reached = "not-overworld"
    return
  end

  local current = World.current()
  if not (current and current.mapId and current.x and current.y) then
    last.reached = "no-cell"
    return
  end

  local here = ctx.roster:onMap(current.mapId)
  last.here = #here
  if #here == 0 then last.reached = "nobody-here" return end

  local Font = mod.ui.Font
  if not (Font and Font.draw and Font.width) then
    last.reached = "no-font"
    return
  end

  -- Reset the graphics state before drawing, and put it back after.
  --
  -- love.graphics.push() saves the transform and nothing else, so a shader
  -- or blend mode left bound by whoever drew the world is still active
  -- here. With DramaticShapeVoxelMod's pipeline on, the labels drew through
  -- its shader and simply did not appear -- the overlay looked broken when
  -- it was in fact drawing every frame.
  local prevShader = love.graphics.getShader()
  local prevBlend = love.graphics.getBlendMode()
  love.graphics.setShader()
  love.graphics.setBlendMode("alpha")

  love.graphics.push()
  love.graphics.translate(gameX, gameY)
  love.graphics.scale(scale)

  -- another mod owns the world pass: label from a corner rather than
  -- guessing at positions in a projection this does not know
  if not self:worldIsFlat(game) then
    last.reached = "roster"
    self:drawRoster(Font, here)
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.pop()
    love.graphics.setBlendMode(prevBlend)
    love.graphics.setShader(prevShader)
    return
  end

  last.reached = "labels"
  for _, player in ipairs(here) do
    -- the live avatar cell, which is where the sprite actually is mid-step
    local ax, ay = ctx.avatars:cellOf(player.id)
    if ax and ay then
      local screenX = ANCHOR_X + (ax - current.x) * CELL
      local screenY = ANCHOR_Y + (ay - current.y) * CELL

      local bubble = ctx.chat:bubbleFor(player.id)
      if bubble then
        -- the bubble takes the slot above the head and pushes the name up
        self:drawLabel(Font, bubble, screenX + CELL / 2, screenY - 20)
        self:drawLabel(Font, player.name, screenX + CELL / 2, screenY - 10)
      else
        self:drawLabel(Font, player.name, screenX + CELL / 2, screenY - 10)
      end
    end
  end

  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.pop()
  love.graphics.setBlendMode(prevBlend)
  love.graphics.setShader(prevShader)
end

M.VIEW_W, M.VIEW_H, M.CELL = VIEW_W, VIEW_H, CELL
M.ANCHOR_X, M.ANCHOR_Y = ANCHOR_X, ANCHOR_Y
M.LOCAL_RADIUS = Config.LOCAL_RADIUS

return M
