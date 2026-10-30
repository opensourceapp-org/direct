import { gcm } from '@noble/ciphers/aes.js';
import { x25519 } from '@noble/curves/ed25519.js';
import { hkdf } from '@noble/hashes/hkdf.js';
import { sha256 } from '@noble/hashes/sha2.js';
import { concat, randomBytes, utf8 } from '@direct/shared';

const SEAL_INFO = utf8('DIRECT-SEAL-v1');
const VERSION = 1;

export class SealError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'SealError';
  }
}

export type SealInput = {
  recipientAgreementPublic: Uint8Array;
  plaintext: Uint8Array;
  aad: Uint8Array;
};

export function seal(input: SealInput): Uint8Array {
  const ephemeralSecret = x25519.utils.randomSecretKey();
  const ephemeralPublic = x25519.getPublicKey(ephemeralSecret);
  const shared = x25519.getSharedSecret(ephemeralSecret, input.recipientAgreementPublic);
  const key = hkdf(sha256, shared, ephemeralPublic, SEAL_INFO, 32);
  const nonce = randomBytes(12);
  const ciphertext = gcm(key, nonce, input.aad).encrypt(input.plaintext);
  return concat([Uint8Array.of(VERSION), ephemeralPublic, nonce, ciphertext]);
}

export function open(input: {
  recipientAgreementSecret: Uint8Array;
  previousSecrets?: Uint8Array[];
  payload: Uint8Array;
  aad: Uint8Array;
}): Uint8Array {
  const secrets = [input.recipientAgreementSecret, ...(input.previousSecrets ?? [])];
  let lastError: unknown;
  for (const secret of secrets) {
    try {
      return openWith(secret, input.payload, input.aad);
    } catch (error) {
      lastError = error;
    }
  }
  throw lastError instanceof Error ? lastError : new SealError('Unable to open sealed payload.');
}

function openWith(secret: Uint8Array, payload: Uint8Array, aad: Uint8Array): Uint8Array {
  if (payload.length < 1 + 32 + 12 + 16 || payload[0] !== VERSION) {
    throw new SealError('Sealed payload is not a DIRECT envelope.');
  }
  const ephemeralPublic = payload.subarray(1, 33);
  const nonce = payload.subarray(33, 45);
  const ciphertext = payload.subarray(45);
  const shared = x25519.getSharedSecret(secret, ephemeralPublic);
  const key = hkdf(sha256, shared, ephemeralPublic, SEAL_INFO, 32);
  try {
    return gcm(key, nonce, aad).decrypt(ciphertext);
  } catch {
    throw new SealError('Sealed payload failed authentication.');
  }
}

export function sealDatabase(key: Uint8Array, plaintext: Uint8Array): Uint8Array {
  if (key.length !== 32) throw new SealError('Database key must be 32 bytes.');
  const nonce = randomBytes(12);
  const ciphertext = gcm(key, nonce, utf8('DIRECT-DB-v1')).encrypt(plaintext);
  return concat([Uint8Array.of(VERSION), nonce, ciphertext]);
}

export function openDatabase(key: Uint8Array, payload: Uint8Array): Uint8Array {
  if (payload.length < 1 + 12 + 16 || payload[0] !== VERSION) {
    throw new SealError('Encrypted database header is not recognized.');
  }
  const nonce = payload.subarray(1, 13);
  try {
    return gcm(key, nonce, utf8('DIRECT-DB-v1')).decrypt(payload.subarray(13));
  } catch {
    throw new SealError('Database key does not match this file.');
  }
}
