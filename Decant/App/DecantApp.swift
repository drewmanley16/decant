import SwiftUI

@main
struct DecantApp: App {
    @State private var env = AppEnvironment.live()

    init() {
        UINavigationBar.appearance().largeTitleTextAttributes = [
            .font: UIFont.systemFont(ofSize: 34, weight: .semibold).withSerifDesign(),
        ]
        UINavigationBar.appearance().titleTextAttributes = [
            .font: UIFont.systemFont(ofSize: 17, weight: .semibold).withSerifDesign(),
        ]
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(env)
                .tint(Palette.burgundy)
                .task { await env.bootstrap() }
        }
    }
}

extension UIFont {
    func withSerifDesign() -> UIFont {
        fontDescriptor.withDesign(.serif).map { UIFont(descriptor: $0, size: pointSize) } ?? self
    }
}

struct RootView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        ZStack {
            switch env.phase {
            case .launching:
                LaunchView()
            case .onboarding:
                OnboardingFlow()
                    .transition(.opacity)
            case .ready:
                MainTabView()
                    .transition(.opacity.combined(with: .scale(scale: 1.02)))
            }
        }
        .animation(.smooth(duration: 0.4), value: env.phase)
        .overlay(alignment: .top) { ToastOverlay() }
    }
}

private struct LaunchView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "wineglass.fill")
                .font(.system(size: 44))
                .foregroundStyle(Palette.burgundy)
            Text("Decant").font(Typo.title)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .screenBackground()
    }
}

private struct ToastOverlay: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        if let toast = env.toast {
            Label(toast.message, systemImage: toast.symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(Palette.charcoal.opacity(0.92), in: Capsule())
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .id(toast.id)
                .task(id: toast.id) {
                    try? await Task.sleep(for: .seconds(2.2))
                    withAnimation(.smooth) { env.toast = nil }
                }
                .accessibilityAddTraits(.isStaticText)
        }
    }
}
