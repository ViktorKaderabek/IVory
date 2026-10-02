import SwiftUI

enum Page: String, CaseIterable, Identifiable, Hashable {
    case run, duplicates, ivTags, device, advanced

    var id: Self { self }

    var title: String {
        switch self {
        case .run: "Úklid boxu"
        case .duplicates: "Duplicity"
        case .ivTags: "IV tagy"
        case .device: "iPhone"
        case .advanced: "Pokročilé"
        }
    }

    var symbol: String {
        switch self {
        case .run: "sparkles"
        case .duplicates: "square.on.square"
        case .ivTags: "tag"
        case .device: "iphone.gen3"
        case .advanced: "slider.horizontal.3"
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var runner: Runner
    @State private var page: Page? = .run

    var body: some View {
        NavigationSplitView {
            List(selection: $page) {
                Section {
                    Label(Page.run.title, systemImage: Page.run.symbol).tag(Page.run)
                }
                Section("Nastavení") {
                    ForEach([Page.duplicates, .ivTags, .device, .advanced]) { p in
                        Label(p.title, systemImage: p.symbol).tag(p)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 210, ideal: 230)
            .safeAreaInset(edge: .bottom) {
                StatusFooter().padding(12)
            }
        } detail: {
            Group {
                switch page ?? .run {
                case .run: DashboardView()
                case .duplicates: DuplicatesSettingsView()
                case .ivTags: IVTagsSettingsView()
                case .device: DeviceSettingsView()
                case .advanced: AdvancedSettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Stav běhu dole v bočním panelu.
struct StatusFooter: View {
    @EnvironmentObject private var runner: Runner

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(color)
                .frame(width: 9, height: 9)
                .shadow(color: color.opacity(0.7), radius: runner.isRunning ? 4 : 0)
            VStack(alignment: .leading, spacing: 1) {
                Text(runner.status).font(.callout.weight(.medium))
                Text(runner.isRunning ? "Nesahej na telefon" : "PoGo Inventory Manager")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var color: Color {
        if runner.isRunning { return .green }
        switch runner.outcome {
        case .failed: return .red
        case .stopped: return .orange
        case .done: return Theme.teal
        case .none: return .secondary
        }
    }
}
