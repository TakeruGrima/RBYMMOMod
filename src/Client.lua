-- Wiring: options, the hooks and events the mod subscribes to, and the
-- dispatch table that turns hub messages into state changes.
--
-- One rule runs through all of it: the mod never takes over a frame it does
-- not own.  Every hook calls next() and returns what the chain gave it, and
-- every per-tick cost is skipped outright when the player is not connected,
-- so an installed-but-offline copy of this mod is as close to absent as it
-- can be.

local need, mod = ...
local Config = need("Config")
local Wire = need("Wire")
local Sha256 = need("Sha256")
local Transport = need("Transport")
local Roster = need("Roster")
local Avatars = need("Avatars")
local Chat = need("Chat")
local Ui = need("Ui")
local Overlay = need("Overlay")
local Sessions = need("Sessions")
local World = need("World")
local HostServer = need("HostServer")
local Chars = need("Chars")

local M = {}

local ctx = {
  game = nil,
  roster = Roster.new(),
  chat = Chat.new(),
  avatars = Avatars.new(),
}

local transport = Transport.new()
local server = HostServer.new()
local ui = Ui.new(ctx)
local overlay = Overlay.new(ctx)
local sessions = Sessions.new(transport, ui)

ctx.client = M
ctx.ui = ui
ctx.sessions = sessions
ctx.server = server

local presenceClock = 0
local lastSent = { map = nil, x = nil, y = nil, facing = nil, busy = nil }

-- Which hub this connection is talking to, and whether its challenge has
-- already been answered.  Both belong to exactly one connection: an
-- mmo.error means "wrong join code" only when it lands after we answered a
-- challenge and before we were welcomed, and only the hub we dialled may be
-- offered the code stored for it.  nil while hosting -- the local net has no
-- address, so the host's own copy answers with the option row's code.
local dialled = nil
local authSent = false

-- ------- helpers

-- Every entry point below is reachable both ways: menu code calls
-- client:foo(x) and internal code calls M.foo(x). The colon form passes M
-- as the first argument, so anything taking a value has to shift it or the
-- value silently becomes the module table. Declared first because several
-- functions below close over it.
local function arg1(a, b)
  if a == M then return b end
  return a
end

function M.isConnected()
  return transport:isReady()
end

function M.isHosting()
  return server.running == true
end

-- what the host reads out to their friends, once hosting
function M.hostAddress()
  return server:address()
end

function M.hostLimit()
  return server:limit()
end

-- Settings that the player can change from inside the game.
--
-- mod.options is READ-ONLY to a mod -- the loader exposes define and get
-- and nothing else -- so the option row is the persisted *default*, edited
-- in the mod manager, and an in-game change is written to mod.save, which
-- mods may write and which persists with the save file. Reads prefer the
-- in-game value and fall back to the option.
function M.maxPlayers()
  local stored = mod.save:get("maxplayers")
  if stored ~= nil then return Config.clampPlayers(stored) end
  return Config.clampPlayers(mod.options:get("maxplayers"))
end

-- arg1 so the colon form the menus use (client:setMaxPlayers(n)) does not
-- land `self` in the value slot, where clampPlayers would quietly turn the
-- host's choice back into the default
function M.setMaxPlayers(a, b)
  local limit = Config.clampPlayers(arg1(a, b))
  mod.save:set("maxplayers", limit)
  return limit
end

function M.joinAddress()
  local stored = mod.save:get("hub")
  if type(stored) == "string" and stored ~= "" then return stored end
  local option = mod.options:get("hub")
  if type(option) == "string" and option ~= "" then return option end
  return Config.DEFAULT_HUB
end

function M.setJoinAddress(a, b)
  local address = arg1(a, b)
  if type(address) ~= "string" or address == "" then return nil end
  mod.save:set("hub", address)
  return address
end

-- Where a hub's join code is kept.
--
-- One key per hub, because a player who plays on two of them should not have
-- to retype either -- and because the code is a secret that belongs to one
-- hub: keying it to the address it was typed for is what stops one hub being
-- handed another's. The address is lower-cased and stripped of spaces so the
-- same hub, typed twice, is one key; nothing else is inferred from it (a
-- guessed default port would key a hub the transport never dials).
local function codeKey(address)
  if type(address) ~= "string" then return nil end
  local clean = address:lower():gsub("%s+", "")
  if clean == "" then return nil end
  return "code:" .. clean
end

