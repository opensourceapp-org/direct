import { text, utf8 } from '@direct/shared';
import { createIdentityMaterial, createPeerCipher, toPublicIdentity } from '@direct/crypto';
import { LocalTransport, MemoryMesh, MemoryWakuNode, WakuTransport } from '@direct/transport';
import { DeliveryEngine } from './delivery';
import { MemoryDeliveryStore } from './memoryStore';
import type { ContactPublic, LocalIdentity, MessageRouter } from './types';

function identity(name: string): { local: LocalIdentity; contact: ContactPublic } {
  const material = createIdentityMaterial();
  const pub = toPublicIdentity(material.keys, name, `dev_${name}`);
  return {
    local: { directId: pub.directId, deviceId: pub.deviceId, cipher: createPeerCipher(material.keys) },
    contact: { directId: pub.directId, signingPublic: pub.signingPublic, agreementPublic: pub.agreementPublic },
  };
}

test('direct delivery waits for a verified acknowledgement and keeps the message', async () => {
  const mesh = new MemoryMesh();
  const aliceWho = identity('Ava');
  const bobWho = identity('Bo');
  const aliceStore = new MemoryDeliveryStore();
  const bobStore = new MemoryDeliveryStore();
  const clock = { now: () => 1_700_000_000_000 };
  let sequence = 0;
  const ids = { next: (prefix: string) => `${prefix}_${sequence++}` };
  const aliceTransport = new LocalTransport(aliceWho.local.directId, mesh);
  const bobTransport = new LocalTransport(bobWho.local.directId, mesh);
  const aliceRouter: MessageRouter = {
    send: (peerId, payload) => aliceTransport.connect(peerId).then(async (ok) => {
      if (!ok) return { kind: 'queued' as const };
      await aliceTransport.send(peerId, payload);
      return { kind: 'direct' as const, transport: 'local' };
    }),
  };
  const bobRouter: MessageRouter = {
    send: (peerId, payload) => bobTransport.connect(peerId).then(async (ok) => {
      if (!ok) return { kind: 'queued' as const };
      await bobTransport.send(peerId, payload);
      return { kind: 'direct' as const, transport: 'local' };
    }),
  };
  const alice = new DeliveryEngine({
    store: aliceStore,
    router: aliceRouter,
    identity: () => aliceWho.local,
    contact: (id) => (id === bobWho.contact.directId ? bobWho.contact : null),
    clock,
    ids,
  });
  const bob = new DeliveryEngine({
    store: bobStore,
    router: bobRouter,
    identity: () => bobWho.local,
    contact: (id) => (id === aliceWho.contact.directId ? aliceWho.contact : null),
    clock,
    ids,
  });
  aliceTransport.subscribe((peer, payload) => {
    void alice.receive(payload, peer);
  });
  bobTransport.subscribe((peer, payload) => {
    void bob.receive(payload, peer);
  });

  const sent = await alice.sendText({ recipient: bobWho.contact, body: 'North gate, dusk.' });
  expect(sent.status).toBe('delivered');
  expect(aliceStore.getQueueByMessage(sent.id)).toBeNull();
  expect(aliceStore.getMessage(sent.id)?.body).toBe('North gate, dusk.');
  expect(aliceStore.hasAck(sent.id)).toBe(true);
  expect(aliceStore.acks[0]?.verified).toBe(true);
  const incoming = bobStore.messages.filter((message) => message.kind === 'user');
  expect(incoming).toHaveLength(1);
  expect(incoming[0]?.body).toBe('North gate, dusk.');

  const again = await bob.receive(incoming[0]!.ciphertext, aliceWho.local.directId);
  expect(again).toBe('duplicate');
  expect(bobStore.messages.filter((message) => message.kind === 'user')).toHaveLength(1);
});

