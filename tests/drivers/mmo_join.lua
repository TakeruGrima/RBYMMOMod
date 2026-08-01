-- Driver: join a hosted game, joining side.
--
-- Pair with tests/drivers/mmo_host.lua in a second instance. Waits for the
-- host to publish its address, then joins over a real socket, walks around
-- so the host has movement to observe, and checks the host shows up on this
-- side's roster too.
--
--   POKEPORT_IDENTITY=mmoguest POKEPORT_DRIVER=mods/rby_mmo/tests/drivers/mmo_join.lua love .

local function mod_current(game)
  local ow
  for i = #game.stack.states, 1, -1 do
    if game.stack.states[i].isOverworld then ow = game.stack.states[i] break end
  end
  ow = ow or game.overworld
  return { mapId = ow.map.id, x = ow.player.cellX, y = ow.player.cellY }
end

return function(game)
  local H = dofile("mods/rby_mmo/tests/drivers/mmo_util.lua")
  local U = H.U
  local TAG = "MMO_JOIN:"
  local ADDR_FILE = os.getenv("MMO_ADDR_FILE") or "/tmp/rby_mmo_addr.txt"
  local SHOT_DIR = os.getenv("SHOT_DIR") or "/tmp/rby_mmo_shots"

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

  U.newGame(game)
  -- U.newGame mashes A through the naming grid, so both sides would
  -- otherwise be called AAAAAAA and no roster assertion could tell
  -- them apart. Name them here instead.
  if game.save and game.save.player then
    game.save.player.name = "GUESTY"
  end
  local Pokemon = require("src.pokemon.Pokemon")
  game.save.party = { Pokemon.new(game.data, "PIKACHU", 30) }
  -- so the driven battle actually resolves; see frontloadDamage
  local lead = H.frontloadDamage(game.data, game.save.party[1])
  log("in the overworld as GUESTY with", table.concat(H.partySpecies(game), ","),
      "leading with", tostring(lead))

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

  -- ------- 2. the host's movement reaches this side
  --
  -- The mirror of the host's own check: the host is a player here like any
  -- other, and its avatar has to walk here too.

  H.await(game, "host_walk_start")
  local before = H.avatarRow(exports)
  local fromX, fromY = before and before.rosterX, before and before.rosterY
  log(("host baseline (%s,%s)"):format(tostring(fromX), tostring(fromY)))
  H.signal("guest_baseline_taken")
  H.await(game, "host_walk_done")

  local hostMoved = H.waitFor(game, function()
    local row = H.avatarRow(exports)
    return row and (row.rosterX ~= fromX or row.rosterY ~= fromY)
  end, 60 * 40, "the host to move on this side")
  check(hostMoved, "the host's movement reaches the guest")

  local hostAvatarFollowed = H.waitFor(game, function()
    local row = H.avatarRow(exports)
    return row and row.spawned
      and math.abs((row.avatarX or -99) - row.rosterX) < 0.01
      and math.abs((row.avatarY or -99) - row.rosterY) < 0.01
  end, 60 * 40, "the host's avatar to catch up")
  check(hostAvatarFollowed, "and its avatar walks to where the host is")
  U.shot(game, SHOT_DIR .. "/join-host-walked.png")

  -- ------- 3. chat crosses the wire in both directions

  local heardHost = H.waitFor(game, function()
    for _, line in ipairs(exports.chat()) do
      if line.text == "HELLO FROM HOST" then return true end
    end
    return false
  end, 60 * 60, "the host's chat line")
  check(heardHost, "the host's chat arrived")

  exports.say("global", "HELLO FROM GUEST")
  log("said hello")
  U.wait(60)

  -- ------- 1. leave the map and come back

  local home = mod_current(game)
  U.teleport(game, "PALLET_TOWN", 5, 6, "down")
  U.wait(60)
  log("left for PALLET_TOWN")
  H.signal("guest_left_map")

  H.await(game, "host_saw_despawn")
  U.teleport(game, home.mapId, home.x, home.y, "down")
  U.wait(60)
  log("back on " .. tostring(home.mapId))
  H.signal("guest_back_on_map")

  -- ------- 4. interact with the host, and get the trade/battle menu

  H.await(game, "host_ready_for_interact")
  local hostRow = H.avatarRow(exports)
  check(hostRow ~= nil and hostRow.rosterX ~= nil,
        "the host has a cell to stand next to")

  if hostRow and hostRow.rosterX then
    -- stand directly below the host and face up at them
    U.teleport(game, hostRow.map, hostRow.rosterX, hostRow.rosterY + 1, "up")
    U.wait(90)

    local facing = H.waitFor(game, function()
      local row = H.avatarRow(exports)
      return row and row.spawned
        and math.abs((row.avatarX or -99) - hostRow.rosterX) < 0.01
        and math.abs((row.avatarY or -99) - hostRow.rosterY) < 0.01
    end, 60 * 30, "the host's avatar to settle on its cell")
    check(facing, "the host's avatar is on the cell we are facing")

    U.shot(game, SHOT_DIR .. "/join-before-interact.png")
    U.tap(game, "a")
    U.wait(60)

    local top = H.top(game)
    local labels = {}
    for _, item in ipairs((top and top.items) or {}) do
      labels[#labels + 1] = tostring(item.label)
    end
    log("interact menu:", table.concat(labels, ","))

    local function has(want)
      for _, label in ipairs(labels) do
        if label == want then return true end
      end
      return false
    end

    check(#labels > 0, "pressing A on another player opens a menu")
    check(has("TRADE"), "the menu offers TRADE")
    check(has("BATTLE"), "the menu offers BATTLE")
    U.shot(game, SHOT_DIR .. "/join-interact-menu.png")

    -- ------- 5. take the menu up on it: a real trade, end to end
    --
    -- Everything past here runs the engine's own TradeSession over the
    -- hub: the party goes on the wire, both sides pick and confirm, and
    -- TradeSession:apply files the received mon. Nothing about the trade
    -- itself is this mod's code.

    H.signal("guest_interact_done")
    if H.selectLabel(game, "TRADE") then
      log("asked to trade")
      H.signal("guest_trade_requested")

      local wanted = "CHARIZARD"
      local traded = H.drivePrompts(game, function()
        return H.partySpecies(game)[1] == wanted
      end, 60 * 90)
      log("guest party now:", table.concat(H.partySpecies(game), ","))
      check(traded, "the guest received the host's " .. wanted)
      U.shot(game, SHOT_DIR .. "/join-after-trade.png")
      H.await(game, "host_trade_done", 60 * 60)

      -- ------- 6. and a real link battle, to a decision
      --
      -- Both sides now hold the mon the other traded over, so the battle
      -- also proves the traded party is what actually fights.

      H.closeToOverworld(game)
      U.wait(30)
      local reopened = false
      if H.top(game) == nil or H.top(game).isOverworld
         or H.top(game) == game.overworld then
        U.tap(game, "a")   -- still facing the host's avatar
        U.wait(45)
        reopened = H.classify(H.top(game)) == "menu"
      end
      check(reopened, "the interact menu opens again for a battle")

      if reopened and H.selectLabel(game, "BATTLE") then
        log("asked to battle")
        H.signal("guest_battle_requested")

        local started = H.drivePrompts(game, function()
          return events["battle.started"] > 0
        end, 60 * 60)
        check(started, "a link battle started on the guest")

        local ended = H.drivePrompts(game, function()
          return events["battle.ended"] > 0
        end, 60 * 240)
        check(ended, "and ran to a decision")
        check(events["link.desync"] == 0, "with no desync reported")
        log(("battle events: started=%d ended=%d desync=%d"):format(
          events["battle.started"], events["battle.ended"],
          events["link.desync"]))
        U.shot(game, SHOT_DIR .. "/join-after-battle.png")
        H.await(game, "host_battle_done", 60 * 120)

        -- ------- 7. leave the game and keep playing
        --
        -- Walking out of someone else's game is not quitting: the save,
        -- the world and the party are untouched, so single-player carries
        -- straight on. That last part is the whole point of the check --
        -- disconnecting cleanly is easy, staying playable afterwards is
        -- where a teardown bug would show.

        H.await(game, "host_address_checked", 60 * 120)
        H.closeToOverworld(game)
        if H.openMmo(game) and H.selectLabel(game, "LEAVE") then
          H.drivePrompts(game, function()
            return not exports.isConnected()
          end, 60 * 30)
          check(not exports.isConnected(), "LEAVE disconnects the guest")
          check(not exports.isHosting(), "without it having been the host")
          check(#exports.players() == 0, "and clears the roster")

          H.closeToOverworld(game)
          U.wait(20)
          local before = H.playerCell(game)
          for _, dir in ipairs({ "left", "right", "up", "down" }) do
            U.hold(game, dir, 22)
            U.wait(8)
            local now = H.playerCell(game)
            if now and before and (now.x ~= before.x or now.y ~= before.y) then
              break
            end
          end
          local after = H.playerCell(game)
          log(("after leaving: (%s,%s) -> (%s,%s)"):format(
            tostring(before and before.x), tostring(before and before.y),
            tostring(after and after.x), tostring(after and after.y)))
          check(after and before
                and (after.x ~= before.x or after.y ~= before.y),
                "and the world is still playable afterwards")
          check(#H.partySpecies(game) > 0, "with the party intact")
          U.shot(game, SHOT_DIR .. "/join-after-leaving.png")
        else
          check(false, "no LEAVE row while connected as a guest")
        end
        H.signal("guest_left_game")
      else
        check(false, "could not select BATTLE")
        H.signal("guest_battle_requested")
      end
    else
      check(false, "could not select TRADE")
      H.signal("guest_trade_requested")
    end
  else
    H.signal("guest_interact_done")
    H.signal("guest_trade_requested")
  end

  U.wait(60)
  log("RESULT " .. failures .. " failure(s)")
  log("DONE")
end
