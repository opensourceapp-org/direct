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
            if let call = model.state.call {
                CallScreen(call: call).ignoresSafeArea()
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
        .scrollDismissesKeyboard(.interactively)
        .onAppear { KeyboardDismiss.shared.install() }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { Keyboard.dismiss() }
                    .font(.body.weight(.semibold))
            }
        }
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
    @EnvironmentObject private var model: AppModel

    var body: some View {
        TabView(selection: $model.tab) {
            NavigationStack(path: $model.chatPath) { ChatsView() }
                .tabItem { Label("Chats", systemImage: "bubble.left.and.bubble.right") }
                .tag(HomeTab.chats)
            NavigationStack { ContactsView() }
                .tabItem { Label("Contacts", systemImage: "person.2") }
                .tag(HomeTab.contacts)
            NavigationStack { NetworkView() }
                .tabItem { Label("Network", systemImage: "antenna.radiowaves.left.and.right") }
                .tag(HomeTab.network)
            NavigationStack { IdentityView() }
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(HomeTab.settings)
        }
        .tint(Ink.accent)
        .onChange(of: model.chatPath) { path in
            if let peer = path.last { MessageAlerts.cancel(threadId: peer) }
        }
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
                                if conversation.group { Text("Group").font(.caption).foregroundStyle(Ink.accent) }
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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { NewGroupView() } label: {
                    Image(systemName: "person.3")
                }
                .accessibilityLabel("New group")
            }
        }
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
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @State private var draft = ""
    @State private var attachments = false

    private var contact: ContactRecord? { model.state.contacts.first { $0.directId == peerId } }
    private var group: GroupRecord? { model.state.groups.first { $0.id == peerId } }
    private var conversation: Conversation? { model.state.conversations.first { $0.peerId == peerId } }
    private var isGroup: Bool { group != nil || conversation?.group == true }
    private var messages: [MessageRecord] { model.state.messages[peerId] ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                            let previous = index > 0 ? messages[index - 1] : nil
                            let next = index + 1 < messages.count ? messages[index + 1] : nil
                            let continues = next.map { $0.direction == message.direction && !messageGap(message, $0) } ?? false
                            VStack(spacing: 2) {
                                if messageGap(previous, message) {
                                    Text(formatTime(message.createdAt))
                                        .font(.caption2)
                                        .foregroundStyle(Ink.muted)
                                        .frame(maxWidth: .infinity)
                                        .padding(.top, 12)
                                        .padding(.bottom, 4)
                                }
                                if isGroup, message.direction == .incoming, let sender = senderName(message) {
                                    Text(sender)
                                        .font(.caption2)
                                        .foregroundStyle(Ink.muted)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.leading, 8)
                                }
                                MediaBubble(message: message, tail: !continues, showReceipt: !continues && message.direction == .outgoing)
                            }
                            .padding(.top, previous?.direction == message.direction && !messageGap(previous, message) ? 2 : 8)
                            .id(message.id)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: messages.count) { _ in
                    if let last = messages.last {
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
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
            } else if isGroup || contact != nil {
                composer
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .onAppear { model.open(peerId) }
    }

    /// Back control, photo, and name share one row. The status sits under the name, beside the photo.
    private var header: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.backward")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Ink.accent)
                        .frame(width: 28, height: 40)
                }
                .buttonStyle(.plain)
                Avatar(name: contact?.name ?? conversation?.name ?? "?", jpeg: contact?.avatarJpegBase64, size: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text(contact?.name ?? conversation?.name ?? peerId)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Ink.text)
                        .lineLimit(1)
                    Text(presence)
                        .font(.system(size: 13))
                        .foregroundStyle(Ink.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if isGroup || (contact?.accepted == true && contact?.blocked != true) {
                    Button { model.placeCall(peerId, video: false) } label: {
                        Image(systemName: "phone.fill").font(.system(size: 18)).foregroundStyle(Ink.accent).frame(width: 36, height: 40)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Audio call")
                    Button { model.placeCall(peerId, video: true) } label: {
                        Image(systemName: "video.fill").font(.system(size: 18)).foregroundStyle(Ink.accent).frame(width: 36, height: 40)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Video call")
                }
            }
            .padding(.leading, 8)
            .padding(.trailing, 16)
            .padding(.vertical, 4)
            Divider().overlay(Ink.line)
        }
        .background(Ink.background)
    }

    private var presence: String {
        if isGroup { return "\(group?.members.count ?? conversation?.memberCount ?? 0) members" }
        guard let contact else { return "Not a contact" }
        if contact.blocked { return "Blocked" }
        if !contact.accepted { return "Message request" }
        if model.state.connected.contains(peerId) { return "Connected directly" }
        if model.state.online.contains(peerId) { return "On the bootstrap" }
        return "Offline · messages wait on this phone"
    }

    private func senderName(_ message: MessageRecord) -> String? {
        guard let id = message.senderId else { return nil }
        return model.state.contacts.first { $0.directId == id }?.name ?? id
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func messageGap(_ earlier: MessageRecord?, _ later: MessageRecord) -> Bool {
        guard let earlier else { return true }
        return later.createdAt - earlier.createdAt > 5 * 60 * 1000
    }

    private var composer: some View {
        VStack(spacing: 0) {
            AttachmentBar(expanded: $attachments,
                onPhoto: { sendAttachment(kind: "image", mime: "image/jpeg", name: "photo.jpg", bytes: $0) },
                onVideo: { sendAttachment(kind: "video", mime: "video/mp4", name: "video.mp4", bytes: $0) },
                onGif: { sendAttachment(kind: "gif", mime: "image/gif", name: "animation.gif", bytes: $0) },
                onSticker: { sendAttachment(kind: "sticker", mime: "image/png", name: "sticker.png", bytes: $0, caption: "") },
                onVoice: { sendAttachment(kind: "audio", mime: "audio/mp4", name: "voice.m4a", bytes: $0) },
                onError: { model.toast = $0 }
            )
            HStack(alignment: .bottom, spacing: 8) {
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { attachments.toggle() }
                } label: {
                    Image(systemName: attachments ? "xmark" : "plus")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Ink.accent)
                        .frame(width: 36, height: 36)
                        .background(Ink.surface, in: Circle())
                }
                .buttonStyle(ComposerPressStyle())
                TextField("Message", text: $draft, axis: .vertical)
                    .font(.body)
                    .foregroundStyle(Ink.text)
                    .lineLimit(1...5)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Ink.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                Button {
                    sendDraft()
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
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(Ink.background)
        .overlay(alignment: .top) { Rectangle().fill(Ink.line).frame(height: 0.5) }
        .animation(.easeOut(duration: 0.2), value: attachments)
    }

    private func sendDraft() {
        let body = draft
        draft = ""
        withAnimation(.easeOut(duration: 0.2)) { attachments = false }
        SendFeedback.play()
        model.send(peerId, body)
    }

    private func sendAttachment(kind: String, mime: String, name: String, bytes: Data, caption: String? = nil) {
        let text = caption ?? draft
        draft = ""
        withAnimation(.easeOut(duration: 0.2)) { attachments = false }
        SendFeedback.play()
        model.sendMedia(peerId: peerId, kind: kind, mime: mime, name: name, bytes: bytes, caption: text)
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
                    .font(.system(size: 17))
                    .foregroundStyle(outgoing ? Color.white : Ink.text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(outgoing ? Ink.accent : Ink.incoming, in: messageBubble(outgoing, tail: true))
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

struct NewGroupView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var selected: Set<String> = []

    private var people: [ContactRecord] {
        model.state.contacts.filter { $0.accepted && !$0.blocked }
    }

    var body: some View {
        List {
            Section {
                Field(placeholder: "Weekend", text: $name)
                PrimaryButton(title: "Create group", enabled: !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !selected.isEmpty) {
                    model.createGroup(name: name, memberIds: Array(selected)) { id in
                        dismiss()
                    }
                }
                Muted("Pick at least one accepted contact. Each member gets their own sealed invite.")
            }
            .listRowBackground(Ink.surface)
            Section("Members") {
                if people.isEmpty {
                    Muted("Add an accepted contact before you create a group.")
                }
                ForEach(people) { contact in
                    Button {
                        if selected.contains(contact.directId) { selected.remove(contact.directId) } else { selected.insert(contact.directId) }
                    } label: {
                        HStack {
                            Avatar(name: contact.name, jpeg: contact.avatarJpegBase64)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(contact.name).font(.headline).foregroundStyle(Ink.text)
                                Text(contact.directId).font(.system(.caption, design: .monospaced)).foregroundStyle(Ink.muted)
                            }
                            Spacer()
                            Image(systemName: selected.contains(contact.directId) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selected.contains(contact.directId) ? Ink.accent : Ink.muted)
                        }
                    }
                }
            }
            .listRowBackground(Ink.surface)
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("New group")
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
                Muted("A DIRECT ID is looked up on the server, so the other phone must be open on that same address. A QR code or pasted card also carries the server, and scanning it saves that address on this phone.")
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
    @State private var help = false

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
                Field(placeholder: BootstrapUrl.defaultUrl, text: $input, monospaced: true)
                PrimaryButton(title: "Save", enabled: !input.isEmpty) { model.setBootstrap(input) }
                Muted("This phone uses the public DIRECT signaling server unless you save a different address. Both phones must use the same value. localhost does not work on a phone. The bootstrap only sees public bundles, presence, and connection setup; message text goes phone to phone.")
            }
            .listRowBackground(Ink.surface)
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Network")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { help = true } label: {
                    Image(systemName: "questionmark.circle")
                }
                .accessibilityLabel("How to run your own server")
            }
        }
        .sheet(isPresented: $help) {
            NavigationStack {
                ServerHelp()
                    .navigationTitle("Your server")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { help = false }
                        }
                    }
            }
        }
        .onAppear { input = model.state.bootstrapUrl ?? BootstrapUrl.defaultUrl }
    }
}

