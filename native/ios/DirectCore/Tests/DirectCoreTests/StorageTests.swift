import XCTest
@testable import DirectCore

final class StorageTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("direct-store-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    func testTheIdentitySeedLivesOnlyInTheSecretStoreAndSurvivesARestart() throws {
        let secrets = MemorySecretStore()
        let (keys, phrase) = try IdentityVault(secrets).create()
        XCTAssertEqual([IdentityVault.seedName], secrets.names())
        let reloaded = try XCTUnwrap(try IdentityVault(secrets).load())
        XCTAssertEqual(keys.directId, reloaded.directId)
        XCTAssertEqual(phrase, try IdentityVault(secrets).recoveryPhrase())

        let elsewhere = MemorySecretStore()
        XCTAssertEqual(keys.directId, try IdentityVault(elsewhere).restore(phrase).directId)
        XCTAssertEqual(try Mnemonic.toSeed(phrase), try elsewhere.read(IdentityVault.seedName))
    }

    func testTheStorageKeyIsCreatedOnceAndKeptInTheSecretStore() throws {
        let secrets = MemorySecretStore()
        let first = try IdentityVault(secrets).storageKey()
        XCTAssertEqual(first, try IdentityVault(secrets).storageKey())
        XCTAssertEqual(32, first.count)
        try IdentityVault(secrets).erase()
        XCTAssertNil(try secrets.read(IdentityVault.storeKeyName))
    }

    func testAFailingPlatformStoreIsSurfacedNeverReplacedWithPlainStorage() {
        final class Broken: SecretStore {
            struct Unavailable: Error {}
            func read(_ name: String) throws -> Data? { throw Unavailable() }
            func write(_ name: String, _ value: Data) throws { throw Unavailable() }
            func delete(_ name: String) throws {}
        }
        XCTAssertThrowsError(try IdentityVault(Broken()).create())
        XCTAssertThrowsError(try IdentityVault(Broken()).storageKey())
    }

    func testTheQueueAndMessagesPersistEncryptedAndReloadAfterARestart() throws {
        let file = dir.appendingPathComponent("direct.store")
        let key = Encoding.randomBytes(32)
        let store = try LocalStore.open(file: file, key: key)
        store.putContact(ContactRecord(directId: "dir_ABCDEFGHJKMNPQRS", name: "Bo", bundle: "{}", fingerprint: "FP", createdAt: 1))
        store.putMessage(MessageRecord(id: "msg_1", peerId: "dir_ABCDEFGHJKMNPQRS", direction: .outgoing, body: "meet at noon", createdAt: 10, state: .queued))
        store.putQueued(QueueItem(id: "msg_1", peerId: "dir_ABCDEFGHJKMNPQRS", kind: .message, payload: "{sealed}", attempts: 2, nextAttemptAt: 50, expiresAt: 999))
        try store.save()

        let raw = Encoding.text(try Data(contentsOf: file))
        XCTAssertFalse(raw.contains("meet at noon"))
        XCTAssertFalse(raw.contains("dir_ABCDEFGHJKMNPQRS"))
        XCTAssertEqual(["direct.store"], try FileManager.default.contentsOfDirectory(atPath: dir.path))

        let reopened = try LocalStore.open(file: file, key: key)
        XCTAssertEqual("meet at noon", reopened.message("msg_1")?.body)
        XCTAssertEqual(.queued, reopened.message("msg_1")?.state)
        XCTAssertEqual(2, reopened.queued("msg_1")?.attempts)
        XCTAssertEqual(50, reopened.queued("msg_1")?.nextAttemptAt)
    }

    func testAWrongKeyFailsLoudlyAndLeavesTheFileIntact() throws {
        let file = dir.appendingPathComponent("other.store")
        let store = try LocalStore.open(file: file, key: Encoding.randomBytes(32))
        store.putMessage(MessageRecord(id: "m", peerId: "p", direction: .incoming, body: "x", createdAt: 1))
        try store.save()
        let before = try Data(contentsOf: file)
        XCTAssertThrowsError(try LocalStore.open(file: file, key: Encoding.randomBytes(32))) { error in
            XCTAssertTrue(error is SealError)
        }
        XCTAssertEqual(before, try Data(contentsOf: file))
    }
}
