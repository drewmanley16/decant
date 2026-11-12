import SwiftUI

struct ProfileView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        NavigationStack {
            Group {
                if let me = env.currentUser {
                    ProfileContent(userID: me.id, isMe: true)
                }
            }
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: Route.settings) { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
                if let me = env.currentUser {
                    ToolbarItem(placement: .topBarLeading) {
                        ShareLink(item: DeepLink.user(me.id).url, message: Text("My wine diary on Decant")) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .accessibilityLabel("Share profile")
                    }
                }
            }
            .appDestinations()
        }
    }
}

struct UserProfileView: View {
    var userID: UUID
    @Environment(AppEnvironment.self) private var env

    @State private var reporting = false
    @State private var confirmBlock = false

    var body: some View {
        ProfileContent(userID: userID, isMe: userID == env.currentUser?.id)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if userID != env.currentUser?.id {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            ShareLink(item: DeepLink.user(userID).url) { Label("Share profile", systemImage: "square.and.arrow.up") }
                            Button { reporting = true } label: { Label("Report account", systemImage: "flag") }
                            Button(role: .destructive) { confirmBlock = true } label: { Label("Block", systemImage: "hand.raised") }
                        } label: { Image(systemName: "ellipsis.circle") }
                        .accessibilityLabel("More options")
                    }
                }
            }
            .sheet(isPresented: $reporting) { ReportSheet(target: .user(userID)) }
            .confirmationDialog("Block this account?", isPresented: $confirmBlock, titleVisibility: .visible) {
                Button("Block", role: .destructive) { Task { await BlockAction.block(userID, name: "this account", env: env) } }
            } message: {
                Text("They won't be able to see your profile or content, and you won't see theirs.")
            }
    }
}

private struct ProfileContent: View {
    var userID: UUID
    var isMe: Bool
    @Environment(AppEnvironment.self) private var env
    @State private var summary: Loadable<ProfileSummary> = .idle
    @State private var diary: [ReviewItem] = []
    @State private var stats = WineStats()
    @State private var shortcutCounts: (wishlist: Int, scans: Int, milestones: String)?
    @State private var editing = false
    @State private var invite: InviteStatus?
    @State private var editingEntry: ReviewItem?
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                switch summary {
                case .loaded(let s):
                    header(s)
                    if s.canViewContent {
                        if isMe { shortcuts }
                        if isMe, let invite { InviteCard(invite: invite) }
                        statsTeaser
                        diarySection
                    } else {
                        EmptyStateView(symbol: "lock.fill", title: "This profile is private",
                                       message: s.isFollowing ? "Your follow request is pending." : "Follow to see their tastings.")
                    }
                case .failed(let message):
                    ErrorStateView(message: message) { Task { await load() } }
                default:
                    VStack(spacing: 16) {
                        SkeletonBlock(width: 84, height: 84, radius: 42)
                        SkeletonBlock(width: 160, height: 22)
                        SkeletonBlock(height: 120, radius: Metrics.cardRadius)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(Metrics.gutter)
        }
        .screenBackground()
        .refreshable { await load() }
        .task(id: userID) { await load() }
        .onChange(of: env.diaryRevision) { Task { await load() } }
        .onChange(of: env.moderationRevision) { Task { await load() } }
        .sheet(isPresented: $editing) {
            if let me = env.currentUser { EditProfileView(profile: me) }
        }
        .sheet(item: $editingEntry) { item in
            RateWineView(wine: item.wine, editing: item.entry)
        }
    }

    private func load() async {
        do {
            let s = try await env.social.profileSummary(userID: userID)
            summary = .loaded(s)
            if s.canViewContent {
                diary = try await env.tastings.entries(forUser: userID)
                stats = StatsCalculator.compute(diary)
                if isMe { await loadShortcutCounts() }
            }
        } catch {
            summary = .failed(error.localizedDescription)
        }
    }

    private func loadShortcutCounts() async {
        async let wishlist = try? env.cellar.wishlist()
        async let scans = try? env.scans.history(limit: 500)
        async let bottles = try? env.cellar.bottles()
        invite = try? await env.auth.myInvite()
        let milestones = StatsCalculator.milestones(history: StatsCalculator.history(diary), bottles: await bottles ?? [])
        shortcutCounts = (await wishlist?.count ?? 0, await scans?.count ?? 0,
                          "\(milestones.filter(\.achieved).count)/\(milestones.count)")
    }

