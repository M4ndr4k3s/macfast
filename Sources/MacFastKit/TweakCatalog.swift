import Foundation

/// Convenience builders so catalog entries stay readable.
private func write(
    _ domain: String,
    _ key: String,
    _ value: PrefValue,
    currentHost: Bool = false
) -> Action {
    .defaultsWrite(domain: domain, key: key, value: value, currentHost: currentHost)
}

/// Builds a shell probe that prints `off` when the feature is disabled.
private func probeOff(_ test: String) -> [String] {
    ["/bin/sh", "-c", "\(test) && echo off || echo on"]
}

/// A preference living in a system-wide domain (a path under `/Library`).
/// These need root, so they go through a command instead of `.defaultsWrite`,
/// which the engine always runs as the current user.
///
/// Unlike `.defaultsWrite`, the revert value is Apple's default rather than
/// whatever the user had — a root plist is not backed up per user.
private func rootWrite(
    _ domain: String,
    _ key: String,
    optimized: String,
    original: String,
    type: String = "-bool",
    appliedOutput: String
) -> Action {
    .command(
        apply: ["/usr/bin/sudo", "/usr/bin/defaults", "write", domain, key, type, optimized],
        revert: ["/usr/bin/sudo", "/usr/bin/defaults", "write", domain, key, type, original],
        // The path may contain spaces, so it is quoted for the shell.
        probe: ["/bin/sh", "-c",
                "defaults read \(Shell.shellQuote(domain)) \(Shell.shellQuote(key)) 2>/dev/null"
                    + " || echo ausente"],
        appliedOutput: appliedOutput
    )
}

public enum Preset: String, CaseIterable, Sendable {
    /// Only cosmetic, instantly reversible changes. Nothing stops working.
    case conservative
    /// The balanced default: visible speed-up, features you rarely miss.
    case recommended
    /// Everything that pays off on Macs running through OpenCore Legacy Patcher.
    case oclp

    public var localizedName: String {
        switch self {
        case .conservative: return "Conservador"
        case .recommended: return "Recomendado"
        case .oclp: return "OCLP (Mac não suportado)"
        }
    }

    public var localizedSummary: String {
        switch self {
        case .conservative:
            return "Só ajustes visuais, sem perder nenhum recurso."
        case .recommended:
            return "Ganho perceptível trocando recursos que a maioria não usa."
        case .oclp:
            return "Foco no que mais pesa em Macs sem suporte a Metal nativo."
        }
    }

    public func tweaks(from catalog: [Tweak] = TweakCatalog.all) -> [Tweak] {
        switch self {
        case .conservative:
            return catalog.filter { $0.risk == .safe }
        case .recommended:
            return catalog.filter { $0.risk != .advanced }
        case .oclp:
            return catalog.filter { $0.recommendedForOCLP }
        }
    }
}

/// A category and the tweaks it holds. A named type rather than a tuple so it
/// can be identified in SwiftUI lists.
public struct TweakGroup: Identifiable, Equatable, Sendable {
    public let category: Category
    public let tweaks: [Tweak]

    public var id: Category { category }
}

public enum TweakCatalog {

    public static func tweak(id: String) -> Tweak? {
        all.first { $0.id == id }
    }

    public static func grouped() -> [TweakGroup] {
        Category.allCases.compactMap { category in
            let matches = all.filter { $0.category == category }
            return matches.isEmpty ? nil : TweakGroup(category: category, tweaks: matches)
        }
    }

    public static let all: [Tweak] =
        animations + interface + indexing + background + power + network + privacy

    // MARK: - Animações

