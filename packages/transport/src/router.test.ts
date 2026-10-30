import { KademliaTable } from './kademlia';
import { InProcessLibp2p } from './libp2p';
import { LocalTransport, MemoryMesh } from './local';
import { TransportRouter } from './router';
import type { IncomingHandler, TransportAdapter } from './types';
import { SignalingBus, WebRTCTransport, assertSignalMessage, virtualPeerConnectionFactory } from './webrtc';
import { randomBytes } from '@direct/shared';

class FakeTransport implements TransportAdapter {
  readonly sent: Uint8Array[] = [];
  connected = false;
  connectable = false;
  constructor(readonly name: string) {}
  async connect(): Promise<boolean> {
    if (!this.connectable) return false;
    this.connected = true;
    return true;
  }
  async send(_peerId: string, payload: Uint8Array): Promise<void> {
    if (!this.connected) throw new Error('not connected');
    this.sent.push(payload);
  }
  async disconnect(): Promise<void> {
    this.connected = false;
  }
  isConnected(): boolean {
    return this.connected;
  }
  subscribe(): () => void {
    return () => undefined;
  }
}

test('router prefers an existing direct connection over relay', async () => {
  const webrtc = new FakeTransport('webrtc');
  webrtc.connected = true;
  const relay = new FakeTransport('waku');
  relay.connectable = true;
  const router = new TransportRouter({ direct: [webrtc], relay, relayEnabled: true });
  const result = await router.send('bob', new Uint8Array([1]));
  expect(result).toEqual({ kind: 'direct', transport: 'webrtc' });
  expect(relay.sent).toHaveLength(0);
});

test('router opens a new direct connection before using relay', async () => {
  const webrtc = new FakeTransport('webrtc');
  webrtc.connectable = true;
  const relay = new FakeTransport('waku');
  relay.connectable = true;
  const router = new TransportRouter({ direct: [webrtc], relay, relayEnabled: true });
  const result = await router.send('bob', new Uint8Array([1]));
  expect(result.kind).toBe('direct');
  expect(relay.sent).toHaveLength(0);
});

test('router uses relay only after direct transports fail, then queues', async () => {
  const webrtc = new FakeTransport('webrtc');
  const relay = new FakeTransport('waku');
  relay.connectable = true;
  const router = new TransportRouter({ direct: [webrtc], relay, relayEnabled: true });
  expect((await router.send('bob', new Uint8Array([1]))).kind).toBe('relay');
  relay.connectable = false;
  relay.connected = false;
  expect(await router.send('bob', new Uint8Array([1]))).toEqual({ kind: 'queued' });
});

test('local mesh delivers between two online peers', async () => {
  const mesh = new MemoryMesh();
  const alice = new LocalTransport('alice', mesh);
  const bob = new LocalTransport('bob', mesh);
  const received: string[] = [];
  bob.subscribe((_peer, payload) => received.push(new TextDecoder().decode(payload)));
  expect(await alice.connect('bob')).toBe(true);
  await alice.send('bob', new TextEncoder().encode('hello'));
  expect(received).toEqual(['hello']);
  await bob.disconnect('alice');
  expect(await alice.connect('bob')).toBe(false);
});

test('kademlia ranks peers by xor distance', () => {
  const local = new Uint8Array(32);
  local[31] = 0;
  const table = new KademliaTable(local, 20);
  table.add({ id: local, peerId: 'self', addrs: [], lastSeen: 1 });
  const near = new Uint8Array(32);
  near[31] = 1;
  const far = new Uint8Array(32);
  far[0] = 128;
  table.add({ id: far, peerId: 'far', addrs: ['/ip4/1'], lastSeen: 1 });
  table.add({ id: near, peerId: 'near', addrs: ['/ip4/2'], lastSeen: 2 });
  expect(table.size).toBe(2);
  expect(table.closest(local, 2).map((peer) => peer.peerId)).toEqual(['near', 'far']);
});

test('libp2p dials a peer announced in the local kademlia table', async () => {
  const swarm = new InProcessLibp2p();
  const aliceTable = new KademliaTable(randomBytes(32));
  const bobTable = new KademliaTable(randomBytes(32));
  const alice = swarm.register(aliceTable, 'alice');
  const bob = swarm.register(bobTable, 'bob');
  swarm.announce(aliceTable, 'bob', ['/ip4/bob'], 1);
  const got: Uint8Array[] = [];
  bob.subscribe((_peer, payload) => got.push(payload));
  expect(await alice.connect('missing')).toBe(false);
  expect(await alice.connect('bob')).toBe(true);
  await alice.send('bob', new Uint8Array([9]));
  expect([...got[0]!]).toEqual([9]);
});

test('webrtc data channel delivers across a signaling bus', async () => {
  const bus = new SignalingBus();
  const alice = new WebRTCTransport('alice', bus.client('alice'), virtualPeerConnectionFactory);
  const bob = new WebRTCTransport('bob', bus.client('bob'), virtualPeerConnectionFactory);
  const got: number[] = [];
  bob.subscribe((_peer, payload) => got.push(payload[0] ?? 0));
  alice.subscribe(() => undefined);
  expect(await alice.connect('bob')).toBe(true);
  await alice.send('bob', new Uint8Array([7]));
  expect(got).toEqual([7]);
  expect(() => assertSignalMessage({ to: 'a', from: 'b', kind: 'message' } as never)).toThrow(/non-session/);
});

test('handlers satisfy the transport subscription type', () => {
  const handler: IncomingHandler = () => undefined;
  expect(typeof handler).toBe('function');
});
