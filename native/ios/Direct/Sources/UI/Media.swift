import AVFoundation
import AVKit
import CoreImage
import CoreImage.CIFilterBuiltins
import DirectCore
import CoreTransferable
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum MediaPrep {
    static let maxBytes = 6 * 1024 * 1024

    static func photo(_ data: Data) throws -> (kind: String, mime: String, name: String, bytes: Data) {
        if isGif(data) {
            guard data.count <= maxBytes else { throw PrepError("That GIF is over 6 MB. Choose a shorter one.") }
            return ("gif", "image/gif", "animation.gif", data)
        }
        guard let jpeg = compress(data, maxEdge: 1280, maxBytes: maxBytes, quality: 0.85) else {
            throw PrepError("That photo could not be read.")
        }
        guard jpeg.count <= maxBytes else { throw PrepError("That photo is still over 6 MB after compression.") }
        return ("image", "image/jpeg", "photo.jpg", jpeg)
    }

    static func video(_ data: Data, mime: String) throws -> (kind: String, mime: String, name: String, bytes: Data) {
        guard !data.isEmpty else { throw PrepError("That video is empty.") }
        guard data.count <= maxBytes else { throw PrepError("That video is over 6 MB. Choose a shorter one. DIRECT does not compress video.") }
        return ("video", mime.isEmpty ? "video/mp4" : mime, "video.mp4", data)
    }

    static func avatar(_ data: Data) throws -> Data {
        var edge: CGFloat = 256
        var quality: CGFloat = 0.8
        while edge >= 48 {
            if let jpeg = compress(data, maxEdge: edge, maxBytes: 48_000, quality: quality),
               jpeg.count >= 3, jpeg.count <= 48_000, jpeg[0] == 0xFF, jpeg[1] == 0xD8 {
                return jpeg
            }
            if quality > 0.4 { quality -= 0.15 } else { edge *= 0.75; quality = 0.7 }
        }
        throw PrepError("Choose a smaller photo.")
    }

    static func qrAvatar(_ jpeg: Data?) -> Data? {
        guard let jpeg, jpeg.count >= 3, let tiny = compress(jpeg, maxEdge: 48, maxBytes: 700, quality: 0.5),
              tiny.count <= 700, tiny.first == 0xFF else { return nil }
        return tiny
    }

    static func sticker(_ index: Int) -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 256, height: 256))
        let image = renderer.image { context in
            let cg = context.cgContext
            switch index % 6 {
            case 0:
                UIColor(red: 0.05, green: 0.42, blue: 0.27, alpha: 1).setFill()
                cg.fillEllipse(in: CGRect(x: 18, y: 18, width: 220, height: 220))
                UIColor.white.setStroke()
                cg.setLineWidth(10)
                cg.setLineCap(.round)
                cg.addArc(center: CGPoint(x: 128, y: 140), radius: 48, startAngle: 0.2, endAngle: .pi - 0.2, clockwise: false)
                cg.strokePath()
                cg.fillEllipse(in: CGRect(x: 88, y: 100, width: 18, height: 18))
                cg.fillEllipse(in: CGRect(x: 150, y: 100, width: 18, height: 18))
            case 1:
                UIColor(red: 0.77, green: 0.27, blue: 0.21, alpha: 1).setFill()
                cg.fillEllipse(in: CGRect(x: 48, y: 60, width: 90, height: 90))
                cg.fillEllipse(in: CGRect(x: 118, y: 60, width: 90, height: 90))
                cg.move(to: CGPoint(x: 58, y: 128))
                cg.addLine(to: CGPoint(x: 128, y: 210))
                cg.addLine(to: CGPoint(x: 198, y: 128))
                cg.fillPath()
            case 2:
                UIColor(red: 0.89, green: 0.64, blue: 0.13, alpha: 1).setFill()
                let star = UIBezierPath()
                let points: [CGPoint] = [
                    CGPoint(x: 128, y: 28), CGPoint(x: 156, y: 100), CGPoint(x: 232, y: 104),
                    CGPoint(x: 172, y: 154), CGPoint(x: 196, y: 228), CGPoint(x: 128, y: 186),
                    CGPoint(x: 60, y: 228), CGPoint(x: 84, y: 154), CGPoint(x: 24, y: 104), CGPoint(x: 100, y: 100),
                ]
                star.move(to: points[0])
                points.dropFirst().forEach { star.addLine(to: $0) }
                star.close()
                star.fill()
            case 3:
                UIColor(red: 0.18, green: 0.44, blue: 0.56, alpha: 1).setStroke()
                cg.setLineWidth(16)
                cg.setLineCap(.round)
                cg.addArc(center: CGPoint(x: 90, y: 128), radius: 50, startAngle: .pi, endAngle: 0, clockwise: false)
                cg.strokePath()
                cg.addArc(center: CGPoint(x: 166, y: 128), radius: 50, startAngle: 0, endAngle: .pi, clockwise: false)
                cg.strokePath()
            case 4:
                UIColor(red: 0.10, green: 0.10, blue: 0.09, alpha: 1).setFill()
                cg.fillEllipse(in: CGRect(x: 18, y: 18, width: 220, height: 220))
                UIColor(red: 0.95, green: 0.95, blue: 0.93, alpha: 1).setStroke()
                cg.setLineWidth(14)
                cg.setLineCap(.round)
                cg.move(to: CGPoint(x: 78, y: 132))
                cg.addLine(to: CGPoint(x: 114, y: 168))
                cg.addLine(to: CGPoint(x: 184, y: 92))
                cg.strokePath()
            default:
                UIColor(red: 0.96, green: 0.79, blue: 0.36, alpha: 1).setFill()
                cg.fillEllipse(in: CGRect(x: 72, y: 72, width: 112, height: 112))
                cg.setLineWidth(10)
                cg.setLineCap(.round)
                UIColor(red: 0.96, green: 0.79, blue: 0.36, alpha: 1).setStroke()
                for index in 0..<8 {
                    cg.saveGState()
                    cg.translateBy(x: 128, y: 128)
                    cg.rotate(by: CGFloat(index) * .pi / 4)
                    cg.move(to: CGPoint(x: 0, y: -92))
                    cg.addLine(to: CGPoint(x: 0, y: -70))
                    cg.strokePath()
                    cg.restoreGState()
                }
            }
        }
        return image.pngData() ?? Data()
    }

    static func shareCard(bundle: String, status: String, avatarJpeg: Data?) -> String {
        let tiny = qrAvatar(avatarJpeg)
        let withPhoto = ProfileCards.encode(bundle: bundle, status: status, avatarJpeg: tiny)
        if tiny != nil, qrImage(withPhoto) == nil {
            return ProfileCards.encode(bundle: bundle, status: status, avatarJpeg: nil)
        }
        return withPhoto
    }

    static func qrImage(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        return UIImage(ciImage: scaled)
    }

    private static func isGif(_ data: Data) -> Bool {
        data.starts(with: Data("GIF8".utf8))
    }

    private static func compress(_ data: Data, maxEdge: CGFloat, maxBytes: Int, quality: CGFloat) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let longest = max(image.size.width, image.size.height)
        let scale = longest > maxEdge ? maxEdge / longest : 1
        let size = CGSize(width: max(1, floor(image.size.width * scale)), height: max(1, floor(image.size.height * scale)))
        let renderer = UIGraphicsImageRenderer(size: size)
        let drawn = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        var q = quality
        var out = drawn.jpegData(compressionQuality: q) ?? Data()
        while out.count > maxBytes, q > 0.3 {
            q -= 0.1
            out = drawn.jpegData(compressionQuality: q) ?? out
        }
        return out.isEmpty ? nil : out
    }
}

