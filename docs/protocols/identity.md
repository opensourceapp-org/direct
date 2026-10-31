# Identity

A DIRECT identity is a 32-byte seed.

- The Ed25519 signing key is the seed.
- The X25519 agreement key is HKDF-SHA256 of the seed with info `DIRECT-X25519-v1`, unless the device has rotated it.
- The DIRECT ID is `dir_` plus 16 Crockford characters of SHA-256(signing public key).
- The DID is `did:direct:<DIRECT ID>`. Nothing is written to a chain and no wallet is required.

The public bundle carries the display name, both public keys, a signature over the name and the agreement key, the fingerprint, and the device id. Bundles that fail that check are rejected.

The fingerprint is the first 16 bytes of SHA-256(signing public key ‖ agreement public key), grouped in fours. It changes when the agreement key rotates. The DIRECT ID does not.

The recovery phrase is the BIP-39 encoding of the seed. Twenty-four words. DIRECT never sees them.
