# RBY MMO

### Kanto, but your friends are in it.

Other trainers walk the same routes you do — real sprites, names over their
heads, chat bubbles when they talk. Bump into someone outside Viridian and
trade on the spot. Or throw down, right there on the grass.

A multiplayer mod for [Gen1Recomp](https://github.com/bryanthaboi/gen1recomp).

![LÖVE 11.x](https://img.shields.io/badge/L%C3%96VE-11.x-e64998?style=for-the-badge)
![Players 2–64](https://img.shields.io/badge/players-2--64-3aa757?style=for-the-badge)
![No server needed](https://img.shields.io/badge/dedicated%20server-optional-4c8fd6?style=for-the-badge)
![Experimental](https://img.shields.io/badge/status-experimental-d9822b?style=for-the-badge)
![MIT](https://img.shields.io/badge/licence-MIT-666?style=for-the-badge)

**No server to rent. No launcher. No account.** One of you hosts from inside
the game — you're a player, your copy is just also the relay.

---

## 🎮 Get in

Copy `.env.example` to `.env`, point `ROM_PATH` at your own ROM, then:

```sh
bash mods/rby_mmo/tools/play.sh          # boots straight in, mod already on
bash mods/rby_mmo/tools/play.sh guest    # a second window, separate save
```

Then hit **START → MMO**:

```
        ┌──────────────┐
        │▶ HOST GAME   │   pick 2–64 players. done. you're live.
        │  JOIN GAME   │   type their address. you're in.
        └──────────────┘
```

Running both commands gives you two windows on one machine — host in the
first, join `127.0.0.1:7788` from the second. That's the fastest way to see
it work.

Same house? Same Wi-Fi? Your friends just join. Across the internet, the host
forwards port **7788** — or nobody forwards anything and you all point at a
standalone hub instead ([server/README.md](server/README.md)).

> **Why `play.sh` and not `love .`?** A normal launch always stops at the
> ROM screen — the engine only skips it for scripted runs. `play.sh` hands
> the engine your ROM through its own supported route and flips the mod on,
> so you go straight to the overworld.

---

## ⚡ What you actually get

**👥 They're really there.** Every other player on your map is a genuine
overworld NPC — right sprite, right depth sorting, right palette, walking
tile to tile on the engine's own step clock. Not a floating overlay. If a
renderer mod redraws the world, it redraws them too.

**💬 Chat, on a Game Boy keyboard.** Three scopes:

| Scope | Who hears it | Floats over your head |
| --- | --- | --- |
| `EVERYONE` | the whole hub | ✅ |
| `NEARBY` | same map, 12 tiles | ✅ |
| `WHISPER` | one player | ❌ — it's a whisper |

**🔁 Trade. ⚔️ Battle.** Walk up, press A, pick from the menu. Both run the
engine's *own* link code, untouched — so a trade still evolves your Kadabra
and stamps the mon as traded, and a battle is the same lockstep simulation a
real link cable runs. This mod carries the bytes; Gen 1 does the rest.

---

## 🕹️ The menu

`START → MMO` is a bordered box in the corner like any other START submenu.
B goes back. The cursor remembers where you left it. The world stays visible
behind it.

| Row | Shows up when | What it does |
| --- | --- | --- |
| `ADDRESS` | hosting | your address again — for when someone asks *again* |
| `PLAYERS` | connected | who's on, `n/limit` if you're hosting |
| `CHAT` / `SAY` | connected | the log (`CHAT*` = unread) and sending |
| `LEAVE` | you joined | drop out and **keep playing single-player** |
| `END GAME` | hosting | asks first — this one ends it for everybody |

Leaving isn't quitting. Your save, your world, your party: untouched. The
game just carries on without the other people in it.

---

## ⚙️ Options

`MMO` in the mod manager (`F10`):

| Option | Default | Does |
| --- | --- | --- |
| `MAX PLAYERS` | 4 | room size for games you host (2–64, you count) |
| `JOIN` | `127.0.0.1:7788` | where JOIN GAME starts from |
| `MY SPRITE` | RED | how everyone else sees you |
| `BUBBLES` | on | names and chat over heads |

These are just the *defaults* — HOST GAME asks the room size every time and
JOIN GAME lets you type an address, and those in-game choices stick with your
save. (Mods can read their options but not write them, so the in-game values
live in the save file instead of overwriting the rows above.)

**Typing an address on a Game Boy?** The vanilla naming grid has no digits at
all — so this mod adds a number page to *its own* text screens. **SELECT**
flips `ABC` ⇄ `123`. Every other naming screen in the game is left alone.

---

## 🧩 Plays nice with other mods

Tested against
[DramaticShapeVoxelMod](https://github.com/DramaticShape/DramaticShapeVoxelMod):
both load clean, and everything — presence, chat, trade, battle — works with
the voxel diorama running.

Your friends show up as **voxel characters**, free of charge. That's the
payoff for spawning real NPCs instead of drawing avatars: whoever owns the
world pass draws them too.

Nameplates are the one thing that can't follow into 3D — they're positioned
by tile offset, which only means anything in the flat projection. So when
another mod owns the world, the overlay names nearby players in a corner list
instead. You lose the arrows, nothing else.

It's entirely optional, and that's a *checked* claim — the test suite runs
both ways and pins which:

```sh
MMO_WITHOUT_MODS="DRAMATIC_SHAPE" bash mods/rby_mmo/tests/drivers/run-mmo-e2e.sh
MMO_WITH_MODS="DRAMATIC_SHAPE"    bash mods/rby_mmo/tests/drivers/run-mmo-e2e.sh
```

---

## 🔬 Prove it

```sh
luajit mods/rby_mmo/tests/rby_mmo_test.lua   # from the engine root
node server/hub.test.js                      # from this folder
```

The first drives the real headless loader — same `Loader`, same merge the
game uses — and hammers the protocol logic with fake peers. The second boots
the Node hub as a child process and drives it over real sockets.

But neither of those ever binds a socket, renders a menu, or spawns an
avatar. **This does:**

```sh
bash mods/rby_mmo/tests/drivers/run-mmo-e2e.sh
```

Two real LÖVE instances. Separate saves. A real socket between them. One
hosts, one joins, and both sides assert:

- ✅ the listener comes up and publishes an address you can re-read later
- ✅ each player lands on the other's roster
- ✅ avatars **walk** to where the network says they are — not teleport
- ✅ leaving a map despawns the avatar but keeps the player listed
- ✅ chat crosses both ways
- ✅ pressing A on someone opens TRADE / BATTLE
- 🔁 **a trade completes** — each side ends holding the other's Pokémon
- ⚔️ **a link battle runs to a decision**, zero `link.desync` on either side
- ✅ a guest LEAVEs and keeps playing

Screenshots land in `/tmp/rby_mmo_shots` so you can see it, not just read a
pass count.

> Two windows open and drive themselves. Don't click into them — you'll
> steal the input the drivers are queueing.

---

## 🧑‍💻 Hooking in from your own mod

```lua
local mmo = mod.find("rby_mmo")
if mmo and mmo.exports.isConnected() then
  -- isHosting() tells you whether this copy is also the relay
  for _, player in ipairs(mmo.exports.players()) do
    print(player.name, player.map, player.x, player.y)
  end
  mmo.exports.say("global", "hello from my mod")
end
```

---

## 🚧 Known jank — read this bit

It's `0.1.0` and it ships flagged `experimental` on purpose. The full list
lives in `mod.card` under `differences.known`. The ones that'll actually bite
you:

- **No NAT traversal.** Hosting from the game means your friends have to
  reach *you*. LAN is effortless; over the internet somebody forwards 7788,
  or you all use a standalone hub on a box with a public address.
- **No host migration.** Host leaves → the game ends for everyone. They get
  told, rather than left staring at a frozen world.
- **Nameplates can drift a tile or two** at the edge of small maps, where the
  camera stops scrolling but you keep walking. Fixing it properly needs a
  camera seam the mod API doesn't expose yet.
- **Only ever tested over loopback**, two instances on one desk. Real latency
  and packet loss are still an unknown.
- **No accounts, no bans, no encryption.** Anyone who can reach the port can
  join under any name. Host for people you know — see the security posture in
  [server/README.md](server/README.md).

---

## Licence

MIT, matching the engine. Bring your own ROM — this repo ships no game data
and never will.
