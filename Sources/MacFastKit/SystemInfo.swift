import Foundation

public struct SystemInfo: Sendable {
    public let osVersion: String
    public let modelIdentifier: String
    public let isRunningOCLP: Bool

    public init(osVersion: String, modelIdentifier: String, isRunningOCLP: Bool) {
        self.osVersion = osVersion
        self.modelIdentifier = modelIdentifier
        self.isRunningOCLP = isRunningOCLP
    }

    /// Paths OpenCore Legacy Patcher leaves behind once it has patched a system.
    /// Detection is only a hint for the UI — it never gates what the user may do.
    static let oclpMarkers = [
        "/Library/Application Support/Dortania",
        "/Library/Application Support/Dortania/OpenCore-Legacy-Patcher.plist",
        "/System/Library/CoreServices/OpenCore-Legacy-Patcher.plist",
    ]

    public static func current(runner: CommandRunner = SystemCommandRunner()) -> SystemInfo {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let versionString = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"

        let model = (try? runner.run(["/usr/sbin/sysctl", "-n", "hw.model"]))?
            .trimmedOutput ?? "desconhecido"

        return SystemInfo(
            osVersion: versionString,
            modelIdentifier: model.isEmpty ? "desconhecido" : model,
            isRunningOCLP: detectOCLP()
        )
    }

    public static func detectOCLP(fileManager: FileManager = .default) -> Bool {
        oclpMarkers.contains { fileManager.fileExists(atPath: $0) }
    }
}
