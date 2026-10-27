import Charts
import SwiftUI

struct StatsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var stats: WineStats?
    @State private var selectedMonth: Date?

    var body: some View {
        ScrollView {
            if let stats {
                if stats.totalTastings == 0 {
                    EmptyStateView(symbol: "chart.bar.xaxis", title: "No stats yet",
                                   message: "Rate a few wines and your tasting statistics will appear here.")
                } else {
                    content(stats)
                }
            } else {
                ProgressView().padding(60)
            }
        }
        .screenBackground()
        .navigationTitle("Statistics")
        .task {
            guard let me = env.currentUser else { return }
            stats = StatsCalculator.compute((try? await env.tastings.entries(forUser: me.id)) ?? [])
        }
    }

    private func content(_ s: WineStats) -> some View {
        VStack(spacing: 18) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                tile("\(s.totalTastings)", "Tastings", "book.closed")
                tile("\(s.uniqueWines)", "Unique wines", "wineglass")
                tile("\(s.uniqueWineries)", "Wineries", "building.columns")
                tile("\(s.countries.count)", "Countries", "globe.europe.africa")
                tile(s.averageRating.map { $0.formatted(.number.precision(.fractionLength(2))) } ?? "–", "Average rating", "star")
                tile(s.mostExpensive?.price?.formatted ?? "–", "Priciest bottle", "tag")
            }

            card("Monthly tastings") {
                Chart(s.monthly) { month in
                    BarMark(x: .value("Month", month.start, unit: .month), y: .value("Tastings", month.count))
                        .foregroundStyle(selectedMonth.map { Calendar.current.isDate($0, equalTo: month.start, toGranularity: .month) } == true
                                         ? Palette.gold : Palette.burgundy)
                        .cornerRadius(4)
                }
                .chartXSelection(value: $selectedMonth)
                .chartXAxis { AxisMarks(values: .stride(by: .month, count: 2)) { _ in AxisValueLabel(format: .dateTime.month(.abbreviated)) } }
                .frame(height: 180)
                if let selectedMonth, let month = s.monthly.first(where: { Calendar.current.isDate($0.start, equalTo: selectedMonth, toGranularity: .month) }) {
                    Text("\(month.start.formatted(.dateTime.month(.wide).year())): \(month.count) tasting\(month.count == 1 ? "" : "s")")
                        .font(.caption.weight(.semibold))
                }
            }

            card("Red vs. white & more") {
                HStack(spacing: 20) {
                    Chart(s.types) { item in
                        SectorMark(angle: .value("Count", item.value), innerRadius: .ratio(0.62), angularInset: 1.5)
                            .foregroundStyle(by: .value("Type", item.label))
                            .cornerRadius(3)
                    }
                    .chartForegroundStyleScale(domain: s.types.map(\.label), range: s.types.map { color(forType: $0.label) })
                    .chartLegend(.hidden)
                    .frame(width: 130, height: 130)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(s.types) { item in
                            HStack(spacing: 6) {
                                Circle().fill(color(forType: item.label)).frame(width: 9, height: 9)
                                Text(item.label).font(.subheadline)
                                Spacer()
                                Text("\(item.value)").font(.subheadline.monospacedDigit()).foregroundStyle(Palette.secondaryText)
                            }
                        }
                    }
                }
            }

            if !s.grapes.isEmpty { barCard("Favorite grapes", s.grapes) }
            if !s.regions.isEmpty { barCard("Favorite regions", s.regions) }
            if !s.countries.isEmpty { barCard("Countries explored", s.countries) }

            if !s.topRated.isEmpty {
                card("Top-rated wines") {
                    ForEach(Array(s.topRated.enumerated()), id: \.offset) { index, item in
                        NavigationLink(value: Route.wine(item.wine)) {
                            HStack(spacing: 12) {
                                Text("\(index + 1)").font(.system(.title3, design: .serif).weight(.semibold)).foregroundStyle(Palette.gold).frame(width: 24)
                                BottleArtView(wine: item.wine, height: 50).frame(width: 22)
                                Text(item.wine.displayName).font(.subheadline.weight(.medium)).lineLimit(1).foregroundStyle(Palette.charcoal)
                                Spacer()
                                StarRatingView(rating: item.rating, size: 10)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(Metrics.gutter)
    }

    private func tile(_ value: String, _ label: String, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(Palette.gold)
            Text(value).font(.system(.title2, design: .serif).weight(.semibold)).lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.caption).foregroundStyle(Palette.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(padding: 14)
        .accessibilityElement(children: .combine)
    }

    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(Typo.title3)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private func barCard(_ title: String, _ data: [WineStats.Count]) -> some View {
        card(title) {
            Chart(Array(data.prefix(6))) { item in
                BarMark(x: .value("Count", item.value), y: .value("Name", item.label))
                    .foregroundStyle(Palette.burgundy.gradient)
                    .cornerRadius(4)
                    .annotation(position: .trailing) { Text("\(item.value)").font(.caption2).foregroundStyle(Palette.secondaryText) }
            }
            .chartXAxis(.hidden)
            .frame(height: CGFloat(min(6, data.count)) * 34 + 10)
        }
    }

    private func color(forType label: String) -> Color {
        WineType.allCases.first { $0.displayName == label }.map(Palette.wineColor) ?? Palette.secondaryText
    }
}
