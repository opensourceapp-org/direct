import AVFoundation
import AVKit
import DirectCore
import PhotosUI
import SwiftUI
import UIKit

func liveStories(_ state: NodeState, ownerId: String) -> [FeedItem] {
    state.feed.filter { $0.ownerId == ownerId && $0.channel == FeedNotes.story }.sorted { $0.createdAt < $1.createdAt }
}

func profilePosts(_ state: NodeState, ownerId: String) -> [FeedItem] {
    state.feed.filter { $0.ownerId == ownerId && $0.channel == FeedNotes.post }.sorted { $0.createdAt > $1.createdAt }
}

func storyOwners(_ state: NodeState, selfId: String) -> [String] {
    let grouped = Dictionary(grouping: state.feed.filter { $0.channel == FeedNotes.story }, by: \.ownerId)
    let contacts = state.contacts.filter { $0.accepted && !$0.blocked && grouped[$0.directId] != nil }
        .sorted { left, right in
            let leftSeen = grouped[left.directId]?.allSatisfy(\.seen) == true
            let rightSeen = grouped[right.directId]?.allSatisfy(\.seen) == true
            if leftSeen != rightSeen { return !leftSeen }
            return left.name < right.name
        }
    return [selfId] + contacts.map(\.directId)
}

func othersPosts(_ state: NodeState) -> [FeedItem] {
    guard let selfId = state.profile?.directId else { return [] }
    return state.feed.filter { $0.channel == FeedNotes.post && $0.ownerId != selfId }
        .sorted { $0.createdAt > $1.createdAt }
}

func feedOwnerName(_ state: NodeState, _ ownerId: String) -> String {
    if ownerId == state.profile?.directId { return state.profile?.name ?? "You" }
    return state.contacts.first { $0.directId == ownerId }?.name ?? ownerId
}

func feedOwnerJpeg(_ state: NodeState, _ ownerId: String) -> String? {
    if ownerId == state.profile?.directId { return state.profile?.avatarJpegBase64 }
    return state.contacts.first { $0.directId == ownerId }?.avatarJpegBase64
}

func formatFeedTime(_ ms: Int64) -> String {
    let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: date, relativeTo: Date())
}

func likeSummary(_ state: NodeState, _ item: FeedItem) -> String? {
    let names = item.likes.map { feedOwnerName(state, $0.fromId) }
    switch names.count {
    case 0: return nil
    case 1: return "Liked by \(names[0])"
    case 2: return "Liked by \(names[0]) and \(names[1])"
    default: return "Liked by \(names[0]) and \(names.count - 1) others"
    }
}

struct FeedView: View {
    @EnvironmentObject private var model: AppModel
    @State private var storyOwner: String?
    @State private var viewing: FeedItem?
    @State private var profilePeer: String?

    var body: some View {
        let posts = othersPosts(model.state)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                StoriesTray { storyOwner = $0 }
                    .padding(.top, 4)
                    .padding(.bottom, 8)
                if posts.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 52, weight: .ultraLight))
                            .foregroundStyle(.tertiary)
                            .padding(.bottom, 4)
                        Text("No Posts")
                            .font(.title2.weight(.semibold))
                        Text("When people you know share photos and videos, they appear here.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 28)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 72)
                } else {
                    LazyVStack(spacing: 20) {
                        ForEach(posts) { item in
                            FeedPostCard(item: item, onOpen: { viewing = item }, onProfile: { profilePeer = item.ownerId })
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
            }
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("Feed")
        .navigationBarTitleDisplayMode(.large)
        .fullScreenCover(isPresented: Binding(
            get: { storyOwner != nil },
            set: { if !$0 { storyOwner = nil } }
        )) {
            if let storyOwner {
                StoryViewer(ownerId: storyOwner) { self.storyOwner = nil }
                    .environmentObject(model)
            }
        }
        .sheet(item: $viewing) { post in
            FeedLightbox(id: post.id, canDelete: false)
                .environmentObject(model)
        }
        .sheet(isPresented: Binding(
            get: { profilePeer != nil },
            set: { if !$0 { profilePeer = nil } }
        )) {
            if let profilePeer {
                NavigationStack {
                    ContactProfileView(peerId: profilePeer)
                        .environmentObject(model)
                }
            }
        }
    }
}

