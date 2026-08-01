-- Every screen the mod puts on the stack.
--
-- All of them are registered in the `screens` registry and reached with
-- mod.ui.push, including the ones that only wrap a widget instance.  That
-- indirection is the point: pushing a state means touching game.stack,
-- which is engine internals, whereas Screens.push is the supported door and
-- takes its arguments straight through to the registered constructor.  So a
-- one-line screen like RbyMmoState -- whose whole job is to hand back a
-- state somebody else built -- buys the mod a supported way to show it.
--
-- Widgets come from mod.ui (the shared toolkit facade), never from a
-- private require.

local need, mod = ...
local Config = need("Config")
local Chat = need("Chat")
local World = need("World")

local M = {}
M.__index = M

local SCREEN = {
  TEXT     = "RbyMmoText",
  CONFIRM  = "RbyMmoConfirm",
  STATE    = "RbyMmoState",
  MAIN     = "RbyMmoMain",
  ROSTER   = "RbyMmoRoster",
  ACTIONS  = "RbyMmoActions",
  CHATLOG  = "RbyMmoChatLog",
  SCOPE    = "RbyMmoScope",
  COMPOSE  = "RbyMmoCompose",
  PICK     = "RbyMmoPick",
  HOSTSET  = "RbyMmoHostSetup",
  HOSTINFO = "RbyMmoHostInfo",
  JOINADDR = "RbyMmoJoinAddress",
}
M.SCREEN = SCREEN

-- ------- the digits page
--
-- The vanilla naming grid (src/ui/NamingScreen.lua) carries letters, space
-- and punctuation and *no digits at all*, so an address like
-- "192.168.1.20:7788" is literally untypeable on it. The ui.naming.grid
-- hook exists to replace a page, and its context carries the screen title,
-- so the swap below is scoped to the naming screens this mod pushes and
-- leaves rival-naming and mon nicknames exactly as they were.
--
-- Every glyph here survives Wire.text's sanitiser, so nothing can be typed
-- that the receiving end would silently strip.
local LETTERS = {
  { "A", "B", "C", "D", "E", "F", "G", "H", "I" },
  { "J", "K", "L", "M", "N", "O", "P", "Q", "R" },
  { "S", "T", "U", "V", "W", "X", "Y", "Z", " " },
  { "-", "?", "!", ",", ".", ":", ";", "/", "ED" },
  { "123" },
}

local DIGITS = {
  { "1", "2", "3", "4", "5", "6", "7", "8", "9" },
  { "0", ".", ":", "-", "/", "(", ")", ";", "," },
  { "?", "!", " ", "ED" },
  { "ABC" },
}

-- titles of naming screens this mod owns; the grid hook matches on these
-- rather than on a flag, so a cancelled screen cannot leave the swap armed
-- for whatever opens next
local ownedTitles = {}

local function ownTitle(title)
  ownedTitles[title] = true
  return title
end

function M.new(ctx)
  -- ctx is filled in by Client once every part exists; holding the table
  -- rather than its fields is what lets Ui be built before Sessions
  return setmetatable({ ctx = ctx }, M)
end

-- ------- primitives other modules call

function M:say(text, onDone)
  local game = self.ctx.game
  if not game then return end
  mod.ui.push(game, SCREEN.TEXT, { text = text, onDone = onDone })
end

function M:confirm(game, text, onChoose)
  game = game or self.ctx.game
  if not game then return end
  mod.ui.push(game, SCREEN.CONFIRM, { text = text, onChoose = onChoose })
end

function M:pushState(game, state)
  game = game or self.ctx.game
  if not (game and state) then return end
  mod.ui.push(game, SCREEN.STATE, { state = state })
end

function M:pickPartyMon(game, trade, onPick)
  game = game or self.ctx.game
  if not game then return end
  mod.ui.push(game, SCREEN.PICK, { trade = trade, onPick = onPick })
end

-- ------- registration

