import { createRequire } from 'module';
import { readFileSync } from 'fs';
import { createIdentityMaterial, createPeerCipher, MemoryKeyVault, toPublicIdentity } from '@direct/crypto';
import { bytesToBase64Url, utf8 } from '@direct/shared';
import { DeliveryEngine } from '@direct/protocol';
import { LocalTransport, MemoryMesh } from '@direct/transport';
import { MemoryBlobStore, openEncryptedDatabase } from './database';
import { DirectRepository } from './repositories';

function wasmBytes(): Uint8Array {
  const nodeRequire = createRequire(__filename);
  return new Uint8Array(readFileSync(nodeRequire.resolve('sql.js/dist/sql-wasm.wasm')));
}

function contains(bytes: Uint8Array, needle: string): boolean {
  const encoded = utf8(needle);
  outer: for (let index = 0; index <= bytes.length - encoded.length; index += 1) {
    for (let offset = 0; offset < encoded.length; offset += 1) {
      if (bytes[index + offset] !== encoded[offset]) continue outer;
    }
    return true;
  }
  return false;
}

async function freshRepo() {
  const vault = new MemoryKeyVault();
  const blobs = new MemoryBlobStore();
  const db = await openEncryptedDatabase({ wasmBinary: wasmBytes(), vault, blobs, now: 10 });
  return { vault, blobs, repo: new DirectRepository(db) };
}

test('an unknown sender is kept as a message request until accepted', async () => {
  const { repo } = await freshRepo();
  const peer = toPublicIdentity(createIdentityMaterial().keys, 'Bo', 'dev_bo');
  repo.upsertContact({
    id: 'contact_bo',
    directId: peer.directId,
    did: peer.did,
    displayName: 'Bo',
    agreementPublic: bytesToBase64Url(peer.agreementPublic),
    signingPublic: bytesToBase64Url(peer.signingPublic),
    agreementSignature: bytesToBase64Url(peer.agreementSignature),
    fingerprint: peer.fingerprint,
    deviceId: peer.deviceId,
    verified: false,
    blocked: false,
    accepted: false,
    createdAt: 11,
  });
  const conversationId = repo.ensureConversation(peer.directId, 'hello', 12, true);
  expect(repo.listConversations()[0]).toMatchObject({ id: conversationId, accepted: false, preview: 'hello' });
  repo.setContactAccepted(peer.directId, true);
  expect(repo.getContact(peer.directId)?.accepted).toBe(true);
  expect(repo.listConversations()[0]?.accepted).toBe(true);
});

test('sqlite persists an identity and rolls back a broken message insert', async () => {
  const { repo } = await freshRepo();
  const material = createIdentityMaterial();
  const identity = toPublicIdentity(material.keys, 'Ava', 'dev_ava');
  repo.transaction(() => {
    repo.insertIdentity({
      id: 'id_ava',
      directId: identity.directId,
      did: identity.did,
      displayName: 'Ava',
      agreementPublic: bytesToBase64Url(identity.agreementPublic),
      signingPublic: bytesToBase64Url(identity.signingPublic),
      agreementSignature: bytesToBase64Url(identity.agreementSignature),
      fingerprint: identity.fingerprint,
      deviceId: identity.deviceId,
      createdAt: 10,
    });
    repo.insertDevice({
      id: 'device_row',
      identityId: 'id_ava',
      deviceId: identity.deviceId,
      label: 'This device',
      publicKey: bytesToBase64Url(identity.agreementPublic),
      createdAt: 10,
      revokedAt: null,
      lastSeenAt: 10,
    });
  });
  expect(repo.getIdentity()?.directId).toBe(identity.directId);
  expect(repo.listDevices()).toHaveLength(1);

  expect(() =>
    repo.transaction(() => {
      repo.insertMessage({
        id: 'msg_missing',
        conversationId: 'conv_missing',
        senderDirectId: identity.directId,
        recipientDirectId: 'dir_other',
        body: 'should rollback',
        ciphertext: utf8('cipher'),
        createdAt: 11,
        status: 'pending',
        direction: 'outgoing',
        kind: 'user',
        transport: null,
      });
    }),
  ).toThrow(/FOREIGN KEY/i);
  expect(repo.getMessage('msg_missing')).toBeNull();
  const unsealed = repo.unsealedDatabase();
  expect(contains(unsealed, bytesToBase64Url(material.keys.signingSecret))).toBe(false);
});

