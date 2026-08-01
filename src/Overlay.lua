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

function M:draw(game, viewport)
  local ctx = self.ctx
  if not (ctx.client and ctx.client:isConnected()) then return end
  if not (viewport and viewport.scale and viewport.scale > 0) then return end

  -- render.hud composites over the *finished* frame -- menus and text boxes
  -- included -- so a nameplate drawn unconditionally lands on top of
  -- whatever UI is open. These labels annotate the world, so they are drawn
  -- only while the world is what the player is actually looking at.
  local top = game and game.stack and game.stack:top()
  local overworld = mod.world and mod.world:overworld()
  if not (top and overworld and top == overworld) then return end

  local current = World.current()
  if not (current and current.mapId and current.x and current.y) then return end

  local here = ctx.roster:onMap(current.mapId)
  if #here == 0 then return end

  local Font = mod.ui.Font
  if not (Font and Font.draw and Font.width) then return end

  love.graphics.push()
  love.graphics.translate(viewport.gameX or 0, viewport.gameY or 0)
  love.graphics.scale(viewport.scale)

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
end

M.VIEW_W, M.VIEW_H, M.CELL = VIEW_W, VIEW_H, CELL
M.ANCHOR_X, M.ANCHOR_Y = ANCHOR_X, ANCHOR_Y
M.LOCAL_RADIUS = Config.LOCAL_RADIUS

return M
