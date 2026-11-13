import XCTest
@testable import DirectCore

@DirectActor
final class BootstrapClientTests: XCTestCase {
    private let ada = "dir_0123456789ABCDEF"
    private let bo = "dir_ABCDEFGHJKMNPQRS"
    private func bundle(_ id: String) -> String { #"{"v":1,"name":"Phone","directId":"\#(id)","note":"public"}"# }

    private func client(_ hub: FakeHub) -> BootstrapClient {
        var timing = BootstrapClient.Timing()
        timing.retryBaseMs = 100
        timing.offerUnreachableWaitMs = 100
        timing.lookupTimeoutMs = 300
        return BootstrapClient(sockets: hub, timing: timing)
    }

    func testNoAddressMeansNotConfiguredWithNoSocketOpened() async {
        let hub = FakeHub()
        let client = client(hub)
        client.start()
        await sleepMs(20)
        XCTAssertEqual(.notConfigured, client.status.phase)
        let found = await client.lookup(bo)
        XCTAssertNil(found)
        XCTAssertTrue(hub.frames().isEmpty)
    }

    func testHelloOnOpenLookupWatchAndAnUnreachableOffer() async {
        let hub = FakeHub()
        let alice = client(hub)
        let bob = client(hub)
        var presence: [(String, Bool)] = []
        alice.onPresence = { presence.append(($0, $1)) }
        alice.announce(directId: ada, bundle: bundle(ada))
        alice.watch([bo])
        alice.configure("ws://192.168.1.20:8787")
        alice.start()
        await sleepMs(50)
        XCTAssertEqual(.open, alice.status.phase)
        XCTAssertEqual(.hello(from: ada, bundle: bundle(ada), nonce: nil, proof: nil, discoverable: false), SignalCodec.decode(hub.frames().first!))
        XCTAssertTrue(presence.contains { $0 == (bo, false) })

        bob.announce(directId: bo, bundle: bundle(bo), discoverable: true)
        bob.configure("ws://192.168.1.20:8787")
        bob.start()
        await sleepMs(50)
        XCTAssertTrue(presence.contains { $0 == (bo, true) })

        let found = await alice.lookup(bo)
        XCTAssertEqual(bundle(bo), found)
        let missing = await alice.lookup("dir_0123456789ABCDEH")
        XCTAssertNil(missing)
        let unreachable = await alice.sendNegotiation(.offer(to: "dir_0123456789ABCDEH", from: ada, sdp: "v=0"))
        XCTAssertFalse(unreachable)
        let reachable = await alice.sendNegotiation(.offer(to: bo, from: ada, sdp: "v=0"))
        XCTAssertTrue(reachable)
        XCTAssertFalse(hub.frames().contains { $0.contains("body") || $0.contains("\"message\"") })
        alice.stop()
        bob.stop()
    }

    func testOnlyNegotiationAddressedToThisDeviceIsDelivered() async {
        let hub = FakeHub()
        let alice = client(hub)
        let bob = client(hub)
        var seen: [SignalFrame] = []
        bob.onNegotiation = { seen.append($0) }
        for (client, id) in [(alice, ada), (bob, bo)] {
            client.announce(directId: id, bundle: bundle(id))
            client.configure("ws://10.0.0.5")
            client.start()
        }
        await sleepMs(50)
        _ = await alice.sendNegotiation(.ice(to: bo, from: ada, candidate: "candidate:1", sdpMid: "0", sdpMLineIndex: 0))
        _ = await alice.sendNegotiation(.ice(to: bo, from: "dir_0123456789ABCDEH", candidate: "spoofed", sdpMid: nil, sdpMLineIndex: nil))
        await sleepMs(50)
        XCTAssertEqual([.ice(to: bo, from: ada, candidate: "candidate:1", sdpMid: "0", sdpMLineIndex: 0)], seen)
        alice.stop()
        bob.stop()
    }

    func testADroppedBootstrapRetriesWithBackoffAndReconnectNowSkipsTheWait() async {
        let hub = FakeHub()
        let client = client(hub)
        client.announce(directId: ada, bundle: bundle(ada))
        client.configure("ws://192.168.1.20:8787")
        client.start()
        await sleepMs(30)
        XCTAssertEqual(.open, client.status.phase)

        hub.reachable = false
        hub.dropAll()
        await sleepMs(30)
        XCTAssertEqual(.retrying, client.status.phase)
        await sleepMs(120)
        XCTAssertEqual(.retrying, client.status.phase, "first retry at 100ms is refused")

        hub.reachable = true
        await sleepMs(100)
        XCTAssertEqual(.retrying, client.status.phase, "second retry waits 200ms")
        await sleepMs(150)
        XCTAssertEqual(.open, client.status.phase)
        XCTAssertEqual(2, hub.frames().filter { $0.contains("\"hello\"") }.count, "hello is sent again on every open")

        hub.dropAll()
        await sleepMs(20)
        client.reconnectNow()
        await sleepMs(20)
        XCTAssertEqual(.open, client.status.phase)
        client.stop()
        XCTAssertEqual(.stopped, client.status.phase)
    }

    func testSuggestListsOnlyDiscoverableLivePhones() async {
        let hub = FakeHub()
        let alice = client(hub)
        let bob = client(hub)
        alice.announce(directId: ada, bundle: bundle(ada), discoverable: true)
        alice.configure("ws://192.168.1.20:8787")
        alice.start()
        bob.announce(directId: bo, bundle: bundle(bo))
        bob.configure("ws://192.168.1.20:8787")
        bob.start()
        await sleepMs(50)
        let fromAlice = await alice.suggest()
        XCTAssertTrue(fromAlice.isEmpty)
        let fromBob = await bob.suggest()
        XCTAssertEqual(1, fromBob.count)
        XCTAssertEqual(ada, fromBob.first?.directId)
        XCTAssertTrue(fromBob.first?.online == true)
        alice.stop()
        bob.stop()
    }
}