test('an unavailable recipient stays pending and is not deleted', async () => {
  const aliceWho = identity('Ava');
  const bobWho = identity('Bo');
  const store = new MemoryDeliveryStore();
  const clock = { t: 1_000, now() { return this.t; } };
  const engine = new DeliveryEngine({
    store,
    router: { send: async () => ({ kind: 'queued' }) },
    identity: () => aliceWho.local,
    contact: () => bobWho.contact,
    clock,
    ids: { next: (prefix) => `${prefix}_${store.messages.length}_${store.queue.length}` },
    random: () => 0,
    ttlMs: 5_000,
  });
  const sent = await engine.sendText({ recipient: bobWho.contact, body: 'Still here.' });
  expect(sent.status).toBe('pending');
  expect(store.queue).toHaveLength(1);
  expect(store.queue[0]?.nextAttemptAt).toBe(2_000);
  clock.t = 10_000;
  await engine.flush();
  expect(store.getMessage(sent.id)?.status).toBe('expired');
  expect(store.getMessage(sent.id)?.body).toBe('Still here.');
  expect(store.queue).toHaveLength(0);
});

test('relay acceptance does not mark a message delivered', async () => {
  const aliceWho = identity('Ava');
  const bobWho = identity('Bo');
  const node = new MemoryWakuNode();
  const now = 5_000;
  const aliceRelay = new WakuTransport(aliceWho.local.directId, node, {
    enabled: true,
    storage: true,
    ttlMs: 60_000,
    now: () => now,
  });
  const bobRelay = new WakuTransport(bobWho.local.directId, node, {
    enabled: true,
    storage: true,
    ttlMs: 60_000,
    now: () => now,
  });
  const aliceStore = new MemoryDeliveryStore();
  const bobStore = new MemoryDeliveryStore();
  let n = 0;
  const ids = { next: (prefix: string) => `${prefix}_${n++}` };
  const alice = new DeliveryEngine({
    store: aliceStore,
    router: {
      send: async (peerId, payload) => {
        if (await aliceRelay.connect(peerId)) {
          await aliceRelay.send(peerId, payload);
          return { kind: 'relay', transport: 'waku' };
        }
        return { kind: 'queued' };
      },
    },
    identity: () => aliceWho.local,
    contact: () => bobWho.contact,
    clock: { now: () => now },
    ids,
  });
  const bob = new DeliveryEngine({
    store: bobStore,
    router: {
      send: async (peerId, payload) => {
        if (await bobRelay.connect(peerId)) {
          await bobRelay.send(peerId, payload);
          return { kind: 'relay', transport: 'waku' };
        }
        return { kind: 'queued' };
      },
    },
    identity: () => bobWho.local,
    contact: () => aliceWho.contact,
    clock: { now: () => now },
    ids,
  });
  aliceRelay.subscribe((peer, payload) => {
    void alice.receive(payload, peer);
  });
  const sent = await alice.sendText({ recipient: bobWho.contact, body: 'Ciphertext only.' });
  expect(sent.status).toBe('pending');
  expect(sent.transport).toBe('relay');
  expect(aliceStore.queue).toHaveLength(1);
  const topic = `direct/v1/${bobWho.contact.directId}`;
  expect(node.storedCount(topic)).toBe(1);
  const stored = node.storedPayloads(topic)[0];
  expect(stored && text(stored).includes('Ciphertext only.')).toBe(false);

  let incoming: Promise<unknown> = Promise.resolve();
  bobRelay.subscribe((peer, payload) => {
    incoming = bob.receive(payload, peer);
  });
  await incoming;
  expect(bobStore.messages.filter((message) => message.kind === 'user')[0]?.body).toBe('Ciphertext only.');
  expect(aliceStore.getMessage(sent.id)?.status).toBe('delivered');
  expect(utf8('Ciphertext only.').byteLength).toBeGreaterThan(0);
});

test('blocked contacts are not delivered', async () => {
  const aliceWho = identity('Ava');
  const bobWho = identity('Bo');
  const store = new MemoryDeliveryStore();
  store.blocked.add(bobWho.contact.directId);
  const engine = new DeliveryEngine({
    store,
    router: { send: async () => ({ kind: 'direct', transport: 'local' }) },
    identity: () => aliceWho.local,
    contact: () => bobWho.contact,
    clock: { now: () => 10 },
    ids: { next: (prefix) => `${prefix}_1` },
  });
  await expect(engine.sendText({ recipient: bobWho.contact, body: 'nope' })).rejects.toThrow(/blocked/);
});
