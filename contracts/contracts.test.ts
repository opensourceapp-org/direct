import { readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
import {
  createBundle,
  createPeerCipher,
  encodeBundle,
  keysFromSeed,
  mnemonicForSeed,
  open,
  parseBundle,
  seal,
  signBytes,
  toPublicIdentity,
} from '@direct/crypto';
import { aadFor, applyHostedDefault, decodeEnvelope, encodeEnvelope, HOSTED_BOOTSTRAP_URL, HOSTED_DEFAULT_VERSION, nextDelayMs, normalizeBootstrapUrl, signalProofMessage } from '@direct/protocol';
import type { Envelope } from '@direct/protocol';
import { base64UrlToBytes, bytesToBase64Url, text, utf8 } from '@direct/shared';

type HubSocket = {
  readyState: number;
  send(data: string): void;
  on(event: 'message', listener: (raw: unknown) => void): void;
  on(event: 'close', listener: () => void): void;
};

const { createSignalHub } = createRequire(__filename)(
  path.resolve(__dirname, '../infrastructure/signaling/hub.cjs'),
) as {
  createSignalHub: (options?: { now?: () => number }) => {
    attach(socket: HubSocket): void;
    roster(): { directId: string; name: string }[];
  };
};

const here = (name: string) => path.join(__dirname, name);
const signaling = JSON.parse(readFileSync(here('signaling.json'), 'utf8'));
const urls = JSON.parse(readFileSync(here('bootstrap-url.json'), 'utf8')) as {
  hostedDefault: string;
  cases: { input: string; url?: string; error?: string }[];
};

function socket(): HubSocket & { sent: Record<string, unknown>[]; receive(frame: unknown): void; close(): void } {
  const listeners = { message: [] as ((raw: unknown) => void)[], close: [] as (() => void)[] };
  return {
    readyState: 1,
    sent: [],
    send(data) {
      this.sent.push(JSON.parse(data) as Record<string, unknown>);
    },
    on(event: 'message' | 'close', listener: never) {
      listeners[event].push(listener);
    },
    receive(frame) {
      for (const listener of listeners.message) listener(JSON.stringify(frame));
    },
    close() {
      this.readyState = 3;
      for (const listener of listeners.close) listener();
    },
  };
}

describe('bootstrap address contract', () => {
  test.each(urls.cases)('$input', ({ input, url, error }) => {
    const result = normalizeBootstrapUrl(input);
    if (url) expect(result).toEqual({ ok: true, url });
    else expect(result).toEqual({ ok: false, error });
  });

  test('the hosted default is a public wss address both phones share', () => {
    expect(urls.hostedDefault).toBe(HOSTED_BOOTSTRAP_URL);
    expect(normalizeBootstrapUrl(HOSTED_BOOTSTRAP_URL)).toEqual({ ok: true, url: HOSTED_BOOTSTRAP_URL });
    expect(normalizeBootstrapUrl('https://direct-signaling.apps.grok.bot/')).toEqual({ ok: true, url: HOSTED_BOOTSTRAP_URL });
    expect(applyHostedDefault(null, 0)).toEqual({ url: HOSTED_BOOTSTRAP_URL, version: HOSTED_DEFAULT_VERSION });
    expect(applyHostedDefault('ws://192.168.1.121:8787', 0)).toEqual({ url: HOSTED_BOOTSTRAP_URL, version: HOSTED_DEFAULT_VERSION });
    expect(applyHostedDefault('192.168.1.121', 0)).toEqual({ url: HOSTED_BOOTSTRAP_URL, version: HOSTED_DEFAULT_VERSION });
    expect(applyHostedDefault('ws://192.168.1.121:8787', HOSTED_DEFAULT_VERSION)).toEqual({
      url: 'ws://192.168.1.121:8787',
      version: HOSTED_DEFAULT_VERSION,
    });
    expect(applyHostedDefault('wss://signals.example.com', 0)).toEqual({ url: 'wss://signals.example.com', version: HOSTED_DEFAULT_VERSION });
  });

  test('both phones typing the same computer in different ways get one address', () => {
    const forms = ['192.168.1.20', 'ws://192.168.1.20', 'http://192.168.1.20:8787/', ' WS://192.168.1.20:8787 '];
    const normalized = new Set(forms.map((form) => {
      const result = normalizeBootstrapUrl(form);
      return result.ok ? result.url : result.error;
    }));
    expect([...normalized]).toEqual(['ws://192.168.1.20:8787']);
  });
});

describe('signaling contract', () => {
  const identityVectors = JSON.parse(readFileSync(here('vectors.json'), 'utf8')) as {
    ada: { seedHex: string; bundle: string; directId: string; name: string };
    bo: { seedHex: string; bundle: string; directId: string; name: string };
  };
  const ada = identityVectors.ada.directId;
  const bo = identityVectors.bo.directId;
  const missing = 'dir_0123456789ABCDEH';

  function seedFromHex(value: string): Uint8Array {
    return Uint8Array.from({ length: value.length / 2 }, (_, i) => Number.parseInt(value.slice(i * 2, i * 2 + 2), 16));
  }

  function signedHello(who: 'ada' | 'bo', nonce: string) {
    const keys = keysFromSeed(seedFromHex(identityVectors[who].seedHex));
    const directId = identityVectors[who].directId;
    return {
      kind: 'hello',
      from: directId,
      bundle: identityVectors[who].bundle,
      nonce,
      proof: bytesToBase64Url(signBytes(keys.signingSecret, signalProofMessage(nonce, directId))),
    };
  }

  function challengeNonce(sock: { sent: Record<string, unknown>[] }): string {
    const challenge = sock.sent.find((frame) => frame.kind === 'challenge');
    expect(typeof challenge?.nonce).toBe('string');
    return String(challenge?.nonce);
  }

  function announce(sock: ReturnType<typeof socket>, who: 'ada' | 'bo') {
    sock.receive(signedHello(who, challengeNonce(sock)));
  }

  test('hello, lookup, and watch produce the documented hub frames', () => {
    const hub = createSignalHub();
    const a = socket();
    const b = socket();
    hub.attach(a);
    hub.attach(b);
    announce(a, 'ada');
    a.receive({ kind: 'watch', ids: [bo] });
    expect(a.sent.at(-1)).toEqual({ kind: 'presence', directId: bo, online: false });
    announce(b, 'bo');
    expect(a.sent.at(-1)).toEqual({ kind: 'presence', directId: bo, online: true });
    a.receive({ kind: 'lookup', requestId: 'req-1', directId: bo });
    expect(a.sent.at(-1)).toEqual({
      kind: 'lookup',
      requestId: 'req-1',
      directId: bo,
      present: true,
      bundle: identityVectors.bo.bundle,
    });
    a.receive({ kind: 'lookup', requestId: 'req-2', directId: missing });
    expect(a.sent.at(-1)).toEqual({ kind: 'lookup', requestId: 'req-2', directId: missing, present: false, bundle: null });
    b.close();
    expect(a.sent.at(-1)).toEqual({ kind: 'presence', directId: bo, online: false });
  });

  test('offer, answer, and ice are forwarded unchanged between announced devices', () => {
    const hub = createSignalHub();
    const a = socket();
    const b = socket();
    hub.attach(a);
    hub.attach(b);
    announce(a, 'ada');
    announce(b, 'bo');
    const offer = { ...signaling.clientToHub.offer, from: ada, to: bo };
    const answer = { ...signaling.clientToHub.answer, from: bo, to: ada };
    const ice = { ...signaling.clientToHub.ice, from: ada, to: bo };
    a.receive(offer);
    expect(b.sent.at(-1)).toEqual(offer);
    b.receive(answer);
    expect(a.sent.at(-1)).toEqual(answer);
    a.receive(ice);
    expect(b.sent.at(-1)).toEqual(ice);
  });

  test('an offer to a missing device is unreachable and a spoofed sender is dropped', () => {
    const hub = createSignalHub();
    const a = socket();
    const b = socket();
    hub.attach(a);
    hub.attach(b);
    announce(a, 'ada');
    a.receive({ ...signaling.clientToHub.offer, from: ada, to: missing });
    expect(a.sent.at(-1)).toEqual({ kind: 'unreachable', to: missing });
    announce(b, 'bo');
    const before = a.sent.length;
    b.receive({ ...signaling.clientToHub.answer, from: missing, to: ada });
    const spoofer = socket();
    hub.attach(spoofer);
    spoofer.receive({ ...signaling.clientToHub.offer, from: ada, to: bo });
    expect(a.sent.length).toBe(before);
    expect(b.sent.some((frame) => frame.kind === 'offer')).toBe(false);
  });

  test('a socket that floods frames is closed', () => {
    const hub = createSignalHub({ maxMessagesPerSec: 3 });
    const a = socket();
    hub.attach(a);
    announce(a, 'ada');
    for (let i = 0; i < 8; i += 1) a.receive({ kind: 'lookup', requestId: `r${i}`, directId: bo });
    expect(a.readyState).toBe(3);
  });

  test('a public bundle without a matching proof cannot claim a DIRECT ID', () => {
    const hub = createSignalHub();
    const thief = socket();
    hub.attach(thief);
    const nonce = challengeNonce(thief);
    thief.receive(signaling.clientToHub.hello);
    thief.receive({ kind: 'hello', from: ada, bundle: identityVectors.ada.bundle, nonce, proof: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' });
    expect(hub.roster()).toEqual([]);
    announce(thief, 'ada');
    expect(hub.roster()).toEqual([{ directId: ada, name: identityVectors.ada.name }]);
  });

  test('message text and envelopes are never forwarded', () => {
    const hub = createSignalHub();
    const a = socket();
    const b = socket();
    hub.attach(a);
    hub.attach(b);
    announce(a, 'ada');
    announce(b, 'bo');
    const beforeA = a.sent.length;
    const beforeB = b.sent.length;
    for (const frame of signaling.forbidden) a.receive(frame);
    expect(b.sent.length).toBe(beforeB);
    expect(a.sent.length).toBe(beforeA);
  });

  test('the connected list is available on this computer', async () => {
    const { createSignalingServer } = createRequire(__filename)(
      path.resolve(__dirname, '../infrastructure/signaling/createServer.cjs'),
    ) as {
      createSignalingServer: () => {
        listen(port: number, host: string): Promise<{ port: number }>;
        close(): Promise<void>;
      };
    };
    const WebSocket = createRequire(__filename)('ws') as new (url: string, options?: { origin?: string }) => {
      once(event: 'open' | 'message' | 'error' | 'unexpected-response', listener: (...args: never[]) => void): void;
      send(data: string): void;
      close(): void;
    };
    const server = createSignalingServer();
    const info = await server.listen(0, '127.0.0.1');
    const health = await fetch(`http://127.0.0.1:${info.port}/health`);
    expect(health.headers.get('content-type')).toMatch(/application\/json/);
    expect(await health.json()).toEqual({ ok: true, service: 'direct-signaling', contract: 1 });
    const home = await fetch(`http://127.0.0.1:${info.port}/`);
    expect(home.headers.get('content-type')).toMatch(/text\/html/);
    expect(await home.text()).toContain('Signaling is running.');
    const blocked = new WebSocket(`ws://127.0.0.1:${info.port}`, { origin: 'https://evil.example' });
    const blockedCode = await new Promise<number>((resolve, reject) => {
      blocked.once('unexpected-response', (_request, response: { statusCode: number }) => resolve(response.statusCode));
      blocked.once('open', () => reject(new Error('evil origin was accepted')));
      blocked.once('error', () => {});
    });
    expect(blockedCode).toBe(403);
    blocked.close();
    const phone = new WebSocket(`ws://127.0.0.1:${info.port}`);
    try {
      const nonce = await new Promise<string>((resolve, reject) => {
        phone.once('error', (openError) => reject(openError));
        phone.once('message', (raw) => {
          const frame = JSON.parse(String(raw)) as { kind?: string; nonce?: string };
          if (frame.kind === 'challenge' && frame.nonce) resolve(frame.nonce);
          else reject(new Error('expected challenge'));
        });
      });
      phone.send(JSON.stringify(signedHello('ada', nonce)));
      let users: { directId: string; name: string }[] = [];
      for (let attempt = 0; attempt < 20 && users.length === 0; attempt += 1) {
        const response = await fetch(`http://127.0.0.1:${info.port}/roster`);
        expect(response.status).toBe(200);
        users = (await response.json()).users;
        if (users.length === 0) await new Promise((resolve) => setTimeout(resolve, 25));
      }
      expect(users).toEqual([{ directId: ada, name: identityVectors.ada.name }]);
    } finally {
      phone.close();
      await server.close();
    }
  });

  test('admission uses the socket address unless the peer is a local proxy', () => {
    const { clientIp } = createRequire(__filename)(
      path.resolve(__dirname, '../infrastructure/signaling/createServer.cjs'),
    ) as {
      clientIp: (request: {
        headers: Record<string, string | undefined>;
        socket: { remoteAddress?: string };
      }) => string;
    };
    const req = (peer: string, forwarded?: string) => ({
      headers: forwarded === undefined ? {} : { 'x-forwarded-for': forwarded },
      socket: { remoteAddress: peer },
    });
    expect(clientIp(req('203.0.113.10', '198.51.100.1'))).toBe('203.0.113.10');
    expect(clientIp(req('::ffff:203.0.113.10', '198.51.100.1'))).toBe('203.0.113.10');
    expect(clientIp(req('2001:db8::10', '198.51.100.1'))).toBe('2001:db8::10');
    expect(clientIp(req('127.0.0.1', '198.51.100.1'))).toBe('198.51.100.1');
    expect(clientIp(req('127.0.0.1', '10.0.0.1, 198.51.100.1'))).toBe('198.51.100.1');
    expect(clientIp(req('127.0.0.1', '1.1.1.1, 2.2.2.2, 198.51.100.1'))).toBe('198.51.100.1');
    expect(clientIp(req('::1', '198.51.100.1, 127.0.0.1'))).toBe('198.51.100.1');
    expect(clientIp(req('::ffff:127.0.0.1', '198.51.100.1'))).toBe('198.51.100.1');
    expect(clientIp(req('127.0.0.1'))).toBe('127.0.0.1');
    expect(clientIp(req('127.0.0.1', 'not-an-ip'))).toBe('127.0.0.1');
    expect(clientIp(req('127.0.0.1', 'evil.example'))).toBe('127.0.0.1');
  });

  test('a flood of sockets from one address is refused even with spoofed forwarded-for', async () => {
    const { createSignalingServer, MAX_CONNECTS_PER_WINDOW, lanUrls } = createRequire(__filename)(
      path.resolve(__dirname, '../infrastructure/signaling/createServer.cjs'),
    ) as {
      createSignalingServer: () => {
        listen(port: number, host: string): Promise<{ port: number }>;
        close(): Promise<void>;
      };
      MAX_CONNECTS_PER_WINDOW: number;
      lanUrls: (port: number) => string[];
    };
    const WebSocket = createRequire(__filename)('ws') as new (
      url: string,
      options?: { headers?: Record<string, string> },
    ) => {
      once(event: 'open' | 'error' | 'unexpected-response', listener: (...args: never[]) => void): void;
      close(): void;
    };
    const server = createSignalingServer();
    const info = await server.listen(0, '0.0.0.0');
    const lan = lanUrls(info.port)[0];
    const url = lan ?? `ws://127.0.0.1:${info.port}`;
    const sockets: InstanceType<typeof WebSocket>[] = [];
    try {
      let refused = 0;
      for (let i = 0; i <= MAX_CONNECTS_PER_WINDOW; i += 1) {
        const phone = new WebSocket(url, lan ? { headers: { 'X-Forwarded-For': `198.51.100.${i + 1}` } } : undefined);
        sockets.push(phone);
        const outcome = await new Promise<'open' | number>((resolve) => {
          phone.once('unexpected-response', (_request, response: { statusCode: number }) => resolve(response.statusCode));
          phone.once('open', () => resolve('open'));
          phone.once('error', () => {});
        });
        if (outcome === 'open') continue;
        expect(outcome).toBe(429);
        refused += 1;
      }
      expect(refused).toBeGreaterThan(0);
    } finally {
      for (const socket of sockets) socket.close();
      await server.close();
    }
  });

  test('the operator roster lists a phone only while its socket is open', () => {
    const hub = createSignalHub();
    const phone = socket();
    hub.attach(phone);
    announce(phone, 'ada');
    expect(hub.roster()).toEqual([{ directId: ada, name: identityVectors.ada.name }]);
    phone.close();
    expect(hub.roster()).toEqual([]);
  });

  test('a dropped device stays findable for the grace period only', () => {
    let now = 5_000_000;
    const hub = createSignalHub({ now: () => now });
    const a = socket();
    const b = socket();
    hub.attach(a);
    hub.attach(b);
    announce(b, 'bo');
    b.close();
    a.receive({ kind: 'lookup', requestId: 'req-1', directId: bo });
    expect(a.sent.at(-1)).toMatchObject({ present: true });
    now += signaling.limits.presenceGraceMs;
    a.receive({ kind: 'lookup', requestId: 'req-1', directId: bo });
    expect(a.sent.at(-1)).toMatchObject({ present: false, bundle: null });
  });
});

const VECTORS = here('vectors.json');
const ADA_SEED = Uint8Array.from({ length: 32 }, (_, i) => i);
const BO_SEED = Uint8Array.from({ length: 32 }, (_, i) => 0x20 + i);
const CREATED_AT = 1_790_000_000_000;
const TTL = 7 * 24 * 60 * 60 * 1000;

function hex(bytes: Uint8Array): string {
  return [...bytes].map((byte) => byte.toString(16).padStart(2, '0')).join('');
}

function person(seed: Uint8Array, name: string, device: string) {
  const keys = keysFromSeed(seed);
  const identity = toPublicIdentity(keys, name, device);
  return {
    keys,
    vector: {
      seedHex: hex(seed),
      name,
      deviceId: device,
      mnemonic: mnemonicForSeed(seed),
      signingPublic: bytesToBase64Url(keys.signingPublic),
      agreementSecret: bytesToBase64Url(keys.agreementSecret),
      agreementPublic: bytesToBase64Url(keys.agreementPublic),
      directId: identity.directId,
      did: identity.did,
      fingerprint: identity.fingerprint,
      bundle: encodeBundle(createBundle(identity)),
    },
  };
}

function envelope(
  from: ReturnType<typeof person>,
  to: ReturnType<typeof person>,
  id: string,
  type: Envelope['type'],
  plaintext: string,
): string {
  const draft: Omit<Envelope, 'signature'> = {
    v: 1,
    id,
    type,
    from: from.vector.directId,
    to: to.vector.directId,
    deviceId: from.vector.deviceId,
    createdAt: CREATED_AT,
    expiresAt: CREATED_AT + TTL,
    ciphertext: '',
  };
  const cipher = createPeerCipher(from.keys);
  draft.ciphertext = bytesToBase64Url(cipher.sealTo(to.keys.agreementPublic, utf8(plaintext), aadFor(draft)));
  return text(encodeEnvelope(draft, cipher));
}

function generate() {
  const ada = person(ADA_SEED, 'Ada', 'dev_0000000000000ADA');
  const bo = person(BO_SEED, 'Bo', 'dev_00000000000000B0');
  const quoted = person(ADA_SEED, 'Zoë "Z" \\ ✓', 'dev_0000000000000ADA');
  const aad = 'vector-aad';
  return {
    note: 'Generated from the TypeScript reference with WRITE_VECTORS=1. Kotlin and Swift must reproduce every deterministic field and open every sealed value.',
    ada: ada.vector,
    bo: bo.vector,
    escapedName: { name: quoted.vector.name, bundle: quoted.vector.bundle },
    seal: {
      to: 'bo',
      aad,
      plaintext: 'Hello from Ada',
      sealed: bytesToBase64Url(seal({ recipientAgreementPublic: bo.keys.agreementPublic, plaintext: utf8('Hello from Ada'), aad: utf8(aad) })),
    },
    envelopes: {
      now: CREATED_AT + 1000,
      message: { body: 'Hello from Ada', json: envelope(ada, bo, 'msg_vector', 'message', 'Hello from Ada') },
      ack: { receipt: 'ack:msg_vector', json: envelope(bo, ada, 'ack_vector', 'ack', 'ack:msg_vector') },
      read: { receipt: 'read:msg_vector', json: envelope(bo, ada, 'read_vector', 'read', 'read:msg_vector') },
    },
    backoff: [1, 2, 3, 4, 5, 8, 9, 12].map((attempt) => ({
      attempt,
      min: nextDelayMs(attempt, () => 0),
      max: nextDelayMs(attempt, () => 1),
    })),
  };
}

describe('crypto vectors shared with Kotlin and Swift', () => {
  if (process.env.WRITE_VECTORS === '1') {
    writeFileSync(VECTORS, `${JSON.stringify(generate(), null, 2)}\n`);
  }
  const vectors = JSON.parse(readFileSync(VECTORS, 'utf8'));
  const fresh = generate();

  test('identity and bundle fields are deterministic', () => {
    expect(fresh.ada).toEqual(vectors.ada);
    expect(fresh.bo).toEqual(vectors.bo);
    expect(fresh.escapedName).toEqual(vectors.escapedName);
    expect(parseBundle(vectors.ada.bundle).directId).toBe(vectors.ada.directId);
    expect(parseBundle(vectors.escapedName.bundle).name).toBe(vectors.escapedName.name);
  });

  test('the recorded seal and envelopes open with the recipient key', () => {
    const bo = keysFromSeed(BO_SEED);
    const ada = keysFromSeed(ADA_SEED);
    const opened = open({ recipientAgreementSecret: bo.agreementSecret, payload: base64UrlToBytes(vectors.seal.sealed), aad: utf8(vectors.seal.aad) });
    expect(text(opened)).toBe(vectors.seal.plaintext);
    const cipherBo = createPeerCipher(bo);
    const message = decodeEnvelope(utf8(vectors.envelopes.message.json), cipherBo.verify, ada.signingPublic, vectors.envelopes.now);
    expect(text(cipherBo.open(base64UrlToBytes(message.ciphertext), aadFor(message)))).toBe(vectors.envelopes.message.body);
    const cipherAda = createPeerCipher(ada);
    for (const kind of ['ack', 'read'] as const) {
      const receipt = decodeEnvelope(utf8(vectors.envelopes[kind].json), cipherAda.verify, bo.signingPublic, vectors.envelopes.now);
      expect(text(cipherAda.open(base64UrlToBytes(receipt.ciphertext), aadFor(receipt)))).toBe(vectors.envelopes[kind].receipt);
    }
  });

  test('backoff bounds match', () => {
    expect(fresh.backoff).toEqual(vectors.backoff);
  });
});
