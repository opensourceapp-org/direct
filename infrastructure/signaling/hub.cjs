const DIRECT_ID = /^dir_[0-9A-HJKMNP-TV-Z]{16}$/;
const MAX_BUNDLE = 8192;
const MAX_SIGNAL = 64 * 1024;

/**
 * In-memory rendezvous for devices that are not on the same network.
 * Holds the latest public bundle per DIRECT ID and forwards session descriptions.
 * Message plaintext is never accepted here.
 */
function createSignalHub() {
  const peers = new Map();

  function attach(socket) {
    let selfId = '';
    let token = 0;

    const send = (text) => {
      if (socket.readyState === 1) socket.send(text);
    };

    const onMessage = (raw) => {
      let message;
      try {
        message = JSON.parse(String(raw));
      } catch {
        return;
      }
      if (!message || typeof message !== 'object') return;

      if (message.kind === 'hello') {
        const id = message.from;
        const bundle = message.bundle;
        if (typeof id !== 'string' || !DIRECT_ID.test(id)) return;
        if (typeof bundle !== 'string' || bundle.length < 32 || bundle.length > MAX_BUNDLE) return;
        if (!bundle.includes(`"directId":"${id}"`)) return;
        selfId = id;
        token += 1;
        peers.set(id, { bundle, send, token });
        return;
      }

      if (message.kind === 'lookup') {
        const requestId = message.requestId;
        const directId = message.directId;
        if (typeof requestId !== 'string' || requestId.length < 1 || requestId.length > 80) return;
        const peer = typeof directId === 'string' ? peers.get(directId) : undefined;
        send(JSON.stringify({
          kind: 'lookup',
          requestId,
          directId: typeof directId === 'string' ? directId : '',
          present: Boolean(peer),
          bundle: peer ? peer.bundle : null,
        }));
        return;
      }

      if (message.kind !== 'offer' && message.kind !== 'answer' && message.kind !== 'ice') return;
      if (typeof message.to !== 'string' || typeof message.from !== 'string') return;
      const encoded = JSON.stringify(message);
      if (encoded.length > MAX_SIGNAL) return;
      const target = peers.get(message.to);
      if (target) {
        target.send(encoded);
        return;
      }
      if (message.kind === 'offer') send(JSON.stringify({ kind: 'unreachable', to: message.to }));
    };

    const onClose = () => {
      if (!selfId) return;
      const current = peers.get(selfId);
      if (current && current.send === send && current.token === token) peers.delete(selfId);
    };

    socket.on('message', onMessage);
    socket.on('close', onClose);
    const beat = setInterval(() => {
      if (socket.readyState === 1 && typeof socket.ping === 'function') socket.ping();
    }, 25_000);
    if (typeof beat.unref === 'function') beat.unref();
    socket.on('close', () => clearInterval(beat));
  }

  return { attach };
}

module.exports = { createSignalHub };
