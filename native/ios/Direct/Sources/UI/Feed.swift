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
    @State private var viewingId: String?
    @State private var profilePeer: String?

    var body: some View {
        let posts = othersPosts(model.state)
        List {
            Section {
                StoriesTray { storyOwner = $0 }
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            if posts.isEmpty {
                Section {
                    VStack(spacing: 10) {
                        Image(systemName: "newspaper")
                            .font(.system(size: 40, weight: .ultraLight))
                            .foregroundStyle(.tertiary)
                            .padding(.bottom, 2)
                        Text("No Posts")
                            .font(.title3.weight(.semibold))
                        Text("When people you know share photos and videos, they appear here.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 12)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 48)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            } else {
                ForEach(posts) { item in
                    Section {
                        FeedPostCard(item: item, onOpen: { viewingId = item.id }, onProfile: { profilePeer = item.ownerId })
                            .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 14, trailing: 16))
                            .listRowBackground(Ink.surface)
                            .listRowSeparator(.hidden)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Ink.background)
        .navigationTitle("Feed")
        .navigationBarTitleDisplayMode(.large)
        .navigationDestination(isPresented: Binding(
            get: { viewingId != nil },
            set: { if !$0 { viewingId = nil } }
        )) {
            FeedLightbox(id: viewingId ?? "", canDelete: false)
        }
        .fullScreenCover(isPresented: Binding(
            get: { storyOwner != nil },
            set: { if !$0 { storyOwner = nil } }
        )) {
            if let storyOwner {
                StoryViewer(ownerId: storyOwner) { self.storyOwner = nil }
                    .environmentObject(model)
            }
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
        VStack(alignment: .leading, spacing: 12) {
            Button(action: onProfile) {
                HStack(spacing: 10) {
                    Avatar(name: name, jpeg: feedOwnerJpeg(model.state, item.ownerId), size: 34)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(name).font(.subheadline.weight(.semibold))
                        Text(formatFeedTime(item.createdAt)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.forward")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            Button(action: onOpen) {
                FeedThumb(item: item)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 8) {
                FeedActions(item: item, onComments: onOpen)
                if let summary = likeSummary(model.state, item) {
                    Text(summary).font(.footnote.weight(.semibold))
                }
                if !item.caption.isEmpty {
                    Text(item.caption).font(.subheadline)
                }
                if !item.comments.isEmpty {
                    Button(action: onOpen) {
                        Text(item.comments.count == 1 ? "1 Comment" : "\(item.comments.count) Comments")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

struct FeedActions: View {
    @EnvironmentObject private var model: AppModel
    let item: FeedItem
    var onComments: () -> Void = {}

    var body: some View {
        let liked = item.likes.contains { $0.fromId == model.state.profile?.directId }
        HStack(spacing: 8) {
            Button { model.likeFeed(item.id) } label: {
                Label(liked ? "Liked" : "Like", systemImage: liked ? "heart.fill" : "heart")
                    .font(.footnote.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .tint(liked ? Color.pink : Ink.accent)
            .controlSize(.small)
            Button(action: onComments) {
                Label(item.comments.isEmpty ? "Comment" : "\(item.comments.count)", systemImage: "text.bubble")
                    .font(.footnote.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .tint(Ink.accent)
            .controlSize(.small)
            Spacer(minLength: 0)
        }
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
            VStack(alignment: .leading, spacing: 4) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(compact ? .footnote.weight(.semibold) : .subheadline.weight(.semibold))
                    Text(text)
                        .font(compact ? .footnote : .subheadline)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                Text(formatFeedTime(createdAt)).font(.caption2).foregroundStyle(.secondary)
                    .padding(.leading, 4)
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
                                            .background(Circle().fill(Ink.background).padding(2))
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
    @State private var picking = false
    @State private var viewingId: String?

    var body: some View {
        let posts = profilePosts(model.state, ownerId: ownerId)
        VStack(alignment: .leading, spacing: 12) {
            if showsHeading {
                Text("Posts").font(.headline)
            }
            if posts.isEmpty && !canAdd {
                Text("Nothing on this profile yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                profileGrid(tiles(from: posts))
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
        .photosPicker(isPresented: $picking, selection: $item, matching: .any(of: [.images, .videos]))
        .navigationDestination(isPresented: Binding(
            get: { viewingId != nil },
            set: { if !$0 { viewingId = nil } }
        )) {
            FeedLightbox(id: viewingId ?? "", canDelete: canAdd)
        }
    }

    private func tiles(from posts: [FeedItem]) -> [ProfileTile] {
        (canAdd ? [.add] : []) + posts.map(ProfileTile.post)
    }

    @ViewBuilder
    private func profileGrid(_ tiles: [ProfileTile]) -> some View {
        VStack(spacing: 10) {
            ForEach(Array(stride(from: 0, to: tiles.count, by: 2)), id: \.self) { start in
                profileRow(row(from: tiles, start: start))
            }
        }
    }

    private func row(from tiles: [ProfileTile], start: Int) -> [ProfileTile] {
        Array(tiles[start..<min(start + 2, tiles.count)])
    }

    @ViewBuilder
    private func profileRow(_ row: [ProfileTile]) -> some View {
        HStack(spacing: 10) {
            ForEach(row) { tile in
                profileTile(tile)
            }
            if row.count == 1 {
                Color.clear.aspectRatio(1, contentMode: .fit).frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder
    private func profileTile(_ tile: ProfileTile) -> some View {
        switch tile {
        case .add:
            Button { picking = true } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(uiColor: .tertiarySystemFill))
                    VStack(spacing: 6) {
                        Image(systemName: "plus")
                            .font(.title.weight(.semibold))
                        Text("Add")
                            .font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(Color.accentColor)
                }
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add post")
        case .post(let post):
            Button { viewingId = post.id } label: {
                FeedThumb(item: post)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
        }
    }
}

private enum ProfileTile: Identifiable {
    case add
    case post(FeedItem)

    var id: String {
        switch self {
        case .add: return "add"
        case .post(let item): return item.id
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
        let postCount = profilePosts(model.state, ownerId: peerId).count
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 8) {
                    Button { if !stories.isEmpty { storyOpen = true } } label: {
                        Avatar(name: name, jpeg: jpeg, size: 108)
                            .overlay {
                                Circle().strokeBorder(stories.isEmpty ? Color.clear : Color.accentColor, lineWidth: 2)
                            }
                    }
                    .buttonStyle(.plain)
                    Text(name).font(.title2.weight(.semibold))
                    if !about.isEmpty {
                        Text(about)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    Text(postCount == 1 ? "1 post" : "\(postCount) posts")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
                ProfilePosts(ownerId: peerId, canAdd: selfProfile, showsHeading: true)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .background(Ink.background)
        .navigationTitle(name)
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
    @Environment(\.dismiss) private var dismiss
    let id: String
    var canDelete: Bool
    @State private var bytes: Data?
    @State private var draft = ""
    @State private var confirmDelete = false
    @FocusState private var commenting: Bool

    var body: some View {
        let item = model.state.feed.first { $0.id == id }
        let name = item.map { feedOwnerName(model.state, $0.ownerId) } ?? "Post"
        VStack(spacing: 0) {
            ZStack {
                Color(uiColor: .secondarySystemFill)
                if let item, let bytes, item.kind != "video", let image = UIImage(data: bytes) {
                    Image(uiImage: image).resizable().scaledToFit()
                } else if let item, let bytes, item.kind == "video" {
                    StoryVideo(data: bytes, name: item.name)
                } else {
                    ProgressView().tint(Ink.accent)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: commenting ? 140 : 260)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal, 16)
            .padding(.top, 8)
            if let item {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Avatar(name: name, jpeg: feedOwnerJpeg(model.state, item.ownerId), size: 36)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(name).font(.subheadline.weight(.semibold))
                            Text(formatFeedTime(item.createdAt)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    FeedActions(item: item) { commenting = true }
                    if let summary = likeSummary(model.state, item) {
                        Text(summary).font(.footnote.weight(.semibold))
                    }
                    if !item.caption.isEmpty {
                        Text(item.caption).font(.subheadline)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                Divider().overlay(Ink.line)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            if item.comments.isEmpty {
                                Text("No comments yet")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .padding(.vertical, 24)
                            } else {
                                ForEach(item.comments) { comment in
                                    CommentRow(fromId: comment.fromId, text: comment.body, createdAt: comment.createdAt)
                                        .id(comment.id)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                    .scrollDismissesKeyboard(.interactively)
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
            if let item {
                commentComposer(item.id)
            }
        }
        .modifier(KeyboardLift())
        .background(Ink.background)
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            if canDelete, item != nil {
                ToolbarItem(placement: .topBarTrailing) {
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
        .animation(.easeInOut(duration: 0.22), value: commenting)
        .onAppear { model.loadFeed(id) { bytes = $0 } }
    }

    private func commentComposer(_ postId: String) -> some View {
        let ready = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return HStack(alignment: .bottom, spacing: 8) {
            TextField("Comment", text: $draft, axis: .vertical)
                .font(.body)
                .lineLimit(1...5)
                .textInputAutocapitalization(.sentences)
                .focused($commenting)
                .submitLabel(.send)
                .onSubmit { send(postId) }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            Button {
                send(postId)
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(ready ? Color.white : Ink.muted)
                    .frame(width: 36, height: 36)
                    .background(ready ? Ink.accent : Ink.surface, in: Circle())
            }
            .buttonStyle(ComposerPressStyle())
            .disabled(!ready)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(Ink.background)
        .overlay(alignment: .top) { Rectangle().fill(Ink.line).frame(height: 0.5) }
    }

    private func send(_ postId: String) {
        let body = draft
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draft = ""
        commenting = false
        model.commentFeed(postId, body)
    }
}

/// Lifts the comment field above the keyboard. Sheets and some navigation stacks skip SwiftUI's keyboard safe area, so this uses the keyboard frame directly.
private struct KeyboardLift: ViewModifier {
    @State private var inset: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .padding(.bottom, inset)
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
                guard
                    let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
                    let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double
                else { return }
                let overlap = max(0, UIScreen.main.bounds.maxY - frame.minY)
                withAnimation(.easeOut(duration: duration)) {
                    inset = overlap
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { note in
                let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.22
                withAnimation(.easeOut(duration: duration)) {
                    inset = 0
                }
            }
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
