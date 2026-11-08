import DirectCore
import PhotosUI
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("direct.intro.seen") private var introSeen = false

    var body: some View {
        ZStack(alignment: .bottom) {
            Ink.background.ignoresSafeArea()
            if !model.state.ready {
                ProgressView().tint(Ink.accent)
            } else if let error = model.state.storageError {
                Card {
                    Text("Local data is locked").font(.headline)
                    Muted(error)
                }.padding()
            } else if model.showIntro || (model.state.profile == nil && !introSeen) {
                IntroView(creating: model.state.profile == nil) {
                    introSeen = true
                    model.showIntro = false
                }
            } else if model.state.profile == nil {
                OnboardingView()
            } else {
                HomeView()
            }
            if let toast = model.toast {
                Text(toast)
                    .font(.footnote)
                    .padding(12)
                    .background(Ink.surface, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Ink.line))
                    .padding()
                    .onTapGesture { model.toast = nil }
                    .task(id: toast) {
                        try? await Task.sleep(nanoseconds: 4_000_000_000)
                        if model.toast == toast { model.toast = nil }
                    }
            }
        }
        .foregroundStyle(Ink.text)
        .sheet(item: Binding(get: { model.newPhrase.map(Phrase.init) }, set: { _ in model.newPhrase = nil })) { phrase in
            PhraseSheet(phrase: phrase.value)
        }
    }
}

private struct Phrase: Identifiable {
    let value: String
    var id: String { value }
}

struct PhraseSheet: View {
    let phrase: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Recovery phrase").font(.title2.bold())
            Muted("These 24 words are the only way to restore this DIRECT ID on a new phone. Write them down. DIRECT never uploads them.")
            Text(phrase).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                .padding().frame(maxWidth: .infinity, alignment: .leading)
                .background(Ink.surface, in: RoundedRectangle(cornerRadius: 12))
            PrimaryButton(title: "I wrote it down") { dismiss() }
            Spacer()
        }
        .padding(24)
        .background(Ink.background.ignoresSafeArea())
        .foregroundStyle(Ink.text)
    }
}

struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel
    @State private var name = ""
    @State private var phrase = ""
    @State private var restoring = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("DIRECT").font(.largeTitle.bold())
                Muted("Peer-to-peer messages. Keys are created on this phone and kept in the Keychain. Messages go device to device; the bootstrap only introduces phones.")
                Card {
                    Field(placeholder: "Display name", text: $name)
                    if restoring {
                        Field(placeholder: "24-word recovery phrase", text: $phrase, monospaced: true)
                        PrimaryButton(title: "Restore identity", enabled: !name.isEmpty && !phrase.isEmpty) {
                            model.restoreIdentity(phrase: phrase, name: name)
                        }
                    } else {
                        PrimaryButton(title: "Create identity", enabled: !name.isEmpty) { model.createIdentity(name: name) }
                    }
                    Button(restoring ? "Create a new identity instead" : "Restore from a recovery phrase") { restoring.toggle() }
                        .font(.footnote).tint(Ink.accent)
                }
            }
            .padding(24)
        }
    }
}

struct HomeView: View {
    var body: some View {
        TabView {
            NavigationStack { ChatsView() }.tabItem { Label("Chats", systemImage: "bubble.left.and.bubble.right") }
            NavigationStack { ContactsView() }.tabItem { Label("Contacts", systemImage: "person.2") }
            NavigationStack { NetworkView() }.tabItem { Label("Network", systemImage: "antenna.radiowaves.left.and.right") }
            NavigationStack { IdentityView() }.tabItem { Label("Identity", systemImage: "key") }
        }
        .tint(Ink.accent)
    }
}

struct ChatsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        List {
            if model.state.bootstrap.phase != .open {
                StatusRow()
            }
            if model.state.conversations.isEmpty {
                Muted("No conversations yet. Add a contact by DIRECT ID on the Contacts tab.")
            }
            ForEach(model.state.conversations) { conversation in
                NavigationLink(value: conversation.peerId) {
                    HStack {
                        Avatar(name: conversation.name, jpeg: model.state.contacts.first { $0.directId == conversation.peerId }?.avatarJpegBase64)
                        StatusDot(color: model.state.connected.contains(conversation.peerId) ? Ink.success : model.state.online.contains(conversation.peerId) ? Ink.accent : Ink.muted)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(conversation.name).font(.headline)
                                if conversation.request { Text("Request").font(.caption).foregroundStyle(Ink.warning) }
                            }
                            Text(conversation.lastBody ?? "No messages").font(.subheadline).foregroundStyle(Ink.muted).lineLimit(1)
                        }
                        Spacer()
                        if conversation.unread > 0 {
                            Text("\(conversation.unread)").font(.caption.bold()).foregroundStyle(Color.white).padding(6).background(Ink.success, in: Circle())
                        }
                    }
                }
                .listRowBackground(Ink.surface)
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Chats")
        .navigationDestination(for: String.self) { ChatView(peerId: $0) }
    }
}