private struct ServerHelp: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Phones already use the public DIRECT signaling server. Open Network and you will see that address filled in. Save a different address only if you want both phones on your own server.")
                    .foregroundStyle(Ink.muted)
                helpCode(BootstrapUrl.defaultUrl)
                Text("To run your own server, download Direct Server for Mac, Windows, or Linux from https://direct-server.apps.grok.bot. Open the app, press Start server, and share the address it shows. Each phone that connects is listed in the window.")
                    .foregroundStyle(Ink.muted)
                helpCode("https://direct-server.apps.grok.bot")
                Text("To run it from source instead, clone the project. On a Mac, double-click Start Server.command in that folder. Direct.app is the iPhone app. macOS will not open it.")
                    .foregroundStyle(Ink.muted)
                helpCode("git clone https://github.com/opensourceapp-org/direct.git\ncd direct\npnpm install\npnpm server")
                Text("The server only introduces the two phones. It does not store messages, photos, voice notes, or calls.")
                    .foregroundStyle(Ink.muted)
                helpBlock("What you need", "A computer both phones can reach. The download does not need Node.js. From source, you need Node.js 22 or newer, pnpm, and this DIRECT project on that computer.")
                helpBlock("Start it", "Open Direct Server, or run pnpm server from source. Press Start server. The window shows one address for each network on that computer and lists each phone that connects. Closing the window stops the server. The same server can run in a terminal with pnpm signaling. Leave that terminal open. Use the address your phones are on, for example:")
                    .foregroundStyle(Ink.muted)
                helpCode("ws://192.168.1.20:8787")
                Text("Allow TCP port 8787 through that computer's firewall. On both phones, open Network, paste that address, and save it. Both phones must save the same address.")
                    .foregroundStyle(Ink.muted)
                helpBlock("Check that it is running", "On the same network, open this page in a browser. Replace the example with the address the window or the terminal showed.")
                helpCode("http://192.168.1.20:8787/health")
                Text("A working server answers:")
                    .foregroundStyle(Ink.muted)
                helpCode("{\"ok\":true,\"service\":\"direct-signaling\",\"contract\":1}")
                Text("The page at the server root is a short note that this is the DIRECT signaling server.")
                    .foregroundStyle(Ink.muted)
                helpCode("http://192.168.1.20:8787")
                helpBlock("Addresses the phone accepts", "A bare host is saved as ws:// and port 8787. http:// is saved as ws://. https:// is saved as wss://. The host is lowercased, and a trailing slash is removed.")
                helpCode("ws://192.168.1.20:8787\n192.168.1.20\nhttp://192.168.1.20:8787\nhttps://signals.example.com")
                Text("Do not enter localhost, 127.0.0.1, or 0.0.0.0. On a phone those names mean the phone itself.")
                    .foregroundStyle(Ink.muted)
                helpBlock("Choose a port", "8787 is the default. The server listens on every network interface of that computer unless you set HOST to one address.")
                helpCode("PORT=9000 pnpm signaling\nws://192.168.1.20:9000")
                helpBlock("Phones away from your Wi-Fi", "A 192.168 address only works on that local network. Forward TCP 8787 to this computer, or run the server where both phones can reach it, and save that address. This server speaks plain WebSocket and does not add TLS itself. For a public wss:// address, put a TLS proxy in front of port 8787 and save wss://your.host, or https://your.host.")
                helpBlock("What it is allowed to see", "Public identity bundles, who is online, and the WebRTC setup that connects the phones. The message itself stays sealed on the phones.")
            }
            .font(.subheadline)
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Ink.background)
    }

    private func helpBlock(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline).foregroundStyle(Ink.text)
            Text(body).foregroundStyle(Ink.muted)
        }
    }

    private func helpCode(_ text: String) -> some View {
        Text(text)
            .font(.system(.footnote, design: .monospaced))
            .foregroundStyle(Ink.text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Ink.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Ink.line))
    }
}

