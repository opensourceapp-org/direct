import { createServer } from 'node:http';
import path from 'node:path';
import { createRequire } from 'node:module';
import { WebSocketServer } from 'ws';
import { createBundle, directIdFromSigningPublic, encodeBundle, keysFromSeed, signBytes, toPublicIdentity } from '@direct/crypto';
import { signalProofMessage } from '@direct/protocol';
import { bytesToBase64Url } from '@direct/shared';
import { DirectBootstrap } from './bootstrap';

type HubSocket = {
  readyState: number;
  send(data: string): void;
  ping?: () => void;
  on(event: 'message', listener: (raw: unknown) => void): void;
  on(event: 'close', listener: () => void): void;
};

const { createSignalHub } = createRequire(__filename)(
  path.resolve(__dirname, '../../../../../infrastructure/signaling/hub.cjs'),
) as {
  createSignalHub: (options?: { now?: () => number; onHello?: (id: string, bundle: string) => void }) => {
    attach(socket: HubSocket): void;
    remember(id: string, bundle: string): boolean;
  };
};

const ADA_SEED = Uint8Array.from({ length: 32 }, (_, i) => i);
const BO_SEED = Uint8Array.from({ length: 32 }, (_, i) => 0x20 + i);
const aliceKeys = keysFromSeed(ADA_SEED);
const bobKeys = keysFromSeed(BO_SEED);
const ALICE = directIdFromSigningPublic(aliceKeys.signingPublic);
const BOB = directIdFromSigningPublic(bobKeys.signingPublic);

function bundleFor(keys: ReturnType<typeof keysFromSeed>, name: string): string {
  return encodeBundle(createBundle(toPublicIdentity(keys, name, 'dev_test')));
}

function signFor(keys: ReturnType<typeof keysFromSeed>): (nonce: string) => string {
  const directId = directIdFromSigningPublic(keys.signingPublic);
  return (nonce) => bytesToBase64Url(signBytes(keys.signingSecret, signalProofMessage(nonce, directId)));
}

function signedHello(keys: ReturnType<typeof keysFromSeed>, name: string, nonce: string) {
  const directId = directIdFromSigningPublic(keys.signingPublic);
  return {
    kind: 'hello',
    from: directId,
    bundle: bundleFor(keys, name),
    nonce,
    proof: signFor(keys)(nonce),
  };
}

function localSocket(): HubSocket & {
  sent: { kind?: string; present?: boolean; bundle?: string | null; to?: string; nonce?: string }[];
  receive(raw: string | object): void;
  close(): void;
} {
  const listeners: { message: ((raw: unknown) => void)[]; close: (() => void)[] } = { message: [], close: [] };
  return {
    readyState: 1,
    sent: [],
    send(data) {
      this.sent.push(JSON.parse(data) as { kind?: string; present?: boolean; bundle?: string | null; to?: string; nonce?: string });
    },
    on(event, listener) {
      listeners[event].push(listener as never);
    },
    receive(raw) {
      const text = typeof raw === 'string' ? raw : JSON.stringify(raw);
      for (const listener of listeners.message) listener(text);
    },
    close() {
      this.readyState = 3;
      for (const listener of listeners.close) listener();
    },
  };
}

function announce(sock: ReturnType<typeof localSocket>, keys: ReturnType<typeof keysFromSeed>, name: string) {
  const nonce = sock.sent.find((frame) => frame.kind === 'challenge')?.nonce;
  if (!nonce) throw new Error('missing challenge');
  sock.receive(signedHello(keys, name, nonce));
}

function waitFor(ready: () => boolean): Promise<void> {
  const started = Date.now();
  return new Promise((resolve, reject) => {
    const timer = setInterval(() => {
      if (ready()) {
        clearInterval(timer);
        resolve();
      } else if (Date.now() - started > 4_000) {
        clearInterval(timer);
        reject(new Error('timed out'));
      }
    }, 20);
  });
}

