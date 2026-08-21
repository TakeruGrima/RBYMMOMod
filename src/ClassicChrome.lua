-- The classic Game Boy chrome, drawn onto the arena's 640x360 canvas.
--
-- White bordered box, the engine's own 8px tile font, the tile cursor, a
-- GB-shaped HP bar. This is the second painter behind Battlefield.skin(); the
-- first is Battlefield's own modern panel set. Both consume one model
-- (BattleRows), so they cannot disagree about facts -- only about looks.
--
-- NO REQUIRE OF Battlefield HERE, and that is structural rather than stylistic:
-- Battlefield requires this file for the dispatch, so requiring it back would
-- be a cycle, and main.lua's resolver refuses cycles by disabling the whole
-- mod. Every rect and every constant this file needs therefore arrives as an
-- ARGUMENT. That also makes each widget assertable on its own.
--
-- ------- the scale, and why the numbers are what they are
--
-- Everything is drawn in the GB's own 8px tile space and scaled x2, so a glyph
-- lands on screen as a 16px cell -- against 10-13px for the modern panels, and
-- black on white instead of white on translucent slate. That contrast, more
-- than the size, is the readability fix.
--
-- The canvas is 640 wide, which is exactly 40 tiles at x2, and the box is five
-- tile rows tall: 80px, starting at y=280, which is FIELD_BOTTOM exactly.
--
-- **It used to be seven rows (112px), overhanging upward over the arena, and
-- that was wrong.** The claim was that the field never consults the box so the
-- overhang was free. The ALLY PLATE disproves it: Battlefield puts it at
-- `FIELD_BOTTOM - PLATE_H - PLATE_PAD` = y 220, so it occupies 220..268, and a
-- 112px box starting at 248 ate its bottom 20px -- the HP bar and the whole exp
-- strip, on the player's own monster. Owner caught it in the first frame.
--
-- The constraint, stated so nobody re-derives it wrong twice: the box top must
-- be >= 268, so its height must be <= 92px, so at x2 it is **5 tiles = 80px**.
-- That lands it exactly on FIELD_BOTTOM. The box IS the band again.
--
-- The cost is real and accepted: three content rows, not five. A party list
-- therefore scrolls (the switch list offers at most five, the active monster
-- being excluded). Titles are dropped when they would cost a row -- see
-- drawListPanel.
--
-- ------- the plate has no box, on purpose
--
-- The original's battle HUD is not boxed: name, level and HP bar sit straight
-- on the background (the engine does the same at MediatedBattle:5409-5441).
-- Boxing it here would spend two of the plate's three tile rows on a border it
-- never had. So plates draw bare, which is both authentic and what makes all
-- three rows usable.
--
-- ------- icons are drawn at screen scale, never inside the transform
--
-- Menu icons are 16x16 sources. Inside the x2 transform they would land as 32px
-- and swamp a 16px row, and stretching them is what Battlefield.lua:29-31 warns
-- about. They are therefore painted OUTSIDE the transform, 1:1, which makes them
-- exactly one row tall.

local need, mod = ...
local BattleRows = need("BattleRows")
local BattleIcon = need("BattleIcon")

local M = {}

M.SCALE = 2
M.TILE = 8
-- Tile cell in screen pixels: one row of text.
M.CELL = M.TILE * M.SCALE

-- The band box: full canvas width, five rows tall, bottom-anchored. See the
-- header for why five and not seven -- it is the ally plate that sets the cap.
M.BOX_TILES_W = 40
M.BOX_TILES_H = 5
M.BOX_W = M.BOX_TILES_W * M.TILE * M.SCALE   -- 640
M.BOX_H = M.BOX_TILES_H * M.TILE * M.SCALE   -- 80

-- Content area inside the border, in LOCAL (pre-scale) pixels.
M.CONTENT_X = M.TILE                          -- 8
M.CONTENT_Y = M.TILE                          -- 8
M.CONTENT_W = (M.BOX_TILES_W - 2) * M.TILE    -- 304
M.CONTENT_ROWS = M.BOX_TILES_H - 2            -- 5
M.ROW_H = M.TILE                              -- 8 local == 16 screen

-- Local x of each list column. The cursor sits in the first content column and
-- the text one further, which is the spacing the engine's own list uses.
M.CURSOR_X = 8
M.ICON_X = 16
M.LABEL_X = 26

