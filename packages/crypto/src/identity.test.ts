import { base64UrlToBytes } from '@direct/shared';
import {
  createBundle,
  createIdentityMaterial,
  encodeBundle,
  fingerprintFor,
  parseBundle,
  restoreFromMnemonic,
  rotateAgreementKey,
  toPublicIdentity,
} from './index';

test('creating an identity restores from its recovery phrase', () => {
  const created = createIdentityMaterial();
  const restored = restoreFromMnemonic(created.mnemonic);
  expect([...restored.signingPublic]).toEqual([...created.keys.signingPublic]);
  expect([...restored.agreementPublic]).toEqual([...created.keys.agreementPublic]);
  const identity = toPublicIdentity(created.keys, 'Ava', 'dev_test');
  expect(identity.directId.startsWith('dir_')).toBe(true);
  expect(identity.did).toBe(`did:direct:${identity.directId}`);
  expect(identity.fingerprint).toBe(fingerprintFor(created.keys.signingPublic, created.keys.agreementPublic));
  expect(created.mnemonic.split(' ')).toHaveLength(24);
});

test('a published bundle verifies and a tampered bundle does not', () => {
  const { keys } = createIdentityMaterial();
  const identity = toPublicIdentity(keys, 'Ava', 'dev_test');
  const bundle = parseBundle(encodeBundle(createBundle(identity)));
  expect(bundle.directId).toBe(identity.directId);

  const forged = { ...bundle, name: 'Someone else' };
  expect(() => parseBundle(JSON.stringify(forged))).toThrow(/signature/);

  const swapped = { ...bundle, agreementKey: bundle.signingKey };
  expect(() => parseBundle(JSON.stringify(swapped))).toThrow(/signature|Fingerprint|DIRECT ID/);
});

test('agreement key rotation keeps the DIRECT ID and the previous key can still be identified', () => {
  const { keys } = createIdentityMaterial();
  const before = toPublicIdentity(keys, 'Ava', 'dev_stable');
  const rotated = rotateAgreementKey(keys);
  const after = toPublicIdentity(rotated.keys, 'Ava', 'dev_stable');
  expect(after.directId).toBe(before.directId);
  expect(after.fingerprint).not.toBe(before.fingerprint);
  expect([...rotated.previousSecret]).toEqual([...keys.agreementSecret]);
  expect(base64UrlToBytes(createBundle(after).signingKey).length).toBe(32);
});

test('rejects a recovery phrase that is not bip39', () => {
  expect(() => restoreFromMnemonic('not a real recovery phrase at all ever')).toThrow(/not valid/);
});
