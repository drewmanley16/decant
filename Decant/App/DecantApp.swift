import SwiftUI

@main
struct DecantApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var env = AppEnvironment.live()

    init() {
        let largeTitle: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 34, weight: .semibold).withSerifDesign()]
        let title: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 17, weight: .semibold).withSerifDesign()]
        // Transparent at rest; a cream bar once content scrolls underneath, so the
        // floating toolbar buttons never sit directly on top of cards.
        let scrolled = UINavigationBarAppearance()
        scrolled.configureWithDefaultBackground()
        scrolled.backgroundEffect = nil
        scrolled.backgroundColor = UIColor(Palette.cream).withAlphaComponent(0.96)
        scrolled.shadowColor = UIColor(Palette.hairline)
        scrolled.largeTitleTextAttributes = largeTitle
        scrolled.titleTextAttributes = title
        let atRest = UINavigationBarAppearance()
        atRest.configureWithTransparentBackground()
        atRest.largeTitleTextAttributes = largeTitle
        atRest.titleTextAttributes = title
        let bar = UINavigationBar.appearance()
        bar.standardAppearance = scrolled
        bar.compactAppearance = scrolled
        bar.scrollEdgeAppearance = atRest
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(env)
                .tint(Palette.burgundy)
                .task {
                    AppDelegate.environment = env
                    await env.bootstrap()
                }
                .onOpenURL { env.open($0) }
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
        .sensoryFeedback(.error, trigger: env.toast?.id) { _, _ in
            env.toast?.symbol.hasPrefix("exclamationmark") == true
        }
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
