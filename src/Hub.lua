-- The hub, as pure logic.
--
-- This is the same relay `server/hub.js` implements, ported to Lua so a
-- player can host from inside the game. It owns who is connected, where
-- they last said they were, which two players are paired, and the player
-- cap the host chose. It does not simulate anything: trade and battle run
-- inside the two clients on the engine's own link code, and `mmo.relay`
-- payloads pass through unread.
--
-- **No sockets appear anywhere below.** Everything talks to *peer handles*
-- -- any table answering `:send(msg)` and `:close()`. `HostServer` supplies
-- socket-backed ones; the host's own client supplies an in-process one; the
-- suite supplies fakes. That is what lets the cap, the scope routing and
-- the session pairing be tested under plain luajit, which has no luasocket
-- and no LOVE.
--
-- Everything arriving here is untrusted -- it comes from another player's
-- process, and a modified one is a normal thing to meet -- so every field
-- is re-derived through Wire before it is believed.

local need = ...
local Config = need("Config")
local Wire = need("Wire")

local M = {}
M.__index = M

function M.new(opts)
  opts = opts or {}
  return setmetatable({
    limit = Config.clampPlayers(opts.maxPlayers),
    clients = {},     -- id -> client (greeted or not)
    count = 0,        -- connections
    players = 0,      -- of those, the ones that have said hello
    sessions = {},    -- sessionId -> { a, b, kind }
    nextId = 1,
    nextSession = 1,
    clock = 0,
  }, M)
end

-- Full means no room for another *player*. A connection that has not said
-- hello is not a player, and must not be able to hold a seat.
function M:isFull()
  return self.players >= self.limit
end

function M:pendingCount()
  return self.count - self.players
end

-- ------- plumbing

local function send(client, msgType, payload)
  if not client or not client.peer then return end
  local msg = {}
  if type(payload) == "table" then
    for k, v in pairs(payload) do msg[k] = v end
  end
  msg.type = msgType
  client.peer:send(msg)
end

local function presenceOf(client)
  return {
    id = client.id,
    name = client.name,
    sprite = client.sprite,
    map = client.map,
    x = client.x,
    y = client.y,
    facing = client.facing,
    busy = client.sessionId ~= nil,
  }
end

function M:broadcast(msgType, payload, exceptId)
  for id, client in pairs(self.clients) do
    if id ~= exceptId and client.ready then send(client, msgType, payload) end
  end
end

function M:refuse(peer, message)
  peer:send({ type = Wire.ERROR, message = message })
  peer:close()
end

-- Refuse someone who has a client record, and drop it in the same breath.
-- A connection turned away at hello will never become a player, so leaving
-- it in the table would hold a pending slot until the reaper came round.
function M:refuseClient(client, message)
  self:refuse(client.peer, message)
  self:drop(client)
end

-- ------- connection lifecycle

-- A peer that got this far has a socket (or a loopback) but has not said
-- hello yet, so it is not a player and does not appear on anyone's roster.
--
-- The player cap is therefore NOT applied here -- that is checked at hello.
-- Charging it on connect meant a peer that connected and said nothing held
-- a seat forever, so four silent sockets could lock everyone out of a
-- four-player game. What is bounded here is the number of un-greeted
-- connections, and update() reaps the ones that never introduce themselves.
function M:accept(peer)
  if self:pendingCount() >= Config.MAX_PENDING then
    self:refuse(peer, "Too many connections. Try again.")
    return nil
  end
  local client = {
    since = self.clock,
    id = tostring(self.nextId),
    peer = peer,
    ready = false,
    name = nil,
    sprite = Config.DEFAULT_SPRITE,
    map = nil, x = nil, y = nil, facing = "down",
    sessionId = nil,
    pendingTo = nil,
    lastChat = -math.huge,
  }
  self.nextId = self.nextId + 1
  self.clients[client.id] = client
  self.count = self.count + 1
  return client
end

function M:drop(client)
  if not client or not self.clients[client.id] then return false end
  self:endSession(client, "peer_left")
  self.clients[client.id] = nil
  self.count = self.count - 1
  if client.ready then self.players = self.players - 1 end
  -- an outstanding request pointed at a player who just left would let the
  -- asker wait forever for an answer nobody can give
  for _, other in pairs(self.clients) do
    if other.pendingTo == client.id then other.pendingTo = nil end
  end
  if client.ready then
    self:broadcast(Wire.PART, { id = client.id }, client.id)
  end
  return true
