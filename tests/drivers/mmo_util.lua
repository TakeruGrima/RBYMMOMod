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

-- Wait on something the OTHER process has to get round to, in seconds.
--
-- Frames are the right unit for anything inside this game: a menu animation
-- is so many frames whatever the clock is doing. They are exactly the wrong
-- unit across the pair. LOVE steps a driver once per rendered frame, and two
-- windows on one desktop do not render at the same rate -- the focused one
-- runs at the display's refresh while the occluded one is throttled by the
-- window server, by an order of magnitude in the bad case.
--
-- One run died of precisely that: the host spent "60 * 420 frames" of
-- patience waiting for the guest to connect, burned it in half that many
-- seconds on a 120Hz display, quit -- and the guest, still crawling through
-- the intro at a fraction of its frame rate, finally dialled a port nobody
-- was listening on any more and reported "connection refused". Nothing was
-- wrong with the mod. So anything that waits on the other process waits on
-- the clock.
function M.waitSeconds(game, predicate, seconds, what)
  seconds = seconds or 120
  local deadline = os.time() + seconds
  while os.time() < deadline do
    if predicate() then return true end
    U.wait(2)
  end
  U.log(("TIMEOUT waiting %ds for %s"):format(seconds, tostring(what or "condition")))
  return false
end

-- ------- join codes
--
-- The driver learns the code the way a friend does: off the screen the host
-- is looking at. Nothing reaches into the mod for it -- Client deliberately
-- keeps the code out of every log and out of exports, and a test that read
-- it from a private table would still pass on a build whose screen printed
-- nothing.

-- Config.CODE_ALPHABET, as a Lua character class. Crockford-style, so I, L,
-- O and U are absent -- which is also what stops "will" or "code" in the
-- surrounding sentence from looking like a group of code.
local CODE_CHAR = "[0-9A-HJKMNP-TV-Z]"
local CODE_GROUP = "(" .. CODE_CHAR:rep(4) .. ")"

-- Pull a join code out of whatever a screen is showing.
--
-- Ui shows one as Wire.formatCode does -- four-character groups joined by
-- dashes, broken after two groups so a text box does not wrap it -- so what
-- comes back from textOf is "... ABCD-EFGH JKMN-PQRS". Only dashed pairs are
-- matched, which is what keeps the prose in front of it out of the answer.
function M.codeFrom(text)
  if type(text) ~= "string" then return nil end
  local parts = {}
  for a, b in text:gmatch(CODE_GROUP .. "%-" .. CODE_GROUP) do
    parts[#parts + 1] = a
    parts[#parts + 1] = b
  end
  local code = table.concat(parts)
  if #code ~= 16 then return nil end
  return code
end

-- the display form, for logs and for asserting a screen reads it back
function M.formatCode(code)
  if type(code) ~= "string" then return "" end
  local groups = {}
  for i = 1, #code, 4 do groups[#groups + 1] = code:sub(i, i + 3) end
  return table.concat(groups, "-")
end

-- A code of the right shape that is not the right code.
--
-- Derived from the real one rather than invented, so it is guaranteed to
-- normalise (Wire.code refuses anything that is not exactly 16 symbols of
-- the alphabet) and guaranteed to be wrong. A hand-written constant could
-- be neither.
function M.wrongCode(code)
  local first = code:sub(1, 1)
  return (first == "0" and "1" or "0") .. code:sub(2)
end

-- ------- typing on the naming grid
--
-- The join code screen is NamingScreen, so the only way to enter one is the
-- d-pad: move the cursor onto a cell and press A. That is worth driving
-- properly rather than writing the glyphs in directly -- "is the code
-- typeable at all" is exactly the question this screen answers, and the
-- alphabet was chosen (Config.CODE_ALPHABET) so that every symbol sits on
-- the mod's own grid pages.
local function findCell(grid, ch)
  for r, row in ipairs(grid) do
    for c, cell in ipairs(row) do
      if cell == ch then return r, c end
    end
  end
  return nil
end

-- Walks the cursor rather than computing a tap count. NamingScreen wraps
-- both axes and clamps the column when the row changes, and SELECT swaps in
-- a page with a different number of rows -- so arithmetic that was right on
-- the letters page lands somewhere else on the digits page. Stepping until
-- the cursor is where it should be is immune to all of that.
local function moveTo(game, screen, r, c)
  for _ = 1, 12 do
    if (screen.row or 1) == r then break end
    U.tap(game, "down")
    U.wait(1)
  end
  for _ = 1, 12 do
    if (screen.col or 1) == c then break end
    U.tap(game, "right")
    U.wait(1)
  end
  return (screen.row or 1) == r and (screen.col or 1) == c
end

function M.typeOnGrid(game, text)
  local screen = M.top(game)
  if not (screen and type(screen.glyphs) == "table" and screen.grid) then
    U.log("WARN not on a naming screen; cannot type")
    return false
  end
  for i = 1, #text do
    local ch = text:sub(i, i)
    local r, c = findCell(screen:grid(), ch)
    if not r then
      -- the other page. SELECT is what the case-switch row does, and the
      -- mod's grid hook reads the same flag to swap letters for digits
      U.tap(game, "select")
      U.wait(2)
      r, c = findCell(screen:grid(), ch)
    end
    if not r then
      U.log("WARN no cell on the naming grid for", ch)
      return false
    end
    if not moveTo(game, screen, r, c) then
      U.log("WARN could not reach the cell for", ch)
      return false
    end
    U.tap(game, "a")
    U.wait(2)
  end
  return true
end

-- Answer a join-code prompt: dismiss whatever box is asking, type the code
-- on the grid, and confirm with START.
--
-- The box comes first and its onDone pushes the grid, and a refusal arrives
-- as two boxes rather than one (the hub's sentence, then Transport's), so
-- the way through is to keep pressing A until the grid is actually there
-- instead of counting screens.
function M.enterJoinCode(game, code)
  local screen
  for _ = 1, 40 do
    local top = M.top(game)
    if top and type(top.glyphs) == "table" and top.grid then
      screen = top
      break
    end
    U.tap(game, "a")
    U.wait(10)
  end
  if not screen then
    U.log("WARN never reached the join-code grid; top is",
          tostring(M.top(game) and (M.top(game).title or "?")))
    return false
  end
  if not M.typeOnGrid(game, code) then return false end
  local typed = table.concat(screen.glyphs)
  if typed ~= code then
    U.log("WARN the grid holds", typed, "not", M.formatCode(code))
    return false
  end
  U.tap(game, "start")
  U.wait(30)
  return true
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

-- Seconds, not frames: a barrier is by definition a wait on the other
-- process, and the two do not run at the same speed. See waitSeconds.
function M.await(game, name, seconds)
  return M.waitSeconds(game, function()
    local handle = io.open(M.syncPath(name), "r")
    if not handle then return false end
    handle:close()
    return true
  end, seconds or 180, "phase " .. name)
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
