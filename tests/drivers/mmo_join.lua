-- Driver: join a hosted game, joining side.
--
-- Pair with tests/drivers/mmo_host.lua in a second instance. Waits for the
-- host to publish its address, then joins over a real socket, walks around
-- so the host has movement to observe, and checks the host shows up on this
-- side's roster too.
--
--   POKEPORT_IDENTITY=mmoguest POKEPORT_DRIVER=mods/rby_mmo/tests/drivers/mmo_join.lua love .

return function(game)
  local H = dofile("mods/rby_mmo/tests/drivers/mmo_util.lua")
  local U = H.U
  local TAG = "MMO_JOIN:"
  local ADDR_FILE = os.getenv("MMO_ADDR_FILE") or "/tmp/rby_mmo_addr.txt"
  local SHOT_DIR = os.getenv("SHOT_DIR") or "/tmp/rby_mmo_shots"

  local function log(...) U.log(TAG, ...) end
  local failures = 0
  local function check(ok, what)
    if ok then
      log("ok " .. what)
    else
      failures = failures + 1
      log("FAIL " .. what)
    end
    return ok
  end

  U.newGame(game)
  -- U.newGame mashes A through the naming grid, so both sides would
  -- otherwise be called AAAAAAA and no roster assertion could tell
  -- them apart. Name them here instead.
  if game.save and game.save.player then
    game.save.player.name = "GUESTY"
  end
  log("in the overworld as GUESTY")

  local exports = H.requireMod(game, TAG)
  if not exports then
    log("RESULT 1 failure(s)")
    return
  end

  -- The host writes its address once the listener is up; that file is the
  -- start gun. This side still dials the default 127.0.0.1:7788, because
  -- both instances are on one machine.
  local ready = H.waitFor(game, function()
    local handle = io.open(ADDR_FILE, "r")
    if not handle then return false end
    handle:close()
    return true
  end, 60 * 60, "the host to publish its address")
  check(ready, "the host came up")
  if not ready then
    log("RESULT " .. failures .. " failure(s)")
    return
  end

  -- ------- join, through the real menus

  if not H.openMmo(game) then
    log("FAIL could not reach the MMO menu")
    log("RESULT " .. (failures + 1) .. " failure(s)")
    return
  end

  if not H.selectLabel(game, "JOIN GAME") then
    log("FAIL no JOIN GAME row")
    log("RESULT " .. (failures + 1) .. " failure(s)")
    return
  end

  -- The naming screen opens prefilled with the saved address, so START
  -- confirms it as-is. That the field is prefilled at all is the point:
  -- the vanilla grid has no digits, so a default that already reads
  -- 127.0.0.1:7788 is what makes this reachable without typing.
  U.wait(20)
  local naming = H.top(game)
  if naming and naming.glyphs then
    log("address field reads", '"' .. table.concat(naming.glyphs) .. '"')
  else
    log("WARN the top state is not a naming screen:",
        tostring(naming and naming.title))
  end
  U.shot(game, SHOT_DIR .. "/join-address.png")
  U.tap(game, "start")
  U.wait(60)

  local connected = H.waitFor(game, function() return exports.isConnected() end,
                              60 * 30, "the connection to open")
  check(connected, "joined over a real socket")
  if not connected then
    -- Transport puts a player-facing sentence in the box on failure, so the
    -- screenshot is the diagnosis: "can't reach ...", a bad address, or a
    -- naming screen that never confirmed at all
    U.shot(game, SHOT_DIR .. "/join-FAILED.png")
    log("top state after the attempt:",
        tostring(H.top(game) and (H.top(game).title or "?")))
  end
  check(exports.isHosting() == false, "and is not the host")
  if not connected then
    log("RESULT " .. failures .. " failure(s)")
    return
  end

  H.closeToOverworld(game)

  -- ------- the host is a player over here too

  local sawHost = H.waitFor(game, function()
    return #exports.players() > 0
  end, 60 * 20, "the host to appear on the roster")
  check(sawHost, "the host appears on the guest's roster")
  if sawHost then
    log("host is", tostring(exports.players()[1].name))
  end
  U.wait(90)
  U.shot(game, SHOT_DIR .. "/join-sees-host.png")

  -- ------- walk, so the host has movement to observe
  --
  -- This is the avatar path end to end: these steps become presence
  -- messages, and the host turns them into scriptMove on a spawned NPC.

  for _ = 1, 3 do
    U.hold(game, "down", 20)
    U.wait(10)
    U.hold(game, "right", 20)
    U.wait(10)
  end
  log("walked")
  U.shot(game, SHOT_DIR .. "/join-after-walk.png")

  -- ------- chat crosses the wire in both directions

  local heardHost = H.waitFor(game, function()
    for _, line in ipairs(exports.chat()) do
      if line.text == "HELLO FROM HOST" then return true end
    end
    return false
  end, 60 * 30, "the host's chat line")
  check(heardHost, "the host's chat arrived")

  exports.say("global", "HELLO FROM GUEST")
  log("said hello")
  U.wait(180)

  U.wait(120)
  log("RESULT " .. failures .. " failure(s)")
  log("DONE")
end
