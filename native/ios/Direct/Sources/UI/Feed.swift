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

func savedFeed(_ state: NodeState) -> [FeedItem] {
    let byId = Dictionary(state.feed.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    return state.savedPosts.compactMap { byId[$0] }.filter { $0.channel == FeedNotes.post }
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

struct FeedView: View {
    @EnvironmentObject private var model: AppModel
    @State private var storyOwner: String?
    @State private var viewingId: String?
    @State private var mediaId: String?
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
                        FeedPostCard(
                            item: item,
                            onOpen: { viewingId = item.id },
                            onMedia: { mediaId = item.id },
                            onProfile: { profilePeer = item.ownerId }
                        )
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
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
        .background {
            Color.clear.fullScreenCover(isPresented: Binding(
                get: { mediaId != nil },
                set: { if !$0 { mediaId = nil } }
            )) {
                if let mediaId {
                    FeedMediaViewer(id: mediaId, canDelete: false) { self.mediaId = nil }
                        .id(mediaId)
                        .environmentObject(model)
                }
            }
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
    var onMedia: () -> Void
    var onProfile: () -> Void

    var body: some View {
        let name = feedOwnerName(model.state, item.ownerId)
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onProfile) {
                HStack(spacing: 10) {
                    Avatar(name: name, jpeg: feedOwnerJpeg(model.state, item.ownerId), size: 32)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(name).font(.subheadline.weight(.semibold))
                        Text(formatFeedTime(item.createdAt)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Button(action: onMedia) {
                FeedThumb(item: item, cornerRadius: 18)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .accessibilityLabel(item.kind == "video" ? "View video" : "View photo")
            VStack(alignment: .leading, spacing: 8) {
                if !item.caption.isEmpty {
                    Text(item.caption)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
                FeedActions(item: item, onComments: onOpen)
                if !item.comments.isEmpty {
                    Button(action: onOpen) {
                        Text(item.comments.count == 1 ? "1 Comment" : "\(item.comments.count) Comments")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 14)
        }
    }
}

struct FeedActions: View {
    @EnvironmentObject private var model: AppModel
    let item: FeedItem
    var onComments: () -> Void = {}
    @State private var pickingEmoji = false
    @State private var forwarding = false

    var body: some View {
        let selfId = model.state.profile?.directId
        let mine = item.likes.first { $0.fromId == selfId }?.emoji
        VStack(alignment: .leading, spacing: 10) {
            if pickingEmoji {
                emojiBar(mine: mine)
            }
            HStack(spacing: 10) {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { pickingEmoji.toggle() }
                } label: {
                    Group {
                        if let mine {
                            Text(mine).font(.body)
                        } else {
                            Image(systemName: "heart")
                                .font(.body.weight(.semibold))
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(Color.primary)
                        }
                    }
                    .frame(width: 36, height: 36)
                    .background(Color(uiColor: .tertiarySystemFill), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("React")
                iconButton(systemImage: "text.bubble", tint: .primary, label: "Comment", action: onComments)
                iconButton(systemImage: "square.and.arrow.up", tint: .primary, label: "Forward") {
                    forwarding = true
                }
                Spacer(minLength: 0)
                iconButton(
                    systemImage: model.state.savedPosts.contains(item.id) ? "bookmark.fill" : "bookmark",
                    tint: model.state.savedPosts.contains(item.id) ? Ink.accent : .primary,
                    label: model.state.savedPosts.contains(item.id) ? "Saved" : "Save"
                ) {
                    model.saveFeed(item.id)
                }
            }
            reactionChips(selfId: selfId)
        }
        .sheet(isPresented: $forwarding) {
            ForwardPicker { target in
                model.forwardFeed(item.id, to: target)
            }
            .environmentObject(model)
        }
    }

    private func emojiBar(mine: String?) -> some View {
        HStack(spacing: 0) {
            ForEach(ChatNotes.emojis, id: \.self) { emoji in
                Button {
                    model.reactFeed(item.id, emoji)
                    withAnimation(.easeOut(duration: 0.15)) { pickingEmoji = false }
                } label: {
                    Text(emoji)
                        .font(.system(size: 22))
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(mine == emoji ? Ink.accent.opacity(0.16) : Color.clear, in: Circle())
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(emoji)
            }
        }
        .padding(.horizontal, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(Ink.line, lineWidth: 0.5))
    }

    @ViewBuilder
    private func reactionChips(selfId: String?) -> some View {
        if !item.likes.isEmpty {
            chipRow(selfId: selfId)
        }
    }

    private func chipRow(selfId: String?) -> some View {
        let groups = Dictionary(grouping: item.likes, by: \.emoji)
        let order = item.likes.map(\.emoji).reduce(into: [String]()) { seen, emoji in
            if !seen.contains(emoji) { seen.append(emoji) }
        }
        return HStack(spacing: 6) {
            ForEach(order, id: \.self) { emoji in
                reactionChip(emoji: emoji, people: groups[emoji] ?? [], selfId: selfId)
            }
            Spacer(minLength: 0)
        }
    }

    private func reactionChip(emoji: String, people: [FeedLike], selfId: String?) -> some View {
        let mine = people.contains { $0.fromId == selfId }
        return Button {
            model.reactFeed(item.id, emoji)
        } label: {
            HStack(spacing: 4) {
                Text(emoji).font(.system(size: 14))
                if people.count > 1 {
                    Text("\(people.count)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(mine ? Ink.accent.opacity(0.16) : Color(uiColor: .tertiarySystemFill), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(emoji), \(people.count)")
    }

    private func iconButton(
        systemImage: String,
        tint: Color,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .background(Color(uiColor: .tertiarySystemFill), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
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
    @State private var mediaId: String?

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
        .fullScreenCover(isPresented: Binding(
            get: { mediaId != nil },
            set: { if !$0 { mediaId = nil } }
        )) {
            if let mediaId {
                FeedMediaViewer(id: mediaId, canDelete: canAdd) { self.mediaId = nil }
                    .id(mediaId)
                    .environmentObject(model)
            }
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
            Button { mediaId = post.id } label: {
                FeedThumb(item: post)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .accessibilityLabel(post.kind == "video" ? "View video" : "View photo")
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

struct SavedPosts: View {
    @EnvironmentObject private var model: AppModel
    @State private var mediaId: String?

    var body: some View {
        let posts = savedFeed(model.state)
        VStack(alignment: .leading, spacing: 12) {
            Text("Saved").font(.headline)
            if posts.isEmpty {
                Text("Save a post and it stays here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 10) {
                    ForEach(Array(stride(from: 0, to: posts.count, by: 2)), id: \.self) { start in
                        savedRow(Array(posts[start..<min(start + 2, posts.count)]))
                    }
                }
            }
        }
        .fullScreenCover(isPresented: Binding(
            get: { mediaId != nil },
            set: { if !$0 { mediaId = nil } }
        )) {
            if let mediaId {
                FeedMediaViewer(
                    id: mediaId,
                    canDelete: model.state.feed.first { $0.id == mediaId }?.ownerId == model.state.profile?.directId
                ) { self.mediaId = nil }
                    .id(mediaId)
                    .environmentObject(model)
            }
        }
    }

    @ViewBuilder
    private func savedRow(_ row: [FeedItem]) -> some View {
        HStack(spacing: 10) {
            ForEach(row, id: \.id) { post in
                Button { mediaId = post.id } label: {
                    FeedThumb(item: post)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .accessibilityLabel(post.kind == "video" ? "View video" : "View photo")
            }
            if row.count == 1 {
                Color.clear.aspectRatio(1, contentMode: .fit).frame(maxWidth: .infinity)
            }
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
                    if !selfProfile {
                        HStack(spacing: 12) {
                            profileAction("Message", "bubble.left.fill") {
                                dismiss()
                                model.openChat(peerId)
                            }
                            if contact?.accepted == true, contact?.blocked != true {
                                profileAction("Call", "phone.fill") {
                                    dismiss()
                                    model.placeCall(peerId, video: false)
                                }
                                profileAction("Video", "video.fill") {
                                    dismiss()
                                    model.placeCall(peerId, video: true)
                                }
                            }
                        }
                        .padding(.top, 10)
                    }
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

    private func profileAction(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Ink.accent)
                    .frame(width: 52, height: 52)
                    .background(Ink.accent.opacity(0.14), in: Circle())
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Ink.text)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

struct FeedThumb: View {
    @EnvironmentObject private var model: AppModel
    let item: FeedItem
    var cornerRadius: CGFloat = 16
    @State private var bytes: Data?

    var body: some View {
        Color(uiColor: .tertiarySystemFill)
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay {
                GeometryReader { geo in
                    if let bytes, let image = UIImage(data: bytes) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geo.size.width, height: geo.size.height)
                            .clipped()
                    }
                }
            }
            .overlay {
                if item.kind == "video" {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 36))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.white)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .onAppear { model.loadFeed(item.id) { bytes = $0 } }
            .onChange(of: item.mediaFile) { _ in model.loadFeed(item.id) { bytes = $0 } }
    }
}

struct FeedLightbox: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let id: String
    var canDelete: Bool
    var allowsFullView: Bool = true
    var showsClose: Bool = false
    @State private var bytes: Data?
    @State private var draft = ""
    @State private var confirmDelete = false
    @State private var mediaOpen = false
    @FocusState private var commenting: Bool

    var body: some View {
        let item = model.state.feed.first { $0.id == id }
        let name = item.map { feedOwnerName(model.state, $0.ownerId) } ?? "Post"
        VStack(spacing: 0) {
            ZStack {
                Color(uiColor: .secondarySystemFill)
                if let item, let bytes, item.kind != "video", let image = UIImage(data: bytes) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .contentShape(Rectangle())
                        .onTapGesture { if allowsFullView { mediaOpen = true } }
                        .accessibilityLabel(allowsFullView ? "View full size" : item.name)
                        .accessibilityAddTraits(allowsFullView ? .isButton : .isImage)
                } else if let item, let bytes, item.kind == "video" {
                    StoryVideo(data: bytes, name: item.name)
                } else {
                    ProgressView().tint(Ink.accent)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: commenting ? 140 : 260)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                if allowsFullView, bytes != nil {
                    Button { mediaOpen = true } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(.black.opacity(0.45), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(8)
                    .accessibilityLabel("View full size")
                }
            }
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
                    if !item.caption.isEmpty {
                        Text(item.caption).font(.subheadline)
                    }
                    FeedActions(item: item) { commenting = true }
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
            if showsClose {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            if canDelete, item != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Delete", role: .destructive) { confirmDelete = true }
                }
            }
        }
        .fullScreenCover(isPresented: $mediaOpen) {
            FeedMediaViewer(id: id, canDelete: canDelete, onClose: { mediaOpen = false }, onComments: { mediaOpen = false })
                .id(id)
                .environmentObject(model)
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
        .onAppear {
            if model.state.feed.first(where: { $0.id == id }) == nil { dismiss() }
            model.loadFeed(id) { bytes = $0 }
        }
        .onChange(of: model.state.feed.contains(where: { $0.id == id })) { exists in
            if !exists { dismiss() }
        }
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

/// Full-screen photo or video for a post. Pinch, double-tap, and the buttons zoom between 1x and 5x.
struct FeedMediaViewer: View {
    @EnvironmentObject private var model: AppModel
    let id: String
    var canDelete: Bool
    var onClose: () -> Void
    var onComments: (() -> Void)? = nil
    @State private var image: UIImage?
    @State private var player: AVPlayer?
    @State private var playing = true
    @State private var missing = false
    @State private var comments = false
    @State private var confirmDelete = false
    @State private var scale: CGFloat = 1
    @State private var command = ZoomCommand()

    var body: some View {
        let item = model.state.feed.first { $0.id == id }
        ZStack {
            Color.black.ignoresSafeArea()
            ZoomingMedia(image: image, player: player, command: command, scale: $scale)
                .ignoresSafeArea()
            if image == nil, player == nil {
                if missing {
                    Text(item?.kind == "video" ? "This video could not be opened." : "This photo could not be opened.")
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                } else {
                    ProgressView().tint(.white)
                }
            }
        }
        .overlay(alignment: .topLeading) {
            ViewerIconButton(systemName: "xmark", label: "Close", action: onClose)
                .padding(.leading, 8)
                .padding(.top, 4)
        }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 8) {
                ViewerIconButton(systemName: "text.bubble", label: "Comments") {
                    if let onComments {
                        onComments()
                    } else {
                        comments = true
                    }
                }
                if canDelete, item != nil {
                    ViewerIconButton(systemName: "trash", label: "Delete") { confirmDelete = true }
                }
            }
            .padding(.trailing, 8)
            .padding(.top, 4)
        }
        .overlay(alignment: .bottom) { bottomBar(item) }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $comments) {
            NavigationStack {
                FeedLightbox(id: id, canDelete: canDelete, allowsFullView: false, showsClose: true)
                    .environmentObject(model)
            }
        }
        .confirmationDialog("Delete this post?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Post", role: .destructive) {
                model.deleteFeed(id)
                onClose()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It will be removed from your profile and from people who already received it.")
        }
        .onAppear { load() }
        .onChange(of: item?.mediaFile) { _ in load() }
        .onChange(of: item == nil) { gone in
            if gone { onClose() }
        }
        .onChange(of: comments) { shown in
            if shown {
                player?.pause()
            } else if playing {
                player?.play()
            }
        }
        .onDisappear { player?.pause() }
    }

    private func bottomBar(_ item: FeedItem?) -> some View {
        let percent = Int((scale * 100).rounded())
        return VStack(alignment: .leading, spacing: 8) {
            if let caption = item?.caption, !caption.isEmpty {
                Text(caption)
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.85), radius: 6)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                Color.clear.frame(width: 36, height: 36)
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                ViewerIconButton(systemName: "minus.magnifyingglass", label: "Zoom out", disabled: scale <= 1.01) {
                    command = ZoomCommand(generation: command.generation + 1, factor: 1 / 1.4)
                }
                Text("\(percent)%")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(minWidth: 52)
                    .accessibilityLabel("\(percent) percent")
                ViewerIconButton(systemName: "plus.magnifyingglass", label: "Zoom in", disabled: scale >= 4.99) {
                    command = ZoomCommand(generation: command.generation + 1, factor: 1.4)
                }
                if item?.kind == "video" {
                    ViewerIconButton(systemName: playing ? "pause.fill" : "play.fill", label: playing ? "Pause" : "Play") {
                        playing.toggle()
                        if playing { player?.play() } else { player?.pause() }
                    }
                }
            }
            .padding(.horizontal, 6)
            .background(.black.opacity(0.45), in: Capsule())
                Spacer(minLength: 0)
                if let item {
                    ViewerIconButton(
                        systemName: model.state.savedPosts.contains(item.id) ? "bookmark.fill" : "bookmark",
                        label: model.state.savedPosts.contains(item.id) ? "Saved" : "Save"
                    ) {
                        model.saveFeed(item.id)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    private func load() {
        guard let item = model.state.feed.first(where: { $0.id == id }) else { missing = true; return }
        model.loadFeed(item.id) { data in
            guard let data else { missing = true; return }
            if item.kind == "video" {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("feed-view-\(item.id).mp4")
                do {
                    try data.write(to: url, options: .atomic)
                    let next = AVPlayer(url: url)
                    player = next
                    image = nil
                    playing = true
                    missing = false
                    next.play()
                } catch {
                    missing = true
                }
            } else if let photo = UIImage(data: data) {
                image = photo
                player = nil
                missing = false
            } else {
                missing = true
            }
        }
    }
}

private struct ZoomCommand: Equatable {
    var generation: Int = 0
    var factor: CGFloat = 1
}

private struct ViewerIconButton: View {
    let systemName: String
    let label: String
    var disabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.45), in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
        .accessibilityLabel(label)
    }
}

private struct ZoomingMedia: UIViewRepresentable {
    let image: UIImage?
    let player: AVPlayer?
    let command: ZoomCommand
    @Binding var scale: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ZoomHost {
        let host = ZoomHost()
        context.coordinator.bind(host, scale: $scale)
        return host
    }

    func updateUIView(_ host: ZoomHost, context: Context) {
        context.coordinator.bind(host, scale: $scale)
        context.coordinator.sync(host, image: image, player: player, command: command)
    }

    final class Coordinator {
        var image: UIImage?
        var player: AVPlayer?
        var applied = 0

        func bind(_ host: ZoomHost, scale: Binding<CGFloat>) {
            host.onScale = { value in
                guard abs(scale.wrappedValue - value) > 0.01 else { return }
                DispatchQueue.main.async { scale.wrappedValue = value }
            }
        }

        func sync(_ host: ZoomHost, image: UIImage?, player: AVPlayer?, command: ZoomCommand) {
            if player !== self.player || image !== self.image {
                self.player = player
                self.image = image
                if let player {
                    host.setPlayer(player)
                } else {
                    host.setImage(image)
                }
            }
            if command.generation != applied {
                applied = command.generation
                if command.generation > 0 {
                    host.apply(factor: command.factor)
                }
            }
        }
    }
}

private final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    var player: AVPlayer? {
        get { playerLayer.player }
        set {
            playerLayer.player = newValue
            playerLayer.videoGravity = .resizeAspect
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        playerLayer.videoGravity = .resizeAspect
    }

    required init?(coder: NSCoder) { return nil }
}

private final class ZoomHost: UIScrollView, UIScrollViewDelegate {
    let canvas = UIView()
    let imageView = UIImageView()
    let playerView = PlayerLayerView()
    var onScale: ((CGFloat) -> Void)?
    private var fittedBounds: CGSize = .zero
    private var pinchActive = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 5
        bouncesZoom = true
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        backgroundColor = .clear
        contentInsetAdjustmentBehavior = .never
        addSubview(canvas)
        canvas.addSubview(imageView)
        canvas.addSubview(playerView)
        imageView.contentMode = .scaleAspectFit
        imageView.isHidden = true
        playerView.isHidden = true
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(onDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }

    required init?(coder: NSCoder) { return nil }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { canvas }

    func setImage(_ image: UIImage?) {
        playerView.player = nil
        playerView.isHidden = true
        imageView.image = image
        imageView.isHidden = image == nil
        fittedBounds = .zero
        if zoomScale > 1.001 { setZoomScale(1, animated: false) }
        setNeedsLayout()
    }

    func setPlayer(_ player: AVPlayer?) {
        imageView.image = nil
        imageView.isHidden = true
        playerView.isHidden = player == nil
        playerView.player = player
        fittedBounds = .zero
        if zoomScale > 1.001 { setZoomScale(1, animated: false) }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if !pinchActive, zoomScale <= 1.001 {
            layoutCanvasToFit()
        }
        centerContent()
        updateBounce()
    }

    private func layoutCanvasToFit() {
        let boundsSize = bounds.size
        guard boundsSize.width > 1, boundsSize.height > 1 else { return }
        let size = fittedSize(boundsSize)
        if abs(fittedBounds.width - boundsSize.width) < 0.5,
           abs(fittedBounds.height - boundsSize.height) < 0.5,
           abs(canvas.bounds.width - size.width) < 0.5,
           abs(canvas.bounds.height - size.height) < 0.5 {
            return
        }
        fittedBounds = boundsSize
        canvas.transform = .identity
        canvas.frame = CGRect(origin: .zero, size: size)
        imageView.frame = canvas.bounds
        playerView.frame = canvas.bounds
        contentSize = size
    }

    private func fittedSize(_ boundsSize: CGSize) -> CGSize {
        guard let image = imageView.image, image.size.width > 0, image.size.height > 0 else { return boundsSize }
        let fit = min(boundsSize.width / image.size.width, boundsSize.height / image.size.height)
        return CGSize(width: max(1, floor(image.size.width * fit)), height: max(1, floor(image.size.height * fit)))
    }

    private func centerContent() {
        let extraW = max(bounds.width - contentSize.width, 0)
        let extraH = max(bounds.height - contentSize.height, 0)
        let inset = UIEdgeInsets(top: extraH / 2, left: extraW / 2, bottom: extraH / 2, right: extraW / 2)
        if contentInset != inset { contentInset = inset }
    }

    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) { pinchActive = true }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerContent()
        updateBounce()
        onScale?(zoomScale)
    }

    private func updateBounce() {
        let enabled = zoomScale > 1.01
        if bounces != enabled { bounces = enabled }
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        pinchActive = false
        if scale <= 1.001 {
            fittedBounds = .zero
            setNeedsLayout()
        }
    }

    func apply(factor: CGFloat) {
        let next = min(maximumZoomScale, max(minimumZoomScale, zoomScale * factor))
        setZoomScale(next, animated: true)
    }

    @objc private func onDoubleTap(_ gesture: UITapGestureRecognizer) {
        if zoomScale > 1.01 {
            setZoomScale(minimumZoomScale, animated: true)
            return
        }
        let point = gesture.location(in: canvas)
        let target = min(maximumZoomScale, 2.5)
        let width = bounds.width / target
        let height = bounds.height / target
        zoom(to: CGRect(x: point.x - width / 2, y: point.y - height / 2, width: width, height: height), animated: true)
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
