import XCTest
@testable import DirectCore

/// Two devices end to end over the fake bootstrap and fake data channel, in real time with short timeouts.
@DirectActor
final class DirectNodeTests: XCTestCase {
    private let dir = FileManager.default.temporaryDirectory.appendingPathComponent("direct-node-\(UUID().uuidString)")
    private let hub = FakeHub()
    private let network = FakePeerNetwork()

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func node(_ secrets: MemorySecretStore, _ name: String) -> DirectNode {
        var timing = DirectNode.Timing()
        timing.connectWaitMs = 200
        timing.lookupRetryMs = 200
        timing.bootstrap.retryBaseMs = 100
        timing.bootstrap.offerUnreachableWaitMs = 50
        timing.bootstrap.lookupTimeoutMs = 200
        let network = network
        return DirectNode(
            secrets: secrets,
            storeFile: dir.appendingPathComponent("\(name).store"),
            sockets: hub,
            transportFactory: { network.transport($0, $1) },
            random: { 0 },
            timing: timing
        )
    }

    private func settle(_ ms: Int64 = 150) async { await sleepMs(ms) }

    private func assertThrows(_ reason: DirectError.Reason, _ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async -> DirectError? {
        do {
            try await body()
            XCTFail("expected \(reason)", file: file, line: line)
        } catch let error as DirectError {
            XCTAssertEqual(reason, error.reason, file: file, line: line)
            return error
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
        return nil
    }

    func testAMessageToAnOfflinePhoneWaitsSurvivesRestartsArrivesAsARequestAndIsAcknowledged() async throws {
        let adaSecrets = MemorySecretStore()
        let boSecrets = MemorySecretStore()
        var ada = node(adaSecrets, "ada")
        var bo = node(boSecrets, "bo")
        await ada.start()
        await bo.start()
        _ = try ada.createIdentity("Ada")
        _ = try bo.createIdentity("Bo")
        let adaId = ada.state.profile!.directId
        let boId = bo.state.profile!.directId

        _ = await assertThrows(.noBootstrap) { try await ada.addContact(boId) }

        XCTAssertEqual("ws://192.168.1.20:8787", try ada.setBootstrap("192.168.1.20"))
        XCTAssertEqual("ws://192.168.1.20:8787", try bo.setBootstrap("ws://192.168.1.20:8787/"))
        await settle()
        XCTAssertEqual(.open, ada.state.bootstrap.phase)

        _ = await assertThrows(.notFound) { try await ada.addContact("dir_0123456789ABCDEH") }
        try await ada.addContact(boId.lowercased().replacingOccurrences(of: "dir_", with: "DIR_"))
        XCTAssertEqual(true, ada.state.contacts.first?.accepted)

        bo.close()
        await settle()
        try ada.send(boId, "Hello from Ada")
        await settle()
        let queued = try XCTUnwrap(ada.state.messages[boId]?.first)
        XCTAssertEqual(.queued, queued.state)
        XCTAssertEqual("Recipient unavailable", queued.lastError)

        ada.close()
        ada = node(adaSecrets, "ada")
        await ada.start()
        await settle()
        XCTAssertEqual(adaId, ada.state.profile?.directId)
        XCTAssertEqual(.queued, ada.state.messages[boId]?.first?.state)
        XCTAssertEqual("Hello from Ada", ada.state.messages[boId]?.first?.body)

        bo = node(boSecrets, "bo")
        await bo.start()
        await settle(400)
        XCTAssertEqual(.accepted, ada.state.messages[boId]?.first?.state)
        let request = try XCTUnwrap(bo.state.conversations.first)
        XCTAssertEqual(adaId, request.peerId)
        XCTAssertTrue(request.request)
        XCTAssertEqual("Hello from Ada", bo.state.messages[adaId]?.first?.body)
        _ = await assertThrows(.notAccepted) { try bo.send(adaId, "too soon") }

        try bo.acceptRequest(adaId)
        await settle()
        XCTAssertEqual(.acknowledged, ada.state.messages[boId]?.first?.state)

        try bo.send(adaId, "Hi Ada")
        await settle()
        let reply = try XCTUnwrap(ada.state.messages[boId]?.last)
        XCTAssertEqual(.incoming, reply.direction)
        XCTAssertEqual("Hi Ada", reply.body)
        XCTAssertEqual(.accepted, bo.state.messages[adaId]?.last?.state)

        XCTAssertFalse(hub.frames().contains { $0.contains("Hello from Ada") || $0.contains("Hi Ada") }, "the bootstrap never sees message text")
        ada.close()
        bo.close()
    }

    func testDecliningARequestBlocksTheSender() async throws {
        let ada = node(MemorySecretStore(), "ada2")
        let bo = node(MemorySecretStore(), "bo2")
        await ada.start()
        await bo.start()
        _ = try ada.createIdentity("Ada")
        _ = try bo.createIdentity("Bo")
        try ada.setBootstrap("10.0.0.5")
        try bo.setBootstrap("10.0.0.5")
        await settle()
        let adaId = ada.state.profile!.directId
        let boId = bo.state.profile!.directId
        try await ada.addContact(boId)
        try ada.send(boId, "first")
        await settle()
        try bo.declineRequest(adaId)
        await settle()
        XCTAssertTrue(bo.state.conversations.isEmpty)
        try ada.send(boId, "second")
        await settle()
        XCTAssertEqual(["first"], bo.state.messages[adaId]?.map(\.body))
        ada.close()
        bo.close()
    }

    func testADisconnectedBootstrapIsReportedAsOfflineNotAsAMissingPhone() async throws {
        let ada = node(MemorySecretStore(), "ada3")
        await ada.start()
        _ = try ada.createIdentity("Ada")
        hub.reachable = false
        try ada.setBootstrap("192.168.1.20")
        await settle()
        let error = await assertThrows(.bootstrapOffline) { try await ada.addContact("dir_ABCDEFGHJKMNPQRS") }
        XCTAssertTrue(error?.message.contains("ws://192.168.1.20:8787") == true)
        hub.reachable = true
        ada.onNetworkAvailable()
        await settle()
        XCTAssertEqual(.open, ada.state.bootstrap.phase)
        ada.close()
    }

    func testALoopbackBootstrapIsRefusedWithAPhoneSpecificMessage() async throws {
        let ada = node(MemorySecretStore(), "ada4")
        await ada.start()
        let error = await assertThrows(.invalidBootstrap) { try ada.setBootstrap("ws://localhost:8787") }
        XCTAssertTrue(error?.message.contains("the phone itself") == true)
        XCTAssertNil(ada.state.bootstrapUrl)
        ada.close()
    }
}
