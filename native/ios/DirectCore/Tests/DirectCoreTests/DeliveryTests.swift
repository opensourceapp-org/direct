import XCTest
@testable import DirectCore

final class StateMachineTests: XCTestCase {
    private func path(_ events: DeliveryEvent...) -> MessageState? {
        events.reduce(MessageState.queued as MessageState?) { state, event in state.flatMap { DeliveryStateMachine.next($0, event) } }
    }

    func testHappyPathIsQueuedSendingSentAcceptedAcknowledged() {
        XCTAssertEqual(.sending, path(.attempt))
        XCTAssertEqual(.sent, path(.attempt, .written))
        XCTAssertEqual(.accepted, path(.attempt, .written, .deliveryReceipt))
        XCTAssertEqual(.acknowledged, path(.attempt, .written, .deliveryReceipt, .readReceipt))
    }

    func testOfflineAndTimeoutGoBackToQueuedForRetry() {
        XCTAssertEqual(.queued, path(.attempt, .unreachable))
        XCTAssertEqual(.queued, path(.attempt, .written, .receiptTimeout))
        XCTAssertEqual(.sent, path(.attempt, .unreachable, .attempt, .written))
    }

    func testRestartRecoveryRequeuesAnythingInFlight() {
        XCTAssertEqual(.queued, DeliveryStateMachine.next(.sending, .recovered))
        XCTAssertEqual(.queued, DeliveryStateMachine.next(.sent, .recovered))
        XCTAssertNil(DeliveryStateMachine.next(.queued, .recovered))
        XCTAssertNil(DeliveryStateMachine.next(.accepted, .recovered))
    }

    func testExpiryAndBlockingFailOnlyMessagesStillAwaitingAReceipt() {
        for state in [MessageState.queued, .sending, .sent] {
            XCTAssertEqual(.failed, DeliveryStateMachine.next(state, .expired))
            XCTAssertEqual(.failed, DeliveryStateMachine.next(state, .rejected))
        }
        XCTAssertNil(DeliveryStateMachine.next(.accepted, .expired))
        XCTAssertNil(DeliveryStateMachine.next(.acknowledged, .rejected))
        XCTAssertEqual(.queued, DeliveryStateMachine.next(.failed, .retry))
        XCTAssertNil(DeliveryStateMachine.next(.queued, .retry))
    }

    func testLateReceiptsStillCountAndNothingLeavesAcknowledged() {
        XCTAssertEqual(.accepted, DeliveryStateMachine.next(.queued, .deliveryReceipt))
        XCTAssertEqual(.accepted, DeliveryStateMachine.next(.failed, .deliveryReceipt))
        XCTAssertEqual(.acknowledged, DeliveryStateMachine.next(.sent, .readReceipt))
        XCTAssertNil(DeliveryStateMachine.next(.accepted, .deliveryReceipt))
        for event in DeliveryEvent.allCases { XCTAssertNil(DeliveryStateMachine.next(.acknowledged, event)) }
        XCTAssertNil(DeliveryStateMachine.next(.sent, .attempt))
        XCTAssertNil(DeliveryStateMachine.next(.queued, .written))
    }
}

@DirectActor
final class DeliveryEngineTests: XCTestCase {
    private final class Links: PeerLinks {
        var reachable = false
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
        let engine: DeliveryEngine

        init(_ name: String, _ clock: Clock, _ links: PeerLinks) {
            bundle = try! Bundles.create(keys: keys, displayName: name, deviceId: deviceId)
            let keys = self.keys
            let deviceId = self.deviceId
            engine = DeliveryEngine(
                store: store, identity: { (keys, deviceId) }, links: links,
                clock: { clock.now }, random: { 0 }, ttlMs: 60_000, receiptTimeoutMs: 5_000
            )
        }

        func know(_ other: Device, accepted: Bool = true) {
            store.putContact(ContactRecord(
                directId: other.keys.directId, name: other.bundle.name, bundle: other.bundle.encode(),
                fingerprint: other.bundle.fingerprint, accepted: accepted, createdAt: 0
            ))
        }
    }

    func testOfflineRecipientKeepsTheMessageQueuedWithGrowingBackoff() async throws {
        let clock = Clock()
        let ada = Device("Ada", clock, Links())
        let bo = Device("Bo", clock, Links())
        ada.know(bo)
        let message = try ada.engine.queueText(bo.keys.directId, "hello")
        XCTAssertEqual(.queued, ada.store.message(message.id)?.state)

        try await ada.engine.flush()
        let first = try XCTUnwrap(ada.store.queued(message.id))
        XCTAssertEqual(.queued, ada.store.message(message.id)?.state)
        XCTAssertEqual(1, first.attempts)
        XCTAssertEqual(clock.now + 1_000, first.nextAttemptAt)
        XCTAssertEqual("Recipient unavailable", first.lastError)

        clock.now += 1_000
        try await ada.engine.flush()
        XCTAssertEqual(clock.now + 2_000, ada.store.queued(message.id)?.nextAttemptAt)

        try ada.engine.peerOnline(bo.keys.directId)
        XCTAssertEqual(clock.now, ada.store.queued(message.id)?.nextAttemptAt)
    }

