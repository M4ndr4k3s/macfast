import Foundation

public struct TweakFailure {
    public let tweak: Tweak
    public let error: Error

    public var reason: String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

public struct ApplyReport {
    public let applied: [Tweak]
    public let failed: [TweakFailure]
    /// Union of every applied tweak's effect, so the caller restarts the Dock
    /// once at the end instead of after each individual change.
    public let effects: Set<ApplyEffect>

    public var hasFailures: Bool { !failed.isEmpty }

    /// What the user still has to do for the batch to take full effect.
    /// Lives here, rather than in the UI, so the app and the CLI say the same
    /// thing and the wording can be tested.
    public var localizedNotes: [String] {
        var notes: [String] = []
        if effects.contains(.needsLogout) {
            notes.append("Saia da conta e entre novamente para os ajustes valerem por completo.")
        }
        if effects.contains(.needsReboot) {
            notes.append("Reinicie o Mac para os ajustes valerem por completo.")
        }
        return notes
    }

    /// One message per failed tweak, or `nil` when everything worked.
    public var localizedFailureMessage: String? {
        guard !failed.isEmpty else { return nil }
        return failed.map { "\($0.tweak.title): \($0.reason)" }.joined(separator: "\n")
    }
}

public final class TweakEngine {
    private let runner: CommandRunner
    private let backups: BackupStore
    private let osMajor: Int

    private static let defaultsTool = "/usr/bin/defaults"

    public init(
        runner: CommandRunner = SystemCommandRunner(),
        backups: BackupStore = BackupStore(),
        osMajor: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    ) {
        self.runner = runner
        self.backups = backups
        self.osMajor = osMajor
    }

    // MARK: - Reading state

    public func state(of tweak: Tweak) -> TweakState {
        // Checked before touching the system: a `defaults write` for a key this
        // release does not know would otherwise look like a success.
        guard tweak.isAvailable(onMajor: osMajor) else { return .unavailable }

        var appliedCount = 0
        var knownCount = 0

        for action in tweak.actions {
            switch actionState(action) {
            case .applied:
                appliedCount += 1
                knownCount += 1
            case .notApplied:
                knownCount += 1
            // `actionState` never returns these two, but they keep the switch
            // exhaustive: an unreadable action simply does not vote.
            case .unknown, .partial, .unavailable:
                break
            }
        }

        guard knownCount > 0 else { return .unknown }
        if appliedCount == tweak.actions.count { return .applied }
        if appliedCount == 0 { return .notApplied }
        return .partial
    }

    private func actionState(_ action: Action) -> TweakState {
        switch action {
        case .defaultsWrite(let domain, let key, let value, let currentHost):
            guard let current = readDefault(domain: domain, key: key, currentHost: currentHost) else {
                // A missing key means the system default is in effect, which is
                // by definition not the optimised value.
                return .notApplied
            }
            let currentNormalized = PrefValue.normalizeNumericText(current)
            return currentNormalized == value.normalizedText ? .applied : .notApplied

        case .command(_, _, let probe, let appliedOutput):
            guard let probe, let appliedOutput,
                  let result = try? runner.run(probe), result.succeeded else {
                return .unknown
            }
            return result.trimmedOutput == appliedOutput ? .applied : .notApplied
        }
    }

    /// Returns the raw textual value, or `nil` when the key is not set.
    private func readDefault(domain: String, key: String, currentHost: Bool) -> String? {
        var arguments = [TweakEngine.defaultsTool]
        if currentHost { arguments.append("-currentHost") }
        arguments += ["read", domain, key]

        guard let result = try? runner.run(arguments), result.succeeded else { return nil }
        return result.trimmedOutput
    }

    // MARK: - Applying

    @discardableResult
    public func apply(_ tweaks: [Tweak]) -> ApplyReport {
        var applied: [Tweak] = []
        var failed: [TweakFailure] = []
        var effects: Set<ApplyEffect> = []

        for tweak in tweaks {
            do {
                try apply(tweak)
                applied.append(tweak)
                effects.insert(tweak.effect)
            } catch {
                failed.append(TweakFailure(tweak: tweak, error: error))
            }
        }

        return ApplyReport(applied: applied, failed: failed, effects: effects)
    }

