import Foundation

/// A preference value that can be written with `defaults` and compared against
/// whatever is currently stored on disk.
public enum PrefValue: Equatable, Codable, Sendable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)

    /// Arguments for `defaults write <domain> <key> ...`
    var defaultsWriteArguments: [String] {
        switch self {
        case .bool(let value): return ["-bool", value ? "true" : "false"]
        case .int(let value): return ["-int", String(value)]
        case .double(let value): return ["-float", String(value)]
        case .string(let value): return ["-string", value]
        }
    }

    /// `defaults read` prints untyped scalars, so comparison happens on the
    /// normalised textual form rather than on the typed value.
    var normalizedText: String {
        switch self {
        case .bool(let value): return value ? "1" : "0"
        case .int(let value): return String(value)
        case .double(let value): return PrefValue.normalizeNumericText(String(value))
        case .string(let value): return value
        }
    }

    static func normalizeNumericText(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmed.lowercased() {
        case "true", "yes": return "1"
        case "false", "no": return "0"
        default: break
        }
        guard let number = Double(trimmed) else { return trimmed }
        // 0.001 and "0.0010" must compare equal; 1 and 1.0 too.
        if number == number.rounded(), abs(number) < 1e15 {
            return String(Int(number))
        }
        return String(format: "%g", number)
    }
}

/// One reversible change. A tweak is a list of these.
public enum Action: Equatable, Codable, Sendable {
    /// Write a value into a user (or host-wide) preference domain.
    case defaultsWrite(domain: String, key: String, value: PrefValue, currentHost: Bool = false)

    /// Run a shell command to apply, and another to undo it.
    ///
    /// `probe` is expected to print the state on stdout; the action counts as
    /// applied when the trimmed output equals `appliedOutput`.
    case command(apply: [String], revert: [String], probe: [String]?, appliedOutput: String?)

    var requiresRoot: Bool {
        switch self {
        case .defaultsWrite:
            return false
        case .command(let apply, _, _, _):
            return apply.first.map { $0.hasPrefix("/usr/bin/sudo") || $0 == "sudo" } ?? false
        }
    }
}

/// The range of macOS releases a tweak actually does something on, expressed
/// as major versions (11 = Big Sur … 26 = Tahoe).
///
/// This matters because a `defaults write` for a key the running system does
/// not know succeeds silently. Without a range, such a tweak would report
/// itself as applied while changing nothing.
public struct OSRange: Equatable, Codable, Sendable {
    /// Oldest release where the tweak works. `nil` means "as far back as the
    /// app supports".
    public let minimumMajor: Int?
    /// Newest release where it still works, inclusive. `nil` means "still
    /// current".
    public let maximumMajor: Int?

    public init(minimumMajor: Int? = nil, maximumMajor: Int? = nil) {
        self.minimumMajor = minimumMajor
        self.maximumMajor = maximumMajor
    }

    public static let any = OSRange()

    public static func from(_ major: Int) -> OSRange { OSRange(minimumMajor: major) }
    public static func upTo(_ major: Int) -> OSRange { OSRange(maximumMajor: major) }

    public func contains(major: Int) -> Bool {
        if let minimumMajor, major < minimumMajor { return false }
        if let maximumMajor, major > maximumMajor { return false }
        return true
    }

    public var isUniversal: Bool { minimumMajor == nil && maximumMajor == nil }

    /// Marketing names, so the UI can say "Ventura" instead of "13".
    public static func releaseName(for major: Int) -> String? {
        switch major {
        case 11: return "Big Sur"
        case 12: return "Monterey"
        case 13: return "Ventura"
        case 14: return "Sonoma"
        case 15: return "Sequoia"
        case 26: return "Tahoe"
        default: return nil
        }
    }

    private static func label(_ major: Int) -> String {
        if let name = releaseName(for: major) { return "macOS \(major) \(name)" }
        return "macOS \(major)"
    }

    public var localizedName: String {
        switch (minimumMajor, maximumMajor) {
        case (nil, nil):
            return "Qualquer versão"
        case (let minimum?, nil):
            return "\(OSRange.label(minimum)) ou mais recente"
        case (nil, let maximum?):
            return "Até o \(OSRange.label(maximum))"
        case (let minimum?, let maximum?) where minimum == maximum:
            return "Só no \(OSRange.label(minimum))"
        case (let minimum?, let maximum?):
            return "Do \(OSRange.label(minimum)) ao \(OSRange.label(maximum))"
        }
    }