    func testWrittenIsSentAckIsAcceptedReadIsAcknowledged() async throws {
        let clock = Clock()
        let adaLinks = Links()
        adaLinks.reachable = true
        let boLinks = Links()
        boLinks.reachable = true
        let ada = Device("Ada", clock, adaLinks)
        let bo = Device("Bo", clock, boLinks)
        ada.know(bo)
        bo.know(ada, accepted: false)
        let message = try ada.engine.queueText(bo.keys.directId, "hello")
        try await ada.engine.flush()
        XCTAssertEqual(.sent, ada.store.message(message.id)?.state)

        XCTAssertEqual(.stored, try bo.engine.receive(ada.keys.directId, adaLinks.sent.last!))
        XCTAssertEqual("hello", bo.store.message(message.id)?.body)
        try await bo.engine.flush()
        XCTAssertEqual(.receipt, try ada.engine.receive(bo.keys.directId, boLinks.sent.last!))
        XCTAssertEqual(.accepted, ada.store.message(message.id)?.state)
        XCTAssertNil(ada.store.queued(message.id))

        XCTAssertEqual(0, try bo.engine.markRead(ada.keys.directId), "an unaccepted request sends no read receipt")
        var contact = bo.store.contact(ada.keys.directId)!
        contact.accepted = true
        bo.store.putContact(contact)
        XCTAssertEqual(1, try bo.engine.markRead(ada.keys.directId))
        try await bo.engine.flush()
        XCTAssertEqual(.receipt, try ada.engine.receive(bo.keys.directId, boLinks.sent.last!))
        XCTAssertEqual(.acknowledged, ada.store.message(message.id)?.state)
        XCTAssertTrue(bo.store.queue().isEmpty, "receipts leave the queue once written")
    }

    func testNoReceiptMeansResendAndTheDuplicateIsAckedWithoutASecondCopy() async throws {
        let clock = Clock()
        let adaLinks = Links()
        adaLinks.reachable = true
        let boLinks = Links()
        boLinks.reachable = true
        let ada = Device("Ada", clock, adaLinks)
        let bo = Device("Bo", clock, boLinks)
        ada.know(bo)
        bo.know(ada)
        let message = try ada.engine.queueText(bo.keys.directId, "again")
        try await ada.engine.flush()
        _ = try bo.engine.receive(ada.keys.directId, adaLinks.sent.last!)

        clock.now += 5_000
        try await ada.engine.flush()
        XCTAssertEqual(.queued, ada.store.message(message.id)?.state)
        clock.now += 1_000
        try await ada.engine.flush()
        XCTAssertEqual(.sent, ada.store.message(message.id)?.state)
        XCTAssertEqual(2, adaLinks.sent.count)
        XCTAssertEqual(.duplicate, try bo.engine.receive(ada.keys.directId, adaLinks.sent.last!))
        XCTAssertEqual(1, bo.store.messagesWith(ada.keys.directId).count)
    }

    func testExpiryFailsTheMessageAndRetryRequeuesItWithAFreshEnvelope() async throws {
        let clock = Clock()
        let ada = Device("Ada", clock, Links())
        let bo = Device("Bo", clock, Links())
        ada.know(bo)
        let message = try ada.engine.queueText(bo.keys.directId, "late")
        clock.now += 60_000
        try await ada.engine.flush()
        XCTAssertEqual(.failed, ada.store.message(message.id)?.state)
        XCTAssertNil(ada.store.queued(message.id))
        XCTAssertTrue(try ada.engine.retry(message.id))
        XCTAssertEqual(.queued, ada.store.message(message.id)?.state)
        XCTAssertEqual(clock.now + 60_000, ada.store.queued(message.id)?.expiresAt)
    }

    func testRestartRecoveryRequeuesSentMessagesForAnImmediateRetry() async throws {
        let clock = Clock()
        let links = Links()
        links.reachable = true
        let ada = Device("Ada", clock, links)
        let bo = Device("Bo", clock, Links())
        ada.know(bo)
        let message = try ada.engine.queueText(bo.keys.directId, "in flight")
        try await ada.engine.flush()
        XCTAssertEqual(.sent, ada.store.message(message.id)?.state)
        try ada.engine.recover()
        XCTAssertEqual(.queued, ada.store.message(message.id)?.state)
        XCTAssertNil(ada.store.queued(message.id)?.sentAt)
        XCTAssertEqual(clock.now, ada.engine.nextWakeAt())
    }

