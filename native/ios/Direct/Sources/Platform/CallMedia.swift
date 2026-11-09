import AVFoundation
import CoreMedia
import DirectCore
import Foundation
import SwiftUI
import WebRTC

/// The call's own peer connection. Offers, answers, and ICE are sealed on the data channel.
/// The message channel is left alone, and the bootstrap never sees the call.
final class CallSession: NSObject, ObservableObject, RTCPeerConnectionDelegate {
    static let shared = CallSession()

    @Published var remoteTrack: RTCVideoTrack?
    @Published var localTrack: RTCVideoTrack?

    private let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory()
    }()
    private var connections: [String: RTCPeerConnection] = [:]
    private var tokens: [String: Int] = [:]
    private var audioTrack: RTCAudioTrack?
    private var videoTrack: RTCVideoTrack?
    private var capturer: RTCCameraVideoCapturer?
    private var usingFront = true
    private var liveVideo = false
    private var sessionLive = false
    private var remoteReady: Set<String> = []
    private var pendingIce: [String: [RTCIceCandidate]] = [:]
    private var epoch = 0

    func handle(_ event: CallEvent) {
        switch event {
        case let .begin(video, outgoing, peerId):
            start(video: video, outgoing: outgoing, peerId: peerId)
        case let .offer(sdp, peerId):
            onOffer(sdp, peerId)
        case let .answer(sdp, peerId):
            onAnswer(sdp, peerId)
        case let .ice(candidate, mid, line, peerId):
            addIce(candidate, mid, line, peerId)
        case .end:
            stop()
        }
    }

    func setMuted(_ muted: Bool) { audioTrack?.isEnabled = !muted }

    func setCamera(_ enabled: Bool) { videoTrack?.isEnabled = enabled }

    func setSpeaker(_ speaker: Bool) { configureAudio(video: liveVideo, speaker: speaker) }

    func flipCamera() {
        usingFront.toggle()
        guard let capturer else { return }
        capturer.stopCapture { [weak self] in
            self?.beginCapture()
        }
    }

    private func start(video: Bool, outgoing: Bool, peerId: String) {
        if !sessionLive {
            liveVideo = video
            usingFront = true
            configureAudio(video: video, speaker: video)
            sessionLive = true
            let empty = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
            let source = factory.audioSource(with: empty)
            let audio = factory.audioTrack(with: source, trackId: "audio0")
            audio.isEnabled = true
            audioTrack = audio
            if video { openCamera() }
        }
        guard connections[peerId] == nil else { return }
        let config = RTCConfiguration()
        config.iceServers = WebRTCTransport.defaultIceServers
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually
        let empty = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let connection = factory.peerConnection(with: config, constraints: empty, delegate: self) else { return }
        if let audioTrack { connection.add(audioTrack, streamIds: ["direct"]) }
        if let videoTrack { connection.add(videoTrack, streamIds: ["direct"]) }
        epoch += 1
        connections[peerId] = connection
        tokens[peerId] = epoch
        if outgoing { makeOffer(video: liveVideo, peerId: peerId) }
    }

    private func openCamera() {
        let source = factory.videoSource()
        let camera = RTCCameraVideoCapturer(delegate: source)
        let track = factory.videoTrack(with: source, trackId: "video0")
        track.isEnabled = true
        capturer = camera
        videoTrack = track
        localTrack = track
        connections.values.forEach { $0.add(track, streamIds: ["direct"]) }
        beginCapture()
    }

    private func beginCapture() {
        guard let capturer else { return }
        let position: AVCaptureDevice.Position = usingFront ? .front : .back
        guard let device = RTCCameraVideoCapturer.captureDevices().first(where: { $0.position == position })
            ?? RTCCameraVideoCapturer.captureDevices().first else { return }
        let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
        let format = formats.min { lhs, rhs in
            let a = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
            let b = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
            let da = abs(Int(a.width) - 640) + abs(Int(a.height) - 480)
            let db = abs(Int(b.width) - 640) + abs(Int(b.height) - 480)
            return da < db
        } ?? formats.last
        guard let format else { return }
        capturer.startCapture(with: device, format: format, fps: 24)
    }

    private func makeOffer(video: Bool, peerId: String) {
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: ["OfferToReceiveAudio": "true", "OfferToReceiveVideo": video ? "true" : "false"],
            optionalConstraints: nil
        )
        Task { [weak self] in
            guard let self, let connection = self.connections[peerId] else { return }
            guard let description = try? await connection.offer(for: constraints) else { return }
            do { try await connection.setLocalDescription(description) } catch { return }
            let sdp = description.sdp
            Task { @DirectActor in await Runtime.shared.node.relayOffer(sdp, peerId: peerId) }
        }
    }

    private func onOffer(_ sdp: String, _ peerId: String) {
        Task { [weak self] in
            guard let self, let connection = self.connections[peerId] else { return }
            do { try await connection.setRemoteDescription(RTCSessionDescription(type: .offer, sdp: sdp)) } catch { return }
            self.remoteReady.insert(peerId)
            self.flushIce(peerId)
            let constraints = RTCMediaConstraints(
                mandatoryConstraints: ["OfferToReceiveAudio": "true", "OfferToReceiveVideo": self.liveVideo ? "true" : "false"],
                optionalConstraints: nil
            )
            guard let description = try? await connection.answer(for: constraints) else { return }
            do { try await connection.setLocalDescription(description) } catch { return }
            let answer = description.sdp
            Task { @DirectActor in await Runtime.shared.node.relayAnswer(answer, peerId: peerId) }
        }
    }

    private func onAnswer(_ sdp: String, _ peerId: String) {
        Task { [weak self] in
            guard let self, let connection = self.connections[peerId] else { return }
            do { try await connection.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp)) } catch { return }
            self.remoteReady.insert(peerId)
            self.flushIce(peerId)
        }
    }

    private func addIce(_ candidate: String, _ mid: String, _ line: Int, _ peerId: String) {
        let ice = RTCIceCandidate(sdp: candidate, sdpMLineIndex: Int32(line), sdpMid: mid)
        if remoteReady.contains(peerId) {
            connections[peerId]?.add(ice) { _ in }
        } else {
            pendingIce[peerId, default: []].append(ice)
        }
    }

    private func flushIce(_ peerId: String) {
        pendingIce[peerId]?.forEach { connections[peerId]?.add($0) { _ in } }
        pendingIce[peerId] = nil
    }

    private func configureAudio(video: Bool, speaker: Bool) {
        let mode: AVAudioSession.Mode = video ? .videoChat : .voiceChat
        let port: AVAudioSession.PortOverride = speaker ? .speaker : .none
        Task.detached {
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playAndRecord, mode: mode, options: [.allowBluetoothHFP, .duckOthers])
            try? await CallAudio.setActive(true)
            try? session.overrideOutputAudioPort(port)
        }
    }

    private func stop() {
        epoch += 1
        capturer?.stopCapture()
        capturer = nil
        connections.values.forEach { $0.close() }
        connections.removeAll()
        tokens.removeAll()
        audioTrack = nil
        videoTrack = nil
        remoteTrack = nil
        localTrack = nil
        pendingIce.removeAll()
        remoteReady.removeAll()
        sessionLive = false
        Task.detached {
            try? await CallAudio.setActive(false)
        }
    }

    private func peerId(for connection: RTCPeerConnection) -> String? {
        connections.first { $0.value === connection }?.key
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        guard let peerId = peerId(for: peerConnection) else { return }
        let seen = tokens[peerId]
        let sdp = candidate.sdp
        let mid = candidate.sdpMid ?? "0"
        let line = Int(candidate.sdpMLineIndex)
        Task { @DirectActor in
            guard seen == CallSession.shared.tokens[peerId] else { return }
            await Runtime.shared.node.relayIce(sdp, mid, line, peerId: peerId)
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        guard newState == .connected || newState == .completed else { return }
        guard let peerId = peerId(for: peerConnection) else { return }
        let seen = tokens[peerId]
        Task { @DirectActor in
            guard seen == CallSession.shared.tokens[peerId] else { return }
            Runtime.shared.node.markCallLive()
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        guard let track = stream.videoTracks.first else { return }
        DispatchQueue.main.async { self.remoteTrack = track }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams: [RTCMediaStream]) {
        guard let track = rtpReceiver.track as? RTCVideoTrack else { return }
        DispatchQueue.main.async { self.remoteTrack = track }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
}

private enum CallAudio {
    static func setActive(_ active: Bool) async throws {
        let session = AVAudioSession.sharedInstance()
        let options: AVAudioSession.SetActiveOptions = active ? [] : [.notifyOthersOnDeactivation]
        if #available(iOS 17.0, *) {
            try await session.setActive(active, options: options)
        } else {
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try session.setActive(active, options: options)
                        done.resume()
                    } catch {
                        done.resume(throwing: error)
                    }
                }
            }
        }
    }
}

struct CallVideo: UIViewRepresentable {
    var track: RTCVideoTrack?
    var mirror: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView()
        view.videoContentMode = .scaleAspectFill
        view.clipsToBounds = true
        return view
    }

    func updateUIView(_ view: RTCMTLVideoView, context: Context) {
        context.coordinator.bind(track, view)
        view.transform = mirror ? CGAffineTransform(scaleX: -1, y: 1) : .identity
    }

    final class Coordinator {
        private var track: RTCVideoTrack?
        func bind(_ track: RTCVideoTrack?, _ view: RTCMTLVideoView) {
            guard self.track !== track else { return }
            self.track?.remove(view)
            self.track = track
            track?.add(view)
        }
    }
}
