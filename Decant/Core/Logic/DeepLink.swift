import Foundation

/// A link into the app: shared as https://decant-diary.vercel.app/<kind>/<id>
/// (opens the app when installed) or decant://<kind>/<id> (from notifications).
enum DeepLink: Hashable, Identifiable, Sendable {
    case entry(UUID)
    case user(UUID)
    case wine(UUID)
    case invite(String)

    static let host = "decant-diary.vercel.app"

    var id: String { path }

    init?(url: URL) {
        let parts: [String]
        switch url.scheme?.lowercased() {
        case "decant":
            // decant://t/<id>: the first segment arrives as the host.
            parts = ([url.host ?? ""] + url.pathComponents.filter { $0 != "/" }).filter { !$0.isEmpty }
        case "https", "http":
            guard url.host?.lowercased() == Self.host else { return nil }
            parts = url.pathComponents.filter { $0 != "/" }
        default:
            return nil
        }
        guard parts.count == 2 else { return nil }
        let (kind, value) = (parts[0].lowercased(), parts[1])
        switch kind {
        case "t": guard let id = UUID(uuidString: value) else { return nil }; self = .entry(id)
        case "u": guard let id = UUID(uuidString: value) else { return nil }; self = .user(id)
        case "w": guard let id = UUID(uuidString: value) else { return nil }; self = .wine(id)
        case "invite":
            let code = value.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
            guard code.count == 6 else { return nil }
            self = .invite(code)
        default: return nil
        }
    }

    private var path: String {
        switch self {
        case .entry(let id): "t/\(id.uuidString.lowercased())"
        case .user(let id): "u/\(id.uuidString.lowercased())"
        case .wine(let id): "w/\(id.uuidString.lowercased())"
        case .invite(let code): "invite/\(code)"
        }
    }

    /// The shareable web link.
    var url: URL { URL(string: "https://\(Self.host)/\(path)")! }

    var route: Route? {
        switch self {
        case .entry(let id): .entry(id)
        case .user(let id): .user(id)
        case .wine(let id): .wineID(id)
        case .invite: nil
        }
    }
}