    static let animations: [Tweak] = [
        Tweak(
            id: "reduce-motion",
            title: "Reduzir movimento",
            summary: "Troca as animações de janelas, Spaces e Launchpad por transições simples.",
            tradeoff: "As transições ficam secas, sem deslizamento entre telas.",
            category: .animations,
            risk: .safe,
            effect: .needsLogout,
            recommendedForOCLP: true,
            actions: [write("com.apple.universalaccess", "reduceMotion", .bool(true))]
        ),
        Tweak(
            id: "window-animations",
            title: "Desativar animação de abrir janelas",
            summary: "Janelas e caixas de diálogo aparecem instantaneamente.",
            tradeoff: "Perde o efeito de crescimento ao abrir uma janela.",
            category: .animations,
            risk: .safe,
            recommendedForOCLP: true,
            actions: [write("NSGlobalDomain", "NSAutomaticWindowAnimationsEnabled", .bool(false))]
        ),
        Tweak(
            id: "window-resize-speed",
            title: "Acelerar redimensionamento de janelas",
            summary: "Reduz o tempo de animação ao redimensionar para quase zero.",
            tradeoff: "Nenhum: apenas mais rápido.",
            category: .animations,
            risk: .safe,
            recommendedForOCLP: true,
            actions: [write("NSGlobalDomain", "NSWindowResizeTime", .double(0.001))]
        ),
        Tweak(
            id: "smooth-scrolling",
            title: "Desativar rolagem suave",
            summary: "A rolagem passa a acompanhar o gesto sem inércia animada.",
            tradeoff: "A rolagem fica menos fluida visualmente.",
            category: .animations,
            risk: .safe,
            recommendedForOCLP: true,
            actions: [write("NSGlobalDomain", "NSScrollAnimationEnabled", .bool(false))]
        ),
        Tweak(
            id: "finder-animations",
            title: "Desativar animações do Finder",
            summary: "Copiar, mover e abrir pastas deixa de animar.",
            tradeoff: "Menos retorno visual nas operações de arquivo.",
            category: .animations,
            risk: .safe,
            effect: .restartsFinder,
            recommendedForOCLP: true,
            actions: [write("com.apple.finder", "DisableAllAnimations", .bool(true))]
        ),
        Tweak(
            id: "mission-control-speed",
            title: "Acelerar Mission Control",
            summary: "Encurta a animação de entrada e saída do Mission Control.",
            tradeoff: "Nenhum: só a animação fica mais curta.",
            category: .animations,
            risk: .safe,
            effect: .restartsDock,
            recommendedForOCLP: true,
            actions: [write("com.apple.dock", "expose-animation-duration", .double(0.1))]
        ),
        Tweak(
            id: "dock-autohide-speed",
            title: "Acelerar ocultação do Dock",
            summary: "Remove o atraso e encurta a animação do Dock automático.",
            tradeoff: "Nenhum: o Dock aparece na hora.",
            category: .animations,
            risk: .safe,
            effect: .restartsDock,
            recommendedForOCLP: true,
            actions: [
                write("com.apple.dock", "autohide-delay", .double(0)),
                write("com.apple.dock", "autohide-time-modifier", .double(0.35)),
            ]
        ),
        Tweak(
            id: "quicklook-animation",
            title: "Desativar animação do Quick Look",
            summary: "A janela de visualização rápida abre sem transição.",
            tradeoff: "Nenhum: só a animação some.",
            category: .animations,
            risk: .safe,
            actions: [write("NSGlobalDomain", "QLPanelAnimationDuration", .double(0))]
        ),
    ]

    // MARK: - Interface

    static let interface: [Tweak] = [
        Tweak(
            id: "reduce-transparency",
            title: "Reduzir transparência",
            summary: "Remove o desfoque do Dock, da barra de menus e das barras laterais. "
                + "É o ajuste com maior impacto em Macs sem aceleração gráfica adequada.",
            tradeoff: "A interface fica com fundos sólidos, sem o efeito de vidro.",
            category: .interface,
            risk: .safe,
            effect: .needsLogout,
            recommendedForOCLP: true,
            actions: [write("com.apple.universalaccess", "reduceTransparency", .bool(true))]
        ),
        Tweak(
            id: "desktop-tinting",
            title: "Desativar tingimento pelo papel de parede",
            summary: "Impede que as janelas recalculem cor a partir do papel de parede.",
            tradeoff: "As janelas deixam de combinar com a cor do fundo.",
            category: .interface,
            risk: .safe,
            effect: .needsLogout,
            recommendedForOCLP: true,
            actions: [write("NSGlobalDomain", "AppleReduceDesktopTinting", .bool(true))]
        ),
        Tweak(
            id: "stage-manager",
            title: "Desativar Stage Manager",
            summary: "Desliga o gerenciador de palco, que mantém miniaturas ao vivo das janelas.",
            tradeoff: "Perde o Stage Manager (só existe no Ventura ou mais recente).",
            category: .interface,
            risk: .safe,
            recommendedForOCLP: true,
            actions: [write("com.apple.WindowManager", "GloballyEnabled", .bool(false))]
        ),
        Tweak(
            id: "dock-magnification",
            title: "Desativar ampliação do Dock",
            summary: "Os ícones deixam de crescer quando o cursor passa por cima.",
            tradeoff: "Perde o efeito de lupa do Dock.",
            category: .interface,
            risk: .safe,
            effect: .restartsDock,
            actions: [write("com.apple.dock", "magnification", .bool(false))]
        ),
        Tweak(
            id: "dock-recents",
            title: "Ocultar apps recentes no Dock",
            summary: "Evita que o Dock rastreie e desenhe aplicativos usados recentemente.",
            tradeoff: "A seção de recentes do Dock desaparece.",
            category: .interface,
            risk: .safe,
            effect: .restartsDock,
            actions: [write("com.apple.dock", "show-recents", .bool(false))]
        ),
    ]

