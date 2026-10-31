import { BrowserMesh, type MeshLoopback } from './browserMesh';
import { PresenceBoard } from './presenceBoard';

function sharedLoopback(): MeshLoopback {
  const board = new PresenceBoard();
  return {
    async hello(peerId, bundle) {
      return board.hello(peerId, bundle);
    },
    async deliver(from, to, payload) {
      return board.deliver(from, to, payload);
    },
    async pull(peerId) {
      return board.pull(peerId);
    },
  };
}

test('a private window and a normal window on the same address discover each other', async () => {
  const loopback = sharedLoopback();
  const seen: string[] = [];
  const alice = new BrowserMesh((bundle) => seen.push(bundle), loopback);
  const bob = new BrowserMesh(() => undefined, loopback);
  const bobId = 'dir_ABCDEFGHJKMNPQRS';
  const aliceId = 'dir_0123456789ABCDEF';
  const bundle = JSON.stringify({ v: 1, directId: bobId, name: 'Bob' });

  const stopBob = bob.register(bobId, () => undefined);
  const stopAlice = alice.register(aliceId, () => undefined);
  bob.publishBundle(bundle);
  await alice.sync();

  expect(seen).toContain(bundle);
  expect(alice.online(bobId)).toBe(true);
  stopAlice();
  stopBob();
});
