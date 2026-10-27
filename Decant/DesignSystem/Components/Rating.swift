import SwiftUI

/// Read-only star rating with half-star precision.
struct StarRatingView: View {
    var rating: Double
    var size: CGFloat = 14
    var color: Color = Palette.gold

    var body: some View {
        HStack(spacing: size * 0.15) {
            ForEach(0..<5, id: \.self) { index in
                Image(systemName: symbol(for: index))
                    .font(.system(size: size, weight: .semibold))
                    .foregroundStyle(color)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(rating.formatted(.number.precision(.fractionLength(0...1)))) out of 5 stars")
    }

    private func symbol(for index: Int) -> String {
        let value = rating - Double(index)
        if value >= 1 { return "star.fill" }
        if value >= 0.5 { return "star.leadinghalf.filled" }
        return "star"
    }
}

/// Interactive 0.5–5 star input. Tap or drag across the stars; haptic on each change.
/// Exposed to VoiceOver as an adjustable control.
struct StarRatingPicker: View {
    @Binding var rating: Double?
    var size: CGFloat = 38

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                ForEach(0..<5, id: \.self) { index in
                    Image(systemName: symbol(for: index))
                        .font(.system(size: size, weight: .medium))
                        .foregroundStyle(rating == nil ? Palette.hairline : Palette.gold)
                        .frame(maxWidth: .infinity)
                        .scaleEffect(isActive(index) ? 1.0 : 0.92)
                        .animation(.snappy(duration: 0.18), value: rating)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { update(x: $0.location.x, width: proxy.size.width) }
            )
        }
        .frame(height: size * 1.3)
        .sensoryFeedback(.selection, trigger: rating)
        .accessibilityElement()
        .accessibilityLabel("Rating")
        .accessibilityValue(rating.map { "\($0.formatted()) stars" } ?? "Not rated")
        .accessibilityAdjustableAction { direction in
            let current = rating ?? 0
            switch direction {
            case .increment: rating = min(5, current + 0.5)
            case .decrement: rating = current <= 0.5 ? nil : current - 0.5
            @unknown default: break
            }
        }
    }

    private func isActive(_ index: Int) -> Bool { (rating ?? 0) > Double(index) }

    private func symbol(for index: Int) -> String {
        let value = (rating ?? 0) - Double(index)
        if value >= 1 { return "star.fill" }
        if value >= 0.5 { return "star.leadinghalf.filled" }
        return "star"
    }

    private func update(x: CGFloat, width: CGFloat) {
        guard width > 0 else { return }
        let raw = Double(max(0, min(x, width)) / width) * 5
        let stepped = max(0.5, (raw * 2).rounded(.up) / 2)
        if stepped != rating { rating = stepped }
    }
}

struct RatingPill: View {
    var rating: Double?
    var count: Int?

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "star.fill").font(.caption2).foregroundStyle(Palette.gold)
            Text(rating.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "–")
                .font(.caption.weight(.semibold).monospacedDigit())
            if let count, count > 0 {
                Text("(\(count))").font(.caption2).foregroundStyle(Palette.secondaryText)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
