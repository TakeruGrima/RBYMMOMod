# RBY MMO

Play Kanto with your friends: see each other walking around with names over
your heads, talk in a chat box, and trade or battle from wherever you are
standing — a mod for [Gen1Recomp](https://github.com/bryanthaboi/gen1recomp).

It is for the person who wants their single-player Red to have other people
in it. **No server to install** — one of you hosts from inside the game.

## Try it

From a Gen1Recomp checkout, with this folder linked in as `mods/rby_mmo`,
start the game (`love .`) and turn the mod on in the mod manager (`F10`) —
it ships disabled.

Then **START > MMO**:

- **HOST GAME** — pick how many players (2–64), and you are hosting. The
  menu's **ADDRESS** row shows what to read out to your friends.
- **JOIN GAME** — type their address and you are in.

The host plays like everybody else; hosting just means their copy is also
the relay. A limit of 4 means the host plus three friends.

Everyone on the same LAN can join straight away. Over the internet the host
has to forward their port (7788) — or, if you would rather not, run the
standalone hub on a box that already has a public address and have everyone
JOIN that instead; see [server/README.md](server/README.md).

## What you get

**Presence.** Everyone else on your current map is a real overworld NPC —
correct sprite, correct depth sorting, correct palette — walking tile to
tile on the engine's own step clock.

**Chat**, composed on the Game Boy naming grid, in three scopes:

| Scope | Reaches | Bubbles over your head |
| --- | --- | --- |
| `EVERYONE` | everyone on the hub | yes |
| `NEARBY` | same map, within 12 tiles | yes |
| `WHISPER` | one player | no |

**Trade and battle.** Face someone and press A, or pick them from
**MMO > PLAYERS**. Both run the engine's own link code, unmodified, so a
trade evolves Kadabra and marks the mon as traded, and a battle is the same
lockstep simulation a cable link runs.

## While you're in a game

`START > MMO` opens a bordered box in the corner, like any other START
submenu — B goes back to START, the cursor remembers where you left it, and
the world stays visible behind. It changes with what you're doing:

| Row | When | What it does |
| --- | --- | --- |
| `ADDRESS` | hosting | shows your address again — read it out whenever a friend asks |
| `PLAYERS` | connected | who's on, and `n/limit` if you're hosting |
| `CHAT` / `SAY` | connected | the log (`CHAT*` when unread), and sending in a scope |
| `LEAVE` | joined someone | disconnect and **carry on playing single-player** |
| `END GAME` | hosting | asks first — it ends the game for everyone |

Leaving someone else's game is not quitting: your save, your world and your
party are untouched, and the game keeps going exactly as it was.

## Options

`MMO` in the mod manager's options pane:

| Option | Default | What it does |
| --- | --- | --- |
| `MAX PLAYERS` | 4 | how many fit in a game you host (2–64, host included) |
| `JOIN` | `127.0.0.1:7788` | the address JOIN GAME starts from |
| `MY SPRITE` | RED | how you look to everyone else |
| `BUBBLES` | on | draw names and chat over heads |

These are the *defaults*. Both are also editable from inside the game —
HOST GAME asks for the player count each time, and JOIN GAME lets you type
an address — and an in-game change sticks with your save. (Mods can read
their options but not write them, so the in-game values live in the save
file rather than overwriting the rows above.)

**Typing addresses.** The Game Boy naming grid has no digits, so this mod
adds a number page to its own text screens: press SELECT to flip between
`ABC` and `123`. Every other naming screen in the game is untouched.

## For other mods

```lua
local mmo = mod.find("rby_mmo")
if mmo and mmo.exports.isConnected() then
  -- exports.isHosting() tells you whether this copy is also the relay
  for _, player in ipairs(mmo.exports.players()) do
    print(player.name, player.map, player.x, player.y)
  end
  mmo.exports.say("global", "hello from my mod")
end
```

## Tests

```sh
luajit mods/rby_mmo/tests/rby_mmo_test.lua   # from the engine checkout root
node server/hub.test.js                      # from this folder
```

The first drives the real headless loader — same `Loader`, same merge the
game uses — and unit-tests the protocol logic with fake peers. The second
starts the Node hub as a child process and drives it over real sockets.

### End to end, in the real game

Neither of the above ever binds a socket, renders a menu, or spawns an
avatar — they structurally can't. This does:

```sh
bash mods/rby_mmo/tests/drivers/run-mmo-e2e.sh   # from the engine root
```

It launches **two real LÖVE instances** with separate save identities, has
one host and the other join over a real socket, and asserts on both sides:

- hosting binds a listener and publishes an address you can re-view later
- each player reaches the other's roster, and their avatar walks (not
  teleports) to where the network says they are
- leaving a map despawns the avatar but keeps the player on the roster
- chat crosses in both directions
- pressing A on another player opens a menu offering TRADE and BATTLE
- **a trade completes** — each side ends holding the other's Pokémon
- **a link battle runs to a decision** with no `link.desync` on either side
- a guest can LEAVE and carry on playing single-player

Screenshots land in `/tmp/rby_mmo_shots`.

Needs LÖVE on `PATH` and a ROM already imported (`scripts/setup.sh --rom …`)
— the engine cannot boot without `data/generated/`. Two windows will open
and drive themselves; clicking into them steals the input the drivers are
queueing.

## Playing with other mods

Tested against
[DramaticShapeVoxelMod](https://github.com/DramaticShape/DramaticShapeVoxelMod)
— both load together cleanly and the whole feature set (presence, chat,
trade, battle) works with the voxel diorama on. It is entirely optional:
the end-to-end suite runs both ways and pins which, so "works without it"
is a checked claim rather than an assumption.

```sh
MMO_WITHOUT_MODS="DRAMATIC_SHAPE" bash mods/rby_mmo/tests/drivers/run-mmo-e2e.sh
MMO_WITH_MODS="DRAMATIC_SHAPE"    bash mods/rby_mmo/tests/drivers/run-mmo-e2e.sh
```

Remote players appear as **voxel characters**, because this mod spawns real
overworld NPCs rather than drawing avatars itself — whoever owns the world
pass draws them for free.

Nameplates are the one thing that cannot follow. They are placed by tile
offset from your own player, which is only true of the flat 2D projection;
under a 3D diorama a floating label would land nowhere near the character it
names. So when a mod owns the world pass, the overlay switches to naming
nearby players in a corner list instead. Nothing is lost but the arrows.

## Honest limitations

This is version 0.1.0 and it ships `experimental`. The things most likely to
bite you are listed in `mod.card` under `differences.known`; the two worth
repeating here:

- **No NAT traversal.** Hosting from the game means your friends have to
  reach *you*: fine on a LAN, but over the internet the host forwards port
  7788 or everyone uses a standalone hub on a public box instead.
- **No host migration.** If the host leaves, the game ends for everyone —
  they are told, rather than left staring at a frozen world.
- **Nameplates can drift a tile or two at small map edges**, because the mod
  API exposes where players are but not where the camera is. Fixing it
  properly is an upstream RFC, not something to hack around with a private
  require.

## Licence

MIT, matching the engine.
