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

/// Disables a per-user launch agent. The uid is resolved at run time so the
/// same command works for whoever is logged in.
private func launchAgentDisabled(_ label: String) -> Action {
    .command(
        apply: ["/bin/sh", "-c", "launchctl disable gui/$(id -u)/\(label)"],
        revert: ["/bin/sh", "-c", "launchctl enable gui/$(id -u)/\(label)"],
        // `print-disabled` prints `=> true` on older systems and `=> disabled`
        // on newer ones.
        probe: probeOff(
            "launchctl print-disabled gui/$(id -u) 2>/dev/null"
                + " | grep -q '\"\(label)\" => \\(true\\|disabled\\)'"
        ),
        appliedOutput: "off"
    )
}

/// A power-management setting, read back from `pmset -g`.
///
/// The probe matches on the whole field name so that, say, `sleep` does not
/// also match `displaysleep`.
private func pmset(_ setting: String, optimized: String, original: String) -> Action {
    .command(
        apply: ["/usr/bin/sudo", "/usr/bin/pmset", "-a", setting, optimized],
        revert: ["/usr/bin/sudo", "/usr/bin/pmset", "-a", setting, original],
        probe: ["/bin/sh", "-c", "pmset -g | awk '$1 == \"\(setting)\" {print $2}'"],
        appliedOutput: optimized
    )
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

    /// - Parameter availableOn: major macOS version to filter by. Passing it
    ///   keeps a preset from failing on every tweak the running system does not
    ///   support; `nil` returns the preset regardless of version.
    public func tweaks(
        from catalog: [Tweak] = TweakCatalog.all,
        availableOn osMajor: Int? = nil
    ) -> [Tweak] {
        let supported = osMajor.map { major in
            catalog.filter { $0.isAvailable(onMajor: major) }
        } ?? catalog

        switch self {
        case .conservative:
            return supported.filter { $0.risk == .safe }
        case .recommended:
            return supported.filter { $0.risk != .advanced }
        case .oclp:
            return supported.filter { $0.recommendedForOCLP }
        }
    }
}

/// A category and the tweaks it holds. A named type rather than a tuple so it
/// can be identified in SwiftUI lists.
public struct TweakGroup: Identifiable, Equatable, Sendable {
    public let category: TweakCategory
    public let tweaks: [Tweak]

    public var id: TweakCategory { category }
}

public enum TweakCatalog {

    public static func tweak(id: String) -> Tweak? {
        all.first { $0.id == id }
    }

    public static func grouped() -> [TweakGroup] {
        TweakCategory.allCases.compactMap { category in
            let matches = all.filter { $0.category == category }
            return matches.isEmpty ? nil : TweakGroup(category: category, tweaks: matches)
        }
    }

