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
        // `-probeNames "A|B|C"` picks specific catalog wines; `-probeHeight N` sets render size.
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-probeNames"), i + 1 < args.count {
            let names = args[i + 1].split(separator: "|").map(String.init)
            picks = names.compactMap { name in wines.first { $0.name == name } }
        }
        var height = 720
        if let i = args.firstIndex(of: "-probeHeight"), i + 1 < args.count, let h = Int(args[i + 1]) { height = h }
        for (index, wine) in picks.prefix(12).enumerated() {
            let image = height == 720 ? await BottleStudio.shared.thumbnail(for: wine)
                                      : await BottleStudio.shared.render(wine: wine, pixelHeight: height)
            if let image {
                images.append(image)
                try? image.pngData()?.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("bottle-\(index).png"))
            }
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
