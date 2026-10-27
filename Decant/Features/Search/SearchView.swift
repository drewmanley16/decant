import SwiftUI

@MainActor
@Observable
final class SearchViewModel {
    enum Scope: String, CaseIterable, Identifiable {
        case wines = "Wines"
        case people = "People"
        var id: String { rawValue }
    }

    var scope: Scope = .wines
    var query = WineSearchQuery()
    var wines: Loadable<[Wine]> = .idle
    var people: Loadable<[Profile]> = .idle
    var following: Set<UUID> = []
    private let env: AppEnvironment

    init(env: AppEnvironment) {
        self.env = env
    }

    func run() async {
        switch scope {
        case .wines:
            wines = .loading
            do { wines = .loaded(try await env.catalog.search(query, limit: 60)) } catch { wines = .failed(error.localizedDescription) }
        case .people:
            people = .loading
            do {
                people = .loaded(try await env.social.searchUsers(query.text))
                if let me = env.currentUser {
                    following = Set(((try? await env.social.following(of: me.id)) ?? []).map(\.id))
                }
            } catch {
                people = .failed(error.localizedDescription)
            }
        }
    }

    func toggleFollow(_ profile: Profile) async {
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
            Section {
                Picker("Search for", selection: $model.scope) {
                    ForEach(SearchViewModel.Scope.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: Metrics.gutter, bottom: 4, trailing: Metrics.gutter))

                if model.scope == .wines {
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
                }
            }
            .listRowSeparator(.hidden)

            switch model.scope {
            case .wines: wineResults
            case .people: peopleResults
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .searchable(text: $model.query.text, prompt: model.scope == .wines ? "Wine, winery, grape, region…" : "Name or username")
        .task(id: model.query) {
            try? await Task.sleep(for: .milliseconds(250)) // debounce typing
            await model.run()
        }
        .onChange(of: model.scope) { Task { await model.run() } }
        .sheet(isPresented: $showFilters) { SearchFilterSheet(query: $model.query) }
    }

    @ViewBuilder private var wineResults: some View {
        switch model.wines {
        case .loaded(let wines) where wines.isEmpty:
            EmptyStateView(symbol: "magnifyingglass", title: "No wines found",
                           message: "Try a different spelling, fewer filters — or scan the label.")
                .listRowBackground(Color.clear)
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

    @ViewBuilder private var peopleResults: some View {
        switch model.people {
        case .loaded(let people) where people.isEmpty:
            EmptyStateView(symbol: "person.2", title: "No one found", message: "Search by name or @username.")
                .listRowBackground(Color.clear)
        case .loaded(let people):
            ForEach(people) { profile in
                HStack(spacing: 12) {
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
                    FollowButton(isFollowing: model.following.contains(profile.id)) { Task { await model.toggleFollow(profile) } }
                }
                .listRowBackground(Color.clear)
            }
        case .failed(let message):
            ErrorStateView(message: message) { Task { await model.run() } }.listRowBackground(Color.clear)
        default:
            ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear)
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
                Picker("Max price", selection: $query.maxPrice) {
                    Text("Any").tag(Double?.none)
                    ForEach([15.0, 25, 50, 100, 250], id: \.self) { Text("Under $\(Int($0))").tag(Double?.some($0)) }
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