    // MARK: - Indexação e busca

    static let indexing: [Tweak] = [
        Tweak(
            id: "spotlight-indexing",
            title: "Desativar indexação do Spotlight",
            summary: "Para o mdworker em todos os volumes. Alívio grande em HDs mecânicos.",
            tradeoff: "A busca do Spotlight para de encontrar arquivos e apps por nome. "
                + "Reverter reindexa tudo, o que leva tempo e consome CPU.",
            category: .indexing,
            risk: .moderate,
            recommendedForOCLP: true,
            actions: [.command(
                apply: ["/usr/bin/sudo", "/usr/bin/mdutil", "-i", "off", "-a"],
                revert: ["/usr/bin/sudo", "/usr/bin/mdutil", "-i", "on", "-a"],
                probe: probeOff("/usr/bin/mdutil -s / 2>/dev/null | grep -q 'disabled'"),
                appliedOutput: "off"
            )]
        ),
        Tweak(
            id: "spotlight-suggestions",
            title: "Desativar sugestões da Siri no Spotlight",
            summary: "Impede que a busca local consulte servidores da Apple.",
            tradeoff: "O Spotlight deixa de trazer resultados da web e sugestões.",
            category: .indexing,
            risk: .safe,
            effect: .needsLogout,
            recommendedForOCLP: true,
            actions: [write("com.apple.lookup.shared", "LookupSuggestionsDisabled", .bool(true))]
        ),
    ]

    // MARK: - Serviços em segundo plano

    static let background: [Tweak] = [
        Tweak(
            id: "siri",
            title: "Desativar a Siri",
            summary: "Desliga o assistente e o seu processo residente.",
            tradeoff: "A Siri para de responder e some da barra de menus.",
            category: .background,
            risk: .moderate,
            effect: .needsLogout,
            recommendedForOCLP: true,
            actions: [
                write("com.apple.assistant.support", "Assistant Enabled", .bool(false)),
                write("com.apple.Siri", "StatusMenuVisible", .bool(false)),
            ]
        ),
        Tweak(
            id: "media-analysis",
            title: "Desativar análise de mídia (Texto ao Vivo)",
            summary: "Para o mediaanalysisd, que varre imagens para Texto ao Vivo e Consulta Visual.",
            tradeoff: "Texto ao Vivo e Consulta Visual param de funcionar.",
            category: .background,
            risk: .advanced,
            effect: .needsReboot,
            recommendedForOCLP: true,
            actions: [.command(
                apply: ["/bin/sh", "-c", "launchctl disable gui/$(id -u)/com.apple.mediaanalysisd"],
                revert: ["/bin/sh", "-c", "launchctl enable gui/$(id -u)/com.apple.mediaanalysisd"],
                probe: probeOff(
                    "launchctl print-disabled gui/$(id -u) 2>/dev/null"
                        + " | grep -q '\"com.apple.mediaanalysisd\" => \\(true\\|disabled\\)'"
                ),
                appliedOutput: "off"
            )]
        ),
        Tweak(
            id: "photo-analysis",
            title: "Desativar análise da Fototeca",
            summary: "Para o photoanalysisd, que faz reconhecimento facial e de cenas em segundo plano.",
            tradeoff: "O app Fotos deixa de agrupar por rostos e memórias.",
            category: .background,
            risk: .advanced,
            effect: .needsReboot,
            recommendedForOCLP: true,
            actions: [.command(
                apply: ["/bin/sh", "-c", "launchctl disable gui/$(id -u)/com.apple.photoanalysisd"],
                revert: ["/bin/sh", "-c", "launchctl enable gui/$(id -u)/com.apple.photoanalysisd"],
                probe: probeOff(
                    "launchctl print-disabled gui/$(id -u) 2>/dev/null"
                        + " | grep -q '\"com.apple.photoanalysisd\" => \\(true\\|disabled\\)'"
                ),
                appliedOutput: "off"
            )]
        ),
    ]

    // MARK: - Energia e disco

