# DIRECT

No Middlemen. Just Connection.

DIRECT is a peer-to-peer messenger. Each device holds its own identity, encrypts messages before they leave, and keeps them until the recipient's device signs an acknowledgement. There is no company message database.

## Run the browser preview

```bash
pnpm install
pnpm dev
```

Open the printed local URL. The preview uses the same React Native components as the mobile app, rendered with React Native Web.

Create an identity on this device. A second phone, in another place, opens the same reachable DIRECT address and looks up the DIRECT ID from Contacts. The phones do not need the same Wi-Fi. That address runs a bootstrap at `/api/direct/signal`: it keeps the latest public bundle for each online DIRECT ID and forwards WebRTC session descriptions. It does not receive message text.

If the direct data channel cannot open, the same host can still hand sealed ciphertext through a short-lived mailbox. That handoff stays pending until the recipient's device signs an acknowledgement.

A second `pnpm dev` on another port is a different bootstrap. Point both phones at one address, or set the same bootstrap URL on the Network screen. Two windows on one address, including a private window, still find each other.

```bash
pnpm test
pnpm typecheck
pnpm --filter @direct/mobile build
```

Optional standalone bootstrap, for a host that is not the Vite preview. It exchanges public bundles and session descriptions, and nothing else:

```bash
pnpm signaling
```

## What this repository contains

| Area | Role |
| --- | --- |
| `apps/mobile` | React Native application, design system, screens, encrypted SQLite repositories |
| `packages/crypto` | Identity, recovery phrase, signatures, and sealed messages using audited primitives |
| `packages/protocol` | Envelopes, acknowledgements, expiry, backoff, and the delivery engine |
| `packages/transport` | `TransportAdapter`, router, local mesh, WebRTC, libp2p dial boundary, Waku-style relay, Kademlia table |
| `packages/shared` | Identifiers, encoding, and log redaction |
| `infrastructure` | Signaling server and notes for bootstrap, TURN, and relay hosts |
| `docs` | Architecture, protocol, and security notes |

The interface never calls WebRTC, libp2p, Waku, SQLite, or private keys directly. Screens talk to `DirectController`.

## Transport order

1. An existing direct connection.
2. A new direct connection.
3. An optional distributed relay, if you turn it on.
4. The encrypted local queue, with exponential backoff, until expiry.

A relay that accepts a payload does not mark the message delivered.

## Security boundary

- Identity is an Ed25519 signing key. The DIRECT ID is derived from that public key. The DID is `did:direct:<DIRECT ID>` and does not use a blockchain.
- The agreement key is X25519. A recovery phrase encodes the 32-byte seed with BIP-39. Rotating the agreement key does not change the DIRECT ID.
- Each message is sealed to the recipient with a fresh X25519 key, HKDF-SHA256, and AES-256-GCM. The libraries are `@noble/curves`, `@noble/hashes`, and `@noble/ciphers`.
- This is not an implementation of the Signal Double Ratchet. Native builds are expected to satisfy that requirement with `react-native-libsignal-client` behind the existing `PeerCipher` boundary. The pure-JS seal is the path that runs in tests and in the browser preview.
- The local database is SQL, sealed with AES-256-GCM before it is written. Private keys stay in the key store, not in SQLite. iOS Keychain and Android Keystore are the production key stores; this browser profile uses IndexedDB and says so in Settings.
- Logs drop message text, phrases, and keys.

## Native projects

`apps/mobile/android` and `apps/mobile/ios` contain the background-delivery entry points. They attach to a React Native host when the native projects are generated. They are not a substitute for the browser preview, and they are not claimed to build in this repository yet.

Background work respects the platform. Android schedules a worker. iOS registers a background refresh and always retries when the app becomes active.
