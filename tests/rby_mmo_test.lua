-- rby_mmo suite.
--
-- Two halves.
--
-- The first drives the real headless loader, which is what proves the mod
-- loads in the game: same Loader, same validate, same merge.  It asserts
-- the mod's *stated effect* -- the screens and seams it claims to install
-- are actually installed -- rather than just that nothing threw.
--
-- The second unit-tests the pure modules through the same resolver main.lua
-- uses, so the files under test are the shipped ones and not a copy.  These
-- are the parts that face the network, and they are the parts worth pinning:
-- everything arriving from another player's process goes through Wire, and
-- everything the trade and battle code sees goes through SessionNet.
--
-- Run: luajit tests/rby_mmo_test.lua   (from the engine checkout root)

package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.modkit")
local check, eq = T.check, T.eq

local MOD_PATH = "mods/rby_mmo"

-- ------------------------------------------------------------------
-- 1. the real load
-- ------------------------------------------------------------------

-- The committed fixture dataset, not a ROM import: this tier has to run on
-- a checkout that has never seen a ROM, which is what CI is.
--
-- The link surface is snapshotted from a no-mod load first, so the "vanilla
-- is untouched" assertion below compares against the engine's own baseline
-- rather than against hardcoded Red values the fixture does not carry.
-- That is the check that makes affects_link=false in the manifest honest:
-- if this mod ever starts writing into pokemon/moves/type_chart, two
-- players' link fingerprints diverge and this test fails first.
local function linkSurface(data)
  local rows = {}
  for _, registry in ipairs({ "pokemon", "moves" }) do
    local ids = {}
    for id in pairs(data[registry] or {}) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
      local record = data[registry][id]
      local stats = record.baseStats or {}
      rows[#rows + 1] = table.concat({
        registry, id,
        tostring(record.power), tostring(record.accuracy), tostring(record.type),
        tostring(stats.hp), tostring(stats.attack), tostring(stats.defense),
        tostring(stats.speed), tostring(stats.special),
      }, "|")
    end
  end
  return table.concat(rows, "\n")
end

