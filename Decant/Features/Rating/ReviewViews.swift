import SwiftUI

/// A review / tasting entry card used in feeds and on wine pages.
struct ReviewCard: View {
    var item: ReviewItem
    var showsWine = true
    var onLike: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                NavigationLink(value: Route.user(item.author.id)) {
                    HStack(spacing: 10) {
                        AvatarView(profile: item.author, size: 38)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.author.displayName).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.charcoal)
                            Text("@\(item.author.username) · \(item.entry.createdAt.relativeShort)")
                                .font(.caption).foregroundStyle(Palette.secondaryText)
                        }
                    }
                }
                .buttonStyle(.plain)
                Spacer()
                if let rating = item.entry.rating { StarRatingView(rating: rating, size: 12) }
                SafetyMenu(target: .entry(id: item.id, author: item.author.id), authorName: "@\(item.author.username)")
            }

            if showsWine {
                NavigationLink(value: Route.wine(item.wine)) {
                    HStack(spacing: 14) {
                        BottleArtView(wine: item.wine, height: 92)
                            .frame(width: 44)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.wine.name).font(.system(.headline, design: .serif)).foregroundStyle(Palette.charcoal)
                            Text("\(item.wine.producer) · \(item.wine.vintageLabel)").font(.subheadline).foregroundStyle(Palette.secondaryText)
                            TypeDot(type: item.wine.type)
                        }
                        Spacer()
                    }
                    .padding(12)
                    .background(Palette.cream, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            if let review = item.entry.review {
                NavigationLink(value: Route.entry(item.id)) {
                    Text(review)
                        .font(.system(.callout, design: .serif))
                        .foregroundStyle(Palette.charcoal)
                        .lineLimit(5)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }

            if !item.entry.photoPaths.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(item.entry.photoPaths, id: \.self) { path in
                            StoredImage(path: path, maxPixel: 400) { Rectangle().fill(Palette.hairline) }
                                .scaledToFill()
                                .frame(width: 110, height: 110)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
            }

            HStack(spacing: 18) {
                Button(action: onLike) {
                    Label("\(item.entry.likeCount)", systemImage: item.entry.likedByMe ? "heart.fill" : "heart")
                        .foregroundStyle(item.entry.likedByMe ? Palette.burgundy : Palette.secondaryText)
                }
                .accessibilityLabel(item.entry.likedByMe ? "Unlike, \(item.entry.likeCount) likes" : "Like, \(item.entry.likeCount) likes")
                .sensoryFeedback(.impact(weight: .light), trigger: item.entry.likedByMe)
                NavigationLink(value: Route.entry(item.id)) {
                    Label("\(item.entry.commentCount)", systemImage: "bubble.right")
                        .foregroundStyle(Palette.secondaryText)
                }
                .accessibilityLabel("\(item.entry.commentCount) comments")
                Spacer()
                if let location = item.entry.location {
                    Label(location, systemImage: "mappin").font(.caption).foregroundStyle(Palette.secondaryText).lineLimit(1)
                }
            }
            .font(.subheadline.weight(.medium))
            .buttonStyle(.plain)
        }
        .cardSurface()
    }
}

/// A single review with its comment thread.
struct ReviewThreadView: View {
    var entryID: UUID
    @Environment(AppEnvironment.self) private var env
    @State private var item: Loadable<ReviewItem> = .idle
    @State private var comments: [ReviewComment] = []
    @State private var draft = ""
    @State private var sending = false
    @State private var confirmDelete = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch item {
                case .loaded(let review):
                    ReviewCard(item: review, onLike: { Task { await toggleLike(review) } })
                    if review.author.id == env.currentUser?.id {
                        ownerDetails(review)
                    }
                    Text("Comments").font(Typo.title3)
                    if comments.isEmpty {
                        Text("No comments yet.").font(.callout).foregroundStyle(Palette.secondaryText)
                    }
                    ForEach(comments) { comment in
                        HStack(alignment: .top, spacing: 10) {
                            AvatarView(profile: comment.author, size: 32)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(comment.author.displayName).font(.subheadline.weight(.semibold))
                                    Text(comment.createdAt.relativeShort).font(.caption).foregroundStyle(Palette.secondaryText)
                                }
                                Text(comment.body).font(.callout)
                            }
                            Spacer()
                            SafetyMenu(target: .comment(id: comment.id, author: comment.author.id), authorName: "@\(comment.author.username)")
                        }
                    }
                case .failed(let message):
                    ErrorStateView(message: message) { Task { await load() } }
                default:
                    SkeletonBlock(height: 180)
                }
            }
            .padding(Metrics.gutter)
        }
        .screenBackground()
        .safeAreaInset(edge: .bottom) { composer }
        .navigationTitle("Review")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .onChange(of: env.moderationRevision) {
            Task {
                await load()
                if case .failed = item { dismiss() } // the review itself was reported or its author blocked
            }
        }
        .confirmationDialog("Delete this tasting?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task {
                    try? await env.tastings.deleteEntry(id: entryID)
                    env.diaryRevision += 1
                    dismiss()
                }
            }
        }
    }

    private func ownerDetails(_ review: ReviewItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let notes = review.entry.personalNotes {
                Label(notes, systemImage: "lock.fill").font(.callout)
            }
            HStack(spacing: 14) {
                Label(review.entry.consumedOn.formatted(date: .abbreviated, time: .omitted), systemImage: "calendar")
                Label(review.entry.visibility.label, systemImage: review.entry.visibility.systemImage)
                if let again = review.entry.drinkAgain {
                    Label(again ? "Would drink again" : "Wouldn't again", systemImage: again ? "hand.thumbsup" : "hand.thumbsdown")
                }
            }
            .font(.caption)
            .foregroundStyle(Palette.secondaryText)
            Button("Delete tasting", role: .destructive) { confirmDelete = true }
                .font(.caption.weight(.semibold))
        }
        .cardSurface()
    }

    private var composer: some View {
        HStack(spacing: 10) {
            TextField("Add a comment…", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Palette.creamElevated, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            Button {
                Task { await send() }
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 32))
            }
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || sending)
            .accessibilityLabel("Send comment")
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func load() async {
        do {
            item = .loaded(try await env.tastings.entry(id: entryID))
            comments = try await env.social.comments(entryID: entryID)
        } catch {
            item = .failed(error.localizedDescription)
        }
    }

    private func toggleLike(_ review: ReviewItem) async {
        var updated = review
        updated.entry.likedByMe.toggle()
        updated.entry.likeCount += updated.entry.likedByMe ? 1 : -1
        item = .loaded(updated)
        try? await env.social.setLike(updated.entry.likedByMe, entryID: review.id)
    }

    private func send() async {
        sending = true
        defer { sending = false }
        do {
            let comment = try await env.social.addComment(draft, entryID: entryID)
            comments.append(comment)
            draft = ""
        } catch {
            env.show(error.localizedDescription, symbol: "exclamationmark.triangle.fill")
        }
    }
}
