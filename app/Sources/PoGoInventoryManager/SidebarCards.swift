import AppKit
import SwiftUI

// The cards at the bottom of the sidebar: the run control, and the banner that offers a new version.

/// What the phone is doing and the one button that matters. It sits at the bottom of the rail on every
/// page, so a run can be started or stopped without going back to Run first.
struct RunControlCard: View {
    /// On the Run screen the big dial in the band is the one place to start from, so the rail only says
    /// what the phone is doing.
    let showsButton: Bool

    @EnvironmentObject private var store: ConfigStore
    @EnvironmentObject private var runner: Runner
    @ObservedObject private var phone = ConnectedPhone.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var now = Date()

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.raise)
                    .frame(width: 30, height: 30)
                    .overlay {
                        Image(systemName: "iphone")
                            .font(.system(size: 16))
                            .foregroundStyle(Theme.muted)
                    }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        PulsingCircle(fill: dot, glow: runner.isRunning ? dot : nil, glowRadius: 4,
                                      blinkTo: 0.3, duration: 0.7,
                                      animate: runner.isRunning && !reduceMotion)
                            .frame(width: 6, height: 6)
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.muted)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }

            if runner.isRunning {
                progress
                if showsButton { stopButton }
            } else if showsButton {
                startButton
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border, lineWidth: 1)
        }
        .ticking(every: 1, while: runner.isRunning) { now = $0 }
        .onAppear { phone.look() }
        .onChange(of: runner.isRunning) { _, _ in phone.look() }
        .animation(.easeOut(duration: 0.2), value: runner.isRunning)
        .entrance(0.3, rise: 10)
    }

    private var title: String {
        if runner.isRunning {
            let step = Runner.Step(rawValue: runner.stats.phase)?.phaseTitle
            return tr("Běží", "Running") + (step.map { " · \($0)" } ?? "")
        }
        if let end = runner.finishedAt, let start = runner.startedAt, runner.outcome != nil {
            return tr("Hotovo", "Done") + " · " + short(end.timeIntervalSince(start))
        }
        return phone.current(udid: store.config.udid)?.name ?? "iPhone"
    }

    private var subtitle: String {
        if runner.isRunning { return tr("Nesahej na telefon", "Don't touch the phone") }
        if let device = phone.current(udid: store.config.udid), runner.finishedAt == nil {
            return tr("Připojený · iOS \(device.os)", "Connected · iOS \(device.os)")
        }
        if let end = runner.finishedAt {
            let f = DateFormatter()
            f.locale = L10n.locale
            f.dateFormat = Calendar.current.isDateInToday(end) ? tr("'dnes' H:mm", "'Today' h:mm a") : tr("d. M. H:mm", "MMM d, h:mm a")
            return f.string(from: end)
        }
        return tr("Připoj ho a odemkni", "Connect and unlock it")
    }

    private var dot: Color {
        if runner.isRunning || runner.outcome == .done { return Theme.green }
        return phone.current(udid: store.config.udid) != nil ? Theme.green : Theme.muted
    }

    private var progress: some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                Text(tr("Krok \(max(1, runner.stats.phase)) z 6", "Step \(max(1, runner.stats.phase)) of 6")
                     + (runner.phaseProgress.map { " · \(Int($0 * 100)) %" } ?? ""))
                Spacer(minLength: 4)
                if let start = runner.startedAt {
                    Text(long(now.timeIntervalSince(start)))
                }
            }
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(Theme.muted)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.track)
                    Capsule()
                        .fill(Theme.progress)
                        .frame(width: geo.size.width * CGFloat(fraction))
                }
            }
            .frame(height: 4)
            .animation(.easeOut(duration: 0.4), value: fraction)
        }
    }

    /// How far the whole run is: finished steps plus the progress inside the current one.
    private var fraction: Double { runner.runProgress }

    private var startButton: some View {
        Button {
            guard !runner.isRunning, store.config.steps.count > 0 else { return }
            SetupFlow.shared.beforeStart {
                store.prepareRun()
                runner.start(steps: store.config.steps, fresh: false)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: runner.outcome == nil ? "play.fill" : "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                Text(runner.outcome == nil ? tr("Spustit", "Start") : tr("Spustit znovu", "Run again"))
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(Theme.accentInk)
            .frame(maxWidth: .infinity)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.accent, lineWidth: 1))
            .shadow(color: Theme.accent.opacity(0.25), radius: 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(store.config.steps.count == 0)
        .opacity(store.config.steps.count == 0 ? 0.5 : 1)
    }

    private var stopButton: some View {
        Button(action: runner.stop) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2).fill(Theme.red).frame(width: 10, height: 10)
                Text(tr("Zastavit", "Stop")).font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(Theme.red)
            .frame(maxWidth: .infinity)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.red, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func long(_ s: TimeInterval) -> String {
        let t = max(0, Int(s))
        return String(format: "%d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60)
    }

    private func short(_ s: TimeInterval) -> String {
        let t = max(0, Int(s))
        return t < 60 ? tr("\(t) s", "\(t)s") : tr("\(t / 60) min \(t % 60) s", "\(t / 60) min \(t % 60)s")
    }
}

/// The "a new version is ready" card. In the rail above the run controls, where it is out of the content's way.
struct UpdateCard: View {
    @ObservedObject private var updater = Updater.shared

    /// Appearance check: IVORY_BANNER=1 shows the card with a sample release.
    private var shownRelease: Updater.Release? {
        if case .ready(let release, _) = updater.state { return release }
        #if DEBUG
        if ProcessInfo.processInfo.environment["IVORY_BANNER"] == "1" { return Updater.sampleRelease }
        #endif
        return nil
    }

    var body: some View {
        if let release = shownRelease, !updater.bannerHidden {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.green)
                    Text("\(Theme.appName) \(release.version)" + tr(" je připravená", " is ready"))
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Button { updater.bannerHidden = true } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.muted)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Text(tr("Restart zabere pár vteřin. Nastavení i paměť zůstanou.",
                        "Restarting takes a few seconds. Your settings and memory stay."))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Button { updater.installAndRestart() } label: {
                        Text(tr("Restartovat", "Restart"))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.accentInk)
                            .frame(maxWidth: .infinity)
                            .frame(height: 28)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(Theme.accent, lineWidth: 1))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Button { NSWorkspace.shared.open(release.notesURL) } label: {
                        Text(tr("Co je nového", "What's new"))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.accentInk)
                            .padding(.horizontal, 8)
                            .frame(height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.surface))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border, lineWidth: 1)
            }
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }
}
