const { randomBytes } = require('node:crypto');
const { newToken, hashToken } = require('./verify.cjs');

const GRACE_MS = 120_000;
const SESSION_TTL_MS = 90_000;

function newId() {
  return randomBytes(16).toString('hex');
}

function live(peer, at) {
  if (!peer) return false;
  if (peer.sessionId) return true;
  return at - Number(peer.closedAt || 0) < GRACE_MS;
}

function createMemoryStore() {
  const sessions = new Map();
  const peers = new Map();
  const inbox = new Map();

  return {
    async createSession() {
      const token = newToken();
      const row = {
        id: newId(),
        tokenHash: hashToken(token),
        nonce: '',
        directId: null,
        bundle: null,
        watch: [],
        helloCount: 0,
        lastSeen: Date.now(),
      };
      sessions.set(row.id, row);
      return { session: row, token };
    },
    async loadSession(id) {
      return sessions.get(id) || null;
    },
    async saveSession(row) {
      row.lastSeen = Date.now();
      sessions.set(row.id, row);
    },
    async loadPeer(directId) {
      return peers.get(directId) || null;
    },
    async savePeer(row) {
      peers.set(row.directId, row);
    },
    async listDiscoverable(exceptId, limit = 24) {
      const people = [];
      for (const [directId, peer] of peers) {
        if (!peer.sessionId || !peer.discoverable) continue;
        if (exceptId && directId === exceptId) continue;
        people.push({ directId, bundle: peer.bundle });
      }
      people.sort((a, b) => a.directId.localeCompare(b.directId));
      return people.slice(0, limit);
    },
    async sessionsWatching(directId) {
      const ids = [];
      for (const row of sessions.values()) {
        if ((row.watch || []).includes(directId)) ids.push(row.id);
      }
      return ids;
    },
    async push(sessionId, payload) {
      const list = inbox.get(sessionId) || [];
      list.push(payload);
      inbox.set(sessionId, list);
    },
    async pull(sessionId) {
      const list = inbox.get(sessionId) || [];
      inbox.set(sessionId, []);
      return list;
    },
    async sweep() {
      const at = Date.now();
      for (const [id, row] of sessions) {
        if (at - row.lastSeen <= SESSION_TTL_MS) continue;
        sessions.delete(id);
        inbox.delete(id);
        if (!row.directId) continue;
        const peer = peers.get(row.directId);
        if (peer && peer.sessionId === id) {
          peers.set(row.directId, { ...peer, sessionId: null, closedAt: at });
        }
      }
      for (const [id, peer] of peers) {
        if (!live(peer, at) && at - Number(peer.closedAt || 0) >= GRACE_MS) peers.delete(id);
      }
    },
    visible(peer, at = Date.now()) {
      return live(peer, at);
    },
  };
}

function createPgStore(pool) {
  return {
    async createSession() {
      const id = newId();
      const token = newToken();
      const tokenHash = hashToken(token);
      await pool.query(
        'insert into signal_sessions (id, nonce, watch, hello_count, last_seen, token_hash) values ($1, $2, $3, 0, now(), $4)',
        [id, '', [], tokenHash],
      );
      return {
        session: { id, nonce: '', directId: null, bundle: null, watch: [], helloCount: 0, lastSeen: Date.now(), tokenHash },
        token,
      };
    },
    async loadSession(id) {
      const { rows } = await pool.query(
        'select id, nonce, direct_id as "directId", bundle, watch, hello_count as "helloCount", token_hash as "tokenHash" from signal_sessions where id = $1',
        [id],
      );
      const row = rows[0];
      if (!row) return null;
      return { ...row, watch: row.watch || [] };
    },
    async saveSession(row) {
      await pool.query(
        `insert into signal_sessions (id, nonce, direct_id, bundle, watch, hello_count, last_seen)
         values ($1, $2, $3, $4, $5, $6, now())
         on conflict (id) do update set nonce = $2, direct_id = $3, bundle = $4, watch = $5, hello_count = $6, last_seen = now()`,
        [row.id, row.nonce || '', row.directId, row.bundle, row.watch || [], row.helloCount || 0],
      );
    },
    async loadPeer(directId) {
      const { rows } = await pool.query(
        'select direct_id as "directId", bundle, session_id as "sessionId", extract(epoch from closed_at) * 1000 as "closedAt", discoverable from signal_peers where direct_id = $1',
        [directId],
      );
      const row = rows[0];
      if (!row) return null;
      return { ...row, closedAt: row.closedAt == null ? null : Number(row.closedAt) };
    },
    async savePeer(row) {
      await pool.query(
        `insert into signal_peers (direct_id, bundle, session_id, closed_at, discoverable)
         values ($1, $2, $3, $4, $5)
         on conflict (direct_id) do update set bundle = $2, session_id = $3, closed_at = $4, discoverable = $5`,
        [row.directId, row.bundle, row.sessionId || null, row.closedAt ? new Date(row.closedAt) : null, Boolean(row.discoverable)],
      );
    },
    async listDiscoverable(exceptId, limit = 24) {
      const { rows } = await pool.query(
        `select direct_id as "directId", bundle
         from signal_peers
         where discoverable is true and session_id is not null
           and ($1::text is null or direct_id <> $1)
         order by direct_id
         limit $2`,
        [exceptId || null, limit],
      );
      return rows;
    },
    async sessionsWatching(directId) {
      const { rows } = await pool.query(
        "select id from signal_sessions where watch @> array[$1]::text[] and last_seen > now() - interval '90 seconds'",
        [directId],
      );
      return rows.map((row) => row.id);
    },
    async push(sessionId, payload) {
      await pool.query('insert into signal_inbox (session_id, payload) values ($1, $2)', [sessionId, payload]);
    },
    async pull(sessionId) {
      const { rows } = await pool.query(
        `with taken as (
           select id from signal_inbox where session_id = $1 order by id for update skip locked
         )
         delete from signal_inbox where id in (select id from taken) returning payload`,
        [sessionId],
      );
      return rows.map((row) => row.payload);
    },
    async sweep() {
      await pool.query("delete from signal_sessions where last_seen < now() - interval '90 seconds'");
      await pool.query('update signal_peers set session_id = null, closed_at = now() where session_id is not null and session_id not in (select id from signal_sessions)');
      await pool.query("delete from signal_peers where session_id is null and closed_at < now() - interval '2 minutes'");
      await pool.query("delete from signal_inbox where created_at < now() - interval '2 minutes'");
    },
    visible(peer, at = Date.now()) {
      return live(peer, at);
    },
  };
}

let cached;

async function getStore() {
  if (cached) return cached;
  const url = String(process.env.DATABASE_URL || '').trim();
  if (!url) {
    cached = createMemoryStore();
    return cached;
  }
  const pg = require('pg');
  cached = createPgStore(new pg.Pool({ connectionString: url, max: 5 }));
  return cached;
}

module.exports = { getStore, createMemoryStore, GRACE_MS, SESSION_TTL_MS };
