import AppKit
import SwiftUI

/// Banner nad hero kartou: nová verze, stahování, připraveno k restartu, chyba.
struct UpdateBanner: View {
    @ObservedObject private var updater = Updater.shared
    @EnvironmentObject private var runner: Runner

    private enum Kind { case available, downloading(Double), ready, failed(String) }

    private var kind: Kind? {
        guard !updater.bannerHidden else { return nil }
        switch updater.state {
        case .available: return .available
        case .downloading(_, let p): return .downloading(p)
        case .ready: return .ready
        case .failed(let message, let r) where r != nil && updater.showErrorBanner: return .failed(message)
        default: return nil
        }
    }

    var body: some View {
        if let kind, let release = updater.release {
            content(kind, release)
                .padding(.leading, 14)
                .padding(.trailing, 10)
                .padding(.vertical, 11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(border(kind)))
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityElement(children: .contain)
        }
    }

    @ViewBuilder
    private func content(_ kind: Kind, _ r: Updater.Release) -> some View {
        HStack(spacing: 12) {
            icon(kind)
            VStack(alignment: .leading, spacing: 3) {
                Text(title(kind, r)).font(.system(size: 14, weight: .semibold))
                if case .downloading(let p) = kind {
                    HStack(spacing: 10) {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Theme.track)
                                Capsule().fill(Theme.progress).frame(width: max(6, geo.size.width * p))
                            }
                        }
                        .frame(width: 220, height: 6)
                        Text(percentText(Int((p * 100).rounded())))
                            .font(.system(size: 12)).monospacedDigit().foregroundStyle(Theme.muted)
                            .contentTransition(.numericText())
                        Text(tr("Mezitím můžeš dál pracovat.", "You can keep working."))
                            .font(.system(size: 12)).foregroundStyle(Theme.muted)
                    }
                    .animation(.easeOut(duration: 0.2), value: p)
                } else {
                    Text(subtitle(kind, r)).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            buttons(kind, r)
            if case .downloading = kind {} else {
                Button { withAnimation(.snappy) { updater.bannerHidden = true } } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(GhostButtonStyle(color: Theme.muted, hover: Theme.raise, height: 26))
                .help(tr("Skrýt do příštího spuštění", "Hide until the next start"))
                .accessibilityLabel(tr("Zavřít", "Close"))
            }
        }
    }

    private func icon(_ kind: Kind) -> some View {
        let (symbol, color, bg): (String, Color, Color) = {
            switch kind {
            case .available: return ("sparkles", Theme.accentInk, Theme.tint)
            case .downloading: return ("arrow.down", Theme.accentInk, Theme.tint)
            case .ready: return ("checkmark", Theme.green, Theme.greenTint)
            case .failed: return ("exclamationmark.triangle.fill", Theme.red, Theme.redTint)
            }
        }()
        return Image(systemName: symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 34, height: 34)
            .background(bg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityHidden(true)
    }

    private func border(_ kind: Kind) -> Color {
        switch kind {
        case .ready: return Theme.green.opacity(0.45)
        case .failed: return Theme.red.opacity(0.45)
        default: return Theme.accent.opacity(0.45)
        }
    }

    private func title(_ kind: Kind, _ r: Updater.Release) -> String {
        switch kind {
        case .available: return tr("Je tu IVory \(r.version)", "IVory \(r.version) is available")
        case .downloading: return tr("Stahuji IVory \(r.version)…", "Downloading IVory \(r.version)…")
        case .ready: return tr("IVory \(r.version) je připravená", "IVory \(r.version) is ready")
        case .failed: return tr("Aktualizace se nepovedla", "The update failed")
        }
    }

    private func subtitle(_ kind: Kind, _ r: Updater.Release) -> String {
        switch kind {
        case .available: return tr("Máš verzi \(Updater.currentVersion).", "You have \(Updater.currentVersion).")
        case .ready:
            return runner.isRunning
                ? tr("Restart počká, až třídění doběhne.", "The restart waits until sorting is done.")
                : tr("Restart trvá pár vteřin. Nastavení i paměť zůstanou.", "Restarting takes a few seconds. Your settings and memory stay.")
        case .failed(let message): return message
        case .downloading: return ""
        }
    }

    @ViewBuilder
    private func buttons(_ kind: Kind, _ r: Updater.Release) -> some View {
        HStack(spacing: 6) {
            switch kind {
            case .available:
                Button(tr("Co je nového", "What's new")) { NSWorkspace.shared.open(r.notesURL) }
                    .buttonStyle(GhostButtonStyle(height: 30))
                Button(tr("Stáhnout", "Download")) { updater.download() }
                    .buttonStyle(OutlineButtonStyle(height: 30))
            case .downloading:
                Button(tr("Zrušit", "Cancel")) { updater.cancelDownload() }
                    .buttonStyle(GhostButtonStyle(color: Theme.muted, hover: Theme.raise, height: 30))
            case .ready:
                Button(tr("Co je nového", "What's new")) { NSWorkspace.shared.open(r.notesURL) }
                    .buttonStyle(GhostButtonStyle(height: 30))
                Button(tr("Restartovat", "Restart")) { updater.installAndRestart() }
                    .buttonStyle(FilledButtonStyle())
                    .disabled(runner.isRunning)
                    .opacity(runner.isRunning ? 0.45 : 1)
                    .help(runner.isRunning ? tr("Během třídění restartovat nejde.", "You can't restart while sorting.") : "")
            case .failed:
                Button(tr("Zkusit znovu", "Try again")) { updater.download() }
                    .buttonStyle(OutlineButtonStyle(height: 30))
            }
        }
    }
}

