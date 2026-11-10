import SwiftUI

/// Colours for the dark wall the shelves hang on. Fixed in both themes: it's a lit room.
enum CellarWallStyle {
    static let wall = Color(red: 0.075, green: 0.058, blue: 0.052)
    static let wallDeep = Color(red: 0.045, green: 0.035, blue: 0.032)
    static let glow = Color(red: 1.0, green: 0.72, blue: 0.42)
    static let text = Color(red: 0.95, green: 0.92, blue: 0.89)
    static let secondaryText = Color(red: 0.72, green: 0.67, blue: 0.63)

    static func wood(_ finish: ShelfFinish) -> Color {
        switch finish {
        case .oak: Color(red: 0.62, green: 0.45, blue: 0.28)
        case .walnut: Color(red: 0.40, green: 0.26, blue: 0.17)
        case .ebony: Color(red: 0.16, green: 0.12, blue: 0.11)
        case .whitewash: Color(red: 0.82, green: 0.78, blue: 0.72)
        }
    }
}

/// The cellar as lit shelves, one per wine style. Each shelf scrolls sideways when
/// it holds more bottles than fit across the screen.
struct CellarWallView: View {
    var model: CellarViewModel
    var onSelect: (CellarBottle) -> Void

    static let bottleHeight: CGFloat = 172

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 30) {
                ForEach(model.wall.shelves) { shelf in
                    ShelfRow(shelf: shelf, finish: model.settings.finish, dimmed: model.dimmedIDs, onSelect: onSelect)
                }
            }
            .padding(.top, 18)
            .padding(.bottom, 120)
        }
        .scrollIndicators(.hidden)
        .background {
            LinearGradient(colors: [CellarWallStyle.wall, CellarWallStyle.wallDeep], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        }
    }
}

private struct ShelfRow: View {
    var shelf: CellarWall.Shelf
    var finish: ShelfFinish
    var dimmed: Set<UUID>
    var onSelect: (CellarBottle) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(shelf.title)
                    .font(.system(.title3, design: .serif).weight(.medium))
                    .foregroundStyle(CellarWallStyle.text)
                Spacer()
                Text("\(shelf.bottleCount) bottle\(shelf.bottleCount == 1 ? "" : "s")")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(CellarWallStyle.secondaryText)
            }
            .padding(.horizontal, Metrics.gutter)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            ZStack(alignment: .bottom) {
                // Warm LED wash rising up the wall from the back of the shelf.
                LinearGradient(colors: [CellarWallStyle.glow.opacity(0.2), CellarWallStyle.glow.opacity(0.05), .clear],
                               startPoint: .bottom, endPoint: .top)
                    .frame(height: CellarWallView.bottleHeight * 0.85)
                    .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.18),
                                                 .init(color: .black, location: 0.82), .init(color: .clear, location: 1)],
                                         startPoint: .leading, endPoint: .trailing))
                    .padding(.bottom, Ledge.thickness)
                    .allowsHitTesting(false)
                Ledge(finish: finish)
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .bottom, spacing: 2) {
                        ForEach(shelf.bottles) { bottle in
                            Button { onSelect(bottle) } label: {
                                ShelfBottle(bottle: bottle)
                            }
                            .buttonStyle(LiftButtonStyle())
                            .opacity(dimmed.contains(bottle.id) ? 0.22 : 1)
                            .accessibilityLabel("\(bottle.wine.displayName), \(bottle.quantity) in cellar")
                            .accessibilityHint("Opens the bottle in 3D")
                        }
                    }
                    .padding(.horizontal, Metrics.gutter - 4)
                    // Bottles stand on the ledge's top surface.
                    .padding(.bottom, Ledge.thickness - 2)
                }
                .scrollIndicators(.hidden)
                .scrollClipDisabled()
            }
        }
    }
}

/// A slim floating shelf with a lit top edge.
private struct Ledge: View {
    static let thickness: CGFloat = 12
    var finish: ShelfFinish

    var body: some View {
        let wood = CellarWallStyle.wood(finish)
        ZStack(alignment: .top) {
            Rectangle()
                .fill(LinearGradient(colors: [wood, wood.mix(with: .black, by: 0.45)], startPoint: .top, endPoint: .bottom))
            Rectangle()
                .fill(.white.opacity(0.22))
                .frame(height: 1)
        }
        .frame(height: Self.thickness)
        .shadow(color: .black.opacity(0.55), radius: 10, y: 8)
        .padding(.horizontal, 10)
        .accessibilityHidden(true)
    }
}

private struct ShelfBottle: View {
    var bottle: CellarBottle

    var body: some View {
        BottleRender(wine: bottle.wine, height: CellarWallView.bottleHeight)
            .background(alignment: .bottom) {
                // Contact shadow on the shelf.
                Ellipse()
                    .fill(.black.opacity(0.55))
                    .frame(width: CellarWallView.bottleHeight * 0.26, height: 7)
                    .blur(radius: 3)
                    .offset(y: 2)
            }
            .overlay(alignment: .topTrailing) {
                if bottle.quantity > 1 {
                    Text("×\(bottle.quantity)")
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Palette.burgundy, in: Capsule())
                        .offset(x: 2, y: CellarWallView.bottleHeight * 0.36)
                }
            }
    }
}

/// Raises a bottle slightly off the shelf while it's pressed.
private struct LiftButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .offset(y: configuration.isPressed ? -10 : 0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// A studio render of a bottle at real scale. Shows the flat illustration while the
/// render is prepared (first view only; renders are cached on disk).
struct BottleRender: View {
    var wine: Wine
    var height: CGFloat
    @State private var image: UIImage?

    init(wine: Wine, height: CGFloat) {
        self.wine = wine
        self.height = height
        _image = State(initialValue: BottleStudio.shared.cachedThumbnail(for: wine))
    }

    var body: some View {
        let width = height * BottleStudio.canvasAspect
        ZStack(alignment: .bottom) {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: width, height: height)
                    .transition(.opacity)
            } else {
                // The illustration is drawn to its own scale; size it like a 750 ml bottle.
                BottleArtView(wine: wine, height: height * 0.8)
                    .opacity(0.5)
                    .frame(width: width, height: height, alignment: .bottom)
            }
        }
        .frame(width: width, height: height)
        .task(id: BottleStudio.cacheKey(for: wine)) {
            guard image == nil else { return }
            let rendered = await BottleStudio.shared.thumbnail(for: wine)
            withAnimation(.easeOut(duration: 0.25)) { image = rendered }
        }
        .accessibilityHidden(true)
    }
}
