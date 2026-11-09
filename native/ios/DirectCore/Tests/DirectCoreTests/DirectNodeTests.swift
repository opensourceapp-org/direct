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

        XCTAssertEqual(BootstrapUrl.defaultUrl, ada.state.bootstrapUrl)
        XCTAssertEqual(BootstrapUrl.defaultUrl, bo.state.bootstrapUrl)

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

    func testAnInboundMessageRaisesAnAlertTheAppCanShowWhileTheScreenIsOff() async throws {
        let ada = node(MemorySecretStore(), "ada-alert")
        let bo = node(MemorySecretStore(), "bo-alert")
        var alerts: [InboundAlert] = []
        bo.onInboundAlert = { alerts.append($0) }
        await ada.start()
        await bo.start()
        _ = try ada.createIdentity("Ada")
        _ = try bo.createIdentity("Bo")
        try ada.setBootstrap("10.0.0.9")
        try bo.setBootstrap("10.0.0.9")
        await settle()
        let adaId = ada.state.profile!.directId
        let boId = bo.state.profile!.directId
        try await ada.addContact(boId)
        try ada.send(boId, "Are you there?")
        await settle()
        XCTAssertEqual(1, alerts.count)
        XCTAssertEqual(adaId, alerts.first?.threadId)
        XCTAssertEqual("Ada", alerts.first?.title)
        XCTAssertEqual("Are you there?", alerts.first?.body)
        try bo.acceptRequest(adaId)
        await settle()
        try ada.setStatus("Out")
        await settle()
        XCTAssertEqual(1, alerts.count)
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

    func testASharedProfileSavesTheServer() async throws {
        let ada = node(MemorySecretStore(), "ada-share")
        let bo = node(MemorySecretStore(), "bo-share")
        await ada.start()
        await bo.start()
        _ = try ada.createIdentity("Ada")
        _ = try bo.createIdentity("Bo")
        let bundle = try XCTUnwrap(ada.state.bundle)
        let card = ProfileCards.encode(bundle: bundle, status: "Here", avatarJpeg: nil, bootstrap: "192.168.1.20")
        let added = try bo.addFromShare(card)
        XCTAssertEqual(ada.state.profile?.directId, added.directId)
        XCTAssertEqual("Here", added.about)
        XCTAssertEqual("ws://192.168.1.20:8787", bo.state.bootstrapUrl)
        await settle()
        XCTAssertEqual(.open, bo.state.bootstrap.phase)
        ada.close()
        bo.close()
    }

    func testAProfilePhotoReachesTheOtherPhoneAndCanBeCleared() async throws {
        let ada = node(MemorySecretStore(), "ada-photo")
        let bo = node(MemorySecretStore(), "bo-photo")
        await ada.start()
        await bo.start()
        _ = try ada.createIdentity("Ada")
        _ = try bo.createIdentity("Bo")
        try ada.setBootstrap("192.168.1.20")
        try bo.setBootstrap("192.168.1.20")
        await settle()
        let adaId = try XCTUnwrap(ada.state.profile?.directId)
        let boId = try XCTUnwrap(bo.state.profile?.directId)
        _ = try await ada.addContact(boId)
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])
        try ada.setAvatar(jpeg)
        try ada.setStatus("At work")
        await settle()
        let seen = try XCTUnwrap(bo.state.contacts.first { $0.directId == adaId })
        XCTAssertEqual(Encoding.base64Url(jpeg), seen.avatarJpegBase64)
        XCTAssertEqual("At work", seen.about)
        XCTAssertFalse(hub.received.contains { Encoding.base64Url(jpeg).contains($0) || $0.contains(Encoding.base64Url(jpeg)) })
        try ada.clearAvatar()
        await settle()
        XCTAssertNil(bo.state.contacts.first { $0.directId == adaId }?.avatarJpegBase64)
        ada.close()
        bo.close()
    }

    func testALoopbackBootstrapIsRefusedWithAPhoneSpecificMessage() async throws {
        let ada = node(MemorySecretStore(), "ada4")
        await ada.start()
        let error = await assertThrows(.invalidBootstrap) { try ada.setBootstrap("ws://localhost:8787") }
        XCTAssertTrue(error?.message.contains("the phone itself") == true)
        XCTAssertEqual(BootstrapUrl.defaultUrl, ada.state.bootstrapUrl)
        ada.close()
    }

    func testHostedBootstrapIsSavedOnFirstStart() async throws {
        let ada = node(MemorySecretStore(), "ada-hosted")
        await ada.start()
        XCTAssertEqual(BootstrapUrl.defaultUrl, ada.state.bootstrapUrl)
        ada.close()
    }

    func testAnAudioCallIsSealedOnTheDataChannel() async throws {
        let ada = node(MemorySecretStore(), "ada-call")
        let bo = node(MemorySecretStore(), "bo-call")
        await ada.start()
        await bo.start()
        _ = try ada.createIdentity("Ada")
        _ = try bo.createIdentity("Bo")
        _ = try ada.setBootstrap("192.168.1.20")
        _ = try bo.setBootstrap("192.168.1.20")
        await settle(300)
        let adaId = try XCTUnwrap(ada.state.profile?.directId)
        let boId = try XCTUnwrap(bo.state.profile?.directId)
        _ = try await ada.addContact(boId)
        await settle(300)
        try await bo.acceptRequest(adaId)
        await settle(300)

        try await ada.placeCall(boId, video: false)
        await settle(300)
        XCTAssertEqual(.incoming, bo.state.call?.phase)
        XCTAssertEqual(false, bo.state.call?.video)

        await bo.acceptCall()
        await settle(300)
        XCTAssertEqual(.connecting, ada.state.call?.phase)
        await ada.relayOffer("direct-call-offer")
        await settle(300)
        await bo.relayAnswer("direct-call-answer")
        ada.markCallLive()
        bo.markCallLive()
        await settle(300)
        XCTAssertEqual(.active, ada.state.call?.phase)
        XCTAssertEqual(.active, bo.state.call?.phase)
        XCTAssertFalse(hub.received.contains { $0.contains("direct-call-offer") || $0.contains("direct-call-answer") || $0.contains("\"op\":\"invite\"") })

        await ada.endCall()
        await settle(300)
        XCTAssertEqual(.ended, bo.state.call?.phase)
        XCTAssertTrue(ada.state.messages[boId]?.contains { $0.mediaKind == "call" && $0.body.hasPrefix("Audio call") } == true)
        XCTAssertTrue(bo.state.messages[adaId]?.contains { $0.mediaKind == "call" && $0.body.hasPrefix("Audio call") } == true)

        ada.dismissCall()
        bo.dismissCall()
        try await ada.placeCall(boId, video: true)
        await settle(300)
        XCTAssertEqual(true, bo.state.call?.video)
        await bo.endCall()
        await settle(300)
        XCTAssertEqual("Call declined", ada.state.call?.reason)
        XCTAssertEqual("Declined", bo.state.call?.reason)
        ada.close()
        bo.close()
    }

    func testCreatingAGroupListsItOnThisPhone() async throws {
        let ada = node(MemorySecretStore(), "ada-g")
        let bo = node(MemorySecretStore(), "bo-g")
        await ada.start()
        await bo.start()
        _ = try ada.createIdentity("Ada")
        _ = try bo.createIdentity("Bo")
        _ = try ada.setBootstrap("192.168.1.20")
        _ = try bo.setBootstrap("192.168.1.20")
        await settle(300)
        let boId = try XCTUnwrap(bo.state.profile?.directId)
        _ = try await ada.addContact(boId)
        await settle(300)
        let group = try ada.createGroup(name: "Weekend", memberIds: [boId])
        XCTAssertTrue(group.id.hasPrefix("grp_"))
        XCTAssertEqual("Weekend", ada.state.conversations.first { $0.group }?.name)
        XCTAssertEqual(2, ada.state.groups.first?.members.count)
        ada.close()
        bo.close()
    }

    func testAGroupMessageIsSealedToEachMember() async throws {
        let ada = node(MemorySecretStore(), "ada-gm")
        let bo = node(MemorySecretStore(), "bo-gm")
        await ada.start()
        await bo.start()
        _ = try ada.createIdentity("Ada")
        _ = try bo.createIdentity("Bo")
        _ = try ada.setBootstrap("192.168.1.20")
        _ = try bo.setBootstrap("192.168.1.20")
        await settle(300)
        let adaId = try XCTUnwrap(ada.state.profile?.directId)
        let boId = try XCTUnwrap(bo.state.profile?.directId)
        _ = try await ada.addContact(boId)
        await settle(300)
        try bo.acceptRequest(adaId)
        await settle(300)

        let group = try ada.createGroup(name: "Weekend", memberIds: [boId])
        await settle(300)
        XCTAssertEqual("Weekend", bo.state.conversations.first { $0.group }?.name)

        _ = try ada.send(group.id, "hello all")
        await settle(300)
        XCTAssertEqual("hello all", bo.state.messages[group.id]?.last?.body)
        XCTAssertEqual(adaId, bo.state.messages[group.id]?.last?.senderId)
        XCTAssertEqual(.accepted, ada.state.messages[group.id]?.first { $0.body == "hello all" }?.state)
        XCTAssertFalse(hub.received.contains { $0.contains("hello all") || $0.contains("DIRECT-GROUP/1") })

        _ = try bo.send(group.id, "hi from bo")
        await settle(300)
        XCTAssertEqual("hi from bo", ada.state.messages[group.id]?.last?.body)
        ada.close()
        bo.close()
    }

    func testAGroupAudioCallIsSealedToEachMember() async throws {
        let ada = node(MemorySecretStore(), "ada-gc")
        let bo = node(MemorySecretStore(), "bo-gc")
        await ada.start()
        await bo.start()
        _ = try ada.createIdentity("Ada")
        _ = try bo.createIdentity("Bo")
        _ = try ada.setBootstrap("192.168.1.20")
        _ = try bo.setBootstrap("192.168.1.20")
        await settle(300)
        let adaId = try XCTUnwrap(ada.state.profile?.directId)
        let boId = try XCTUnwrap(bo.state.profile?.directId)
        _ = try await ada.addContact(boId)
        await settle(300)
        try bo.acceptRequest(adaId)
        await settle(300)
        let group = try ada.createGroup(name: "Weekend", memberIds: [boId])
        await settle(300)

        try await ada.placeCall(group.id, video: false)
        await settle(300)
        XCTAssertEqual(.incoming, bo.state.call?.phase)
        XCTAssertEqual(true, bo.state.call?.group)
        XCTAssertEqual(group.id, bo.state.call?.peerId)

        await bo.acceptCall()
        await settle(300)
        XCTAssertEqual(.connecting, ada.state.call?.phase)
        await ada.relayOffer("group-offer", peerId: boId)
        await settle(300)
        await bo.relayAnswer("group-answer", peerId: adaId)
        ada.markCallLive()
        bo.markCallLive()
        await settle(300)
        XCTAssertEqual(.active, ada.state.call?.phase)
        XCTAssertFalse(hub.received.contains { $0.contains("group-offer") || $0.contains("group-answer") || $0.contains("\"op\":\"invite\"") })

        await ada.endCall()
        await settle(300)
        XCTAssertEqual(.ended, bo.state.call?.phase)
        XCTAssertTrue(ada.state.messages[group.id]?.contains { $0.mediaKind == "call" && $0.body.hasPrefix("Group audio") } == true)
        ada.close()
        bo.close()
    }
}
