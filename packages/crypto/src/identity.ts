import { ed25519, x25519 } from '@noble/curves/ed25519.js';
import { hkdf } from '@noble/hashes/hkdf.js';
import { sha256 } from '@noble/hashes/sha2.js';
import { entropyToMnemonic, mnemonicToEntropy, validateMnemonic } from '@scure/bip39';
import { wordlist } from '@scure/bip39/wordlists/english.js';
import { base64UrlToBytes, bytesToBase64Url, concat, randomBytes, text, utf8 } from '@direct/shared';
import { deviceId as newDeviceId, didFromDirectId, directIdFromSigningPublic } from './id';

const AGREEMENT_INFO = utf8('DIRECT-X25519-v1');

export class IdentityError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'IdentityError';
  }
}

export type IdentityKeys = {
  seed: Uint8Array;
  signingSecret: Uint8Array;
  signingPublic: Uint8Array;
  agreementSecret: Uint8Array;
  agreementPublic: Uint8Array;
};

export type PublicIdentity = {
  directId: string;
  did: string;
  deviceId: string;
  displayName: string;
  fingerprint: string;
  signingPublic: Uint8Array;
  agreementPublic: Uint8Array;
  agreementSignature: Uint8Array;
};

export function deriveAgreement(seed: Uint8Array): { secret: Uint8Array; publicKey: Uint8Array } {
  const secret = hkdf(sha256, seed, undefined, AGREEMENT_INFO, 32);
  return { secret, publicKey: x25519.getPublicKey(secret) };
}

export function keysFromSeed(seed: Uint8Array): IdentityKeys {
  if (seed.length !== 32) throw new IdentityError('Identity seed must be 32 bytes.');
  const signingSecret = seed;
  const signingPublic = ed25519.getPublicKey(signingSecret);
  const agreement = deriveAgreement(seed);
  return {
    seed,
    signingSecret,
    signingPublic,
    agreementSecret: agreement.secret,
    agreementPublic: agreement.publicKey,
  };
}

export function createIdentityMaterial(): { keys: IdentityKeys; mnemonic: string } {
  const seed = randomBytes(32);
  const mnemonic = entropyToMnemonic(seed, wordlist);
  return { keys: keysFromSeed(seed), mnemonic };
}

export function restoreFromMnemonic(mnemonic: string): IdentityKeys {
  const normalized = mnemonic.trim().toLowerCase().split(/\s+/).join(' ');
  if (!validateMnemonic(normalized, wordlist)) {
    throw new IdentityError('Recovery phrase is not valid.');
  }
  const seed = mnemonicToEntropy(normalized, wordlist);
  return keysFromSeed(seed);
}

export function mnemonicForSeed(seed: Uint8Array): string {
  return entropyToMnemonic(seed, wordlist);
}

export function fingerprintFor(signingPublic: Uint8Array, agreementPublic: Uint8Array): string {
  const digest = sha256(concat([signingPublic, agreementPublic]));
  const hex = [...digest.subarray(0, 16)].map((byte) => byte.toString(16).padStart(2, '0')).join('').toUpperCase();
  return hex.match(/.{1,4}/g)?.join(' ') ?? hex;
}

function agreementPayload(displayName: string, agreementPublic: Uint8Array): Uint8Array {
  return concat([utf8(displayName), Uint8Array.of(0), agreementPublic]);
}

export function signAgreement(signingSecret: Uint8Array, displayName: string, agreementPublic: Uint8Array): Uint8Array {
  return ed25519.sign(agreementPayload(displayName, agreementPublic), signingSecret);
}

export function verifyAgreement(
  signingPublic: Uint8Array,
  displayName: string,
  agreementPublic: Uint8Array,
  signature: Uint8Array,
): boolean {
  try {
    return ed25519.verify(signature, agreementPayload(displayName, agreementPublic), signingPublic);
  } catch {
    return false;
  }
}

export function signBytes(signingSecret: Uint8Array, message: Uint8Array): Uint8Array {
  return ed25519.sign(message, signingSecret);
}

export function verifyBytes(signingPublic: Uint8Array, message: Uint8Array, signature: Uint8Array): boolean {
  try {
    return ed25519.verify(signature, message, signingPublic);
  } catch {
    return false;
  }
}

export function replaceAgreement(keys: IdentityKeys, secret: Uint8Array): IdentityKeys {
  return {
    ...keys,
    agreementSecret: secret,
    agreementPublic: x25519.getPublicKey(secret),
  };
}

export function rotateAgreementKey(keys: IdentityKeys): { keys: IdentityKeys; previousSecret: Uint8Array } {
  const secret = x25519.utils.randomSecretKey();
  return {
    previousSecret: keys.agreementSecret,
    keys: {
      ...keys,
      agreementSecret: secret,
      agreementPublic: x25519.getPublicKey(secret),
    },
  };
}

export function toPublicIdentity(keys: IdentityKeys, displayName: string, currentDeviceId = newDeviceId()): PublicIdentity {
  const directId = directIdFromSigningPublic(keys.signingPublic);
  return {
    directId,
    did: didFromDirectId(directId),
    deviceId: currentDeviceId,
    displayName: displayName.trim(),
    fingerprint: fingerprintFor(keys.signingPublic, keys.agreementPublic),
    signingPublic: keys.signingPublic,
    agreementPublic: keys.agreementPublic,
    agreementSignature: signAgreement(keys.signingSecret, displayName.trim(), keys.agreementPublic),
  };
}

export type PublicBundle = {
  v: 1;
  name: string;
  directId: string;
  did: string;
  deviceId: string;
  signingKey: string;
  agreementKey: string;
  agreementSig: string;
  fingerprint: string;
};

export function createBundle(identity: PublicIdentity): PublicBundle {
  return {
    v: 1,
    name: identity.displayName,
    directId: identity.directId,
    did: identity.did,
    deviceId: identity.deviceId,
    signingKey: bytesToBase64Url(identity.signingPublic),
    agreementKey: bytesToBase64Url(identity.agreementPublic),
    agreementSig: bytesToBase64Url(identity.agreementSignature),
    fingerprint: identity.fingerprint,
  };
}

export function encodeBundle(bundle: PublicBundle): string {
  return JSON.stringify(bundle);
}

export function parseBundle(serialized: string): PublicBundle {
  let parsed: PublicBundle;
  try {
    parsed = JSON.parse(serialized) as PublicBundle;
  } catch {
    throw new IdentityError('Identity bundle is not valid JSON.');
  }
  if (parsed?.v !== 1 || !parsed.directId || !parsed.signingKey || !parsed.agreementKey || !parsed.agreementSig) {
    throw new IdentityError('Identity bundle is missing required fields.');
  }
  const signingPublic = base64UrlToBytes(parsed.signingKey);
  const agreementPublic = base64UrlToBytes(parsed.agreementKey);
  const signature = base64UrlToBytes(parsed.agreementSig);
  const directId = directIdFromSigningPublic(signingPublic);
  if (directId !== parsed.directId || parsed.did !== didFromDirectId(directId)) {
    throw new IdentityError('DIRECT ID does not match the signing key.');
  }
  if (!verifyAgreement(signingPublic, parsed.name, agreementPublic, signature)) {
    throw new IdentityError('Agreement key signature is not valid.');
  }
  const fingerprint = fingerprintFor(signingPublic, agreementPublic);
  if (parsed.fingerprint !== fingerprint) {
    throw new IdentityError('Fingerprint does not match the published keys.');
  }
  if (text(utf8(parsed.name)).length > 32) {
    throw new IdentityError('Display name is too long.');
  }
  return { ...parsed, fingerprint };
}