struct FeedPostCard: View {
    @EnvironmentObject private var model: AppModel
    let item: FeedItem
    var onOpen: () -> Void
    var onProfile: () -> Void

    var body: some View {
        let name = feedOwnerName(model.state, item.ownerId)
        VStack(alignment: .leading, spacing: 10) {
            Button(action: onProfile) {
                HStack(spacing: 10) {
                    Avatar(name: name, jpeg: feedOwnerJpeg(model.state, item.ownerId), size: 36)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(name).font(.headline)
                        Text(formatFeedTime(item.createdAt)).font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
            }
            .buttonStyle(.plain)
            Button(action: onOpen) {
                FeedThumb(item: item)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            VStack(alignment: .leading, spacing: 6) {
                FeedActions(item: item, onComments: onOpen)
                if let summary = likeSummary(model.state, item) {
                    Text(summary).font(.subheadline.weight(.semibold))
                }
                if !item.caption.isEmpty {
                    Text(item.caption).font(.subheadline)
                }
                if !item.comments.isEmpty {
                    Button(action: onOpen) {
                        HStack(spacing: 4) {
                            Text(item.comments.count == 1 ? "1 Comment" : "\(item.comments.count) Comments")
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    if let latest = item.comments.last {
                        CommentRow(fromId: latest.fromId, text: latest.body, createdAt: latest.createdAt, compact: true)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

struct FeedActions: View {
    @EnvironmentObject private var model: AppModel
    let item: FeedItem
    var onComments: () -> Void = {}

    var body: some View {
        let liked = item.likes.contains { $0.fromId == model.state.profile?.directId }
        HStack(spacing: 18) {
            Button { model.likeFeed(item.id) } label: {
                Image(systemName: liked ? "heart.fill" : "heart")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(liked ? Color.pink : Color.primary)
                    .symbolRenderingMode(.monochrome)
            }
            Button(action: onComments) {
                Image(systemName: "bubble.right")
                    .font(.system(size: 19, weight: .regular))
                    .foregroundStyle(.primary)
            }
            Spacer()
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
    }
}

struct CommentRow: View {
    @EnvironmentObject private var model: AppModel
    let fromId: String
    let text: String
    let createdAt: Int64
    var compact = false

    var body: some View {
        let name = feedOwnerName(model.state, fromId)
        HStack(alignment: .top, spacing: 10) {
            Avatar(name: name, jpeg: feedOwnerJpeg(model.state, fromId), size: compact ? 28 : 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(compact ? .footnote.weight(.semibold) : .subheadline.weight(.semibold))
                Text(text)
                    .font(compact ? .footnote : .subheadline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(formatFeedTime(createdAt)).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}

struct StoriesTray: View {
    @EnvironmentObject private var model: AppModel
    var onOpen: (String) -> Void
    @State private var photoItem: PhotosPickerItem?

    var body: some View {
        let selfId = model.state.profile?.directId
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 16) {
                if let selfId {
                    ForEach(storyOwners(model.state, selfId: selfId), id: \.self) { ownerId in
                        let stories = liveStories(model.state, ownerId: ownerId)
                        let selfStory = ownerId == selfId
                        let name = selfStory ? "You" : model.state.contacts.first { $0.directId == ownerId }?.name ?? ownerId
                        let jpeg = selfStory ? model.state.profile?.avatarJpegBase64 : model.state.contacts.first { $0.directId == ownerId }?.avatarJpegBase64
                        let unseen = stories.contains { !$0.seen }
                        VStack(spacing: 6) {
                            ZStack(alignment: .bottomTrailing) {
                                Button {
                                    if !stories.isEmpty { onOpen(ownerId) }
                                } label: {
                                    Avatar(name: name, jpeg: jpeg, size: 58)
                                        .padding(3)
                                        .overlay {
                                            Circle().strokeBorder(
                                                stories.isEmpty ? Color(uiColor: .tertiarySystemFill) : (unseen ? Color.accentColor : Color(uiColor: .tertiaryLabel)),
                                                lineWidth: 2
                                            )
                                        }
                                }
                                .buttonStyle(.plain)
                                if selfStory {
                                    PhotosPicker(selection: $photoItem, matching: .any(of: [.images, .videos])) {
                                        Image(systemName: "plus.circle.fill")
                                            .symbolRenderingMode(.palette)
                                            .foregroundStyle(.white, Color.accentColor)
                                            .font(.system(size: 20))
                                            .background(Circle().fill(Color(uiColor: .systemGroupedBackground)).padding(2))
                                    }
                                }
                            }
                            Text(name)
                                .font(.caption2)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .frame(width: 72)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .onChange(of: photoItem) { item in
            Task { await publish(item) }
        }
    }

    private func publish(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        do {
            let prepared = try await loadFeedMedia(item, fallbackKind: "image")
            model.publishFeed(channel: FeedNotes.story, kind: prepared.kind, mime: prepared.mime, name: prepared.name, bytes: prepared.bytes)
        } catch {
            await MainActor.run { model.toast = (error as? PrepError)?.message ?? "That story was not added." }
        }
        await MainActor.run { photoItem = nil }
    }
}

struct StoryViewer: View {
    @EnvironmentObject private var model: AppModel
    let ownerId: String
    var onClose: () -> Void
    @State private var index = 0
    @State private var bytes: Data?

    var body: some View {
        let stories = liveStories(model.state, ownerId: ownerId)
        let current = stories.indices.contains(index) ? stories[index] : stories.last
        let name = ownerId == model.state.profile?.directId ? (model.state.profile?.name ?? "You") : (model.state.contacts.first { $0.directId == ownerId }?.name ?? ownerId)
        ZStack {
            Color.black.ignoresSafeArea()
            if let current, let bytes, current.kind != "video", let image = UIImage(data: bytes) {
                Image(uiImage: image).resizable().scaledToFit()
            } else if let current, let bytes, current.kind == "video" {
                StoryVideo(data: bytes, name: current.name)
            }
            HStack(spacing: 0) {
                Color.clear.contentShape(Rectangle()).onTapGesture {
                    if index == 0 { onClose() } else { index -= 1 }
                }
                Color.clear.contentShape(Rectangle()).onTapGesture {
                    if index + 1 < stories.count { index += 1 } else { onClose() }
                }
            }
            VStack {
                HStack(spacing: 4) {
                    ForEach(Array(stories.enumerated()), id: \.element.id) { i, _ in
                        Capsule().fill(i <= index ? Color.white : Color.white.opacity(0.28)).frame(height: 3)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
                HStack {
                    Text(name).font(.headline).foregroundStyle(.white)
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.black.opacity(0.35))
                    }
                    .accessibilityLabel("Close")
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                Spacer()
            }
        }
        .onAppear {
            model.markStoriesSeen(ownerId)
            load()
        }
        .onChange(of: index) { _ in load() }
        .task(id: current?.id) {
            guard let current, current.kind != "video" else { return }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if index + 1 < liveStories(model.state, ownerId: ownerId).count { index += 1 } else { onClose() }
        }
    }

    private func load() {
        let stories = liveStories(model.state, ownerId: ownerId)
        guard stories.indices.contains(index) else { bytes = nil; return }
        model.loadFeed(stories[index].id) { bytes = $0 }
    }
}

private struct StoryVideo: View {
    let data: Data
    let name: String
    @State private var player: AVPlayer?

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
            } else {
                ProgressView().tint(.white)
            }
        }
        .onAppear {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(name.isEmpty ? "story.mp4" : name)
            try? data.write(to: url)
            let next = AVPlayer(url: url)
            player = next
            next.play()
        }
        .onDisappear { player?.pause() }
    }
}

struct ProfilePosts: View {
    @EnvironmentObject private var model: AppModel
    let ownerId: String
    var canAdd: Bool
    var showsHeading: Bool = true
    @State private var item: PhotosPickerItem?
    @State private var viewing: FeedItem?

    var body: some View {
        let posts = profilePosts(model.state, ownerId: ownerId)
        VStack(alignment: .leading, spacing: 10) {
            if showsHeading || canAdd {
                HStack {
                    if showsHeading {
                        Text("Photos & Videos").font(.title3.weight(.semibold))
                    }
                    Spacer()
                    if canAdd {
                        PhotosPicker(selection: $item, matching: .any(of: [.images, .videos])) {
                            Image(systemName: "plus.circle.fill")
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(Color.accentColor)
                                .font(.title3)
                        }
                    }
                }
                .padding(.horizontal, showsHeading ? 0 : 16)
            }
            if posts.isEmpty {
                Muted(canAdd ? "Add photos and videos to your profile. Accepted contacts see them." : "No photos or videos on this profile yet.")
                    .padding(.horizontal, showsHeading ? 0 : 16)
            } else {
                VStack(spacing: 2) {
                    ForEach(Array(stride(from: 0, to: posts.count, by: 3)), id: \.self) { start in
                        let row = Array(posts[start..<min(start + 3, posts.count)])
                        HStack(spacing: 2) {
                            ForEach(row) { post in
                                Button { viewing = post } label: {
                                    FeedThumb(item: post)
                                }
                                .buttonStyle(.plain)
                                .frame(maxWidth: .infinity)
                            }
                            ForEach(0..<(3 - row.count), id: \.self) { _ in
                                Color.clear.aspectRatio(1, contentMode: .fit).frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
            }
        }
        .onChange(of: item) { picked in
            Task {
                guard let picked else { return }
                do {
                    let prepared = try await loadFeedMedia(picked, fallbackKind: "image")
                    model.publishFeed(channel: FeedNotes.post, kind: prepared.kind, mime: prepared.mime, name: prepared.name, bytes: prepared.bytes)
                } catch {
                    await MainActor.run { model.toast = (error as? PrepError)?.message ?? "That post was not added." }
                }
                await MainActor.run { item = nil }
            }
        }
        .sheet(item: $viewing) { post in
            FeedLightbox(id: post.id, canDelete: canAdd)
                .environmentObject(model)
        }
    }
}

struct ContactProfileView: View {
    @EnvironmentObject private var model: AppModel
    let peerId: String
    @Environment(\.dismiss) private var dismiss
    @State private var storyOpen = false

    var body: some View {
        let selfProfile = peerId == model.state.profile?.directId
        let contact = model.state.contacts.first { $0.directId == peerId }
        let name = selfProfile ? (model.state.profile?.name ?? "You") : (contact?.name ?? peerId)
        let jpeg = selfProfile ? model.state.profile?.avatarJpegBase64 : contact?.avatarJpegBase64
        let about = selfProfile ? (model.state.profile?.status ?? "") : (contact?.about ?? "")
        let stories = liveStories(model.state, ownerId: peerId)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 16) {
                    Button { if !stories.isEmpty { storyOpen = true } } label: {
                        Avatar(name: name, jpeg: jpeg, size: 72)
                            .overlay {
                                Circle().strokeBorder(stories.isEmpty ? Color.clear : Color.accentColor, lineWidth: 2)
                            }
                    }
                    .buttonStyle(.plain)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(name).font(.title2.weight(.semibold))
                        if !about.isEmpty { Text(about).foregroundStyle(.secondary) }
                        Text(profilePosts(model.state, ownerId: peerId).count == 1 ? "1 Photo" : "\(profilePosts(model.state, ownerId: peerId).count) Photos")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                ProfilePosts(ownerId: peerId, canAdd: selfProfile)
            }
            .padding()
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
            }
        }
        .fullScreenCover(isPresented: $storyOpen) {
            StoryViewer(ownerId: peerId) { storyOpen = false }
                .environmentObject(model)
        }
    }
}

struct FeedThumb: View {
    @EnvironmentObject private var model: AppModel
    let item: FeedItem
    @State private var bytes: Data?

    var body: some View {
        ZStack {
            if let bytes, let image = UIImage(data: bytes) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Color(uiColor: .tertiarySystemFill)
            }
            if item.kind == "video" {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 40))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white)
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(1, contentMode: .fit)
        .clipped()
        .onAppear { model.loadFeed(item.id) { bytes = $0 } }
        .onChange(of: item.mediaFile) { _ in model.loadFeed(item.id) { bytes = $0 } }
    }
}

struct FeedLightbox: View {
    @EnvironmentObject private var model: AppModel
    let id: String
    var canDelete: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var bytes: Data?
    @State private var draft = ""
    @State private var confirmDelete = false

    var body: some View {
        let item = model.state.feed.first { $0.id == id }
        let name = item.map { feedOwnerName(model.state, $0.ownerId) } ?? "Post"
        NavigationStack {
            VStack(spacing: 0) {
                ZStack {
                    Color(uiColor: .secondarySystemFill)
                    if let item, let bytes, item.kind != "video", let image = UIImage(data: bytes) {
                        Image(uiImage: image).resizable().scaledToFit()
                    } else if let item, let bytes, item.kind == "video" {
                        StoryVideo(data: bytes, name: item.name)
                    } else {
                        ProgressView()
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 280)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(.horizontal, 16)
                .padding(.top, 8)
                if let item {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            Avatar(name: name, jpeg: feedOwnerJpeg(model.state, item.ownerId), size: 36)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(name).font(.headline)
                                Text(formatFeedTime(item.createdAt)).font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        FeedActions(item: item)
                        if let summary = likeSummary(model.state, item) {
                            Text(summary).font(.subheadline.weight(.semibold))
                        }
                        if !item.caption.isEmpty {
                            Text(item.caption).font(.body)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 8)
                    Divider()
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 14) {
                                if item.comments.isEmpty {
                                    Text("No Comments")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                } else {
                                    ForEach(item.comments) { comment in
                                        CommentRow(fromId: comment.fromId, text: comment.body, createdAt: comment.createdAt)
                                            .id(comment.id)
                                    }
                                }
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .layoutPriority(1)
                        .onChange(of: item.comments.count) { _ in
                            if let last = item.comments.last {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                } else {
                    Spacer()
                }
            }
            .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
            .navigationTitle(name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                if canDelete, item != nil {
                    ToolbarItem(placement: .destructiveAction) {
                        Button("Delete", role: .destructive) { confirmDelete = true }
                    }
                }
            }
            .confirmationDialog("Delete this post?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete Post", role: .destructive) {
                    model.deleteFeed(id)
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("It will be removed from your profile and from people who already received it.")
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let item {
                    commentComposer(item.id)
                }
            }
        }
        .presentationDragIndicator(.visible)
        .onAppear { model.loadFeed(id) { bytes = $0 } }
    }

    @ViewBuilder
    private func commentComposer(_ postId: String) -> some View {
        let ready = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        VStack(spacing: 0) {
            Divider()
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Add a comment", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .textInputAutocapitalization(.sentences)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                Button {
                    let body = draft
                    draft = ""
                    model.commentFeed(postId, body)
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 32))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, ready ? Color.accentColor : Color(uiColor: .tertiaryLabel))
                }
                .disabled(!ready)
                .accessibilityLabel("Send")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(.bar)
    }
}

private func loadFeedMedia(_ item: PhotosPickerItem, fallbackKind: String) async throws -> (kind: String, mime: String, name: String, bytes: Data) {
    if fallbackKind == "video" || item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
        guard let video = try await item.loadTransferable(type: VideoBytes.self) else {
            throw PrepError("That video could not be read.")
        }
        return try MediaPrep.video(video.data, mime: "video/mp4")
    }
    guard let data = try await item.loadTransferable(type: Data.self) else {
        throw PrepError("That photo could not be read.")
    }
    if item.supportedContentTypes.contains(.gif) || data.starts(with: Data("GIF8".utf8)) {
        guard data.count <= MediaPrep.maxBytes else { throw PrepError("That GIF is over 6 MB. Choose a shorter one.") }
        return ("image", "image/gif", "animation.gif", data)
    }
    let photo = try MediaPrep.photo(data)
    return (photo.kind == "gif" ? "image" : photo.kind, photo.mime, photo.name, photo.bytes)
}