-- The join code for a hub, normalised into the bytes the HMAC is keyed with.
--
-- No address means no per-hub code -- hosting, where the local net has no
-- address -- and falls through to the option row, which is the standing code
-- for a player who only ever plays on one hub. Same shape as joinAddress:
-- the in-game value wins, the option is the default.
function M.joinCode(a, b)
  local key = codeKey(arg1(a, b))
  local stored = key and mod.save:get(key)
  return Wire.code(stored) or Wire.code(mod.options:get("code"))
end

-- Stores the *normalised* form, never what was typed: the dashes, the case
-- and any punctuation that came with a pasted code are all noise the HMAC
-- key must not carry. Refuses anything that is not a code rather than
-- storing a half-code that would fail every challenge silently.
function M.setJoinCode(a, b, c)
  local address, value
  if a == M then address, value = b, c else address, value = a, b end
  local code = Wire.code(value)
  local key = codeKey(address)
  if not (code and key) then return nil end
  mod.save:set(key, code)
  return code
end

-- Put the player in front of the code screen.
--
-- Reached when a hub asks for a code we do not have, and when it refuses the
-- one we do. Either way the alternative is a connection that simply stops,
-- with nothing on screen to act on.
function M.askJoinCode(game, address, reconnect)
  game = game or ctx.game
  if not game then return false end
  mod.ui.push(game, Ui.SCREEN.JOINCODE, {
    address = address,
    connect = reconnect and true or false,
  })
  return true
end

-- The name other players see.
--
-- Separate from the save's trainer name on purpose: character creation lets
-- someone be "ASH" online without renaming their single-player file. It
-- falls back to the save name, so a player who never opens the creator is
-- still recognisable.
function M.playerName(game)
  local chosen = mod.save:get("name")
  if type(chosen) == "string" and chosen ~= "" then
    return Wire.name(chosen) or "PLAYER"
  end
  game = game or ctx.game
  local name = game and game.save and game.save.player and game.save.player.name
  return Wire.name(name) or "PLAYER"
end

function M.setPlayerName(a, b)
  local name = Wire.name(arg1(a, b))
  if not name then return nil end
  mod.save:set("name", name)
  return name
end

-- The character other players see you as. Resolved against this game's own
-- catalog, so a value carried over from a save made against a different ROM
-- degrades to RED instead of failing to draw.
function M.spriteChoice()
  local chosen = mod.save:get("sprite")
  if type(chosen) ~= "string" or chosen == "" then
    chosen = mod.options:get("sprite")
  end
  return Chars.resolve(chosen)
end

function M.setSpriteChoice(a, b)
  local id = arg1(a, b)
  if not Chars.available(id) then return nil end
  mod.save:set("sprite", id)
  return id
end

-- The trainer-card fields this player shows to others. Read from the save
-- at hello time, so it is a snapshot of who you were when you joined.
function M.profile(game)
  game = game or ctx.game
  local save = game and game.save
  if not save then return nil end
  local dex = save.pokedex or {}
  local seen, owned = 0, 0
  for _ in pairs(dex.seen or {}) do seen = seen + 1 end
  for _ in pairs(dex.owned or {}) do owned = owned + 1 end

  -- Badges are counted through the engine's own list rather than assumed to
  -- be the eight Kanto ones, so a mod that adds a badge is counted too.
  local badges = 0
  local ok = pcall(function()
    local Badges = require("src.inventory.Badges")
    badges = Badges.count(game.data, save) or 0
  end)
  if not ok then badges = 0 end

  -- Deliberately no money: the card does not show another player's wallet,
  -- so there is no reason to put it on the wire.
  return {
    idNo = tonumber(save.player and save.player.id) or 0,
    badges = badges,
    seen = seen,
    owned = owned,
    playtime = math.floor(tonumber(save.playtime) or 0),
  }
end

-- ------- your own look, in your own game
--
-- Choosing a character has to change what *you* see too, not just what
-- everyone else sees, or the creator reads as broken.
--
-- The overworld player takes its sheet from field.playerSprites at
-- Player.new time (src/world/Player.lua), so there is no option to flip
-- once the player exists -- the renderer has to be swapped on the live
-- object. The original is kept so leaving a game puts your own trainer
-- back, rather than leaving you dressed as a Rocket grunt in single-player.
local originalLook = nil

local function playerEntity()
  local world = mod.world
  local ow = world and world:overworld()
  return ow and ow.player or nil
