-- Trade and battle between two players, anywhere in the world.
--
-- Almost nothing about trading or link battling is reimplemented here.  The
-- engine already owns both: Protocol.TradeSession is a symmetric trade
-- state machine (including trade evolutions and the OT bookkeeping that
-- marks a mon as traded), and LinkBattle is a full lockstep battle.  Both
-- are driven over a SessionNet, so what this module actually does is:
--
--   * carry a request from one player to another through the hub,
--   * run the engine's own hello/verdict handshake between the two peers,
--   * hand the resulting session to the engine's machinery,
--   * and tear it down when either side leaves.
--
-- Running the real handshake matters.  It is what decides whether two
-- players with different mod sets may battle at all, and it produces the
-- `strict` and `verdict` values the trade and battle code need to refuse a
-- mon the other game would rebuild differently.  Skipping it and hardcoding
-- "full" would silently desync two differently-modded players.

local need, mod = ...
local Wire = need("Wire")
local SessionNet = need("SessionNet")

local M = {}
M.__index = M

local linkModules, linkTried

-- Loaded on demand: a player who never trades or battles should not drag
-- the link stack in, and a headless validate never touches it at all.
local function link()
  if linkTried then return linkModules end
  linkTried = true
  local ok, protocol = pcall(require, "src.link.Protocol")
  local okH, handshake = pcall(require, "src.link.Handshake")
  local okB, battle = pcall(require, "src.link.LinkBattle")
  if ok and okH and okB then
    linkModules = { Protocol = protocol, Handshake = handshake, Battle = battle }
  else
    mod.log:error("the engine's link modules are unavailable; trading and "
      .. "battling are off for this session -- chat and presence still work")
  end
  return linkModules
end

function M.new(transport, ui)
  return setmetatable({
    transport = transport,
    ui = ui,
    active = nil,      -- the one live session; two at once is never valid
    outgoing = nil,    -- { to, kind } while waiting for an answer
    incoming = nil,    -- { from, name, kind } while the prompt is up
  }, M)
end

function M:isBusy()
  return self.active ~= nil or self.outgoing ~= nil
end

-- ------- requests

function M:request(peer, kind)
  if self:isBusy() then
    self.ui:say("You're already busy\nwith someone.")
    return false
  end
  self.outgoing = { to = peer.id, kind = kind, name = peer.name }
  self.transport:send(Wire.REQUEST, { to = peer.id, kind = kind })
  self.ui:say(("Asked %s to\n%s."):format(peer.name,
    kind == "trade" and "trade" or "battle"))
  return true
end

function M:onRequest(game, msg)
  local from = Wire.id(msg.from)
  local name = Wire.name(msg.name)
  local kind = Wire.KINDS[msg.kind] and msg.kind or nil
  if not (from and name and kind) then return end

  -- Busy is answered immediately rather than queued: a prompt that appears
  -- minutes later, over whatever the player is doing by then, is worse than
  -- a refusal the asker can act on now.
  if self:isBusy() then
    self.transport:send(Wire.RESPOND, { to = from, kind = kind, accept = false })
    return
  end

  self.incoming = { from = from, name = name, kind = kind }
  self.ui:confirm(game,
    ("%s wants to\n%s!"):format(name, kind == "trade" and "trade" or "battle"),
    function(yes)
      local pending = self.incoming
      self.incoming = nil
      if not pending then return end
      self.transport:send(Wire.RESPOND,
        { to = pending.from, kind = pending.kind, accept = yes and true or false })
    end)
end

function M:onDecline(msg)
  local name = Wire.name(msg.name) or "They"
  self.outgoing = nil
  self.ui:say(("%s said no."):format(name))
end

-- ------- session lifecycle

function M:onSession(game, msg)
  local peerId = Wire.id(msg.peer)
  local peerName = Wire.name(msg.peerName) or "FRIEND"
  local kind = Wire.KINDS[msg.kind] and msg.kind or nil
  local role = (msg.role == "host" or msg.role == "guest") and msg.role or nil
  if not (peerId and kind and role) then return end

  self.outgoing = nil
  local modules = link()
  if not modules then return end

  local net = SessionNet.new(self.transport, peerId, peerName)
  self.active = {
    peerId = peerId,
    peerName = peerName,
    kind = kind,
    role = role,
    net = net,
    stage = "handshake",
  }

  -- the engine's own hello, unmodified: same fingerprint, same mod list,
  -- same verdict rules as a cable-club link
  local myHello = modules.Handshake.hello(game, kind)
  self.active.myHello = myHello
  net:send(myHello)
end

function M:onRelay(msg)
  local session = self.active
  if not session then return end
  if Wire.id(msg.from) ~= session.peerId then return end
  if type(msg.payload) ~= "table" then return end
  session.net:deliver(msg.payload)
end

function M:onSessionEnd(reason)
  local session = self.active
  self.active = nil
  self.outgoing = nil
  if not session then return end
  session.net.closed = true
  if reason == "peer_left" then
    self.ui:say(("%s disconnected."):format(session.peerName))
  end
end

