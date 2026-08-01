#!/usr/bin/env node
'use strict';

/*
 * RBY MMO hub.
 *
 * A relay, not a game server. It never simulates anything: it owns who is
 * connected, where they said they are, and which two players are currently
 * paired for a trade or a battle. Everything else -- the trade state
 * machine, the lockstep battle -- runs inside the two game clients, exactly
 * as it does over a direct link, with this process forwarding the bytes.
 *
 * That split is deliberate. The engine's link code is the authority on Gen
 * 1 behaviour and it already works; a hub that tried to referee battles
 * would be a second, worse implementation of it that could disagree with
 * the clients.
 *
 * Wire format is newline-delimited JSON, which is what src/link/Net.lua's
 * relay backend already speaks, so the client reuses the engine's framing
 * instead of shipping its own.
 *
 * No dependencies: node hub.js [port]
 */

const net = require('net');

const PROTOCOL = 1;
const PORT = Number(process.argv[2] || process.env.RBY_MMO_PORT || 7788);
const HOST = process.env.RBY_MMO_HOST || '0.0.0.0';

const LOCAL_RADIUS = 12;
const NAME_MAX = 10;
const MESSAGE_MAX = 60;
const MAX_LINE = 64 * 1024;
const TIMEOUT_MS = 45000;
// The player cap. Defaults to 4 and may be raised to 64 -- the same bounds
// the in-game host picks from, and clamped here for the same reason they
// are clamped there: the limit must not be settable out of range by editing
// a config, only by the one mechanism that is meant to set it.
//
// A dedicated hub takes its limit from the environment. A hub running
// inside somebody's game takes it from the host's in-game choice; the two
// are the same protocol and the same bounds, just different front doors.
const MIN_PLAYERS = 2;
const MAX_PLAYERS = 64;
const DEFAULT_PLAYERS = 4;

function clampPlayers(value) {
  const n = Math.floor(Number(value));
  if (!Number.isFinite(n)) return DEFAULT_PLAYERS;
  return Math.min(MAX_PLAYERS, Math.max(MIN_PLAYERS, n));
}

const MAX_CLIENTS = process.env.RBY_MMO_MAX
  ? clampPlayers(process.env.RBY_MMO_MAX)
  : DEFAULT_PLAYERS;

/** id -> client */
const clients = new Map();
/** sessionId -> { a, b, kind } */
const sessions = new Map();

let nextId = 1;
let nextSession = 1;

const log = (...args) => console.log(new Date().toISOString(), ...args);

// ---------------------------------------------------------------- sanitising
//
// Everything below the line is untrusted: a client is somebody else's
// process, and a modified one is a normal thing to encounter. Every field
// is re-derived rather than checked in place.

