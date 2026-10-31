import DirectCore
import SwiftUI

struct IntroView: View {
    let creating: Bool
    let onDone: () -> Void
    @State private var page = 0

    private let pages: [(String, String)] = [
        ("A conversation between two phones", "DIRECT creates your identity on this phone. A message is sealed here before it leaves, and the other phone is the only one that can open it."),
        ("The bootstrap only introduces you", "A small server helps the two phones find each other. It never sees your messages, photos, voice notes, or keys."),
        ("Add someone with an ID or a QR code", "Share your DIRECT ID, or let them scan your QR code. You can scan theirs too. The first message arrives as a request they accept."),
        ("Offline messages wait on this phone", "If the other phone is away, the message stays here and sends when they can be reached. There is no chat server holding a copy."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("DIRECT").font(.caption.weight(.semibold)).tracking(2).foregroundStyle(Ink.accent)
            TabView(selection: $page) {
                ForEach(pages.indices, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 16) {
                        Text(pages[index].0).font(.title.bold())
                        Muted(pages[index].1)
                        Spacer()
                    }
                    .tag(index)
                    .padding(.top, 24)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            Button(page == pages.count - 1 ? (creating ? "Create your identity" : "Done") : "Next") {
                if page == pages.count - 1 { onDone() } else { page += 1 }
            }
            .buttonStyle(.borderedProminent)
            .tint(Ink.accent)
            .frame(maxWidth: .infinity)
        }
        .padding(24)
        .background(Ink.background.ignoresSafeArea())
        .foregroundStyle(Ink.text)
    }
}
