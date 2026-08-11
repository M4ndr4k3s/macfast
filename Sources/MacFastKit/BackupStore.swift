import Foundation

/// The value a preference key held before MacFast first touched it.
public struct DefaultsBackup: Codable, Equatable, Sendable {
    public let domain: String
    public let key: String
    public let currentHost: Bool
    /// `nil` means the key did not exist, so reverting deletes it rather than
    /// writing something back.
    public let originalValue: String?

    public init(domain: String, key: String, currentHost: Bool, originalValue: String?) {
        self.domain = domain
        self.key = key
        self.currentHost = currentHost
        self.originalValue = originalValue
    }
}

public struct TweakBackup: Codable, Equatable, Sendable {
    public let tweakId: String
    public let recordedAt: Date
    public var defaults: [DefaultsBackup]

    public init(tweakId: String, recordedAt: Date = Date(), defaults: [DefaultsBackup]) {
        self.tweakId = tweakId
        self.recordedAt = recordedAt
        self.defaults = defaults
    }
}

/// Persists the pre-change state so every tweak can be undone, even across
/// app launches. Without this, reverting could only guess at "the default",
/// which is wrong for anyone who had customised their system already.
public final class BackupStore {
    private let fileURL: URL
    private var entries: [String: TweakBackup]
    /// When false the store still reads the real backups but never writes,
    /// so a dry run cannot corrupt the record of what the system looked like.
    private let persists: Bool

    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("MacFast", isDirectory: true)
    }

    public init(
        fileURL: URL = BackupStore.defaultDirectory.appendingPathComponent("backups.json"),
        persists: Bool = true
    ) {
        self.fileURL = fileURL
        self.persists = persists
        self.entries = BackupStore.load(from: fileURL)
    }

    private static func load(from url: URL) -> [String: TweakBackup] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: TweakBackup].self, from: data)) ?? [:]
    }

    public func backup(for tweakId: String) -> TweakBackup? {
        entries[tweakId]
    }

    public func hasBackup(for tweakId: String) -> Bool {
        entries[tweakId] != nil
    }

    public func record(_ backup: TweakBackup) throws {
        entries[backup.tweakId] = backup
        try persist()
    }

    public func remove(tweakId: String) throws {
        entries.removeValue(forKey: tweakId)
        try persist()
    }

    public var trackedTweakIds: [String] {
        entries.keys.sorted()
    }

    private func persist() throws {
        guard persists else { return }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(entries).write(to: fileURL, options: .atomic)
    }
}
