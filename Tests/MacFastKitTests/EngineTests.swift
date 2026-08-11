import XCTest
@testable import MacFastKit

/// Records every command and replays canned output, so the engine can be
/// exercised without changing the machine running the tests.
final class FakeRunner: CommandRunner {
    var commands: [[String]] = []
    var privilegedCommands: [[String]] = []
    /// Keyed by the joined argument list.
    var responses: [String: CommandResult] = [:]

    func stub(_ arguments: [String], output: String, status: Int32 = 0) {
        responses[arguments.joined(separator: " ")] =
            CommandResult(status: status, standardOutput: output, standardError: "")
    }

    func run(_ arguments: [String]) throws -> CommandResult {
        commands.append(arguments)
        if let stubbed = responses[arguments.joined(separator: " ")] {
            return stubbed
        }
        // An unstubbed `defaults read` fails, which is exactly how the real
        // tool reports a key that is not set. Everything else (writes,
        // deletes) succeeds, so failures in tests are always deliberate.
        let isRead = arguments.first?.hasSuffix("defaults") == true && arguments.contains("read")
        return isRead
            ? CommandResult(status: 1, standardOutput: "", standardError: "does not exist")
            : CommandResult(status: 0, standardOutput: "", standardError: "")
    }

    func runPrivileged(_ arguments: [String]) throws -> CommandResult {
        privilegedCommands.append(arguments)
        return CommandResult(status: 0, standardOutput: "", standardError: "")
    }
}

final class EngineTests: XCTestCase {
    private var backupURL: URL!
    private var runner: FakeRunner!
    private var engine: TweakEngine!

