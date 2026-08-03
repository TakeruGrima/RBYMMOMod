-- HMAC-SHA256 / SHA-256 test vectors, pinning src/Sha256.lua against two
-- independent sources of truth.
--
-- Section 1 (RFC_HMAC) and Section 2 (SHA256) are the published standard:
-- RFC 4231 test cases 1, 2, 3 and 6, and the textbook SHA-256 vectors for the
-- empty string, "abc", and the 56-byte multi-block string. These pin the
-- primitive against the spec, not against itself.
--
-- Section 3 (KAT) is the fixed known-answer vector already carried by
-- server/auth.test.js -- reused here rather than re-derived, so both suites
-- assert the same literal.
--
-- Section 4 (CROSS) is a generated set of (code, nonce) -> digest triples,
-- produced by Node (server/lib/auth.js -- normalizeCode + crypto.createHmac,
-- the same recipe sign() uses) and frozen here as literals. The Lua suite
-- asserts src/Sha256.lua reproduces every one; that is what catches the two
-- implementations drifting apart, since a drift here reaches a player only
-- as "wrong join code" with nothing else to go on.
--
-- HOW THIS FILE WAS GENERATED (and how to regenerate it):
--
--   RFC_HMAC / SHA256 (sections 1-2): computed once with node:crypto against
--   the literal RFC 4231 / FIPS 180-4 inputs. Nothing here depends on this
--   repo's code, so these never need regenerating; they would only change if
--   a transcription error were found.
--
--   CROSS (section 4): run this from the repo root with the Node on PATH
--   (or the one CLAUDE.md names) --
--
--     node -e '
--       const crypto = require("crypto");
--       const auth = require("./server/lib/auth.js");
--       function sign(code, nonce) {
--         const key = auth.normalizeCode(code);
--         return crypto.createHmac("sha256", Buffer.from(key, "ascii"))
--           .update(nonce, "ascii").digest("hex");
--       }
--       console.log(sign("ABCD-EFGH-JKMN-PQRS", "<32-hex-nonce>"));
--     '
--
--   which is exactly the recipe auth.sign() documents at the top of
--   server/lib/auth.js, and the one src/Sha256.lua + src/Wire.lua reimplement.
--   Each entry below records its `code` exactly as a player would type or
--   paste it (dashed, undashed, lowercase, messy) plus the `normalized` form
--   Wire.code() must reduce it to, so a vector doubles as a normalisation
--   check when read alongside the Wire.code tests in rby_mmo_test.lua.
--
-- No love, no engine modules: a plain table, safe to require from anywhere.

local M = {}

-- ------------------------------------------------------------------
-- 1. RFC 4231 HMAC-SHA256 test vectors (cases 1, 2, 3, 6)
-- ------------------------------------------------------------------
-- key and message are given as hex, since case 1/3/6 keys are raw bytes,
-- not text -- a suite decodes them with a small hex->bytes helper before
-- calling Sha256.hmacHex.  Case 6 is the key-longer-than-the-block path:
-- a 131-byte key gets hashed down to 32 bytes before use.
M.RFC_HMAC = {
  {
    case = 1,
    keyHex = "0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b",
    dataHex = "4869205468657265",
    digest = "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7",
  },
  {
    case = 2,
    keyHex = "4a656665",
    dataHex = "7768617420646f2079612077616e7420666f72206e6f7468696e673f",
    digest = "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843",
  },
  {
    case = 3,
    keyHex = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    dataHex = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
    digest = "773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe",
  },
  {
    case = 6,
    keyHex = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    dataHex = "54657374205573696e67204c6172676572205468616e20426c6f636b2d53697a65204b6579202d2048617368204b6579204669727374",
    digest = "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54",
  },
}

-- ------------------------------------------------------------------
-- 2. Standard SHA-256 vectors: empty string, "abc", and the 56-byte
--    multi-block string that straddles the single/double-block boundary
-- ------------------------------------------------------------------
M.SHA256 = {
  {
    label = "empty string",
    input = "",
    digest = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
  },
  {
    label = "abc",
    input = "abc",
    digest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
  },
  {
    label = "56-byte multi-block string",
    input = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
    digest = "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
  },
}

-- ------------------------------------------------------------------
-- 3. The cross-language known-answer vector server/auth.test.js already
--    fixes.  Reused verbatim, not re-derived: both suites pin the same
--    literal, so a divergence anywhere shows up as a failure on one side
--    or the other rather than two tests that quietly drift together.
-- ------------------------------------------------------------------
M.KAT = {
  code = "ABCD-EFGH-JKMN-PQRS",
  nonce = "a1b2c3d4e5f6070819293a4b5c6d7e8f",
  digest = "025b38b6dc30464f973489da3bf148a208877406707fd1b6d93abfc521c663e7",
}

