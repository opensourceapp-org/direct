const CHUNK = 0x8000;

export function utf8(value: string): Uint8Array {
  return new TextEncoder().encode(value);
}

export function text(bytes: Uint8Array): string {
  return new TextDecoder().decode(bytes);
}

function binaryFromBytes(bytes: Uint8Array): string {
  let out = '';
  for (let i = 0; i < bytes.length; i += CHUNK) {
    out += String.fromCharCode(...bytes.subarray(i, i + CHUNK));
  }
  return out;
}

export function bytesToBase64Url(bytes: Uint8Array): string {
  return btoa(binaryFromBytes(bytes)).replaceAll('+', '-').replaceAll('/', '_').replaceAll('=', '');
}

export function base64UrlToBytes(value: string): Uint8Array {
  const padded = value.replaceAll('-', '+').replaceAll('_', '/') + '==='.slice((value.length + 3) % 4);
  const binary = atob(padded);
  const out = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) out[i] = binary.charCodeAt(i);
  return out;
}

export function randomBytes(length: number): Uint8Array {
  const bytes = new Uint8Array(length);
  const cryptoApi = globalThis.crypto;
  if (!cryptoApi?.getRandomValues) {
    throw new Error('A CSPRNG is required to generate DIRECT keys.');
  }
  cryptoApi.getRandomValues(bytes);
  return bytes;
}

export function newId(prefix: string): string {
  const hex = [...randomBytes(16)].map((byte) => byte.toString(16).padStart(2, '0')).join('');
  return `${prefix}_${hex}`;
}

export function concat(parts: Uint8Array[]): Uint8Array {
  const length = parts.reduce((sum, part) => sum + part.length, 0);
  const out = new Uint8Array(length);
  let offset = 0;
  for (const part of parts) {
    out.set(part, offset);
    offset += part.length;
  }
  return out;
}

export function equalBytes(left: Uint8Array, right: Uint8Array): boolean {
  if (left.length !== right.length) return false;
  let diff = 0;
  for (let i = 0; i < left.length; i += 1) diff |= left[i]! ^ right[i]!;
  return diff === 0;
}
