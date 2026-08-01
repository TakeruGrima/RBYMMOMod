-- Shared helpers for the two MMO frame drivers.
--
-- Loaded with dofile from the engine checkout root, the same way
-- tests/drivers/util.lua is, so both drivers share one copy of the menu
-- navigation instead of each guessing at cursor arithmetic.

local U = dofile("tests/drivers/util.lua")

local M = { U = U }

function M.top(game)
  return game.stack and game.stack:top() or nil
end

-- Spin until `predicate` is true, or give up. Returns whether it happened,
-- so a driver can log a real failure instead of walking on and producing a
-- confusing error three steps later.
function M.waitFor(game, predicate, frames, what)
  for _ = 1, frames or 300 do
    if predicate() then return true end
    U.wait(1)
  end
  U.log("TIMEOUT waiting for " .. tostring(what or "condition"))
  return false
end

-- Pick a row by its label rather than by counting taps.
--
-- The START menu's length depends on save state (POKéDEX only appears once
-- Oak hands it over), and this mod inserts its own row, so a driver that
-- tapped "down" a fixed number of times would break the moment the menu
-- changed shape. Menu and ListMenu both expose `items` and a 1-based
-- `index`, so the cursor distance can be computed instead.
function M.selectLabel(game, label, frames)
  local ok = M.waitFor(game, function()
    local top = M.top(game)
    if not (top and type(top.items) == "table") then return false end
    for _, item in ipairs(top.items) do
      if item.label == label then return true end
    end
    return false
  end, frames or 240, "menu row " .. label)
  if not ok then return false end

  local menu = M.top(game)
  local target
  for i, item in ipairs(menu.items) do
    if item.label == label then target = i break end
  end

  local steps = (target - (menu.index or 1)) % #menu.items
  for _ = 1, steps do
    U.tap(game, "down")
    U.wait(2)
  end
  U.wait(2)
  U.tap(game, "a")
  U.wait(10)
  return true
end

function M.exports(game)
  local loader = game.mods
  return loader and loader.exports and loader.exports.rby_mmo or nil
end

-- The mod ships experimental, so a run where the wrapper forgot to enable
-- it would otherwise fail deep inside a menu that never appears. Say so up
-- front instead.
function M.requireMod(game, tag)
  local loader = game.mods
  local mod = loader and loader.mods and loader.mods.rby_mmo
  if not mod then
    U.log(tag, "FAIL rby_mmo was not discovered -- is it linked into mods/?")
    return nil
  end
  if mod.state ~= "loaded" then
    U.log(tag, ("FAIL rby_mmo is %s, not loaded -- it ships experimental, so "
      .. "options.lua must enable it"):format(tostring(mod.state)))
    return nil
  end
  local exports = M.exports(game)
  if not exports then
    U.log(tag, "FAIL rby_mmo published no exports")
    return nil
  end
  return exports
end

-- open the START menu and step into MMO
function M.openMmo(game)
  U.tap(game, "start")
  U.wait(15)
  return M.selectLabel(game, "MMO")
end

return M
