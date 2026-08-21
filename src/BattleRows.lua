-- What a battle list row and a field plate SAY, with nothing about how they
-- look.
--
-- This file exists so the two skins cannot disagree about facts. The classic
-- GB chrome and the modern arena panels are two painters over one model: the
-- level, the gender and the icon are decided here, once, above the fork in
-- Battlefield.skin(). A bug fixed here is fixed in both looks, and a row that
-- gains a field gains it in both.
--
-- Love-free and engine-free on purpose. Nothing here calls love.graphics and
-- nothing requires an engine module, so the whole model is assertable in the
-- headless suite. Painting lives in ClassicChrome (GB) and Battlefield
-- (modern); icon painting specifically lives in BattleIcon, which does need
-- the render stack and therefore cannot live here.
--
-- Two monster shapes reach this file and both are supported, because the same
-- switch menu is drawn for a local party and for a mediated one:
--
--   save mon   { species = "PIKACHU", nickname = ?, level, hp,
--                stats = { hp = max }, dvs = { attack = n } }
--   wire sheet { species = "<prose / nickname>", speciesId = "PIKACHU",
--                level, hp, maxHp, ivs = { atk = n } }
--
-- The wire sheet's `species` is PROSE -- it is the nickname when the monster
-- has one, which is exactly why it cannot be looked up -- and `speciesId` is
-- the registry id. Wire.lua:1412-1428 states that contract; this file consumes
-- it and never confuses the two.

local need, mod = ...

local M = {}

-- The mod whose exports answer "what gender is this monster". Optional in
-- every direction: an absent mod, an absent export, or a throw all mean "no
-- gender", never an error. It is gen 1 only (its manifest carries no `games`
-- field), so on Gold this simply never resolves and no glyph is drawn.
M.GENDER_MOD = "gender_mod"

-- Gen 1 DVs are spelled with engine keys on a save mon (`attack`) and with
-- wire keys on a sheet (`atk`). gender_mod's resolver reads the engine
-- spelling, so a sheet is translated rather than the resolver second-guessed.
local DV_ATTACK_KEYS = { "attack", "atk" }

-- pokered's own charmap codes, used only if gender_mod moved its helper:
-- EF is the male sign, F5 the female one.
local FALLBACK_TILE = { M = 0xEF, F = 0xF5 }
-- U+2642 / U+2640 as raw UTF-8 bytes. NOT "\u{2642}" -- that escape is Lua
-- 5.3 and LuaJIT 2.1 refuses to parse it, which would purge the whole mod at
-- load with nothing on screen to say why.
local FALLBACK_SYMBOL = { M = "\226\153\130", F = "\226\153\128" }

local function isTable(v)
  return type(v) == "table"
end

local function posInt(v)
  local n = tonumber(v)
  -- NaN compares false against itself. Refuse it here rather than letting
  -- math.floor propagate it into a printed "L nan".
  if not n or n ~= n then return nil end
  n = math.floor(n)
  if n < 0 then return nil end
  return n
end

-- ------- gender

--- The other mod's exports table, or nil.
--
-- Resolved on every call rather than memoised: mods can be enabled and
-- disabled between battles, and a cached nil would outlive the change for the
-- rest of the session.
function M.genderExports()
  if not isTable(mod) or type(mod.find) ~= "function" then return nil end
  local ok, handle = pcall(mod.find, M.GENDER_MOD)
  if not ok or not isTable(handle) then return nil end
  local exports = handle.exports
  return isTable(exports) and exports or nil
end

local function exportsFrom(deps)
  if isTable(deps) and deps.gender ~= nil then
    return isTable(deps.gender) and deps.gender or nil
  end
  return M.genderExports()
end

--- The Attack DV, whichever dialect the monster is spelled in.
--
-- The two blocks are read one at a time and NOT walked as `ipairs({ dvs, ivs })`.
-- A mediated sheet has no `dvs`, so that list would be `{ nil, ivs }` -- a table
-- with a hole at index 1, which ipairs stops on before it ever reaches the ivs.
-- The symptom was silent and exactly wrong-shaped: gender resolved for your own
-- party (which has `dvs`) and never once for an MMO opponent (which has `ivs`).
local function dvFrom(block)
  if not isTable(block) then return nil end
  for _, key in ipairs(DV_ATTACK_KEYS) do
    local n = tonumber(block[key])
    if n and n == n then return math.floor(n) end
  end
  return nil
end

function M.attackDv(monster)
  if not isTable(monster) then return nil end
  local found = dvFrom(monster.dvs)
  if found ~= nil then return found end
  return dvFrom(monster.ivs)