local baseline = T.sdk.loadNone()
local vanillaSurface = linkSurface(baseline.data)
baseline.release()
check(#vanillaSurface > 0, "the baseline snapshot is not vacuously empty")

-- The manifest sets experimental=true, so the loader leaves the mod off
-- until the player turns it on in the mod manager.  That is the intended
-- behaviour for a mod that opens a network connection -- installing it must
-- not be what starts talking to a server -- so it is asserted, not worked
-- around.
local offByDefault = T.sdk.loadMod(MOD_PATH)
eq(#offByDefault.errors, 0, "an experimental mod still discovers cleanly")
eq(offByDefault.mod.state, "disabled",
   "experimental means off until the player opts in")
eq(offByDefault.loader.content.screens:get("RbyMmoMain"), nil,
   "and a disabled mod installs nothing")
offByDefault.release()

-- Everything past here is the opted-in mod, reached by handing the loader a
-- filesystem whose options.lua already has it enabled -- the same file the
-- mod manager writes when the player flips the switch.
local function enabledFs()
  local inner = T.fs.new(".")
  local OPTIONS = "options.lua"
  local body = "return { mods = { rby_mmo = true } }"
  local loadstr = loadstring or load
  local fs = { root = inner.root }

  function fs.read(path)
    if path == OPTIONS then return body end
    return inner.read(path)
  end
  function fs.load(path)
    if path == OPTIONS then return loadstr(body, OPTIONS) end
    return inner.load(path)
  end
  function fs.getInfo(path)
    if path == OPTIONS then return { type = "file" } end
    return inner.getInfo(path)
  end
  -- narrowed to this mod alone: the checkout also carries the gallery and
  -- nuzlocke, and a suite that loaded those too would be testing them
  function fs.getDirectoryItems(path)
    if path == "mods" then return { "rby_mmo" } end
    return inner.getDirectoryItems(path)
  end
  return fs
end

local run = T.sdk.loadMod(MOD_PATH, { fs = enabledFs() })

eq(#run.errors, 0, "loads clean through the headless loader")
check(run.mod ~= nil, "the loader found the mod")
eq(run.mod.state, "loaded", "the mod reached the loaded state once enabled")

-- the screens it says it installs
local screens = run.loader.content.screens
for _, id in ipairs({
  "RbyMmoMain", "RbyMmoRoster", "RbyMmoActions", "RbyMmoChatLog",
  "RbyMmoScope", "RbyMmoCompose", "RbyMmoPick", "RbyMmoText",
  "RbyMmoConfirm", "RbyMmoState",
  "RbyMmoHostSetup", "RbyMmoHostInfo", "RbyMmoJoinAddress",
}) do
  check(screens:get(id) ~= nil, "screen " .. id .. " is registered")
end

-- the seams it says it wraps
for _, hook in ipairs({ "input.step", "render.hud", "ui.start_menu.items",
                        "ui.naming.grid" }) do
  local chain = run.loader.hooks.chains[hook]
  check(chain ~= nil and #chain > 0, "wraps " .. hook)
end

-- the inter-mod surface it publishes
local exports = run.loader.exports["rby_mmo"]
check(type(exports) == "table", "publishes exports")
check(type(exports.isHosting) == "function", "exports isHosting")
eq(exports.isHosting(), false, "and reports not hosting on a fresh load")
check(type(exports.hostAddress) == "function", "exports hostAddress")
eq(exports.hostAddress(), false, "which is falsy while not hosting")
check(type(exports.chat) == "function", "exports chat")
eq(#exports.chat(), 0, "with no messages on a fresh load")
check(type(exports.isConnected) == "function", "exports isConnected")
check(type(exports.players) == "function", "exports players")
eq(exports.isConnected(), false, "reports disconnected before connecting")
eq(#exports.players(), 0, "the roster starts empty")

-- Vanilla must be untouched.  This mod adds multiplayer; it does not change
-- Gen 1 content, which is exactly what affects_link=false promises about
-- the link fingerprint.
eq(linkSurface(run.data), vanillaSurface,
   "the link surface is byte-identical with the mod installed")

run.release()

-- ------------------------------------------------------------------
-- 2. the modules, through main.lua's own resolver
-- ------------------------------------------------------------------

local stubSave, stubOptions, stubPipelines = {}, {}, {}
local stubSprites = {}

local stubMod = {
  id = "rby_mmo",
  path = MOD_PATH,
  log = {
    info = function() end,
    warn = function() end,
    error = function() end,
  },
  -- mod.save is writable by a mod; mod.options is not. The stub mirrors
  -- that asymmetry, because the settings code depends on it.
  save = {
    get = function(_, key, default)
      local value = stubSave[key]
      if value == nil then return default end
      return value
    end,
    set = function(_, key, value) stubSave[key] = value end,
  },
  options = {
    define = function() end,
    get = function(_, key) return stubOptions[key] end,
  },
  -- only what Overlay's pipeline query touches
  content = {
    sprites = {
      each = function()
        local id = nil
        return function()
          id = next(stubSprites, id)
          if id == nil then return nil end
          return id, stubSprites[id]
        end
      end,
      get = function(_, id) return stubSprites[id] end,
    },
    render_pipelines = {
      each = function(self)
        local id = nil
        return function()
          id = next(stubPipelines, id)
          if id == nil then return nil end
          return id, stubPipelines[id]
        end
      end,
    },
  },
}

local function resolver()
  local loadstr = loadstring or load
  local cache = {}
  local function need(name)
    if cache[name] then return cache[name] end
    local handle = io.open(MOD_PATH .. "/src/" .. name .. ".lua", "rb")
    if not handle then error("missing module " .. name, 0) end
    local body = handle:read("*a")
    handle:close()
    local chunk = assert(loadstr(body, "@" .. name .. ".lua"))
    cache[name] = chunk(need, stubMod)
    return cache[name]
  end
  return need
end

local need = resolver()
local Config = need("Config")
local Wire = need("Wire")
local Roster = need("Roster")
local Chat = need("Chat")
local SessionNet = need("SessionNet")
local Transport = need("Transport")

-- ------------------------------------------------------------------
-- Sha256: pinned against the published standard, then against Node
-- ------------------------------------------------------------------
--
-- src/Sha256.lua is a from-scratch SHA-256 / HMAC-SHA256 (its own header
-- explains why: love.data is unavailable under this headless suite). A
-- hand-written digest is exactly the kind of code that can be subtly wrong
-- and still agree with itself, so every check below is against an outside
-- source of truth -- RFC 4231, FIPS 180-4, or Node's node:crypto via
-- tests/fixtures/hmac_vectors.lua -- never Sha256 asserting against Sha256.

local Sha256 = need("Sha256")
local Vectors = dofile(MOD_PATH .. "/tests/fixtures/hmac_vectors.lua")

-- hex -> raw bytes, for RFC 4231's keys and messages, several of which are
-- not text (a 20/131-byte key of 0x0b/0xaa, 50 bytes of 0xdd)
local function fromHex(hex)
  return (hex:gsub("..", function(cc) return string.char(tonumber(cc, 16)) end))
end

for _, v in ipairs(Vectors.SHA256) do
  eq(Sha256.hex(v.input), v.digest,
     "Sha256.hex matches the standard vector: " .. v.label)
end

for _, v in ipairs(Vectors.RFC_HMAC) do
  eq(Sha256.hmacHex(fromHex(v.keyHex), fromHex(v.dataHex)), v.digest,
     "Sha256.hmacHex matches RFC 4231 test case " .. v.case)
end
-- case 6 alone exercises the key-longer-than-the-block path (131 bytes into
-- a 64-byte block), so it is worth naming on its own rather than trusting
-- the loop above to have covered it
local case6
for _, v in ipairs(Vectors.RFC_HMAC) do
  if v.case == 6 then case6 = v end
end
check(case6 ~= nil, "RFC 4231 case 6 is present in the fixture")
eq(#fromHex(case6.keyHex), 131,
   "case 6's key really is longer than the HMAC block size")

-- the cross-language known-answer vector server/auth.test.js already fixes.
-- The Lua-side key is the *normalised* code as ASCII bytes -- never the
-- dashed display form -- which is what Wire.code produces and what Hub.lua
-- actually signs with, so this doubles as a Wire.code cross-check.
eq(Wire.code(Vectors.KAT.code), "ABCDEFGHJKMNPQRS",
   "the known-answer vector's code normalises the way the digest assumes")
eq(Sha256.hmacHex(Wire.code(Vectors.KAT.code), Vectors.KAT.nonce), Vectors.KAT.digest,
   "the cross-language known-answer vector (also fixed by server/auth.test.js) "
   .. "reproduces exactly")

-- the generated cross-language set: 24 (code, nonce) -> digest triples Node
-- produced, covering dashed/undashed/lowercase/messy spellings of one code,
-- every character of Config.CODE_ALPHABET across the set, and 32-hex
-- nonces throughout. A drift in either Wire.code or Sha256.hmacHex shows up
-- here as a specific failing label, not as "wrong join code" in the field.
for _, v in ipairs(Vectors.CROSS) do
  eq(Wire.code(v.code), v.normalized,
     "Wire.code normalises like Node's normalizeCode: " .. v.label)
  eq(Sha256.hmacHex(v.normalized, v.nonce), v.digest,
     "Sha256.hmacHex matches the Node-generated vector: " .. v.label)
end

-- embedded \0 does not truncate the digest the way a C-string read would
local withNul = fromHex("6162630064656600676869")
eq(#withNul, 11, "the embedded-\\0 fixture really is 11 raw bytes")
eq(Sha256.hex(withNul), "039829b9687ee660b05223c59daa86348bf5856dda159e65412a454c57dc1911",
   "a NUL byte inside the message does not truncate the digest")

-- the 55/56/64-byte padding boundaries: FIPS 180-4 padding needs a 0x80
-- byte plus an 8-byte length field, so a message must be under 56 bytes to
-- keep its padding inside the same block; 56 spills into a second block,
-- and 64 is exactly one full block with the pad occupying an entire block
-- of its own
eq(Sha256.hex(string.rep("a", 55)), "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318",
   "55 bytes -- padding still fits in the same block")
eq(Sha256.hex(string.rep("a", 56)), "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a",
   "56 bytes -- padding spills into a second block")
eq(Sha256.hex(string.rep("a", 64)), "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb",
   "64 bytes -- exactly one full block, padding is a block of its own")

-- ------- Sha256.equals: constant-time, but still just equality

check(Sha256.equals("abc123", "abc123"), "equals is true for identical strings")
check(not Sha256.equals("abc123", "abc124"), "and false for a one-character difference")
check(not Sha256.equals("abc", "abcd"), "and false when the lengths differ")
check(Sha256.equals(fromHex("610062"), fromHex("610062")),
      "and true for equal strings containing \\0")

-- ------- Wire: the trust boundary

eq(Wire.text("HELLO"), "HELLO", "plain text survives")
eq(Wire.text("  spaced   out  "), "spaced out", "runs of whitespace collapse")
eq(Wire.text("drop\0these\tbytes"), "dropthesebytes", "control bytes are dropped")
eq(Wire.text("emoji \240\159\152\128 gone"), "emoji gone",
   "multi-byte sequences the font cannot draw are dropped")
eq(Wire.text(""), nil, "an empty string is not a message")
eq(Wire.text("   "), nil, "whitespace alone is not a message")
eq(Wire.text(12345), nil, "a non-string is not a message")
eq(#Wire.text(string.rep("a", 500)), Config.MESSAGE_MAX, "text is capped")
eq(#Wire.name(string.rep("b", 50)), Config.NAME_MAX, "names are capped shorter")

eq(Wire.id("abc_123-x"), "abc_123-x", "a well-formed id survives")
eq(Wire.id("../../etc/passwd"), nil, "a path is not an id")
eq(Wire.id(""), nil, "an empty id is rejected")

eq(Wire.int("42", 0, 100), 42, "a numeric string becomes a number")
eq(Wire.int(7.9, 0, 100), 7, "floats are floored")
eq(Wire.int(0 / 0, 0, 100), nil, "NaN is rejected")
eq(Wire.int(math.huge, 0, 100), nil, "infinity is rejected")
eq(Wire.int(500, 0, 100), nil, "out of range is rejected")
eq(Wire.int(-1, 0, 100), nil, "below range is rejected")

-- Sprite ids are identifiers, not prose. Running one through the chat
-- sanitiser strips the underscore, and SPRITE_RED silently became
-- SPRITERED -- which missed the catalog lookup and drew every remote player
-- as the fallback. Found by the first real two-instance run; pinned here.
eq(Wire.spriteId("SPRITE_RED"), "SPRITE_RED", "an underscore survives a sprite id")
eq(Wire.text("SPRITE_RED"), "SPRITERED",
   "which the prose sanitiser would have eaten -- hence the separate one")
eq(Wire.spriteId("SPRITE_COOLTRAINER_M"), "SPRITE_COOLTRAINER_M",
   "several underscores too")
eq(Wire.spriteId("../etc/passwd"), nil, "a path is not a sprite id")
eq(Wire.spriteId("has space"), nil, "nor is anything with a space")
eq(Wire.spriteId(42), nil, "nor a non-string")
eq(Wire.presence({ id = "s1", name = "ANN", sprite = "SPRITE_BLUE" }).sprite,
   "SPRITE_BLUE", "and presence carries it through intact")

eq(Wire.facing("left"), "left", "a real facing survives")
eq(Wire.facing("sideways"), nil, "an invented facing is rejected")
eq(Wire.mapId("PALLET_TOWN"), "PALLET_TOWN", "a map id survives")
eq(Wire.mapId("../secret"), nil, "a traversal is not a map id")

local presence = Wire.presence({
  id = "p1", name = "ASH", sprite = "SPRITE_RED",
  map = "PALLET_TOWN", x = 5, y = 6, facing = "up",
})
check(presence ~= nil, "a full presence sanitises")
eq(presence.x, 5, "position survives")
eq(presence.busy, false, "busy defaults to false")

eq(Wire.presence({ name = "NOID" }), nil, "presence without an id is rejected")
eq(Wire.presence({ id = "p2" }), nil, "presence without a name is rejected")

-- a half-formed position must not place an avatar at a made-up cell
local partial = Wire.presence({ id = "p3", name = "MISTY", map = "VIRIDIAN", x = 4 })
check(partial ~= nil, "presence survives a missing position")
eq(partial.map, nil, "an incomplete position is dropped whole")
eq(partial.x, nil, "x goes with it")

eq(Wire.presence({ id = "p4", name = "BROCK" }).sprite, Config.DEFAULT_SPRITE,
   "a missing sprite falls back rather than failing")

-- ------- payload shape (the relay's only defence)

local function nest(depth)
  local node = { leaf = 1 }
  for _ = 1, depth do node = { node } end
  return node
end

eq(Wire.payloadOk({ type = "party", mons = { { species = "PIKACHU" } } }), true,
   "an ordinary link payload passes")
eq(Wire.payloadOk(nest(6)), true, "so does a party-shaped nesting depth")
eq(Wire.payloadOk("not a table"), false, "a scalar is not a payload")
eq(Wire.payloadOk(nil), false, "nor is nothing")

-- The regression. src/link/Json.lua decodes inside a pcall and tolerates
-- input far deeper than Json.encode can re-emit, so a payload nested a few
-- thousand levels used to decode fine and then throw while being forwarded
-- -- taking the host's whole game down with it. ~12KB of brackets, well
-- under the line cap, from any player already in a session with you.
eq(Wire.payloadOk(nest(6000)), false, "a payload deep enough to break the "
   .. "encoder is refused before it is forwarded")
eq(Wire.payloadOk(nest(Config.PAYLOAD_MAX_DEPTH + 5)), false,
   "and so is anything past the depth budget")

-- breadth is bounded too, so a flat-but-enormous payload cannot get through
local wide = {}
for i = 1, Config.PAYLOAD_MAX_NODES + 50 do wide[i] = i end
eq(Wire.payloadOk(wide), false, "an over-wide payload is refused")

-- ------- Wire.code / Wire.hex / Wire.formatCode: the join-code sanitisers
--
-- Wire.code normalises exactly the way server/lib/auth.js's normalizeCode
-- does -- same inputs, same verdicts -- so both suites assert the same
-- cases from testNormalization() in server/auth.test.js rather than two
-- suites that quietly drift apart on what a "valid code" is.

local CODE_DASHED = "ABCD-EFGH-JKMN-PQRS"
local CODE_UNDASHED = "ABCDEFGHJKMNPQRS"
local CODE_LOWER = "abcd-efgh-jkmn-pqrs"
local CODE_MESSY = " abcd efgh, jkmn! pqrs?? "

eq(Wire.code(CODE_DASHED), CODE_UNDASHED, "the dashed form normalises to the bare 16 characters")
eq(Wire.code(CODE_UNDASHED), CODE_UNDASHED, "the undashed form is unchanged")
eq(Wire.code(CODE_LOWER), CODE_UNDASHED, "lowercase normalises the same as uppercase")
eq(Wire.code(CODE_MESSY), CODE_UNDASHED, "spaces and stray punctuation are stripped")

eq(Wire.code("ABCD-EFGH-JKMN"), nil, "a too-short input is rejected")
eq(Wire.code("ABCD-EFGH-JKMN-PQRS-TVWX"), nil, "a too-long input is rejected")

eq(Wire.code(42), nil, "a number is not a code")
eq(Wire.code(true), nil, "a boolean is not a code")
eq(Wire.code({}), nil, "a table is not a code")
eq(Wire.code(nil), nil, "nil is not a code")

eq(Wire.formatCode(Wire.code(CODE_DASHED)), CODE_DASHED,
   "formatCode(code(x)) round-trips the canonical dashed form")
eq(Wire.formatCode(Wire.code(CODE_MESSY)), CODE_DASHED,
   "a messy input round-trips to the same canonical dashed form")

-- ------- Wire.hex: the digest/nonce sanitiser
--
-- Not "exactly N hex characters" but "hex, and no longer than the caller's
-- budget" -- the same string accepts a 64-char digest with the default cap
-- and a 32-char nonce under Config.NONCE_HEX, which is exactly the two
-- shapes that cross the wire (mmo.challenge's nonce, mmo.auth's response).

local HEX64 = string.rep("a1", 32)
local HEX32 = string.rep("b2", 16)

eq(Wire.hex(HEX64), HEX64, "64 lowercase hex characters is accepted at the digest length")
eq(#Wire.hex(HEX64), Config.DIGEST_HEX, "matching the digest length exactly")
eq(Wire.hex(HEX32, Config.NONCE_HEX), HEX32, "32 lowercase hex characters is accepted as a nonce")
eq(Wire.hex(HEX64, Config.NONCE_HEX), nil, "64 hex characters exceeds the 32-hex nonce budget")

eq(Wire.hex(HEX64:upper()), nil, "uppercase hex is rejected")
eq(Wire.hex(HEX64 .. "a1"), nil, "past the default digest budget is rejected")
eq(Wire.hex("not-hex-at-all!!"), nil, "non-hex characters are rejected")
eq(Wire.hex(""), nil, "an empty string is rejected")
eq(Wire.hex(12345), nil, "a non-string is rejected")
eq(Wire.hex(nil), nil, "nil is rejected")

-- ------- Roster

local roster = Roster.new()
roster:setSelf("me")

roster:put(Wire.presence({ id = "me", name = "SELF", map = "PALLET", x = 1, y = 1 }))
eq(roster.count, 0, "our own presence is never added as a remote player")

roster:put(Wire.presence({ id = "a", name = "ANN", map = "PALLET", x = 5, y = 5 }))
roster:put(Wire.presence({ id = "b", name = "BOB", map = "PALLET", x = 30, y = 30 }))
roster:put(Wire.presence({ id = "c", name = "CAL", map = "VIRIDIAN", x = 5, y = 5 }))
eq(roster.count, 3, "three remote players are tracked")

eq(#roster:onMap("PALLET"), 2, "onMap filters by map")
eq(#roster:near("PALLET", 5, 6, Config.LOCAL_RADIUS), 1, "near filters by distance")
eq(roster:near("PALLET", 5, 6, Config.LOCAL_RADIUS)[1].name, "ANN",
   "and returns the close one")

eq(Roster.distance({ x = 0, y = 0 }, { x = 3, y = 4 }), 4,
   "distance is Chebyshev, not Euclidean -- the world is a grid")

eq(roster:at("PALLET", 5, 5).name, "ANN", "at() finds who is standing on a cell")
eq(roster:at("PALLET", 9, 9), nil, "at() finds nobody on an empty cell")

-- a move must not erase the identity that arrived with the join
roster:move("a", "PALLET", 6, 5, "right")
eq(roster:get("a").name, "ANN", "a move keeps the name")
eq(roster:get("a").sprite, Config.DEFAULT_SPRITE, "a move keeps the sprite")
eq(roster:get("a").x, 6, "and applies the new position")

local sorted = roster:sorted()
eq(sorted[1].name, "ANN", "sorted is stable and alphabetical")
eq(sorted[3].name, "CAL", "all the way down")

roster:remove("a")
eq(roster.count, 2, "remove decrements the count")
eq(roster:remove("nosuch"), nil, "removing an unknown id is a no-op")
eq(roster.count, 2, "and does not corrupt the count")

-- ------- Chat

local chat = Chat.new()
for i = 1, Config.CHAT_HISTORY + 20 do
  chat:push({ name = "N", scope = "global", text = "line " .. i })
end
eq(#chat.history, Config.CHAT_HISTORY, "history is bounded")
eq(chat.history[#chat.history].text, "line " .. (Config.CHAT_HISTORY + 20),
   "and keeps the newest")

chat:clear()
chat:push({ name = "ANN", scope = "global", text = "hi" })
eq(chat.unread, 1, "an inbound line counts as unread")
chat:push({ name = "ME", scope = "global", text = "hey", outgoing = true })
eq(chat.unread, 1, "our own line does not")
chat:markRead()
eq(chat.unread, 0, "opening the log clears it")

eq(chat:line({ name = "ANN", scope = "global", text = "hi" }), "[G]ANN: hi",
   "a global line is tagged")
eq(chat:line({ name = "ANN", scope = "private", text = "psst" }), "[W]ANN: psst",
   "a whisper is tagged differently")

chat:bubble("a", "over here", "global")
eq(chat:bubbleFor("a"), "over here", "a global message bubbles")
chat:bubble("a", "newer", "global")
eq(chat:bubbleFor("a"), "newer", "a newer bubble replaces the older one")

eq(chat:bubble("b", "secret", "private"), nil, "a whisper never bubbles")
eq(chat:bubbleFor("b"), nil, "so nothing is drawn over their head")

chat:update(Config.BUBBLE_SECONDS - 0.1)
check(chat:bubbleFor("a") ~= nil, "a bubble survives until its time is up")
chat:update(0.2)
eq(chat:bubbleFor("a"), nil, "and then expires")

-- ------- SessionNet: the shim the engine's link code runs over

local sent = {}
local fakeTransport = {
  ready = true,
  send = function(self, msgType, payload)
    sent[#sent + 1] = { type = msgType, payload = payload }
    return true
  end,
  isReady = function(self) return self.ready end,
}

local session = SessionNet.new(fakeTransport, "peer1", "RIVAL")
eq(session.closed, false, "a new session is open")
eq(session.paired, true, "and presents as paired, which link code expects")

session:send({ type = "party", mons = {} })
eq(#sent, 1, "sending puts exactly one message on the transport")
eq(sent[1].type, Wire.RELAY, "wrapped in a relay envelope")
eq(sent[1].payload.to, "peer1", "addressed to the peer")
eq(sent[1].payload.payload.type, "party",
   "with the engine's own message untouched inside it")

session:deliver({ type = "pick", index = 2 })
session:deliver({ type = "confirm", ok = true })
local polled = session:poll()
eq(#polled, 2, "poll drains everything delivered")
eq(polled[1].type, "pick", "in order")
eq(#session:poll(), 0, "and leaves the inbox empty")

-- LinkBattle watches .closed to notice the link died underneath it
fakeTransport.ready = false
session:update()
eq(session.closed, true, "a dead transport closes the session")

sent = {}
local closing = SessionNet.new(fakeTransport, "peer2", "GARY")
closing:close()
eq(closing.closed, true, "close marks it closed")
eq(sent[1].type, Wire.SESSION_LEAVE, "and tells the hub to tear the session down")
sent = {}
closing:close()
eq(#sent, 0, "closing twice does not send a second goodbye")

-- ------- Transport framing

local fakeNet = {
  closed = false,
  outbox = {},
  inbox = {},
  send = function(self, msg) self.outbox[#self.outbox + 1] = msg end,
  update = function() end,
  poll = function(self)
    local msgs = self.inbox
    self.inbox = {}
    return msgs
  end,
  close = function(self) self.closed = true end,
}

local transport = Transport.new()
transport:attach(fakeNet)
check(transport:isOpen(), "an attached transport is open")
eq(transport:isReady(), false, "but not ready until the hub welcomes us")

transport:send(Wire.HELLO, { name = "ASH" })
eq(fakeNet.outbox[1].type, Wire.HELLO, "send stamps the type")
eq(fakeNet.outbox[1].name, "ASH", "and carries the payload")

fakeNet.inbox = {
  { type = Wire.WELCOME, id = "x" },
  "not a table",
  { noType = true },
  { type = Wire.PONG },
}
local got = transport:update(0.016)
eq(#got, 1, "malformed messages and pongs are filtered out")
eq(got[1].type, Wire.WELCOME, "leaving the real one")

transport:markReady()
check(transport:isReady(), "markReady flips it to ready")

-- silence past the timeout must not leave the player staring at a frozen
-- world believing they are still connected
transport:update(Config.TIMEOUT + 1)
eq(transport:isOpen(), false, "a silent hub times out")
check(transport.error ~= nil, "and says why")

-- ------------------------------------------------------------------
-- 3. Hub: the relay a hosting player runs
-- ------------------------------------------------------------------
--
-- Hub is deliberately socket-free so it can be driven here with fake peers.
-- These are the same behaviours server/hub.test.js pins on the Node side;
-- two implementations of one protocol only stay honest if both are tested.

local Hub = need("Hub")

local function fakePeer()
  local peer = { outbox = {}, closed = false }
  function peer:send(msg) self.outbox[#self.outbox + 1] = msg end
  function peer:close() self.closed = true end
  return peer
end

-- pull the first message of a type off a peer, so later assertions are not
-- confused by traffic an earlier step left behind
local function take(peer, msgType)
  for i, msg in ipairs(peer.outbox) do
    if msg.type == msgType then return table.remove(peer.outbox, i) end
  end
  return nil
end

local function saw(peer, msgType)
  return take(peer, msgType) ~= nil
end

local function join(hub, name, map, x, y)
  local peer = fakePeer()
  local client = hub:accept(peer)
  if client then
    hub:receive(client, { type = Wire.HELLO, proto = Config.PROTOCOL,
      name = name, map = map, x = x, y = y, facing = "down" })
  end
  return client, peer
end

-- ------- the cap the host chose

eq(Hub.new({}).limit, Config.DEFAULT_PLAYERS, "no limit given falls back to 4")
eq(Hub.new({ maxPlayers = 12 }).limit, 12, "the host's number is honoured")
eq(Hub.new({ maxPlayers = 999 }).limit, Config.MAX_PLAYERS,
   "above the ceiling clamps to 64")
eq(Hub.new({ maxPlayers = 1 }).limit, Config.MIN_PLAYERS,
   "below the floor clamps to 2")
eq(Hub.new({ maxPlayers = "nonsense" }).limit, Config.DEFAULT_PLAYERS,
   "a non-number falls back rather than erroring")

local hub = Hub.new({ maxPlayers = 3 })
local ann, annPeer = join(hub, "ANN", "PALLET", 5, 5)
local bob, bobPeer = join(hub, "BOB", "PALLET", 6, 5)
local cal, calPeer = join(hub, "CAL", "PALLET", 40, 40)

eq(hub.count, 3, "three players fill a limit of three")
check(take(annPeer, Wire.WELCOME) ~= nil, "the first player is welcomed")
local bobWelcome = take(bobPeer, Wire.WELCOME)
eq(#bobWelcome.players, 1, "the second sees the first on the roster")
eq(bobWelcome.players[1].name, "ANN", "by name")
check(saw(annPeer, Wire.JOIN), "and the first is told about the second")

-- The cap is charged at hello, not on connect. A socket that has not
-- introduced itself is not a player, so it gets accepted and then refused
-- when it tries to claim a seat.
local fourth, fourthPeer = join(hub, "FOURTH", "PALLET", 1, 1)
check(fourth ~= nil, "a fourth connection is accepted")
local refusal = take(fourthPeer, Wire.ERROR)
check(refusal ~= nil, "but refused when it says hello")
check(refusal.message:find("full"), "saying it is full")
check(refusal.message:find("3"), "and naming the limit")
check(fourthPeer.closed, "and the connection is closed")
eq(hub.players, 3, "so it never became a player")

-- ------- an idle connection cannot hold a seat
--
-- This is the slot-exhaustion fix. Charging the player cap on connect meant
-- four sockets that said nothing locked everyone out of a four-player game.

local idleHub = Hub.new({ maxPlayers = 2 })
local idlePeer = fakePeer()
local idle = idleHub:accept(idlePeer)
check(idle ~= nil, "a silent connection is accepted")
eq(idleHub.players, 0, "but is not a player")
eq(idleHub:isFull(), false, "and does not fill the game")

-- two real players still fit alongside it
check(select(1, join(idleHub, "ONE")) ~= nil, "a real player still fits")
check(select(1, join(idleHub, "TWO")) ~= nil, "and so does a second")
eq(idleHub.players, 2, "both became players")
eq(idleHub:isFull(), true, "which is what fills the game")

-- ...and the silent one is reaped once its welcome runs out
idleHub:update(Config.HELLO_TIMEOUT + 1)
check(idlePeer.closed, "the silent connection is dropped after the deadline")
check(take(idlePeer, Wire.ERROR) ~= nil, "having been told why")
eq(idleHub.clients[idle.id], nil, "and is gone from the table")

-- a flood of silent connections is bounded rather than unbounded
local floodHub = Hub.new({ maxPlayers = 2 })
local accepted = 0
for _ = 1, Config.MAX_PENDING + 6 do
  if floodHub:accept(fakePeer()) then accepted = accepted + 1 end
end
eq(accepted, Config.MAX_PENDING, "pending connections are capped")
eq(floodHub.players, 0, "and none of them are players")

-- ------- authentication: an optional join-code gate in front of admission
--
-- Same handshake server/lib/relay.js drives on the Node side: hello, then
-- -- only when the hub carries a code -- a challenge, then an HMAC response
-- before the peer is admitted. A hub with no code configured must behave
-- exactly as it always did: hello admits straight away and no challenge
-- ever crosses the wire, which is the regression guard every player who
-- joined before codes existed depends on.

local openHub = Hub.new({ maxPlayers = 3 })
eq(openHub:requiresCode(), false, "a hub built with no join code does not require one")
local openClient, openPeer = join(openHub, "OPENPLAYER", "PALLET", 1, 1)
check(openClient ~= nil, "a hub with no join code still admits on hello")
eq(openHub.players, 1, "immediately -- no challenge round trip")
eq(take(openPeer, Wire.CHALLENGE), nil, "and no challenge is ever sent")
check(take(openPeer, Wire.WELCOME) ~= nil, "the welcome arrives exactly as before codes existed")

-- mmo.auth with no outstanding challenge (never issued one, on a hub with
-- no code) is a no-op, not an error
openPeer.outbox = {}
openHub:receive(openClient, { type = Wire.AUTH, response = string.rep("0", 64) })
eq(#openPeer.outbox, 0, "mmo.auth with no outstanding challenge is a no-op")

-- ------- a coded hub

local JOIN_CODE = "ABCD-EFGH-JKMN-PQRS"
local codedHub = Hub.new({ maxPlayers = 3, joinCode = JOIN_CODE })
eq(codedHub:requiresCode(), true, "a hub constructed with a join code requires one")

-- the answer a client owes for a given nonce, computed the way a real
-- client would: normalise the code it was handed, then HMAC the nonce with
-- it -- mirroring src/Sessions.lua / src/Ui.lua, not reaching into the hub
local function answer(rawCode, nonce)
  return Sha256.hmacHex(Wire.code(rawCode), nonce)
end

local codedPeer = fakePeer()
local codedClient = codedHub:accept(codedPeer)
codedHub:receive(codedClient, { type = Wire.HELLO, proto = Config.PROTOCOL,
  name = "ASH", map = "PALLET", x = 1, y = 1, facing = "down" })

eq(codedHub.players, 0, "hello alone does not seat a player on a coded hub")
eq(codedHub:isFull(), false, "so a coded hub with only unanswered challenges is not full")
local challenge = take(codedPeer, Wire.CHALLENGE)
check(challenge ~= nil, "a challenge is sent instead of a welcome")
eq(#challenge.nonce, Config.NONCE_HEX, "the nonce is 32 hex characters")
check(challenge.nonce:match("^[0-9a-f]+$") ~= nil, "and lowercase hex")
eq(take(codedPeer, Wire.WELCOME), nil, "no welcome until the challenge is answered")

-- the correct response admits, and only now charges the seat
codedHub:receive(codedClient, { type = Wire.AUTH, response = answer(JOIN_CODE, challenge.nonce) })
check(take(codedPeer, Wire.WELCOME) ~= nil, "the correct response admits the player")
eq(codedHub.players, 1, "and the seat is charged only on a successful answer")

-- replaying the same accepted response again does nothing: the nonce was
-- consumed the moment it was read, and the client is ready besides
codedPeer.outbox = {}
codedHub:receive(codedClient, { type = Wire.AUTH, response = answer(JOIN_CODE, challenge.nonce) })
eq(#codedPeer.outbox, 0, "auth after admission is a no-op, not a re-welcome")

-- a wrong response is refused and the connection dropped
local wrongPeer = fakePeer()
local wrongClient = codedHub:accept(wrongPeer)
codedHub:receive(wrongClient, { type = Wire.HELLO, proto = Config.PROTOCOL, name = "MISTY" })
local wrongChallenge = take(wrongPeer, Wire.CHALLENGE)
check(wrongChallenge ~= nil, "a second connection is challenged independently")

codedHub:receive(wrongClient,
  { type = Wire.AUTH, response = answer("WXYZ-2345-6789-ABCD", wrongChallenge.nonce) })
local wrongError = take(wrongPeer, Wire.ERROR)
check(wrongError ~= nil, "a wrong response is refused")
check(wrongError.message:find("code"), "naming the join code as the problem")
check(wrongPeer.closed, "and the connection is closed")
eq(codedHub.clients[wrongClient.id], nil, "the client record is gone, not merely refused")
eq(codedHub.players, 1, "and no seat was ever charged for it")

-- a second mmo.auth on a connection that already failed is silently
-- nothing, since the client record no longer exists to receive it
wrongPeer.outbox = {}
codedHub:receive(wrongClient, { type = Wire.AUTH, response = answer(JOIN_CODE, wrongChallenge.nonce) })
eq(#wrongPeer.outbox, 0, "a message from a client the hub already forgot goes nowhere")

-- a response captured for one connection's nonce does not work on another:
-- the HMAC is bound to the nonce it answers, not just to the join code
local nonceOwnerPeer = fakePeer()
local nonceOwnerClient = codedHub:accept(nonceOwnerPeer)
codedHub:receive(nonceOwnerClient, { type = Wire.HELLO, proto = Config.PROTOCOL, name = "OWNER" })
local ownerNonce = take(nonceOwnerPeer, Wire.CHALLENGE).nonce

local replayPeer = fakePeer()
local replayClient = codedHub:accept(replayPeer)
codedHub:receive(replayClient, { type = Wire.HELLO, proto = Config.PROTOCOL, name = "REPLAY" })
local replayNonce = take(replayPeer, Wire.CHALLENGE).nonce
check(ownerNonce ~= replayNonce, "two connections are challenged with different nonces")

codedHub:receive(replayClient, { type = Wire.AUTH, response = answer(JOIN_CODE, ownerNonce) })
eq(take(replayPeer, Wire.WELCOME), nil,
   "a response computed for another connection's nonce does not admit this one")
check(take(replayPeer, Wire.ERROR) ~= nil, "and is refused just like a wrong code")

-- a code typed messily still authenticates: both sides normalise through
-- Wire.code, so the display form the player typed does not have to match
-- the display form the host was given
local messyPeer = fakePeer()
local messyClient = codedHub:accept(messyPeer)
codedHub:receive(messyClient, { type = Wire.HELLO, proto = Config.PROTOCOL, name = "MESSY" })
local messyNonce = take(messyPeer, Wire.CHALLENGE).nonce
codedHub:receive(messyClient,
  { type = Wire.AUTH, response = answer("  abcd efgh, jkmn! pqrs  ", messyNonce) })
check(take(messyPeer, Wire.WELCOME) ~= nil,
      "a code typed lowercase and messily still authenticates")

-- an unanswered challenge does not hold a slot forever: HELLO_TIMEOUT alone
-- is not enough once a challenge is outstanding, but HELLO_TIMEOUT plus
-- AUTH_TIMEOUT together reap it, same as the plain hello-timeout case above
local ghostPeer = fakePeer()
local ghostClient = codedHub:accept(ghostPeer)
codedHub:receive(ghostClient, { type = Wire.HELLO, proto = Config.PROTOCOL, name = "GHOST" })
check(take(ghostPeer, Wire.CHALLENGE) ~= nil, "the ghost connection is challenged")

codedHub:update(Config.HELLO_TIMEOUT + 1)
check(not ghostPeer.closed, "HELLO_TIMEOUT alone is not enough once challenged")

codedHub:update(Config.AUTH_TIMEOUT + 1)
check(ghostPeer.closed, "but HELLO_TIMEOUT + AUTH_TIMEOUT together reap an unanswered challenge")
check(take(ghostPeer, Wire.ERROR) ~= nil, "having been told why")
eq(codedHub.clients[ghostClient.id], nil, "and the slot is freed, not held forever")

-- MAX_PENDING and greeted-only isFull() behave the same with a code
-- configured: a challenged-but-unanswered peer is still just pending
local pendingHub = Hub.new({ maxPlayers = 2, joinCode = "ZZZZ-ZZZZ-ZZZZ-ZZZZ" })
local pendingClient, pendingPeer = join(pendingHub, "WAITING")
check(pendingClient ~= nil, "a hello on a coded hub is still accepted")
check(take(pendingPeer, Wire.CHALLENGE) ~= nil, "and still challenged")
eq(pendingHub.players, 0, "but is not a player yet")
eq(pendingHub:isFull(), false, "so isFull() does not count it")

local floodCodedHub = Hub.new({ maxPlayers = 2, joinCode = "ZZZZ-ZZZZ-ZZZZ-ZZZZ" })
local floodAccepted = 0
for _ = 1, Config.MAX_PENDING + 6 do
  if floodCodedHub:accept(fakePeer()) then floodAccepted = floodAccepted + 1 end
end
eq(floodAccepted, Config.MAX_PENDING, "pending connections are capped the same with a code configured")
eq(floodCodedHub.players, 0, "and none of them are players")

-- the host occupies a slot like anyone else, so a freed one reopens
hub:drop(cal)
eq(hub.players, 2, "dropping frees a seat")
check(saw(annPeer, Wire.PART), "and the others are told")
local late = join(hub, "LATE", "PALLET", 1, 1)
check(late ~= nil, "which the next player can take")
hub:drop(late)

-- ------- chat scopes

hub:update(Config.CHAT_GATE * 2) -- clear the gate for everyone
annPeer.outbox, bobPeer.outbox = {}, {}

hub:receive(ann, { type = Wire.CHAT, scope = "global", text = "hello all" })
local heard = take(bobPeer, Wire.CHAT)
check(heard ~= nil, "global chat reaches the other player")
eq(heard.text, "hello all", "intact")
eq(heard.name, "ANN", "and attributed")
eq(take(annPeer, Wire.CHAT), nil, "the sender is not echoed to themselves")

-- the gate is per sender and spans scopes
hub:receive(ann, { type = Wire.CHAT, scope = "global", text = "again" })
eq(take(bobPeer, Wire.CHAT), nil, "a second message inside the gate is dropped")
hub:update(Config.CHAT_GATE * 2)
hub:receive(ann, { type = Wire.CHAT, scope = "global", text = "later" })
check(saw(bobPeer, Wire.CHAT), "and allowed once the gate lapses")

-- local: BOB is adjacent, a distant player is not
local far, farPeer = join(hub, "FAR", "PALLET", 90, 90)
take(farPeer, Wire.WELCOME)

hub:update(Config.CHAT_GATE * 2)
hub:receive(ann, { type = Wire.CHAT, scope = "local", text = "nearby" })
check(saw(bobPeer, Wire.CHAT), "local chat reaches a neighbour")
eq(take(farPeer, Wire.CHAT), nil, "and does not reach someone across the map")

-- a player with no cell (in a battle or a menu) cannot be heard locally
hub:receive(bob, { type = Wire.MOVE })
hub:update(Config.CHAT_GATE * 2)
hub:receive(bob, { type = Wire.CHAT, scope = "local", text = "from limbo" })
eq(take(annPeer, Wire.CHAT), nil, "a player with no position sends no local chat")
hub:receive(bob, { type = Wire.MOVE, map = "PALLET", x = 6, y = 5, facing = "up" })

-- private reaches exactly one person
hub:update(Config.CHAT_GATE * 2)
annPeer.outbox, bobPeer.outbox, farPeer.outbox = {}, {}, {}
hub:receive(ann, { type = Wire.CHAT, scope = "private", to = bob.id,
                   text = "psst" })
local whisper = take(bobPeer, Wire.CHAT)
check(whisper ~= nil, "a whisper reaches its target")
eq(whisper.scope, "private", "tagged private")
eq(take(farPeer, Wire.CHAT), nil, "and nobody else")

-- ------- requests and sessions

annPeer.outbox, bobPeer.outbox, farPeer.outbox = {}, {}, {}
hub:receive(ann, { type = Wire.REQUEST, to = bob.id, kind = "trade" })
local request = take(bobPeer, Wire.REQUEST)
check(request ~= nil, "a request reaches the other player")
eq(request.kind, "trade", "with the kind")
eq(request.name, "ANN", "and the asker's name")

-- a third party must not be able to answer on someone else's behalf
hub:receive(far, { type = Wire.RESPOND, to = ann.id, kind = "trade",
                   accept = true })
eq(take(annPeer, Wire.SESSION), nil, "only the player asked may accept")

hub:receive(bob, { type = Wire.RESPOND, to = ann.id, kind = "trade",
                   accept = true })
local annSession = take(annPeer, Wire.SESSION)
local bobSession = take(bobPeer, Wire.SESSION)
check(annSession ~= nil and bobSession ~= nil, "accepting starts a session")
eq(annSession.role, "host", "the asker hosts")
eq(bobSession.role, "guest", "the answerer joins")
eq(annSession.id, bobSession.id, "both sides share a session id")
eq(annSession.peer, bob.id, "and know who they are paired with")

-- relay carries the engine's own vocabulary through unread
hub:receive(ann, { type = Wire.RELAY, to = bob.id,
                   payload = { type = "party", mons = { { species = "PIKACHU" } } } })
local relayed = take(bobPeer, Wire.RELAY)
check(relayed ~= nil, "a relay reaches the paired player")
eq(relayed.payload.type, "party", "payload type intact")
eq(relayed.payload.mons[1].species, "PIKACHU", "and its contents")
eq(relayed.from, ann.id, "stamped with the sender")

-- ...but only inside the session
hub:receive(ann, { type = Wire.RELAY, to = far.id, payload = { type = "party" } })
eq(take(farPeer, Wire.RELAY), nil, "a relay outside the session goes nowhere")

-- a busy player auto-declines
hub:receive(far, { type = Wire.REQUEST, to = bob.id, kind = "battle" })
local declined = take(farPeer, Wire.DECLINE)
check(declined ~= nil, "a busy player declines")
eq(declined.name, "BOB", "naming them")

hub:receive(ann, { type = Wire.SESSION_LEAVE })
local ended = take(bobPeer, Wire.SESSION_END)
check(ended ~= nil, "leaving ends the session for the other side")
eq(ended.reason, "peer_left", "with a reason")

-- ------- refusals and liveness

-- the cap is charged at hello, so a stranger connects and is then refused
local stranger, strangerPeer = join(hub, "STRANGER", "PALLET", 1, 1)
check(take(strangerPeer, Wire.ERROR) ~= nil, "the room is full again")
eq(hub.players, 3, "and the stranger never became a player")

local hub2 = Hub.new({ maxPlayers = 4 })
local oldPeer = fakePeer()
local oldClient = hub2:accept(oldPeer)
hub2:receive(oldClient, { type = Wire.HELLO, proto = Config.PROTOCOL + 1,
                          name = "OLD" })
local mismatch = take(oldPeer, Wire.ERROR)
check(mismatch ~= nil, "a protocol mismatch is refused")
check(mismatch.message:find("protocol"), "and says so")

local namelessPeer = fakePeer()
local namelessClient = hub2:accept(namelessPeer)
hub2:receive(namelessClient, { type = Wire.HELLO, proto = Config.PROTOCOL,
                               name = "   " })
check(take(namelessPeer, Wire.ERROR) ~= nil, "an unusable name is refused")

local pingClient, pingPeer = join(hub2, "PING")
take(pingPeer, Wire.WELCOME)
hub2:receive(pingClient, { type = Wire.PING })
check(saw(pingPeer, Wire.PONG), "a ping is answered")

-- shutting down tells everyone rather than dropping them silently
local shutPeer = select(2, join(hub2, "SHUT"))
take(shutPeer, Wire.WELCOME)
hub2:shutdown("The host ended the game.")
local goodbye = take(shutPeer, Wire.ERROR)
check(goodbye ~= nil, "shutdown tells every player")
check(shutPeer.closed, "and closes their connection")
eq(hub2.count, 0, "leaving the hub empty")

-- ------------------------------------------------------------------
-- 4. The host joins its own game over loopback
-- ------------------------------------------------------------------
--
-- HostServer:start needs luasocket, which plain luajit does not have, so
-- the hub and the running flag are set directly here. Everything under
-- test -- the Net-shaped local peer, the JSON round-trip, and Transport
-- driving it -- is the real code path a hosting player takes.

local HostServer = need("HostServer")

local hosted = HostServer.new()
eq(hosted:localNet(), nil, "there is no local net before hosting starts")

hosted.hub = Hub.new({ maxPlayers = 2 })
hosted.running = true

local localNet = hosted:localNet()
check(localNet ~= nil, "hosting yields a local net for the host's own client")
eq(hosted.hub.count, 1, "and the host occupies a slot like anyone else")

local hostTransport = Transport.new()
hostTransport:attach(localNet)
check(hostTransport:isOpen(), "Transport accepts it unchanged")

hostTransport:send(Wire.HELLO, { proto = Config.PROTOCOL, name = "HOST",
                                 map = "PALLET", x = 3, y = 4, facing = "down" })
local hostMsgs = hostTransport:update(0.016)
eq(#hostMsgs, 1, "the host hears back from its own hub")
eq(hostMsgs[1].type, Wire.WELCOME, "with a welcome, exactly as a guest would")
check(hostMsgs[1].id ~= nil, "carrying an id")

-- the second slot is the one friend a limit of 2 allows
local guestPeer = fakePeer()
local guestClient = hosted.hub:accept(guestPeer)
hosted.hub:receive(guestClient, { type = Wire.HELLO, proto = Config.PROTOCOL,
                                  name = "FRIEND" })
check(take(guestPeer, Wire.WELCOME) ~= nil, "one friend fits alongside the host")
local thirdPeer = fakePeer()
local third = hosted.hub:accept(thirdPeer)
hosted.hub:receive(third, { type = Wire.HELLO, proto = Config.PROTOCOL,
                            name = "THIRD" })
check(take(thirdPeer, Wire.ERROR) ~= nil, "a second friend does not")

-- the friend is still on; only the host's own seat is given back
localNet:close()
eq(hosted.hub.players, 1, "closing the local net frees the host's own slot")

-- ------------------------------------------------------------------
-- 5. Avatar step routing
-- ------------------------------------------------------------------
--
-- The rest of Avatars needs a live overworld, but the routing decision is
-- pure and is what decides whether a remote player walks or teleports.

local Avatars = need("Avatars")

local function step(fromX, fromY, toX, toY)
  local dir, tx, ty = Avatars.stepToward(fromX, fromY, toX, toY)
  return dir, tx, ty
end

eq(step(3, 6, 3, 6), nil, "already there is not a step")

local dir, tx, ty = step(3, 6, 4, 6)
eq(dir, "right", "one tile east steps right")
eq(tx, 4, "onto the next cell")
eq(ty, 6, "with y unchanged")

eq(step(3, 6, 2, 6), "left", "west steps left")
eq(step(3, 6, 3, 7), "down", "south steps down")
eq(step(3, 6, 3, 5), "up", "north steps up")

-- One axis at a time: the overworld grid has no diagonal step, so a
-- diagonal target has to be walked as two separate steps.
dir, tx, ty = step(3, 6, 5, 8)
eq(dir, "right", "a diagonal target resolves x first")
eq(tx, 4, "and moves exactly one tile")
eq(ty, 6, "leaving y for the next step")

-- ...and each call moves one tile, so a run of them walks the whole path
local x, y = 3, 6
local walked = 0
while true do
  local d, nx, ny = step(x, y, 5, 8)
  if not d then break end
  x, y = nx, ny
  walked = walked + 1
  if walked > 10 then break end
end
eq(walked, 4, "two east and two south is four steps")
eq(x, 5, "landing on the target x")
eq(y, 8, "and the target y")

-- ------------------------------------------------------------------
-- 6. Characters you can wear
-- ------------------------------------------------------------------
--
-- The catalog carries boulders and Poke Balls next to the people. Wearing a
-- boulder is not just odd-looking: an object sheet has no walk frames, so
-- the avatar would animate wrongly on every other screen.

local Chars = need("Chars")

eq(Chars.label("SPRITE_COOLTRAINER_M"), "COOLTRAINER M", "labels are readable")
eq(Chars.label("SPRITE_RED"), "RED", "and short ones stay short")

eq(Chars.excluded("SPRITE_BOULDER"), true, "a boulder is not a character")
eq(Chars.excluded("SPRITE_POKE_BALL"), true, "nor is an item")
eq(Chars.excluded("SPRITE_UNUSED_GUARD"), true, "unused entries are skipped")
eq(Chars.excluded("SPRITE_GAMBLER_ASLEEP"), true,
   "and a pose with no walk cycle is skipped")
eq(Chars.excluded("SPRITE_YOUNGSTER"), false, "a person is a character")

-- Shaped like the real records: `walker` is what the catalog actually
-- carries, and it is the flag that decides whether a sprite can be worn.
-- SPRITE_NURSE is here as the case that catches a naive "is it a person"
-- filter -- a person, but drawn from a sheet with no walking frames.
stubSprites = {
  SPRITE_RED = { walker = true },
  SPRITE_YOUNGSTER = { walker = true },
  SPRITE_AGATHA = { walker = true },
  SPRITE_NURSE = { walker = false },
  SPRITE_BOULDER = { walker = false },
  SPRITE_POKE_BALL = { walker = false },
  SPRITE_UNUSED_GUARD = { walker = true },
}
local wearable = Chars.list()
eq(wearable[1], "SPRITE_RED", "RED leads the list -- it is the guaranteed one")
local names = {}
for _, id in ipairs(wearable) do names[id] = true end
check(names.SPRITE_AGATHA and names.SPRITE_YOUNGSTER, "people are offered")
check(not names.SPRITE_BOULDER and not names.SPRITE_POKE_BALL,
      "objects are not")
check(not names.SPRITE_UNUSED_GUARD, "and neither are unused entries")
check(not names.SPRITE_NURSE,
      "nor a person with no walk cycle -- she would break mid-step")

-- The fallback the goal asks for: a character this game does not carry --
-- a different ROM, a mod the other player has and you do not -- becomes RED
-- rather than failing to draw.
eq(Chars.available("SPRITE_AGATHA"), true, "a character we have is available")
eq(Chars.available("SPRITE_MISSINGNO"), false, "one we do not have is not")
eq(Chars.resolve("SPRITE_AGATHA"), "SPRITE_AGATHA", "so it resolves to itself")
eq(Chars.resolve("SPRITE_MISSINGNO"), Config.DEFAULT_SPRITE,
   "and an unknown character falls back to RED")
eq(Chars.resolve(nil), Config.DEFAULT_SPRITE, "as does nothing at all")
eq(Chars.resolve("SPRITE_BOULDER"), Config.DEFAULT_SPRITE,
   "and so does a real sprite that is not a character")

-- ------- the trainer card on the wire

local card = Wire.profile({ idNo = 12345, money = 3000, badges = 3,
                            seen = 60, owned = 30, playtime = 7265 })
eq(card.money, nil, "money is never carried -- the card does not show it")
check(card ~= nil, "a full card sanitises")
eq(card.badges, 3, "badge count survives")
eq(card.playtime, 7265, "so does playtime")
eq(Wire.profile(nil), nil, "no card is not a card")
eq(Wire.profile("nope"), nil, "and neither is a string")

local hostile = Wire.profile({ idNo = "9" .. string.rep("9", 12),
                               badges = 1e9, seen = 0 / 0 })
check(hostile ~= nil, "a hostile card still sanitises to a table")
eq(hostile.idNo, nil, "an out-of-range id is dropped")
eq(hostile.badges, nil, "an absurd badge count is dropped")
eq(hostile.seen, nil, "and NaN is dropped")

-- presence carries it through, since the card is shown from the roster
local withCard = Wire.presence({ id = "p9", name = "ASH",
                                 profile = { badges = 8 } })
eq(withCard.profile.badges, 8, "presence carries the card")
eq(Wire.presence({ id = "p9", name = "ASH" }).profile, nil,
   "and a player who sent none simply has none")

stubSprites = {}

-- ------------------------------------------------------------------
-- 7. Playing nicely with a mod that owns the world pass
-- ------------------------------------------------------------------
--
-- DramaticShapeVoxelMod registers a "voxel" render pipeline whose drawWorld
-- replaces the overworld with a 3D diorama. This overlay places nameplates
-- by tile offset from the local player, which is only true of the flat 2D
-- projection -- under a diorama a label would float somewhere unrelated to
-- the character it names. Detecting that is what lets it fall back instead
-- of drawing nonsense.

local Overlay = need("Overlay")
local overlay = Overlay.new({ chat = Chat.new() })

local function gameWith(pipelineLevels)
  return { save = { options = { pipelines = pipelineLevels } } }
end

stubPipelines = {}
eq(overlay:worldIsFlat(gameWith({})), true, "no pipelines means the flat world")
eq(overlay:worldIsFlat({}), true, "and so does a save with no options")
eq(overlay:worldIsFlat(nil), true, "and no game at all")

-- a post-process pipeline does not move anything; the projection is intact
stubPipelines = { tiltshift = { worldPresent = function() end } }
eq(overlay:worldIsFlat(gameWith({ tiltshift = 2 })), true,
   "a post-process pipeline leaves the projection alone")

-- one that replaces the world does
stubPipelines = {
  voxel = { drawWorld = function() end },
  tiltshift = { worldPresent = function() end },
}
eq(overlay:worldIsFlat(gameWith({ voxel = 0, tiltshift = 2 })), true,
   "a world pipeline that is switched off still leaves it flat")
eq(overlay:worldIsFlat(gameWith({ voxel = 1 })), false,
   "but an active one means the flat projection no longer holds")
eq(overlay:worldIsFlat(gameWith({ voxel = 3, tiltshift = 1 })), false,
   "at any level, alongside any post-process")

stubPipelines = {}

-- ------------------------------------------------------------------
-- 7. Settings the player changes in game
-- ------------------------------------------------------------------
--
-- Menu code calls these as client:setMaxPlayers(n) -- the colon form, which
-- passes the module table as the first argument. A setter that took the
-- value positionally would store `self` instead, and clampPlayers would
-- turn that into the default: the host's choice silently ignored, with no
-- error anywhere. Both spellings are pinned here for exactly that reason.

local Client = need("Client")

stubSave, stubOptions = {}, { maxplayers = 6, hub = "10.0.0.9:7788" }

eq(Client.maxPlayers(), 6, "with nothing saved, the option row is the default")
eq(Client.joinAddress(), "10.0.0.9:7788", "and likewise for the address")

eq(Client.setMaxPlayers(Client, 12), 12, "the colon form stores the value")
eq(Client.maxPlayers(), 12, "and it reads back")
eq(Client.setMaxPlayers(20), 20, "the dot form works too")
eq(Client.maxPlayers(), 20, "and reads back")

eq(Client.setMaxPlayers(Client, 999), Config.MAX_PLAYERS,
   "an out-of-range value is clamped, not stored")
eq(Client.setMaxPlayers(Client, 1), Config.MIN_PLAYERS, "at both ends")

eq(Client.setJoinAddress(Client, "192.168.1.7:7788"), "192.168.1.7:7788",
   "the colon form stores an address")
eq(Client.joinAddress(), "192.168.1.7:7788", "which then wins over the option")
eq(Client.setJoinAddress(Client, ""), nil, "an empty address is refused")
eq(Client.joinAddress(), "192.168.1.7:7788", "leaving the previous one intact")

eq(Client.isHosting(), false, "a fresh client is not hosting")

T.finish("rby_mmo")
