-- One monster's menu icon, drawn the engine's own way so icon packs are free.
--
-- CREDIT: the call recipe below (both generations, the gen 2 stand-in `self`,
-- and the three traps) is adapted from gc_pokebank's src/ui/Icon.lua, which
-- solved the same problem for its bank rows. It is repeated here rather than
-- depended on, because a cross-mod dependency for a decoration would make this
-- mod refuse to load without that one.
--
-- WHY THROUGH THE ENGINE AND NOT OFF THE REGISTRY DIRECTLY. PartyMenu.drawIcon
-- resolves `icons.bySpecies` and then the `pokemon.icon` hook -- which is
-- exactly where unique_menu_icons and new_icons write (unique_menu_icons
-- main.lua:440 and :444). Drawing through it therefore picks their art up with
-- no branch naming either mod, and with none of them installed this is the
-- same code rather than a degraded mode.
--
-- Three traps, all closed here:
--
--   * NOTHING from the render stack is required at file scope. This module is
--     resolved while the Game is still being wired, and the engine states the
--     same rule for itself at src/ui/ModUI.lua:1-4. A require that raised up
--     here would cost the WHOLE MOD, silently, with one line in a log nobody
--     reads. Every require below sits inside draw(), where a renderer exists;
--     after the first call it is a table hit.
--   * `selected` is always false. With it true the engine reads mon.hp and
--     mon.stats.hp, which a mediated sheet does not carry in that shape -- and
--     false also means one fixed frame, which is what a list wants.
--   * on Gold, drawIcon is a METHOD whose first line dispatches through the
--     module's own metatable. Handed a bare table it is a call on a nil value,
--     raised from inside draw() where no pcall of ours reaches. The stand-in
--     below has its metatable set from the loaded module on every call.
--
-- NO ICON ANIMATES, deliberately. A list is read, not watched: a column of
-- icons swapping in step reads as flicker, and an icon pack whose two frames
-- come from different sets makes the same species appear to change art every
-- few frames. The clock is held at zero on both paths.

local need, mod = ...
local Gen = need("Gen")

local M = {}

-- The engine's own party icon footprint. Sources are 16x16; drawing them at
-- any other size is what Battlefield.lua:29-31 already warns about for the
-- 16xN sheets, so nothing here scales them.
M.SIZE = 16

-- The stand-in gen 2 `self`. A real PartyMenu.new(game) builds a save-backed
-- party list and a BattleHud this file never draws; what drawIcon actually
-- reads is the four fields set before every call. iconCache persists across
-- calls so a species already resolved does not pay the lookup again next
-- frame.
local gen2Self = { iconCache = {} }

local function generationOf(game)
  local ok, gen = pcall(Gen.generation, game)
  if not ok then return 1 end
  return tonumber(gen) or 1
end

--- Draw one monster's menu icon at pixel (x, y).
--
-- `row` is the minimal record BattleRows put on the model: `{ species = id }`,
-- where id is the REGISTRY id and never the prose nickname.
--
-- Returns true only when something was painted. Callers use that to reclaim
-- the space rather than leaving a hole: an icon is an ornament, and its
-- absence must cost nothing but itself.
function M.draw(game, row, x, y)
  if type(row) ~= "table" or row.species == nil then return false end
  if not (love and love.graphics) then return false end

  local painted = false
  pcall(function()
    if generationOf(game) == 1 then
      local PartyMenu = require("src.ui.PartyMenu")
      if type(PartyMenu) ~= "table" or type(PartyMenu.drawIcon) ~= "function" then
        return
      end
      -- selected = false, counter = 0, forceAlt = false: one fixed frame, and
      -- with `selected` false the engine never reads mon.hp either.
      PartyMenu.drawIcon(game, row, x, y, false, 0, false)
      painted = true
      return
    end

    local data = game and game.data
    -- No icon registry at all (a boot whose extractor never produced
    -- gen2Icons): the engine would resolve nothing and return before drawing,
    -- so say so by not claiming the space. A registry that merely lacks THIS
    -- species is a different case and stays with the engine, because an icon
    -- mod can still answer it through the pokemon.icon hook.
    if data == nil or data.gen2Icons == nil then return end

    local PartyMenu = require("src.ui.gen2.PartyMenu")
    if type(PartyMenu) ~= "table" or type(PartyMenu.drawIcon) ~= "function" then
      return
    end
    -- Set from the loaded module on every call: it is the loaded module's
    -- dispatch that has to be used, not one captured earlier.
    setmetatable(gen2Self, PartyMenu)
    gen2Self.game = game
    gen2Self.icons = data.gen2Icons
    gen2Self.palettes = data.gen2Palettes
    -- Read as a number by the engine (math.floor(self.clock / 16)). A fixed
    -- clock is a fixed frame.
    gen2Self.clock = 0
    PartyMenu.drawIcon(gen2Self, row, x, y)
    painted = true
  end)

  -- Whatever the engine left set, the next painter starts from white.
  pcall(love.graphics.setColor, 1, 1, 1, 1)
  return painted
end

return M
