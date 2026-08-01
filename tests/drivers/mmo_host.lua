-- Driver: host a game from inside the game, hosting side.
--
-- Pair with tests/drivers/mmo_join.lua in a second instance; the wrapper
-- script run-mmo-e2e.sh launches both and greps the MMO_HOST: / MMO_JOIN:
-- lines these print.
--
-- This is the half of the mod the headless suites structurally cannot
-- reach: a real luasocket listener, the real accept loop, the real menus
-- being navigated, and avatars spawned by an actual remote player. Every
-- assertion below is about something no unit test can see.
--
--   POKEPORT_IDENTITY=mmohost POKEPORT_DRIVER=mods/rby_mmo/tests/drivers/mmo_host.lua love .

return function(game)
  local H = dofile("mods/rby_mmo/tests/drivers/mmo_util.lua")
  local U = H.U
  local TAG = "MMO_HOST:"
  local ADDR_FILE = os.getenv("MMO_ADDR_FILE") or "/tmp/rby_mmo_addr.txt"
  local SHOT_DIR = os.getenv("SHOT_DIR") or "/tmp/rby_mmo_shots"
  local LIMIT = tonumber(os.getenv("MMO_LIMIT") or "") or 2

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

  os.remove(ADDR_FILE)

  U.newGame(game)
  -- U.newGame mashes A through the naming grid, so both sides would
  -- otherwise be called AAAAAAA and no roster assertion could tell
  -- them apart. Name them here instead.
  if game.save and game.save.player then
    game.save.player.name = "HOSTY"
  end
  log("in the overworld as HOSTY")

  local exports = H.requireMod(game, TAG)
  if not exports then
    log("RESULT 1 failure(s)")
    return
  end
  if exports.traceAvatars then exports.traceAvatars(true) end
  check(exports.isConnected() == false, "starts disconnected")
  check(exports.isHosting() == false, "starts not hosting")

  -- ------- host, through the real menus

  if not H.openMmo(game) then
    log("FAIL could not reach the MMO menu")
    log("RESULT 1 failure(s)")
    return
  end
  check(true, "the MMO row exists on the START menu")

  if not H.selectLabel(game, "HOST GAME") then
    log("FAIL no HOST GAME row")
    log("RESULT " .. (failures + 1) .. " failure(s)")
    return
  end

  -- QuantityBox starts at the saved/default limit and steps by one; walk it
  -- down to LIMIT so the cap under test is the one this run chose
  U.wait(15)
  local box = H.top(game)
  check(box ~= nil and box.qty ~= nil, "the limit picker opened")
  if box and box.qty then
    local guard = 0
    while box.qty > LIMIT and guard < 80 do
      U.tap(game, "down")
      U.wait(2)
      guard = guard + 1
    end
    check(box.qty == LIMIT, "the limit reads " .. LIMIT)
  end
  U.shot(game, SHOT_DIR .. "/host-limit.png")
  U.tap(game, "a")
  U.wait(30)

  -- ------- the listener is real

  local hosting = H.waitFor(game, function() return exports.isHosting() end,
                            240, "the listener to come up")
  check(hosting, "hosting started (a real socket is bound)")
  if not hosting then
    log("RESULT " .. failures .. " failure(s)")
    return
  end
  U.shot(game, SHOT_DIR .. "/host-address.png")

  local address = exports.hostAddress and exports.hostAddress() or nil
  check(type(address) == "string" and address:find(":"),
        "an address is published: " .. tostring(address))

  -- the host is a player on its own hub, over loopback
  local joinedSelf = H.waitFor(game, function() return exports.isConnected() end,
                               240, "the host to join its own game")
  check(joinedSelf, "the host joined its own game over loopback")

  -- close the menus so the overworld is on top when the guest arrives
  for _ = 1, 4 do U.tap(game, "b") U.wait(8) end

  -- The guest connects to 127.0.0.1; the LAN address is what a human would
  -- read aloud, so publish both and let the joiner pick.
  local handle = io.open(ADDR_FILE, "w")
  if handle then
    handle:write(tostring(address) .. "\n")
    handle:close()
  end
  log("hosting", tostring(address), "limit", LIMIT)

  -- ------- a real remote player shows up

  local sawGuest = H.waitFor(game, function()
    return #exports.players() > 0
  end, 60 * 150, "the guest to connect")
  check(sawGuest, "a remote player joined over a real socket")

  if sawGuest then
    local guest = exports.players()[1]
    log("guest is", tostring(guest.name), "on", tostring(guest.map))
    check(type(guest.name) == "string" and guest.name ~= "",
          "the guest has a name on the roster")
    U.wait(120)
    U.shot(game, SHOT_DIR .. "/host-sees-guest.png")

    -- presence: the guest walks, and the host's roster follows
    local before = exports.players()[1]
    local startX, startY = before.x, before.y
    local moved = H.waitFor(game, function()
      local now = exports.players()[1]
      return now and (now.x ~= startX or now.y ~= startY)
    end, 60 * 20, "the guest to move")
    check(moved, "the guest's movement reaches the host")

    -- The roster moving proves the wire works. Whether the *avatar* moved
    -- is a separate question, and the one the screenshots answer badly --
    -- so read both and compare, rather than trusting a passing roster
    -- assertion to mean the world looks right.
    U.wait(90)
    local followed = false
    for _ = 1, 60 do
      local rows = exports.avatarState()
      local row = rows and rows[1]
      if row then
        log(("avatar: spawned=%s roster=(%s,%s) avatar=(%s,%s) map=%s/%s")
          :format(tostring(row.spawned), tostring(row.rosterX),
                  tostring(row.rosterY), tostring(row.avatarX),
                  tostring(row.avatarY), tostring(row.map),
                  tostring(row.avatarMap)))
        if row.spawned and row.avatarX == row.rosterX
           and row.avatarY == row.rosterY then
          followed = true
          break
        end
      else
        log("avatar: no roster rows")
      end
      U.wait(30)
    end
    check(followed, "the avatar caught up to where the network says it is")
    U.shot(game, SHOT_DIR .. "/host-guest-moved.png")

    -- chat, in the direction the unit tests cannot see: over the wire
    exports.say("global", "HELLO FROM HOST")
    log("said hello")
    U.wait(180)
  end

  -- ------- teardown

  U.wait(90)
  log("RESULT " .. failures .. " failure(s)")
  log("DONE")
end
