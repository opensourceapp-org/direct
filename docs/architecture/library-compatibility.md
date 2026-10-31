# Library compatibility

Checked before integration. Versions move; this is the decision for this repository.

| Library | Decision |
| --- | --- |
| `@noble/curves`, `@noble/hashes`, `@noble/ciphers` | Used. Audited primitive implementations. They run under Node and in the browser. React Native needs `react-native-get-random-values` before the first call. |
| `@scure/bip39` | Used for the recovery phrase. |
| `@signalapp/libsignal-client` | Official Signal protocol library. It is a Node native addon and does not run on Hermes or in the browser. Not bundled. |
| `react-native-libsignal-client` | The practical native binding of libsignal. It needs a real iOS or Android build, not Expo Go. The `PeerCipher` boundary is where it should be connected. |
| `@privacyresearch/libsignal-protocol-typescript` | Not used. It is unmaintained and has an open trust-check bug. |
| `sql.js` | Used for the runnable database so migrations, foreign keys, and transactions can be tested here. The file is sealed with AES-256-GCM. |
| `@op-engineering/op-sqlite` with SQLCipher | Intended native database. It requires a native build and conflicts with other SQLite pods. Not linked in this preview. |
| `react-native-keychain` | Intended Keychain and Keystore adapter. Not linked in the browser preview. IndexedDB is labeled as such in Settings. |
| `react-native-webrtc` / browser `RTCPeerConnection` | `WebRTCTransport` is written against a small peer-connection interface and tested with an in-process connection. The browser preview attaches `RTCPeerConnection` with public STUN when a bootstrap socket is open. |
| `js-libp2p` and `@waku/sdk` | Not bundled. Current releases expect Node or browser APIs that Hermes does not provide, and pulling them in before a device spike would make the app depend on a stack we cannot run here. `Libp2pTransport` and `WakuTransport` are real adapters with in-process dial and relay doubles. |
| Kademlia | `KademliaTable` implements XOR distance and k-buckets for discovery records. It is not the libp2p kad-dht wire protocol. |

Expo Go is not a target, and neither is a WebView shell. The installable apps are `native/android` (Kotlin, Android Keystore, OkHttp, WebRTC, WorkManager) and `native/ios` (Swift, Keychain, URLSession, WebRTC, background refresh). They share `contracts/` with these TypeScript packages and still need a reachable `pnpm signaling` bootstrap. The libraries above describe the browser preview and the reference packages, not the phone apps. Phone primitives are BouncyCastle and JCA on Android, and CryptoKit (`swift-crypto` under test on Linux) on iOS.