    func testBlockedSendersAndForgedEnvelopesAreIgnored() async throws {
        let clock = Clock()
        let adaLinks = Links()
        adaLinks.reachable = true
        let ada = Device("Ada", clock, adaLinks)
        let bo = Device("Bo", clock, Links())
        let eve = Device("Eve", clock, Links())
        ada.know(bo)
        bo.know(ada)
        bo.know(eve)
        _ = try ada.engine.queueText(bo.keys.directId, "hi")
        try await ada.engine.flush()
        let bytes = adaLinks.sent.last!
        XCTAssertEqual(.ignored, try bo.engine.receive(eve.keys.directId, bytes), "claimed sender must match the channel")
        var contact = bo.store.contact(ada.keys.directId)!
        contact.blocked = true
        bo.store.putContact(contact)
        XCTAssertEqual(.ignored, try bo.engine.receive(ada.keys.directId, bytes))
        contact.blocked = false
        bo.store.putContact(contact)
        let forged = Encoding.text(bytes).replacingOccurrences(of: "\"signature\":\"", with: "\"signature\":\"A")
        XCTAssertEqual(.ignored, try bo.engine.receive(ada.keys.directId, Encoding.utf8(forged)))
        XCTAssertEqual(.stored, try bo.engine.receive(ada.keys.directId, bytes))
    }

    func testAGroupTextIsFannedOutAndAcceptedWhenEveryMemberAcks() async throws {
        let clock = Clock()
        let adaLinks = Links(); adaLinks.reachable = true
        let boLinks = Links(); boLinks.reachable = true
        let cyLinks = Links(); cyLinks.reachable = true
        let ada = Device("Ada", clock, adaLinks)
        let bo = Device("Bo", clock, boLinks)
        let cy = Device("Cy", clock, cyLinks)
        ada.know(bo)
        ada.know(cy)
        bo.know(ada)
        bo.know(cy)
        cy.know(ada)
        cy.know(bo)
        let members = [ada.keys.directId, bo.keys.directId, cy.keys.directId]
        let group = GroupRecord(id: "grp_" + String(repeating: "ab", count: 16), name: "Weekend", members: members, createdBy: ada.keys.directId, createdAt: clock.now)
        ada.store.putGroup(group)
        bo.store.putGroup(group)
        cy.store.putGroup(group)

        try ada.engine.queueGroupInvite(group, ada.keys.directId)
        try await ada.engine.flush()
        func deliver(_ to: Device, _ from: Device, _ payloads: [Data]) throws {
            for payload in payloads {
                guard let header = Envelopes.peek(payload), header.to == to.keys.directId, header.from == from.keys.directId else { continue }
                _ = try to.engine.receive(from.keys.directId, payload)
            }
        }
        try deliver(bo, ada, adaLinks.sent)
        try deliver(cy, ada, adaLinks.sent)
        XCTAssertEqual("Weekend", bo.store.group(group.id)?.name)

        adaLinks.sent.removeAll()
        let message = try ada.engine.queueGroupText(group, ada.keys.directId, "hello all")
        XCTAssertEqual("hello all", GroupNotes.parsePrefixed(GroupNotes.encodeText(groupId: group.id, mid: message.id, body: "hello all"))?.body)
        XCTAssertEqual(2, ada.store.queue().filter { $0.messageId == message.id }.count)
        try await ada.engine.flush()
        XCTAssertEqual(.sent, ada.store.message(message.id)?.state)
        XCTAssertEqual(2, adaLinks.sent.count)
        let toBo = try XCTUnwrap(adaLinks.sent.first { Envelopes.peek($0)?.to == bo.keys.directId })
        let opened = Encoding.text(try Envelopes.open(recipient: bo.keys, envelope: try Envelopes.decode(toBo, senderSigningPublic: ada.keys.signingPublic, now: clock.now)))
        XCTAssertEqual("hello all", GroupNotes.parsePrefixed(opened)?.body, opened)
        XCTAssertEqual(.stored, try bo.engine.receive(ada.keys.directId, toBo))
        let toCy = try XCTUnwrap(adaLinks.sent.first { Envelopes.peek($0)?.to == cy.keys.directId })
        XCTAssertEqual(.stored, try cy.engine.receive(ada.keys.directId, toCy))
        let hello = try XCTUnwrap(bo.store.messagesWith(group.id).first { $0.body == "hello all" })
        XCTAssertEqual(ada.keys.directId, hello.senderId)
        XCTAssertNil(GroupNotes.parsePrefixed("DIRECT-GROUP/1\n{}"))
        try await bo.engine.flush()
        try await cy.engine.flush()
        XCTAssertEqual(.receipt, try ada.engine.receive(bo.keys.directId, boLinks.sent.last!))
        XCTAssertEqual(.sent, ada.store.message(message.id)?.state)
        XCTAssertEqual(.receipt, try ada.engine.receive(cy.keys.directId, cyLinks.sent.last!))
        XCTAssertEqual(.accepted, ada.store.message(message.id)?.state)
        XCTAssertFalse(ada.store.queue().contains { $0.logicalId() == message.id })
    }
}
