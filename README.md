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

Download Direct Server for macOS, Windows, or Linux from [direct-server.apps.grok.bot](https://direct-server.apps.grok.bot). Open the app, press Start server, copy the `ws://` address it shows, and save that address on both phones. Each phone that connects is listed in the window.

Tagged builds start at [v0.1.0](https://github.com/opensourceapp-org/direct/releases/tag/v0.1.0). The same page in [site/index.html](site/index.html) also has clone steps. From source, `pnpm server` downloads the desktop app the first time. On a Mac, double-click `Start Server.command` in the project folder. `Direct.app` is the iPhone app, and macOS will not open it. Clone the repository from [github.com/opensourceapp-org/direct](https://github.com/opensourceapp-org/direct).

## Install on Android or iPhone

The phone apps are native. Android is Kotlin in `native/android`. iOS is Swift in `native/ios`. They are not a WebView, not React Native, and not Expo Go. `apps/mobile` stays as the browser preview and the TypeScript reference.

The phone apps do not contain the bootstrap. On a computer both phones can reach:

```bash
pnpm signaling
```

That listens on port 8787 and prints `ws://<this computer>:8787`. Allow that port through the firewall. On each phone, open Network and save that same address. `localhost` is rejected, because on a phone it means the phone itself. The phones do not need the same Wi-Fi if both can reach that computer. Create an identity on each phone. The sender looks up the other DIRECT ID and sends. The recipient sees a message request and accepts it before replying.

Android: install Android Studio, open `native/android`, and run the `app` configuration (API 26 or newer). From a terminal, `cd native/android && ./gradlew :app:assembleDebug` writes `app/build/outputs/apk/debug/app-debug.apk`.

iPhone: on a Mac, open `native/ios/Direct.xcodeproj` (File → Open, or double-click that file). Pick your team under Signing & Capabilities, then run on a device. Xcode 16 or newer.

Do not open `App.xcodeproj`. That was the old shell. If a leftover `apps/mobile/ios` folder is still on disk, delete it. Opening that `App.xcodeproj` shows “does not contain a project definition file” because `project.pbxproj` is gone on purpose.

The steps, the background-work limits, and the two-phone checklist are in [docs/native.md](docs/native.md).

## What this repository contains

| Area | Role |
| --- | --- |
| `native/android` | Kotlin app. Keystore secrets, OkHttp bootstrap socket, WebRTC data channel, WorkManager retries, Compose UI |
| `native/ios` | Swift app and the `DirectCore` package. Keychain secrets, URLSession socket, WebRTC data channel, background refresh, SwiftUI |
| `contracts` | Bootstrap URL rules, signaling frames, and wire vectors shared by TypeScript, Kotlin, and Swift |
| `apps/mobile` | Browser preview and the React Native screens used to exercise the TypeScript packages |
| `packages/crypto` | Identity, recovery phrase, signatures, and sealed messages using audited primitives |
| `packages/protocol` | Envelopes, acknowledgements, expiry, backoff, and the delivery engine |
| `packages/transport` | `TransportAdapter`, router, local mesh, WebRTC, libp2p dial boundary, Waku-style relay, Kademlia table |
| `packages/shared` | Identifiers, encoding, and log redaction |
| `infrastructure` | Signaling server and notes for bootstrap, TURN, and relay hosts |
| `docs` | Architecture, protocol, security notes, and the native device checklist |

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
- This is not an implementation of the Signal Double Ratchet. The phone apps and the TypeScript packages use the same one-shot seal: a fresh X25519 key, HKDF-SHA256, and AES-256-GCM. Android uses BouncyCastle and JCA. iOS uses CryptoKit. The TypeScript packages use `@noble/curves`, `@noble/hashes`, and `@noble/ciphers`.
- The phone apps keep the identity seed in the Android Keystore or the iOS Keychain. The local queue is one AES-256-GCM file, replaced atomically. The browser preview keeps its database in IndexedDB and says so in Settings.
- Logs drop message text, phrases, and keys.

## Native projects

`native/android` and `native/ios` are the apps that run on a phone. Each process owns one node. Foreground reconnects the bootstrap immediately. Android schedules the outbox with WorkManager. iOS registers a background refresh and retries again when the app becomes active. A suspended app cannot receive, because there is no push service. Details and the two-phone checklist are in [docs/native.md](docs/native.md).
