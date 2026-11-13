const { DIRECT_ID, MAX_BUNDLE, verifyHello, newNonce, tokenMatches } = require('./verify.cjs');
const { getStore, createMemoryStore } = require('./store.cjs');

const MAX_SIGNAL = 64 * 1024;
const MAX_WATCH = 256;
const MAX_HELLOS = 8;
const MAX_SUGGEST = 24;
const MAX_WAIT_MS = 8_000;
const MAX_FRAMES = 40;

class SignalingAuthError extends Error {
  constructor() {
    super('unauthorized');
    this.status = 401;
  }
}

function displayName(bundle) {
  try {
    const parsed = JSON.parse(bundle);
    if (parsed && typeof parsed.name === 'string') {
      const name = parsed.name.trim();
      if (name) return name.slice(0, 80);
    }
  } catch {
    // A public bundle only has to contain the DIRECT ID. The name is optional.
  }
  return '';
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function enqueue(store, sessionId, frame) {
  await store.push(sessionId, JSON.stringify(frame));
}

async function announce(store, directId, online) {
  const watchers = await store.sessionsWatching(directId);
  for (const id of watchers) {
    await enqueue(store, id, { kind: 'presence', directId, online });
  }
}

async function handleFrames(store, session, frames) {
  // lookup, watch, suggest, and WebRTC forwarding require a verified hello
  // on this session. The session token is checked in exchange() before this.
  const replies = [];
  if (!session.nonce) {
    session.nonce = newNonce();
    replies.push({ kind: 'challenge', nonce: session.nonce });
  }

  for (const message of frames) {
    if (!message || typeof message !== 'object') continue;

    if (message.kind === 'hello') {
      session.helloCount = (session.helloCount || 0) + 1;
      if (session.helloCount > MAX_HELLOS) continue;
      const verified = verifyHello(message, session.nonce);
      if (!verified) continue;
      if (session.directId && session.directId !== verified.directId) continue;
      const wasOnline = Boolean((await store.loadPeer(verified.directId))?.sessionId);
      session.directId = verified.directId;
      session.bundle = message.bundle;
      await store.savePeer({
        directId: verified.directId,
        bundle: message.bundle,
        sessionId: session.id,
        closedAt: null,
        discoverable: message.discoverable === true,
      });
      if (!wasOnline) await announce(store, verified.directId, true);
      continue;
    }

    if (message.kind === 'lookup') {
      if (!session.directId) continue;
      const requestId = message.requestId;
      const directId = message.directId;
      if (typeof requestId !== 'string' || requestId.length < 1 || requestId.length > 80) continue;
      const peer = typeof directId === 'string' ? await store.loadPeer(directId) : null;
      const shown = store.visible(peer) ? peer : null;
      replies.push({
        kind: 'lookup',
        requestId,
        directId: typeof directId === 'string' ? directId : '',
        present: Boolean(shown),
        bundle: shown ? shown.bundle : null,
      });
      continue;
    }

    if (message.kind === 'watch') {
      if (!session.directId) continue;
      if (!Array.isArray(message.ids)) continue;
      session.watch = message.ids.filter((id) => typeof id === 'string' && DIRECT_ID.test(id)).slice(0, MAX_WATCH);
      for (const id of session.watch) {
        const peer = await store.loadPeer(id);
        replies.push({ kind: 'presence', directId: id, online: Boolean(peer && peer.sessionId) });
      }
      continue;
    }

    if (message.kind === 'suggest') {
      if (!session.directId) continue;
      const requestId = message.requestId;
      if (typeof requestId !== 'string' || requestId.length < 1 || requestId.length > 80) continue;
      const people = [];
      if (session.directId) {
        const listed = await store.listDiscoverable(session.directId, MAX_SUGGEST);
        for (const row of listed) {
          people.push({
            directId: row.directId,
            name: displayName(row.bundle),
            bundle: row.bundle,
            online: true,
          });
        }
      }
      people.sort((a, b) => (a.name || a.directId).localeCompare(b.name || b.directId));
      replies.push({ kind: 'suggestions', requestId, people: people.slice(0, MAX_SUGGEST) });
      continue;
    }

    if (message.kind !== 'offer' && message.kind !== 'answer' && message.kind !== 'ice') continue;
    if (typeof message.to !== 'string' || typeof message.from !== 'string') continue;
    if (!session.directId || message.from !== session.directId) continue;
    const encoded = JSON.stringify(message);
    if (encoded.length > MAX_SIGNAL) continue;
    const target = await store.loadPeer(message.to);
    if (target && target.sessionId) {
      await enqueue(store, target.sessionId, message);
      continue;
    }
    if (message.kind === 'offer') replies.push({ kind: 'unreachable', to: message.to });
  }

  await store.saveSession(session);
  return replies;
}

async function exchange(body, options = {}) {
  const store = options.store || (await getStore());
  await store.sweep();
  const frames = Array.isArray(body.frames) ? body.frames.slice(0, MAX_FRAMES) : [];
  let session;
  let issuedToken;
  if (typeof body.session === 'string' && body.session) {
    session = await store.loadSession(body.session);
    // The public session id is a locator, not a credential. Inbox frames
    // (offers, answers, ICE) are only released when the creation token matches.
    if (!session || !tokenMatches(session.tokenHash, body.token)) {
      throw new SignalingAuthError();
    }
  } else {
    const created = await store.createSession();
    session = created.session;
    issuedToken = created.token;
  }
  const immediate = await handleFrames(store, session, frames);
  for (const frame of immediate) await enqueue(store, session.id, frame);
  const waitMs = session.directId
    ? Math.max(0, Math.min(MAX_WAIT_MS, Number(body.waitMs) || 0))
    : 0;
  let outbound = await store.pull(session.id);
  const deadline = Date.now() + waitMs;
  while (outbound.length === 0 && Date.now() < deadline) {
    await sleep(Math.min(250, deadline - Date.now()));
    outbound = await store.pull(session.id);
  }
  const result = {
    session: session.id,
    nonce: session.nonce,
    frames: outbound.map((raw) => {
      try {
        return JSON.parse(raw);
      } catch {
        return null;
      }
    }).filter(Boolean),
  };
  if (issuedToken) result.token = issuedToken;
  return result;
}

module.exports = {
  exchange,
  getStore,
  createMemoryStore,
  SignalingAuthError,
  MAX_BUNDLE,
  MAX_WAIT_MS,
  MAX_FRAMES,
};