    public static let all: [Tweak] =
        animations + interface + indexing + background + power + network + privacy
            + notifications + battery + trackpad

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
            id: "dock-launch-animation",
            title: "Desativar animação de abrir apps",
            summary: "O ícone para de pular no Dock enquanto o app carrega.",
            tradeoff: "Menos indicação visual de que um app está abrindo.",
            category: .animations,
            risk: .safe,
            effect: .restartsDock,
            recommendedForOCLP: true,
            actions: [write("com.apple.dock", "launchanim", .bool(false))]
        ),
        Tweak(
            id: "launchpad-animations",
            title: "Acelerar o Launchpad",
            summary: "Encurta a abertura, o fechamento e a troca de páginas do Launchpad.",
            tradeoff: "Nenhum: só as animações ficam mais curtas.",
            category: .animations,
            risk: .safe,
            effect: .restartsDock,
            recommendedForOCLP: true,
            availability: .upTo(15),
            actions: [
                write("com.apple.dock", "springboard-show-duration", .double(0.1)),
                write("com.apple.dock", "springboard-hide-duration", .double(0.1)),
                write("com.apple.dock", "springboard-page-duration", .double(0.2)),
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
            tradeoff: "Perde o Stage Manager.",
            category: .interface,
            risk: .safe,
            recommendedForOCLP: true,
            availability: .from(13),
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
            id: "reopen-windows",
            title: "Não reabrir janelas ao ligar",
            summary: "O macOS para de restaurar todas as janelas e apps do login anterior, "
                + "que é o que costuma travar a máquina nos primeiros minutos depois de ligar.",
            tradeoff: "Você reabre à mão o que estava usando antes de desligar.",
            category: .interface,
            risk: .safe,
            effect: .needsLogout,
            recommendedForOCLP: true,
            actions: [write("NSGlobalDomain", "NSQuitAlwaysKeepsWindows", .bool(false))]
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
            availability: .from(12),
            actions: [launchAgentDisabled("com.apple.mediaanalysisd")]
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
            actions: [launchAgentDisabled("com.apple.photoanalysisd")]
        ),
        Tweak(
            id: "proactive-suggestions",
            title: "Desativar sugestões proativas",
            summary: "Para o suggestd, que lê e-mails, mensagens e calendário em segundo plano "
                + "para sugerir contatos, eventos e atalhos.",
            tradeoff: "O macOS deixa de sugerir eventos a partir de e-mails e contatos "
                + "desconhecidos em ligações.",
            category: .background,
            risk: .moderate,
            effect: .needsReboot,
            recommendedForOCLP: true,
            actions: [launchAgentDisabled("com.apple.suggestd")]
        ),
        Tweak(
            id: "game-center",
            title: "Desativar Game Center",
            summary: "Para o gamed, que fica ativo mesmo em Macs onde ninguém joga.",
            tradeoff: "Jogos com placar e conquistas do Game Center param de sincronizar.",
            category: .background,
            risk: .safe,
            effect: .needsReboot,
            recommendedForOCLP: true,
            actions: [launchAgentDisabled("com.apple.gamed")]
        ),
        Tweak(
            id: "camera-hotplug",
            title: "Não abrir Fotos ao conectar câmera",
            summary: "Conectar iPhone, câmera ou cartão deixa de abrir o Fotos e disparar "
                + "leitura de todas as imagens.",
            tradeoff: "Você abre o Fotos ou o Captura de Imagem à mão quando quiser importar.",
            category: .background,
            risk: .safe,
            recommendedForOCLP: true,
            actions: [write("com.apple.ImageCapture", "disableHotPlug", .bool(true))]
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
            actions: [pmset("hibernatemode", optimized: "0", original: "3")]
        ),
        Tweak(
            id: "power-nap",
            title: "Desativar Power Nap",
            summary: "O Mac deixa de acordar sozinho para sincronizar e indexar.",
            tradeoff: "Mail e iCloud só atualizam com a máquina acordada.",
            category: .power,
            risk: .moderate,
            recommendedForOCLP: true,
            actions: [pmset("powernap", optimized: "0", original: "1")]
        ),
        Tweak(
            id: "sudden-motion-sensor",
            title: "Desativar sensor de movimento súbito",
            summary: "Sensor que estaciona a cabeça de HDs mecânicos ao detectar queda.",
            tradeoff: "Só ative se o Mac tiver SSD. Com HD mecânico, isso remove uma proteção real.",
            category: .power,
            risk: .advanced,
            actions: [pmset("sms", optimized: "0", original: "1")]
        ),
        Tweak(
            id: "timemachine-new-disks",
            title: "Não oferecer novos discos para backup",
            summary: "Conectar um HD externo deixa de abrir a pergunta do Time Machine e de "
                + "varrer o disco.",
            tradeoff: "Para configurar um backup novo, você abre o Time Machine à mão.",
            category: .power,
            risk: .safe,
            recommendedForOCLP: true,
            actions: [write("com.apple.TimeMachine", "DoNotOfferNewDisksForBackup", .bool(true))]
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
            availability: .from(12),
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
        Tweak(
            id: "network-ds-store",
            title: "Não criar .DS_Store em pastas de rede",
            summary: "O Finder para de escrever arquivos de metadados em volumes SMB e AFP. "
                + "É o que mais deixa o Finder lento em disco de rede.",
            tradeoff: "Cada pasta de rede esquece o modo de visualização e a posição dos ícones.",
            category: .network,
            risk: .safe,
            effect: .needsLogout,
            recommendedForOCLP: true,
            actions: [write("com.apple.desktopservices", "DSDontWriteNetworkStores", .bool(true))]
        ),
        Tweak(
            id: "universal-control",
            title: "Desativar Controle Universal",
            summary: "Para a procura contínua por Macs e iPads por perto para compartilhar "
                + "teclado e mouse.",
            tradeoff: "Você não consegue mais mover o cursor direto para um iPad ou outro Mac.",
            category: .network,
            risk: .safe,
            effect: .needsLogout,
            recommendedForOCLP: true,
            availability: .from(12),
            actions: [write("com.apple.universalcontrol", "Disable", .bool(true))]
        ),
        Tweak(
            id: "sharing-daemon",
            title: "Desativar daemon de compartilhamento",
            summary: "Para o sharingd de vez. Só faz sentido depois de desativar AirDrop e "
                + "Handoff, já que é ele quem sustenta os dois.",
            tradeoff: "AirDrop, Handoff, Área de Transferência Universal e Instant Hotspot "
                + "param de funcionar por completo.",
            category: .network,
            risk: .advanced,
            effect: .needsReboot,
            actions: [launchAgentDisabled("com.apple.sharingd")]
        ),
        Tweak(
            id: "icloud-default-save",
            title: "Não salvar no iCloud por padrão",
            summary: "Novos documentos passam a ser salvos no disco local em vez do iCloud Drive.",
            tradeoff: "Você escolhe o iCloud à mão quando quiser sincronizar um documento.",
            category: .network,
            risk: .safe,
            actions: [write("NSGlobalDomain", "NSDocumentSaveNewDocumentsToCloud", .bool(false))]
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
            id: "safari-preload-top-hit",
            title: "Não pré-carregar o primeiro resultado no Safari",
            summary: "O Safari deixa de baixar em segundo plano a página que ele acha que "
                + "você vai abrir.",
            tradeoff: "O primeiro resultado abre um pouco mais devagar; em troca, nenhuma "
                + "página é baixada sem você pedir.",
            category: .privacy,
            risk: .safe,
            effect: .needsLogout,
            recommendedForOCLP: true,
            actions: [write("com.apple.Safari", "PreloadTopHit", .bool(false))]
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

    // MARK: - Notificações e alertas

    static let notifications: [Tweak] = [
        Tweak(
            id: "notification-banner-time",
            title: "Encurtar duração dos banners",
            summary: "Os banners somem em cerca de um segundo, em vez de cinco.",
            tradeoff: "Você tem menos tempo para ler ou clicar num banner antes de ele sumir. "
                + "As notificações continuam guardadas na Central.",
            category: .notifications,
            risk: .safe,
            effect: .needsLogout,
            actions: [write("com.apple.notificationcenterui", "BannerTime", .int(1))]
        ),
        Tweak(
            id: "tips-notifications",
            title: "Desativar Dicas do macOS",
            summary: "Para o tipsd, que roda em segundo plano só para sugerir dicas do sistema.",
            tradeoff: "O app Dicas para de avisar sobre recursos do macOS.",
            category: .notifications,
            risk: .safe,
            effect: .needsReboot,
            recommendedForOCLP: true,
            actions: [launchAgentDisabled("com.apple.tipsd")]
        ),
        Tweak(
            id: "automatic-updates",
            title: "Desativar busca automática por atualizações",
            summary: "O macOS para de checar e baixar atualizações sozinho em segundo plano. "
                + "Você continua podendo atualizar à mão quando quiser.",
            tradeoff: "Você precisa checar atualizações manualmente em Ajustes do Sistema. "
                + "Num Mac com OCLP isso costuma ser desejável: uma atualização aplicada sem "
                + "preparo remove os root patches e pode deixar o sistema sem vídeo ou sem Wi-Fi.",
            category: .notifications,
            risk: .moderate,
            recommendedForOCLP: true,
            actions: [
                rootWrite(
                    "/Library/Preferences/com.apple.SoftwareUpdate", "AutomaticCheckEnabled",
                    optimized: "false", original: "true", appliedOutput: "0"
                ),
                rootWrite(
                    "/Library/Preferences/com.apple.SoftwareUpdate", "AutomaticDownload",
                    optimized: "false", original: "true", appliedOutput: "0"
                ),
            ]
        ),
        Tweak(
            id: "notification-center",
            title: "Desativar a Central de Notificações",
            summary: "Encerra o processo da Central. Nenhuma notificação de nenhum app aparece.",
            tradeoff: "Você deixa de receber qualquer alerta — inclusive de mensagens, "
                + "calendário e backups falhando. Só ative se quiser mesmo silêncio total.",
            category: .notifications,
            risk: .advanced,
            effect: .needsReboot,
            actions: [launchAgentDisabled("com.apple.notificationcenterui")]
        ),
    ]

    // MARK: - Bateria

    static let battery: [Tweak] = [
        Tweak(
            id: "proximity-wake",
            title: "Não acordar por aproximação",
            summary: "O Mac deixa de acordar sozinho quando um iPhone ou Apple Watch chega perto.",
            tradeoff: "Desbloquear com o Apple Watch pode exigir abrir a tampa primeiro.",
            category: .battery,
            risk: .safe,
            recommendedForOCLP: true,
            actions: [pmset("proximitywake", optimized: "0", original: "1")]
        ),
        Tweak(
            id: "wake-on-network",
            title: "Não acordar por acesso de rede",
            summary: "Impede que pacotes na rede tirem o Mac do sono várias vezes por noite.",
            tradeoff: "Wake on LAN e acesso remoto com o Mac dormindo param de funcionar.",
            category: .battery,
            risk: .moderate,
            recommendedForOCLP: true,
            actions: [pmset("womp", optimized: "0", original: "1")]
        ),
        Tweak(
            id: "tty-keep-awake",
            title: "Não ficar acordado por sessão de terminal",
            summary: "Uma sessão SSH ou terminal aberta deixa de impedir o Mac de dormir.",
            tradeoff: "Um comando longo rodando no terminal pode ser interrompido pelo sono. "
                + "Não ative se você usa este Mac como servidor por SSH.",
            category: .battery,
            risk: .moderate,
            actions: [pmset("ttyskeepawake", optimized: "0", original: "1")]
        ),
        Tweak(
            id: "tcp-keepalive",
            title: "Desligar rede durante o sono",
            summary: "O Mac para de manter conexões vivas enquanto dorme. É o ajuste de bateria "
                + "com maior efeito em quem fecha a tampa e só volta horas depois.",
            tradeoff: "Com a tampa fechada, o Buscar (Find My) não localiza o Mac e mensagens, "
                + "e-mails e chamadas não chegam até você acordá-lo.",
            category: .battery,
            risk: .advanced,
            recommendedForOCLP: true,
            actions: [pmset("tcpkeepalive", optimized: "0", original: "1")]
        ),
    ]

    // MARK: - Trackpad e teclado

    static let trackpad: [Tweak] = [
        Tweak(
            id: "force-click",
            title: "Desativar Force Touch",
            summary: "O clique forte deixa de disparar consulta de dicionário e pré-visualizações.",
            tradeoff: "Perde o clique forte; o clique normal e os gestos continuam iguais.",
            category: .trackpad,
            risk: .safe,
            effect: .needsLogout,
            recommendedForOCLP: true,
            actions: [
                write("com.apple.AppleMultitouchTrackpad", "ForceSuppressed", .bool(true)),
                write("com.apple.driver.AppleBluetoothMultitouch.trackpad",
                      "ForceSuppressed", .bool(true)),
            ]
        ),
        Tweak(
            id: "trackpad-gestures",
            title: "Desativar gestos de Launchpad e Mesa",
            summary: "Desliga os gestos de vários dedos para Launchpad, Mostrar Mesa e "
                + "Exposé de aplicativo.",
            tradeoff: "Esses gestos param de responder. Mission Control e troca de Spaces "
                + "continuam funcionando.",
            category: .trackpad,
            risk: .safe,
            effect: .restartsDock,
            recommendedForOCLP: true,
            actions: [
                write("com.apple.dock", "showLaunchpadGestureEnabled", .bool(false)),
                write("com.apple.dock", "showDesktopGestureEnabled", .bool(false)),
                write("com.apple.dock", "showAppExposeGestureEnabled", .bool(false)),
            ]
        ),
        Tweak(
            id: "text-substitutions",
            title: "Desativar correção e substituição automáticas",
            summary: "Desliga correção ortográfica, maiúscula automática e troca de aspas e "
                + "travessões enquanto você digita.",
            tradeoff: "Você digita sem correção automática — em português, isso normalmente "
                + "atrapalha menos do que ajuda.",
            category: .trackpad,
            risk: .safe,
            effect: .needsLogout,
            actions: [
                write("NSGlobalDomain", "NSAutomaticSpellingCorrectionEnabled", .bool(false)),
                write("NSGlobalDomain", "NSAutomaticCapitalizationEnabled", .bool(false)),
                write("NSGlobalDomain", "NSAutomaticQuoteSubstitutionEnabled", .bool(false)),
                write("NSGlobalDomain", "NSAutomaticDashSubstitutionEnabled", .bool(false)),
            ]
        ),
        Tweak(
            id: "key-repeat-speed",
            title: "Acelerar repetição de teclas",
            summary: "Deixa a tecla segurada repetir bem mais rápido e começar antes.",
            tradeoff: "Nenhum recurso é perdido, mas segurar uma tecla passa a repetir "
                + "muito rápido, o que leva algumas horas de costume.",
            category: .trackpad,
            risk: .safe,
            effect: .needsLogout,
            actions: [
                write("NSGlobalDomain", "KeyRepeat", .int(2)),
                write("NSGlobalDomain", "InitialKeyRepeat", .int(15)),
            ]
        ),
        Tweak(
            id: "dictation",
            title: "Desativar Ditado",
            summary: "Desliga o ditado por voz e o daemon que ele mantém em segundo plano.",
            tradeoff: "O ditado para de funcionar. Em português também some o atalho de "
                + "duplo toque na tecla de função.",
            category: .trackpad,
            risk: .moderate,
            effect: .needsLogout,
            recommendedForOCLP: true,
            actions: [write("com.apple.HIToolbox", "AppleDictationAutoEnable", .int(0))]
        ),
        Tweak(
            id: "press-and-hold",
            title: "Trocar menu de acentos por repetição de tecla",
            summary: "Segurar uma tecla passa a repetir o caractere em vez de abrir o menu "
                + "de acentos.",
            tradeoff: "Você perde o menu de acentuação ao segurar a tecla — em português "
                + "isso costuma ser ruim. Acentuação pelo teclado ABNT ou por tecla morta "
                + "continua normal.",
            category: .trackpad,
            risk: .moderate,
            effect: .needsLogout,
            actions: [write("NSGlobalDomain", "ApplePressAndHoldEnabled", .bool(false))]
        ),
    ]
}