    static let power: [Tweak] = [
        Tweak(
            id: "hibernate-mode",
            title: "Desativar imagem de hibernação",
            summary: "Faz o Mac dormir só na memória, sem gravar a RAM inteira no disco.",
            tradeoff: "Se a bateria acabar durante o sono, a sessão é perdida. "
                + "Em troca, o disco para de escrever vários GB a cada suspensão.",
            category: .power,
            risk: .advanced,
            recommendedForOCLP: true,
            actions: [.command(
                apply: ["/usr/bin/sudo", "/usr/bin/pmset", "-a", "hibernatemode", "0"],
                revert: ["/usr/bin/sudo", "/usr/bin/pmset", "-a", "hibernatemode", "3"],
                probe: ["/bin/sh", "-c", "pmset -g | awk '/hibernatemode/ {print $2}'"],
                appliedOutput: "0"
            )]
        ),
        Tweak(
            id: "power-nap",
            title: "Desativar Power Nap",
            summary: "O Mac deixa de acordar sozinho para sincronizar e indexar.",
            tradeoff: "Mail e iCloud só atualizam com a máquina acordada.",
            category: .power,
            risk: .moderate,
            recommendedForOCLP: true,
            actions: [.command(
                apply: ["/usr/bin/sudo", "/usr/bin/pmset", "-a", "powernap", "0"],
                revert: ["/usr/bin/sudo", "/usr/bin/pmset", "-a", "powernap", "1"],
                probe: ["/bin/sh", "-c", "pmset -g | awk '/powernap/ {print $2}'"],
                appliedOutput: "0"
            )]
        ),
        Tweak(
            id: "sudden-motion-sensor",
            title: "Desativar sensor de movimento súbito",
            summary: "Sensor que estaciona a cabeça de HDs mecânicos ao detectar queda.",
            tradeoff: "Só ative se o Mac tiver SSD. Com HD mecânico, isso remove uma proteção real.",
            category: .power,
            risk: .advanced,
            actions: [.command(
                apply: ["/usr/bin/sudo", "/usr/bin/pmset", "-a", "sms", "0"],
                revert: ["/usr/bin/sudo", "/usr/bin/pmset", "-a", "sms", "1"],
                probe: ["/bin/sh", "-c", "pmset -g | awk '/sms/ {print $2}'"],
                appliedOutput: "0"
            )]
        ),
        Tweak(
            id: "time-machine-auto",
            title: "Desativar backup automático do Time Machine",
            summary: "Os backups passam a ser manuais, em vez de a cada hora.",
            tradeoff: "Você precisa lembrar de fazer backup. O Time Machine continua "
                + "instalado e funciona normalmente quando acionado à mão.",
            category: .power,
            risk: .moderate,
            actions: [.command(
                apply: ["/usr/bin/sudo", "/usr/bin/tmutil", "disable"],
                revert: ["/usr/bin/sudo", "/usr/bin/tmutil", "enable"],
                probe: ["/bin/sh", "-c",
                        "defaults read /Library/Preferences/com.apple.TimeMachine AutoBackup 2>/dev/null || echo 0"],
                appliedOutput: "0"
            )]
        ),
    ]

    // MARK: - Rede e sincronização

    static let network: [Tweak] = [
        Tweak(
            id: "handoff",
            title: "Desativar Handoff",
            summary: "Para o anúncio contínuo de atividade por Bluetooth e Wi-Fi entre dispositivos.",
            tradeoff: "Perde a continuidade entre Mac, iPhone e iPad.",
            category: .network,
            risk: .moderate,
            effect: .needsLogout,
            recommendedForOCLP: true,
            actions: [
                write("com.apple.coreservices.useractivityd", "ActivityAdvertisingAllowed",
                      .bool(false), currentHost: true),
                write("com.apple.coreservices.useractivityd", "ActivityReceivingAllowed",
                      .bool(false), currentHost: true),
            ]
        ),
        Tweak(
            id: "airdrop",
            title: "Desativar AirDrop",
            summary: "Para a busca contínua por dispositivos próximos via Bluetooth e Wi-Fi.",
            tradeoff: "O AirDrop some do Finder e o Mac deixa de aparecer para outros aparelhos.",
            category: .network,
            risk: .moderate,
            effect: .restartsFinder,
            recommendedForOCLP: true,
            actions: [write("com.apple.NetworkBrowser", "DisableAirDrop", .bool(true))]
        ),
        Tweak(
            id: "airplay-receiver",
            title: "Desativar Receptor AirPlay",
            summary: "Impede que o Mac fique escutando para receber transmissões de outros "
                + "aparelhos. Também libera a porta 5000, que costuma conflitar com "
                + "servidores locais de desenvolvimento.",
            tradeoff: "Você não consegue mais espelhar a tela do iPhone ou iPad neste Mac.",
            category: .network,
            risk: .safe,
            effect: .needsLogout,
            recommendedForOCLP: true,
            // Apple's own key carries the typo "Reciever"; it must be written
            // exactly like this to take effect.
            actions: [write("com.apple.controlcenter", "AirplayRecieverEnabled", .bool(false))]
        ),
        Tweak(
            id: "bonjour-advertising",
            title: "Parar de se anunciar na rede (Bonjour)",
            summary: "O Mac deixa de transmitir seus serviços por multicast, reduzindo tráfego "
                + "constante em redes cheias.",
            tradeoff: "Outros aparelhos não encontram este Mac pelo nome. Compartilhamento de "
                + "tela e de arquivos ainda funcionam se você digitar o IP.",
            category: .network,
            risk: .advanced,
            effect: .needsReboot,
            actions: [rootWrite(
                "/Library/Preferences/com.apple.mDNSResponder.plist",
                "NoMulticastAdvertisements",
                optimized: "true", original: "false", appliedOutput: "1"
            )]
        ),
        Tweak(
            id: "captive-portal",
            title: "Desativar assistente de rede Wi-Fi",
            summary: "Impede que o macOS abra sozinho uma janela e faça requisições de teste "
                + "ao entrar em qualquer Wi-Fi.",
            tradeoff: "Em Wi-Fi público com tela de login, você precisa abrir o navegador à mão.",
            category: .network,
            risk: .moderate,
            actions: [rootWrite(
                "/Library/Preferences/SystemConfiguration/com.apple.captive.control",
                "Active",
                optimized: "false", original: "true", appliedOutput: "0"
            )]
        ),
    ]

