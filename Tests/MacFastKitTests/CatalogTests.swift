import XCTest
@testable import MacFastKit

/// These tests never touch the real system: they check catalog integrity and
/// pure string/state logic only.
final class CatalogTests: XCTestCase {

    func testTweakIdsAreUnique() {
        let ids = TweakCatalog.all.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "ids duplicados no catálogo")
    }

    func testEveryTweakDocumentsItsTradeoff() {
        for tweak in TweakCatalog.all {
            XCTAssertFalse(tweak.tradeoff.trimmingCharacters(in: .whitespaces).isEmpty,
                           "\(tweak.id) não diz o que o usuário perde")
            XCTAssertFalse(tweak.summary.trimmingCharacters(in: .whitespaces).isEmpty,
                           "\(tweak.id) sem descrição")
        }
    }

    /// Nothing irreversible may enter the catalog: every command action needs a
    /// working undo, and every tweak needs at least one action.
    func testEveryActionIsReversible() {
        for tweak in TweakCatalog.all {
            XCTAssertFalse(tweak.actions.isEmpty, "\(tweak.id) não faz nada")
            for action in tweak.actions {
                switch action {
                case .defaultsWrite(let domain, let key, _, _):
                    XCTAssertFalse(domain.isEmpty, "\(tweak.id) com domínio vazio")
                    XCTAssertFalse(key.isEmpty, "\(tweak.id) com chave vazia")
                case .command(let apply, let revert, _, _):
                    XCTAssertFalse(apply.isEmpty, "\(tweak.id) sem comando de aplicação")
                    XCTAssertFalse(revert.isEmpty, "\(tweak.id) sem comando de reversão")
                }
            }
        }
    }

    /// A command tweak without a probe reports `.unknown` forever, which shows
    /// up in the UI as a switch that never reflects reality.
    func testCommandActionsCanReportTheirState() {
        for tweak in TweakCatalog.all {
            for action in tweak.actions {
                if case .command(_, _, let probe, let appliedOutput) = action {
                    XCTAssertNotNil(probe, "\(tweak.id) não sabe ler o próprio estado")
                    XCTAssertNotNil(appliedOutput, "\(tweak.id) sem saída esperada")
                }
            }
        }
    }

    func testCatalogAvoidsSecurityWeakeningCommands() {
        let forbidden = ["csrutil", "spctl", "xprotect", "fdesetup", "nvram"]
        for tweak in TweakCatalog.all {
            for action in tweak.actions {
                guard case .command(let apply, let revert, _, _) = action else { continue }
                let text = (apply + revert).joined(separator: " ").lowercased()
                for term in forbidden {
                    XCTAssertFalse(text.contains(term),
                                   "\(tweak.id) mexe em segurança do sistema (\(term))")
                }
            }
        }
    }

    func testPresetsAreNonEmptyAndDrawnFromTheCatalog() {
        let ids = Set(TweakCatalog.all.map(\.id))
        for preset in Preset.allCases {
            let tweaks = preset.tweaks()
            XCTAssertFalse(tweaks.isEmpty, "preset \(preset.rawValue) está vazio")
            for tweak in tweaks {
                XCTAssertTrue(ids.contains(tweak.id), "preset traz ajuste fora do catálogo")
            }
        }
    }

    func testConservativePresetOnlyContainsSafeTweaks() {
        XCTAssertTrue(Preset.conservative.tweaks().allSatisfy { $0.risk == .safe })
    }

    func testLookupById() {
        XCTAssertEqual(TweakCatalog.tweak(id: "reduce-transparency")?.category, .interface)
        XCTAssertNil(TweakCatalog.tweak(id: "não-existe"))
    }

    func testGroupingCoversEveryTweak() {
        let grouped = TweakCatalog.grouped().flatMap(\.tweaks)
        XCTAssertEqual(grouped.count, TweakCatalog.all.count)
    }
}
