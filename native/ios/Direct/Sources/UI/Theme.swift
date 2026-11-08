import DirectCore
import SwiftUI
import UIKit

enum Ink {
    static let background = Color(red: 0.04, green: 0.05, blue: 0.07)
    static let surface = Color(red: 0.08, green: 0.09, blue: 0.12)
    static let line = Color.white.opacity(0.08)
    static let text = Color(red: 0.93, green: 0.94, blue: 0.96)
    static let muted = Color(red: 0.56, green: 0.59, blue: 0.65)
    /// Apple system blue and system green in dark mode (#0A84FF, #30D158).
    static let accent = Color(red: 0.039, green: 0.518, blue: 1.0)
    static let success = Color(red: 0.188, green: 0.820, blue: 0.345)
    static let warning = Color(red: 0.98, green: 0.77, blue: 0.36)
    static let danger = Color(red: 1.0, green: 0.42, blue: 0.42)
}

extension MessageState {
    var label: String {
        switch self {
        case .queued: return "Queued"
        case .sending: return "Sending"
        case .sent: return "Sent"
        case .accepted: return "Delivered"
        case .acknowledged: return "Read"
        case .failed: return "Failed · tap to retry"
        }
    }
}

extension BootstrapStatus {
    var describe: (String, Color) {
        switch phase {
        case .notConfigured: return ("Not set", Ink.warning)
        case .connecting: return ("Connecting", Ink.warning)
        case .open: return ("Connected", Ink.success)
        case .retrying: return ("Retrying", Ink.danger)
        case .stopped: return ("Stopped", Ink.muted)
        }
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Ink.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Ink.line))
    }
}

struct PrimaryButton: View {
    let title: String
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.headline).frame(maxWidth: .infinity).padding(.vertical, 12)
        }
        .buttonStyle(.borderedProminent)
        .tint(Ink.accent)
        .disabled(!enabled)
    }
}

struct Field: View {
    let placeholder: String
    @Binding var text: String
    var monospaced = false

    var body: some View {
        TextField(placeholder, text: $text, axis: .vertical)
            .font(monospaced ? .system(.body, design: .monospaced) : .body)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(12)
            .background(Ink.background, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Ink.line))
    }
}

struct Avatar: View {
    let name: String
    let jpeg: String?

    var body: some View {
        Group {
            if let data = jpeg.flatMap({ Encoding.fromBase64Url($0) }), let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Text(String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased())
                    .font(.headline)
                    .foregroundStyle(Color.white)
            }
        }
        .frame(width: 44, height: 44)
        .background(Ink.accent)
        .clipShape(Circle())
    }
}

struct StatusDot: View {
    let color: Color
    var body: some View { Circle().fill(color).frame(width: 8, height: 8) }
}

struct Muted: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.footnote).foregroundStyle(Ink.muted) }
}

func formatTime(_ ms: Int64) -> String {
    Date(timeIntervalSince1970: TimeInterval(ms) / 1000).formatted(date: .omitted, time: .shortened)
}
