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
-- Matches a row by label, tolerating a trailing marker: the CHAT row reads
-- "CHAT*" while messages are unread, and a driver that demanded an exact
-- string would fail for the wrong reason.
local function labelMatches(actual, wanted)
  if actual == wanted then return true end
  return type(actual) == "string"
    and actual:sub(1, #wanted) == wanted
    and actual:sub(#wanted + 1):match("^[%*%s]*$") ~= nil
end

function M.selectLabel(game, label, frames)
  local ok = M.waitFor(game, function()
    local top = M.top(game)
    if not (top and type(top.items) == "table") then return false end
    for _, item in ipairs(top.items) do
      if labelMatches(item.label, label) then return true end
    end
    return false
  end, frames or 240, "menu row " .. label)
  if not ok then return false end

  local menu = M.top(game)
  local target
  for i, item in ipairs(menu.items) do
    if labelMatches(item.label, label) then target = i break end
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

-- Dismiss whatever is on the stack until the overworld is on top again.
--
-- This matters for more than tidiness: StateStack updates only the top
-- state, so while any box or menu is up the overworld -- and every NPC in
-- it -- is frozen. An avatar mid-step stays mid-step, which is correct in
-- play but makes a driver that samples avatar movement behind an open text
-- box wait forever for a step that cannot finish.
function M.closeToOverworld(game, tries)
  for _ = 1, tries or 24 do
    local top = M.top(game)
    if top == nil or top == game.overworld or top.isOverworld then return true end
    -- a text box wants A to advance and close; a menu wants B to cancel
    U.tap(game, "b")
    U.wait(6)
    if M.top(game) == top then
      U.tap(game, "a")
      U.wait(6)
    end
  end
  local top = M.top(game)
  U.log("WARN could not get back to the overworld; top is",
        tostring(top and (top.title or "?")))
  return false
end

-- ------- phase barriers
--
-- The two drivers are separate processes with no channel between them but
-- the filesystem. Polling "has the other side got there yet" with sleeps is
-- what made the early runs flaky, so each phase is gated on an explicit
-- marker instead.

local SYNC_DIR = os.getenv("MMO_SYNC_DIR") or "/tmp/rby_mmo_sync"

function M.syncPath(name)
  return SYNC_DIR .. "/" .. name
end

function M.signal(name)
  os.execute('mkdir -p "' .. SYNC_DIR .. '" 2>/dev/null')
  local handle = io.open(M.syncPath(name), "w")
  if handle then
    handle:write("1")
    handle:close()
  end
end

function M.await(game, name, frames)
  return M.waitFor(game, function()
    local handle = io.open(M.syncPath(name), "r")
    if not handle then return false end
    handle:close()
    return true
  end, frames or 60 * 90, "phase " .. name)
end

-- this game's own player cell
function M.playerCell(game)
  local ow
  for i = #game.stack.states, 1, -1 do
    if game.stack.states[i].isOverworld then ow = game.stack.states[i] break end
  end
  ow = ow or game.overworld
  if not (ow and ow.map and ow.player) then return nil end
  return { mapId = ow.map.id, x = ow.player.cellX, y = ow.player.cellY }
end

-- the other side's avatar, as this game sees it
function M.avatarRow(exports, name)
  for _, row in ipairs(exports.avatarState() or {}) do
    if name == nil or row.name == name then return row end
  end
  return nil
end

-- ------- driving a session's prompts
--
-- A trade puts a sequence of boxes in front of both players -- "X wants to
-- trade!", the party picker, "Trade for Y?", then the result -- and the two
-- sides do not see them at the same moments. Rather than scripting an exact
-- order per side (which would be a different script for host and guest, and
-- would break the moment a prompt moved), both sides run this: answer
-- whatever is on top, affirmatively, until `done` says the flow finished.
--
-- The three shapes are distinguishable by their fields:
--   ListMenu / Menu -> has `items`      (the party picker)
--   ChoiceBox       -> has `onChoose` and `index` but no `items`
--   TextBox         -> neither
local function classify(top)
  if not top then return nil end
  if type(top.items) == "table" then return "menu" end
  if top.onChoose ~= nil and top.index ~= nil then return "choice" end
  return "text"
end

M.classify = classify

-- Returns whether `done` came true, and the sequence of prompt kinds it
-- answered on the way. A trade or battle that stalls is otherwise a bare
-- "did not happen": the sequence says whether the prompt never arrived, or
-- arrived and was answered and still went nowhere.
function M.drivePrompts(game, done, frames, onStep)
  local seen = {}
  local function note(kind)
    if kind and seen[#seen] ~= kind then seen[#seen + 1] = kind end
  end
  for _ = 1, frames or 60 * 60 do
    if done and done() then return true end
    local top = M.top(game)

    -- The overworld is NOT a prompt. It has no `items` and no `onChoose`,
    -- so classify() called it a text box and this loop mashed A into the
    -- open world -- pressing A on doors and NPCs and walking into grass.
    -- One run wandered the host out of Red's house, through Pallet Town and
    -- Oak's lab, onto Route 1, and left it fighting wild Pokemon while the
    -- trade it was supposed to be answering timed out. Wait for a real
    -- prompt instead.
    if top == nil or top == game.overworld or top.isOverworld then
      U.wait(4)
      if onStep then onStep(nil) end
      goto continue
    end

    local kind = classify(top)
    if kind == "choice" then
      -- YES is index 1; walk the cursor there rather than assuming it
      local guard = 0
      while (M.top(game) == top) and (top.index or 1) > 1 and guard < 4 do
        U.tap(game, "up")
        U.wait(3)
        guard = guard + 1
      end
      U.tap(game, "a")
      U.wait(12)
    elseif kind == "menu" then
      -- the party picker: take whatever is under the cursor (slot 1)
      U.tap(game, "a")
      U.wait(12)
    elseif kind == "text" then
      U.tap(game, "a")
      U.wait(8)
    else
      U.wait(4)
    end
    note(kind)
    if onStep then onStep(kind) end
    ::continue::
  end
  return (done and done() or false), table.concat(seen, ">")
end

-- Put the hardest-hitting move in slot 1.
--
-- drivePrompts answers a battle menu by taking whatever is under the
-- cursor: FIGHT, then move 1. Gen 1 leads do not cooperate -- CHARIZARD at
-- 50 opens with LEER and PIKACHU at 30 with GROWL, both zero power -- so
-- two driven parties would lower each other's stats until PP ran out and
-- the test burned its whole budget without a decision.
--
-- Reordering rather than injecting a move keeps the mon otherwise
-- authentic, and picking by power rather than by name means this works for
-- any species without hardcoding move ids that differ between versions.
function M.frontloadDamage(data, mon)
  local best, bestPower
  for i, mv in ipairs(mon.moves or {}) do
    local def = data.moves[mv.id]
    local power = def and def.power or 0
    if power > 0 and (bestPower == nil or power > bestPower) then
      best, bestPower = i, power
    end
  end
  if not best or best == 1 then
    return mon.moves and mon.moves[1] and mon.moves[1].id or nil
  end
  local mv = table.remove(mon.moves, best)
  table.insert(mon.moves, 1, mv)
  return mv.id
end

-- species in party order, for asserting a trade actually swapped something
function M.partySpecies(game)
  local out = {}
  for _, mon in ipairs((game.save and game.save.party) or {}) do
    out[#out + 1] = tostring(mon.species)
  end
  return out
end

-- Record engine events by wrapping Runtime.emit.
--
-- Same trick tests/drivers/online_match_host.lua uses. Subscribing through
-- the event bus would work too, but wrapping catches everything regardless
-- of which bus a mod installed, and a battle is exactly where an assertion
-- must not depend on this mod's own plumbing being correct.
--
-- link.desync is the one to watch: two games disagreeing mid-battle is the
-- failure a lockstep simulation exists to prevent, and it is silent
-- otherwise.
function M.captureEvents(names)
  local Runtime = require("src.mods.Runtime")
  local seen = {}
  for _, name in ipairs(names) do seen[name] = 0 end
  local realEmit = Runtime.emit
  Runtime.emit = function(name, payload)
    if seen[name] ~= nil then seen[name] = seen[name] + 1 end
    return realEmit(name, payload)
  end
  return seen
end

-- The visible contents of a TextBox, flattened. TextBox paginates into
-- self.pages, so this is how a driver checks that what the player is
-- actually being shown says what it should.
function M.textOf(top)
  if not (top and type(top.pages) == "table") then return "" end
  local out = {}
  for _, page in ipairs(top.pages) do
    if type(page) == "table" then
      for _, line in ipairs(page) do out[#out + 1] = tostring(line) end
    end
  end
  return table.concat(out, " ")
end

-- open the START menu and step into MMO
function M.openMmo(game)
  U.tap(game, "start")
  U.wait(15)
  return M.selectLabel(game, "MMO")
end

return M
