import XCTest
@testable import DirectCore

final class MediaTests: XCTestCase {
    private final class Links: PeerLinks {
        var reachable = true
        var sent: [Data] = []
        func isConnected(_ peerId: String) -> Bool { reachable }
        func connect(_ peerId: String) async -> Bool { reachable }
        func send(_ peerId: String, _ payload: Data) async -> Bool {
            guard reachable else { return false }
            sent.append(payload)
            return true
        }
    }

    private final class Clock {
        var now: Int64 = 1_000
    }

    @DirectActor
    private final class Device {
        let keys = IdentityKeys.generate()
        let deviceId = Encoding.newDeviceId()
        let bundle: PublicBundle
        let store = LocalStore.inMemory()
        let media: URL
        let engine: DeliveryEngine

        init(_ name: String, _ clock: Clock, _ links: PeerLinks, chunk: Int) {
            bundle = try! Bundles.create(keys: keys, displayName: name, deviceId: deviceId)
            media = FileManager.default.temporaryDirectory.appendingPathComponent("direct-media-\(name)-\(UUID().uuidString)", isDirectory: true)
            let keys = self.keys
            let deviceId = self.deviceId
            engine = DeliveryEngine(
                store: store, identity: { (keys, deviceId) }, links: links,
                clock: { clock.now }, random: { 0 }, ttlMs: 60_000, receiptTimeoutMs: 5_000,
                mediaDirectory: media, mediaChunkBytes: chunk
            )
        }

        func know(_ other: Device) {
            store.putContact(ContactRecord(
                directId: other.keys.directId, name: other.bundle.name, bundle: other.bundle.encode(),
                fingerprint: other.bundle.fingerprint, createdAt: 0
            ))
        }
    }

    func testAMediaNoteRoundtripsAndAProfileCardKeepsTheBundle() {
        let bytes = Data([1, 2, 3, 9, 0xFF])
        let part = MediaNotes.Part(mediaId: "med_1", kind: "image", mime: "image/jpeg", name: "a.jpg", part: 0, parts: 2, caption: "see you")
        let encoded = MediaNotes.encodePart(part, bytes)
        let decoded = MediaNotes.decodePart(encoded)
        XCTAssertEqual(part, decoded?.0)
        XCTAssertEqual(bytes, decoded?.1)
        XCTAssertNil(MediaNotes.decodePart(Encoding.utf8("hello")))
        XCTAssertEqual([3, 3, 2], MediaNotes.split(Data(repeating: 0, count: 8), chunkBytes: 3).map(\.count))

        let bundle = #"{"v":1,"name":"Ada","directId":"dir_X"}"#
        let card = ProfileCards.encode(bundle: bundle, status: "In the garden", avatarJpeg: Data([0xFF, 0xD8, 1]))
        let parsed = ProfileCards.parse(card)
        XCTAssertEqual(bundle, parsed.bundle)
        XCTAssertEqual("In the garden", parsed.status)
        XCTAssertEqual(3, parsed.avatarJpeg?.count)
        XCTAssertEqual(bundle, ProfileCards.parse(bundle).bundle)
    }

    func testAnOlderSnapshotStillOpens() throws {
        let json = """
        {"version":1,"profile":{"name":"Ada","deviceId":"dev","directId":"dir_X"},"settings":{},"contacts":[{"directId":"dir_Y","name":"Bo","bundle":"b","fingerprint":"f","createdAt":1}],"messages":[{"id":"m","peerId":"dir_Y","direction":"OUTGOING","body":"hi","createdAt":1,"state":"QUEUED","updatedAt":1}],"queue":[]}
        """
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(json.utf8))
        XCTAssertEqual("", snapshot.profile?.status)
        XCTAssertNil(snapshot.profile?.avatarJpegBase64)
        XCTAssertEqual("", snapshot.contacts.first?.about)
        XCTAssertNil(snapshot.messages.first?.mediaKind)
    }

    @DirectActor
    func testChunksAreSealedToThePeerAndReassembledOnce() async throws {
        let clock = Clock()
        let adaLinks = Links()
        let boLinks = Links()
        let ada = Device("Ada", clock, adaLinks, chunk: 4)
        let bo = Device("Bo", clock, boLinks, chunk: 4)
        ada.know(bo)
        bo.know(ada)
        let payload = Data([10, 11, 12, 13, 14, 15, 16])
        let message = try ada.engine.queueMedia(bo.keys.directId, kind: "image", mime: "image/jpeg", name: "pic.jpg", bytes: payload, caption: "sunset")
        XCTAssertEqual(.queued, ada.store.message(message.id)?.state)

        adaLinks.reachable = false
        try await ada.engine.flush()
        XCTAssertEqual(.queued, ada.store.message(message.id)?.state)
        XCTAssertEqual("Recipient unavailable", ada.store.message(message.id)?.lastError)
        XCTAssertTrue(adaLinks.sent.isEmpty)

        adaLinks.reachable = true
        clock.now += 1_000
        try await ada.engine.flush()
        XCTAssertEqual(.sent, ada.store.message(message.id)?.state)
        XCTAssertEqual(2, adaLinks.sent.count, "7 bytes at 4 per chunk")
        XCTAssertFalse(adaLinks.sent.contains { String(decoding: $0, as: UTF8.self).contains("sunset") })

        XCTAssertEqual(.stored, try bo.engine.receive(ada.keys.directId, adaLinks.sent[0]))
        XCTAssertNil(bo.store.message(message.id)?.mediaFile)
        XCTAssertEqual(.stored, try bo.engine.receive(ada.keys.directId, adaLinks.sent[1]))
        let file = try Data(contentsOf: bo.media.appendingPathComponent("\(message.id).bin"))
        XCTAssertEqual(payload, file)
        XCTAssertEqual("sunset", bo.store.message(message.id)?.body)
        try await bo.engine.flush()
        XCTAssertEqual(.receipt, try ada.engine.receive(bo.keys.directId, boLinks.sent.last!))
        XCTAssertEqual(.accepted, ada.store.message(message.id)?.state)
        XCTAssertFalse(bo.store.queue().contains { $0.id == message.id && MediaNotes.isJob($0.payload) })
    }
}
