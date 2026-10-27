#if DEBUG
import Foundation

/// DEBUG ONLY — never compiled into release builds.
/// `-screenshotSeed` launches into a throwaway Local Mode store with a stocked
/// cellar and diary for App Store screenshots. `-tab cellar|search|profile`
/// picks the starting tab; `-inspectFirst` opens the first bottle in 3D.
enum ScreenshotSeed {
    static var isEnabled: Bool { CommandLine.arguments.contains("-screenshotSeed") }

    static func argument(_ name: String) -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    @MainActor
    static func makeEnvironment() -> AppEnvironment {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("screenshots-\(UUID()).json")
        let backend = LocalBackend(store: LocalStore(fileURL: url))
        UserDefaults.standard.set(true, forKey: "onboardingComplete")
        UserDefaults.standard.set(true, forKey: "ageAndTermsConfirmed")
        return AppEnvironment(mode: .local, auth: backend, catalog: backend, tastings: backend, social: backend,
                              cellar: backend, scans: backend, media: backend, remoteReader: nil)
    }

    static func populate(_ backend: AuthService & WineCatalogService & TastingService & CellarService) async {
        _ = try? await backend.startLocalSession(username: "drew", displayName: "Drew Manley")
        let wines = (try? await backend.catalogSample(limit: 40)) ?? []
        func wine(_ name: String) -> Wine? { wines.first { $0.name == name } }

        let tastings: [(String, Double, String?, Int)] = [
            ("Château Margaux", 5, "Violets, graphite and an endless finish. A bottle to remember.", 2),
            ("Tignanello", 4.5, "Bright cherry, cedar and spice. Gorgeous with steak.", 9),
            ("Cloudy Bay Sauvignon Blanc", 4, "Passion fruit and lime — summer in a glass.", 15),
            ("Dom Pérignon", 4.5, "Toasty, precise, beautiful mousse.", 31),
            ("Catena Malbec", 4, nil, 48),
            ("Dr. Loosen Blue Slate Riesling Kabinett", 4.5, "Off-dry and electric.", 70),
        ]
        for (name, rating, review, daysAgo) in tastings {
            guard let w = wine(name) else { continue }
            var draft = TastingDraft()
            draft.rating = rating
            draft.review = review ?? ""
            draft.isFavorite = rating >= 5
            draft.consumedOn = Calendar.current.date(byAdding: .day, value: -daysAgo, to: .now) ?? .now
            _ = try? await backend.addEntry(for: w.id, draft: draft)
        }
        let cellar = ["Château Margaux", "Opus One", "Sassicaia", "Penfolds Grange", "Tignanello", "Pio Cesare Barolo",
                      "Vega Sicilia Único", "Ridge Monte Bello", "Caymus Cabernet Sauvignon", "Louis Jadot Bourgogne Pinot Noir",
                      "Domaine Leflaive Puligny-Montrachet", "Cloudy Bay Sauvignon Blanc", "Dr. Loosen Blue Slate Riesling Kabinett",
                      "La Crema Sonoma Coast Chardonnay", "Whispering Angel", "Dom Pérignon", "Veuve Clicquot Yellow Label Brut",
                      "Moët Impérial Brut", "Château d'Yquem", "Taylor Fladgate 20 Year Old Tawny Port", "Gravner Ribolla Gialla"]
        for (i, name) in cellar.enumerated() {
            guard let w = wine(name) else { continue }
            _ = try? await backend.addBottle(wineID: w.id, draft: CellarBottleDraft(quantity: i % 5 == 0 ? 3 : 1))
        }
        var settings = (try? await backend.settings()) ?? CellarSettings()
        settings.sort = .type
        try? await backend.saveSettings(settings)
    }
}
#endif