    override func setUpWithError() throws {
        backupURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macfast-tests-\(UUID().uuidString)")
            .appendingPathComponent("backups.json")
        runner = FakeRunner()
        engine = TweakEngine(runner: runner, backups: BackupStore(fileURL: backupURL))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: backupURL.deletingLastPathComponent())
    }

    private let sample = Tweak(
        id: "test-tweak",
        title: "Teste",
        summary: "resumo",
        tradeoff: "nada",
        category: .animations,
        risk: .safe,
        actions: [.defaultsWrite(domain: "com.example.app", key: "Flag", value: .bool(true))]
    )

    // MARK: - Value normalisation

    func testBooleanAndNumericTextsNormaliseToTheSameForm() {
        XCTAssertEqual(PrefValue.normalizeNumericText("true"), "1")
        XCTAssertEqual(PrefValue.normalizeNumericText("YES"), "1")
        XCTAssertEqual(PrefValue.normalizeNumericText("0"), "0")
        XCTAssertEqual(PrefValue.normalizeNumericText("1.0"), "1")
        XCTAssertEqual(PrefValue.normalizeNumericText(" 1 "), "1")
        XCTAssertEqual(PrefValue.bool(true).normalizedText, "1")
        XCTAssertEqual(PrefValue.int(3).normalizedText, "3")
        XCTAssertEqual(PrefValue.string("abc").normalizedText, "abc")
    }

    func testDoubleValuesSurviveNormalisation() {
        XCTAssertEqual(PrefValue.double(0.001).normalizedText,
                       PrefValue.normalizeNumericText("0.0010"))
    }

    // MARK: - State detection

    func testStateIsAppliedWhenStoredValueMatches() {
        runner.stub(["/usr/bin/defaults", "read", "com.example.app", "Flag"], output: "1\n")
        XCTAssertEqual(engine.state(of: sample), .applied)
    }

    func testMissingKeyCountsAsNotApplied() {
        // Nothing stubbed, so `defaults read` fails the way it does for an
        // unset key.
        XCTAssertEqual(engine.state(of: sample), .notApplied)
    }

    func testPartialStateWhenOnlyOneActionMatches() {
        let twoActions = Tweak(
            id: "two", title: "t", summary: "s", tradeoff: "x",
            category: .animations, risk: .safe,
            actions: [
                .defaultsWrite(domain: "com.example.app", key: "A", value: .bool(true)),
                .defaultsWrite(domain: "com.example.app", key: "B", value: .bool(true)),
            ]
        )
        runner.stub(["/usr/bin/defaults", "read", "com.example.app", "A"], output: "1")
        runner.stub(["/usr/bin/defaults", "read", "com.example.app", "B"], output: "0")
        XCTAssertEqual(engine.state(of: twoActions), .partial)
    }

    func testCommandStateIsUnknownWithoutAProbe() {
        let tweak = Tweak(
            id: "cmd", title: "t", summary: "s", tradeoff: "x",
            category: .power, risk: .safe,
            actions: [.command(apply: ["/bin/true"], revert: ["/bin/true"],
                               probe: nil, appliedOutput: nil)]
        )
        XCTAssertEqual(engine.state(of: tweak), .unknown)
    }

    // MARK: - Apply and revert

    func testApplyWritesTheOptimisedValue() throws {
        try engine.apply(sample)
        XCTAssertTrue(runner.commands.contains(
            ["/usr/bin/defaults", "write", "com.example.app", "Flag", "-bool", "true"]
        ))
    }

    func testRevertRestoresTheOriginalValueThatWasThereBefore() throws {
        runner.stub(["/usr/bin/defaults", "read", "com.example.app", "Flag"], output: "0")
        try engine.apply(sample)
        try engine.revert(sample)

        XCTAssertTrue(runner.commands.contains(
            ["/usr/bin/defaults", "write", "com.example.app", "Flag", "-int", "0"]
        ), "o valor original do usuário deve voltar, não um padrão inventado")
    }

    func testRevertDeletesKeyThatDidNotExistBefore() throws {
        try engine.apply(sample)
        try engine.revert(sample)
        XCTAssertTrue(runner.commands.contains(
            ["/usr/bin/defaults", "delete", "com.example.app", "Flag"]
        ))
    }

    /// Re-applying must not overwrite the recorded original with MacFast's own
    /// value, otherwise the undo becomes a no-op.
    func testReapplyingKeepsTheFirstBackup() throws {
        runner.stub(["/usr/bin/defaults", "read", "com.example.app", "Flag"], output: "0")
        try engine.apply(sample)
        runner.stub(["/usr/bin/defaults", "read", "com.example.app", "Flag"], output: "1")
        try engine.apply(sample)
        try engine.revert(sample)

        XCTAssertTrue(runner.commands.contains(
            ["/usr/bin/defaults", "write", "com.example.app", "Flag", "-int", "0"]
        ))
    }

    func testCurrentHostActionsUseTheCurrentHostFlag() throws {
        let tweak = Tweak(
            id: "byhost", title: "t", summary: "s", tradeoff: "x",
            category: .network, risk: .safe,
            actions: [.defaultsWrite(domain: "com.example.app", key: "K",
                                     value: .bool(false), currentHost: true)]
        )
        try engine.apply(tweak)
        XCTAssertTrue(runner.commands.contains(
            ["/usr/bin/defaults", "-currentHost", "write", "com.example.app", "K", "-bool", "false"]
        ))
    }

    func testRootCommandsGoThroughThePrivilegedPath() throws {
        let tweak = Tweak(
            id: "root", title: "t", summary: "s", tradeoff: "x",
            category: .power, risk: .advanced,
            actions: [.command(apply: ["/usr/bin/sudo", "/usr/bin/pmset", "-a", "powernap", "0"],
                               revert: ["/usr/bin/sudo", "/usr/bin/pmset", "-a", "powernap", "1"],
                               probe: nil, appliedOutput: nil)]
        )
        try engine.apply(tweak)
        XCTAssertEqual(runner.privilegedCommands.count, 1)
    }

    func testApplyReportSeparatesFailuresFromSuccesses() {
        let failing = Tweak(
            id: "fails", title: "t", summary: "s", tradeoff: "x",
            category: .power, risk: .safe,
            actions: [.command(apply: ["/bin/false"], revert: ["/bin/true"],
                               probe: nil, appliedOutput: nil)]
        )
        runner.stub(["/bin/false"], output: "", status: 1)
        let report = engine.apply([sample, failing])
        XCTAssertEqual(report.applied.map(\.id), ["test-tweak"])
        XCTAssertEqual(report.failed.map(\.tweak.id), ["fails"])
        XCTAssertTrue(report.hasFailures)
    }

    func testBackupsSurviveAcrossEngineInstances() throws {
        runner.stub(["/usr/bin/defaults", "read", "com.example.app", "Flag"], output: "7")
        try engine.apply(sample)

        let secondRunner = FakeRunner()
        let secondEngine = TweakEngine(runner: secondRunner,
                                       backups: BackupStore(fileURL: backupURL))
        XCTAssertEqual(secondEngine.trackedTweakIds, ["test-tweak"])
        try secondEngine.revert(sample)
        XCTAssertTrue(secondRunner.commands.contains(
            ["/usr/bin/defaults", "write", "com.example.app", "Flag", "-int", "7"]
        ))
    }

    /// A dry run must leave the record of the original system untouched,
    /// otherwise `--dry-run apply` would poison a later real revert.
    func testNonPersistingStoreDoesNotTouchTheBackupFile() throws {
        runner.stub(["/usr/bin/defaults", "read", "com.example.app", "Flag"], output: "42")
        try engine.apply(sample)

        let dryEngine = TweakEngine(runner: DryRunCommandRunner { _ in },
                                    backups: BackupStore(fileURL: backupURL, persists: false))
        try dryEngine.revert(sample)

        // The real store still knows the original value.
        let reloaded = TweakEngine(runner: runner, backups: BackupStore(fileURL: backupURL))
        XCTAssertEqual(reloaded.trackedTweakIds, ["test-tweak"])
    }

    // MARK: - Quoting

    func testShellQuotingHandlesEmbeddedQuotes() {
        XCTAssertEqual(Shell.shellQuote("it's"), "'it'\\''s'")
        XCTAssertEqual(Shell.shellCommand(["/bin/echo", "a b"]), "'/bin/echo' 'a b'")
    }

    func testAppleScriptQuotingEscapesBackslashesBeforeQuotes() {
        XCTAssertEqual(Shell.appleScriptQuote(#"a\b"#), #""a\\b""#)
        XCTAssertEqual(Shell.appleScriptQuote(#"say "hi""#), #""say \"hi\"""#)
    }

    func testSudoDetectionAndStripping() {
        XCTAssertTrue(Shell.isPrivileged(["/usr/bin/sudo", "pmset"]))
        XCTAssertFalse(Shell.isPrivileged(["/usr/bin/pmset"]))
        XCTAssertEqual(Shell.strippingSudo(["/usr/bin/sudo", "pmset"]), ["pmset"])
        XCTAssertEqual(Shell.strippingSudo(["/usr/bin/pmset"]), ["/usr/bin/pmset"])
    }

    func testRestoreArgumentsPreserveValueShape() {
        XCTAssertEqual(TweakEngine.restoreArguments(for: "5"), ["-int", "5"])
        XCTAssertEqual(TweakEngine.restoreArguments(for: "0.5"), ["-float", "0.5"])
        XCTAssertEqual(TweakEngine.restoreArguments(for: "hello"), ["-string", "hello"])
    }
}
