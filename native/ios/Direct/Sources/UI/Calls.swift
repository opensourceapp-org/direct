import AudioToolbox
import AVFoundation
import DirectCore
import SwiftUI

struct CallScreen: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var session = CallSession.shared
    @State private var now = Date()
    let call: CallSnapshot

    var body: some View {
        let contact = model.state.contacts.first { $0.directId == call.peerId }
        let name = contact?.name ?? call.peerId
        ZStack {
            Color.black.ignoresSafeArea()
            if call.video, call.phase != .incoming, call.phase != .ended {
                CallVideo(track: session.remoteTrack, mirror: false)
                    .ignoresSafeArea()
                if call.cameraOn {
                    CallVideo(track: session.localTrack, mirror: true)
                        .frame(width: 104, height: 150)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(.top, 24)
                        .padding(.trailing, 16)
                }
            }
            VStack(spacing: 22) {
                Spacer()
                if !(call.video && call.phase == .active) {
                    Avatar(name: name, jpeg: contact?.avatarJpegBase64, size: 96)
                }
                Text(name).font(.system(size: 22, weight: .semibold)).foregroundStyle(.white)
                Text(status).font(.system(size: 15)).foregroundStyle(.white.opacity(0.72))
                controls
                    .padding(.bottom, 28)
            }
            .padding(.horizontal, 24)
        }
        .onAppear { apply() }
        .onChange(of: call.muted) { _ in apply() }
        .onChange(of: call.speaker) { _ in apply() }
        .onChange(of: call.cameraOn) { _ in apply() }
        .task(id: call.phase) {
            guard call.phase == .incoming || call.phase == .active else { return }
            while !Task.isCancelled {
                if call.phase == .incoming { AudioServicesPlayAlertSound(SystemSoundID(1005)) }
                if call.phase == .active { now = Date() }
                try? await Task.sleep(nanoseconds: call.phase == .incoming ? 2_000_000_000 : 1_000_000_000)
            }
        }
        .task(id: call.phase == .ended) {
            guard call.phase == .ended else { return }
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            model.dismissCall()
        }
    }

    private var status: String {
        switch call.phase {
        case .outgoing: return call.video ? "Calling video…" : "Calling…"
        case .incoming: return call.video ? "Incoming video call" : "Incoming audio call"
        case .connecting: return "Connecting…"
        case .active:
            let started = call.startedAt ?? Int64(now.timeIntervalSince1970 * 1000)
            let seconds = max(0, (Int64(now.timeIntervalSince1970 * 1000) - started) / 1000)
            return String(format: "%d:%02d", seconds / 60, seconds % 60)
        case .ended: return call.reason ?? "Call ended"
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch call.phase {
        case .incoming:
            HStack(spacing: 48) {
                roundButton("phone.down.fill", color: Ink.danger, label: "Decline") { model.endCall() }
                roundButton("phone.fill", color: Ink.success, label: "Accept") { model.acceptCall(call.video) }
            }
        case .ended:
            EmptyView()
        default:
            HStack(spacing: 18) {
                roundButton(call.muted ? "mic.slash.fill" : "mic.fill", color: Color.white.opacity(0.16), label: call.muted ? "Unmute" : "Mute") {
                    model.setCallMuted(!call.muted)
                }
                roundButton(call.speaker ? "speaker.wave.2.fill" : "speaker.slash.fill", color: Color.white.opacity(0.16), label: "Speaker") {
                    model.setCallSpeaker(!call.speaker)
                }
                if call.video {
                    roundButton(call.cameraOn ? "video.fill" : "video.slash.fill", color: Color.white.opacity(0.16), label: "Camera") {
                        model.setCallCamera(!call.cameraOn)
                    }
                    roundButton("camera.rotate", color: Color.white.opacity(0.16), label: "Flip") { session.flipCamera() }
                }
                roundButton("phone.down.fill", color: Ink.danger, label: "End") { model.endCall() }
            }
        }
    }

    private func roundButton(_ symbol: String, color: Color, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 58, height: 58)
                .background(color, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func apply() {
        session.setMuted(call.muted)
        session.setSpeaker(call.speaker)
        session.setCamera(call.cameraOn)
    }
}