end

--- The registry id to look art and gender ratios up by.
--
-- Never the prose name: on a mediated sheet that is the nickname, and a
-- nickname resolves to nothing in either registry.
function M.speciesId(monster)
  if not isTable(monster) then return nil end
  local id = monster.speciesId
  if type(id) == "string" and id ~= "" then return id end
  -- A save mon carries no speciesId because its `species` IS the registry id.
  -- The three fields below are what only a save mon has.
  if monster.nickname ~= nil or monster.dvs ~= nil or monster.stats ~= nil then
    id = monster.species
    if type(id) == "string" and id ~= "" then return id end
  end
  return nil
end

--- "M", "F", or nil (genderless, unknown, or no gender mod installed).
--
-- `deps.gender` overrides the resolved exports so the suite can drive this
-- without the other mod installed.
-- `deps.speciesId` overrides the id this resolves ratios by. A Battlefield SEAT
-- needs it: a seat spells things the other way round from a wire sheet
-- (`species` is the registry key, `name` is the prose), so letting speciesId()
-- guess would answer nil and silently drop the gender.
function M.gender(monster, deps)
  if not isTable(monster) then return nil end
  local exports = exportsFrom(deps)
  if not isTable(exports) then return nil end

  -- A real save mon goes through genderOf, which also honours the mod's own
  -- lock sheet and its GENDER-OOZE overrides. Asking genderOfSpecies instead
  -- would silently ignore a monster the player deliberately changed.
  if isTable(monster.dvs) and type(exports.genderOf) == "function" then
    local ok, got = pcall(exports.genderOf, monster)
    if ok then
      return (got == "M" or got == "F") and got or nil
    end
  end

  if type(exports.genderOfSpecies) ~= "function" then return nil end
  local id = (isTable(deps) and type(deps.speciesId) == "string"
    and deps.speciesId ~= "" and deps.speciesId) or M.speciesId(monster)
  local attack = M.attackDv(monster)
  if id == nil or attack == nil then return nil end
  local ok, got = pcall(exports.genderOfSpecies, id, { attack = attack })
  if ok and (got == "M" or got == "F") then return got end
  return nil
end

--- The GB charmap code for a gender, for Font.drawCode.
-- nil when there is nothing to draw -- genderless reads as absent, per the
-- series, rather than as a third glyph.
function M.genderTile(gender, deps)
  if gender ~= "M" and gender ~= "F" then return nil end
  local exports = exportsFrom(deps)
  if isTable(exports) and type(exports.tile) == "function" then
    local ok, code = pcall(exports.tile, gender)
    if ok and tonumber(code) then return tonumber(code) end
  end
  return FALLBACK_TILE[gender]
end

--- The unicode symbol, for the TrueType (modern) painter.
function M.genderSymbol(gender, deps)
  if gender ~= "M" and gender ~= "F" then return nil end
  local exports = exportsFrom(deps)
  if isTable(exports) and type(exports.symbol) == "function" then
    local ok, sym = pcall(exports.symbol, gender)
    if ok and type(sym) == "string" and sym ~= "" then return sym end
  end
  return FALLBACK_SYMBOL[gender]
end

--- The ink a gender glyph is tinted with, or nil to keep the painter's own.
function M.genderColor(gender, deps)
  if gender ~= "M" and gender ~= "F" then return nil end
  local exports = exportsFrom(deps)
  if isTable(exports) and type(exports.palette) == "function" then
    local ok, rgba = pcall(exports.palette, gender)
    if ok and isTable(rgba) and #rgba >= 3 then return rgba end
  end
  return nil
end

-- ------- names and numbers

--- What a monster is CALLED on a menu row: its nickname when it has one, its
--- species name otherwise.
--
-- `partyRows` used to print `mon.species` outright, which on a mediated sheet
-- is already the prose name but on a save mon threw the player's own nickname
-- away.
function M.displayName(monster, data)
  if not isTable(monster) then return "?" end
  local nick = monster.nickname
  if type(nick) == "string" and nick ~= "" then return nick end
  -- A sheet carries BOTH: `species` is already the display token -- prose, and
  -- the nickname when the monster has one, because the sender resolved it --
  -- while `speciesId` is the registry id. So when both are present the prose
  -- one IS the answer, and looking the id up in the dex would quietly replace
  -- the other player's nickname with a species name.
  if type(monster.speciesId) == "string" and monster.speciesId ~= ""
     and type(monster.species) == "string" and monster.species ~= "" then
    return monster.species
  end
  local id = monster.speciesId or monster.species
  if isTable(data) and isTable(data.pokemon) and id ~= nil then
    local def = data.pokemon[id]
    local name = isTable(def) and def.name
    if type(name) == "string" and name ~= "" then return name end
  end
  local species = monster.species
  if type(species) == "string" and species ~= "" then return species end
  return tostring(id or "?")