-- ------------------------------------------------------------------
-- 4. Generated cross-language (code, nonce) -> digest triples, produced
--    by Node as described above.  `code` is the input exactly as it would
--    arrive off a player's keyboard or a pasted message; `normalized` is
--    what Wire.code(code) must equal, and what actually gets HMAC-keyed.
-- ------------------------------------------------------------------
M.CROSS = {
  {
    label = "dashed form",
    code = "ABCD-EFGH-JKMN-PQRS",
    normalized = "ABCDEFGHJKMNPQRS",
    nonce = "af0370b116f5d5e7ff962a6059fe10a2",
    digest = "41372829d8875e30262ae9cd4384d882ded7e04b937a3fa93b5e3b7b034388e4",
  },
  {
    label = "undashed spelling of the same code",
    code = "ABCDEFGHJKMNPQRS",
    normalized = "ABCDEFGHJKMNPQRS",
    nonce = "af0370b116f5d5e7ff962a6059fe10a2",
    digest = "41372829d8875e30262ae9cd4384d882ded7e04b937a3fa93b5e3b7b034388e4",
  },
  {
    label = "lowercase spelling of the same code",
    code = "abcd-efgh-jkmn-pqrs",
    normalized = "ABCDEFGHJKMNPQRS",
    nonce = "af0370b116f5d5e7ff962a6059fe10a2",
    digest = "41372829d8875e30262ae9cd4384d882ded7e04b937a3fa93b5e3b7b034388e4",
  },
  {
    label = "messy spacing and punctuation, same code",
    code = " abcd efgh, jkmn! pqrs?? ",
    normalized = "ABCDEFGHJKMNPQRS",
    nonce = "af0370b116f5d5e7ff962a6059fe10a2",
    digest = "41372829d8875e30262ae9cd4384d882ded7e04b937a3fa93b5e3b7b034388e4",
  },
  {
    label = "alphabet coverage block 1 (chars 1-16)",
    code = "0123456789ABCDEF",
    normalized = "0123456789ABCDEF",
    nonce = "56e393452650ccda3d58584b9d1f4709",
    digest = "499582825143509f014bdda1a939a3992e6f6180fdf494943158b68a66da9775",
  },
  {
    label = "alphabet coverage block 2 (chars 17-32)",
    code = "GHJKMNPQRSTVWXYZ",
    normalized = "GHJKMNPQRSTVWXYZ",
    nonce = "1f25d2ca18c9b971f9fdc62544978f0a",
    digest = "972cbc9214aa425d1e2a22be7a675b04b62e7d80aacbefb864744e641aa18855",
  },
  {
    label = "generated code 1 (stride 3)",
    code = "0369CFJNRVY147AD",
    normalized = "0369CFJNRVY147AD",
    nonce = "6afa931347675ff7f41490a20b54bc7d",
    digest = "a0a9bdc2650033a060a9e10223efa21d8b1b1bddb66d30ac4fd8ef1e85093976",
  },
  {
    label = "generated code 2 (stride 5)",
    code = "16BGNTZ49EKRX27C",
    normalized = "16BGNTZ49EKRX27C",
    nonce = "c6f8d734991af6c65b20568996fd7e8b",
    digest = "402e57bf096a6af0b64f80cac420013d4d6c62a4319f54e7fa09bdd1d4fcbd72",
  },
  {
    label = "generated code 3 (stride 7)",
    code = "29GQY5CKT18FPX4B",
    normalized = "29GQY5CKT18FPX4B",
    nonce = "1b52c0b723d697774d9ea196be43d6df",
    digest = "4be4e8f74eb0a8cb1317d3fdb6f40ebb93ce42e2ca3277862d92f2b6ea698f0d",
  },
  {
    label = "generated code 4 (stride 9)",
    code = "3CNY7GS2BMX6FR1A",
    normalized = "3CNY7GS2BMX6FR1A",
    nonce = "ae02d33ec4e7ede74c1b436e8f056983",
    digest = "9dea366a154b0e6043af2c2e178ca8ae129dc4442c718fb8d5dfc6f2fb9e72c5",
  },
  {
    label = "generated code 5 (stride 11)",
    code = "4FT5GV6HW7JX8KY9",
    normalized = "4FT5GV6HW7JX8KY9",
    nonce = "7e7f34e245a74e6eefcb11c6b304fca8",
    digest = "67a5bbb22e55c3def1d247ac64ac51dcabd78175cc1467431c02484eaf008601",
  },
  {
    label = "generated code 6 (stride 13)",
    code = "5JZCS6K0DT7M1EV8",
    normalized = "5JZCS6K0DT7M1EV8",
    nonce = "29a87032e31e2de50b92bb3e19413d43",
    digest = "1d8c91b58ee91b59e62f89d81086da9137e56eec06851bddc26bd2819df80cc2",
  },
  {
    label = "generated code 7 (stride 15)",
    code = "6N4K2H0FYDWBT9R7",
    normalized = "6N4K2H0FYDWBT9R7",
    nonce = "4d2359196ecab7c40849ed4d708bd636",
    digest = "4730a14afe23d3536e79630d8795e3dd249dfdec98f8df9dfb144fe70068d86e",
  },
  {
    label = "generated code 8 (stride 17)",
    code = "7R9TBWDYF0H2K4N6",
    normalized = "7R9TBWDYF0H2K4N6",
    nonce = "4ea96f8ba0ac4a4bc9eb6dd479bcf11d",
    digest = "13ae4af1f6307e29f52687bfb965874dc1b0cb63a5df7f13c92831355f5b4fdf",
  },
  {
    label = "generated code 9 (stride 19)",
    code = "8VE1M7TD0K6SCZJ5",
    normalized = "8VE1M7TD0K6SCZJ5",
    nonce = "fbea1e091a8e6dff5eebd7a369dc745d",
    digest = "52bedcc489bc168b7117de7d715f99b031021af81245d3976af034051bc2b596",
  },
  {
    label = "generated code 10 (stride 21)",
    code = "9YK8XJ7WH6VG5TF4",
    normalized = "9YK8XJ7WH6VG5TF4",
    nonce = "7a8c1f4a42731b2be8343055a8280222",
    digest = "df2ac18a1a50cdffa1f384be819c3fa1651d2ee850b8bfda02d803d3ed37d931",
  },
  {
    label = "generated code 11 (stride 23)",
    code = "A1RF6XMB2SG7YNC3",
    normalized = "A1RF6XMB2SG7YNC3",
    nonce = "586899a53e7ad15a3900d0b85a189848",
    digest = "7b5aa183647ab22ba5d8c1462b90b43e0b4a2d0affc527b99fbd77c83da5d230",
  },
  {
    label = "generated code 12 (stride 25)",
    code = "B4XPF81TKC5YQG92",
    normalized = "B4XPF81TKC5YQG92",
    nonce = "892e01528447bc0ee2ba0bc932df4571",
    digest = "1df5b0ec385611cd4aca1e52c7f4e9b5a111576d966e09f778c09f5e51ec88a0",
  },
  {
    label = "generated code 13 (stride 27)",
    code = "C72XRKE94ZTNGB61",
    normalized = "C72XRKE94ZTNGB61",
    nonce = "506b0bd8c7aa1374fdb30dcc76633238",
    digest = "b76b91f837e62b5bd47e08f7518c425317249da342ff0f38e226d1ecc9ea1d11",
  },
  {
    label = "generated code 14 (stride 29)",
    code = "DA741YVRNJFC9630",
    normalized = "DA741YVRNJFC9630",
    nonce = "90eeb3db5f247d8a4ec64a974a561ba6",
    digest = "7628a01ea1197a316e75544235f739f6e647dfd9644c87374a5df33a4154a2e2",
  },
  {
    label = "generated code 15 (stride 31)",
    code = "EDCBA9876543210Z",
    normalized = "EDCBA9876543210Z",
    nonce = "d60fcbb2a206ec48b9077faf98f24a4e",
    digest = "1f4d83b5c8a1256503ccf97e179fb9420cd57fdcab8ce090ab1b9af574842692",
  },
  {
    label = "generated code 16 (stride 1)",
    code = "FGHJKMNPQRSTVWXY",
    normalized = "FGHJKMNPQRSTVWXY",
    nonce = "ddf6e202bac907081e75d2f8a69a85b1",
    digest = "c0a3fc9eaf847507c3c25e06b21aafc7cc194bc8b952a6ad7de4e8a5238fc434",
  },
  {
    label = "dashed spelling of a generated code",
    code = "29GQ-Y5CK-T18F-PX4B",
    normalized = "29GQY5CKT18FPX4B",
    nonce = "ea5d3078b803015f80cdf55855aaa4c8",
    digest = "1453c424013208195a1dbed2a6e28217efca7397bd4ea2be1d2a00b9560b0d2e",
  },
  {
    label = "lowercase dashed spelling of a generated code",
    code = "5gv6-hw7j-x8ky-9mza",
    normalized = "5GV6HW7JX8KY9MZA",
    nonce = "8cd28d7c25eeb75b2880ccb8751cc4be",
    digest = "75976d9cdccdb8d47279149cbf3613d6f4f88237dc894614c76c05bd5f931e5a",
  },
}

return M