struct StatusRow: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let (label, color) = model.state.bootstrap.describe
        HStack {
            StatusDot(color: color)
            Text("Bootstrap: \(label)")
            Spacer()
            if model.state.pending > 0 { Text("\(model.state.pending) waiting").foregroundStyle(Ink.muted) }
        }
        .font(.footnote)
        .listRowBackground(Ink.surface)
    }
}

struct ChatView: View {
    let peerId: String
    @EnvironmentObject private var model: AppModel
    @State private var draft = ""

    private var contact: ContactRecord? { model.state.contacts.first { $0.directId == peerId } }
    private var messages: [MessageRecord] { model.state.messages[peerId] ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(messages) { message in
                            MediaBubble(message: message).id(message.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: messages.count) { _ in
                    if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    model.open(peerId)
                }
            }
            if let contact, !contact.accepted, !contact.blocked {
                Card {
                    Text("Message request").font(.headline)
                    Muted("\(contact.name) is not in your contacts. Accepting sends read receipts and lets you reply. Declining blocks this DIRECT ID.")
                    HStack {
                        PrimaryButton(title: "Accept") { model.accept(peerId) }
                        Button("Decline", role: .destructive) { model.decline(peerId) }.padding(.horizontal)
                    }
                }
                .padding()
            } else if contact?.blocked == true {
                Muted("Blocked. Messages from this DIRECT ID are dropped.").padding()
            } else {
                composer
            }
        }
        .navigationTitle(contact?.name ?? peerId)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { model.open(peerId) }
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var composer: some View {
        VStack(spacing: 12) {
            AttachmentBar(
                onPhoto: { model.sendMedia(peerId: peerId, kind: "image", mime: "image/jpeg", name: "photo.jpg", bytes: $0, caption: draft); draft = "" },
                onVideo: { model.sendMedia(peerId: peerId, kind: "video", mime: "video/mp4", name: "video.mp4", bytes: $0, caption: draft); draft = "" },
                onGif: { model.sendMedia(peerId: peerId, kind: "gif", mime: "image/gif", name: "animation.gif", bytes: $0, caption: draft); draft = "" },
                onSticker: { model.sendMedia(peerId: peerId, kind: "sticker", mime: "image/png", name: "sticker.png", bytes: $0, caption: ""); draft = "" },
                onVoice: { model.sendMedia(peerId: peerId, kind: "audio", mime: "audio/mp4", name: "voice.m4a", bytes: $0, caption: draft); draft = "" },
                onError: { model.toast = $0 }
            )
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message", text: $draft, axis: .vertical)
                    .font(.body)
                    .foregroundStyle(Ink.text)
                    .lineLimit(1...5)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Ink.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                Button {
                    model.send(peerId, draft)
                    draft = ""
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(canSend ? Color.white : Ink.muted)
                        .frame(width: 36, height: 36)
                        .background(canSend ? Ink.accent : Ink.surface, in: Circle())
                }
                .buttonStyle(ComposerPressStyle())
                .allowsHitTesting(canSend)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(Ink.background)
        .overlay(alignment: .top) { Rectangle().fill(Ink.line).frame(height: 0.5) }
    }
}

struct Bubble: View {
    let message: MessageRecord

    var body: some View {
        let outgoing = message.direction == .outgoing
        HStack {
            if outgoing { Spacer(minLength: 48) }
            VStack(alignment: outgoing ? .trailing : .leading, spacing: 4) {
                Text(message.body)
                    .foregroundStyle(outgoing ? Color.white : Ink.text)
                    .padding(10)
                    .background(outgoing ? Ink.accent : Ink.surface, in: RoundedRectangle(cornerRadius: 14))
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
            if !outgoing { Spacer(minLength: 48) }
        }
    }
}

struct ContactsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var input = ""
    @State private var scanning = false

    var body: some View {
        List {
            Section {
                Button("Scan a QR code") { scanning = true }.tint(Ink.accent)
                Field(placeholder: "dir_… or a pasted identity bundle", text: $input, monospaced: true)
                PrimaryButton(title: "Add contact", enabled: !input.isEmpty) {
                    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.hasPrefix("{") {
                        model.addFromShare(trimmed) { input = "" }
                    } else {
                        model.addContact(trimmed) { input = "" }
                    }
                }
                Muted("A DIRECT ID is looked up on the bootstrap, so the other phone must be open with the same bootstrap address. A QR code or pasted card works with no bootstrap at all.")
            }
            .listRowBackground(Ink.surface)
            Section("Contacts") {
                ForEach(model.state.contacts) { contact in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Avatar(name: contact.name, jpeg: contact.avatarJpegBase64)
                            StatusDot(color: model.state.online.contains(contact.directId) ? Ink.success : Ink.muted)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(contact.name).font(.headline)
                                if !contact.about.isEmpty { Text(contact.about).font(.caption).foregroundStyle(Ink.muted) }
                            }
                            if contact.verified { Image(systemName: "checkmark.seal.fill").foregroundStyle(Ink.success) }
                            if contact.blocked { Text("Blocked").font(.caption).foregroundStyle(Ink.danger) }
                            if !contact.accepted { Text("Request").font(.caption).foregroundStyle(Ink.warning) }
                        }
                        Text(contact.directId).font(.system(.caption, design: .monospaced)).foregroundStyle(Ink.muted)
                        Text("Safety number \(contact.fingerprint)").font(.system(.caption2, design: .monospaced)).foregroundStyle(Ink.muted)
                    }
                    .swipeActions {
                        Button("Remove", role: .destructive) { model.remove(contact.directId) }
                        Button(contact.verified ? "Unverify" : "Verified") { model.setVerified(contact.directId, !contact.verified) }.tint(Ink.success)
                    }
                }
            }
            .listRowBackground(Ink.surface)
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Contacts")
        .sheet(isPresented: $scanning) {
            NavigationStack {
                QrScannerView { text in
                    scanning = false
                    model.addFromShare(text)
                }
                .ignoresSafeArea()
                .navigationTitle("Scan QR")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { scanning = false } } }
            }
        }
    }
}