struct IdentityView: View {
    @EnvironmentObject private var model: AppModel
    @State private var status = ""
    /// The draft last written by Save status. The button shows Saved while the field still matches it.
    @State private var acknowledged: String?
    @State private var photoItem: PhotosPickerItem?
    @State private var showQr = false
    @State private var qrImage: UIImage?
    @State private var share = false

    var body: some View {
        List {
            if let profile = model.state.profile {
                Section {
                    HStack(spacing: 16) {
                        Avatar(name: profile.name, jpeg: profile.avatarJpegBase64, size: 64)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(profile.name).font(.title3.bold())
                            Text("Your name").font(.caption).foregroundStyle(Ink.muted)
                            if !profile.status.isEmpty {
                                Text(profile.status).font(.subheadline)
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("DIRECT ID").font(.caption).foregroundStyle(Ink.muted)
                        Text(profile.directId)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        actionLabel("Change photo", icon: "camera", tint: Ink.accent)
                    }
                    .buttonStyle(.plain)
                    if profile.avatarJpegBase64 != nil {
                        Button { model.clearAvatar() } label: {
                            actionLabel("Remove photo", icon: "trash", tint: Ink.danger)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listRowBackground(Ink.surface)
                Section {
                    Field(placeholder: "Write your own status", text: $status)
                    PrimaryButton(title: acknowledged == statusDraft ? "Saved" : "Save status") {
                        acknowledged = statusDraft
                        model.setStatus(status)
                    }
                    if acknowledged == statusDraft {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Ink.success)
                            Text(statusDraft.isEmpty ? "Status cleared" : "Status saved")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Ink.success)
                        }
                    }
                    Picker("Choose a status", selection: Binding(
                        get: { StatusPresets.all.contains(profile.status) ? profile.status : "" },
                        set: { choice in
                            guard !choice.isEmpty else { return }
                            status = choice
                            acknowledged = choice
                            model.setStatus(choice)
                        }
                    )) {
                        Text("Choose a status").tag("")
                        ForEach(StatusPresets.all, id: \.self) { preset in
                            Text(preset).tag(preset)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(Ink.accent)
                } header: {
                    Text("Status")
                } footer: {
                    Text("Choose one, or write your own and tap Save status.")
                }
                .listRowBackground(Ink.surface)
                if let bundle = model.state.bundle {
                    let server = model.state.bootstrapUrl ?? ""
                    let card = MediaPrep.shareCard(bundle: bundle, status: profile.status, avatarJpeg: profile.avatarJpegBase64.flatMap { Encoding.fromBase64Url($0) }, bootstrap: server)
                    Section {
                        Button {
                            showQr.toggle()
                            qrImage = showQr ? MediaPrep.qrImage(card) : nil
                        } label: {
                            actionLabel(showQr ? "Hide QR code" : "Show QR code", icon: "qrcode", tint: Ink.accent)
                        }
                        .buttonStyle(.plain)
                        if showQr {
                            VStack(alignment: .leading, spacing: 8) {
                                if let qrImage {
                                    Image(uiImage: qrImage)
                                        .interpolation(.none)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 220, height: 220)
                                        .padding(12)
                                        .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                } else {
                                    Muted("This profile is too large to draw as a QR code. Share it instead, or remove the photo and try again.")
                                }
                                Muted(server.isEmpty
                                    ? "Set the server under Network before sharing. Without that address, the other phone can save your identity but cannot connect."
                                    : "The QR code is your signed identity and your server address, plus the status and a small photo. Scanning it saves that server so the two phones can connect. The status and photo are for display. They are not part of the signature.")
                            }
                        }
                        Button { share = true } label: {
                            actionLabel("Share profile", icon: "square.and.arrow.up", tint: Ink.accent)
                        }
                        .buttonStyle(.plain)
                        Button { model.copy(profile.directId, label: "DIRECT ID") } label: {
                            actionLabel("Copy DIRECT ID", icon: "doc.on.doc", tint: Ink.accent)
                        }
                        .buttonStyle(.plain)
                        Button { model.copy(bundle, label: "Identity bundle") } label: {
                            actionLabel("Copy identity bundle", icon: "doc.on.doc", tint: Ink.accent)
                        }
                        .buttonStyle(.plain)
                        Muted(server.isEmpty
                            ? "Share includes your name and DIRECT ID. Set the server under Network first, or the other phone will not know where to connect."
                            : "Share sends a picture of your QR code, with your name, DIRECT ID, and server address. Scanning it saves that server on the other phone.")
                    } header: {
                        Text("Share")
                    }
                    .listRowBackground(Ink.surface)
                }
                Section {
                    Button { model.showIntro = true } label: {
                        actionLabel("How DIRECT works", icon: "info.circle", tint: Ink.accent)
                    }
                    .buttonStyle(.plain)
                }
                .listRowBackground(Ink.surface)
                Section {
                    Button { model.showPhrase() } label: {
                        actionLabel("Show recovery phrase", icon: "key", tint: Ink.warning)
                    }
                    .buttonStyle(.plain)
                    Muted("The private key never leaves this phone's Keychain. The phrase is the only backup.")
                } header: {
                    Text("Recovery")
                }
                .listRowBackground(Ink.surface)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .navigationTitle("Settings")
        .onAppear { status = model.state.profile?.status ?? "" }
        .onChange(of: model.state.profile?.status) { status = $0 ?? "" }
        .onChange(of: photoItem) { item in
            Task {
                guard let item, let data = try? await item.loadTransferable(type: Data.self) else { return }
                do { model.setAvatar(try MediaPrep.avatar(data)) } catch { model.toast = (error as? PrepError)?.message ?? "That photo could not be used." }
            }
        }
        .sheet(isPresented: $share) {
            if let profile = model.state.profile, let bundle = model.state.bundle {
                let server = model.state.bootstrapUrl ?? ""
                let card = MediaPrep.shareCard(bundle: bundle, status: profile.status, avatarJpeg: profile.avatarJpegBase64.flatMap { Encoding.fromBase64Url($0) }, bootstrap: server)
                let caption = MediaPrep.profileShareCaption(name: profile.name, status: profile.status, directId: profile.directId, server: server)
                if let image = MediaPrep.profileCardImage(name: profile.name, status: profile.status, directId: profile.directId, server: server, qrText: card) {
                    ShareSheet(items: [image, caption])
                } else {
                    ShareSheet(items: [caption])
                }
            }
        }
    }

    private var statusDraft: String { status.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func actionLabel(_ title: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(title)
                .font(.body.weight(.medium))
                .foregroundStyle(Ink.text)
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Ink.muted)
        }
        .contentShape(Rectangle())
    }
}

private enum StatusPresets {
    static let all = [
        "😊 Available",
        "🔴 Busy",
        "📚 At school",
        "🎬 At the movies",
        "💼 At work",
        "🔋 Battery about to die",
        "📵 Can't talk, messages only",
        "📅 In a meeting",
        "🏋️ At the gym",
        "😴 Sleeping",
        "🚨 Urgent calls only",
    ]
}