end

-- ------- sessions

function M:peerOf(client)
  local session = client.sessionId and self.sessions[client.sessionId]
  if not session then return nil end
  local otherId = session.a == client.id and session.b or session.a
  return self.clients[otherId]
end

function M:endSession(client, reason)
  local id = client.sessionId
  if not id then return end
  local session = self.sessions[id]
  self.sessions[id] = nil
  client.sessionId = nil

  if session then
    local otherId = session.a == client.id and session.b or session.a
    local other = self.clients[otherId]
    if other and other.sessionId == id then
      other.sessionId = nil
      send(other, Wire.SESSION_END, { reason = reason })
      self:broadcast(Wire.MOVE, presenceOf(other), other.id)
    end
  end
  if self.clients[client.id] then
    self:broadcast(Wire.MOVE, presenceOf(client), client.id)
  end
end

function M:startSession(a, b, kind)
  local id = tostring(self.nextSession)
  self.nextSession = self.nextSession + 1
  self.sessions[id] = { a = a.id, b = b.id, kind = kind }
  a.sessionId, b.sessionId = id, id

  -- The requester hosts. Someone has to deal the battle's shared RNG seed,
  -- and picking the side that asked keeps it deterministic rather than
  -- racing on who answers first.
  send(a, Wire.SESSION,
    { peer = b.id, peerName = b.name, kind = kind, role = "host", id = id })
  send(b, Wire.SESSION,
    { peer = a.id, peerName = a.name, kind = kind, role = "guest", id = id })

  self:broadcast(Wire.MOVE, presenceOf(a), a.id)
  self:broadcast(Wire.MOVE, presenceOf(b), b.id)
end

-- ------- handlers

local handlers = {}

