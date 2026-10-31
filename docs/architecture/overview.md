# Architecture

DIRECT is a set of modules with one rule: the interface does not touch transports, SQL, or private keys.

```text
Screens → DirectController → DeliveryEngine → TransportRouter
                          ↘ DirectRepository → Encrypted SQLite
                          ↘ PeerCipher        → vault
```

Modules:

| Module | Responsibility |
| --- | --- |
| Identity | Create, restore, rotate, and publish a public bundle |
| Device management | Record this device and mark it revoked |
| Contacts | Verify bundles, block, remove |
| Conversations | Local threads and unread counts |
| Messaging | Compose and read messages. An unknown sender is stored as a request until accepted |
| Encryption | Seal, open, sign, verify |
| Peer discovery | Accept signed bundles and file them in a Kademlia table |
| Networking | Report path, peers, relay, and network type |
| Transport | Move ciphertext bytes |
| Delivery queue | Persist outgoing payloads until a verified acknowledgement |
| Acknowledgements | Verify the recipient's signature before clearing the queue |
| Relay | Optional ciphertext fallback |
| Background execution | Retry when the runtime is allowed to run |
| Persistence | Migrations, foreign keys, transactions |
| Synchronization | Refresh public UI state after each durable change |

`TransportAdapter` is implemented by `WebRTCTransport`, `Libp2pTransport`, `WakuTransport`, and `LocalTransport`. `TransportRouter` tries an existing direct session, then a new direct session, then the relay if it is enabled, and otherwise returns `queued`.

Phones that are not on the same network share one bootstrap. The bootstrap remembers which public bundle is online and forwards WebRTC offers, answers, and ICE candidates. A sealed mailbox on that same host can move ciphertext when the data channel does not open. Neither store is a message database, and neither path counts as delivery until the recipient signs an acknowledgement.

## Phone apps

`native/android` and `native/ios` are the apps that run on a device. They do not embed the browser preview. Each one is a platform shell around the same node:

```text
Compose / SwiftUI → DirectNode → DeliveryEngine → PeerTransport (WebRTC data channel)
                              ↘ LocalStore       → AES-256-GCM snapshot file
                              ↘ IdentityVault    → SecretStore (Keystore or Keychain)
                              ↘ BootstrapClient  → WebSocket (OkHttp or URLSession)
```

`DirectNode` is the only place that changes identity, contacts, the queue, and delivery state. Android runs it on a single-thread dispatcher. iOS runs it on one actor. The platform supplies the secret store, the socket, and the data channel, and reports foreground, background, and network changes.

The bootstrap socket carries `hello`, `lookup`, `watch`, `offer`, `answer`, and `ice` from `contracts/signaling.json`. Envelope bytes cross the data channel only. The node behavior and the wire bytes are checked against `contracts/` from Kotlin (`:core:test`) and from Swift (`swift test` in `native/ios/DirectCore`). The device checklist is [native.md](../native.md).