    public func apply(_ tweak: Tweak) throws {
        guard tweak.isAvailable(onMajor: osMajor) else {
            throw MacFastError.unavailableOnThisOS(
                title: tweak.title, requirement: tweak.availability.localizedName)
        }

        // Capture the original state once, before the first change. Re-applying
        // must not overwrite a backup with MacFast's own values.
        if !backups.hasBackup(for: tweak.id) {
            var records: [DefaultsBackup] = []
            for action in tweak.actions {
                if case .defaultsWrite(let domain, let key, _, let currentHost) = action {
                    records.append(DefaultsBackup(
                        domain: domain,
                        key: key,
                        currentHost: currentHost,
                        originalValue: readDefault(domain: domain, key: key, currentHost: currentHost)
                    ))
                }
            }
            try backups.record(TweakBackup(tweakId: tweak.id, defaults: records))
        }

        for action in tweak.actions {
            switch action {
            case .defaultsWrite(let domain, let key, let value, let currentHost):
                var arguments = [TweakEngine.defaultsTool]
                if currentHost { arguments.append("-currentHost") }
                arguments += ["write", domain, key] + value.defaultsWriteArguments
                try execute(arguments)

            case .command(let apply, _, _, _):
                try execute(apply)
            }
        }
    }

    // MARK: - Reverting

    @discardableResult
    public func revert(_ tweaks: [Tweak]) -> ApplyReport {
        var reverted: [Tweak] = []
        var failed: [TweakFailure] = []
        var effects: Set<ApplyEffect> = []

        for tweak in tweaks {
            do {
                try revert(tweak)
                reverted.append(tweak)
                effects.insert(tweak.effect)
            } catch {
                failed.append(TweakFailure(tweak: tweak, error: error))
            }
        }

        return ApplyReport(applied: reverted, failed: failed, effects: effects)
    }

    public func revert(_ tweak: Tweak) throws {
        let backup = backups.backup(for: tweak.id)

        for action in tweak.actions {
            switch action {
            case .defaultsWrite(let domain, let key, _, let currentHost):
                let record = backup?.defaults.first {
                    $0.domain == domain && $0.key == key && $0.currentHost == currentHost
                }

                var arguments = [TweakEngine.defaultsTool]
                if currentHost { arguments.append("-currentHost") }

                if let original = record?.originalValue {
                    // The original type is not recorded, so restore as a string
                    // for text and let numeric-looking values go back as numbers.
                    arguments += ["write", domain, key] + Self.restoreArguments(for: original)
                } else {
                    // Either there was no backup at all, or the key was absent
                    // before. Both revert to "not set", which is what macOS
                    // itself falls back to.
                    arguments += ["delete", domain, key]
                }
                // Deleting a key that is already gone exits non-zero; that is
                // still the state we wanted, so it is not an error.
                _ = try? runner.runAutoElevating(arguments)

            case .command(_, let revert, _, _):
                try execute(revert)
            }
        }

        try backups.remove(tweakId: tweak.id)
    }

    static func restoreArguments(for original: String) -> [String] {
        if let intValue = Int(original) {
            return ["-int", String(intValue)]
        }
        if let doubleValue = Double(original) {
            return ["-float", String(doubleValue)]
        }
        return ["-string", original]
    }

    private func execute(_ arguments: [String]) throws {
        let result = try runner.runAutoElevating(arguments)
        guard result.succeeded else {
            throw MacFastError.commandFailed(command: arguments, result: result)
        }
    }

    // MARK: - Post-apply housekeeping

    /// Restarts the UI processes needed to make the applied changes visible.
    /// Called once per batch.
    public func settle(effects: Set<ApplyEffect>) {
        if effects.contains(.restartsDock) {
            _ = try? runner.run(["/usr/bin/killall", "Dock"])
        }
        if effects.contains(.restartsFinder) {
            _ = try? runner.run(["/usr/bin/killall", "Finder"])
        }
    }

    public var trackedTweakIds: [String] { backups.trackedTweakIds }
}