function M:endSession(message)
  local session = self.active
  self.active = nil
  if session then session.net:close() end
  if message then self.ui:say(message) end
end

-- ------- the handshake, then the handoff

function M:beginTrade(game, session, modules)
  if not modules.Handshake.tradeAllowed(session.verdict) then
    return self:endSession("You can't trade\nwith that game.")
  end
  session.trade = modules.Protocol.TradeSession.new(game.data, game.save.party, {
    subset = session.verdict == "subset",
    strict = modules.Handshake.strict(session.verdict),
    peerName = session.peerName,
  })
  session.stage = "trade"
  session.net:send(session.trade:opening())
end

function M:beginBattle(game, session, modules)
  if not modules.Handshake.battleAllowed(session.verdict) then
    return self:endSession("Link battle needs\nthe same mods on\nboth games.")
  end
  session.stage = "battleWait"
  session.myParty = modules.Protocol.packParty(game.save.party)
  -- the host deals the shared seed the lockstep simulation runs on
  if session.role == "host" and love and love.math then
    session.seed = love.math.random(1, 2 ^ 30)
  end
  session.net:send({ type = "party", mons = session.myParty, seed = session.seed })
end

function M:handleHandshake(game, session, msg, modules)
  if msg.type ~= "hello" then return end
  session.theirHello = msg
  local verdict = modules.Handshake.checkCompat(session.myHello, msg)
  session.verdict = verdict
  if session.kind == "trade" then
    self:beginTrade(game, session, modules)
  else
    self:beginBattle(game, session, modules)
  end
end

function M:handleBattleWait(game, session, msg, modules)
  if msg.type ~= "party" then return end
  session.theirParty = msg.mons
  if session.role == "guest" then session.seed = session.seed or msg.seed end
  if not (session.myParty and session.theirParty and session.seed) then return end

  local constructor = session.role == "host"
    and modules.Battle.newHost or modules.Battle.newGuest
  local state, err = constructor(game, session.net, {
    theirName = session.peerName,
    verdict = session.verdict,
    strict = modules.Handshake.strict(session.verdict),
    myParty = session.myParty,
    theirParty = session.theirParty,
    seed = session.seed,
  })
  if not state then
    return self:endSession(err or "That battle can't\nstart.")
  end
  session.stage = "battle"
  -- the engine owns the battle from here; the mod only watches for the
  -- connection dying underneath it
  self.ui:pushState(game, state)
end

function M:handleTrade(game, session, msg)
  local reply = session.trade:handle(msg)
  if reply then session.net:send(reply) end
end

-- Drives the trade UI from the state machine's stage rather than from the
-- messages, so the prompt shown always matches what the machine will accept.
function M:advanceTrade(game, session)
  local trade = session.trade
  if not trade then return end

  if trade.stage == "picking" and not session.pickOpen then
    session.pickOpen = true
    self.ui:pickPartyMon(game, trade, function(index)
      session.pickOpen = false
      if not index then
        session.net:send({ type = "bye" })
        return self:endSession("The trade was\ncancelled.")
      end
      session.net:send(trade:pick(index))
    end)

  elseif trade.stage == "confirming" and not session.confirmOpen then
    session.confirmOpen = true
    local theirs = trade.theirParty and trade.theirParty[trade.theirPick]
    local label = theirs and tostring(theirs.species) or "their POKéMON"
    self.ui:confirm(game, ("Trade for\n%s?"):format(label), function(yes)
      session.confirmOpen = false
      session.net:send(trade:confirm(yes and true or false))
    end)

  elseif trade.stage == "done" and not session.applied then
    session.applied = true
    local ok, received = pcall(function() return trade:apply(game) end)
    if ok then
      local name = received and tostring(received.species) or "a POKéMON"
      self:endSession(("%s was\ntraded over!"):format(name))
    else
      self:endSession("The trade failed\nto complete.")
    end

  elseif trade.stage == "cancelled" and not session.applied then
    session.applied = true
    self:endSession(trade.error and ("The trade stopped:\n" .. trade.error)
      or "The trade was\ncancelled.")
  end
end

-- ------- per-tick

function M:update(game, dt)
  local session = self.active
  if not session then return end

  session.net:update()
  if session.net.closed and session.stage ~= "ended" then
    return self:endSession(("The link with %s\nwas lost."):format(session.peerName))
  end

  local modules = link()
  if not modules then return end

  -- Once the battle state is up it owns the inbox: LinkBattle polls the
  -- same SessionNet every frame, and draining it here first would consume
  -- the action/event messages the lockstep simulation is waiting on.
  if session.stage == "battle" then return end

  for _, msg in ipairs(session.net:poll()) do
    if type(msg) == "table" and type(msg.type) == "string" then
      if session.stage == "handshake" then
        self:handleHandshake(game, session, msg, modules)
      elseif session.stage == "battleWait" then
        self:handleBattleWait(game, session, msg, modules)
      elseif session.stage == "trade" then
        self:handleTrade(game, session, msg)
      end
    end
  end

  if session.stage == "trade" then self:advanceTrade(game, session) end
end

return M
