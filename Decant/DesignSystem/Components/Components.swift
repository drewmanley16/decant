import SwiftUI

// MARK: - Load state

enum Loadable<Value> {
    case idle
    case loading
    case loaded(Value)
    case failed(String)

    var value: Value? {
        if case .loaded(let value) = self { return value }
        return nil
    }

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
}

// MARK: - Cards & rows

/// Compact vertical card used in horizontal carousels.
struct WineCard: View {
    var wine: Wine

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            BottleStage(tint: Palette.wineColor(wine.type)) {
                BottleArtView(wine: wine, height: 130)
            }
            .frame(height: 150)
            .frame(maxWidth: .infinity)
            .background(Palette.cream.opacity(0.6), in: RoundedRectangle(cornerRadius: 18, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(wine.name)
                    .font(.system(.subheadline, design: .serif).weight(.semibold))
                    .lineLimit(2, reservesSpace: true)
                    .foregroundStyle(Palette.charcoal)
                Text("\(wine.producer) · \(wine.vintageLabel)")
                    .font(.caption)
                    .foregroundStyle(Palette.secondaryText)
                    .lineLimit(1)
                HStack {
                    RatingPill(rating: wine.communityRating, count: wine.ratingsCount)
                    Spacer()
                    if let price = wine.price {
                        Text(price.formatted).font(.caption.weight(.medium)).foregroundStyle(Palette.secondaryText)
                    }
                }
            }
        }
        .frame(width: 160)
        .cardSurface(padding: 10)
        .accessibilityElement(children: .combine)
    }
}

/// Full-width list row.
struct WineRow: View {
    var wine: Wine
    var trailing: String?

