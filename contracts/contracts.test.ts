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
  toPublicIdentity,
} from '@direct/crypto';
import { aadFor, decodeEnvelope, encodeEnvelope, nextDelayMs, normalizeBootstrapUrl } from '@direct/protocol';
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
) as { createSignalHub: (options?: { now?: () => number }) => { attach(socket: HubSocket): void } };

const here = (name: string) => path.join(__dirname, name);
const signaling = JSON.parse(readFileSync(here('signaling.json'), 'utf8'));
const urls = JSON.parse(readFileSync(here('bootstrap-url.json'), 'utf8')) as {
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
  const ada = 'dir_0123456789ABCDEF';
  const bo = 'dir_ABCDEFGHJKMNPQRS';
  const boHello = {
    kind: 'hello',
    from: bo,
    bundle: signaling.hubToClient.lookupPresent.bundle as string,
  };

  test('hello, lookup, and watch produce the documented hub frames', () => {
    const hub = createSignalHub();
    const a = socket();
    const b = socket();
    hub.attach(a);
    hub.attach(b);
    a.receive(signaling.clientToHub.hello);
    a.receive(signaling.clientToHub.watch);
    expect(a.sent.at(-1)).toEqual(signaling.hubToClient.presenceOffline);
    b.receive(boHello);
    expect(a.sent.at(-1)).toEqual(signaling.hubToClient.presenceOnline);
    a.receive(signaling.clientToHub.lookup);
    expect(a.sent.at(-1)).toEqual(signaling.hubToClient.lookupPresent);
    a.receive({ kind: 'lookup', requestId: 'req-2', directId: 'dir_0123456789ABCDEH' });
    expect(a.sent.at(-1)).toEqual(signaling.hubToClient.lookupAbsent);
    b.close();
    expect(a.sent.at(-1)).toEqual(signaling.hubToClient.presenceOffline);
  });

  test('offer, answer, and ice are forwarded unchanged between announced devices', () => {
    const hub = createSignalHub();
    const a = socket();
    const b = socket();
    hub.attach(a);
    hub.attach(b);
    a.receive(signaling.clientToHub.hello);
    b.receive(boHello);
    a.receive(signaling.clientToHub.offer);
    expect(b.sent.at(-1)).toEqual(signaling.clientToHub.offer);
    b.receive(signaling.clientToHub.answer);
    expect(a.sent.at(-1)).toEqual(signaling.clientToHub.answer);
    a.receive(signaling.clientToHub.ice);
    expect(b.sent.at(-1)).toEqual(signaling.clientToHub.ice);
  });

  test('an offer to a missing device is unreachable and a spoofed sender is dropped', () => {
    const hub = createSignalHub();
    const a = socket();
    const b = socket();
    hub.attach(a);
    hub.attach(b);
    a.receive(signaling.clientToHub.hello);
    a.receive({ ...signaling.clientToHub.offer, to: 'dir_0123456789ABCDEH' });
    expect(a.sent.at(-1)).toEqual(signaling.hubToClient.unreachable);
    b.receive(boHello);
    const before = a.sent.length;
    b.receive({ ...signaling.clientToHub.answer, from: 'dir_0123456789ABCDEH' });
    const spoofer = socket();
    hub.attach(spoofer);
    spoofer.receive({ ...signaling.clientToHub.offer, from: ada });
    expect(a.sent.length).toBe(before);
    expect(b.sent.some((frame) => frame.kind === 'offer')).toBe(false);
  });

  test('message text and envelopes are never forwarded', () => {
    const hub = createSignalHub();
    const a = socket();
    const b = socket();
    hub.attach(a);
    hub.attach(b);
    a.receive(signaling.clientToHub.hello);
    b.receive(boHello);
    for (const frame of signaling.forbidden) a.receive(frame);
    expect(b.sent).toEqual([]);
    expect(a.sent).toEqual([]);
  });

  test('a dropped device stays findable for the grace period only', () => {
    let now = 5_000_000;
    const hub = createSignalHub({ now: () => now });
    const a = socket();
    const b = socket();
    hub.attach(a);
    hub.attach(b);
    b.receive(boHello);
    b.close();
    a.receive(signaling.clientToHub.lookup);
    expect(a.sent.at(-1)).toMatchObject({ present: true });
    now += signaling.limits.presenceGraceMs;
    a.receive(signaling.clientToHub.lookup);
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