    private func header(_ s: ProfileSummary) -> some View {
        // Your own profile reflects edits immediately, without waiting for a reload.
        let profile = isMe ? (env.currentUser ?? s.profile) : s.profile
        return VStack(spacing: 14) {
            if isMe {
                Button { editing = true } label: {
                    AvatarView(profile: profile, size: 88)
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: profile.avatarURL == nil ? "plus" : "pencil")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                                .frame(width: 28, height: 28)
                                .background(Palette.burgundy, in: Circle())
                                .overlay(Circle().strokeBorder(Palette.cream, lineWidth: 2.5))
                                .offset(x: 2, y: 2)
                        }
                }
                .buttonStyle(PressableCardStyle())
                .accessibilityLabel("Edit profile photo")
            } else {
                AvatarView(profile: profile, size: 88)
            }
            VStack(spacing: 3) {
                HStack(spacing: 6) {
                    Text(profile.displayName).font(Typo.title2)
                    if profile.isPrivate { Image(systemName: "lock.fill").font(.caption).foregroundStyle(Palette.secondaryText) }
                }
                Text("@\(profile.username)").font(.subheadline).foregroundStyle(Palette.secondaryText)
            }
            if let bio = profile.bio {
                Text(bio).font(.callout).multilineTextAlignment(.center)
            } else if isMe {
                Button("Add a bio") { editing = true }
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Palette.burgundy)
            }
            HStack(spacing: 0) {
                counter(s.tastings, "Tastings", route: nil)
                counter(s.followers, "Followers", route: s.canViewContent ? .followers(userID) : nil)
                counter(s.following, "Following", route: s.canViewContent ? .following(userID) : nil)
            }
            if isMe {
                Button { editing = true } label: {
                    Label("Edit profile", systemImage: "pencil")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Palette.burgundy)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(Palette.burgundy.opacity(0.08), in: Capsule())
                        .overlay(Capsule().strokeBorder(Palette.burgundy.opacity(0.2), lineWidth: 1))
                }
                .buttonStyle(PressableCardStyle())
                .padding(.horizontal, 40)
            } else {
                FollowButton(isFollowing: s.isFollowing) {
                    Task {
                        if s.isFollowing { try? await env.social.unfollow(userID) } else { try? await env.social.follow(userID) }
                        await load()
                    }
                }
            }
            if isMe && env.mode == .local {
                Label("Local Mode · stored on this device", systemImage: "iphone")
                    .font(.caption).foregroundStyle(Palette.secondaryText)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private func counter(_ value: Int, _ label: String, route: Route?) -> some View {
        let content = VStack(spacing: 2) {
            Text("\(value)").font(.system(.title3, design: .serif).weight(.semibold))
            Text(label).font(.caption).foregroundStyle(Palette.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        if let route {
            NavigationLink(value: route) { content }.buttonStyle(.plain)
        } else {
            content
        }
    }

    private var shortcuts: some View {
        // Three tiles side by side leave ~90pt each, which splits "Milestones"
        // mid-word at accessibility sizes — stack them instead.
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 10))
            : AnyLayout(HStackLayout(spacing: 10))
        return layout {
            shortcut("Wishlist", "bookmark.fill", .wishlist, value: shortcutCounts.map { "\($0.wishlist)" })
            shortcut("Scans", "viewfinder", .scanHistory, value: shortcutCounts.map { "\($0.scans)" })
            shortcut("Milestones", "rosette", .milestones, value: shortcutCounts?.milestones)
        }
    }

    private func shortcut(_ title: String, _ symbol: String, _ route: Route, value: String?) -> some View {
        let tileLayout = typeSize.isAccessibilitySize
            ? AnyLayout(HStackLayout(spacing: 14))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
        return NavigationLink(value: route) {
            tileLayout {
                Image(systemName: symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.burgundy)
                    .frame(width: 32, height: 32)
                    .background(Palette.burgundy.opacity(0.1), in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(value ?? "–")
                        .font(.system(.title3, design: .serif).weight(.semibold))
                        .foregroundStyle(Palette.charcoal)
                        .contentTransition(.numericText())
                    Text(title).font(.caption.weight(.medium)).foregroundStyle(Palette.secondaryText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface(padding: 14)
        }
        .buttonStyle(PressableCardStyle())
        .accessibilityElement(children: .combine)
    }

    private var statsTeaser: some View {
        NavigationLink(value: Route.stats) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(isMe ? "Your taste & year in wine" : "Statistics").font(Typo.title3)
                    Spacer()
                    if isMe { Image(systemName: "chevron.right").foregroundStyle(Palette.secondaryText) }
                }
                let cells = [
                    ("\(stats.uniqueWines)", "Wines"),
                    ("\(stats.uniqueWineries)", "Wineries"),
                    ("\(stats.countries.count)", "Countries"),
                    (stats.averageRating.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "–", "Avg ★"),
                ]
                // Four across at accessibility sizes breaks "Wineries" and
                // "Countries" mid-word, so use a 2×2 grid there.
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0),
                                         count: typeSize.isAccessibilitySize ? 2 : 4),
                          spacing: 14) {
                    ForEach(cells, id: \.1) { statCell($0.0, $0.1) }
                }
            }
            .foregroundStyle(Palette.charcoal)
            .cardSurface()
        }
        .buttonStyle(.plain)
        .disabled(!isMe)
    }

    private func statCell(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(.title2, design: .serif).weight(.semibold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(Palette.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var diarySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Diary", subtitle: diary.isEmpty ? nil : "\(diary.count) tasting\(diary.count == 1 ? "" : "s")")
            if diary.isEmpty {
                EmptyStateView(symbol: "book.closed", title: "No tastings yet",
                               message: isMe ? "Scan or search for a wine and rate it to start your diary." : "Nothing logged yet.",
                               actionTitle: isMe ? "Scan a wine" : nil, action: isMe ? { env.isScannerPresented = true } : nil)
            } else {
                ForEach(diary) { item in
                    NavigationLink(value: Route.entry(item.id)) {
                        HStack(spacing: 14) {
                            VStack(spacing: 0) {
                                Text(item.entry.consumedOn.formatted(.dateTime.month(.abbreviated))).font(.caption2.weight(.semibold)).textCase(.uppercase)
                                Text(item.entry.consumedOn.formatted(.dateTime.day())).font(.system(.title3, design: .serif).weight(.semibold))
                            }
                            .foregroundStyle(Palette.burgundy)
                            .fixedSize()
                            .frame(minWidth: 40)
                            BottleArtView(wine: item.wine, height: 60).frame(width: 26)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.wine.displayName).font(.system(.subheadline, design: .serif).weight(.semibold))
                                    .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                                Text(item.wine.producer).font(.caption).foregroundStyle(Palette.secondaryText)
                                    .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                                HStack(spacing: 6) {
                                    if let r = item.entry.rating { StarRatingView(rating: r, size: 10) }
                                    if item.entry.isFavorite { Image(systemName: "heart.fill").font(.caption2).foregroundStyle(Palette.burgundy) }
                                    if item.entry.review != nil { Image(systemName: "text.alignleft").font(.caption2).foregroundStyle(Palette.secondaryText) }
                                }
                            }
                            Spacer()
                        }
                        .foregroundStyle(Palette.charcoal)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if isMe {
                            Button { editingEntry = item } label: { Label("Edit tasting", systemImage: "pencil") }
                        }
                        NavigationLink(value: Route.wine(item.wine)) { Label("View wine", systemImage: "wineglass") }
                    }
                    Divider()
                }
            }
        }
    }
}

