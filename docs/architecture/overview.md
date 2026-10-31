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
