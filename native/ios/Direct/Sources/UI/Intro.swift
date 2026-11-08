import DirectCore
import SwiftUI

struct IntroView: View {
    let creating: Bool
    let onDone: () -> Void
    @State private var page = 0

    private let pages: [(symbol: String, title: String, body: String)] = [
        ("lock.iphone", "A conversation between two phones", "DIRECT creates your identity on this phone. A message is sealed here before it leaves, and the other phone is the only one that can open it."),
        ("antenna.radiowaves.left.and.right", "The bootstrap only introduces you", "A small server helps the two phones find each other. It never sees your messages, photos, voice notes, or keys."),
        ("qrcode", "Add someone with an ID or a QR code", "Share your DIRECT ID, or let them scan your QR code. You can scan theirs too. The first message arrives as a request they accept."),
        ("hourglass", "Offline messages wait on this phone", "If the other phone is away, the message stays here and sends when they can be reached. There is no chat server holding a copy."),
    ]

    private var isLast: Bool { page == pages.count - 1 }
    private var finishTitle: String { creating ? "Create your identity" : "Done" }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("DIRECT")
                    .font(.caption.weight(.semibold))
                    .tracking(2)
                    .foregroundStyle(Ink.accent)
                Spacer()
                Text("\(page + 1) of \(pages.count)")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Ink.muted)
            }
            TabView(selection: $page) {
                ForEach(pages.indices, id: \.self) { index in
                    pageView(pages[index])
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            Button {
                if isLast {
                    onDone()
                } else {
                    withAnimation(.easeOut(duration: 0.22)) { page += 1 }
                }
            } label: {
                Text(isLast ? finishTitle : "Next")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(Ink.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(ComposerPressStyle())
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .background(Ink.background.ignoresSafeArea())
        .foregroundStyle(Ink.text)
    }

    private func pageView(_ page: (symbol: String, title: String, body: String)) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            ZStack {
                Circle()
                    .fill(Ink.accent.opacity(0.16))
                    .frame(width: 148, height: 148)
                Circle()
                    .stroke(Ink.accent.opacity(0.45), lineWidth: 1)
                    .frame(width: 148, height: 148)
                Image(systemName: page.symbol)
                    .font(.system(size: 64, weight: .medium))
                    .foregroundStyle(Ink.accent)
                    .symbolRenderingMode(.hierarchical)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 12)
            Text(page.title)
                .font(.system(size: 28, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)
            Text(page.body)
                .font(.system(size: 17))
                .foregroundStyle(Ink.muted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 28)
        }
    }
}
