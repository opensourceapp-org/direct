const DIRECT_ID = /^dir_[0-9A-HJKMNP-TV-Z]{16}$/;
const MAX_BUNDLE = 8192;
const MAX_SIGNAL = 64 * 1024;
const MAX_FRAME = MAX_SIGNAL + MAX_BUNDLE;
const MAX_WATCH = 256;
const GRACE_MS = 120_000;

/**
 * In-memory rendezvous for devices that are not on the same network.
 * Holds the latest public bundle per DIRECT ID, tells watchers when a DIRECT ID
 * comes online or drops, and forwards WebRTC session descriptions and ICE candidates.
 * A bundle stays findable for two minutes after the socket drops so a lookup
 * still succeeds while the phone reconnects. Message text and envelopes are never
 * accepted or forwarded here; see contracts/signaling.json.
 */
function createSignalHub(options = {}) {
  const peers = new Map();
  const watchers = new Map();
  const now = typeof options.now === 'function' ? options.now : () => Date.now();
  const onHello = typeof options.onHello === 'function' ? options.onHello : null;

  function valid(id, bundle) {
    return typeof id === 'string'
      && DIRECT_ID.test(id)
      && typeof bundle === 'string'
      && bundle.length >= 32
      && bundle.length <= MAX_BUNDLE
      && bundle.includes(`"directId":"${id}"`);
  }

  function visible(peer, at) {
    if (!peer) return false;
    if (peer.send) return true;
    return at - peer.closedAt < GRACE_MS;
  }

  function sweep(at) {
    for (const [id, peer] of peers) {
      if (!peer.send && at - peer.closedAt >= GRACE_MS) peers.delete(id);
    }
  }

  function announce(id, online) {
    const listeners = watchers.get(id);
    if (!listeners) return;
    const frame = JSON.stringify({ kind: 'presence', directId: id, online });
    for (const listener of listeners) listener(frame);
  }

  /** Record a public bundle with no live socket, or refresh one that already has a socket. */
  function remember(id, bundle) {
    if (!valid(id, bundle)) return false;
    const current = peers.get(id);
    const send = current && current.send ? current.send : null;
    peers.set(id, {
      bundle,
      send,
      token: current ? current.token : 0,
      closedAt: send ? 0 : now(),
    });
    return true;
  }

  function attach(socket) {
    let selfId = '';
    let token = 0;
    let watching = new Set();

    const send = (text) => {
      if (socket.readyState === 1) socket.send(text);
    };

    const unwatch = () => {
      for (const id of watching) {
        const listeners = watchers.get(id);
        if (!listeners) continue;
        listeners.delete(send);
        if (listeners.size === 0) watchers.delete(id);
      }
      watching = new Set();
    };

    const onMessage = (raw) => {
      const textFrame = String(raw);
      if (textFrame.length > MAX_FRAME) return;
      let message;
      try {
        message = JSON.parse(textFrame);
      } catch {
        return;
      }
      if (!message || typeof message !== 'object') return;

      if (message.kind === 'hello') {
        const id = message.from;
        const bundle = message.bundle;
        if (!valid(id, bundle)) return;
        if (selfId && selfId !== id) return;
        const wasOnline = Boolean(peers.get(id)?.send);
        selfId = id;
        token += 1;
        peers.set(id, { bundle, send, token, closedAt: 0 });
        if (onHello) onHello(id, bundle);
        if (!wasOnline) announce(id, true);
        return;
      }

      if (message.kind === 'lookup') {
        const requestId = message.requestId;
        const directId = message.directId;
        if (typeof requestId !== 'string' || requestId.length < 1 || requestId.length > 80) return;
        const at = now();
        sweep(at);
        const peer = typeof directId === 'string' ? peers.get(directId) : undefined;
        const shown = visible(peer, at) ? peer : undefined;
        send(JSON.stringify({
          kind: 'lookup',
          requestId,
          directId: typeof directId === 'string' ? directId : '',
          present: Boolean(shown),
          bundle: shown ? shown.bundle : null,
        }));
        return;
      }

      if (message.kind === 'watch') {
        if (!Array.isArray(message.ids)) return;
        const ids = message.ids.filter((id) => typeof id === 'string' && DIRECT_ID.test(id)).slice(0, MAX_WATCH);
        unwatch();
        watching = new Set(ids);
        for (const id of watching) {
          const listeners = watchers.get(id) ?? new Set();
          listeners.add(send);
          watchers.set(id, listeners);
          send(JSON.stringify({ kind: 'presence', directId: id, online: Boolean(peers.get(id)?.send) }));
        }
        return;
      }

      if (message.kind !== 'offer' && message.kind !== 'answer' && message.kind !== 'ice') return;
      if (typeof message.to !== 'string' || typeof message.from !== 'string') return;
      if (!selfId || message.from !== selfId) return;
      const encoded = JSON.stringify(message);
      if (encoded.length > MAX_SIGNAL) return;
      const target = peers.get(message.to);
      if (target && target.send) {
        target.send(encoded);
        return;
      }
      if (message.kind === 'offer') send(JSON.stringify({ kind: 'unreachable', to: message.to }));
    };

    const onClose = () => {
      unwatch();
      if (!selfId) return;
      const current = peers.get(selfId);
      if (current && current.send === send && current.token === token) {
        peers.set(selfId, { bundle: current.bundle, send: null, token, closedAt: now() });
        announce(selfId, false);
      }
    };

    socket.on('message', onMessage);
    socket.on('close', onClose);
    const beat = setInterval(() => {
      if (socket.readyState === 1 && typeof socket.ping === 'function') socket.ping();
    }, 25_000);
    if (typeof beat.unref === 'function') beat.unref();
    socket.on('close', () => clearInterval(beat));
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

  /** Phones with a live socket. A phone in the two-minute grace window is findable, but not listed. */
  function roster() {
    const at = now();
    sweep(at);
    const users = [];
    for (const [directId, peer] of peers) {
      if (!peer.send) continue;
      users.push({ directId, name: displayName(peer.bundle) });
    }
    users.sort((a, b) => (a.name || a.directId).localeCompare(b.name || b.directId));
    return users;
  }

  return { attach, remember, roster };
}

module.exports = { createSignalHub, DIRECT_ID, GRACE_MS, MAX_SIGNAL, MAX_BUNDLE, MAX_WATCH };