end

--- Max HP, whichever shape carries it.
function M.maxHp(monster)
  if not isTable(monster) then return nil end
  local direct = posInt(monster.maxHp)
  if direct and direct > 0 then return direct end
  if isTable(monster.stats) then
    local stat = posInt(monster.stats.hp)
    if stat and stat > 0 then return stat end
  end
  return nil
end

-- ------- the model

--- One list row.
--
-- `iconRow` is the minimal record BattleIcon.draw needs -- it resolves art by
-- `species` -- and is handed over instead of an image so the registry is read
-- at PAINT time. That is what makes whichever icon mod loaded last the one
-- that wins, with no dependency declared here and no load order assumed.
function M.rowFor(monster, index, opts)
  opts = isTable(opts) and opts or {}
  local hp = posInt(isTable(monster) and monster.hp) or 0
  local id = M.speciesId(monster)
  return {
    index = index,
    name = M.displayName(monster, opts.data),
    level = posInt(isTable(monster) and monster.level),
    gender = M.gender(monster, opts),
    hp = hp,
    maxHp = M.maxHp(monster),
    -- A fainted row is shown and refused, never hidden: the player has to be
    -- able to see WHY a slot cannot be picked.
    fainted = hp <= 0,
    active = index == opts.active,
    dim = (hp <= 0) or nil,
    speciesId = id,
    iconRow = id and { species = id } or nil,
  }
end

--- Rows for a whole party.
--
-- opts.all keeps every monster (the item menu wants the fainted one, for a
-- Revive); without it the switch menu drops the fainted and the active one,
-- which is the rule both handlers already enforce.
function M.rowsFor(party, opts)
  opts = isTable(opts) and opts or {}
  local out = {}
  if not isTable(party) then return out end
  for index, monster in ipairs(party) do
    local row = M.rowFor(monster, index, opts)
    local keep = opts.all
      or (not row.fainted and (opts.replaceOnly or not row.active))
    if keep then out[#out + 1] = row end
  end
  return out
end

--- The right-hand column of a list row: level, then HP.
--
-- One string rather than two columns because the widget has one right slot,
-- and because level-then-HP is the order the series prints them in.
function M.rightText(row)
  if not isTable(row) then return nil end
  local parts = {}
  if row.level then parts[#parts + 1] = ("L%d"):format(row.level) end
  if row.maxHp then
    parts[#parts + 1] = ("%d/%d"):format(row.hp or 0, row.maxHp)
  end
  if #parts == 0 then return nil end
  return table.concat(parts, " ")
end

--- The extra facts a plate carries beyond Battlefield.plateModel: the icon to
--- draw beside the name, and the gender that follows the level.
--
-- Deliberately additive. plateModel keeps owning name truncation, the HP
-- fraction and the display clocks; this only answers what it never knew.
--
-- **A Battlefield SEAT spells its two name fields the OPPOSITE way round from a
-- wire sheet**, and getting that wrong is what made the first shipped frame
-- show neither icon nor gender on any plate:
--
--   seat        species = "CHARMANDER"  (the REGISTRY KEY)   name = prose
--   wire sheet  species = prose         speciesId = registry key
--
-- So `speciesId()`, which is written for monsters, answered nil for a seat --
-- and a nil id drops the icon and the gender together, in silence. The seat's
-- own `species` is taken as the id here rather than guessed.
--
-- DVs are read off `seat.ivs`, which the seat builder stamps from whatever
-- sheet this client actually holds. That is the ally's own party, and the wild
-- foe's uploaded sheet; a remote PVP opponent's sheet is never retained
-- client-side, so their plate has no gender and correctly shows none.
function M.plateExtras(seat, opts)
  opts = isTable(opts) and opts or {}
  if not isTable(seat) then return {} end
  local monster = isTable(seat.mon) and seat.mon or seat
  local id = nil
  if type(seat.species) == "string" and seat.species ~= "" then
    id = seat.species
  else
    id = M.speciesId(monster)
  end
  local deps = { gender = opts.gender, speciesId = id }
  return {
    gender = M.gender(monster, deps),
    speciesId = id,
    iconRow = id and { species = id } or nil,
  }
end

return M