struct NetworkView: View {
    @EnvironmentObject private var model: AppModel
    @State private var input = ""

    var body: some View {
        List {
            Section {
                StatusRow()
                if let url = model.state.bootstrapUrl { Text(url).font(.system(.body, design: .monospaced)) }
                if let error = model.state.bootstrap.error { Muted(error) }
                if !model.state.networkAvailable { Muted("This phone has no network right now.") }
                Button("Reconnect now") { model.reconnect() }.tint(Ink.accent)
            }
            .listRowBackground(Ink.surface)
            Section("Bootstrap address") {
                Field(placeholder: "ws://192.168.1.20:8787", text: $input, monospaced: true)
                PrimaryButton(title: "Save", enabled: !input.isEmpty) { model.setBootstrap(input) }
                Muted("Run the signaling server on a computer, then enter the same ws://<computer address>:8787 on both phones. localhost does not work on a phone. The bootstrap only sees public bundles, presence, and connection setup; message text goes phone to phone.")
            }
            .listRowBackground(Ink.surface)
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Network")
        .onAppear { input = model.state.bootstrapUrl ?? "" }
    }
}

struct IdentityView: View {
    @EnvironmentObject private var model: AppModel
    @State private var status = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var showQr = false
    @State private var share = false

    var body: some View {
        List {
            if let profile = model.state.profile {
                Section {
                    HStack(spacing: 16) {
                        Avatar(name: profile.name, jpeg: profile.avatarJpegBase64)
                        VStack(alignment: .leading, spacing: 8) {
                            PhotosPicker(selection: $photoItem, matching: .images) {
                                Text("Profile photo").foregroundStyle(Ink.accent)
                            }
                            if profile.avatarJpegBase64 != nil {
                                Button("Remove photo") { model.clearAvatar() }.foregroundStyle(Ink.danger)
                            }
                        }
                    }
                    TextField("Status", text: $status)
                    Button("Save status") { model.setStatus(status) }.tint(Ink.accent)
                    Text(profile.name).font(.title3.bold())
                    Text(profile.directId).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    Button("Copy DIRECT ID") { model.copy(profile.directId, label: "DIRECT ID") }.tint(Ink.accent)
                    if let bundle = model.state.bundle {
                        let card = MediaPrep.shareCard(bundle: bundle, status: profile.status, avatarJpeg: profile.avatarJpegBase64.flatMap { Encoding.fromBase64Url($0) })
                        Button(showQr ? "Hide QR code" : "Show QR code") { showQr.toggle() }.tint(Ink.accent)
                        if showQr, let image = MediaPrep.qrImage(card) {
                            Image(uiImage: image).interpolation(.none).resizable().scaledToFit().frame(maxWidth: 240)
                            Muted("The QR code is your signed identity, plus the status and a small photo. The status and photo are for display. They are not part of the signature.")
                        }
                        Button("Share profile") { share = true }.tint(Ink.accent)
                        Button("Copy identity bundle") { model.copy(bundle, label: "Identity bundle") }.tint(Ink.accent)
                        Muted("Share sends the same card as the QR code, as text another DIRECT phone can add.")
                    }
                    Button("How DIRECT works") { model.showIntro = true }.tint(Ink.accent)
                }
                .listRowBackground(Ink.surface)
                .onAppear { status = profile.status }
                .onChange(of: profile.status) { status = $0 }
                .onChange(of: photoItem) { item in
                    Task {
                        guard let item, let data = try? await item.loadTransferable(type: Data.self) else { return }
                        do { model.setAvatar(try MediaPrep.avatar(data)) } catch { model.toast = (error as? PrepError)?.message ?? "That photo could not be used." }
                    }
                }
                .sheet(isPresented: $share) {
                    if let bundle = model.state.bundle {
                        let card = MediaPrep.shareCard(bundle: bundle, status: profile.status, avatarJpeg: profile.avatarJpegBase64.flatMap { Encoding.fromBase64Url($0) })
                        ShareSheet(items: [card])
                    }
                }
                Section("Recovery") {
                    Button("Show recovery phrase") { model.showPhrase() }.tint(Ink.warning)
                    Muted("The private key never leaves this phone's Keychain. The phrase is the only backup.")
                }
                .listRowBackground(Ink.surface)
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Identity")
    }
}
