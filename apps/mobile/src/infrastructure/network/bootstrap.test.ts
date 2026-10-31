import { createServer } from 'node:http';
import path from 'node:path';
import { createRequire } from 'node:module';
import { WebSocketServer } from 'ws';
import { DirectBootstrap } from './bootstrap';

const { createSignalHub } = createRequire(__filename)(
  path.resolve(__dirname, '../../../../../infrastructure/signaling/hub.cjs'),
) as {
  createSignalHub: () => {
    attach(socket: {
      readyState: number;
      send(data: string): void;
      on(event: 'message', listener: (raw: unknown) => void): void;
      on(event: 'close', listener: () => void): void;
    }): void;
  };
};

const ALICE = 'dir_0123456789ABCDEF';
const BOB = 'dir_ABCDEFGHJKMNPQRS';

function bundle(id: string): string {
  return JSON.stringify({ directId: id, name: 'Phone', note: 'public-only' });
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
