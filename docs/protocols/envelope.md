# Envelope

Version 1 envelopes are JSON, signed with the sender's Ed25519 key over a canonical field list. The ciphertext field is a seal:

```text
version || ephemeral X25519 public key || 12-byte nonce || AES-256-GCM ciphertext
```

The AES key is HKDF-SHA256 of the ephemeral shared secret, with the ephemeral public key as salt and info `DIRECT-SEAL-v1`. Associated data binds the envelope version, type, id, sender, recipient, and timestamp.

Types are `message`, `ack`, `read`, `profile`, `call`, and `group`. Acknowledgements are sealed too. Their plaintext is `ack:<message id>` or `read:<message id>`. A `profile` plaintext is the display photo and status. A `call` plaintext is one live signal (invite, accept, reject, busy, hangup, offer, answer, ice, or member) and is not stored as a message. A `group` envelope is a membership invite or leave. Group chat text is a normal `message` whose plaintext starts with `DIRECT-GROUP/1` and is sealed once per member; the sender treats every copy as delivered only after each member's signed `ack`.

Envelopes more than 256 KB, dated more than a minute in the future, or expired are rejected. The signature is checked against the contact's signing key before the seal is opened.