struct VideoBytes: Transferable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        // `contentType` binds the first closure to export. Import has to be named,
        // and `Data(contentsOf:)` without options is async on newer SDKs.
        FileRepresentation(contentType: .movie) { item in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("direct-video-\(UUID().uuidString).mp4")
            try item.data.write(to: url, options: .atomic)
            return SentTransferredFile(url)
        } importing: { received in
            let bytes = try Data(contentsOf: received.file, options: [])
            return VideoBytes(data: bytes)
        }
    }
}

struct PrepError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct QrScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.onCode = onCode
        return controller
    }

    func updateUIViewController(_ controller: ScannerController, context: Context) {}

    final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onCode: ((String) -> Void)?
        private let session = AVCaptureSession()
        private var delivered = false

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else { return }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.frame = view.bounds
            preview.videoGravity = .resizeAspectFill
            view.layer.addSublayer(preview)
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            (view.layer.sublayers?.first { $0 is AVCaptureVideoPreviewLayer })?.frame = view.bounds
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            if !session.isRunning { session.startRunning() }
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            if session.isRunning { session.stopRunning() }
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard !delivered, let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject, let text = object.stringValue else { return }
            delivered = true
            session.stopRunning()
            onCode?(text)
        }
    }
}

final class VoiceCapture: NSObject, ObservableObject {
    @Published var recording = false
    private var recorder: AVAudioRecorder?
    private var file: URL?

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default)
        try session.setActive(true)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(UUID().uuidString).m4a")
        let recorder = try AVAudioRecorder(url: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
        ])
        recorder.record()
        self.recorder = recorder
        file = url
        recording = true
    }

    func stop() throws -> Data {
        recorder?.stop()
        recorder = nil
        recording = false
        guard let file, let data = try? Data(contentsOf: file), !data.isEmpty else {
            throw PrepError("That recording is empty.")
        }
        try? FileManager.default.removeItem(at: file)
        self.file = nil
        guard data.count <= MediaPrep.maxBytes else { throw PrepError("That voice message is over 6 MB.") }
        return data
    }

    func cancel() {
        recorder?.stop()
        recorder = nil
        recording = false
        if let file { try? FileManager.default.removeItem(at: file) }
        file = nil
    }
}

