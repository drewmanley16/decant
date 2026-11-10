#if DEBUG
import UIKit

/// Development aid: launch with `-renderBottleProbe` to write a contact sheet of
/// studio renders to the app's tmp folder.
enum BottleRenderProbe {
    @MainActor static func runIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains("-renderBottleProbe") else { return }
        let wines = SeedCatalog.load()
        var picks: [Wine] = []
        for type in WineType.allCases { picks += wines.filter { $0.type == type }.prefix(2) }
        var images: [UIImage] = []
        for wine in picks.prefix(10) {
            if let image = await BottleStudio.shared.thumbnail(for: wine) { images.append(image) }
        }
        guard let first = images.first else { print("PROBE: no renders"); return }
        let cell = first.size
        let sheet = UIGraphicsImageRenderer(size: CGSize(width: cell.width * CGFloat(images.count), height: cell.height)).image { ctx in
            UIColor(red: 0.09, green: 0.07, blue: 0.06, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: CGSize(width: cell.width * CGFloat(images.count), height: cell.height)))
            for (i, image) in images.enumerated() { image.draw(at: CGPoint(x: cell.width * CGFloat(i), y: 0)) }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bottle-probe.png")
        try? sheet.pngData()?.write(to: url)
        print("PROBE: \(images.count) renders -> \(url.path)")
    }
}
#endif
