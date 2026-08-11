import SwiftUI
import AppKit
import MacFastKit

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var selection: Category?

    var body: some View {
        NavigationView {
            sidebar
            detail
        }
        .frame(minWidth: 900, minHeight: 560)
        .onAppear { model.load() }
    }

    private var sidebar: some View {
        List {
            Section(header: Text("Categorias")) {
                ForEach(model.groups, id: \.category) { group in
                    // Big Sur has no NavigationLink(value:), so selection is
                    // driven by an explicit tag binding.
                    NavigationLink(
                        destination: detail(for: group.category),
                        tag: group.category,
                        selection: $selection
                    ) {
                        Label(group.category.localizedName, systemImage: icon(for: group.category))
                    }
                }
            }
        }
        .listStyle(SidebarListStyle())
        .frame(minWidth: 220)
    }

    @ViewBuilder
    private var detail: some View {
        if let selection {
            detail(for: selection)
        } else {
            OverviewView(model: model)
        }
    }

    private func detail(for category: Category) -> some View {
        let tweaks = model.groups.first { $0.category == category }?.tweaks ?? []
        return TweakListView(model: model, category: category, tweaks: tweaks)
    }

    private func icon(for category: Category) -> String {
        switch category {
        case .interface: return "macwindow"
        case .animations: return "wand.and.rays"
        case .indexing: return "magnifyingglass"
        case .background: return "gearshape.2"
        case .power: return "bolt"
        case .network: return "antenna.radiowaves.left.and.right"
        case .privacy: return "hand.raised"
        }
    }
}

struct OverviewView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("MacFast")
                    .font(.largeTitle).bold()
                Text("Desative recursos do macOS que você não usa e recupere fluidez.")
                    .foregroundColor(.secondary)

                if let info = model.systemInfo {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("macOS \(info.osVersion) · \(info.modelIdentifier)")
                            if info.isRunningOCLP {
                                Label(
                                    "OpenCore Legacy Patcher detectado. O preset OCLP foca no que "
                                        + "mais pesa em Macs sem suporte gráfico nativo.",
                                    systemImage: "sparkles"
                                )
                                .foregroundColor(.accentColor)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                    }
                }

                Text("Presets").font(.headline)
                ForEach(Preset.allCases, id: \.self) { preset in
                    GroupBox {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(preset.localizedName).bold()
                                Text(preset.localizedSummary)
                                    .font(.callout)
                                    .foregroundColor(.secondary)
                                Text("\(preset.tweaks().count) ajustes")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Button("Aplicar") { model.apply(preset: preset) }
                                .disabled(model.isBusy)
                        }
                        .padding(6)
                    }
                }

                Divider()

                Button("Reverter tudo ao estado original") { model.revertEverything() }
                    .disabled(model.isBusy)

                Text("O MacFast nunca desativa SIP, Gatekeeper, XProtect ou FileVault. "
                    + "Reduzir a segurança do sistema não deixa o Mac mais rápido e, em máquinas "
                    + "com OCLP, atrapalha os patches do próprio OCLP.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay(StatusBanner(model: model), alignment: .bottom)
    }
}

struct TweakListView: View {
    @ObservedObject var model: AppModel
    let category: Category
    let tweaks: [Tweak]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(category.localizedName)
                    .font(.title).bold()
                    .padding(.bottom, 4)

                ForEach(tweaks) { tweak in
                    TweakRow(model: model, tweak: tweak)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay(StatusBanner(model: model), alignment: .bottom)
    }
}

struct TweakRow: View {
    @ObservedObject var model: AppModel
    let tweak: Tweak

    private var state: TweakState { model.state(of: tweak) }

    var body: some View {
        GroupBox {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(tweak.title).bold()
                        Badge(text: tweak.risk.localizedName, color: color(for: tweak.risk))
                        if tweak.recommendedForOCLP {
                            Badge(text: "OCLP", color: .accentColor)
                        }
                        if tweak.effect != .immediate {
                            Badge(text: tweak.effect.localizedName, color: .secondary)
                        }
                    }
                    Text(tweak.summary)
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Abre mão de: \(tweak.tradeoff)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    // A half-applied or unreadable tweak must not look like a
                    // plain "off", otherwise the switch lies about the system.
                    if state == .partial || state == .unknown {
                        Text(state == .partial
                             ? "Estado parcial: só parte deste ajuste está ativa."
                             : "Não foi possível ler o estado atual.")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }
                Spacer(minLength: 12)
                Toggle("", isOn: Binding(
                    get: { state == .applied },
                    set: { _ in model.toggle(tweak) }
                ))
                .labelsHidden()
                .disabled(model.isBusy)
            }
            .padding(8)
        }
    }

    private func color(for risk: Risk) -> Color {
        switch risk {
        case .safe: return .green
        case .moderate: return .orange
        case .advanced: return .red
        }
    }
}

struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundColor(color)
            .cornerRadius(4)
    }
}

struct StatusBanner: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 6) {
            if model.isBusy {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.6)
                    Text("Aplicando…")
                }
            }
            if let message = model.statusMessage {
                Label(message, systemImage: "info.circle")
            }
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundColor(.red)
            }
        }
        .font(.callout)
        .padding(model.isBusy || model.statusMessage != nil || model.errorMessage != nil ? 10 : 0)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.95))
        .cornerRadius(8)
        .padding(.bottom, 12)
    }
}
