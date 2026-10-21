import Foundation

/// User-editable settings, stored as JSON in `~/Library/Application Support/AirBar/config.json`.
///
/// Every key is optional in the file; anything missing falls back to the defaults below, so the
/// file can stay small. Set `AIRBAR_CONFIG` to use a different file.
public struct AirBarConfig: Codable, Equatable, Sendable {
    /// airCloud REST endpoint. The global server (hosted in Mumbai) serves India, Europe and most regions.
    public var apiBaseURL: String = "https://api-global-prod.aircloudhome.com/"
    /// airCloud notification websocket (STOMP), used to read unit state.
    public var notificationURL: String = "wss://notification-global-prod.aircloudhome.com/rac-notifications/websocket"
    /// The API rejects requests without an app-like User-Agent.
    public var userAgent: String = "okhttp/4.9.1"
    /// How often the menu bar app refreshes unit state, in seconds.
    public var refreshIntervalSeconds: Double = 45
    /// Taps within this window are merged into one command, in milliseconds.
    public var coalesceMilliseconds: Int = 450
    /// Pause after each accepted command before the next one is sent, in seconds.
    public var settleSeconds: Double = 1.2
    /// Show the set temperature next to the menu bar icon while a unit is running.
    public var showTemperatureInMenuBar: Bool = true
    /// Country code pre-filled for phone sign-in.
    public var defaultCountryCode: String = "91"

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AirBarConfig()
        apiBaseURL = try c.decodeIfPresent(String.self, forKey: .apiBaseURL) ?? d.apiBaseURL
        notificationURL = try c.decodeIfPresent(String.self, forKey: .notificationURL) ?? d.notificationURL
        userAgent = try c.decodeIfPresent(String.self, forKey: .userAgent) ?? d.userAgent
        refreshIntervalSeconds = try c.decodeIfPresent(Double.self, forKey: .refreshIntervalSeconds) ?? d.refreshIntervalSeconds
        coalesceMilliseconds = try c.decodeIfPresent(Int.self, forKey: .coalesceMilliseconds) ?? d.coalesceMilliseconds
        settleSeconds = try c.decodeIfPresent(Double.self, forKey: .settleSeconds) ?? d.settleSeconds
        showTemperatureInMenuBar = try c.decodeIfPresent(Bool.self, forKey: .showTemperatureInMenuBar) ?? d.showTemperatureInMenuBar
        defaultCountryCode = try c.decodeIfPresent(String.self, forKey: .defaultCountryCode) ?? d.defaultCountryCode
    }

    // MARK: Storage

    public static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("AirBar", isDirectory: true)
    }

    public static var fileURL: URL {
        if let custom = ProcessInfo.processInfo.environment["AIRBAR_CONFIG"], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        }
        return directory.appendingPathComponent("config.json")
    }

    /// Loads the config, writing a file with the defaults on first run so it's easy to find and edit.
    public static func load() -> AirBarConfig {
        let url = fileURL
        if let data = try? Data(contentsOf: url), let cfg = try? JSONDecoder().decode(AirBarConfig.self, from: data) {
            return cfg
        }
        let cfg = AirBarConfig()
        try? cfg.save()
        return cfg
    }

    public func save() throws {
        let url = Self.fileURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: url, options: .atomic)
    }
}