-- Charmap / HUD tile codes already proven in this repo.
M.CURSOR_CODE = 0xED  -- the list arrow; the charmap has no ">" (skill note)
M.LEVEL_CODE = 0x6E   -- the <LV> marker

-- GB ink. Black on the box's white, with one muted grey for a refused row --
-- the original greys nothing, but a fainted mon that looks identical to a
-- pickable one is a worse lie than a shade the hardware never had.
local INK = { 0, 0, 0, 1 }
local INK_DIM = { 0, 0, 0, 0.38 }
-- Gold's GBC HUD colours the bar; Red's hardware could not. Colouring it is
-- period-correct for one of the two generations and readable on both.
local HP_GREEN = { 0.13, 0.66, 0.20 }
local HP_YELLOW = { 0.85, 0.66, 0.10 }
local HP_RED = { 0.80, 0.16, 0.13 }
local EXP_BLUE = { 0.22, 0.40, 0.80 }

local function gfx()
  return love and love.graphics or nil
end

local function isTable(v)
  return type(v) == "table"
end

local function num(v, fallback)
  local n = tonumber(v)
  if not n or n ~= n then return fallback end
  return n
end

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

-- ------- engine modules
--
-- Grabbed INSIDE a draw, never at file scope. This module is resolved while the
-- Game is still being wired; a require that raised here would purge the whole
-- mod with one line in a log nobody reads (the engine states the same rule for
-- itself at src/ui/ModUI.lua:1-4). After the first call each require is a table
-- hit, so the guard costs nothing per frame.
local engine, engineTried

local function loadEngine()
  if engineTried then return engine end
  engineTried = true
  local parts = {}
  local ok, value = pcall(require, "src.render.Font")
  if ok then parts.Font = value end
  ok, value = pcall(require, "src.render.HudTiles")
  if ok then parts.HudTiles = value end
  engine = parts.Font and parts or false
  return engine
end

--- Exposed so the suite can drive the painters without the render stack.
--
-- `nil` means FORGET rather than "there is none": it clears the memo so the
-- next call resolves for real. Latching nil instead would leave the classic
-- painter permanently disabled for the rest of the process after any test that
-- put the module back.
function M.useEngine(parts)
  if parts == nil then
    engine, engineTried = nil, false
    return
  end
  engine, engineTried = parts, true
end

--- Whether this painter can actually paint right now.
--
-- Asked by anything that has to AGREE with what gets drawn rather than merely
-- draw it -- `Battlefield.bandGridCols` above all, because it is what the
-- CURSOR reads. Without this, a build where the engine's Font is unreachable
-- would fall through to the modern painter's four-across grid while the cursor
-- still stepped a 2x2, walking the highlight onto a slab that is not next to
-- the one it left.
function M.available()
  if not gfx() then return false end
  local eng = loadEngine()
  return (eng and eng.Font) and true or false
end

local function setColor(g, c, alpha)
  if not isTable(c) then return end
  g.setColor(c[1], c[2], c[3], alpha or c[4] or 1)
end

--- Run `fn` with the origin at screen (x, y) and everything scaled x2, so the
--- body can work in plain GB tile pixels.
--
-- Restores the transform whatever `fn` does. A painter that threw mid-body with
-- the transform still pushed would leave every later draw in the frame -- the
-- overlay, the toasts, the next screen -- doubled and offset.
local function withTiles(g, x, y, fn)
  if not (g.push and g.pop and g.translate and g.scale) then return false end
  if not pcall(g.push) then return false end
  local ok = pcall(function()
    g.translate(x, y)
    g.scale(M.SCALE, M.SCALE)
    fn()
  end)
  pcall(g.pop)
  return ok
end

-- ------- primitives (all in LOCAL tile-pixel space)

local function drawText(eng, text, x, y, color)
  local g = gfx()
  if not g then return end
  setColor(g, color or INK)
  pcall(eng.Font.draw, tostring(text or ""), x, y)
end

local function drawCode(eng, code, x, y, color)
  local g = gfx()
  if not g or not code then return end
  setColor(g, color or INK)
  pcall(eng.Font.drawCode, code, x, y)
end