/// Karta nahoře v nastavení: jazyk a aktualizace. Jazyk jde měnit i během běhu.
struct LanguageUpdateCard: View {
    @EnvironmentObject private var store: ConfigStore
    @EnvironmentObject private var runner: Runner
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                SoftIcon(symbol: "globe", size: 26, radius: 8)
                Text(tr("Jazyk", "Language")).font(.system(size: 14, weight: .medium))
                Spacer()
                Picker("", selection: Binding(get: { store.config.language },
                                              set: { LanguageSwitch.change(to: $0, store: store) })) {
                    ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .padding(12)

            Rectangle().fill(Theme.border).frame(height: 1)

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 10) {
                    SoftIcon(symbol: "arrow.triangle.2.circlepath", size: 26, radius: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tr("Aktualizace", "Updates")).font(.system(size: 14, weight: .medium))
                        statusLine
                    }
                    Spacer(minLength: 6)
                    action
                }
                HStack {
                    Text(tr("Kontrolovat automaticky", "Check automatically")).font(.system(size: 13))
                    Spacer()
                    Toggle("", isOn: $store.config.checkUpdates).toggleStyle(.switch).controlSize(.small).labelsHidden()
                }
                .padding(.leading, 36)
            }
            .padding(12)
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.border))
    }

    @ViewBuilder private var statusLine: some View {
        let (text, color): (String, Color) = {
            let v = tr("Verze \(Updater.currentVersion)", "Version \(Updater.currentVersion)")
            switch updater.state {
            case .checking: return (v + tr(" · kontroluji…", " · checking…"), Theme.muted)
            case .upToDate: return (v + tr(" · máš nejnovější", " · up to date"), Theme.muted)
            case .available(let r): return (tr("K dispozici verze \(r.version)", "Version \(r.version) is available"), Theme.accentInk)
            case .downloading(let r, let p): return (tr("Stahuji \(r.version) · ", "Downloading \(r.version) · ") + percentText(Int(p * 100)), Theme.accentInk)
            case .ready(let r, _): return (tr("Verze \(r.version) čeká na restart", "Version \(r.version) is waiting for a restart"), Theme.green)
            case .failed(let m, _): return (m, Theme.red)
            case .idle: return (v, Theme.muted)
            }
        }()
        Text(text).font(.system(size: 12)).foregroundStyle(color).lineLimit(2).fixedSize(horizontal: false, vertical: true)
        if let last = updater.lastCheck, !isBusy {
            Text(tr("Naposledy ", "Last checked ") + Self.relative(last))
                .font(.system(size: 11)).foregroundStyle(Theme.muted)
        }
    }

    private var isBusy: Bool {
        switch updater.state {
        case .checking, .downloading: return true
        default: return false
        }
    }

    @ViewBuilder private var action: some View {
        switch updater.state {
        case .checking:
            ProgressView().controlSize(.small)
        case .available:
            Button(tr("Stáhnout", "Download")) { updater.bannerHidden = false; updater.download() }
                .buttonStyle(OutlineButtonStyle(height: 28))
        case .downloading:
            Button(tr("Zrušit", "Cancel")) { updater.cancelDownload() }
                .buttonStyle(GhostButtonStyle(color: Theme.muted, hover: Theme.raise))
        case .ready:
            Button(tr("Restartovat", "Restart")) { updater.installAndRestart() }
                .buttonStyle(OutlineButtonStyle(height: 28))
                .disabled(runner.isRunning)
        case .failed(_, .some):
            Button(tr("Zkusit znovu", "Try again")) { updater.bannerHidden = false; updater.download() }
                .buttonStyle(OutlineButtonStyle(height: 28))
        default:
            Button(tr("Zkontrolovat", "Check now")) { updater.check(manual: true) }
                .buttonStyle(OutlineButtonStyle(color: Theme.text, stroke: Theme.border, hover: Theme.raise, height: 28))
        }
    }

    private static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = L10n.locale
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: Date())
    }
}