function M:install()
  local ctx = self.ctx
  local screens = mod.content.screens

  -- Give this mod's naming screens a digits page.  Scoped by title: any
  -- screen the mod did not open -- naming your rival, nicknaming a mon --
  -- falls straight through to next() and keeps the vanilla grid.
  mod.hooks:wrap("ui.naming.grid", function(next, grid, ctxInfo)
    local out = next(grid, ctxInfo)
    if type(ctxInfo) ~= "table" or not ownedTitles[ctxInfo.title] then
      return out
    end
    -- SELECT flips between the two pages, so "lower" becomes "digits"
    return ctxInfo.lower and DIGITS or LETTERS
  end)

  screens:register(SCREEN.TEXT, { new = function(game, opts)
    opts = opts or {}
    return mod.ui.TextBox.new(game, opts.text or "", opts.onDone)
  end })

  screens:register(SCREEN.CONFIRM, { new = function(game, opts)
    opts = opts or {}
    -- TextBox pushes the yes/no box itself once the text finishes printing
    -- and calls opts.choice with the answer, which is the vanilla prompt
    -- rhythm rather than two boxes appearing at once
    return mod.ui.TextBox.new(game, opts.text or "", nil, {
      choice = function(yes)
        if opts.onChoose then opts.onChoose(yes and true or false) end
      end,
    })
  end })

  screens:register(SCREEN.STATE, { new = function(_, opts)
    return opts and opts.state
  end })

  -- ------- the main MMO menu

  screens:register(SCREEN.MAIN, { new = function(game)
    local client = ctx.client
    local items = {}
    local hosting = client:isHosting()
    local connected = client:isConnected()

    -- Each row is gated on what it actually needs, not on one blanket
    -- "connected" test. Hosting and being connected are separate states: a
    -- listener can be up while this copy's own client is not on it, and
    -- gating everything on connected left that host with no way to read out
    -- their address or stop hosting -- the menu offered to start a game
    -- they were already running.
    if connected or hosting then
      -- the address to read out to friends, re-viewable for as long as the
      -- game is up; this is the only place it is shown after starting
      if hosting then
        items[#items + 1] = {
          label = "ADDRESS",
          onSelect = function() mod.ui.push(game, SCREEN.HOSTINFO) end,
        }
      end
      if connected then
      items[#items + 1] = {
        label = "PLAYERS",
        right = hosting
          and ("%d/%d"):format(ctx.roster.count + 1, client:hostLimit())
          or tostring(ctx.roster.count),
        onSelect = function() mod.ui.push(game, SCREEN.ROSTER) end,
      }
      items[#items + 1] = {
        label = "CHAT",
        right = ctx.chat.unread > 0 and ("+" .. ctx.chat.unread) or nil,
        onSelect = function() mod.ui.push(game, SCREEN.CHATLOG) end,
      }
      items[#items + 1] = {
        label = "SAY",
        onSelect = function() mod.ui.push(game, SCREEN.SCOPE) end,
      }
      end
      items[#items + 1] = {
        label = hosting and "END GAME" or "LEAVE",
        onSelect = function()
          -- Leaving someone else's game just disconnects: the save, the
          -- world and the party are untouched, so play carries straight on
          -- single-player. Ending a game you host is destructive for
          -- everyone else, so that one asks first.
          if not hosting then
            client:leave()
            return mod.ui.push(game, SCREEN.TEXT, {
              text = "You left.\nStill playing!",
            })
          end
          mod.ui.push(game, SCREEN.CONFIRM, {
            text = "End the game for\neveryone?",
            onChoose = function(yes)
              if not yes then return end
              client:leave()
              mod.ui.push(game, SCREEN.TEXT, { text = "The game ended." })
            end,
          })
        end,
      }
    else
      items[#items + 1] = {
        label = "HOST GAME",
        onSelect = function() mod.ui.push(game, SCREEN.HOSTSET) end,
      }
      items[#items + 1] = {
        label = "JOIN GAME",
        onSelect = function() mod.ui.push(game, SCREEN.JOINADDR) end,
      }
    end

    return mod.ui.ListMenu.new(game, "MMO", items, {
      onChoose = function(item, menu)
        menu:close()
        if item.onSelect then item.onSelect() end
      end,
    })
  end })

  -- ------- hosting: pick the limit, then start

  screens:register(SCREEN.HOSTSET, { new = function(game)
    local client = ctx.client
    -- QuantityBox is the engine's number picker; it wraps 1..max, so the
    -- floor is enforced on the way out rather than by the widget
    return mod.ui.QuantityBox.new(game, {
      max = Config.MAX_PLAYERS,
      start = client:maxPlayers(),
      onDone = function(qty)
        if not qty then return end
        client:setMaxPlayers(qty)
        if client:host(game) then
          mod.ui.push(game, SCREEN.HOSTINFO)
        end
      end,
    })
  end })

  screens:register(SCREEN.HOSTINFO, { new = function(game)
    local client = ctx.client
    if not client:isHosting() then
      return mod.ui.TextBox.new(game, "You aren't hosting.")
    end
    local address = client:hostAddress()
    -- Net.lanIP() answers nil when it cannot work out which interface faces
    -- the network, and "?:7788" tells a player nothing they can act on.
    -- Name the port instead -- it is the half they need to forward anyway.
    if type(address) ~= "string" or address:find("^%?") then
      return mod.ui.TextBox.new(game, ("Hosting on port %d.\nYour IP is "
        .. "hidden -- check\nyour network settings."):format(Config.DEFAULT_PORT))
    end
    return mod.ui.TextBox.new(game, ("Tell your friends:\n%s"):format(address))
  end })

  -- ------- joining: type an address, then connect

  screens:register(SCREEN.JOINADDR, { new = function(game)
    local client = ctx.client
    return mod.ui.NamingScreen.new(game, {
      title = ownTitle("JOIN"),
      -- long enough for "255.255.255.255:65535"
      maxLen = 21,
      default = client:joinAddress(),
      onDone = function(address)
        if not client:setJoinAddress(address) then return end
        client:connect(game)
      end,
    })
  end })

  -- ------- who is online

  screens:register(SCREEN.ROSTER, { new = function(game)
    local current = World.current()
    local items = {}
    for _, player in ipairs(ctx.roster:sorted()) do
      local here = current and player.map == current.mapId
      items[#items + 1] = {
        label = player.name,
        right = player.busy and "BUSY" or (here and "HERE" or nil),
        value = player.id,
      }
    end
    return mod.ui.ListMenu.new(game, "PLAYERS", items, {
      pageJump = true,
      onChoose = function(item, menu)
        menu:close()
        local player = ctx.roster:get(item.value)
        if player then
          mod.ui.push(game, SCREEN.ACTIONS, { playerId = player.id })
        end
      end,
    })
  end })

  -- ------- what you can do with one of them

  screens:register(SCREEN.ACTIONS, { new = function(game, opts)
    local player = ctx.roster:get(opts and opts.playerId)
    if not player then
      return mod.ui.TextBox.new(game, "They just went\noffline.")
    end

    local items = {
      { label = "TRADE", kind = "trade" },
      { label = "BATTLE", kind = "battle" },
      { label = "WHISPER" },
    }

    return mod.ui.ListMenu.new(game, player.name, items, {
      onChoose = function(item, menu)
        menu:close()
        if item.kind then
          ctx.sessions:request(player, item.kind)
        else
          mod.ui.push(game, SCREEN.COMPOSE,
            { scope = "private", to = player.id, toName = player.name })
        end
      end,
    })
  end })

  -- ------- the chat log

  screens:register(SCREEN.CHATLOG, { new = function(game)
    ctx.chat:markRead()
    local items = {}
    for _, entry in ipairs(ctx.chat:recent(Config.CHAT_HISTORY)) do
      items[#items + 1] = { label = ctx.chat:line(entry) }
    end
    if #items == 0 then
      items[#items + 1] = { label = "No messages yet." }
    end
    return mod.ui.ListMenu.new(game, "CHAT", items, {
      pageJump = true,
      onChoose = function(_, menu) menu:close() end,
    })
  end })

  -- ------- pick a scope, then type

  screens:register(SCREEN.SCOPE, { new = function(game)
    local items = {
      { label = "EVERYONE", scope = "global" },
      { label = "NEARBY", scope = "local" },
    }
    return mod.ui.ListMenu.new(game, "SAY TO", items, {
      onChoose = function(item, menu)
        menu:close()
        mod.ui.push(game, SCREEN.COMPOSE, { scope = item.scope })
      end,
    })
  end })

  screens:register(SCREEN.COMPOSE, { new = function(game, opts)
    opts = opts or {}
    local title = opts.scope == "private"
      and ("TO " .. tostring(opts.toName or "?"))
      or (opts.scope == "local" and "SAY NEARBY" or "SAY TO ALL")
    return mod.ui.NamingScreen.new(game, {
      title = ownTitle(title),
      maxLen = Config.COMPOSE_MAX,
      onDone = function(text)
        ctx.client:say(opts.scope, text, opts.to)
      end,
    })
  end })

  -- ------- trade: choose what to offer

  screens:register(SCREEN.PICK, { new = function(game, opts)
    opts = opts or {}
    local trade = opts.trade
    local items = {}
    for index, mon in ipairs(game.save.party or {}) do
      local blocked = trade and not trade:canPick(index)
      items[#items + 1] = {
        label = tostring(mon.species),
        -- the reason the other game would not rebuild this mon, so a greyed
        -- row explains itself instead of just refusing
        right = blocked and (trade.reasons[index] and "NO" or "NO") or
          ("L" .. tostring(mon.level)),
        value = index,
        blocked = blocked,
      }
    end
    return mod.ui.ListMenu.new(game, "TRADE WHICH?", items, {
      onChoose = function(item, menu)
        if item.blocked then return end
        menu:close()
        if opts.onPick then opts.onPick(item.value) end
      end,
      onCancel = function()
        if opts.onPick then opts.onPick(nil) end
      end,
    })
  end })
end

M.Chat = Chat

return M
