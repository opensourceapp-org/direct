import DirectCore
import SwiftUI
import UIKit

enum Ink {
    static let background = adaptive(light: 0xF2F2F7, dark: 0x0A0C12)
    static let surface = adaptive(light: 0xFFFFFF, dark: 0x14171F)
    static let line = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor.white.withAlphaComponent(0.08) : UIColor.black.withAlphaComponent(0.08)
    })
    static let text = adaptive(light: 0x1C1C1E, dark: 0xEDF0F5)
    static let muted = adaptive(light: 0x8E8E93, dark: 0x8F96A6)
    /// Apple system blue and green, so light and dark mode each get the system color.
    static let accent = Color(uiColor: .systemBlue)
    static let incoming = adaptive(light: 0xE9E9EB, dark: 0x3A3A3C)
    static let success = Color(uiColor: .systemGreen)
    static let warning = Color(uiColor: .systemOrange)
    static let danger = Color(uiColor: .systemRed)

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            ui(traits.userInterfaceStyle == .dark ? dark : light)
        })
    }

    private static func ui(_ hex: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
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
            Text(title).font(.body.weight(.semibold)).frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
        .tint(Ink.accent)
        // The screen's text color would otherwise paint this label dark in light mode.
        .foregroundStyle(Color.white)
        .disabled(!enabled)
    }
}

enum Keyboard {
    static func dismiss() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

/// A tap outside a text field closes the keyboard. Taps on the field itself are left alone, and other controls still receive the touch.
final class KeyboardDismiss: NSObject, UIGestureRecognizerDelegate {
    static let shared = KeyboardDismiss()
    private var started = false
    private var watched = Set<ObjectIdentifier>()

    func install() {
        if !started {
            started = true
            NotificationCenter.default.addObserver(self, selector: #selector(attachWindows), name: UIWindow.didBecomeKeyNotification, object: nil)
        }
        attachWindows()
    }

    @objc private func attachWindows() {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        for window in windows {
            guard watched.insert(ObjectIdentifier(window)).inserted else { continue }
            let tap = UITapGestureRecognizer(target: self, action: #selector(close))
            tap.cancelsTouchesInView = false
            tap.delaysTouchesBegan = false
            tap.delaysTouchesEnded = false
            tap.delegate = self
            window.addGestureRecognizer(tap)
        }
    }

    @objc private func close() { Keyboard.dismiss() }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let view = touch.view else { return true }
        if isTextInput(view) || isTextInput(view.superview) { return false }
        if view.subviews.contains(where: isTextInput) { return false }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }

    private func isTextInput(_ view: UIView?) -> Bool {
        view is UITextField || view is UITextView
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
    var size: CGFloat = 44

    var body: some View {
        Group {
            if let data = jpeg.flatMap({ Encoding.fromBase64Url($0) }), let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Text(String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased())
                    .font(.system(size: size * 0.38, weight: .semibold))
                    .foregroundStyle(Color.white)
            }
        }
        .frame(width: size, height: size)
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

struct ProfileHeader: View {
    let name: String
    let jpeg: String?
    let status: String
    let posts: Int
    var contacts: Int? = nil
    var stories = false
    var unseenStories = false
    var onAvatar: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            avatar
            VStack(alignment: .leading, spacing: 5) {
                Text(name)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Ink.text)
                    .lineLimit(1)
                if !status.isEmpty {
                    Text(status)
                        .font(.subheadline)
                        .foregroundStyle(Ink.muted)
                        .lineLimit(3)
                }
                HStack(spacing: 20) {
                    count(posts, posts == 1 ? "post" : "posts")
                    if let contacts {
                        count(contacts, contacts == 1 ? "contact" : "contacts")
                    }
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, 4)
    }

    private var photo: some View {
        Avatar(name: name, jpeg: jpeg, size: 88)
            .padding(stories ? 3 : 0)
            .overlay {
                Circle().strokeBorder(
                    stories ? (unseenStories ? Ink.accent : Ink.muted.opacity(0.55)) : Color.clear,
                    lineWidth: 2
                )
            }
    }

    @ViewBuilder
    private var avatar: some View {
        if let onAvatar {
            Button(action: onAvatar) { photo }.buttonStyle(.plain)
        } else {
            photo
        }
    }

    private func count(_ value: Int, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(value)")
                .font(.headline)
                .foregroundStyle(Ink.text)
            Text(label)
                .font(.caption)
                .foregroundStyle(Ink.muted)
        }
        .accessibilityLabel("\(value) \(label)")
    }
}

func formatTime(_ ms: Int64) -> String {
    Date(timeIntervalSince1970: TimeInterval(ms) / 1000).formatted(date: .omitted, time: .shortened)
}

func messageBubble(_ outgoing: Bool, tail: Bool) -> UnevenRoundedRectangle {
    let round: CGFloat = 18
    let corner: CGFloat = tail ? 5 : 18
    return UnevenRoundedRectangle(
        topLeadingRadius: round,
        bottomLeadingRadius: outgoing ? round : corner,
        bottomTrailingRadius: outgoing ? corner : round,
        topTrailingRadius: round,
        style: .continuous
    )
}