end

function M.applyLook(game)
  local player = playerEntity()
  if not player then return false end
  local id = M.spriteChoice()
  local record = mod.content.sprites and mod.content.sprites:get(id)
  if not record then return false end

  local ok, renderer = pcall(function()
    local SpriteRenderer = require("src.render.SpriteRenderer")
    return SpriteRenderer.new(record, "player")
  end)
  if not (ok and renderer) then
    mod.log:warn("could not wear %s; staying as you are", tostring(id))
    return false
  end
  if originalLook == nil then originalLook = player.sprite end
  player.sprite = renderer
  return true
end

function M.restoreLook()
  local player = playerEntity()
  if player and originalLook ~= nil then player.sprite = originalLook end
  originalLook = nil
end

-- ------- connect / disconnect

function M.connect(a, b)
  local game = arg1(a, b) or ctx.game
  if not game then return false end
  if transport:isOpen() or M.isHosting() then
    ui:say("You're already in\na game.")
    return false
  end

  local address = M.joinAddress()
  local ok, err = transport:connect(address)
  if not ok then
    ui:say(tostring(err or "Couldn't connect."))
    return false
  end

  dialled, authSent = address, false
  M.sendHello(game)
  M.applyLook(game)
  return true
end

-- ------- hosting
--
-- Start a listener, then join it as an ordinary player over loopback. From
-- the moment the local net is attached, nothing downstream knows or cares
-- that this copy of the game is also the server: the host walks around,
-- chats, trades and battles through exactly the same client code a joining
-- player runs.
function M.host(a, b)
  local game = arg1(a, b) or ctx.game
  if not game then return false end
  if transport:isOpen() or M.isHosting() then
    ui:say("You're already in\na game.")
    return false
  end

  local limit = M.maxPlayers()
  local ok, err = server:start(Config.DEFAULT_PORT, limit)
  if not ok then
    ui:say(tostring(err or "Couldn't start hosting."))
    return false
  end

  local net, netErr = server:localNet()
  if not net then
    server:stop()
    ui:say(tostring(netErr or "Couldn't join your own game."))
    return false
  end

  transport:attach(net)
  dialled, authSent = nil, false
  M.sendHello(game)
  M.applyLook(game)
  return true
end

function M.stopHosting()
  if not M.isHosting() then return false end
  -- tear the local client down first, so the host leaves its own roster
  -- cleanly before the hub tells everyone else the game is over
  M.disconnect()
  server:stop("The host ended the game.")
  return true
end

-- The one hello, used by both paths -- a host and a joiner introduce
-- themselves identically, because to the hub they are the same thing.
function M.sendHello(game)
  local current = World.current()
  transport:send(Wire.HELLO, {
    proto = Config.PROTOCOL,
    name = M.playerName(game),
    sprite = M.spriteChoice(),
    profile = M.profile(game),
    map = current and current.mapId,
    x = current and current.x,
    y = current and current.y,
    facing = current and current.facing,
  })
end

function M.disconnect()
  M.restoreLook()
  sessions:endSession(nil)
  ctx.avatars:clear()
  ctx.roster:reset()
  ctx.chat:clear()
  transport:close()
  lastSent = { map = nil, x = nil, y = nil, facing = nil, busy = nil }
  dialled, authSent = nil, false
end

-- Leaving covers both shapes so callers never have to ask which they are:
-- a host stops the game for everyone, a guest just walks out.
function M.leave()
  if M.isHosting() then return M.stopHosting() end
  M.disconnect()
  return true
end

-- ------- outgoing chat

function M.say(a, b, c, d)
  local scope, text, to
  if a == M then scope, text, to = b, c, d else scope, text, to = a, b, c end
  if not transport:isReady() then return false end
  if not Wire.SCOPES[scope] then return false end

  local clean = Wire.text(text, Config.MESSAGE_MAX)
  if not clean then
    ui:say("Nothing to say.")
    return false
  end

  transport:send(Wire.CHAT, { scope = scope, to = to, text = clean })

  -- Echoed locally rather than waiting for the hub to reflect it back: the
  -- player should see their own line the instant they send it, and the hub
  -- does not echo (which would double every message).
  ctx.chat:push({
    name = M.playerName(ctx.game),
    scope = scope,
    text = clean,
    outgoing = true,
  })
  return true
end

-- ------- presence

