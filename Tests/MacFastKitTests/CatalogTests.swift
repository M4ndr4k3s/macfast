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

    /// A category with no tweaks shows up as an empty section in the sidebar.
    func testEveryCategoryHasAtLeastOneTweak() {
        for category in TweakCategory.allCases {
            XCTAssertTrue(TweakCatalog.all.contains { $0.category == category },
                          "categoria \(category.rawValue) está vazia")
        }
    }

    /// Root plists cannot be written by the engine's user-level `defaults`
    /// call, so they must go through a sudo command instead.
    func testSystemWideDomainsAreWrittenAsRoot() {
        for tweak in TweakCatalog.all {
            for action in tweak.actions {
                if case .defaultsWrite(let domain, _, _, _) = action {
                    XCTAssertFalse(domain.hasPrefix("/"),
                                   "\(tweak.id) escreve num domínio do sistema sem root")
                }
            }
        }
    }

    // MARK: - Disponibilidade por versão

    func testVersionRangeBoundsAreInclusive() {
        let ventura = OSRange.from(13)
        XCTAssertFalse(ventura.contains(major: 12))
        XCTAssertTrue(ventura.contains(major: 13))
        XCTAssertTrue(ventura.contains(major: 26))

        let upToSequoia = OSRange.upTo(15)
        XCTAssertTrue(upToSequoia.contains(major: 15))
        XCTAssertFalse(upToSequoia.contains(major: 26))

        XCTAssertTrue(OSRange.any.contains(major: 11))
        XCTAssertTrue(OSRange.any.isUniversal)
    }

    func testVersionRangeIsDescribedInPlainLanguage() {
        XCTAssertEqual(OSRange.from(13).shortName, "macOS 13+")
        XCTAssertEqual(OSRange.upTo(15).shortName, "≤ macOS 15")
        XCTAssertEqual(OSRange(minimumMajor: 12, maximumMajor: 14).shortName, "macOS 12–14")
        XCTAssertEqual(OSRange.any.shortName, "")
        XCTAssertTrue(OSRange.from(13).localizedName.contains("Ventura"))
    }

    /// Features Apple introduced in a later release must say so, otherwise the
    /// tweak silently writes a key the running system ignores.
    func testVersionGatedTweaksDeclareTheirMinimum() {
        XCTAssertEqual(TweakCatalog.tweak(id: "stage-manager")?.availability.minimumMajor, 13)
        XCTAssertEqual(TweakCatalog.tweak(id: "universal-control")?.availability.minimumMajor, 12)
        XCTAssertEqual(TweakCatalog.tweak(id: "airplay-receiver")?.availability.minimumMajor, 12)
        XCTAssertEqual(TweakCatalog.tweak(id: "media-analysis")?.availability.minimumMajor, 12)
        // O Launchpad deixou de existir no macOS 26.
        XCTAssertEqual(TweakCatalog.tweak(id: "launchpad-animations")?.availability.maximumMajor, 15)
    }

    func testPresetsDropTweaksTheRunningSystemCannotUse() {
        let onBigSur = Preset.recommended.tweaks(availableOn: 11).map(\.id)
        XCTAssertFalse(onBigSur.contains("stage-manager"))
        XCTAssertFalse(onBigSur.contains("universal-control"))

        let onVentura = Preset.recommended.tweaks(availableOn: 13).map(\.id)
        XCTAssertTrue(onVentura.contains("stage-manager"))
    }

    /// Without a version filter the catalog is returned whole, so `list` can
    /// still show everything that exists.
    func testPresetsWithoutFilterKeepEverything() {
        XCTAssertTrue(Preset.recommended.tweaks().map(\.id).contains("stage-manager"))
    }

    func testGroupingCoversEveryTweak() {
        let grouped = TweakCatalog.grouped().flatMap(\.tweaks)
        XCTAssertEqual(grouped.count, TweakCatalog.all.count)
    }
}
