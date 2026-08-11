import Foundation
import MacFastKit

// MARK: - Argument parsing

var arguments = Array(CommandLine.arguments.dropFirst())
let isDryRun = arguments.contains("--dry-run")
arguments.removeAll { $0 == "--dry-run" }

let wantsAll = arguments.contains("--all")
arguments.removeAll { $0 == "--all" }

let oclpOnly = arguments.contains("--oclp")
arguments.removeAll { $0 == "--oclp" }

let command = arguments.first
let operands = Array(arguments.dropFirst())

let runner: CommandRunner = isDryRun ? DryRunCommandRunner() : TerminalCommandRunner()
// A dry run reads the real backups so `revert --all` lists the right tweaks,
// but must not write to them.
let engine = TweakEngine(runner: runner, backups: BackupStore(persists: !isDryRun))

// MARK: - Helpers

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("erro: " + message + "\n").utf8))
    exit(1)
}

func stateLabel(_ state: TweakState) -> String {
    switch state {
    case .applied: return "[x]"
    case .notApplied: return "[ ]"
    case .partial: return "[~]"
    case .unknown: return "[?]"
    }
}

/// Resolves operands that may be either tweak ids or preset names.
func resolveTweaks(_ operands: [String]) -> [Tweak] {
    var resolved: [Tweak] = []
    for operand in operands {
        if let preset = Preset(rawValue: operand) {
            resolved += preset.tweaks()
        } else if let tweak = TweakCatalog.tweak(id: operand) {
            resolved.append(tweak)
        } else {
            fail("ajuste ou preset desconhecido: \(operand)\nUse `macfast list` para ver os ids.")
        }
    }
    // A preset plus an explicit id can name the same tweak twice.
    var seen = Set<String>()
    return resolved.filter { seen.insert($0.id).inserted }
}

func report(_ result: ApplyReport, verb: String) {
    for tweak in result.applied {
        print("\(verb): \(tweak.title)")
    }
    for failure in result.failed {
        FileHandle.standardError.write(
            Data("falhou: \(failure.tweak.title) — \(failure.reason)\n".utf8))
    }

    if !isDryRun {
        engine.settle(effects: result.effects)
    }

    var notes: [String] = []
    if result.effects.contains(.needsLogout) {
        notes.append("Alguns ajustes só valem após sair e entrar de novo na conta.")
    }
    if result.effects.contains(.needsReboot) {
        notes.append("Alguns ajustes só valem após reiniciar o Mac.")
    }
    for note in notes { print("\nnota: \(note)") }

    if result.hasFailures { exit(1) }
}

func printUsage() {
    print("""
    macfast — desativa recursos do macOS para deixá-lo mais rápido

    USO
      macfast list [--oclp]        lista os ajustes disponíveis
      macfast status               mostra o estado atual de cada ajuste
      macfast presets              lista os presets
      macfast apply <id|preset>…   aplica ajustes
      macfast revert <id>… | --all reverte ajustes ao estado original
      macfast info                 mostra dados do sistema

    OPÇÕES
      --dry-run   imprime os comandos sem executar nada
      --oclp      restringe a lista aos ajustes recomendados para OCLP
      --all       com `revert`, desfaz tudo que o MacFast já aplicou

    Este app nunca desativa SIP, Gatekeeper, XProtect ou FileVault.
    """)
}

// MARK: - Commands

switch command {
case "list", nil:
    let info = SystemInfo.current()
    if info.isRunningOCLP {
        print("OpenCore Legacy Patcher detectado — ajustes marcados com ★ rendem mais aqui.\n")
    }
    for group in TweakCatalog.grouped() {
        let tweaks = oclpOnly ? group.tweaks.filter(\.recommendedForOCLP) : group.tweaks
        guard !tweaks.isEmpty else { continue }
        print("\(group.category.localizedName.uppercased())")
        for tweak in tweaks {
            let star = tweak.recommendedForOCLP ? "★" : " "
            print("  \(star) \(tweak.id.padding(toLength: 24, withPad: " ", startingAt: 0)) "
                + "\(tweak.title)  (\(tweak.risk.localizedName))")
            print("      \(tweak.summary)")
            print("      abre mão de: \(tweak.tradeoff)")
        }
        print("")
    }

case "status":
    for tweak in TweakCatalog.all {
        let state = engine.state(of: tweak)
        print("\(stateLabel(state)) \(tweak.id.padding(toLength: 24, withPad: " ", startingAt: 0)) "
            + "\(tweak.title) — \(state.localizedName)")
    }

case "presets":
    for preset in Preset.allCases {
        print("\(preset.rawValue.padding(toLength: 14, withPad: " ", startingAt: 0)) "
            + "\(preset.localizedName) — \(preset.tweaks().count) ajustes")
        print("   \(preset.localizedSummary)")
    }

case "apply":
    guard !operands.isEmpty else { fail("informe ao menos um id ou preset. Ex.: macfast apply oclp") }
    let tweaks = resolveTweaks(operands)
    if isDryRun { print("simulação — nada será alterado:\n") }
    report(engine.apply(tweaks), verb: "aplicado")

case "revert":
    let tweaks: [Tweak]
    if wantsAll {
        tweaks = engine.trackedTweakIds.compactMap { TweakCatalog.tweak(id: $0) }
        if tweaks.isEmpty {
            print("nada a reverter — o MacFast não aplicou nenhum ajuste nesta conta.")
            exit(0)
        }
    } else {
        guard !operands.isEmpty else { fail("informe um id ou use --all.") }
        tweaks = resolveTweaks(operands)
    }
    if isDryRun { print("simulação — nada será alterado:\n") }
    report(engine.revert(tweaks), verb: "revertido")

case "info":
    let info = SystemInfo.current()
    print("macOS:  \(info.osVersion)")
    print("modelo: \(info.modelIdentifier)")
    print("OCLP:   \(info.isRunningOCLP ? "detectado" : "não detectado")")
    print("backup: \(BackupStore.defaultDirectory.path)")

case "help", "--help", "-h":
    printUsage()

default:
    fail("comando desconhecido: \(command ?? "")\nUse `macfast help`.")
}