handlers[Wire.HELLO] = function(self, client, msg)
  if client.ready then return end
  if Wire.int(msg.proto, 0, 9999) ~= Config.PROTOCOL then
    return self:refuseClient(client, ("This game speaks protocol %d; yours "
      .. "speaks %s."):format(Config.PROTOCOL, tostring(msg.proto)))
  end
  local name = Wire.name(msg.name)
  if not name then
    return self:refuseClient(client, "That trainer name can't be used here.")
  end
  -- the seat is claimed here, by someone who has identified themselves
  if self:isFull() then
    return self:refuseClient(client,
      ("This hub is full (%d players)."):format(self.limit))
  end

  client.name = name
  client.sprite = Wire.spriteId(msg.sprite) or Config.DEFAULT_SPRITE
  client.map = Wire.mapId(msg.map)
  client.x = Wire.int(msg.x, 0, 4096)
  client.y = Wire.int(msg.y, 0, 4096)
  client.facing = Wire.facing(msg.facing) or "down"
  client.ready = true
  self.players = self.players + 1

  local players = {}
  for id, other in pairs(self.clients) do
    if other.ready and id ~= client.id then
      players[#players + 1] = presenceOf(other)
    end
  end
  send(client, Wire.WELCOME, { id = client.id, players = players })
  self:broadcast(Wire.JOIN, { player = presenceOf(client) }, client.id)
end

handlers[Wire.MOVE] = function(self, client, msg)
  if not client.ready then return end
  local map = Wire.mapId(msg.map)
  local x, y = Wire.int(msg.x, 0, 4096), Wire.int(msg.y, 0, 4096)
  if map and x and y then
    client.map, client.x, client.y = map, x, y
  else
    -- no cell means "not in the world right now" (a battle, a menu): the
    -- player stays on the roster but stops being placeable
    client.map, client.x, client.y = nil, nil, nil
  end
  if Wire.facing(msg.facing) then client.facing = msg.facing end
  self:broadcast(Wire.MOVE, presenceOf(client), client.id)
end

handlers[Wire.CHAT] = function(self, client, msg)
  if not client.ready then return end
  local scope = Wire.SCOPES[msg.scope] and msg.scope or nil
  local text = Wire.text(msg.text, Config.MESSAGE_MAX)
  if not (scope and text) then return end

  if self.clock - client.lastChat < Config.CHAT_GATE then return end
  client.lastChat = self.clock

  local payload = { from = client.id, name = client.name,
                    scope = scope, text = text }

  if scope == "private" then
    local target = self.clients[Wire.id(msg.to) or ""]
    if target and target.ready then send(target, Wire.CHAT, payload) end
    return
  end

  if scope == "local" then
    if not client.map then return end
    for id, other in pairs(self.clients) do
      if id ~= client.id and other.ready and other.map == client.map then
        local distance = math.max(math.abs(other.x - client.x),
                                  math.abs(other.y - client.y))
        if distance <= Config.LOCAL_RADIUS then
          send(other, Wire.CHAT, payload)
        end
      end
    end
    return
  end

  self:broadcast(Wire.CHAT, payload, client.id)
end

handlers[Wire.REQUEST] = function(self, client, msg)
  if not client.ready or client.sessionId then return end
  local kind = Wire.KINDS[msg.kind] and msg.kind or nil
  local target = self.clients[Wire.id(msg.to) or ""]
  if not (kind and target and target.ready) or target.id == client.id then
    return
  end
  if target.sessionId then
    return send(client, Wire.DECLINE, { name = target.name, kind = kind })
  end
  client.pendingTo = target.id
  send(target, Wire.REQUEST,
    { from = client.id, name = client.name, kind = kind })
end

handlers[Wire.RESPOND] = function(self, client, msg)
  if not client.ready then return end
  local kind = Wire.KINDS[msg.kind] and msg.kind or nil
  local asker = self.clients[Wire.id(msg.to) or ""]
  if not (kind and asker and asker.ready) then return end

  -- only the player who was actually asked can answer, and only while the
  -- ask is still outstanding
  if asker.pendingTo ~= client.id then return end
  asker.pendingTo = nil

  if not msg.accept then
    return send(asker, Wire.DECLINE, { name = client.name, kind = kind })
  end
  if client.sessionId or asker.sessionId then
    return send(asker, Wire.DECLINE, { name = client.name, kind = kind })
  end
  self:startSession(asker, client, kind)
end

handlers[Wire.RELAY] = function(self, client, msg)
  if not client.ready or not client.sessionId then return end
  local peer = self:peerOf(client)
  if not peer then return end
  if Wire.id(msg.to) ~= peer.id then return end
  if not Wire.payloadOk(msg.payload) then return end
  -- The hub does not read the payload. It is the engine's own link
  -- vocabulary, and interpreting it here would couple this to a protocol
  -- the game already owns.
  send(peer, Wire.RELAY, { from = client.id, payload = msg.payload })
end

handlers[Wire.SESSION_LEAVE] = function(self, client)
  self:endSession(client, "peer_left")
end

handlers[Wire.PING] = function(self, client)
  send(client, Wire.PONG, {})
end

-- ------- entry points

function M:receive(client, msg)
  if not (client and self.clients[client.id]) then return end
  if type(msg) ~= "table" or type(msg.type) ~= "string" then return end
  local handler = handlers[msg.type]
  if handler then handler(self, client, msg) end
end

function M:update(dt)
  self.clock = self.clock + (dt or 0)

  -- Reap connections that never introduced themselves. Without this a peer
  -- can hold a slot indefinitely simply by saying nothing.
  local stale
  for _, client in pairs(self.clients) do
    if not client.ready
       and (self.clock - (client.since or 0)) > Config.HELLO_TIMEOUT then
      stale = stale or {}
      stale[#stale + 1] = client
    end
  end
  for _, client in ipairs(stale or {}) do
    if client.peer then
      client.peer:send({ type = Wire.ERROR, message = "Took too long to join." })
      client.peer:close()
    end
    self:drop(client)
  end
end

-- Tell everyone the game is over, then forget them. Called when the host
-- stops hosting or leaves: there is no host migration, so the honest thing
-- is to say so rather than leave clients talking to a dead listener.
function M:shutdown(message)
  for _, client in pairs(self.clients) do
    if client.peer then
      client.peer:send({
        type = Wire.ERROR,
        message = message or "The host ended the game.",
      })
      client.peer:close()
    end
  end
  self.clients, self.count, self.players, self.sessions = {}, 0, 0, {}
end

M.presenceOf = presenceOf

return M