    var body: some View {
        HStack(spacing: 14) {
            BottleArtView(wine: wine, height: 74)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(wine.name)
                    .font(.system(.body, design: .serif).weight(.semibold))
                    .foregroundStyle(Palette.charcoal)
                    .lineLimit(2)
                Text("\(wine.producer) · \(wine.vintageLabel)")
                    .font(.subheadline)
                    .foregroundStyle(Palette.secondaryText)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    TypeDot(type: wine.type)
                    if !wine.locationLine.isEmpty {
                        Text(wine.locationLine).font(.caption).foregroundStyle(Palette.secondaryText).lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                RatingPill(rating: wine.communityRating, count: nil)
                if let trailing {
                    Text(trailing).font(.caption).foregroundStyle(Palette.secondaryText)
                } else if let price = wine.price {
                    Text(price.formatted).font(.caption).foregroundStyle(Palette.secondaryText)
                }
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct TypeDot: View {
    var type: WineType

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(Palette.wineColor(type)).frame(width: 8, height: 8)
                .overlay(Circle().strokeBorder(.white.opacity(0.4), lineWidth: 0.5))
            Text(type.displayName).font(.caption.weight(.medium)).foregroundStyle(Palette.secondaryText)
        }
    }
}

struct AvatarView: View {
    var profile: Profile
    var size: CGFloat = 40

    var body: some View {
        ZStack {
            Circle().fill(gradient)
            if let url = profile.avatarURL {
                StoredImage(path: url.isFileURL ? "file:avatars/\(url.lastPathComponent)" : url.absoluteString,
                            maxPixel: size * 3) {
                    initials
                }
                .scaledToFill()
                .clipShape(Circle())
            } else {
                initials
            }
        }
        .frame(width: size, height: size)
        .overlay(Circle().strokeBorder(Palette.hairline, lineWidth: 0.5))
        .accessibilityHidden(true)
    }

    private var initials: some View {
        Text(profile.initials)
            .font(.system(size: size * 0.38, weight: .semibold, design: .serif))
            .foregroundStyle(.white)
    }

    private var gradient: LinearGradient {
        let hues: [Color] = [Palette.burgundy, Color(red: 0.36, green: 0.27, blue: 0.2), Color(red: 0.25, green: 0.3, blue: 0.27),
                             Color(red: 0.55, green: 0.42, blue: 0.24), Color(red: 0.32, green: 0.22, blue: 0.35)]
        let base = hues[Int(profile.id.stableSeed % UInt64(hues.count))]
        return LinearGradient(colors: [base, base.opacity(0.75)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

struct SourceBadge: View {
    var source: InfoSource

    var body: some View {
        Label(source.badge, systemImage: icon)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(color)
            .background(color.opacity(0.12), in: Capsule())
            .accessibilityLabel("Source: \(source.badge)")
    }

    private var icon: String {
        switch source {
        case .verified: "checkmark.seal.fill"
        case .label: "text.viewfinder"
        case .editorial: "book.closed.fill"
        case .aiSuggested: "sparkles"
        case .user: "person.fill"
        }
    }

    private var color: Color {
        switch source {
        case .verified, .label: Palette.success
        case .editorial: Palette.gold
        case .aiSuggested: Color.purple
        case .user: Palette.secondaryText
        }
    }
}

struct ConfidenceBadge: View {
    var confidence: MatchConfidence

    var body: some View {
        Label(confidence.label, systemImage: icon)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(color)
            .background(color.opacity(0.14), in: Capsule())
    }

    private var icon: String {
        switch confidence {
        case .high: "checkmark.circle.fill"
        case .medium: "questionmark.circle.fill"
        case .low: "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch confidence {
        case .high: Palette.success
        case .medium: Palette.warning
        case .low: Palette.burgundy
        }
    }
}

struct SectionHeader: View {
    var title: String
    var subtitle: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Typo.title3).foregroundStyle(Palette.charcoal)
                if let subtitle {
                    Text(subtitle).font(.subheadline).foregroundStyle(Palette.secondaryText)
                }
            }
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action).font(.subheadline.weight(.semibold))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

struct Chip: View {
    var title: String
    var isSelected = false
    var systemImage: String?

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage { Image(systemName: systemImage).font(.caption) }
            Text(title).font(.subheadline.weight(.medium))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .foregroundStyle(isSelected ? .white : Palette.charcoal)
        .background(isSelected ? Palette.burgundy : Palette.creamElevated, in: Capsule())
        .overlay(Capsule().strokeBorder(isSelected ? .clear : Palette.hairline, lineWidth: 1))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Wrapping horizontal layout for chips and tags.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if rows[rows.count - 1].width + size.width > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.indices.append(index)
            row.width += size.width + (row.indices.count > 1 ? spacing : 0)
            row.height = max(row.height, size.height)
            rows[rows.count - 1] = row
        }
        return rows
    }
}

// MARK: - States

struct EmptyStateView: View {
    var symbol: String
    var title: String
    var message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Palette.gold)
                .padding(22)
                .background(Palette.gold.opacity(0.1), in: Circle())
            Text(title).font(Typo.title3).multilineTextAlignment(.center)
            Text(message)
                .font(.callout)
                .foregroundStyle(Palette.secondaryText)
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.primary)
                    .frame(maxWidth: 260)
                    .padding(.top, 6)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity)
    }
}

struct ErrorStateView: View {
    var message: String
    var retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark").font(.system(size: 30)).foregroundStyle(Palette.secondaryText)
            Text(message).font(.callout).foregroundStyle(Palette.secondaryText).multilineTextAlignment(.center)
            Button("Try again", action: retry).buttonStyle(.bordered)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }
}

/// Animated placeholder shimmer for loading skeletons.
struct Shimmer: ViewModifier {
    @State private var phase: CGFloat = -1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay {
                if !reduceMotion {
                    GeometryReader { proxy in
                        LinearGradient(colors: [.clear, .white.opacity(0.35), .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: proxy.size.width * 0.6)
                            .offset(x: phase * proxy.size.width * 1.6)
                    }
                    .mask(content)
                }
            }
            .onAppear {
                withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) { phase = 1 }
            }
    }
}

struct SkeletonBlock: View {
    var width: CGFloat?
    var height: CGFloat
    var radius: CGFloat = 10

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Palette.hairline.opacity(0.7))
            .frame(width: width, height: height)
            .modifier(Shimmer())
            .accessibilityHidden(true)
    }
}

struct WineCardSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SkeletonBlock(height: 150, radius: 18)
            SkeletonBlock(width: 120, height: 14)
            SkeletonBlock(width: 80, height: 10)
        }
        .frame(width: 160)
        .cardSurface(padding: 10)
    }
}

extension Date {
    var relativeShort: String {
        formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }
}