--- Fit a string to a pixel budget at 8px per glyph, the tile font's fixed
--- advance. Truncation is by whole cells because a half cell is a torn glyph.
function M.fit(text, maxLocalW)
  text = tostring(text or "")
  local cells = math.floor(math.max(0, num(maxLocalW, 0)) / M.TILE)
  if cells <= 0 then return "" end
  if #text <= cells then return text end
  if cells == 1 then return text:sub(1, 1) end
  return text:sub(1, cells - 1) .. "."
end

local function hpColor(frac)
  if frac <= 0.20 then return HP_RED end
  if frac <= 0.50 then return HP_YELLOW end
  return HP_GREEN
end

--- The GB HP bar: a black outline with a proportional fill.
--
-- Drawn from rectangles rather than through HudTiles.drawHPBar, and the reason
-- is verifiability: drawHPBar owns a fixed tile geometry this mod cannot read
-- from here, so a wrong guess would put a bar of the engine's width inside a
-- plate of ours. Rectangles are the same shape at any width and cannot drift.
local function drawGauge(g, x, y, w, h, frac, color)
  frac = clamp(num(frac, 0), 0, 1)
  setColor(g, INK)
  g.rectangle("fill", x, y, w, 1)
  g.rectangle("fill", x, y + h - 1, w, 1)
  g.rectangle("fill", x, y, 1, h)
  g.rectangle("fill", x + w - 1, y, 1, h)
  local innerW = math.max(0, w - 2)
  local fill = math.floor(innerW * frac + 0.5)
  -- A living monster never shows an empty bar: the last sliver is the
  -- difference between "nearly dead" and "fainted", and the series keeps it.
  if frac > 0 and fill < 1 then fill = 1 end
  if fill > 0 then
    setColor(g, color or hpColor(frac))
    g.rectangle("fill", x + 1, y + 1, fill, h - 2)
  end
end

-- ------- band widgets
--
-- Each returns true only when it actually painted. Battlefield's callers gate
-- their GB-chrome fallback on that: without the signal, a widget that failed
-- mid-body would leave an empty band over a live fight, which reads as the
-- battle having frozen.

--- The bottom-anchored box every band widget draws inside.
-- Returns the engine bag and the box's screen origin, or nil.
local function openBox(canvasW, canvasH)
  local g = gfx()
  if not g then return nil end
  local eng = loadEngine()
  if not eng or not eng.Font then return nil end
  local x = math.floor((num(canvasW, M.BOX_W) - M.BOX_W) / 2)
  local y = num(canvasH, 0) - M.BOX_H
  return eng, x, y, g
end

local function paintBox(g, eng)
  setColor(g, INK)
  pcall(eng.Font.drawBox, 0, 0, M.BOX_TILES_W, M.BOX_TILES_H)
end

--- The classic skin paints its own opaque box, so it needs no scrim.
-- Kept so the dispatcher can call the same five names on either skin.
function M.drawBandBackdrop()
  return true
end

