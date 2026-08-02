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
local Chars = need("Chars")

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
  CHARSET  = "RbyMmoCharSetup",
  CHARPICK = "RbyMmoCharPick",
  PROFILE  = "RbyMmoProfile",
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

-- remembered cursor rows, so reopening a menu lands where you left it
local cursor = {}

local function ownTitle(title)
  ownedTitles[title] = true
  return title
end

-- A trainer card for somebody else.
--
-- The engine's own TrainerCard reads the local save, so it cannot be
-- pointed at a remote player; this draws the same fields from what they
-- sent when they joined. It is a plain state rather than a widget because
-- there is no widget for "a page of text with a border".
local Card = {}
Card.__index = Card
Card.isOpaque = true

function Card.new(game, player, onCancel)
  return setmetatable({ game = game, player = player, onCancel = onCancel }, Card)
end

function Card:update()
  local input = self.game.input
  if input:wasPressed("b") or input:wasPressed("a") then
    self.game.stack:pop()
    if self.onCancel then self.onCancel() end
  end
end

function Card:draw()
  local Font = mod.ui.Font
  if not (Font and Font.draw) then return end
  local p = self.player
  -- Full-height box, rows on a 16px grid from y=24. At 17 tiles the last
  -- row landed on the border and the dex line was cut in half.
  Font.drawBox(0, 0, 20, 18)
  Font.draw("TRAINER CARD", 24, 8)

  Font.draw(("NAME/%s"):format(tostring(p.name or "?")), 16, 24)
  Font.draw(("LOOK/%s"):format(Chars.label(p.sprite or "")), 16, 40)

  local card = p.profile
  if not card then
    -- An older build sends no card. Say so, rather than draw zeros that
    -- read as "this trainer has nothing".
    Font.draw("NO CARD SENT.", 16, 64)
    Font.draw("THEIR BUILD IS", 16, 80)
    Font.draw("OLDER THAN YOURS.", 16, 96)
    return
  end

  Font.draw(("IDNo/%05d"):format(card.idNo or 0), 16, 56)
  -- the literal glyph, as the engine's own card uses; a Latin-1 escape drew
  -- nothing at all here
  Font.draw(("MONEY/¥%d"):format(card.money or 0), 16, 72)
  Font.draw(("TIME/%3d:%02d"):format(
    math.floor((card.playtime or 0) / 3600),
    math.floor(((card.playtime or 0) % 3600) / 60)), 16, 88)
  Font.draw(("BADGES/%d"):format(card.badges or 0), 16, 104)
  Font.draw(("SEEN/%d OWN/%d"):format(card.seen or 0, card.owned or 0), 16, 120)
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

  -- The MMO menu is a START submenu, so it looks like one: a bordered box
  -- in the same corner, double-spaced rows, the blinking arrow, and B
  -- returning to START rather than dumping you into the world. Menu (not
  -- ListMenu) is the widget for that -- ListMenu is the full-screen
  -- inventory list the bag and the PC use, which is why this screen used to
  -- take over the whole display for four short commands.
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
      if hosting then
        items[#items + 1] = {
          label = "ADDRESS",
          onSelect = function() mod.ui.push(game, SCREEN.HOSTINFO) end,
        }
      end
      if connected then
        items[#items + 1] = {
          label = "PLAYERS",
          onSelect = function() mod.ui.push(game, SCREEN.ROSTER) end,
        }
        -- an asterisk for unread, the way the original marks state in a
        -- label rather than with a second column the box has no room for
        items[#items + 1] = {
          label = ctx.chat.unread > 0 and "CHAT*" or "CHAT",
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
        onSelect = function()
          mod.ui.push(game, SCREEN.CHARSET, {
            verb = "HOST",
            onReady = function() mod.ui.push(game, SCREEN.HOSTSET) end,
          })
        end,
      }
      items[#items + 1] = {
        label = "JOIN GAME",
        onSelect = function()
          mod.ui.push(game, SCREEN.CHARSET, {
            verb = "JOIN",
            onReady = function() mod.ui.push(game, SCREEN.JOINADDR) end,
          })
        end,
      }
    end

    local menu = mod.ui.Menu.new(game, items, {
      tx = 9, ty = 0, tw = 11,
      -- the same ceiling the START menu uses: (18 rows - 2 border) / 2
      maxVisible = 8,
      -- B goes back where it came from, like every vanilla submenu
      onCancel = function() mod.ui.push(game, "StartMenu") end,
    })
    -- the cursor survives closing the menu, as the original's does
    menu.index = math.min(cursor.main or 1, math.max(1, #items))
    menu:clampScroll()
    local baseUpdate = menu.update
    menu.update = function(self, dt)
      baseUpdate(self, dt)
      cursor.main = self.index
    end
    return menu
  end })

  -- ------- hosting: pick the limit, then start

  -- ------- character creation
  --
  -- Who you are online, asked once before you host or join, rather than
  -- inheriting the save's trainer name and a sprite nobody chose. The name
  -- is separate from the save file's, so somebody can be ASH online without
  -- renaming their single-player game.

  screens:register(SCREEN.CHARSET, { new = function(game, opts)
    opts = opts or {}
    local client = ctx.client
    local items = {
      { label = "NAME", right = client:playerName(game), key = "name" },
      { label = "LOOK", right = Chars.label(client:spriteChoice()), key = "look" },
      { label = opts.verb or "READY", key = "go" },
    }
    return mod.ui.ListMenu.new(game, "TRAINER", items, {
      onChoose = function(item, menu)
        menu:close()
        if item.key == "name" then
          mod.ui.push(game, SCREEN.COMPOSE,
            { scope = "name", back = SCREEN.CHARSET, backOpts = opts })
        elseif item.key == "look" then
          mod.ui.push(game, SCREEN.CHARPICK, { back = opts })
        elseif opts.onReady then
          opts.onReady()
        end
      end,
      onCancel = function() mod.ui.push(game, SCREEN.MAIN) end,
    })
  end })

  screens:register(SCREEN.CHARPICK, { new = function(game, opts)
    opts = opts or {}
    local client = ctx.client
    local current = client:spriteChoice()
    local items, start = {}, 1
    for i, id in ipairs(Chars.list()) do
      if id == current then start = i end
      items[#items + 1] = { label = Chars.label(id), value = id }
    end
    local menu = mod.ui.ListMenu.new(game, "CHARACTER", items, {
      pageJump = true,
      onChoose = function(item, m)
        m:close()
        client:setSpriteChoice(item.value)
        mod.ui.push(game, SCREEN.CHARSET, opts.back or {})
      end,
      onCancel = function()
        mod.ui.push(game, SCREEN.CHARSET, opts.back or {})
      end,
    })
    menu.index = start
    return menu
  end })

  -- ------- somebody else's trainer card

  screens:register(SCREEN.PROFILE, { new = function(game, opts)
    local player = ctx.roster:get(opts and opts.playerId)
    if not player then
      return mod.ui.TextBox.new(game, "They just went\noffline.")
    end
    return Card.new(game, player, opts and opts.onCancel)
  end })

  -- How many players, as a menu of sizes rather than a bare number box.
  --
  -- This was QuantityBox, the engine's *shop* quantity widget, which drew
  -- "x02" in a corner with nothing to say what it counted -- the player had
  -- no way to know they were choosing a room size. Named rows say it
  -- outright, and a bordered list is the shape the original uses for a
  -- choice like this anyway.
  local SIZES = { 2, 4, 8, 16, 32, 64 }

  screens:register(SCREEN.HOSTSET, { new = function(game)
    local client = ctx.client
    local current = client:maxPlayers()

    local sizes = {}
    for _, n in ipairs(SIZES) do sizes[#sizes + 1] = n end
    -- a number set in the options pane is still reachable here, even if it
    -- is not one of the round ones
    local known = false
    for _, n in ipairs(sizes) do if n == current then known = true end end
    if not known then
      sizes[#sizes + 1] = current
      table.sort(sizes)
    end

    local items, start = {}, 1
    for i, n in ipairs(sizes) do
      if n == current then start = i end
      items[#items + 1] = {
        label = ("%d PLAYERS"):format(n),
        onSelect = function()
          client:setMaxPlayers(n)
          if client:host(game) then
            mod.ui.push(game, SCREEN.HOSTINFO)
          end
        end,
      }
    end

    local menu = mod.ui.Menu.new(game, items, {
      tx = 8, ty = 0, tw = 12, maxVisible = 8,
      onCancel = function() mod.ui.push(game, SCREEN.MAIN) end,
    })
    -- open on what is already configured, so confirming is one button
    menu.index = start
    menu:clampScroll()
    return menu
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
    -- A roster is genuinely a list -- variable length, with a status
    -- column -- so this one stays the full-screen ListMenu the bag and the
    -- PC use, rather than a command box.
    return mod.ui.ListMenu.new(game, "PLAYERS", items, {
      pageJump = true,
      onChoose = function(item, menu)
        menu:close()
        local player = ctx.roster:get(item.value)
        if player then
          mod.ui.push(game, SCREEN.ACTIONS, {
            playerId = player.id,
            onCancel = function() mod.ui.push(game, SCREEN.ROSTER) end,
          })
        end
      end,
      onCancel = function() mod.ui.push(game, SCREEN.MAIN) end,
    })
  end })

  -- ------- what you can do with one of them

  screens:register(SCREEN.ACTIONS, { new = function(game, opts)
    local player = ctx.roster:get(opts and opts.playerId)
    if not player then
      return mod.ui.TextBox.new(game, "They just went\noffline.")
    end

    -- Three commands about the person in front of you: a small box, the
    -- way the original asks CUT/SURF or a party submenu. Sized to the
    -- widest label by Menu itself and nudged on-screen, so it stays right
    -- however long a trainer's name is.
    -- PROFILE first: knowing who you are looking at should come before
    -- deciding to trade with them
    local items = {
      { label = "PROFILE", profile = true },
      { label = "TRADE", kind = "trade" },
      { label = "BATTLE", kind = "battle" },
      { label = "WHISPER" },
    }

    local reopen = function()
      mod.ui.push(game, SCREEN.ACTIONS,
        { playerId = player.id, onCancel = opts and opts.onCancel })
    end
    for _, item in ipairs(items) do
      local kind, wantsProfile = item.kind, item.profile
      item.onSelect = function()
        if wantsProfile then
          mod.ui.push(game, SCREEN.PROFILE,
            { playerId = player.id, onCancel = reopen })
        elseif kind then
          ctx.sessions:request(player, kind)
        else
          mod.ui.push(game, SCREEN.COMPOSE,
            { scope = "private", to = player.id, toName = player.name })
        end
      end
    end

    return mod.ui.Menu.new(game, items, {
      -- low and to the right, clear of the two characters this menu is
      -- about: a command box that covers the person you are talking to
      -- reads as a bug even when it is not one
      tx = 11, ty = 7, tw = 9,
      -- back to whatever opened this: the roster if you came from the menu,
      -- the world if you walked up and pressed A
      onCancel = opts and opts.onCancel,
    })
  end })

  -- ------- the chat log

  -- Chat lines are the one thing here that will not fit a Game Boy row.
  -- A 60-character message is three times the width of the screen, and
  -- ListMenu draws a label as one line, so it would simply run off the
  -- edge. Wrap on spaces and indent the continuations, the way the
  -- original's text boxes break a sentence.
  -- 15, not 18: ListMenu indents its rows past the cursor column, so the
  -- full screen width is not what a row actually gets. Wrapping to the
  -- theoretical width put the last word hard against the right edge.
  local CHAT_COLS = 15

  local function wrapLine(text, first, rest)
    local rows, line = {}, first
    for word in tostring(text):gmatch("%S+") do
      local candidate = line == "" and word or (line .. " " .. word)
      if #candidate > CHAT_COLS and line ~= "" then
        rows[#rows + 1] = line
        line = rest .. word
      else
        line = candidate
      end
    end
    if line ~= "" then rows[#rows + 1] = line end
    return rows
  end

  screens:register(SCREEN.CHATLOG, { new = function(game)
    ctx.chat:markRead()
    local items = {}
    for _, entry in ipairs(ctx.chat:recent(Config.CHAT_HISTORY)) do
      -- Speaker on its own row, message wrapped beneath it.
      --
      -- Running them together ate the width and, worse, merged the scope
      -- tag into the name: "G" + "HOSTY" read as "GHOSTY". Brackets keep
      -- the tag distinct, and giving the message its own rows means it gets
      -- the full 18 columns instead of whatever the name left over.
      local tag = Chat.TAG[entry.scope] or "?"
      items[#items + 1] = { label = ("[%s]%s:"):format(tag, entry.name) }
      for _, row in ipairs(wrapLine(entry.text, " ", " ")) do
        items[#items + 1] = { label = row }
      end
    end
    if #items == 0 then
      items[#items + 1] = { label = "No messages yet." }
    end
    -- newest last, so open on the bottom the way a chat log should read
    local menu = mod.ui.ListMenu.new(game, "CHAT", items, {
      pageJump = true,
      onChoose = function(_, menu) menu:close() end,
      onCancel = function() mod.ui.push(game, SCREEN.MAIN) end,
    })
    menu.index = #items
    return menu
  end })

  -- ------- pick a scope, then type

  screens:register(SCREEN.SCOPE, { new = function(game)
    local items = {
      { label = "EVERYONE", scope = "global" },
      { label = "NEARBY", scope = "local" },
    }
    for _, item in ipairs(items) do
      local scope = item.scope
      item.onSelect = function()
        mod.ui.push(game, SCREEN.COMPOSE, { scope = scope })
      end
    end
    return mod.ui.Menu.new(game, items, {
      tx = 9, ty = 0, tw = 11,
      onCancel = function() mod.ui.push(game, SCREEN.MAIN) end,
    })
  end })

  screens:register(SCREEN.COMPOSE, { new = function(game, opts)
    opts = opts or {}

    -- the same grid serves chat and the trainer name; only the title, the
    -- length and what happens on confirm differ
    if opts.scope == "name" then
      local client = ctx.client
      return mod.ui.NamingScreen.new(game, {
        title = ownTitle("YOUR NAME"),
        maxLen = Config.NAME_MAX,
        default = client:playerName(game),
        onDone = function(name)
          client:setPlayerName(name)
          mod.ui.push(game, opts.back or SCREEN.CHARSET, opts.backOpts or {})
        end,
      })
    end

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
