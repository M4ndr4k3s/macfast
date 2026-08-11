import Foundation

public struct CommandResult: Equatable, Sendable {
    public let status: Int32
    public let standardOutput: String
    public let standardError: String

    public var succeeded: Bool { status == 0 }
    public var trimmedOutput: String {
        standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public init(status: Int32, standardOutput: String, standardError: String) {
        self.status = status
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

public enum MacFastError: LocalizedError {
    case emptyCommand
    case commandFailed(command: [String], result: CommandResult)
    case authorizationCancelled
    case unavailableOnThisOS(title: String, requirement: String)

    public var errorDescription: String? {
        switch self {
        case .emptyCommand:
            return "Comando vazio."
        case .commandFailed(let command, let result):
            let detail = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            return "Falha ao executar `\(command.joined(separator: " "))` (código \(result.status))."
                + (detail.isEmpty ? "" : " \(detail)")
        case .authorizationCancelled:
            return "Autorização de administrador cancelada."
        case .unavailableOnThisOS(let title, let requirement):
            return "“\(title)” não existe nesta versão do macOS (requer \(requirement))."
        }
    }
}

public protocol CommandRunner {
    /// Runs a command as the current user.
    func run(_ arguments: [String]) throws -> CommandResult
    /// Runs a command as root, prompting the user for credentials.
    func runPrivileged(_ arguments: [String]) throws -> CommandResult
}

extension CommandRunner {
    /// Picks the privileged or unprivileged path based on the command itself,
    /// so callers do not have to inspect the argument list.
    func runAutoElevating(_ arguments: [String]) throws -> CommandResult {
        Shell.isPrivileged(arguments) ? try runPrivileged(arguments) : try run(arguments)
    }
}

public enum Shell {
    /// Catalog entries mark root commands by prefixing them with sudo. The
    /// GUI strips that prefix and elevates via AppleScript instead; the CLI
    /// leaves it in place and lets sudo do the work.
    public static func isPrivileged(_ arguments: [String]) -> Bool {
        guard let first = arguments.first else { return false }
        return first == "sudo" || first == "/usr/bin/sudo"
    }

    public static func strippingSudo(_ arguments: [String]) -> [String] {
        isPrivileged(arguments) ? Array(arguments.dropFirst()) : arguments
    }

    /// Wraps an argument so the shell treats it as a single literal token.
    public static func shellQuote(_ argument: String) -> String {
        "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func shellCommand(_ arguments: [String]) -> String {
        arguments.map(shellQuote).joined(separator: " ")
    }

    /// Escapes a string for use inside an AppleScript double-quoted literal.
    /// Backslashes must be doubled before quotes are escaped, otherwise the
    /// escape characters introduced here would be escaped again.
    public static func appleScriptQuote(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"" + escaped + "\""
    }
}

public struct SystemCommandRunner: CommandRunner {
    /// Label shown in the macOS authentication dialog.
    private let promptName: String

    public init(promptName: String = "MacFast") {
        self.promptName = promptName
    }

    public func run(_ arguments: [String]) throws -> CommandResult {
        guard let executable = arguments.first else { throw MacFastError.emptyCommand }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(arguments.dropFirst())

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()

        // Read before waiting: a command producing more output than the pipe
        // buffer holds would otherwise block forever.
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return CommandResult(
            status: process.terminationStatus,
            standardOutput: String(data: outData, encoding: .utf8) ?? "",
            standardError: String(data: errData, encoding: .utf8) ?? ""
        )
    }

    public func runPrivileged(_ arguments: [String]) throws -> CommandResult {
        let command = Shell.shellCommand(Shell.strippingSudo(arguments))
        let script = "do shell script \(Shell.appleScriptQuote(command))"
            + " with prompt \(Shell.appleScriptQuote("\(promptName) precisa de privilégios de administrador."))"
            + " with administrator privileges"

        let result = try run(["/usr/bin/osascript", "-e", script])
        // -128 is the AppleScript "user cancelled" code.
        if !result.succeeded, result.standardError.contains("-128") {
            throw MacFastError.authorizationCancelled
        }
        return result
    }
}

/// Terminal variant: keeps the `sudo` prefix so the user is prompted on the
/// tty, instead of raising a GUI authentication dialog.
public struct TerminalCommandRunner: CommandRunner {
    private let base = SystemCommandRunner()

    public init() {}

    public func run(_ arguments: [String]) throws -> CommandResult {
        try base.run(arguments)
    }

    public func runPrivileged(_ arguments: [String]) throws -> CommandResult {
        try base.run(arguments)
    }
}

/// Prints what would run instead of running it. Backs `macfast --dry-run`.
public struct DryRunCommandRunner: CommandRunner {
    private let sink: (String) -> Void

    public init(sink: @escaping (String) -> Void = { print($0) }) {
        self.sink = sink
    }

    public func run(_ arguments: [String]) throws -> CommandResult {
        sink("  $ " + Shell.shellCommand(arguments))
        return CommandResult(status: 0, standardOutput: "", standardError: "")
    }

    public func runPrivileged(_ arguments: [String]) throws -> CommandResult {
        sink("  # " + Shell.shellCommand(Shell.strippingSudo(arguments)) + "   (como root)")
        return CommandResult(status: 0, standardOutput: "", standardError: "")
    }
}