const TEXT_OK = /[^A-Za-z0-9 .,!?'\-:;()/]/g;

function cleanText(value, limit) {
  if (typeof value !== 'string') return null;
  const clean = value.replace(TEXT_OK, '').replace(/\s+/g, ' ').trim();
  if (!clean) return null;
  return clean.slice(0, limit);
}

function cleanId(value) {
  if (typeof value !== 'string') return null;
  return /^[\w-]{1,40}$/.test(value) ? value : null;
}

// A sprite id is an engine identifier (SPRITE_RED), not prose. cleanText
// strips the underscore, turning it into SPRITERED, which then misses the
// catalog lookup and draws every player as the fallback -- invisibly,
// because the fallback works.
function cleanSpriteId(value) {
  if (typeof value !== 'string') return null;
  return /^\w{1,40}$/.test(value) ? value : null;
}

function cleanMapId(value) {
  if (typeof value !== 'string') return null;
  return /^[\w.-]{1,64}$/.test(value) ? value : null;
}

function cleanInt(value, min, max) {
  const n = Number(value);
  if (!Number.isFinite(n)) return null;
  const i = Math.floor(n);
  return i >= min && i <= max ? i : null;
}

const FACINGS = new Set(['up', 'down', 'left', 'right']);
const KINDS = new Set(['trade', 'battle']);
const SCOPES = new Set(['global', 'local', 'private']);

// ------------------------------------------------------------------ plumbing

function send(client, type, payload) {
  if (!client || client.socket.destroyed) return;
  const msg = Object.assign({}, payload, { type });
  // stringify can throw (RangeError on deeply nested input, TypeError on a
  // cycle). One peer's message must never be able to take the hub down for
  // everyone, so a message that will not serialise costs that connection
  // and nothing else.
  let line;
  try {
    line = JSON.stringify(msg) + '\n';
  } catch (err) {
    log(`dropping ${client.id}: message would not serialise (${err.message})`);
    client.socket.destroy();
    return;
  }
  client.socket.write(line);
}

// Relay payloads are forwarded unread, so shape is all that can be judged.
// Iterative on purpose: a recursive check would blow the same stack it is
// meant to protect. Mirrors Wire.payloadOk on the Lua side.
const PAYLOAD_MAX_DEPTH = 32;
const PAYLOAD_MAX_NODES = 4096;

function payloadOk(value) {
  if (value === null || typeof value !== 'object') return false;
  const stack = [[value, 1]];
  let nodes = 0;
  while (stack.length) {
    const [node, depth] = stack.pop();
    if (depth > PAYLOAD_MAX_DEPTH) return false;
    for (const child of Object.values(node)) {
      if (++nodes > PAYLOAD_MAX_NODES) return false;
      if (child !== null && typeof child === 'object') {
        stack.push([child, depth + 1]);
      }
    }
  }
  return true;
}

function fail(client, message) {
  send(client, 'mmo.error', { message });
  client.socket.end();
}

function presenceOf(client) {
  return {
    id: client.id,
    name: client.name,
    sprite: client.sprite,
    map: client.map,
    x: client.x,
    y: client.y,
    facing: client.facing,
    busy: Boolean(client.sessionId),
  };
}

function broadcast(type, payload, exceptId) {
  for (const client of clients.values()) {
    if (client.id !== exceptId && client.ready) send(client, type, payload);
  }
}

// ------------------------------------------------------------------ sessions

function peerOf(client) {
  if (!client.sessionId) return null;
  const session = sessions.get(client.sessionId);
  if (!session) return null;
  return clients.get(session.a === client.id ? session.b : session.a) || null;
}

function endSession(client, reason) {
  const id = client.sessionId;
  if (!id) return;
  const session = sessions.get(id);
  sessions.delete(id);
  client.sessionId = null;

  if (session) {
    const otherId = session.a === client.id ? session.b : session.a;
    const other = clients.get(otherId);
    if (other && other.sessionId === id) {
      other.sessionId = null;
      send(other, 'mmo.session_end', { reason });
      broadcast('mmo.move', presenceOf(other), other.id);
    }
  }
  if (clients.has(client.id)) broadcast('mmo.move', presenceOf(client), client.id);
}

function startSession(a, b, kind) {
  const id = String(nextSession++);
  sessions.set(id, { a: a.id, b: b.id, kind });
  a.sessionId = id;
  b.sessionId = id;

  // The requester hosts. Someone has to deal the battle's shared RNG seed,
  // and picking the side that asked keeps it deterministic rather than
  // racing on who answers first.
  send(a, 'mmo.session',
    { peer: b.id, peerName: b.name, kind, role: 'host', id });
  send(b, 'mmo.session',
    { peer: a.id, peerName: a.name, kind, role: 'guest', id });

  broadcast('mmo.move', presenceOf(a), a.id);
  broadcast('mmo.move', presenceOf(b), b.id);
  log(`session ${id}: ${a.name} <-> ${b.name} (${kind})`);
}

// ------------------------------------------------------------------ handlers

const handlers = {};

handlers['mmo.hello'] = (client, msg) => {
  if (client.ready) return;
  if (cleanInt(msg.proto, 0, 9999) !== PROTOCOL) {
    return fail(client,
      `This hub speaks protocol ${PROTOCOL}; your mod speaks ${msg.proto}.`);
  }
  const name = cleanText(msg.name, NAME_MAX);
  if (!name) return fail(client, 'That trainer name cannot be used here.');

  client.name = name;
  client.sprite = cleanSpriteId(msg.sprite) || 'SPRITE_RED';
  client.map = cleanMapId(msg.map);
  client.x = cleanInt(msg.x, 0, 4096);
  client.y = cleanInt(msg.y, 0, 4096);
  client.facing = FACINGS.has(msg.facing) ? msg.facing : 'down';
  client.ready = true;

  const players = [];
  for (const other of clients.values()) {
    if (other.ready && other.id !== client.id) players.push(presenceOf(other));
  }
  send(client, 'mmo.welcome', { id: client.id, players });
  broadcast('mmo.join', { player: presenceOf(client) }, client.id);
  log(`+ ${client.name} (${client.id}) -- ${clients.size} online`);
};

handlers['mmo.move'] = (client, msg) => {
  if (!client.ready) return;
  const map = cleanMapId(msg.map);
  const x = cleanInt(msg.x, 0, 4096);
  const y = cleanInt(msg.y, 0, 4096);
  if (map !== null && x !== null && y !== null) {
    client.map = map;
    client.x = x;
    client.y = y;
  } else {
    // no cell means "not in the world right now" (a battle, a menu): the
    // player stays on the roster but stops being placeable
    client.map = null;
    client.x = null;
    client.y = null;
  }
  if (FACINGS.has(msg.facing)) client.facing = msg.facing;
  broadcast('mmo.move', presenceOf(client), client.id);
};

handlers['mmo.chat'] = (client, msg) => {
  if (!client.ready) return;
  const scope = SCOPES.has(msg.scope) ? msg.scope : null;
  const text = cleanText(msg.text, MESSAGE_MAX);
  if (!scope || !text) return;

  const now = Date.now();
  // A light flood gate. Not a moderation system -- just enough that one
  // client cannot fill every other client's scrollback faster than it can
  // be read.
  if (now - client.lastChat < 500) return;
  client.lastChat = now;

  const payload = { from: client.id, name: client.name, scope, text };

  if (scope === 'private') {
    const target = clients.get(cleanId(msg.to));
    if (target && target.ready) send(target, 'mmo.chat', payload);
    return;
  }

  if (scope === 'local') {
    if (!client.map) return;
    for (const other of clients.values()) {
      if (other.id === client.id || !other.ready) continue;
      if (other.map !== client.map) continue;
      const distance = Math.max(
        Math.abs(other.x - client.x), Math.abs(other.y - client.y));
      if (distance <= LOCAL_RADIUS) send(other, 'mmo.chat', payload);
    }
    return;
  }

  broadcast('mmo.chat', payload, client.id);
};

handlers['mmo.request'] = (client, msg) => {
  if (!client.ready || client.sessionId) return;
  const kind = KINDS.has(msg.kind) ? msg.kind : null;
  const target = clients.get(cleanId(msg.to));
  if (!kind || !target || !target.ready || target.id === client.id) return;

  if (target.sessionId) {
    return send(client, 'mmo.decline', { name: target.name, kind });
  }
  client.pendingTo = target.id;
  send(target, 'mmo.request', { from: client.id, name: client.name, kind });
};

handlers['mmo.respond'] = (client, msg) => {
  if (!client.ready) return;
  const kind = KINDS.has(msg.kind) ? msg.kind : null;
  const asker = clients.get(cleanId(msg.to));
  if (!kind || !asker || !asker.ready) return;

  // only the player who was actually asked can answer, and only while the
  // ask is still outstanding
  if (asker.pendingTo !== client.id) return;
  asker.pendingTo = null;

  if (!msg.accept) {
    return send(asker, 'mmo.decline', { name: client.name, kind });
  }
  if (client.sessionId || asker.sessionId) {
    return send(asker, 'mmo.decline', { name: client.name, kind });
  }
  startSession(asker, client, kind);
};

handlers['mmo.relay'] = (client, msg) => {
  if (!client.ready || !client.sessionId) return;
  const peer = peerOf(client);
  if (!peer) return;
  if (cleanId(msg.to) !== peer.id) return;
  if (!payloadOk(msg.payload)) return;
  // The hub does not read the payload. It is the engine's own link
  // vocabulary, and interpreting it here would couple this process to a
  // protocol the game already owns.
  send(peer, 'mmo.relay', { from: client.id, payload: msg.payload });
};

handlers['mmo.session_leave'] = (client) => {
  endSession(client, 'peer_left');
};

handlers['mmo.ping'] = (client) => {
  send(client, 'mmo.pong', {});
};

// -------------------------------------------------------------------- server

const server = net.createServer((socket) => {
  if (clients.size >= MAX_CLIENTS) {
    socket.write(JSON.stringify({
      type: 'mmo.error',
      message: `This hub is full (${MAX_CLIENTS} players).`,
    }) + '\n');
    return socket.end();
  }

  const client = {
    id: String(nextId++),
    socket,
    buffer: '',
    ready: false,
    name: null,
    sprite: 'SPRITE_RED',
    map: null, x: null, y: null, facing: 'down',
    sessionId: null,
    pendingTo: null,
    lastChat: 0,
  };
  clients.set(client.id, client);

  socket.setNoDelay(true);
  socket.setTimeout(TIMEOUT_MS);
  socket.setEncoding('utf8');

  socket.on('data', (chunk) => {
    client.buffer += chunk;
    if (client.buffer.length > MAX_LINE) {
      return fail(client, 'Message too long.');
    }
    let index;
    while ((index = client.buffer.indexOf('\n')) >= 0) {
      const line = client.buffer.slice(0, index);
      client.buffer = client.buffer.slice(index + 1);
      if (!line) continue;

      let msg;
      try {
        msg = JSON.parse(line);
      } catch (err) {
        continue; // a malformed line is dropped, not fatal
      }
      if (!msg || typeof msg.type !== 'string') continue;

      const handler = handlers[msg.type];
      if (!handler) continue;
      try {
        handler(client, msg);
      } catch (err) {
        log(`handler ${msg.type} failed for ${client.id}:`, err.message);
      }
    }
  });

  const drop = () => {
    if (!clients.has(client.id)) return;
    endSession(client, 'peer_left');
    clients.delete(client.id);
    for (const other of clients.values()) {
      if (other.pendingTo === client.id) other.pendingTo = null;
    }
    if (client.ready) {
      broadcast('mmo.part', { id: client.id }, client.id);
      log(`- ${client.name} (${client.id}) -- ${clients.size} online`);
    }
  };

  socket.on('timeout', () => socket.destroy());
  socket.on('error', () => drop());
  socket.on('close', drop);
});

server.on('error', (err) => {
  log('hub failed to start:', err.message);
  process.exit(1);
});

server.listen(PORT, HOST, () => {
  log(`RBY MMO hub listening on ${HOST}:${PORT} (protocol ${PROTOCOL})`);
});

for (const signal of ['SIGINT', 'SIGTERM']) {
  process.on(signal, () => {
    log('shutting down');
    for (const client of clients.values()) {
      send(client, 'mmo.error', { message: 'The hub is shutting down.' });
      client.socket.end();
    }
    server.close(() => process.exit(0));
    setTimeout(() => process.exit(0), 1000).unref();
  });
}
