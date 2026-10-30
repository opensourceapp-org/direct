# Security model

DIRECT's promise is limited and specific.

- No server holds message plaintext or private keys.
- A message is confidential to the recipient's agreement key and authenticated by the sender's signing key.
- The local database file does not contain message plaintext. The in-memory database does, because the owner has to read their history. That memory image is sealed before it is stored.
- Private keys are not in SQLite and are not written to logs.
- Replay of a message id is ignored.
- Tampered ciphertext, a swapped sender, or a bad acknowledgement signature is dropped.
- Device revocation marks the local device record and deletes session notes.
- Relay storage is off until the user accepts the disclosure. Stored bytes are ciphertext with an expiry.

## What this build does not claim

The per-message seal provides confidentiality, integrity, and forward secrecy for the sender's ephemeral key. It does not provide the post-compromise healing of the Double Ratchet. Do not describe this preview as a Signal-protocol implementation.

A browser profile is a weaker key store than the iOS Keychain or the Android Keystore. Same-origin script can read IndexedDB. Treat the browser preview as a way to run the product, not as the production key store.

The recovery phrase restores the signing seed and the agreement key derived from it. Agreement keys rotated later live only on that device.

## Release checks

`pnpm test` covers identity creation and restore, bundle tampering, seal authentication, queue acknowledgement, relay non-delivery, expiry, database foreign keys, encryption at rest, and a two-database direct delivery.
