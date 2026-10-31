import { PresenceBoard } from './presenceBoard';

const alice = 'dir_0123456789ABCDEF';
const bob = 'dir_ABCDEFGHJKMNPQRS';
const bundleFor = (id: string) => JSON.stringify({ v: 1, directId: id, name: 'Member' });

test('two profiles on one board can see each other and exchange a sealed payload', () => {
  let now = 1_000;
  const board = new PresenceBoard(() => now);
  expect(board.hello(alice, bundleFor(alice))).toBe(true);
  expect(board.hello(bob, bundleFor(bob))).toBe(true);
  expect(board.deliver(alice, bob, 'AQIDBAUGBwg')).toBe(true);

  const bobView = board.pull(bob);
  expect(bobView.peers.map((peer) => peer.peerId)).toEqual([alice]);
  expect(bobView.mail).toEqual([{ from: alice, payload: 'AQIDBAUGBwg' }]);
  expect(board.pull(bob).mail).toEqual([]);
});

test('a stale hello and a foreign bundle are not published', () => {
  let now = 5_000;
  const board = new PresenceBoard(() => now);
  expect(board.hello(alice, '{"directId":"dir_someoneelse"}')).toBe(false);
  expect(board.hello('not-an-id', bundleFor(alice))).toBe(false);
  board.hello(alice, bundleFor(alice));
  now += 13_000;
  expect(board.pull(bob).peers).toEqual([]);
});
