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
  local events = H.captureEvents({ "battle.started", "battle.ended", "link.desync" })
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
  -- A trade needs something to trade. Distinct species per side is what
  -- makes "the trade happened" checkable rather than a matter of faith.
  local Pokemon = require("src.pokemon.Pokemon")
  game.save.party = { Pokemon.new(game.data, "CHARIZARD", 50) }
  -- so the driven battle actually resolves; see frontloadDamage
  local lead = H.frontloadDamage(game.data, game.save.party[1])
  log("in the overworld as HOSTY with", table.concat(H.partySpecies(game), ","),
      "leading with", tostring(lead))

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
  H.closeToOverworld(game)

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
  end, 60 * 420, "the guest to connect")
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
    --
    -- Sampling starts immediately: the avatar catches up within a second,
    -- so any delay here lands entirely after it has arrived and the
    -- mid-step window is missed.
    -- cellOf reports pixel position in cells, so it is fractional mid-step;
    -- "arrived" is a tolerance, not equality
    local function at(a, b)
      return a ~= nil and b ~= nil and math.abs(a - b) < 0.01
    end

    local followed, sawWalking, samples = false, false, 0
    for _ = 1, 400 do
      local rows = exports.avatarState()
      local row = rows and rows[1]
      if row then
        if row.walking then sawWalking = true end
        samples = samples + 1
        if samples % 25 == 1 then
          log(("avatar: spawned=%s roster=(%s,%s) avatar=(%s,%s) walking=%s")
            :format(tostring(row.spawned), tostring(row.rosterX),
                    tostring(row.rosterY), tostring(row.avatarX),
                    tostring(row.avatarY), tostring(row.walking)))
        end
        if row.spawned and at(row.avatarX, row.rosterX)
           and at(row.avatarY, row.rosterY) then
          followed = true
        end
      end
      if followed and sawWalking then break end
      -- sampled finely: a step lasts 16 frames, so a coarse poll would
      -- miss the walking window entirely and report a false negative
      U.wait(4)
    end
    check(followed, "the avatar caught up to where the network says it is")
    check(sawWalking, "and was seen mid-step -- the walk actually animates")
    U.shot(game, SHOT_DIR .. "/host-guest-moved.png")

    -- ------- 2. the host's own movement reaches the guest
    --
    -- Only the guest can judge this, so the host walks between two markers
    -- and the guest asserts what it saw.

    H.signal("host_walk_start")
    -- Wait for the guest to take its baseline before moving. Signalling and
    -- walking immediately raced it: the guest could sample *after* the walk
    -- and then wait forever for a change that had already happened.
    H.await(game, "guest_baseline_taken")

    local wasAt = H.playerCell(game)
    -- left/right rather than down: Red's bedroom is small and a few tiles
    -- south runs into furniture, which would make "the host did not move"
    -- a map-geometry result rather than a networking one
    for _ = 1, 2 do
      U.hold(game, "left", 22)
      U.wait(8)
    end
    U.hold(game, "right", 22)
    U.wait(8)
    local nowAt = H.playerCell(game)
    log(("host walked (%s,%s) -> (%s,%s)"):format(
      tostring(wasAt and wasAt.x), tostring(wasAt and wasAt.y),
      tostring(nowAt and nowAt.x), tostring(nowAt and nowAt.y)))
    check(nowAt and wasAt and (nowAt.x ~= wasAt.x or nowAt.y ~= wasAt.y),
          "the host's own player actually moved")
    H.signal("host_walk_done")

    -- ------- 3. chat both ways

    exports.say("global", "HELLO FROM HOST")
    log("said hello")
    local heardGuest = H.waitFor(game, function()
      for _, line in ipairs(exports.chat()) do
        if line.text == "HELLO FROM GUEST" then return true end
      end
      return false
    end, 60 * 60, "the guest's chat line")
    check(heardGuest, "the guest's chat reached the host")

    -- ------- 1. the guest leaves the map, and comes back
    --
    -- A remote player on another map must not be drawn on this one; the
    -- roster keeps them, the avatar does not.

    H.await(game, "guest_left_map")
    local despawned = H.waitFor(game, function()
      local row = H.avatarRow(exports)
      return row ~= nil and row.spawned == false
    end, 60 * 40, "the avatar to despawn")
    check(despawned, "a player who leaves the map loses their avatar")
    local stillListed = #exports.players() > 0
    check(stillListed, "but stays on the roster")
    H.signal("host_saw_despawn")

    H.await(game, "guest_back_on_map")
    local respawned = H.waitFor(game, function()
      local row = H.avatarRow(exports)
      return row ~= nil and row.spawned == true
    end, 60 * 40, "the avatar to come back")
    check(respawned, "and gets it back on returning to the map")
    U.shot(game, SHOT_DIR .. "/host-guest-returned.png")

    -- ------- 4. hold still so the guest can interact
    --
    -- The guest teleports next to this cell and presses A; the host just
    -- has to be somewhere known and stay there.

    H.signal("host_ready_for_interact")
    H.await(game, "guest_interact_done")
    U.shot(game, SHOT_DIR .. "/host-after-interact.png")

    -- ------- 5. a real trade, run to completion over the wire
    --
    -- The guest asks; this side gets "GUESTY wants to trade!", the party
    -- picker, and the confirm. Both sides answer whatever is in front of
    -- them until the party actually changes.

    H.await(game, "guest_trade_requested")
    local wanted = "PIKACHU"
    local traded = H.drivePrompts(game, function()
      return H.partySpecies(game)[1] == wanted
    end, 60 * 90)
    log("host party now:", table.concat(H.partySpecies(game), ","))
    check(traded, "the host received the guest's " .. wanted)
    U.shot(game, SHOT_DIR .. "/host-after-trade.png")
    H.signal("host_trade_done")

    -- ------- 6. a real link battle, run to a decision
    --
    -- This is the engine's own LinkBattle -- the lockstep simulation a
    -- cable link runs -- carried over this mod's hub by SessionNet. The
    -- assertions are on engine events rather than on anything this mod
    -- reports, and link.desync is the one that matters: two games
    -- disagreeing mid-battle is exactly what lockstep exists to prevent.

    H.await(game, "guest_battle_requested", 60 * 90)
    local started = H.drivePrompts(game, function()
      return events["battle.started"] > 0
    end, 60 * 60)
    check(started, "a link battle started on the host")

    local ended = H.drivePrompts(game, function()
      return events["battle.ended"] > 0
    end, 60 * 240)
    check(ended, "and ran to a decision")
    check(events["link.desync"] == 0, "with no desync reported")
    log(("battle events: started=%d ended=%d desync=%d"):format(
      events["battle.started"], events["battle.ended"], events["link.desync"]))
    U.shot(game, SHOT_DIR .. "/host-after-battle.png")
    H.signal("host_battle_done")

    -- ------- 7. the address stays re-viewable for as long as the game is up
    --
    -- It is read out once when hosting starts and then scrolls away, so the
    -- only thing that matters is being able to get it back.

    H.closeToOverworld(game)
    local address = exports.hostAddress()
    if H.openMmo(game) and H.selectLabel(game, "ADDRESS") then
      U.wait(30)
      local shown = H.textOf(H.top(game))
      log("address screen reads:", shown)
      check(shown:find(tostring(address), 1, true) ~= nil,
            "the address can be re-viewed from the MMO menu")
      U.shot(game, SHOT_DIR .. "/host-address-recheck.png")
    else
      check(false, "no ADDRESS row while hosting")
    end
    H.closeToOverworld(game)
    H.signal("host_address_checked")

    -- ------- 8. and the guest leaving is seen here

    H.await(game, "guest_left_game", 60 * 120)
    local gone = H.waitFor(game, function()
      return #exports.players() == 0
    end, 60 * 40, "the guest to drop off the roster")
    check(gone, "a guest who leaves drops off the host's roster")
    check(exports.isHosting(), "and the host is still hosting afterwards")
  end

  -- ------- teardown

  U.wait(90)
  log("RESULT " .. failures .. " failure(s)")
  log("DONE")
end
