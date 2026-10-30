import { sha256 } from '@noble/hashes/sha2.js';
import { utf8 } from '@direct/shared';

const CROCKFORD = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

export function crockford(bytes: Uint8Array): string {
  let bits = 0;
  let value = 0;
  let out = '';
  for (const byte of bytes) {
    value = (value << 8) | byte;
    bits += 8;
    while (bits >= 5) {
      bits -= 5;
      out += CROCKFORD[(value >>> bits) & 31];
    }
  }
  if (bits > 0) out += CROCKFORD[(value << (5 - bits)) & 31];
  return out;
}

export function directIdFromSigningPublic(signingPublic: Uint8Array): string {
  const digest = sha256(signingPublic).subarray(0, 10);
  return `dir_${crockford(digest)}`;
}

export function didFromDirectId(directId: string): string {
  return `did:direct:${directId}`;
}

export function discoveryNodeId(directId: string): Uint8Array {
  return sha256(utf8(directId));
}

export function deviceId(): string {
  const bytes = new Uint8Array(10);
  crypto.getRandomValues(bytes);
  return `dev_${crockford(bytes)}`;
}
