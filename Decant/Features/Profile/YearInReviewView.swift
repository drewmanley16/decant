import SwiftUI
import UIKit

/// "Your year in wine": the year's highlights, as a screen and a 9:16 card to share.
struct YearInReviewView: View {
    var items: [ReviewItem]
    @Environment(AppEnvironment.self) private var env
    @State private var year = Calendar.current.component(.year, from: .now)
    @State private var image: UIImage?
    @State private var showActivity = false

    private var years: [Int] {
        let all = Set(items.map { Calendar.current.component(.year, from: $0.entry.consumedOn) })
        return all.sorted(by: >)
    }

    private var review: YearReview { StatsCalculator.yearReview(items, year: year) }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if years.count > 1 {
                    Picker("Year", selection: $year) {
                        ForEach(years, id: \.self) { Text(String($0)).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                if review.tastings == 0 {
                    EmptyStateView(symbol: "calendar", title: "Nothing logged in \(String(year))",
                                   message: "Your year in wine fills in as you rate bottles.")
                } else {
                    YearCardView(review: review, author: env.currentUser)
                        .frame(width: 1080, height: 1920)
                        .scaleEffect(0.3, anchor: .topLeading)
                        .frame(width: 324, height: 576, alignment: .topLeading)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .shadow(color: .black.opacity(0.2), radius: 14, y: 8)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(summary)
                    Button {
                        Task {
                            image = render()
                            showActivity = image != nil
                            Telemetry.track("year_review_shared", ["year": String(year)])
                        }
                    } label: {
                        Label("Share my year", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.primary)
                }
            }
            .padding(Metrics.gutter)
        }
        .screenBackground()
        .navigationTitle("Year in review")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if let latest = years.first, !years.contains(year) { year = latest }
            Telemetry.track("year_review_viewed")
        }
        .sheet(isPresented: $showActivity) {
            if let image { ActivityView(items: [image, "My \(String(year)) in wine, on Decant"]) }
        }
    }

    private var summary: String {
        var parts = ["\(review.tastings) tastings in \(String(year))", "\(review.uniqueWines) different wines"]
        if let wine = review.topWine { parts.append("most poured: \(wine.displayName)") }
        if let grape = review.topGrape { parts.append("top grape: \(grape)") }
        return parts.joined(separator: ", ")
    }

    @MainActor
    private func render() -> UIImage? {
        let renderer = ImageRenderer(content: YearCardView(review: review, author: env.currentUser))
        renderer.scale = 1
        renderer.proposedSize = ProposedViewSize(width: 1080, height: 1920)
        return renderer.uiImage
    }
}

/// The 1080×1920 shareable card.
struct YearCardView: View {
    var review: YearReview
    var author: Profile?

    private let gold = Color(red: 0.83, green: 0.7, blue: 0.48)
    private let cream = Color(red: 0.98, green: 0.96, blue: 0.93)

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.31, green: 0.06, blue: 0.11), Color(red: 0.1, green: 0.03, blue: 0.05)],
                           startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "wineglass.fill")
                    Text("DECANT").tracking(6)
                }
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(gold)

                Text(author.map { "\($0.displayName)’s" } ?? "My")
                    .font(.system(size: 52, weight: .regular, design: .serif))
                    .foregroundStyle(cream.opacity(0.8))
                    .padding(.top, 90)
                Text("\(String(review.year)) in wine")
                    .font(.system(size: 112, weight: .bold, design: .serif))
                    .foregroundStyle(cream)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)

                HStack(alignment: .top, spacing: 60) {
                    bigStat("\(review.tastings)", "tastings")
                    bigStat("\(review.uniqueWines)", "wines")
                    bigStat("\(review.fiveStars)", "five stars")
                }
                .padding(.top, 80)

                VStack(alignment: .leading, spacing: 44) {
                    if let wine = review.topWine, review.topWineCount > 1 {
                        line("Most poured", wine.displayName, "\(review.topWineCount) times")
                    }
                    if let best = review.bestRated {
                        line("Best bottle", best.wine.displayName, "\(best.rating.formatted())★")
                    }
                    if let grape = review.topGrape { line("Go-to grape", grape, nil) }
                    if let country = review.topCountry {
                        line("Favourite country", country, review.countries > 1 ? "+ \(review.countries - 1) more" : nil)
                    }
                    if let occasion = review.topOccasion { line("Favourite occasion", occasion, nil) }
                    if let month = review.busiestMonth {
                        line("Busiest month", month.formatted(.dateTime.month(.wide)), nil)
                    }
                }
                .padding(.top, 90)

                Spacer(minLength: 0)
                Text("Get your year in wine on Decant")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(gold)
            }
            .padding(.horizontal, 96)
            .padding(.vertical, 120)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 1080, height: 1920)
        .environment(\.dynamicTypeSize, .large)
    }

    private func bigStat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value).font(.system(size: 120, weight: .bold, design: .serif)).foregroundStyle(gold)
            Text(label).font(.system(size: 34, weight: .medium)).foregroundStyle(cream.opacity(0.75))
        }
    }

    private func line(_ label: String, _ value: String, _ extra: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label.uppercased()).font(.system(size: 26, weight: .semibold)).tracking(3).foregroundStyle(gold)
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                Text(value).font(.system(size: 54, weight: .semibold, design: .serif)).foregroundStyle(cream).lineLimit(1).minimumScaleFactor(0.6)
                if let extra { Text(extra).font(.system(size: 32)).foregroundStyle(cream.opacity(0.6)) }
            }
        }
    }
}
