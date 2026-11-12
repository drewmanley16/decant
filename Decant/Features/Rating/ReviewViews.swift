import SwiftUI

/// A review / tasting entry card used in feeds and on wine pages.
struct ReviewCard: View {
    var item: ReviewItem
    var showsWine = true
    /// Feed cards show the newest comments; the thread view lists them all instead.
    var showsCommentPreview = true
    var onLike: () -> Void
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dynamicTypeSize) private var typeSize
    /// Reactions change here immediately, before the server confirms.
    @State private var socialOverride: EntrySocial?
    @State private var showsBurst = false
    @State private var showsReactors = false

    private var social: EntrySocial? { socialOverride ?? item.entry.social }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if typeSize.isAccessibilitySize {
                // Stars get their own line so the name isn't squeezed into a
                // narrow column and broken mid-word.
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 10) {
                        authorLink
                        Spacer(minLength: 0)
                        safetyMenu
                    }
                    if let rating = item.entry.rating { StarRatingView(rating: rating, size: 12) }
                }
            } else {
                HStack(spacing: 10) {
                    authorLink
                    Spacer()
                    if let rating = item.entry.rating { StarRatingView(rating: rating, size: 12) }
                    safetyMenu
                }
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

            actionRow

            if let social, social.totalReactions > 0 {
                reactionSummary(social)
            }

            if showsCommentPreview, let preview = social?.preview, !preview.isEmpty {
                commentPreview(preview)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { doubleTapLike() }
        .overlay { if showsBurst { HeartBurst().allowsHitTesting(false) } }
        .sheet(isPresented: $showsReactors) {
            ReactorsSheet(entryID: item.id)
                .presentationDetents([.medium, .large])
        }
        .onChange(of: item.entry.social) { socialOverride = nil }
        .cardSurface()
    }


    // MARK: Likes, reactions, shares

    private var actionRow: some View {
        HStack(spacing: 16) {
            HStack(spacing: 6) {
                Button(action: onLike) {
                    Image(systemName: item.entry.likedByMe ? "heart.fill" : "heart")
                        .foregroundStyle(item.entry.likedByMe ? Palette.burgundy : Palette.secondaryText)
                        .symbolEffect(.bounce, value: item.entry.likedByMe)
                }
                .accessibilityLabel(item.entry.likedByMe ? "Unlike" : "Like")
                .sensoryFeedback(.impact(weight: .light), trigger: item.entry.likedByMe)
                Button { showsReactors = true } label: {
                    Text("\(item.entry.likeCount)").foregroundStyle(Palette.secondaryText)
                }
                .disabled(item.entry.likeCount == 0 && (social?.totalReactions ?? 0) == 0)
                .accessibilityLabel("\(item.entry.likeCount) likes. Show who liked")
            }
            NavigationLink(value: Route.entry(item.id)) {
                Label("\(item.entry.commentCount)", systemImage: "bubble.right")
                    .foregroundStyle(Palette.secondaryText)
            }
            .accessibilityLabel("\(item.entry.commentCount) comments")
            Menu {
                ForEach(ReactionKind.allCases) { kind in
                    Button {
                        toggleReaction(kind)
                    } label: {
                        Label("\(kind.emoji) \(kind.label)", systemImage: social?.mine.contains(kind) == true ? "checkmark" : "")
                    }
                }
            } label: {
                Image(systemName: "face.smiling").foregroundStyle(Palette.secondaryText)
            }
            .accessibilityLabel("React")
            ShareLink(item: DeepLink.entry(item.id).url,
                      message: Text("\(item.author.displayName) on \(item.wine.displayName)")) {
                Label(social.map { $0.shareCount > 0 ? "\($0.shareCount)" : "" } ?? "", systemImage: "square.and.arrow.up")
                    .foregroundStyle(Palette.secondaryText)
            }
            .simultaneousGesture(TapGesture().onEnded { Task { await env.social.recordShare(entryID: item.id) } })
            .accessibilityLabel("Share")
            Spacer()
            if let location = item.entry.location {
                Label(location, systemImage: "mappin").font(.caption).foregroundStyle(Palette.secondaryText).lineLimit(1)
            }
        }
        .font(.subheadline.weight(.medium))
        .buttonStyle(.plain)
    }

    private func reactionSummary(_ social: EntrySocial) -> some View {
        HStack(spacing: 6) {
            ForEach(ReactionKind.allCases) { kind in
                if let count = social.reactions[kind], count > 0 {
                    let mine = social.mine.contains(kind)
                    Button { toggleReaction(kind) } label: {
                        Text("\(kind.emoji) \(count)")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .foregroundStyle(mine ? Palette.burgundy : Palette.charcoal)
                            .background(mine ? Palette.burgundy.opacity(0.12) : Palette.cream, in: Capsule())
                            .overlay(Capsule().strokeBorder(mine ? Palette.burgundy.opacity(0.4) : Palette.hairline, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(kind.label), \(count)\(mine ? ", including you" : "")")
                }
            }
        }
        .transition(.scale(scale: 0.8).combined(with: .opacity))
    }

    private func commentPreview(_ preview: [ReviewComment]) -> some View {
        NavigationLink(value: Route.entry(item.id)) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(preview) { comment in
                    (Text(comment.author.displayName).fontWeight(.semibold) + Text(" ") + Text(comment.body))
                        .font(.footnote)
                        .foregroundStyle(Palette.charcoal)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if item.entry.commentCount > preview.count {
                    Text("View all \(item.entry.commentCount) comments")
                        .font(.footnote).foregroundStyle(Palette.secondaryText)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func toggleReaction(_ kind: ReactionKind) {
        var updated = social ?? EntrySocial()
        let on = !updated.mine.contains(kind)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            updated.toggle(kind)
            socialOverride = updated
        }
        Telemetry.track("reaction", ["kind": kind.rawValue, "on": on ? "yes" : "no"])
        Task {
            do {
                try await env.social.setReaction(kind, on: on, entryID: item.id)
            } catch {
                withAnimation { socialOverride = nil }
            }
        }
    }

    /// Double-tap likes (never unlikes), with a heart burst.
    private func doubleTapLike() {
        if !item.entry.likedByMe { onLike() }
        showsBurst = true
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            showsBurst = false
        }
    }

    private var authorLink: some View {
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
    }

    private var safetyMenu: some View {
        SafetyMenu(target: .entry(id: item.id, author: item.author.id), authorName: "@\(item.author.username)")
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
    @State private var editingItem: ReviewItem?
    @State private var replyingTo: ReviewComment?
    @State private var pendingDelete: ReviewComment?
    /// People who can be @mentioned: who you follow, plus everyone in this thread.
    @State private var mentionable: [Profile] = []
    @FocusState private var composerFocused: Bool
    @Environment(\.dismiss) private var dismiss

    private struct Thread { var parent: ReviewComment; var replies: [ReviewComment] }

    /// Top-level comments in order, each followed by its replies. A reply whose parent is gone shows on its own.
    private var threads: [Thread] {
        let ids = Set(comments.map(\.id))
        let tops = comments.filter { $0.parentID == nil || !ids.contains($0.parentID!) }
        return tops.map { top in Thread(parent: top, replies: comments.filter { $0.parentID == top.id }) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch item {
                case .loaded(let review):
                    ReviewCard(item: review, showsCommentPreview: false, onLike: { Task { await toggleLike(review) } })
                    if review.author.id == env.currentUser?.id {
                        ownerDetails(review)
                    }
                    Text("Comments").font(Typo.title3)
                    if comments.isEmpty {
                        Text("No comments yet. Start the conversation.").font(.callout).foregroundStyle(Palette.secondaryText)
                    }
                    ForEach(threads, id: \.parent.id) { thread in
                        CommentItemView(comment: thread.parent, canDelete: canDelete(thread.parent, in: review),
                                   onLike: { toggleCommentLike(thread.parent) },
                                   onReply: { startReply(to: thread.parent) },
                                   onDelete: { pendingDelete = thread.parent })
                        ForEach(thread.replies) { reply in
                            CommentItemView(comment: reply, canDelete: canDelete(reply, in: review),
                                       onLike: { toggleCommentLike(reply) },
                                       onReply: { startReply(to: thread.parent, mentioning: reply.author) },
                                       onDelete: { pendingDelete = reply })
                                .padding(.leading, 42)
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
        .onChange(of: env.diaryRevision) { Task { await load() } }
        .sheet(item: $editingItem) { review in
            RateWineView(wine: review.wine, editing: review.entry)
        }
        .toolbar {
            if case .loaded(let review) = item {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: DeepLink.entry(review.id).url,
                              message: Text("\(review.author.displayName) on \(review.wine.displayName)")) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share tasting")
                }
                if review.author.id == env.currentUser?.id {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Edit") { editingItem = review }
                    }
                }
            }
        }
        .onChange(of: env.moderationRevision) {
            Task {
                await load()
                if case .failed = item { dismiss() } // the review itself was reported or its author blocked
            }
        }
        .confirmationDialog("Delete this comment?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible, presenting: pendingDelete) { comment in
            Button("Delete", role: .destructive) { Task { await deleteComment(comment) } }
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
            HStack(spacing: 16) {
                Button { editingItem = review } label: { Label("Edit tasting", systemImage: "pencil") }
                    .foregroundStyle(Palette.burgundy)
                Button("Delete tasting", role: .destructive) { confirmDelete = true }
            }
            .font(.caption.weight(.semibold))
        }
        .cardSurface()
    }

    private var composer: some View {
        VStack(spacing: 0) {
            if !mentionSuggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(mentionSuggestions) { person in
                            Button { insertMention(person) } label: {
                                HStack(spacing: 6) {
                                    AvatarView(profile: person, size: 24)
                                    Text("@\(person.username)").font(.subheadline.weight(.medium))
                                }
                                .padding(.leading, 4).padding(.trailing, 12).padding(.vertical, 4)
                                .background(Palette.creamElevated, in: Capsule())
                                .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.vertical, 8)
                }
            }
            if let replyingTo {
                HStack {
                    Text("Replying to \(replyingTo.author.displayName)").font(.caption).foregroundStyle(Palette.secondaryText)
                    Spacer()
                    Button { self.replyingTo = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .foregroundStyle(Palette.secondaryText)
                        .accessibilityLabel("Cancel reply")
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.top, 8)
            }
            HStack(spacing: 10) {
                TextField(replyingTo == nil ? "Add a comment… (@ to mention)" : "Write a reply…", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($composerFocused)
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
        }
        .background(.bar)
        .animation(.smooth(duration: 0.2), value: mentionSuggestions.map(\.id))
        .animation(.smooth(duration: 0.2), value: replyingTo?.id)
    }

    // MARK: Mentions

    /// The word being typed, if it starts with @.
    private var mentionQuery: String? {
        guard let last = draft.split(separator: " ", omittingEmptySubsequences: false).last,
              last.hasPrefix("@") else { return nil }
        return String(last.dropFirst()).lowercased()
    }

    private var mentionSuggestions: [Profile] {
        guard let query = mentionQuery else { return [] }
        let me = env.currentUser?.id
        return mentionable.filter { p in
            p.id != me && (query.isEmpty || p.username.lowercased().hasPrefix(query) || p.displayName.lowercased().contains(query))
        }
        .prefix(8).map { $0 }
    }

    private func insertMention(_ person: Profile) {
        var words = draft.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        if !words.isEmpty { words.removeLast() }
        words.append("@\(person.username) ")
        draft = words.joined(separator: " ")
    }

    /// Usernames written as @name that match someone we know.
    private func mentionedIDs(in text: String) -> [UUID] {
        let names = Set(text.split(whereSeparator: { $0.isWhitespace }).compactMap { word -> String? in
            guard word.hasPrefix("@") else { return nil }
            return word.dropFirst().trimmingCharacters(in: .punctuationCharacters.subtracting(CharacterSet(charactersIn: "._"))).lowercased()
        })
        return mentionable.filter { names.contains($0.username.lowercased()) }.map(\.id)
    }

    private func startReply(to parent: ReviewComment, mentioning person: Profile? = nil) {
        replyingTo = parent
        if let person, person.id != env.currentUser?.id, !draft.contains("@\(person.username)") {
            draft = "@\(person.username) " + draft
        }
        composerFocused = true
    }

    private func canDelete(_ comment: ReviewComment, in review: ReviewItem) -> Bool {
        guard let me = env.currentUser?.id else { return false }
        return comment.author.id == me || review.author.id == me
    }

    private func load() async {
        do {
            let review = try await env.tastings.entry(id: entryID)
            item = .loaded(review)
            comments = try await env.social.comments(entryID: entryID)
            var people = comments.map(\.author) + [review.author]
            if mentionable.isEmpty, let me = env.currentUser {
                people += (try? await env.social.following(of: me.id)) ?? []
            }
            var seen = Set(mentionable.map(\.id))
            for person in people where seen.insert(person.id).inserted { mentionable.append(person) }
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
            let comment = try await env.social.addComment(draft, entryID: entryID, replyTo: replyingTo?.id,
                                                          mentions: mentionedIDs(in: draft))
            Telemetry.track("comment_added", ["reply": replyingTo != nil ? "yes" : "no",
                                              "mentions": String(comment.mentionedUserIDs.count)])
            withAnimation(.smooth) { comments.append(comment) }
            draft = ""
            replyingTo = nil
            bumpCommentCount(by: 1)
        } catch {
            env.show(error.localizedDescription, symbol: "exclamationmark.triangle.fill")
        }
    }

    private func toggleCommentLike(_ comment: ReviewComment) {
        guard let i = comments.firstIndex(where: { $0.id == comment.id }) else { return }
        comments[i].likedByMe.toggle()
        comments[i].likeCount += comments[i].likedByMe ? 1 : -1
        let liked = comments[i].likedByMe
        Task {
            do { try await env.social.setCommentLike(liked, commentID: comment.id) } catch { await load() }
        }
    }

    private func deleteComment(_ comment: ReviewComment) async {
        do {
            try await env.social.deleteComment(id: comment.id)
            let removed = comments.filter { $0.id == comment.id || $0.parentID == comment.id }.count
            withAnimation(.smooth) { comments.removeAll { $0.id == comment.id || $0.parentID == comment.id } }
            bumpCommentCount(by: -removed)
        } catch {
            env.show(error.localizedDescription, symbol: "exclamationmark.triangle.fill")
        }
    }

    private func bumpCommentCount(by delta: Int) {
        guard case .loaded(var review) = item else { return }
        review.entry.commentCount = max(0, review.entry.commentCount + delta)
        item = .loaded(review)
    }
}

/// One comment: author, text with @mentions highlighted, and like / reply / delete.
private struct CommentItemView: View {
    var comment: ReviewComment
    var canDelete: Bool
    var onLike: () -> Void
    var onReply: () -> Void
    var onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            NavigationLink(value: Route.user(comment.author.id)) {
                AvatarView(profile: comment.author, size: 32)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(comment.author.displayName).font(.subheadline.weight(.semibold))
                    Text(comment.createdAt.relativeShort).font(.caption).foregroundStyle(Palette.secondaryText)
                }
                Text(Self.highlighted(comment.body)).font(.callout)
                HStack(spacing: 16) {
                    Button("Reply", action: onReply)
                    if canDelete { Button("Delete", role: .destructive, action: onDelete) }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(Palette.secondaryText)
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
            VStack(spacing: 2) {
                Button(action: onLike) {
                    Image(systemName: comment.likedByMe ? "heart.fill" : "heart")
                        .font(.footnote)
                        .foregroundStyle(comment.likedByMe ? Palette.burgundy : Palette.secondaryText)
                        .symbolEffect(.bounce, value: comment.likedByMe)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(comment.likedByMe ? "Unlike comment" : "Like comment")
                if comment.likeCount > 0 {
                    Text("\(comment.likeCount)").font(.caption2).foregroundStyle(Palette.secondaryText)
                }
            }
            SafetyMenu(target: .comment(id: comment.id, author: comment.author.id), authorName: "@\(comment.author.username)")
        }
        .contextMenu {
            Button { onReply() } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
            Button { UIPasteboard.general.string = comment.body } label: { Label("Copy", systemImage: "doc.on.doc") }
            if canDelete { Button(role: .destructive) { onDelete() } label: { Label("Delete", systemImage: "trash") } }
        }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    /// @mentions in burgundy.
    static func highlighted(_ text: String) -> AttributedString {
        var result = AttributedString()
        let words = text.split(separator: " ", omittingEmptySubsequences: false)
        for (i, word) in words.enumerated() {
            var piece = AttributedString(String(word))
            if word.hasPrefix("@"), word.count > 1 {
                piece.foregroundColor = Palette.burgundy
                piece.font = .callout.weight(.semibold)
            }
            result += piece
            if i < words.count - 1 { result += AttributedString(" ") }
        }
        return result
    }
}

/// Big heart that pops over a card on double-tap.
private struct HeartBurst: View {
    @State private var shown = false

    var body: some View {
        Image(systemName: "heart.fill")
            .font(.system(size: 84))
            .foregroundStyle(Palette.burgundy.gradient)
            .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
            .scaleEffect(shown ? 1 : 0.3)
            .opacity(shown ? 0.95 : 0)
            .onAppear { withAnimation(.spring(response: 0.3, dampingFraction: 0.55)) { shown = true } }
            .sensoryFeedback(.impact(weight: .medium), trigger: shown)
            .accessibilityHidden(true)
    }
}

/// Who liked and reacted to a review.
struct ReactorsSheet: View {
    var entryID: UUID
    @Environment(AppEnvironment.self) private var env
    @State private var people: Loadable<[Reactor]> = .idle

    var body: some View {
        NavigationStack {
            Group {
                switch people {
                case .loaded(let list) where list.isEmpty:
                    ContentUnavailableView("No likes yet", systemImage: "heart")
                case .loaded(let list):
                    List(list) { person in
                        NavigationLink(value: Route.user(person.profile.id)) {
                            HStack(spacing: 12) {
                                AvatarView(profile: person.profile, size: 40)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(person.profile.displayName).font(.subheadline.weight(.semibold))
                                    Text("@\(person.profile.username)").font(.caption).foregroundStyle(Palette.secondaryText)
                                }
                                Spacer()
                                Text((person.liked ? "❤️" : "") + person.reactions.map(\.emoji).joined())
                                    .accessibilityLabel(([person.liked ? "Liked" : nil] + person.reactions.map(\.label)).compactMap { $0 }.joined(separator: ", "))
                            }
                        }
                    }
                    .listStyle(.plain)
                case .failed(let message):
                    ErrorStateView(message: message) { Task { await load() } }
                default:
                    ProgressView()
                }
            }
            .navigationTitle("Likes & reactions")
            .navigationBarTitleDisplayMode(.inline)
            .appDestinations()
        }
        .task { await load() }
    }

    private func load() async {
        do { people = .loaded(try await env.social.reactors(entryID: entryID)) } catch { people = .failed(error.localizedDescription) }
    }
}
