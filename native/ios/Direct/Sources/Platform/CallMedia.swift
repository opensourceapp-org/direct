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
    private var connection: RTCPeerConnection?
    private var audioTrack: RTCAudioTrack?
    private var videoTrack: RTCVideoTrack?
    private var capturer: RTCCameraVideoCapturer?
    private var usingFront = true
    private var liveVideo = false
    private var remoteReady = false
    private var pendingIce: [RTCIceCandidate] = []
    private var epoch = 0

    func handle(_ event: CallEvent) {
        switch event {
        case let .begin(video, outgoing):
            start(video: video, outgoing: outgoing)
        case let .offer(sdp):
            onOffer(sdp)
        case let .answer(sdp):
            onAnswer(sdp)
        case let .ice(candidate, mid, line):
            addIce(candidate, mid, line)
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

    private func start(video: Bool, outgoing: Bool) {
        stop()
        liveVideo = video
        usingFront = true
        configureAudio(video: video, speaker: video)
        let config = RTCConfiguration()
        config.iceServers = WebRTCTransport.defaultIceServers
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually
        let empty = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let connection = factory.peerConnection(with: config, constraints: empty, delegate: self) else { return }
        self.connection = connection
        let source = factory.audioSource(with: empty)
        let audio = factory.audioTrack(with: source, trackId: "audio0")
        audio.isEnabled = true
        connection.add(audio, streamIds: ["direct"])
        audioTrack = audio
        if video { openCamera(connection) }
        if outgoing { makeOffer(video: video) }
    }

    private func openCamera(_ connection: RTCPeerConnection) {
        let source = factory.videoSource()
        let camera = RTCCameraVideoCapturer(delegate: source)
        let track = factory.videoTrack(with: source, trackId: "video0")
        track.isEnabled = true
        connection.add(track, streamIds: ["direct"])
        capturer = camera
        videoTrack = track
        localTrack = track
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

    private func makeOffer(video: Bool) {
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: ["OfferToReceiveAudio": "true", "OfferToReceiveVideo": video ? "true" : "false"],
            optionalConstraints: nil
        )
        connection?.offer(for: constraints) { [weak self] description, _ in
            guard let self, let description else { return }
            self.connection?.setLocalDescription(description) { _ in
                let sdp = description.sdp
                Task { @DirectActor in await Runtime.shared.node.relayOffer(sdp) }
            }
        }
    }

    private func onOffer(_ sdp: String) {
        let description = RTCSessionDescription(type: .offer, sdp: sdp)
        connection?.setRemoteDescription(description) { [weak self] _ in
            guard let self else { return }
            self.remoteReady = true
            self.flushIce()
            let constraints = RTCMediaConstraints(
                mandatoryConstraints: ["OfferToReceiveAudio": "true", "OfferToReceiveVideo": self.liveVideo ? "true" : "false"],
                optionalConstraints: nil
            )
            self.connection?.answer(for: constraints) { description, _ in
                guard let description else { return }
                self.connection?.setLocalDescription(description) { _ in
                    let answer = description.sdp
                    Task { @DirectActor in await Runtime.shared.node.relayAnswer(answer) }
                }
            }
        }
    }

    private func onAnswer(_ sdp: String) {
        connection?.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp)) { [weak self] _ in
            self?.remoteReady = true
            self?.flushIce()
        }
    }

    private func addIce(_ candidate: String, _ mid: String, _ line: Int) {
        let ice = RTCIceCandidate(sdp: candidate, sdpMLineIndex: Int32(line), sdpMid: mid)
        if remoteReady { connection?.add(ice) } else { pendingIce.append(ice) }
    }

    private func flushIce() {
        pendingIce.forEach { connection?.add($0) }
        pendingIce.removeAll()
    }

    private func configureAudio(video: Bool, speaker: Bool) {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: video ? .videoChat : .voiceChat, options: [.allowBluetooth, .duckOthers])
        try? session.setActive(true)
        try? session.overrideOutputAudioPort(speaker ? .speaker : .none)
    }

    private func stop() {
        epoch += 1
        capturer?.stopCapture()
        capturer = nil
        connection?.close()
        connection = nil
        audioTrack = nil
        videoTrack = nil
        remoteTrack = nil
        localTrack = nil
        pendingIce.removeAll()
        remoteReady = false
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        let seen = epoch
        let sdp = candidate.sdp
        let mid = candidate.sdpMid ?? "0"
        let line = Int(candidate.sdpMLineIndex)
        Task { @DirectActor in
            guard seen == CallSession.shared.epoch else { return }
            await Runtime.shared.node.relayIce(sdp, mid, line)
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        guard newState == .connected || newState == .completed else { return }
        let seen = epoch
        Task { @DirectActor in
            guard seen == CallSession.shared.epoch else { return }
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