local function presenceChanged(current, busy)
  local mapId = current and current.mapId
  local x = current and current.x
  local y = current and current.y
  local facing = current and current.facing
  return lastSent.map ~= mapId or lastSent.x ~= x or lastSent.y ~= y
    or lastSent.facing ~= facing or lastSent.busy ~= busy
end

local function pushPresence(force)
  if not transport:isReady() then return end
  local current = World.current()
  local busy = sessions:isBusy()
  if not force and not presenceChanged(current, busy) then return end

  lastSent = {
    map = current and current.mapId,
    x = current and current.x,
    y = current and current.y,
    facing = current and current.facing,
    busy = busy,
  }
  transport:send(Wire.MOVE, {
    map = lastSent.map,
    x = lastSent.x,
    y = lastSent.y,
    facing = lastSent.facing,
    busy = busy,
  })
end

-- ------- inbound dispatch

local handlers = {}

-- The hub wants a join code before it will let anyone in.
--
-- It sends a nonce; the answer is an HMAC of that nonce keyed by the code,
-- so the code itself never crosses the wire -- a capture cannot be replayed
-- (the nonce is single-use) and cannot be turned back into the code. The
-- exact contract is mirrored by server/lib/auth.js: key is the normalised
-- code as ASCII, message is the nonce as its lowercase-hex *string*, and a
-- drift in either reaches the player as nothing but "wrong join code".
--
-- A hub with no code configured never sends this, so an unauthenticated
-- game is the exchange it always was.
handlers[Wire.CHALLENGE] = function(game, msg)
  -- the hub is a stranger's process like every other peer, so its framing
  -- is checked exactly as hard as a player's
  local nonce = Wire.hex(msg.nonce, Config.NONCE_HEX)
  if not nonce then
    mod.log:warn("the hub sent a challenge we cannot read; ignoring it -- if "
      .. "joining keeps failing, the hub is running a different build")
    return
  end

  local address = dialled
  local code = M.joinCode(address)
  if not code then
    -- Nothing to answer with. Hang up first: the hub gives an answer ten
    -- seconds (Config.AUTH_TIMEOUT) and typing sixteen characters on a d-pad
    -- is not ten seconds, so holding the socket open only buys the player a
    -- connection that dies behind the screen they are still typing on.
    M.disconnect()
    ui:say("This game needs a\njoin code.", function()
      M.askJoinCode(game, address, address ~= nil)
    end)
    return
  end

  local response, why = Sha256.hmacHex(code, nonce)
  if not response then
    -- `why` names the argument, never its value: the code does not go to the
    -- log, here or anywhere else
    mod.log:warn("could not answer the hub's challenge (%s) -- re-enter the "
      .. "code from START > MMO > JOIN CODE", tostring(why))
    M.disconnect()
    ui:say("Couldn't answer\nthis game's code.")
    return
  end

  authSent = true
  transport:send(Wire.AUTH, { response = response })
end

handlers[Wire.WELCOME] = function(game, msg)
  local id = Wire.id(msg.id)
  if not id then
    transport:fail("the hub sent a malformed welcome")
    return
  end
  ctx.roster:reset()
  ctx.roster:setSelf(id)
  for _, raw in ipairs(msg.players or {}) do
    ctx.roster:put(Wire.presence(raw))
  end
  transport:markReady()
  pushPresence(true)
  -- Deliberately not a text box. ui:say pushes a modal that sits over the
  -- world until someone presses A, and a routine status line is not worth
  -- interrupting play for -- the first real run left "Connected." covering
  -- the bottom third of the screen for the whole session. The player count
  -- is already on the MMO menu's PLAYERS row, which is where someone who
  -- cares will look. Errors still get a box; this does not.
  mod.log:info("connected -- %d other player(s) on", ctx.roster.count)
end

handlers[Wire.JOIN] = function(_, msg)
  local presence = Wire.presence(msg.player)
  if presence then ctx.roster:put(presence) end
end

handlers[Wire.PART] = function(_, msg)
  local id = Wire.id(msg.id)
  if not id then return end
  ctx.roster:remove(id)
  ctx.avatars:despawn(id)
end

