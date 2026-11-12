import Foundation

/// One product event: a screen reached, an action finished, or something that failed.
/// Stored in Decant's own `app_events` table; nothing goes to a third party.
struct AppEvent: Encodable, Sendable {
    var name: String
    var props: [String: String]
    var install_id: UUID
    var session_id: UUID
    var app_version: String
    var os_version: String
    var device: String
    var created_at: Date
}

/// Buffers events and sends them in small batches, so tracking never slows a screen down.
/// Failures to send are dropped silently (and never tracked, to avoid loops).
actor Telemetry {
    static let shared = Telemetry()

    typealias Sink = @Sendable ([AppEvent]) async throws -> Void

    private var sink: Sink?
    private var buffer: [AppEvent] = []
    private var flushTask: Task<Void, Never>?
    private let sessionID = UUID()
    private static let maxBuffer = 200

    /// A random id per install, so anonymous onboarding steps join up with the account later.
    nonisolated static let installID: UUID = {
        let key = "telemetryInstallID"
        if let raw = UserDefaults.standard.string(forKey: key), let id = UUID(uuidString: raw) { return id }
        let id = UUID()
        UserDefaults.standard.set(id.uuidString, forKey: key)
        return id
    }()

    private static let appVersion: String = {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }()

    private static let deviceModel: String = {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }()

    func configure(_ sink: Sink?) {
        self.sink = sink
    }

    /// Fire-and-forget from anywhere, including the main actor.
    nonisolated static func track(_ name: String, _ props: [String: String] = [:]) {
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        Task { await shared.record(name, props, osVersion: osVersion) }
    }

    private func record(_ name: String, _ props: [String: String], osVersion: String) {
        guard sink != nil else { return }
        let trimmed = props.mapValues { String($0.prefix(300)) }
        buffer.append(AppEvent(name: String(name.prefix(64)), props: trimmed, install_id: Self.installID,
                               session_id: sessionID, app_version: Self.appVersion, os_version: osVersion,
                               device: Self.deviceModel, created_at: .now))
        if buffer.count > Self.maxBuffer { buffer.removeFirst(buffer.count - Self.maxBuffer) }
        scheduleFlush(after: buffer.count >= 20 ? 0 : 8)
    }

    private func scheduleFlush(after seconds: Double) {
        if seconds > 0, flushTask != nil { return }
        flushTask?.cancel()
        flushTask = Task {
            if seconds > 0 { try? await Task.sleep(for: .seconds(seconds)) }
            guard !Task.isCancelled else { return }
            await flush()
        }
    }

    /// Sends everything buffered. Called on a timer and when the app goes to the background.
    func flush() async {
        flushTask = nil
        guard let sink, !buffer.isEmpty else { return }
        let batch = buffer
        buffer.removeAll()
        do {
            try await sink(batch)
        } catch {
            // Keep the newest events for the next try; drop the rest.
            buffer = Array((batch + buffer).suffix(Self.maxBuffer))
        }
    }
}