/// Your personal invite code, ready to copy or share.
private struct InviteCard: View {
    var invite: InviteStatus
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Invite friends", systemImage: "envelope.open.fill")
                    .font(Typo.title3)
                    .foregroundStyle(Palette.charcoal)
                Spacer()
                Text(invite.isUnlimited ? "Unlimited"
                     : invite.remaining == 0 ? "All used" : "\(invite.remaining) of \(invite.maxUses) left")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(invite.remaining == 0 ? Palette.secondaryText : Palette.burgundy)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Palette.burgundy.opacity(0.08), in: Capsule())
            }
            Text("Decant is invite-only. Share your code with people you'd like to taste with.")
                .font(.callout).foregroundStyle(Palette.secondaryText)
            HStack(spacing: 10) {
                Button {
                    UIPasteboard.general.string = invite.code
                    env.show("Invite code copied", symbol: "doc.on.doc.fill")
                } label: {
                    HStack {
                        Text(invite.code)
                            .font(.system(.title3, design: .monospaced).weight(.semibold))
                            .tracking(4)
                            .foregroundStyle(Palette.charcoal)
                        Spacer()
                        Image(systemName: "doc.on.doc").foregroundStyle(Palette.secondaryText)
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 48)
                    .background(Palette.cream, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Palette.gold.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                }
                .buttonStyle(PressableCardStyle())
                .accessibilityLabel("Copy invite code \(invite.code.map(String.init).joined(separator: " "))")
                ShareLink(item: DeepLink.invite(invite.code).url,
                          message: Text("Join me on Decant, the wine diary. My invite code is \(invite.code).")) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .background(Palette.burgundy, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .accessibilityLabel("Share invite")
                .disabled(invite.remaining == 0)
            }
        }
        .cardSurface()
    }
}

