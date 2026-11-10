import AudioToolbox
import AVFoundation
import DirectCore
import SwiftUI

struct CallScreen: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var session = CallSession.shared
    @State private var now = Date()
    @State private var pip = CGSize.zero
    @State private var dragging = CGSize.zero
    let call: CallSnapshot

    var body: some View {
        let contact = model.state.contacts.first { $0.directId == call.peerId }
        let group = model.state.groups.first { $0.id == call.peerId }
        let conversation = model.state.conversations.first { $0.peerId == call.peerId }
        let name = group?.name ?? conversation?.name ?? contact?.name ?? call.peerId
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()
                if call.video, call.phase != .incoming, call.phase != .ended {
                    CallVideo(track: session.remoteTrack, mirror: false)
                        .ignoresSafeArea()
                    if call.cameraOn {
                        CallVideo(track: session.localTrack, mirror: true)
                            .frame(width: 104, height: 150)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .overlay(alignment: .top) {
                                Capsule().fill(.white.opacity(0.7)).frame(width: 36, height: 4).padding(.top, 8)
                            }
                            .offset(x: pip.width + dragging.width, y: pip.height + dragging.height)
                            .highPriorityGesture(
                                DragGesture()
                                    .onChanged { dragging = $0.translation }
                                    .onEnded { value in
                                        pip = clampPip(
                                            CGSize(width: pip.width + value.translation.width, height: pip.height + value.translation.height),
                                            in: geo.size
                                        )
                                        dragging = .zero
                                    }
                            )
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
                    if call.group, !call.members.isEmpty {
                        let memberNames = call.members.map { id in
                            model.state.contacts.first { $0.directId == id }?.name ?? String(id.prefix(12))
                        }.joined(separator: ", ")
                        Text(memberNames).font(.system(size: 13)).foregroundStyle(.white.opacity(0.55))
                    }
                    controls
                        .padding(.bottom, 12)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, max(24, geo.safeAreaInsets.bottom + 8))
            }
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
            VStack(spacing: 16) {
                HStack {
                    Spacer(minLength: 0)
                    roundButton(call.muted ? "mic.slash.fill" : "mic.fill", color: Color.white.opacity(0.16), label: call.muted ? "Unmute" : "Mute") {
                        model.setCallMuted(!call.muted)
                    }
                    Spacer(minLength: 0)
                    roundButton(call.speaker ? "speaker.wave.2.fill" : "speaker.slash.fill", color: Color.white.opacity(0.16), label: "Speaker") {
                        model.setCallSpeaker(!call.speaker)
                    }
                    if call.video {
                        Spacer(minLength: 0)
                        roundButton(call.cameraOn ? "video.fill" : "video.slash.fill", color: Color.white.opacity(0.16), label: "Camera") {
                            model.setCallCamera(!call.cameraOn)
                        }
                        Spacer(minLength: 0)
                        roundButton("camera.rotate", color: Color.white.opacity(0.16), label: "Flip") { session.flipCamera() }
                    }
                    Spacer(minLength: 0)
                }
                roundButton("phone.down.fill", color: Ink.danger, label: "End") { model.endCall() }
            }
        }
    }

    private func clampPip(_ next: CGSize, in size: CGSize) -> CGSize {
        let pipW: CGFloat = 104
        let pipH: CGFloat = 150
        let padTop: CGFloat = 24
        let padEnd: CGFloat = 16
        let left = size.width - pipW - padEnd + next.width
        let top = padTop + next.height
        let clampedLeft = min(max(8, left), max(8, size.width - pipW - 8))
        let clampedTop = min(max(8, top), max(8, size.height - pipH - 8))
        return CGSize(width: clampedLeft - (size.width - pipW - padEnd), height: clampedTop - padTop)
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