test('two phones on one bootstrap find each other by DIRECT ID', async () => {
  const hub = createSignalHub();
  const server = createServer();
  const sockets = new WebSocketServer({ server });
  sockets.on('connection', (socket) => hub.attach(socket));
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', () => resolve()));
  const address = server.address();
  const port = typeof address === 'object' && address ? address.port : 0;
  const url = `ws://127.0.0.1:${port}`;
  const alice = new DirectBootstrap(() => url);
  const bob = new DirectBootstrap(() => url);
  alice.start(ALICE);
  bob.start(BOB);
  try {
    await waitFor(() => alice.state === 'open' && bob.state === 'open');
    alice.announce(bundleFor(aliceKeys, 'Ada'), signFor(aliceKeys));
    bob.announce(bundleFor(bobKeys, 'Bo'), signFor(bobKeys));
    let found: string | null = null;
    const started = Date.now();
    while (!found && Date.now() - started < 3_000) {
      found = await alice.lookup(BOB);
      if (!found) await new Promise((resolve) => setTimeout(resolve, 30));
    }
    expect(found).toContain(BOB);
    expect(await alice.lookup('dir_0123456789ABCDEH')).toBeNull();
    await expect(alice.send({
      to: 'dir_0123456789ABCDEH',
      from: ALICE,
      kind: 'offer',
      description: { type: 'offer', sdp: 'v=0' },
    })).rejects.toThrow(/not on this bootstrap/);
    const forwarded: string[] = [];
    bob.onMessage((message) => forwarded.push(message.kind));
    const delivery = alice.send({
      to: BOB,
      from: ALICE,
      kind: 'offer',
      description: { type: 'offer', sdp: 'v=0' },
    });
    await waitFor(() => forwarded.includes('offer'));
    await delivery;
  } finally {
    alice.stop();
    bob.stop();
    sockets.close();
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }
});

test('a bundle stays findable for two minutes after the phone drops, then expires', () => {
  let now = 1_000_000;
  const hub = createSignalHub({ now: () => now });
  const bob = localSocket();
  const alice = localSocket();
  hub.attach(bob);
  hub.attach(alice);
  announce(bob, bobKeys, 'Bo');
  bob.close();
  alice.receive({ kind: 'lookup', requestId: 'r1', directId: BOB });
  expect(alice.sent.at(-1)).toMatchObject({ present: true, bundle: bundleFor(bobKeys, 'Bo') });
  announce(alice, aliceKeys, 'Ada');
  alice.receive({ kind: 'offer', to: BOB, from: ALICE });
  expect(alice.sent.at(-1)).toMatchObject({ kind: 'unreachable', to: BOB });
  now += 120_001;
  alice.receive({ kind: 'lookup', requestId: 'r2', directId: BOB });
  expect(alice.sent.at(-1)).toMatchObject({ present: false, bundle: null });
  alice.close();
});

test('an http presence hello is visible to a websocket lookup', () => {
  const seen: string[] = [];
  const hub = createSignalHub({ onHello: (id) => seen.push(id) });
  const bobBundle = JSON.stringify({ directId: BOB, name: 'Bo', note: 'public-only' });
  expect(hub.remember(BOB, bobBundle)).toBe(true);
  expect(hub.remember('dir_NOPE', bobBundle)).toBe(false);
  const alice = localSocket();
  hub.attach(alice);
  announce(alice, aliceKeys, 'Ada');
  expect(seen).toEqual([ALICE]);
  alice.receive({ kind: 'lookup', requestId: 'r1', directId: BOB });
  expect(alice.sent.at(-1)?.present).toBe(true);
  expect(alice.sent.at(-1)?.bundle).toContain(BOB);
  expect(hub.remember(ALICE, bundleFor(aliceKeys, 'Ada'))).toBe(true);
  const bob = localSocket();
  hub.attach(bob);
  announce(bob, bobKeys, 'Bo');
  bob.receive({ kind: 'offer', to: ALICE, from: BOB });
  expect(alice.sent.some((message) => message.kind === 'offer')).toBe(true);
  bob.close();
  alice.close();
});
