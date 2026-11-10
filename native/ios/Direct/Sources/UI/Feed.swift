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
    let seconds = max(0, Int64(Date().timeIntervalSince1970 * 1000) - ms) / 1000
    if seconds < 60 { return "just now" }
    if seconds < 3600 { return "\(seconds / 60)m" }
    if seconds < 86_400 { return "\(seconds / 3600)h" }
    return "\(seconds / 86_400)d"
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
                    .background(Ink.surface)
                Divider()
                if posts.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "rectangle.stack")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(Ink.accent)
                            .frame(width: 64, height: 64)
                            .background(Ink.accent.opacity(0.12), in: Circle())
                        Text("No posts yet").font(.headline)
                        Muted("When a contact adds photos or videos to their profile, they show up here.")
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(32)
                } else {
                    VStack(spacing: 10) {
                        ForEach(posts) { item in
                            FeedPostCard(item: item, onOpen: { viewing = item }, onProfile: { profilePeer = item.ownerId })
                        }
                    }
                }
            }
        }
        .background(Ink.background)
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
        .fullScreenCover(item: $viewing) { post in
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
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onProfile) {
                HStack(spacing: 10) {
                    Avatar(name: name, jpeg: feedOwnerJpeg(model.state, item.ownerId), size: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).font(.subheadline.weight(.semibold)).foregroundStyle(Ink.text)
                        Text(formatFeedTime(item.createdAt)).font(.caption).foregroundStyle(Ink.muted)
                    }
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            Button(action: onOpen) {
                FeedThumb(item: item)
                    .aspectRatio(1, contentMode: .fit)
            }
            .buttonStyle(.plain)
            FeedActions(item: item, onComments: onOpen)
                .padding(.horizontal, 10)
            if let summary = likeSummary(model.state, item) {
                Text(summary).font(.subheadline.weight(.semibold)).padding(.horizontal, 14)
            }
            if !item.caption.isEmpty {
                (Text(name).fontWeight(.semibold) + Text("  ") + Text(item.caption))
                    .font(.subheadline)
                    .padding(.horizontal, 14)
                    .padding(.top, 4)
            }
            if let latest = item.comments.last {
                Button(action: onOpen) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.comments.count == 1 ? "View 1 comment" : "View all \(item.comments.count) comments")
                            .font(.footnote)
                            .foregroundStyle(Ink.muted)
                        CommentRow(fromId: latest.fromId, body: latest.body, createdAt: latest.createdAt, compact: true)
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 6)
                }
                .buttonStyle(.plain)
            }
            Spacer().frame(height: 12)
        }
        .background(Ink.surface)
    }
}

struct FeedActions: View {
    @EnvironmentObject private var model: AppModel
    let item: FeedItem
    var onComments: () -> Void = {}

    var body: some View {
        let liked = item.likes.contains { $0.fromId == model.state.profile?.directId }
        HStack(spacing: 16) {
            Button { model.likeFeed(item.id) } label: {
                Image(systemName: liked ? "heart.fill" : "heart")
                    .font(.system(size: 22))
                    .foregroundStyle(liked ? Color(red: 0.88, green: 0.14, blue: 0.37) : Ink.text)
            }
            Button(action: onComments) {
                Image(systemName: "bubble.right")
                    .font(.system(size: 21))
                    .foregroundStyle(Ink.text)
            }
            Spacer()
            if !item.comments.isEmpty {
                Text("\(item.comments.count)").font(.footnote).foregroundStyle(Ink.muted)
            }
        }
        .buttonStyle(.plain)
        .padding(.vertical, 6)
    }
}

struct CommentRow: View {
    @EnvironmentObject private var model: AppModel
    let fromId: String
    let body: String
    let createdAt: Int64
    var compact = false