handlers[Wire.MOVE] = function(_, msg)
  local id = Wire.id(msg.id)
  if not id then return end
  local map = Wire.mapId(msg.map)
  local x, y = Wire.int(msg.x, 0, 4096), Wire.int(msg.y, 0, 4096)
  local facing = Wire.facing(msg.facing)
  ctx.roster:setBusy(id, msg.busy)
  if map and x and y then
    ctx.roster:move(id, map, x, y, facing)
  else
    -- no cell: the player is in a battle or a menu, so they leave the world
    -- without leaving the roster
    ctx.roster:move(id, nil, nil, nil, facing)
    ctx.avatars:despawn(id)
  end
end

handlers[Wire.CHAT] = function(_, msg)
  local from = Wire.id(msg.from)
  local name = Wire.name(msg.name)
  local text = Wire.text(msg.text, Config.MESSAGE_MAX)
  local scope = Wire.SCOPES[msg.scope] and msg.scope or nil
  if not (name and text and scope) then return end
  ctx.chat:push({ from = from, name = name, scope = scope, text = text })
  if from then ctx.chat:bubble(from, text, scope) end
end

handlers[Wire.REQUEST] = function(game, msg) sessions:onRequest(game, msg) end
handlers[Wire.DECLINE] = function(_, msg) sessions:onDecline(msg) end
handlers[Wire.SESSION] = function(game, msg) sessions:onSession(game, msg) end
handlers[Wire.RELAY] = function(_, msg) sessions:onRelay(msg) end

handlers[Wire.SESSION_END] = function(_, msg)
  sessions:onSessionEnd(msg and msg.reason)
end

handlers[Wire.ERROR] = function(game, msg)
  local text = Wire.text(msg.message, 120) or "The hub refused the connection."
  -- A refusal that lands after we answered a challenge and before we were
  -- welcomed is the wrong join code, whatever sentence the hub chose to say
  -- it in -- so the hub's words are shown, and then the code screen, rather
  -- than a refusal with nowhere to go from. The stored code is kept: a typo
  -- is likelier than a rotated code, and clearing it would cost the player
  -- the one they had.
  local wrongCode = authSent and not transport:isReady()
  local address = dialled
  transport:fail(text)
  if wrongCode then
    ui:say(text, function() M.askJoinCode(game, address, address ~= nil) end)
  else
    ui:say(text)
  end
end

-- ------- the tick

local function tick(game, dt)
  ctx.game = game
  dt = dt or 0

  -- The server pumps first. Reading sockets and running the hub is what
  -- fills the host's own loopback inbox, so doing it after the client poll
  -- would put every hosted message one tick behind.
  if server.running then server:update(dt) end

  if not transport:isOpen() then return end

  for _, msg in ipairs(transport:update(dt)) do
    local handler = handlers[msg.type]
    if handler then handler(game, msg) end
  end

  -- a failure surfaced inside update (timeout, socket error) tears the
  -- world state down so nothing is left drawn over a dead connection
  if not transport:isOpen() then
    if transport.error then ui:say(tostring(transport.error)) end
    ctx.avatars:clear()
    ctx.roster:reset()
    return
  end

  if not transport:isReady() then return end

  ctx.chat:update(dt)
  sessions:update(game, dt)

  presenceClock = presenceClock + dt
  if presenceClock >= Config.PRESENCE_INTERVAL then
    presenceClock = 0
    pushPresence(false)
  end

  ctx.avatars:sync(ctx.roster, World.current())
end

-- ------- install

