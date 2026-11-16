import SwiftUI

/// Follow state shared by every list of people.
@MainActor
@Observable
final class FollowTracker {
    var following: Set<UUID> = []
    private let env: AppEnvironment
    private var loaded = false

    init(env: AppEnvironment) { self.env = env }

    func loadIfNeeded() async {
        guard !loaded, let me = env.currentUser else { return }
        loaded = true
        following = Set(((try? await env.social.following(of: me.id)) ?? []).map(\.id))
    }

    func toggle(_ profile: Profile) async {
        let isFollowing = following.contains(profile.id)
        do {
            if isFollowing {
                try await env.social.unfollow(profile.id)
                following.remove(profile.id)
            } else {
                try await env.social.follow(profile.id)
                following.insert(profile.id)
                env.show(profile.isPrivate ? "Follow request sent" : "Following @\(profile.username)", symbol: "person.badge.plus")
            }
        } catch {
            env.show(error.localizedDescription, symbol: "exclamationmark.triangle.fill")
        }
    }
}

@MainActor
@Observable
final class SearchViewModel {
    var query = WineSearchQuery()
    var wines: Loadable<[Wine]> = .idle
    /// People whose name or username matches the text; empty when nothing is typed.
    var people: [Profile] = []
    let follows: FollowTracker
    private let env: AppEnvironment

    /// How many matching people show above the wines before "See all".
    static let peoplePreview = 3

    init(env: AppEnvironment) {
        self.env = env
        self.follows = FollowTracker(env: env)
    }

    private var peopleText: String? {
        let text = query.text.trimmingCharacters(in: .whitespaces)
        let bare = text.hasPrefix("@") ? String(text.dropFirst()) : text
        // Filters only narrow wines, so a filtered search is clearly about wine.
        return bare.count >= 2 && !query.hasFilters && query.types.isEmpty ? bare : nil
    }

    func run() async {
        wines = .loading
        let peopleText = peopleText
        let (catalog, social, query) = (env.catalog, env.social, query)
        async let wineResult: Loadable<[Wine]> = {
            do { return .loaded(try await catalog.search(query, limit: 60)) } catch { var state = Loadable<[Wine]>.loading; state.fail(error); return state }
        }()
        async let peopleResult: [Profile] = {
            guard let peopleText else { return [] }
            return (try? await social.searchUsers(peopleText)) ?? []
        }()
        let (w, p) = await (wineResult, peopleResult)
        guard !Task.isCancelled else { return }
        people = p
        wines = w
        if !p.isEmpty { await follows.loadIfNeeded() }
    }
}

struct SearchView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var model: SearchViewModel?

    var body: some View {
        NavigationStack {
            Group {
                if let model { SearchContent(model: model) }
            }
            .screenBackground()
            .navigationTitle("Search")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: Route.findPeople("")) { Image(systemName: "person.badge.plus") }
                        .accessibilityLabel("Find people")
                }
            }
            .appDestinations()
        }
        .task {
            if model == nil {
                model = SearchViewModel(env: env)
                await model?.run()
            }
        }
    }
}

private struct SearchContent: View {
    @Bindable var model: SearchViewModel
    @State private var showFilters = false

    var body: some View {
        List {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Button { showFilters = true } label: {
                        Chip(title: "Filters", isSelected: model.query.hasFilters, systemImage: "slider.horizontal.3")
                    }
                    ForEach(WineType.allCases) { type in
                        Button {
                            if model.query.types.contains(type) { model.query.types.remove(type) } else { model.query.types.insert(type) }
                        } label: { Chip(title: type.displayName, isSelected: model.query.types.contains(type)) }
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, Metrics.gutter)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)

            if !model.people.isEmpty {
                ResultsHeader(title: "People")
                ForEach(model.people.prefix(SearchViewModel.peoplePreview)) { profile in
                    PersonRow(profile: profile, follows: model.follows)
                }
                if model.people.count > SearchViewModel.peoplePreview {
                    NavigationLink(value: Route.findPeople(model.query.text)) {
                        Text("See all \(model.people.count) people").font(.subheadline.weight(.semibold)).foregroundStyle(Palette.burgundy)
                    }
                    .listRowBackground(Color.clear)
                }
                ResultsHeader(title: "Wines")
            }
            wineResults
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .searchable(text: $model.query.text, prompt: "Wines, wineries, grapes, people…")
        .task(id: model.query) {
            try? await Task.sleep(for: .milliseconds(250)) // debounce typing
            guard !Task.isCancelled else { return }
            await model.run()
        }
        .sheet(isPresented: $showFilters) { SearchFilterSheet(query: $model.query) }
    }

    @ViewBuilder private var wineResults: some View {
        switch model.wines {
        case .loaded(let wines) where wines.isEmpty:
            if model.people.isEmpty {
                EmptyStateView(symbol: "magnifyingglass", title: "No results",
                               message: "Try a different spelling, fewer filters — or scan the label.")
                    .listRowBackground(Color.clear)
            } else {
                Text("No wines match “\(model.query.text)”.").font(.callout).foregroundStyle(Palette.secondaryText)
                    .listRowBackground(Color.clear)
            }
        case .loaded(let wines):
            ForEach(wines) { wine in
                NavigationLink(value: Route.wine(wine)) { WineRow(wine: wine) }
                    .listRowBackground(Color.clear)
            }
        case .failed(let message):
            ErrorStateView(message: message) { Task { await model.run() } }.listRowBackground(Color.clear)
        default:
            ForEach(0..<4, id: \.self) { _ in SkeletonBlock(height: 70).listRowBackground(Color.clear) }
        }
    }
}

