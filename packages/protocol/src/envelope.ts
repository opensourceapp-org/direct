import { base64UrlToBytes, bytesToBase64Url, text, utf8 } from '@direct/shared';
import type { PeerCipher } from './types';

export type EnvelopeType = 'message' | 'ack' | 'read' | 'profile';

export type Envelope = {
  v: 1;
  id: string;
  type: EnvelopeType;
  from: string;
  to: string;
  deviceId: string;
  createdAt: number;
  expiresAt: number;
  ciphertext: string;
  signature: string;
};

const MAX_ENVELOPE_BYTES = 256 * 1024;

export class EnvelopeError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'EnvelopeError';
  }
}

export function canonical(envelope: Omit<Envelope, 'signature'>): Uint8Array {
  return utf8([
    envelope.v,
    envelope.id,
    envelope.type,
    envelope.from,
    envelope.to,
    envelope.deviceId,
    envelope.createdAt,
    envelope.expiresAt,
    envelope.ciphertext,
  ].join('|'));
}

export function aadFor(envelope: Pick<Envelope, 'v' | 'id' | 'type' | 'from' | 'to' | 'createdAt'>): Uint8Array {
  return utf8(`${envelope.v}|${envelope.type}|${envelope.id}|${envelope.from}|${envelope.to}|${envelope.createdAt}`);
}

export function encodeEnvelope(envelope: Omit<Envelope, 'signature'>, cipher: PeerCipher): Uint8Array {
  const signature = bytesToBase64Url(cipher.sign(canonical(envelope)));
  return utf8(JSON.stringify({ ...envelope, signature }));
}

export function decodeEnvelope(bytes: Uint8Array, verify: PeerCipher['verify'], signingPublic: Uint8Array, now: number): Envelope {
  if (bytes.length > MAX_ENVELOPE_BYTES) throw new EnvelopeError('Envelope is too large.');
  let envelope: Envelope;
  try {
    envelope = JSON.parse(text(bytes)) as Envelope;
  } catch {
    throw new EnvelopeError('Envelope is not valid JSON.');
  }
  if (envelope.v !== 1 || !envelope.id || !envelope.signature) throw new EnvelopeError('Envelope is malformed.');
  if (envelope.createdAt > now + 60_000) throw new EnvelopeError('Envelope is too far in the future.');
  if (envelope.expiresAt + 60_000 < now) throw new EnvelopeError('Envelope has expired.');
  const { signature, ...rest } = envelope;
  const ok = verify(signingPublic, canonical(rest), base64UrlToBytes(signature));
  if (!ok) throw new EnvelopeError('Envelope signature is not valid.');
  return envelope;
}
