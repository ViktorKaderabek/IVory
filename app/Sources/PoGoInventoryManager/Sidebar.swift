import AppKit
import SwiftUI

/// The pages the sidebar switches between. "Results folder" isn't a page – it opens Finder.
enum Page: String, CaseIterable, Identifiable {
    case run, storage, raids, pvp, powerups, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .run: return tr("Spuštění", "Run")
        case .storage: return tr("Úložiště", "Storage")
        case .raids: return tr("Raidy", "Raids")
        case .pvp: return tr("PvP týmy", "PvP teams")
        case .powerups: return tr("Vylepšení", "Power-ups")
        case .settings: return tr("Nastavení", "Settings")
        }
    }

    var symbol: String {
        switch self {
        case .run: return "play.circle"
        case .storage: return "archivebox"
        case .raids: return "shield"
        case .pvp: return "trophy"
        case .powerups: return "arrow.up.circle"
        case .settings: return "gearshape"
        }
    }
}

/// The window's left rail: who the app is, where to go, and – always within reach, on every page – the
/// state of the iPhone with Start/Stop. The big hero block of the old layout is gone; this is what
/// replaces it.
struct Sidebar: View {
    @Binding var page: Page
    @EnvironmentObject private var runner: Runner
    @ObservedObject private var updater = Updater.shared
    @ObservedObject private var battle = BattleStore.shared

    static let width: CGFloat = 228

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            nav
            Spacer(minLength: 10)
            VStack(spacing: 10) {
                UpdateCard()
                RunControlCard(showsButton: page != .run)
            }
            .padding(10)
        }
        .frame(width: Self.width)
        .background(Theme.chrome)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Theme.border).frame(width: 1)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            AppIconView()
                .frame(width: 30, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 0) {
                Text(Theme.appName)
                    .font(.system(size: 15, weight: .medium))
                Text(tr("Třídička Pokémonů", "Pokémon storage sorter"))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.top, 52)
        .padding(.bottom, 18)
    }

    private var nav: some View {
        VStack(alignment: .leading, spacing: 14) {
            group(nil, [.run, .storage])
            group(tr("Battle", "Battle"), [.raids, .pvp, .powerups])
            VStack(alignment: .leading, spacing: 1) {
                sectionTitle(tr("Aplikace", "App"))
                NavRow(symbol: "folder", label: tr("Složka s výsledky", "Results folder"),
                       selected: false, badge: nil) { runner.openResults() }
                row(.settings)
            }
        }
        .padding(.horizontal, 10)
    }

    private func group(_ title: String?, _ pages: [Page]) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            if let title { sectionTitle(title) }
            ForEach(pages) { row($0) }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.muted)
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
    }

    private func row(_ target: Page) -> some View {
        NavRow(symbol: target.symbol, label: target.title, selected: page == target,
               badge: badge(target), badgeIsLive: target == .run && runner.isRunning) {
            guard page != target else { return }
            withAnimation(.design(0.28)) { page = target }
        }
    }

    /// Run shows how far the current run is; Raids how many bosses are on today.
    private func badge(_ target: Page) -> String? {
        switch target {
        case .run:
            // the whole run, the same number the dial shows – not just the step it is on
            guard runner.isRunning, runner.phaseProgress != nil else { return nil }
            return "\(Int(runner.runProgress * 100))%"
        case .raids:
            let n = battle.bosses.count
            return n > 0 ? "\(n)" : nil
        default:
            return nil
        }
    }
}

struct NavRow: View {
    let symbol: String
    let label: String
    let selected: Bool
    var badge: String?
    var badgeIsLive = false
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 16))
                    .foregroundStyle(selected ? Theme.accent : Theme.muted)
                    .frame(width: 18)
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(selected ? Theme.text : Theme.text.opacity(0.82))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let badge {
                    Text(badge)
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(badgeIsLive ? Theme.green : Theme.muted)
                        .padding(.horizontal, 6)
                        .frame(height: 18)
                        .background(Capsule().fill(badgeIsLive ? Theme.greenTint : Theme.railBadge))
                        .contentTransition(.numericText())
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Theme.railSelected : Theme.railHover.opacity(hovered ? 1 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: hovered)
        .animation(.easeOut(duration: 0.18), value: selected)
    }
}