    // MARK: - Privacidade

    static let privacy: [Tweak] = [
        Tweak(
            id: "personalized-ads",
            title: "Desativar anúncios personalizados",
            summary: "Desliga o identificador de anúncios e a segmentação da Apple.",
            tradeoff: "Nenhum uso é perdido: os anúncios da App Store continuam, só deixam "
                + "de ser baseados no seu perfil.",
            category: .privacy,
            risk: .safe,
            effect: .needsLogout,
            recommendedForOCLP: true,
            actions: [
                write("com.apple.AdLib", "allowApplePersonalizedAdvertising", .bool(false)),
                write("com.apple.AdLib", "allowIdentifierForAdvertising", .bool(false)),
                write("com.apple.AdLib", "forceLimitAdTracking", .bool(true)),
            ]
        ),
        Tweak(
            id: "siri-data-sharing",
            title: "Não compartilhar gravações da Siri",
            summary: "Recusa o envio de áudio e transcrições da Siri e do Ditado para a Apple.",
            tradeoff: "Nenhum: a Siri continua funcionando igual.",
            category: .privacy,
            risk: .safe,
            effect: .needsLogout,
            actions: [
                // 2 is the "opted out" state used by macOS.
                write("com.apple.assistant.support", "Siri Data Sharing Opt-In Status", .int(2)),
            ]
        ),
        Tweak(
            id: "safari-search-suggestions",
            title: "Desativar sugestões de busca do Safari",
            summary: "O Safari para de enviar o que você digita na barra de endereços antes "
                + "de você apertar Enter.",
            tradeoff: "Some o preenchimento de busca enquanto digita. Este ajuste costuma "
                + "exigir Acesso Total ao Disco para o MacFast, por causa do contêiner do Safari.",
            category: .privacy,
            risk: .safe,
            effect: .needsLogout,
            actions: [
                write("com.apple.Safari", "UniversalSearchEnabled", .bool(false)),
                write("com.apple.Safari", "SuppressSearchSuggestions", .bool(true)),
            ]
        ),
        Tweak(
            id: "crash-reporter-dialog",
            title: "Não perguntar sobre relatórios de falha",
            summary: "A janela “o aplicativo encerrou inesperadamente” para de aparecer.",
            tradeoff: "Você deixa de ser avisado quando um app trava. Os relatórios continuam "
                + "gravados em disco para consulta no Console.",
            category: .privacy,
            risk: .safe,
            actions: [write("com.apple.CrashReporter", "DialogType", .string("none"))]
        ),
        Tweak(
            id: "diagnostic-submission",
            title: "Não enviar diagnósticos para a Apple",
            summary: "Desliga o envio automático de dados de falha e uso do sistema inteiro.",
            tradeoff: "Nenhum para você: só a Apple deixa de receber os relatórios.",
            category: .privacy,
            risk: .safe,
            recommendedForOCLP: true,
            actions: [rootWrite(
                "/Library/Application Support/CrashReporter/DiagnosticMessagesHistory.plist",
                "AutoSubmit",
                optimized: "false", original: "true", appliedOutput: "0"
            )]
        ),
    ]
}