    var body: some View {
        let name = feedOwnerName(model.state, fromId)
        HStack(alignment: .top, spacing: 10) {
            Avatar(name: name, jpeg: feedOwnerJpeg(model.state, fromId), size: compact ? 24 : 32)
            VStack(alignment: .leading, spacing: 2) {
                (Text(name).fontWeight(.semibold) + Text("  ") + Text(body))
                    .font(compact ? .footnote : .subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                Text(formatFeedTime(createdAt)).font(.caption2).foregroundStyle(Ink.muted)
            }
            Spacer(minLength: 0)
        }
    }
}

struct StoriesTray: View {
    @EnvironmentObject private var model: AppModel
    var onOpen: (String) -> Void
    @State private var photoItem: PhotosPickerItem?
    @State private var videoItem: PhotosPickerItem?

    var body: some View {
        let selfId = model.state.profile?.directId
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 14) {
                if let selfId {
                    ForEach(storyOwners(model.state, selfId: selfId), id: \.self) { ownerId in
                        let stories = liveStories(model.state, ownerId: ownerId)
                        let selfStory = ownerId == selfId
                        let name = selfStory ? "Your story" : model.state.contacts.first { $0.directId == ownerId }?.name ?? ownerId
                        let jpeg = selfStory ? model.state.profile?.avatarJpegBase64 : model.state.contacts.first { $0.directId == ownerId }?.avatarJpegBase64
                        let unseen = stories.contains { !$0.seen }
                        VStack(spacing: 6) {
                            ZStack(alignment: .bottomTrailing) {
                                Button {
                                    if !stories.isEmpty { onOpen(ownerId) }
                                } label: {
                                    Avatar(name: name, jpeg: jpeg, size: 56)
                                        .padding(4)
                                        .overlay(Circle().stroke(stories.isEmpty ? Ink.line : (unseen ? Ink.accent : Ink.muted), lineWidth: 2.5))
                                }
                                .buttonStyle(.plain)
                                if selfStory {
                                    PhotosPicker(selection: $photoItem, matching: .any(of: [.images, .videos])) {
                                        Image(systemName: "plus")
                                            .font(.system(size: 11, weight: .bold))
                                            .foregroundStyle(.white)
                                            .frame(width: 20, height: 20)
                                            .background(Ink.accent, in: Circle())
                                    }
                                }
                            }
                            Text(name)
                                .font(.caption2)
                                .foregroundStyle(Ink.text)
                                .lineLimit(1)
                                .frame(width: 72)
                        }
                    }
                    PhotosPicker(selection: $videoItem, matching: .videos) {
                        VStack(spacing: 6) {
                            Image(systemName: "video.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(Ink.accent)
                                .frame(width: 56, height: 56)
                                .background(Ink.surface, in: Circle())
                                .overlay(Circle().stroke(Ink.line))
                            Text("Video")
                                .font(.caption2)
                                .foregroundStyle(Ink.muted)
                                .frame(width: 72)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .onChange(of: photoItem) { item in
            Task { await publish(item, fallbackKind: "image") }
        }
        .onChange(of: videoItem) { item in
            Task { await publish(item, fallbackKind: "video") }
        }
    }

    private func publish(_ item: PhotosPickerItem?, fallbackKind: String) async {
        guard let item else { return }
        do {
            let prepared = try await loadFeedMedia(item, fallbackKind: fallbackKind)
            model.publishFeed(channel: FeedNotes.story, kind: prepared.kind, mime: prepared.mime, name: prepared.name, bytes: prepared.bytes)
        } catch {
            await MainActor.run { model.toast = (error as? PrepError)?.message ?? "That story was not added." }
        }
        await MainActor.run {
            photoItem = nil
            videoItem = nil
        }
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
                        Image(systemName: "xmark").font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                    }
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
                        Text("Photos and videos").font(.headline)
                    }
                    Spacer()
                    if canAdd {
                        PhotosPicker(selection: $item, matching: .any(of: [.images, .videos])) {
                            Image(systemName: "plus.app").foregroundStyle(Ink.accent)
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
        .fullScreenCover(item: $viewing) { post in
            FeedLightbox(id: post.id, canDelete: canAdd)
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
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 16) {
                    Button { if !stories.isEmpty { storyOpen = true } } label: {
                        Avatar(name: name, jpeg: jpeg, size: 72)
                            .overlay(Circle().stroke(stories.isEmpty ? Color.clear : Ink.accent, lineWidth: 2.5))
                    }
                    .buttonStyle(.plain)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(name).font(.title3.bold())
                        if !about.isEmpty { Text(about).foregroundStyle(Ink.muted) }
                        Text("\(profilePosts(model.state, ownerId: peerId).count) posts").font(.subheadline).foregroundStyle(Ink.muted)
                    }
                }
                ProfilePosts(ownerId: peerId, canAdd: selfProfile)
            }
            .padding()
        }
        .background(Ink.background)
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
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
                Ink.surface
            }
            if item.kind == "video" {
                Image(systemName: "play.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Color.black.opacity(0.45), in: Circle())
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

    var body: some View {
        let item = model.state.feed.first { $0.id == id }
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                Color.black
                if let item, let bytes, item.kind != "video", let image = UIImage(data: bytes) {
                    Image(uiImage: image).resizable().scaledToFit()
                } else if let item, let bytes, item.kind == "video" {
                    StoryVideo(data: bytes, name: item.name)
                } else {
                    ProgressView().tint(.white)
                }
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").foregroundStyle(.white).padding()
                    }
                    Spacer()
                    if canDelete, item != nil {
                        Button {
                            model.deleteFeed(id)
                            dismiss()
                        } label: {
                            Image(systemName: "trash").foregroundStyle(.white).padding()
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 280)
            .layoutPriority(1)
            if let item {
                let name = feedOwnerName(model.state, item.ownerId)
                VStack(alignment: .leading, spacing: 0) {
                    Capsule().fill(Ink.line).frame(width: 36, height: 4).frame(maxWidth: .infinity).padding(.top, 8)
                    HStack(spacing: 10) {
                        Avatar(name: name, jpeg: feedOwnerJpeg(model.state, item.ownerId), size: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(name).font(.subheadline.weight(.semibold))
                            Text(formatFeedTime(item.createdAt)).font(.caption).foregroundStyle(Ink.muted)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    FeedActions(item: item)
                        .padding(.horizontal, 10)
                    if let summary = likeSummary(model.state, item) {
                        Text(summary).font(.subheadline.weight(.semibold)).padding(.horizontal, 14)
                    }
                    if !item.caption.isEmpty {
                        (Text(name).fontWeight(.semibold) + Text("  ") + Text(item.caption))
                            .font(.subheadline)
                            .padding(.horizontal, 14)
                            .padding(.top, 4)
                    }
                    Divider().padding(.top, 10)
                    if item.comments.isEmpty {
                        Text("No comments yet. Say something.")
                            .font(.subheadline)
                            .foregroundStyle(Ink.muted)
                            .padding(14)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 12) {
                                ForEach(item.comments) { comment in
                                    CommentRow(fromId: comment.fromId, body: comment.body, createdAt: comment.createdAt)
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                        }
                        .frame(maxHeight: 220)
                    }
                    Divider()
                    HStack(spacing: 10) {
                        Avatar(name: model.state.profile?.name ?? "You", jpeg: model.state.profile?.avatarJpegBase64, size: 32)
                        TextField("Add a comment…", text: $draft, axis: .vertical)
                            .lineLimit(1...3)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Ink.background, in: Capsule())
                            .overlay(Capsule().stroke(Ink.line))
                        Button("Post") {
                            let body = draft
                            draft = ""
                            model.commentFeed(item.id, body)
                        }
                        .font(.subheadline.weight(.semibold))
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .tint(Ink.accent)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
                .background(Ink.surface)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 20, style: .continuous))
            }
        }
        .background(Ink.background.ignoresSafeArea())
        .onAppear { model.loadFeed(id) { bytes = $0 } }
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
