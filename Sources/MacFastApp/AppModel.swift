import Foundation
import MacFastKit

/// Not actor-isolated on purpose: the engine shells out synchronously, so the
/// work happens on `work` and every publish is hopped back to the main queue.
final class AppModel: ObservableObject {
    @Published private(set) var states: [String: TweakState] = [:]
    @Published private(set) var systemInfo: SystemInfo?
    @Published private(set) var isBusy = false
    @Published var statusMessage: String?
    @Published var errorMessage: String?

    /// The GUI elevates through the AppleScript prompt rather than sudo.
    private let engine = TweakEngine(runner: SystemCommandRunner(promptName: "MacFast"))
    private let work = DispatchQueue(label: "app.macfast.engine", qos: .userInitiated)

    let groups = TweakCatalog.grouped()
    let osMajor = ProcessInfo.processInfo.operatingSystemVersion.majorVersion

    func state(of tweak: Tweak) -> TweakState {
        states[tweak.id] ?? .unknown
    }

    /// Presets never offer tweaks this release cannot do anything with.
    func tweaks(for preset: Preset) -> [Tweak] {
        preset.tweaks(availableOn: osMajor)
    }

    func load() {
        let info = SystemInfo.current()
        systemInfo = info
        refresh()
    }

    func refresh() {
        run { engine in
            var fresh: [String: TweakState] = [:]
            for tweak in TweakCatalog.all {
                fresh[tweak.id] = engine.state(of: tweak)
            }
            return .init(states: fresh, message: nil, error: nil)
        }
    }

    func toggle(_ tweak: Tweak) {
        let shouldApply = state(of: tweak) != .applied
        apply(shouldApply ? [tweak] : [], reverting: shouldApply ? [] : [tweak])
    }

    func apply(preset: Preset) {
        apply(tweaks(for: preset), reverting: [])
    }

    func revertEverything() {
        let tracked = engine.trackedTweakIds.compactMap { TweakCatalog.tweak(id: $0) }
        guard !tracked.isEmpty else {
            statusMessage = "Nada a reverter — o MacFast não aplicou nenhum ajuste ainda."
            return
        }
        apply([], reverting: tracked)
    }

    private func apply(_ toApply: [Tweak], reverting toRevert: [Tweak]) {
        run { engine in
            var effects: Set<ApplyEffect> = []
            var notes: [String] = []
            var failures: [String] = []

            for report in [
                toApply.isEmpty ? nil : engine.apply(toApply),
                toRevert.isEmpty ? nil : engine.revert(toRevert),
            ].compactMap({ $0 }) {
                effects.formUnion(report.effects)
                // Applying and reverting in one batch can raise the same note
                // twice.
                notes += report.localizedNotes.filter { !notes.contains($0) }
                if let message = report.localizedFailureMessage { failures.append(message) }
            }

            // Restart Dock/Finder once for the whole batch.
            engine.settle(effects: effects)

            var fresh: [String: TweakState] = [:]
            for tweak in TweakCatalog.all {
                fresh[tweak.id] = engine.state(of: tweak)
            }

            return .init(
                states: fresh,
                message: notes.isEmpty ? nil : notes.joined(separator: " "),
                error: failures.isEmpty ? nil : failures.joined(separator: "\n")
            )
        }
    }

    private struct Outcome {
        let states: [String: TweakState]
        let message: String?
        let error: String?
    }

    private func run(_ body: @escaping (TweakEngine) -> Outcome) {
        guard !isBusy else { return }
        isBusy = true
        statusMessage = nil
        errorMessage = nil

        let engine = self.engine
        work.async {
            let outcome = body(engine)
            DispatchQueue.main.async {
                self.states = outcome.states
                self.statusMessage = outcome.message
                self.errorMessage = outcome.error
                self.isBusy = false
            }
        }
    }
}