    /// Short form for badges and list columns.
    public var shortName: String {
        switch (minimumMajor, maximumMajor) {
        case (nil, nil): return ""
        case (let minimum?, nil): return "macOS \(minimum)+"
        case (nil, let maximum?): return "≤ macOS \(maximum)"
        case (let minimum?, let maximum?) where minimum == maximum: return "macOS \(minimum)"
        case (let minimum?, let maximum?): return "macOS \(minimum)–\(maximum)"
        }
    }
}

public enum Risk: String, Codable, Sendable, CaseIterable {
    /// Cosmetic or trivially reversible; nothing stops working.
    case safe
    /// A user-visible feature actually goes away (that is the point).
    case moderate
    /// Reboot or logout required, or a background service is stopped.
    case advanced

    public var localizedName: String {
        switch self {
        case .safe: return "Seguro"
        case .moderate: return "Moderado"
        case .advanced: return "Avançado"
        }
    }
}

public enum Category: String, Codable, Sendable, CaseIterable {
    case interface
    case animations
    case indexing
    case background
    case power
    case network
    case privacy
    case notifications
    case battery
    case trackpad

    public var localizedName: String {
        switch self {
        case .interface: return "Interface"
        case .animations: return "Animações"
        case .indexing: return "Indexação e busca"
        case .background: return "Serviços em segundo plano"
        case .power: return "Energia e disco"
        case .network: return "Rede e sincronização"
        case .privacy: return "Privacidade"
        case .notifications: return "Notificações e alertas"
        case .battery: return "Bateria"
        case .trackpad: return "Trackpad e teclado"
        }
    }
}

/// What the user has to do before the change is fully visible.
public enum ApplyEffect: String, Codable, Sendable {
    case immediate
    case restartsDock
    case restartsFinder
    case needsLogout
    case needsReboot

    public var localizedName: String {
        switch self {
        case .immediate: return "Efeito imediato"
        case .restartsDock: return "Reinicia o Dock"
        case .restartsFinder: return "Reinicia o Finder"
        case .needsLogout: return "Requer novo login"
        case .needsReboot: return "Requer reinicialização"
        }
    }
}

public struct Tweak: Identifiable, Equatable, Codable, Sendable {
    public let id: String
    public let title: String
    public let summary: String
    /// What the user loses by enabling this. Never empty — every tweak trades
    /// something away, and the UI shows this next to the switch.
    public let tradeoff: String
    public let category: Category
    public let risk: Risk
    public let effect: ApplyEffect
    /// Tweaks that pay off the most on Macs running via OpenCore Legacy Patcher
    /// (no native Metal driver support, spinning disks, low RAM).
    public let recommendedForOCLP: Bool
    /// Releases where this tweak actually has an effect.
    public let availability: OSRange
    public let actions: [Action]

    public var requiresRoot: Bool { actions.contains { $0.requiresRoot } }

    public func isAvailable(onMajor major: Int) -> Bool {
        availability.contains(major: major)
    }

    public init(
        id: String,
        title: String,
        summary: String,
        tradeoff: String,
        category: Category,
        risk: Risk,
        effect: ApplyEffect = .immediate,
        recommendedForOCLP: Bool = false,
        availability: OSRange = .any,
        actions: [Action]
    ) {
        self.availability = availability
        self.id = id
        self.title = title
        self.summary = summary
        self.tradeoff = tradeoff
        self.category = category
        self.risk = risk
        self.effect = effect
        self.recommendedForOCLP = recommendedForOCLP
        self.actions = actions
    }
}

public enum TweakState: String, Codable, Sendable {
    /// Every action is in its optimised state.
    case applied
    /// No action is in its optimised state.
    case notApplied
    /// Some are, some are not — usually a half-finished apply or a manual edit.
    case partial
    /// The state could not be read (probe failed, no permission).
    case unknown
    /// This macOS release does not have the feature the tweak turns off.
    case unavailable

    public var localizedName: String {
        switch self {
        case .applied: return "Ativado"
        case .notApplied: return "Desativado"
        case .partial: return "Parcial"
        case .unknown: return "Desconhecido"
        case .unavailable: return "Indisponível nesta versão"
        }
    }
}
