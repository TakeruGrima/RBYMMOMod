-- Which overworld sprites a player may wear.
--
-- Derived from the live sprite catalog rather than hardcoded, so a ROM or a
-- mod that adds characters offers them without this file changing. What is
-- hardcoded is only what to *leave out*: the catalog carries boulders,
-- Poke Balls, a fossil and a sleeping gambler alongside the people.
--
-- Non-people are excluded for a practical reason as well as a cosmetic one.
-- A walking avatar plays a two-frame step cycle; an object sheet has no
-- such frames, so wearing a boulder would animate wrongly on every other
-- player's screen, not just look odd.

local need, mod = ...
local Config = need("Config")

local M = {}

-- Things in the sprite catalog that are not a person.
local NOT_PEOPLE = {
  SPRITE_BIRD = true, SPRITE_BOULDER = true, SPRITE_CLIPBOARD = true,
  SPRITE_FAIRY = true, SPRITE_FOSSIL = true, SPRITE_MONSTER = true,
  SPRITE_OLD_AMBER = true, SPRITE_PAPER = true, SPRITE_POKEDEX = true,
  SPRITE_POKE_BALL = true, SPRITE_SEEL = true, SPRITE_SNORLAX = true,
}

-- Poses that are a person but not a usable avatar: the UNUSED_ entries are
-- leftovers the game never places, and an asleep sprite has no walk cycle.
local function excluded(id)
  if NOT_PEOPLE[id] then return true end
  if id:match("^SPRITE_UNUSED_") then return true end
  if id:match("_ASLEEP$") then return true end
  return false
end

-- A sprite record's own `walker` flag says whether it has a walk cycle.
--
-- This matters more than it sounds: over half the *people* in the catalog
-- are stationary NPCs -- NURSE, MOM, GRAMPS, the clerks and guards -- drawn
-- from a sheet with no walking frames. Worn as an avatar they would draw,
-- then break the moment the character took a step. So "any human character"
-- means any that can actually walk.
local function walks(record)
  return type(record) == "table" and record.walker == true
end

M.excluded = excluded

-- "SPRITE_COOLTRAINER_M" -> "COOLTRAINER M"
function M.label(id)
  return (tostring(id):gsub("^SPRITE_", ""):gsub("_", " "))
end

-- Every wearable character, sorted, with RED first because it is the
-- fallback everyone is guaranteed to have.
function M.list()
  local registry = mod.content and mod.content.sprites
  if not registry then return { Config.DEFAULT_SPRITE } end

  local out = {}
  local ok = pcall(function()
    for id, record in registry:each() do
      if type(id) == "string" and id:match("^SPRITE_")
         and not excluded(id) and walks(record) then
        out[#out + 1] = id
      end
    end
  end)
  if not ok or #out == 0 then return { Config.DEFAULT_SPRITE } end

  table.sort(out, function(a, b)
    if a == Config.DEFAULT_SPRITE then return true end
    if b == Config.DEFAULT_SPRITE then return false end
    return a < b
  end)
  return out
end

-- Is this character present in *this* game's catalog?
--
-- The answer can differ between players: a modded catalog, or a different
-- ROM, may not carry what someone else picked. Everyone falls back to RED
-- rather than failing to draw, which is why RED is the one id this mod
-- treats as always-present.
function M.available(id)
  local registry = mod.content and mod.content.sprites
  if not (registry and type(id) == "string") then return false end
  local ok, record = pcall(function() return registry:get(id) end)
  return ok and walks(record) and not excluded(id)
end

function M.resolve(id)
  if M.available(id) then return id end
  return Config.DEFAULT_SPRITE
end

return M