struct PeopleListView: View {
    enum Kind { case followers, following }
    var userID: UUID
    var kind: Kind
    @Environment(AppEnvironment.self) private var env
    @State private var people: [Profile] = []

    var body: some View {
        List(people) { profile in
            NavigationLink(value: Route.user(profile.id)) {
                HStack(spacing: 12) {
                    AvatarView(profile: profile, size: 40)
                    VStack(alignment: .leading) {
                        Text(profile.displayName).font(.headline)
                        Text("@\(profile.username)").font(.caption).foregroundStyle(Palette.secondaryText)
                    }
                }
            }
        }
        .overlay { if people.isEmpty { Text("No one yet").foregroundStyle(Palette.secondaryText) } }
        .navigationTitle(kind == .followers ? "Followers" : "Following")
        .task {
            people = (try? await (kind == .followers ? env.social.followers(of: userID) : env.social.following(of: userID))) ?? []
        }
    }
}

struct WishlistView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var items: Loadable<[WishlistItem]> = .idle

    var body: some View {
        Group {
            switch items {
            case .loaded(let list) where list.isEmpty:
                EmptyStateView(symbol: "bookmark", title: "Your wishlist is empty",
                               message: "Tap the bookmark on any wine to save it for later.")
            case .loaded(let list):
                List {
                    ForEach(list) { item in
                        NavigationLink(value: Route.wine(item.wine)) { WineRow(wine: item.wine) }
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            let id = list[index].wine.id
                            Task { try? await env.cellar.setWishlisted(false, wineID: id); await load() }
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
        .screenBackground()
        .navigationTitle("Wishlist")
        .task { await load() }
    }

    private func load() async {
        do { items = .loaded(try await env.cellar.wishlist()) } catch { items = .failed(error.localizedDescription) }
    }
}

struct NotificationsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var items: Loadable<[AppNotification]> = .idle

    var body: some View {
        Group {
            switch items {
            case .loaded(let list) where list.isEmpty:
                EmptyStateView(symbol: "bell", title: "No notifications", message: "Follows, likes and comments will show up here.")
            case .loaded(let list):
                List(list) { n in
                    NavigationLink(value: n.entryID.map(Route.entry) ?? Route.user(n.actor.id)) {
                        HStack(spacing: 12) {
                            AvatarView(profile: n.actor, size: 38)
                            VStack(alignment: .leading, spacing: 2) {
                                (Text(n.actor.displayName).bold() + Text(" \(n.message)")).font(.subheadline)
                                Text(n.createdAt.relativeShort).font(.caption).foregroundStyle(Palette.secondaryText)
                            }
                            Spacer()
                            if !n.isRead { Circle().fill(Palette.burgundy).frame(width: 8, height: 8).accessibilityLabel("Unread") }
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
        .screenBackground()
        .navigationTitle("Notifications")
        .task {
            await load()
            try? await env.social.markNotificationsRead()
            env.setBadge(0)
        }
    }

    private func load() async {
        do { items = .loaded(try await env.social.notifications()) } catch { items = .failed(error.localizedDescription) }
    }
}
