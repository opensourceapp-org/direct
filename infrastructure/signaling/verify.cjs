const { createHash, createPublicKey, randomBytes, verify } = require('node:crypto');

const CROCKFORD = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
const ED25519_SPKI_PREFIX = Buffer.from('302a300506032b6570032100', 'hex');
const DIRECT_ID = /^dir_[0-9A-HJKMNP-TV-Z]{16}$/;
const PROOF_PREFIX = 'DIRECT-SIGNAL/1\n';
const MAX_BUNDLE = 8192;
const MAX_NAME = 32;
const NONCE_PATTERN = /^[A-Za-z0-9_-]{32,64}$/;

function crockford(bytes) {
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

function b64urlDecode(value) {
  if (typeof value !== 'string' || !/^[A-Za-z0-9_-]+$/.test(value)) return null;
  try {
    return Buffer.from(value, 'base64url');
  } catch {
    return null;
  }
}

function ed25519Verify(publicRaw, message, signature) {
  if (!publicRaw || publicRaw.length !== 32 || !signature || signature.length !== 64) return false;
  try {
    const key = createPublicKey({
      key: Buffer.concat([ED25519_SPKI_PREFIX, publicRaw]),
      format: 'der',
      type: 'spki',
    });
    return verify(null, message, key, signature);
  } catch {
    return false;
  }
}

function directIdFromSigningPublic(signingPublic) {
  const digest = createHash('sha256').update(signingPublic).digest().subarray(0, 10);
  return `dir_${crockford(digest)}`;
}

function fingerprint(signingPublic, agreementPublic) {
  const digest = createHash('sha256').update(signingPublic).update(agreementPublic).digest().subarray(0, 16);
  return digest.toString('hex').toUpperCase().match(/.{4}/g).join(' ');
}

function parsePublicBundle(serialized) {
  if (typeof serialized !== 'string' || serialized.length < 32 || serialized.length > MAX_BUNDLE) return null;
  let parsed;
  try {
    parsed = JSON.parse(serialized);
  } catch {
    return null;
  }
  if (!parsed || parsed.v !== 1 || typeof parsed.directId !== 'string' || typeof parsed.name !== 'string') return null;
  if (parsed.name.length > MAX_NAME) return null;
  const signingPublic = b64urlDecode(parsed.signingKey);
  const agreementPublic = b64urlDecode(parsed.agreementKey);
  const agreementSig = b64urlDecode(parsed.agreementSig);
  if (!signingPublic || !agreementPublic || !agreementSig) return null;
  if (signingPublic.length !== 32 || agreementPublic.length !== 32 || agreementSig.length !== 64) return null;
  const directId = directIdFromSigningPublic(signingPublic);
  if (!DIRECT_ID.test(directId) || directId !== parsed.directId || parsed.did !== `did:direct:${directId}`) return null;
  const payload = Buffer.concat([Buffer.from(parsed.name, 'utf8'), Buffer.from([0]), agreementPublic]);
  if (!ed25519Verify(signingPublic, payload, agreementSig)) return null;
  if (parsed.fingerprint !== fingerprint(signingPublic, agreementPublic)) return null;
  return { directId, signingPublic };
}

function proofMessage(nonce, directId) {
  return Buffer.from(`${PROOF_PREFIX}${nonce}\n${directId}`, 'utf8');
}

function newNonce() {
  return randomBytes(32).toString('base64url');
}

/** True only when the hello proves possession of the bundle's signing key for this socket's nonce. */
function verifyHello(message, expectedNonce) {
  if (!message || typeof message !== 'object') return null;
  if (typeof expectedNonce !== 'string' || !NONCE_PATTERN.test(expectedNonce)) return null;
  if (message.nonce !== expectedNonce || !NONCE_PATTERN.test(message.nonce)) return null;
  const parsed = parsePublicBundle(message.bundle);
  if (!parsed || parsed.directId !== message.from) return null;
  const signature = b64urlDecode(message.proof);
  if (!signature) return null;
  if (!ed25519Verify(parsed.signingPublic, proofMessage(message.nonce, parsed.directId), signature)) return null;
  return parsed;
}

module.exports = {
  DIRECT_ID,
  MAX_BUNDLE,
  PROOF_PREFIX,
  parsePublicBundle,
  verifyHello,
  newNonce,
  proofMessage,
};