private struct ResultsHeader: View {
    var title: String
    var body: some View {
        Text(title).font(.footnote.weight(.semibold)).textCase(.uppercase).tracking(0.6)
            .foregroundStyle(Palette.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 10)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A person with their avatar, name and a follow button.
struct PersonRow: View {
    var profile: Profile
    var follows: FollowTracker
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // At accessibility sizes the Follow button drops below the name
        // so long usernames don't get split mid-word.
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(spacing: 12))
        layout {
            NavigationLink(value: Route.user(profile.id)) {
                HStack(spacing: 12) {
                    AvatarView(profile: profile, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(profile.displayName).font(.headline)
                            if profile.isPrivate { Image(systemName: "lock.fill").font(.caption2).foregroundStyle(Palette.secondaryText) }
                        }
                        Text("@\(profile.username)").font(.subheadline).foregroundStyle(Palette.secondaryText)
                    }
                }
            }
            FollowButton(isFollowing: follows.following.contains(profile.id)) { Task { await follows.toggle(profile) } }
        }
        .listRowBackground(Color.clear)
    }
}

/// Look people up by name, with suggestions before anything is typed.
struct FindPeopleView: View {
    var initialText: String
    @Environment(AppEnvironment.self) private var env
    @State private var text = ""
    @State private var people: Loadable<[Profile]> = .idle
    @State private var follows: FollowTracker?

    var body: some View {
        List {
            switch people {
            case .loaded(let list) where list.isEmpty:
                EmptyStateView(symbol: "person.2", title: "No one found", message: "Search by name or @username — or share your invite code from Profile.")
                    .listRowBackground(Color.clear)
            case .loaded(let list):
                if trimmed.isEmpty { ResultsHeader(title: "Suggested") }
                if let follows {
                    ForEach(list) { PersonRow(profile: $0, follows: follows) }
                }
            case .failed(let message):
                ErrorStateView(message: message) { Task { await load() } }.listRowBackground(Color.clear)
            default:
                ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .screenBackground()
        .navigationTitle("Find people")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always), prompt: "Name or @username")
        .onAppear { if follows == nil { text = initialText; follows = FollowTracker(env: env) } }
        .task(id: text) {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await load()
        }
    }

    private var trimmed: String {
        let t = text.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("@") ? String(t.dropFirst()) : t
    }

    private func load() async {
        if case .loaded = people {} else { people = .loading }
        do {
            let result = try await env.social.searchUsers(trimmed)
            await follows?.loadIfNeeded()
            people = .loaded(result)
        } catch {
            people.fail(error)
        }
    }
}

struct FollowButton: View {
    var isFollowing: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(isFollowing ? "Following" : "Follow")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14).padding(.vertical, 7)
                .foregroundStyle(isFollowing ? Palette.charcoal : .white)
                .background(isFollowing ? Palette.hairline : Palette.burgundy, in: Capsule())
        }
        .buttonStyle(.borderless)
        .sensoryFeedback(.selection, trigger: isFollowing)
    }
}

extension WineSearchQuery {
    var hasFilters: Bool {
        country != nil || region != nil || grape != nil || vintage != nil || maxPrice != nil || minRating != nil
    }
}

private struct SearchFilterSheet: View {
    @Binding var query: WineSearchQuery
    @Environment(\.dismiss) private var dismiss

    private let countries = ["Argentina", "Australia", "France", "Germany", "Italy", "New Zealand", "Portugal", "Spain", "USA"]
    private let grapes = ["Cabernet Sauvignon", "Chardonnay", "Malbec", "Merlot", "Nebbiolo", "Pinot Noir", "Riesling", "Sangiovese", "Sauvignon Blanc", "Shiraz", "Tempranillo"]

    var body: some View {
        NavigationStack {
            Form {
                Picker("Country", selection: $query.country) {
                    Text("Any").tag(String?.none)
                    ForEach(countries, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                TextField("Region (e.g. Napa Valley)", text: Binding(get: { query.region ?? "" }, set: { query.region = $0.nilIfBlank }))
                Picker("Grape", selection: $query.grape) {
                    Text("Any").tag(String?.none)
                    ForEach(grapes, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                Picker("Vintage", selection: $query.vintage) {
                    Text("Any").tag(Int?.none)
                    ForEach((1980...Calendar.current.component(.year, from: .now)).reversed(), id: \.self) { Text(String($0)).tag(Int?.some($0)) }
                }
                Picker("Average rating", selection: $query.minRating) {
                    Text("Any").tag(Double?.none)
                    ForEach([3.0, 3.5, 4.0, 4.5], id: \.self) { Text("\($0.formatted())★ and up").tag(Double?.some($0)) }
                }
            }
            .brandedForm()
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Reset") {
                        let text = query.text
                        query = WineSearchQuery(text: text)
                    }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
