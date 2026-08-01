-- A Net-shaped view of one peer, tunnelled through the hub.
--
-- src/link/LinkBattle.lua touches exactly five things on the object it is
-- handed: send, poll, update, close, and .closed.  src/link/Protocol.lua's
-- TradeSession touches none of them -- it is fed messages by its caller.
-- So a table answering those five is a complete stand-in, and the engine's
-- own trade and battle logic runs over this mod's hub without knowing it.
--
-- That is the same property Net.lua already claims for its two backends
-- ("LinkState/LinkBattle/Protocol don't know or care which backend is in
-- play"); this is a third backend, living in a mod.
--
-- Messages go out wrapped in an mmo.relay envelope addressed to the peer,
-- and arrive by the hub handing them to :deliver().  What travels inside
-- the envelope is the engine's own vocabulary -- hello, party, pick,
-- confirm, action, event -- completely unmodified.

local need = ...
local Wire = need("Wire")

local M = {}
M.__index = M

function M.new(transport, peerId, peerName)
  return setmetatable({
    transport = transport,
    peerId = peerId,
    peerName = peerName,
    inbox = {},
    closed = false,
    -- LinkBattle never reads this, but LinkState-shaped code does, and a
    -- session only ever exists once the hub has matched two players
    paired = true,
    error = nil,
  }, M)
end

function M:send(msg)
  if self.closed then return end
  if not self.transport:send(Wire.RELAY, { to = self.peerId, payload = msg }) then
    self.closed = true
  end
end

-- called by Sessions when an mmo.relay addressed to us arrives
function M:deliver(payload)
  if self.closed then return end
  self.inbox[#self.inbox + 1] = payload
end

function M:poll()
  local msgs = self.inbox
  self.inbox = {}
  return msgs
end

-- The hub connection is pumped once per tick by the client, so there is
-- nothing to pump here.  What this does own is noticing that the transport
-- underneath went away: a battle whose hub connection dropped has to end,
-- and LinkBattle watches .closed to do it.
function M:update()
  if not self.transport:isReady() then self.closed = true end
end

function M:close()
  if self.closed then return end
  self.closed = true
  self.transport:send(Wire.SESSION_LEAVE, { to = self.peerId })
end

return M