struct AttachmentBar: View {
    let onPhoto: (Data) -> Void
    let onVideo: (Data) -> Void
    let onGif: (Data) -> Void
    let onSticker: (Data) -> Void
    let onVoice: (Data) -> Void
    let onError: (String) -> Void

    @StateObject private var voice = VoiceCapture()
    @State private var photoItem: PhotosPickerItem?
    @State private var videoItem: PhotosPickerItem?
    @State private var gifItem: PhotosPickerItem?
    @State private var stickers = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if stickers {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(0..<6, id: \.self) { index in
                            let data = MediaPrep.sticker(index)
                            if let image = UIImage(data: data) {
                                Button {
                                    stickers = false
                                    onSticker(data)
                                } label: {
                                    Image(uiImage: image).resizable().frame(width: 56, height: 56).clipShape(Circle())
                                }
                            }
                        }
                    }
                }
            }
            if voice.recording {
                HStack {
                    Text("Recording").foregroundStyle(Ink.muted)
                    Button("Stop and send") {
                        do { onVoice(try voice.stop()) } catch { onError((error as? PrepError)?.message ?? "That recording was not sent.") }
                    }
                    Button("Cancel") { voice.cancel() }.foregroundStyle(Ink.muted)
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        PhotosPicker(selection: $photoItem, matching: .images) { chip("Photo") }
                        PhotosPicker(selection: $videoItem, matching: .videos) { chip("Video") }
                        PhotosPicker(selection: $gifItem, matching: .images) { chip("GIF") }
                        Button { stickers.toggle() } label: { chip("Sticker") }
                        Button {
                            AVAudioSession.sharedInstance().requestRecordPermission { allowed in
                                DispatchQueue.main.async {
                                    guard allowed else { onError("Microphone permission is needed for a voice message."); return }
                                    do { try voice.start() } catch { onError("Recording could not start.") }
                                }
                            }
                        } label: { chip("Voice") }
                    }
                }
            }
        }
        .onChange(of: photoItem) { item in Task { await load(item, gifOnly: false) } }
        .onChange(of: gifItem) { item in Task { await load(item, gifOnly: true) } }
        .onChange(of: videoItem) { item in
            Task {
                guard let item else { return }
                let bytes: Data?
                if let file = try? await item.loadTransferable(type: VideoBytes.self) {
                    bytes = file.data
                } else {
                    bytes = try? await item.loadTransferable(type: Data.self)
                }
                guard let bytes else { onError("That video could not be read."); return }
                do { onVideo(try MediaPrep.video(bytes, mime: "video/mp4").bytes) } catch { onError((error as? PrepError)?.message ?? "That video was not sent.") }
            }
        }
    }

    private func chip(_ title: String) -> some View {
        Text(title).font(.footnote.weight(.medium)).padding(.horizontal, 12).padding(.vertical, 8)
            .background(Ink.accent.opacity(0.2), in: Capsule())
    }

    private func load(_ item: PhotosPickerItem?, gifOnly: Bool) async {
        guard let item, let data = try? await item.loadTransferable(type: Data.self) else { return }
        let gif = item.supportedContentTypes.contains(.gif) || data.starts(with: Data("GIF8".utf8))
        if gifOnly && !gif {
            onError("Choose a GIF.")
            return
        }
        if gif {
            guard data.count <= MediaPrep.maxBytes else { onError("That GIF is over 6 MB. Choose a shorter one."); return }
            onGif(data)
            return
        }
        do { onPhoto(try MediaPrep.photo(data).bytes) } catch { onError((error as? PrepError)?.message ?? "That photo was not sent.") }
    }
}

