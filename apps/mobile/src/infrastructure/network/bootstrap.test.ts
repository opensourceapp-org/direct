import { createServer } from 'node:http';
import path from 'node:path';
import { createRequire } from 'node:module';
import { WebSocketServer } from 'ws';
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

const ALICE = 'dir_0123456789ABCDEF';
const BOB = 'dir_ABCDEFGHJKMNPQRS';

function bundle(id: string): string {
  return JSON.stringify({ directId: id, name: 'Phone', note: 'public-only' });
}

function localSocket(): HubSocket & {
  sent: { kind?: string; present?: boolean; bundle?: string | null; to?: string }[];
  receive(raw: string): void;
  close(): void;
} {
  const listeners: { message: ((raw: unknown) => void)[]; close: (() => void)[] } = { message: [], close: [] };
  return {
    readyState: 1,
    sent: [],
    send(data: string) {
      this.sent.push(JSON.parse(data) as { kind?: string; present?: boolean; bundle?: string | null; to?: string });
    },
    on(event, listener) {
      listeners[event].push(listener as never);
    },
    receive(raw) {
      for (const listener of listeners.message) listener(raw);
    },
    close() {
      this.readyState = 3;
      for (const listener of listeners.close) listener();
    },
  };
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
    alice.announce(bundle(ALICE));
    bob.announce(bundle(BOB));
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
  bob.receive(JSON.stringify({ kind: 'hello', from: BOB, bundle: bundle(BOB) }));
  bob.close();
  alice.receive(JSON.stringify({ kind: 'lookup', requestId: 'r1', directId: BOB }));
  expect(alice.sent.at(-1)).toMatchObject({ present: true, bundle: bundle(BOB) });
  alice.receive(JSON.stringify({ kind: 'offer', to: BOB, from: ALICE }));
  expect(alice.sent.at(-1)).toMatchObject({ kind: 'unreachable', to: BOB });
  now += 120_001;
  alice.receive(JSON.stringify({ kind: 'lookup', requestId: 'r2', directId: BOB }));
  expect(alice.sent.at(-1)).toMatchObject({ present: false, bundle: null });
  alice.close();
});

test('an http presence hello is visible to a websocket lookup', () => {
  const seen: string[] = [];
  const hub = createSignalHub({ onHello: (id) => seen.push(id) });
  expect(hub.remember(BOB, bundle(BOB))).toBe(true);
  expect(hub.remember('dir_NOPE', bundle(BOB))).toBe(false);
  const alice = localSocket();
  hub.attach(alice);
  alice.receive(JSON.stringify({ kind: 'hello', from: ALICE, bundle: bundle(ALICE) }));
  expect(seen).toEqual([ALICE]);
  alice.receive(JSON.stringify({ kind: 'lookup', requestId: 'r1', directId: BOB }));
  expect(alice.sent.at(-1)?.present).toBe(true);
  expect(alice.sent.at(-1)?.bundle).toContain(BOB);
  expect(hub.remember(ALICE, bundle(ALICE))).toBe(true);
  const bob = localSocket();
  hub.attach(bob);
  bob.receive(JSON.stringify({ kind: 'offer', to: ALICE, from: BOB }));
  expect(alice.sent.some((message) => message.kind === 'offer')).toBe(true);
  bob.close();
  alice.close();
});
