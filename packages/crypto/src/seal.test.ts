import { utf8, text } from '@direct/shared';
import { createIdentityMaterial, createPeerCipher, open, seal } from './index';

test('seals a message to the recipient and rejects tampering', () => {
  const alice = createIdentityMaterial().keys;
  const bob = createIdentityMaterial().keys;
  const aad = utf8('msg_1|alice|bob');
  const payload = seal({
    recipientAgreementPublic: bob.agreementPublic,
    plaintext: utf8('north gate'),
    aad,
  });
  expect(text(open({ recipientAgreementSecret: bob.agreementSecret, payload, aad }))).toBe('north gate');
  expect(() => open({ recipientAgreementSecret: alice.agreementSecret, payload, aad })).toThrow(/authentication|Unable to open/);

  const tampered = new Uint8Array(payload);
  tampered[tampered.length - 1] ^= 0xff;
  expect(() => open({ recipientAgreementSecret: bob.agreementSecret, payload: tampered, aad })).toThrow();
  expect(() => open({
    recipientAgreementSecret: bob.agreementSecret,
    payload,
    aad: utf8('other'),
  })).toThrow();
});

test('a rotated recipient key opens payloads sealed to the previous agreement key', () => {
  const bob = createIdentityMaterial().keys;
  const previous = bob.agreementSecret;
  const nextSecret = createIdentityMaterial().keys.agreementSecret;
  const payload = seal({
    recipientAgreementPublic: bob.agreementPublic,
    plaintext: utf8('still readable'),
    aad: utf8('aad'),
  });
  const opened = open({
    recipientAgreementSecret: nextSecret,
    previousSecrets: [previous],
    payload,
    aad: utf8('aad'),
  });
  expect(text(opened)).toBe('still readable');
});

test('peer cipher signatures authenticate the sender', () => {
  const aliceKeys = createIdentityMaterial().keys;
  const alice = createPeerCipher(aliceKeys);
  const bob = createPeerCipher(createIdentityMaterial().keys);
  const message = utf8('ack:msg_1');
  const signature = alice.sign(message);
  expect(bob.verify(aliceKeys.signingPublic, message, signature)).toBe(true);
  const flipped = new Uint8Array(signature);
  flipped[0] ^= 0xff;
  expect(bob.verify(aliceKeys.signingPublic, message, flipped)).toBe(false);
});
