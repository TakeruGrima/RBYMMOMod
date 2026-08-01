# RBY MMO hub (standalone)

**You usually do not need this.** A player can host from inside the game —
`START > MMO > HOST GAME` — and that is the normal way to play. Reach for
this when you want a hub that stays up when nobody is playing, or one on a
box with a public address so nobody has to forward a port.

It is the same protocol and the same 2–64 bounds as the in-game host
(`src/Hub.lua`); the two are interchangeable and a joining client cannot
tell them apart.

Node 18+, no dependencies.

```sh
node hub.js              # port 7788, 4 players
node hub.js 9000         # or pick a port
RBY_MMO_MAX=8 node hub.js
```

| Variable | Default | Meaning |
| --- | --- | --- |
| `RBY_MMO_PORT` | `7788` | listen port (an argv port wins) |
| `RBY_MMO_HOST` | `0.0.0.0` | listen address |
| `RBY_MMO_MAX` | `4` | how many players before it refuses new ones |

`RBY_MMO_MAX` is **clamped to 2–64** — the same bounds the in-game host
picks from. A value outside that range is pulled to the nearest end rather
than obeyed, so the limit cannot be set out of range by editing a config.
A player over the cap is refused with `mmo.error` naming the limit, and
their game shows that sentence rather than hanging on a dead connection.

Players then set their **MMO > HUB** option to `your.host:7788`. Anyone
outside your LAN needs that port reachable — forward it on your router, or
run the hub on a box that already has a public address.

## What it is, and what it deliberately is not

It is a **relay**. It owns who is connected, where they last said they were,
and which two players are currently paired. It forwards bytes.

It does **not** simulate anything. Trades and battles run inside the two
game clients on the engine's own link code, with the hub passing opaque
payloads between them. A hub that refereed battles would be a second, worse
implementation of Gen 1's rules that could disagree with the clients — so
`mmo.relay` payloads are never parsed here.

Wire format is newline-delimited JSON, the same framing
`src/link/Net.lua`'s relay backend already speaks, which is why the mod can
reuse the engine's transport instead of shipping its own socket code.

## Protocol

Every type is prefixed `mmo.` so it can never collide with the four control
types (`hosted`, `paired`, `join_error`, `peer_gone`) that `Net.lua`
intercepts on a relay connection.

**Client → hub**

| Type | Payload |
| --- | --- |
| `mmo.hello` | `proto, name, sprite, map, x, y, facing` |
| `mmo.move` | `map, x, y, facing, busy` — an absent cell means "not in the world" |
| `mmo.chat` | `scope, to, text` |
| `mmo.request` | `to, kind` (`trade` \| `battle`) |
| `mmo.respond` | `to, kind, accept` |
| `mmo.relay` | `to, payload` — opaque |
| `mmo.session_leave` | — |
| `mmo.ping` | — |

**Hub → client**

| Type | Payload |
| --- | --- |
| `mmo.welcome` | `id, players[]` |
| `mmo.join` / `mmo.part` | `player` / `id` |
| `mmo.move` | a presence record |
| `mmo.chat` | `from, name, scope, text` |
| `mmo.request` / `mmo.decline` | `from, name, kind` / `name, kind` |
| `mmo.session` | `peer, peerName, kind, role, id` — the asker hosts |
| `mmo.relay` | `from, payload` |
| `mmo.session_end` | `reason` |
| `mmo.error` | `message` — always fatal to the connection |
| `mmo.pong` | — |

Bump `PROTOCOL` in both `hub.js` and `src/Config.lua` together on any
incompatible change. The hub refuses a mismatched client by name and
version rather than letting two dialects talk past each other.

## Security posture

Be clear-eyed about this before you expose a port.

- Every inbound field is re-derived through a sanitiser; nothing arrives
  trusted, and a malformed line is dropped rather than fatal.
- Chat is rate-limited to roughly two messages a second per sender.
- A connection that has not said hello does **not** hold a player seat, and
  is dropped if it stays silent. Charging the cap on connect meant four idle
  sockets could lock everyone out of a four-player game.
- Relay payloads are forwarded unread, but their *shape* is bounded. The
  decoder tolerates input far deeper than the encoder can re-emit, so a
  deeply nested payload used to throw while being forwarded and take the
  whole hub down with it.
- A message that will not serialise costs its own connection and nothing
  else. No single peer should be able to end everybody's session.
- Identity is **the connection**, nothing more. There are no accounts, no
  passwords, and no bans: anyone who can reach the port can join under any
  name, including one already in use.
- Position is self-reported, so a modified client can claim to be anywhere.
  That is unavoidable in a relay design and harmless for presence, but it
  does mean `local` chat radius is not an enforceable boundary.

Run one for people you know. It is not built to be a public server.

## Tests

```sh
node hub.test.js
```

Starts the hub on a scratch port and drives it over real sockets: framing,
the protocol gate, scope routing, the flood gate, session pairing, relay
isolation between non-paired players, and teardown on a dropped socket.