function M.install()
  local spriteChoices = {}
  for _, row in ipairs(Config.SPRITES) do
    spriteChoices[#spriteChoices + 1] = { row[1], row[2] }
  end

  mod.options:define({
    -- The cap the host picks. min/max make the row itself refuse anything
    -- outside 2..64, so the clamp in Config is a backstop against a hand
    -- edited options file rather than the only guard.
    { key = "maxplayers", label = "MAX PLAYERS", type = "number",
      default = Config.DEFAULT_PLAYERS,
      min = Config.MIN_PLAYERS, max = Config.MAX_PLAYERS, step = 1 },
    { key = "hub", label = "JOIN", type = "text", default = Config.DEFAULT_HUB },
    -- The standing join code, so it can be seen and changed deliberately
    -- rather than only when a hub happens to ask for it. A code typed for a
    -- particular hub is stored against that hub (see M.joinCode); this row
    -- is the fallback, and the one a player who only ever plays on one hub
    -- ever needs. maxLen so the manager's own naming screen accepts a
    -- dashed code instead of cutting it at seven characters.
    { key = "code", label = "JOIN CODE", type = "text", default = "",
      maxLen = Config.CODE_ENTRY_MAX },
    { key = "sprite", label = "MY SPRITE", type = "choice",
      default = Config.DEFAULT_SPRITE, choices = spriteChoices },
    { key = "bubbles", label = "BUBBLES", type = "toggle", default = true },
  })

  ui:install()

  -- One game-logic tick.  This runs before queued button edges are
  -- promoted, which is the documented place for a tool that has to act once
  -- per fixed step rather than once per drawn frame.
  mod.hooks:wrap("input.step", function(next, game, dt)
    local ok, err = pcall(tick, game, dt)
    if not ok then
      mod.log:warn("multiplayer tick failed (%s); leaving the game to keep "
        .. "playing", tostring(err))
      pcall(M.leave)
    end
    return next(game, dt)
  end)

  mod.hooks:wrap("render.hud", function(next, game, viewport)
    local result = next(game, viewport)
    if mod.options:get("bubbles") ~= false then
      overlay:draw(game, viewport)
    end
    return result
  end)

  mod.hooks:wrap("ui.start_menu.items", function(next, game, items)
    local out = next(game, items)
    if type(out) ~= "table" then return out end
    return mod.ui.insertBefore(out, "SAVE", {
      label = "MMO",
      onSelect = function() mod.ui.push(game, Ui.SCREEN.MAIN) end,
    })
  end)

  -- A warp is the one movement the tile-by-tile presence stream cannot
  -- describe, so it is announced the moment it lands instead of waiting for
  -- the next interval.
  mod.events:on("player.warped", function() pushPresence(true) end)
  mod.events:on("map.entered", function()
    pushPresence(true)
    -- entering a map can rebuild the player, taking the chosen look with
    -- it; re-wearing it here is cheaper than watching for that
    if transport:isReady() then
      originalLook = nil
      M.applyLook(ctx.game)
    end
  end)

  -- Facing a remote player and pressing A opens the same menu the roster
  -- does.  The engine's talkTo has already run by this point and found
  -- nothing to say (these NPCs carry no text), so this adds the interaction
  -- rather than replacing one.
  mod.events:on("world.interacted", function(payload)
    if not (payload and payload.kind == "npc") then return end
    if not transport:isReady() then return end
    local player = ctx.roster:at(payload.mapId, payload.x, payload.y)
    if player and ctx.game then
      mod.ui.push(ctx.game, Ui.SCREEN.ACTIONS, { playerId = player.id })
    end
  end)

  -- Leaving to the title screen or loading another save must not leave a
  -- stale roster pointing at a world that is gone -- and if this copy was
  -- hosting, the listener has to come down with it rather than serving a
  -- world nobody is standing in.
  mod.events:on("save.loaded", function() M.leave() end)

  mod.exports.isConnected = M.isConnected
  mod.exports.isHosting = M.isHosting
  -- nil unless this copy is hosting; a mod that wants to show the address
  -- somewhere of its own should not have to reach into HostServer for it
  mod.exports.hostAddress = function() return M.isHosting() and server:address() end
  mod.exports.players = function() return ctx.roster:sorted() end
  mod.exports.say = function(scope, text, to) return M.say(scope, text, to) end
  -- newest last, same order the chat screen scrolls
  mod.exports.chat = function() return ctx.chat:recent() end
  -- Where each remote player is according to the roster, and where their
  -- avatar actually stands. The two diverging is the signature of the
  -- avatar layer falling behind the network, which is invisible from the
  -- roster alone -- the end-to-end driver reads this to tell the two apart.
  mod.exports.traceAvatars = function(on) Avatars.TRACE = on and true or false end
  mod.exports.overlayState = function() return overlay:state() end
  -- what this player looks like in their own game, for tests and for a mod
  -- that wants to know
  mod.exports.myLook = function() return M.spriteChoice() end
  mod.exports.avatarState = function()
    local out = {}
    for _, player in ipairs(ctx.roster:sorted()) do
      local ax, ay = ctx.avatars:cellOf(player.id)
      out[#out + 1] = {
        id = player.id, name = player.name, map = player.map,
        rosterX = player.x, rosterY = player.y,
        avatarX = ax, avatarY = ay,
        spawned = ctx.avatars.spawned[player.id] ~= nil,
        walking = ctx.avatars:isWalking(player.id),
        avatarMap = ctx.avatars.mapId,
      }
    end
    return out
  end
end

M.ctx = ctx
M.transport = transport

return M