test('the database file is encrypted and reopens only with the same key', async () => {
  const { vault, blobs, repo } = await freshRepo();
  const canary = 'CANARY-PLAINTEXT-9f3a2c';
  const material = createIdentityMaterial();
  const identity = toPublicIdentity(material.keys, 'Ava', 'dev_ava');
  const peer = toPublicIdentity(createIdentityMaterial().keys, 'Bo', 'dev_bo');
  repo.transaction(() => {
    repo.insertIdentity({
      id: 'id_ava',
      directId: identity.directId,
      did: identity.did,
      displayName: 'Ava',
      agreementPublic: bytesToBase64Url(identity.agreementPublic),
      signingPublic: bytesToBase64Url(identity.signingPublic),
      agreementSignature: bytesToBase64Url(identity.agreementSignature),
      fingerprint: identity.fingerprint,
      deviceId: identity.deviceId,
      createdAt: 10,
    });
    repo.upsertContact({
      id: 'contact_bo',
      directId: peer.directId,
      did: peer.did,
      displayName: 'Bo',
      agreementPublic: bytesToBase64Url(peer.agreementPublic),
      signingPublic: bytesToBase64Url(peer.signingPublic),
      agreementSignature: bytesToBase64Url(peer.agreementSignature),
      fingerprint: peer.fingerprint,
      deviceId: peer.deviceId,
      verified: true,
      blocked: false,
      accepted: true,
      createdAt: 11,
    });
    const conversationId = repo.ensureConversation(peer.directId, canary, 12, false);
    repo.insertMessage({
      id: 'msg_canary',
      conversationId,
      senderDirectId: identity.directId,
      recipientDirectId: peer.directId,
      body: canary,
      ciphertext: utf8('sealed-placeholder'),
      createdAt: 12,
      status: 'pending',
      direction: 'outgoing',
      kind: 'user',
      transport: null,
    });
  });
  const sealed = await repo.save();
  expect(contains(sealed, canary)).toBe(false);

  const reopened = new DirectRepository(await openEncryptedDatabase({ wasmBinary: wasmBytes(), vault, blobs, now: 20 }));
  expect(reopened.getMessage('msg_canary')?.body).toBe(canary);
  expect(reopened.listConversations()[0]?.preview).toBe(canary);

  const wrong = new MemoryKeyVault();
  await wrong.set('db.encryption.key', utf8('not-the-database-key-32-bytes!!'));
  await expect(openEncryptedDatabase({ wasmBinary: wasmBytes(), vault: wrong, blobs, now: 21 })).rejects.toThrow(/key/i);
});

test('two encrypted databases deliver directly and keep the message after acknowledgement', async () => {
  const mesh = new MemoryMesh();
  const aliceKeys = createIdentityMaterial().keys;
  const bobKeys = createIdentityMaterial().keys;
  const alicePublic = toPublicIdentity(aliceKeys, 'Ava', 'dev_ava');
  const bobPublic = toPublicIdentity(bobKeys, 'Bo', 'dev_bo');
  const aliceRepo = (await freshRepo()).repo;
  const bobRepo = (await freshRepo()).repo;
  const insert = (repo: DirectRepository, self: typeof alicePublic, peer: typeof bobPublic) => {
    repo.transaction(() => {
      repo.insertIdentity({
        id: `id_${self.directId}`,
        directId: self.directId,
        did: self.did,
        displayName: self.displayName,
        agreementPublic: bytesToBase64Url(self.agreementPublic),
        signingPublic: bytesToBase64Url(self.signingPublic),
        agreementSignature: bytesToBase64Url(self.agreementSignature),
        fingerprint: self.fingerprint,
        deviceId: self.deviceId,
        createdAt: 30,
      });
      repo.upsertContact({
        id: `contact_${peer.directId}`,
        directId: peer.directId,
        did: peer.did,
        displayName: peer.displayName,
        agreementPublic: bytesToBase64Url(peer.agreementPublic),
        signingPublic: bytesToBase64Url(peer.signingPublic),
        agreementSignature: bytesToBase64Url(peer.agreementSignature),
        fingerprint: peer.fingerprint,
        deviceId: peer.deviceId,
        verified: false,
        blocked: false,
        accepted: true,
        createdAt: 31,
      });
    });
  };
  insert(aliceRepo, alicePublic, bobPublic);
  insert(bobRepo, bobPublic, alicePublic);
  let n = 0;
  const ids = { next: (prefix: string) => `${prefix}_${n++}` };
  const clock = { now: () => 40 };
  const aliceLink = new LocalTransport(alicePublic.directId, mesh);
  const bobLink = new LocalTransport(bobPublic.directId, mesh);
  const alice = new DeliveryEngine({
    store: aliceRepo,
    router: {
      send: async (peerId, payload) => {
        if (!(await aliceLink.connect(peerId))) return { kind: 'queued' };
        await aliceLink.send(peerId, payload);
        return { kind: 'direct', transport: 'local' };
      },
    },
    identity: () => ({ directId: alicePublic.directId, deviceId: alicePublic.deviceId, cipher: createPeerCipher(aliceKeys) }),
    contact: () => ({ directId: bobPublic.directId, signingPublic: bobPublic.signingPublic, agreementPublic: bobPublic.agreementPublic }),
    clock,
    ids,
  });
  const bob = new DeliveryEngine({
    store: bobRepo,
    router: {
      send: async (peerId, payload) => {
        if (!(await bobLink.connect(peerId))) return { kind: 'queued' };
        await bobLink.send(peerId, payload);
        return { kind: 'direct', transport: 'local' };
      },
    },
    identity: () => ({ directId: bobPublic.directId, deviceId: bobPublic.deviceId, cipher: createPeerCipher(bobKeys) }),
    contact: () => ({ directId: alicePublic.directId, signingPublic: alicePublic.signingPublic, agreementPublic: alicePublic.agreementPublic }),
    clock,
    ids,
  });
  aliceLink.subscribe((peer, payload) => {
    void alice.receive(payload, peer);
  });
  bobLink.subscribe((peer, payload) => {
    void bob.receive(payload, peer);
  });
  const sent = await alice.sendText({
    recipient: { directId: bobPublic.directId, signingPublic: bobPublic.signingPublic, agreementPublic: bobPublic.agreementPublic },
    body: 'Stored locally.',
  });
  expect(sent.status).toBe('delivered');
  expect(aliceRepo.getQueueByMessage(sent.id)).toBeNull();
  expect(aliceRepo.getMessage(sent.id)?.body).toBe('Stored locally.');
  expect(bobRepo.listMessages(`conv_${alicePublic.directId}`)[0]?.body).toBe('Stored locally.');
  const sealed = await aliceRepo.save();
  expect(contains(sealed, 'Stored locally.')).toBe(false);
});
