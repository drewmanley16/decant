import SwiftUI
import UIKit

struct ShareImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

/// 9:16 card designed for Instagram Stories (rendered at 1080×1920).
struct ShareCardView: View {
    var wine: Wine
    var rating: Double?
    var review: String?
    var author: Profile?
    var labelImage: UIImage?

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.2, green: 0.04, blue: 0.08), Color(red: 0.08, green: 0.03, blue: 0.04)],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Palette.wineColor(wine.type).opacity(0.55), .clear], center: .center, startRadius: 20, endRadius: 420)
                .offset(y: -120)

            VStack(spacing: 28) {
                HStack(spacing: 8) {
                    Image(systemName: "wineglass.fill")
                    Text("DECANT").tracking(6)
                }
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Color(red: 0.83, green: 0.7, blue: 0.48))
                .padding(.top, 120)

                Spacer()

                BottleArtView(wine: wine, height: 640)
                    .shadow(color: .black.opacity(0.5), radius: 40, y: 30)

                VStack(spacing: 14) {
                    Text(wine.vintageLabel)
                        .font(.system(size: 30, weight: .semibold))
                        .tracking(6)
                        .foregroundStyle(Color(red: 0.83, green: 0.7, blue: 0.48))
                    Text(wine.name)
                        .font(.system(size: 64, weight: .semibold, design: .serif))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.6)
                    Text([wine.producer, wine.locationLine].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: 30))
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                    if let rating {
                        StarRatingView(rating: rating, size: 54)
                            .padding(.top, 10)
                    }
                    if let review, !review.isEmpty {
                        Text("“\(review)”")
                            .font(.system(size: 34, design: .serif).italic())
                            .foregroundStyle(.white.opacity(0.9))
                            .multilineTextAlignment(.center)
                            .lineLimit(4)
                            .padding(.top, 8)
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 90)

                Spacer()

                if let author {
                    Text("Rated by @\(author.username)")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(.white.opacity(0.65))
                        .padding(.bottom, 140)
                } else {
                    Spacer().frame(height: 140)
                }
            }
        }
        .frame(width: 1080, height: 1920)
    }
}

@MainActor
enum ShareCardRenderer {
    static func render(wine: Wine, rating: Double?, review: String? = nil, author: Profile?) async -> UIImage {
        if let path = wine.labelImagePath { _ = await ImageLoader.shared.image(for: path, maxPixel: 600) }
        let renderer = ImageRenderer(content: ShareCardView(wine: wine, rating: rating, review: review, author: author))
        renderer.scale = 1
        renderer.proposedSize = ProposedViewSize(width: 1080, height: 1920)
        return renderer.uiImage ?? LabelArtRenderer.image(for: wine)
    }
}

/// UIKit share sheet (iMessage, Instagram Stories, Save Image, etc.).
struct ActivityView: UIViewControllerRepresentable {
    var items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// Previews the share card and offers sharing.
struct ShareWineSheet: View {
    var wine: Wine
    var rating: Double?
    var review: String?
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var showActivity = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .shadow(radius: 12, y: 6)
                        .accessibilityLabel("Share card for \(wine.displayName)")
                } else {
                    ProgressView().frame(maxHeight: .infinity)
                }
                Button {
                    showActivity = true
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.primary)
                .disabled(image == nil)
            }
            .padding(Metrics.gutter)
            .screenBackground()
            .navigationTitle("Share")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .sheet(isPresented: $showActivity) {
                if let image { ActivityView(items: [image, "\(wine.displayName) on Decant"]) }
            }
            .task {
                image = await ShareCardRenderer.render(wine: wine, rating: rating, review: review, author: env.currentUser)
            }
        }
    }
}