--- The battle line. Double-spaced, like the original's message box.
function M.drawMessagePanel(text, canvasW, canvasH, opts)
  local eng, bx, by, g = openBox(canvasW, canvasH)
  if not eng then return false end
  opts = isTable(opts) and opts or {}
  return withTiles(g, bx, by, function()
    paintBox(g, eng)
    local lines = M.wrap(text, M.CONTENT_W - M.TILE)
    for i = 1, math.min(#lines, 2) do
      drawText(eng, lines[i], M.LABEL_X - 10, M.CONTENT_Y + (i - 1) * 16)
    end
    if opts.hint ~= false and #lines > 0 then
      -- The continue marker, parked on the box's bottom-right content cell.
      drawCode(eng, M.CURSOR_CODE, M.CONTENT_X + M.CONTENT_W - M.TILE,
        M.CONTENT_Y + (M.CONTENT_ROWS - 1) * M.ROW_H)
    end
  end)
end

--- Word wrap at 8px per glyph.
function M.wrap(text, maxLocalW)
  local cells = math.floor(math.max(0, num(maxLocalW, 0)) / M.TILE)
  local out = {}
  if cells <= 0 then return out end
  for chunk in tostring(text or ""):gmatch("[^\n]+") do
    local line = ""
    for word in chunk:gmatch("%S+") do
      local candidate = (line == "") and word or (line .. " " .. word)
      if #candidate <= cells then
        line = candidate
      else
        if line ~= "" then out[#out + 1] = line end
        line = word:sub(1, cells)
      end
    end
    if line ~= "" then out[#out + 1] = line end
  end
  return out
end

--- FIGHT / PKMN / ITEM / RUN as the classic 2x2.
function M.drawCommandGrid(items, cursor, canvasW, canvasH)
  local eng, bx, by, g = openBox(canvasW, canvasH)
  if not eng then return false end
  if not isTable(items) or #items == 0 then return false end
  cursor = math.floor(clamp(num(cursor, 1), 1, #items))
  local colW = math.floor(M.CONTENT_W / 2)
  return withTiles(g, bx, by, function()
    paintBox(g, eng)
    for i, item in ipairs(items) do
      local row = math.floor((i - 1) / 2)
      local col = (i - 1) % 2
      local x = M.CONTENT_X + col * colW
      local y = M.CONTENT_Y + row * 16
      local label = isTable(item) and item.label or item
      local dim = isTable(item) and item.disabled
      drawText(eng, M.fit(label, colW - 24), x + 16, y, dim and INK_DIM or INK)
      if i == cursor then drawCode(eng, M.CURSOR_CODE, x + 4, y) end
    end
  end)
end

--- A vertical list: icon, name, gender, then level and HP on the right.
--
-- `rows` are BattleRows models. A plain string is accepted too, so a caller
-- with nothing but labels (the move list) still works.
function M.drawListPanel(rows, cursor, canvasW, canvasH, opts)
  local eng, bx, by, g = openBox(canvasW, canvasH)
  if not eng then return false end
  opts = isTable(opts) and opts or {}
  rows = isTable(rows) and rows or {}
  local count = #rows
  cursor = math.floor(clamp(num(cursor, 1), 1, math.max(1, count)))

  local title = type(opts.title) == "string" and opts.title ~= "" and opts.title
  -- A title costs a row, and there are only three. It keeps its row only when
  -- the list still fits underneath -- so a two-answer prompt ("RUN AWAY?")
  -- keeps its question and a six-monster party spends the row on a monster
  -- instead. The original's party list had no title at all, so dropping it is
  -- the faithful answer as well as the useful one.
  if title and #rows > M.CONTENT_ROWS - 1 then title = nil end
  local visible = M.CONTENT_ROWS - (title and 1 or 0)
  local first = 1
  if cursor > visible then first = cursor - visible + 1 end
  first = math.min(first, math.max(1, count - visible + 1))
  local top = M.CONTENT_Y + (title and M.ROW_H or 0)

  local painted = withTiles(g, bx, by, function()
    paintBox(g, eng)
    if title then
      drawText(eng, M.fit(title, M.CONTENT_W), M.CONTENT_X, M.CONTENT_Y)
    end
    for slot = 0, visible - 1 do
      local row = rows[first + slot]
      if row then
        local y = top + slot * M.ROW_H
        local isModel = isTable(row)
        local dim = isModel and row.dim
        local ink = dim and INK_DIM or INK
        local label = isModel and (row.name or row.label) or row
        local right = isModel and (row.right or BattleRows.rightText(row)) or nil
        local rightW = right and (#tostring(right) * M.TILE) or 0
        -- The icon column is only spent when there is an icon to put in it.
        local labelX = (isModel and row.iconRow) and M.LABEL_X or M.ICON_X
        local budget = M.CONTENT_X + M.CONTENT_W - labelX - rightW - M.TILE
        local gender = isModel and row.gender
        if gender then budget = budget - M.TILE end
        drawText(eng, M.fit(label, budget), labelX, y, ink)
        if gender then
          local used = #M.fit(label, budget) * M.TILE
          local tint = dim and INK_DIM or BattleRows.genderColor(gender) or ink
          drawCode(eng, BattleRows.genderTile(gender), labelX + used + 2, y, tint)
        end
        if right then
          drawText(eng, right,
            M.CONTENT_X + M.CONTENT_W - rightW, y, ink)
        end
        if (first + slot) == cursor then
          drawCode(eng, M.CURSOR_CODE, M.CURSOR_X, y)
        end
      end
    end
  end)
  if not painted then return false end

  -- Icons last and OUTSIDE the transform, so a 16x16 source lands exactly one
  -- row tall rather than doubled. A miss costs its own cell and nothing else.
  for slot = 0, visible - 1 do
    local row = rows[first + slot]
    if isTable(row) and row.iconRow then
      local y = by + (top + slot * M.ROW_H) * M.SCALE
      BattleIcon.draw(opts.game, row.iconRow, bx + M.ICON_X * M.SCALE, y)
    end
  end
  return true
end

-- ------- the plate
--
-- Three tile rows, unboxed, in the plate rect Battlefield already measured:
-- 176x48 is exactly 11x3 tiles at x2, so nothing about seat placement moves.

M.PLATE_TILES_W = 11
M.PLATE_TILES_H = 3
-- Local layout. The icon spends one tile column; the name starts after it.
M.PLATE_ICON_X = 0
M.PLATE_TEXT_X = 10
M.PLATE_ROW1_Y = 8
M.PLATE_ROW2_Y = 16
M.PLATE_BAR_H = 6
M.PLATE_EXP_H = 2

--- One field plate. `plate` is Battlefield's own { x, y, w, h, model, numbers },
--- and `extras` is BattleRows.plateExtras (gender + icon).
function M.drawPlate(plate, extras, game)
  local g = gfx()
  if not (g and isTable(plate) and isTable(plate.model)) then return false end
  local eng = loadEngine()
  if not eng or not eng.Font then return false end
  extras = isTable(extras) and extras or {}
  local model = plate.model
  local localW = M.PLATE_TILES_W * M.TILE

  local painted = withTiles(g, plate.x, plate.y, function()
    -- The GB HUD is unboxed but it is not transparent: the arena art behind it
    -- is bright and busy, and black tile glyphs on grass are unreadable. A
    -- white ground under the plate is what the original's screen gave for free.
    g.setColor(1, 1, 1, 0.88)
    g.rectangle("fill", -2, -2, localW + 4, M.PLATE_TILES_H * M.TILE + 4)

    local hasIcon = extras.iconRow ~= nil
    local textX = hasIcon and M.PLATE_TEXT_X or 0
    -- Name first and widest: it is the fact. The icon is an ornament and has
    -- already yielded its column if there was nothing to put there.
    drawText(eng, M.fit(model.name, localW - textX), textX, 0)

    -- Classic rule (and the engine's own, at MediatedBattle:5418-5426): a
    -- status REPLACES the level readout rather than crowding beside it.
    local metaX = textX
    if model.status then
      drawText(eng, tostring(model.status):sub(1, 3), metaX, M.PLATE_ROW1_Y)
      metaX = metaX + 3 * M.TILE + 2
    else
      local level = model.shownLevel or model.level
      if level then
        local drew = pcall(function()
          setColor(g, INK)
          eng.HudTiles.tile(M.LEVEL_CODE, metaX, M.PLATE_ROW1_Y)
        end)
        if not drew or not eng.HudTiles then
          drawText(eng, "L", metaX, M.PLATE_ROW1_Y)
        end
        local text = tostring(level)
        drawText(eng, text, metaX + M.TILE, M.PLATE_ROW1_Y)
        metaX = metaX + M.TILE + #text * M.TILE + 2
      end
    end
    if extras.gender then
      drawCode(eng, BattleRows.genderTile(extras.gender), metaX, M.PLATE_ROW1_Y,
        BattleRows.genderColor(extras.gender))
    end

    -- Exact figures on your own side only, per series convention -- the flag
    -- Battlefield already sets rather than a rule invented here.
    local barW = localW
    if plate.numbers and model.maxHp then
      local text = ("%d/%d"):format(model.shownHp or model.hp or 0, model.maxHp)
      local w = #text * M.TILE
      drawText(eng, text, localW - w, M.PLATE_ROW1_Y)
    end

    drawGauge(g, 0, M.PLATE_ROW2_Y, barW, M.PLATE_BAR_H, model.frac)
    if model.expFrac ~= nil then
      drawGauge(g, 0, M.PLATE_ROW2_Y + M.PLATE_BAR_H, barW, M.PLATE_EXP_H,
        model.expFrac, EXP_BLUE)
    end
    g.setColor(1, 1, 1, 1)
  end)
  if not painted then return false end

  if extras.iconRow then
    BattleIcon.draw(game, extras.iconRow, plate.x + M.PLATE_ICON_X, plate.y)
  end
  return true
end

return M
