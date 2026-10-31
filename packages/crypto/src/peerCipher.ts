import { base64UrlToBytes, bytesToBase64Url, utf8 } from '@direct/shared';
import type { IdentityKeys } from './identity';
import { signBytes, verifyBytes } from './identity';
import { open, seal } from './seal';

export type PeerCipher = {
  sealTo(agreementPublic: Uint8Array, plaintext: Uint8Array, aad: Uint8Array): Uint8Array;
  open(payload: Uint8Array, aad: Uint8Array): Uint8Array;
  sign(message: Uint8Array): Uint8Array;
  verify(signingPublic: Uint8Array, message: Uint8Array, signature: Uint8Array): boolean;
};

export function createPeerCipher(keys: IdentityKeys, previousAgreementSecrets: Uint8Array[] = []): PeerCipher {
  return {
    sealTo(agreementPublic, plaintext, aad) {
      return seal({ recipientAgreementPublic: agreementPublic, plaintext, aad });
    },
    open(payload, aad) {
      return open({
        recipientAgreementSecret: keys.agreementSecret,
        previousSecrets: previousAgreementSecrets,
        payload,
        aad,
      });
    },
    sign(message) {
      return signBytes(keys.signingSecret, message);
    },
    verify(signingPublic, message, signature) {
      return verifyBytes(signingPublic, message, signature);
    },
  };
}

export function encodeSecretList(secrets: Uint8Array[]): Uint8Array {
  return utf8(JSON.stringify(secrets.map((secret) => bytesToBase64Url(secret))));
}

export function decodeSecretList(bytes: Uint8Array | null): Uint8Array[] {
  if (!bytes) return [];
  const parsed = JSON.parse(new TextDecoder().decode(bytes)) as string[];
  return parsed.map((item) => base64UrlToBytes(item));
}
