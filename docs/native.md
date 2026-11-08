# Native apps

Phones run DIRECT as a native app. Android is Kotlin in `native/android`. iOS is Swift in `native/ios`. Both call the same behavior: a device-held identity, a sealed local queue, and a data channel to the other phone. The bootstrap is only used to publish a public bundle, report presence, and forward WebRTC offers, answers, and ICE candidates. Message text is never written to it.

`apps/mobile` is the browser preview and the TypeScript reference that produced `contracts/`. It is not the app that goes on a phone.

## Signaling server

On a computer both phones can reach, download Direct Server for macOS, Windows, or Linux from [direct-server.apps.grok.bot](https://direct-server.apps.grok.bot). Open it, press Start server, and share the `ws://` address it shows. The window lists each phone that connects. Builds are tagged on GitHub, starting at [v0.1.0](https://github.com/opensourceapp-org/direct/releases/tag/v0.1.0).

To run the same window from source:

```bash
git clone https://github.com/opensourceapp-org/direct.git
cd direct
pnpm install
pnpm server
```

`pnpm server` downloads the desktop app the first time, then opens it. On a Mac, double-click `Start Server.command` in the project folder. `Direct.app` is the iPhone build. macOS will not open that file. `pnpm signaling` runs the same server in the terminal and prints those addresses. The steps are also on the page in `site/index.html`.

```bash
pnpm signaling
```

The process listens on `0.0.0.0:8787` (`HOST` and `PORT` override those). It prints one `ws://<LAN address>:8787` line per network interface. `GET /health` returns `{ "ok": true, "service": "direct-signaling" }`.

Open TCP 8787 on that computer's firewall. If the phones are not on the same LAN, use an address both can route to (a public host, or a tunnel that forwards 8787) and put that address on both phones. `localhost`, `127.0.0.1`, and `0.0.0.0` are rejected: on a phone, localhost is the phone.

Both phones must save the same bootstrap, for example `ws://192.168.1.20:8787`. The Network screen normalizes a bare host to `ws://` and port 8787, lowercases the host, and strips a trailing slash. `http://` becomes `ws://` and `https://` becomes `wss://`.

## What each phone does

1. Create an identity. The 32-byte seed is generated on the device. Android stores it with an Android Keystore AES-256-GCM key in `noBackupFilesDir`. iOS stores it in the Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`) and, on a device with a Secure Enclave, wraps it to a non-exportable enclave key. The recovery phrase is BIP-39, 24 words, and is shown once.
2. Set the bootstrap to the address printed by `pnpm signaling`.
3. On one phone, add the other by DIRECT ID. The lookup reads the public bundle the other phone announced. Pasting that bundle skips the lookup.
4. Send. The envelope is sealed and queued before any network attempt. If the other phone is closed, the row stays `Queued` and retries with backoff.
5. The recipient sees a message request. Accepting it sends read receipts. Declining it blocks that DIRECT ID.
6. A profile photo and status are sealed to each accepted contact when they change, when you add or accept that contact, and again when a queued update is still waiting and that phone becomes reachable. The picture is not part of the signed bundle, and the bootstrap never receives it. Android applies the photo's EXIF orientation before saving it, so a portrait shot stays portrait. The chat header places the photo to the left of the name, with the status on the line under the name.
7. An accepted chat has an audio call button and a video call button. The invite, the answer, and the call's own addresses are sealed on the data channel. A second peer connection carries the microphone and, for video, the camera. The bootstrap never hears the call. Both phones have to be open and already able to reach each other. A call is not queued. If the other phone is closed, the row says Unreachable and a message can still wait on this phone. A missed call stays in the chat. The phone rings for 45 seconds.

Outgoing states, in order: Queued, Sending, Sent (written to the data channel), Delivered (the recipient stored it and signed an `ack`, including when it is still a request), Read (the recipient accepted the conversation and opened it). Failed means the envelope expired or the contact was blocked; tap it to seal a fresh envelope under the same id.

## Android Studio

Requirements: JDK 17 or newer, Android SDK 35, a device or emulator on API 26 or newer.

```bash
cd native/android
# local.properties is gitignored; Android Studio writes sdk.dir, or:
echo "sdk.dir=$ANDROID_HOME" > local.properties
./gradlew :core:test :app:assembleDebug
```

Open `native/android` in Android Studio and run the `app` configuration. The debug APK is `app/build/outputs/apk/debug/app-debug.apk`. Cleartext `ws://` is allowed by `network_security_config.xml` so a LAN bootstrap works. Use `wss://` for a public bootstrap and tighten that config.

The app process owns one `DirectNode` on a single-thread dispatcher. Foreground reconnects the bootstrap immediately. Background schedules a WorkManager pass (a one-shot retry and a 15-minute periodic job that requires a network).

## Xcode

Requirements: a Mac with Xcode 16 or newer, and an Apple Developer team for a physical device. The Simulator has no Secure Enclave; secrets then stay in the Keychain only.

Open `native/ios/Direct.xcodeproj`. The project file is in the repository, so there is nothing to generate first. Set the team under Signing & Capabilities, pick a device, and run. Swift Package Manager fetches `DirectCore` from `native/ios/DirectCore` and `stasel/WebRTC` 156.0.0 on the first build.

`App.xcodeproj` was the previous shell and is not part of this tree. A checkout that still has `apps/mobile/ios/App/App.xcodeproj` on disk, without `project.pbxproj` inside it, makes Xcode say the project does not contain a project definition file. Close that window and delete the leftover `apps/mobile/ios` directory. `project.yml` is only for regenerating `Direct.xcodeproj` with XcodeGen after the spec changes.

`Info.plist` allows local networking and cleartext `ws://` for a development bootstrap, and registers `app.direct.messaging.delivery` as a `BGAppRefreshTask`. iOS decides when that task runs. Leaving the app also starts a short background flush. There is no push service, so a suspended or force-quit app cannot receive.

`DirectCore` itself builds on Linux:

```bash
cd native/ios/DirectCore
swift test
```

## Checks that run without a phone

| Check | Command | What it locks |
| --- | --- | --- |
| Bootstrap URL rules | Kotlin `ContractTest`, Swift `ContractTests` | `contracts/bootstrap-url.json`, including the loopback refusal |
| Signaling frames | same | `contracts/signaling.json`. Forbidden frame kinds decode to nothing |
| Wire bytes | same | `contracts/vectors.json` against the TypeScript packages |
| Queue persistence | `StorageTest` / `StorageTests` | AES-256-GCM file, atomic replace, wrong key leaves the file untouched |
| Secret store | same | Seed and store key go through `SecretStore`. A throwing store is not replaced with a plain file |
| Ack and retry | `DeliveryTest` / `DeliveryTests` | Queued → Sending → Sent → Accepted → Acknowledged, plus timeout, expiry, restart recovery, duplicates |
| Two devices | `DirectNodeTest` / `DirectNodeTests` | Offline queue, restart, request, accept, reply. The fake bootstrap's log contains no message text |

## Checks that need devices

This repository's CI environment can compile the Android debug APK and run the Kotlin and Swift test suites. It cannot run Xcode, and it has no phones. Before calling a build shipped, do these on two real devices:

1. Install one Android build and one iOS build, or two of either.
2. Run `pnpm signaling`. Confirm both phones save the identical `ws://<host>:8787` and show Connected.
3. Create an identity on each. Confirm the seed is absent from app storage you can read (no SharedPreferences, no UserDefaults, no plain file). Confirm the recovery phrase restores the same DIRECT ID on a reinstall.
4. Put the recipient in airplane mode. Send. Force-quit the sender, reopen it, and confirm the message is still Queued with its text. Turn the recipient on and confirm it arrives as a request, then becomes Delivered, then Read after Accept.
5. Decline a second request and confirm a later message from that DIRECT ID is not shown.
6. Capture the bootstrap traffic (the signaling log, or a proxy). Confirm it contains hello, lookup, watch, offer, answer, and ice, and none of the message text.
7. Move both phones to mobile data. If the data channel stays Queued, the path is symmetric NAT. Add a TURN server you operate to `WebRtcTransport.DEFAULT_ICE` (Android) and `WebRTCTransport.defaultIceServers` (iOS). TURN carries DTLS ciphertext and cannot read it. A public STUN server is the default and is not enough for every network.

## Limits

- Photos, video, GIFs, stickers, and voice notes are sealed in the same envelopes as text, in chunks, up to 6 MB. The bootstrap never sees those bytes. Video is not transcoded: a file over 6 MB is refused. The sticker tray is a pack of 16 drawings, the same on both phones. Android voice notes show a live waveform while recording and while playing.
- A QR code carries the signed identity bundle, the bootstrap server address, plus an optional status and a small photo. The status and photo are display-only. They are not part of the signature. Scanning one adds the contact without a lookup and saves that server address when the card includes one. Share sends a picture of that code with the name, DIRECT ID, and server address written on it. The signed bundle stays inside the code.
- The first launch shows a short explanation of how two phones talk. It is not shown again after the person finishes it.
- The seal is one-shot X25519 + HKDF-SHA256 + AES-256-GCM. It is not the Signal Double Ratchet.
- The local store is one encrypted snapshot file, not a SQL database.
- Writing to the data channel is Sent. Delivered requires the recipient's signed `ack`.
- A closed app cannot receive. Android retries while WorkManager is allowed to run. iOS retries on the next foreground or background refresh. A call is live only: there is no push, so a force-quit phone cannot ring. Android keeps a call notification so the microphone can stay on while the screen is locked. iOS keeps the audio session while the app is in the background. The same STUN servers are used. A symmetric NAT still needs a TURN server you operate, or the call stays on Connecting.