struct MediaBubble: View {
    let message: MessageRecord
    @EnvironmentObject private var model: AppModel
    @State private var bytes: Data?
    @State private var playing = false

    var body: some View {
        let outgoing = message.direction == .outgoing
        HStack {
            if outgoing { Spacer(minLength: 48) }
            VStack(alignment: outgoing ? .trailing : .leading, spacing: 4) {
                VStack(alignment: .leading, spacing: 6) {
                    if let bytes, let image = UIImage(data: bytes), let kind = message.mediaKind, ["image", "sticker", "gif"].contains(kind) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: 220, maxHeight: 220)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    let label = MediaNotes.label(message.mediaKind)
                    if !message.body.isEmpty, message.body != label {
                        Text(message.body)
                    }
                    if message.mediaKind == "video" || message.mediaKind == "audio", bytes != nil {
                        Button("Open") { playing = true }.tint(outgoing ? Ink.text : Ink.accent)
                    }
                }
                .padding(10)
                .background(outgoing ? Ink.accent.opacity(0.25) : Ink.surface, in: RoundedRectangle(cornerRadius: 14))
                HStack(spacing: 6) {
                    Text(formatTime(message.createdAt))
                    if let state = message.state {
                        Text(state.label).foregroundStyle(state == .failed ? Ink.danger : Ink.muted)
                    }
                }
                .font(.caption2)
                .foregroundStyle(Ink.muted)
                if let error = message.lastError, message.state == .queued || message.state == .failed {
                    Text(error).font(.caption2).foregroundStyle(Ink.warning)
                }
            }
            .onTapGesture { if message.state == .failed { model.retry(message.id) } }
            if !outgoing { Spacer(minLength: 48) }
        }
        .onAppear { model.loadMedia(message.id) { bytes = $0 } }
        .onChange(of: message.mediaFile) { _ in model.loadMedia(message.id) { bytes = $0 } }
        .sheet(isPresented: $playing) {
            if let bytes {
                PlayerSheet(data: bytes, mime: message.mediaMime ?? "video/mp4", name: message.mediaKind == "audio" ? "voice.m4a" : "video.mp4")
            }
        }
    }
}

struct PlayerSheet: View {
    let data: Data
    let mime: String
    let name: String
    @State private var player: AVPlayer?

    var body: some View {
        VStack {
            if let player {
                VideoPlayer(player: player).frame(maxHeight: 320)
            } else {
                ProgressView()
            }
        }
        .padding()
        .background(Ink.background.ignoresSafeArea())
        .onAppear {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            try? data.write(to: url)
            let next = AVPlayer(url: url)
            player = next
            next.play()
        }
    }
}
