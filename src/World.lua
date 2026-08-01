-- A guarded read of where the local player is.
--
-- mod.world materialises on first touch and answers nil until a Game
-- exists -- during a headless load, and on the title screen before a save
-- is up.  WorldAPI:current() then answers nil again whenever no overworld
-- is on the stack (a battle, a menu).
--
-- Every caller wants the same answer for both cases: "not in the world
-- right now."  Collapsing them here means no call site has to remember the
-- first one, and forgetting it would be an index-a-nil crash inside a hook.

local need, mod = ...

local M = {}

function M.current()
  local world = mod.world
  if not world then return nil end
  return world:current()
end

return M
