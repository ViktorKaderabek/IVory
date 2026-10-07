import SwiftUI

/// The one long wait: four rows that tick off, the download with its megabytes, and the phone beside it
/// showing the same progress.
struct InstallScreen: View {
    @ObservedObject var flow: SetupFlow
    @ObservedObject var prep: SetupPrep
    @ObservedObject var install: HelperInstall

    fileprivate enum Row { case todo, now, done, failed }
    /// What the download row counts towards; run.sh --prepare fetches about this much.
    private static let downloadMB = 250.0

    private var phoneName: String { flow.device?.name ?? "iPhone" }
    private var finished: Bool { install.state == .done || flow.done.contains(.install) }

    /// Why it stopped; Try again sits in the footer.
    private var failure: String? {
        if case .failed(let why) = prep.state { return why }
        return install.failure
    }

    var body: some View {
        GeometryReader { geo in
            let w = max(0, geo.size.width - 48 - 56 - 40)
            HStack(spacing: 40) {
                CenteredColumn { checklist.frame(maxWidth: 520, alignment: .leading) }
                    .frame(width: w * 4 / 7)
                phone.frame(width: w * 3 / 7)
            }
            .padding(.leading, 48)
            .padding(.trailing, 56)
            .frame(maxHeight: .infinity)
        }
    }

    private var checklist: some View {
        VStack(alignment: .leading, spacing: 26) {
            SetupHeading(title: finished ? tr("IVory je připravené", "IVory is ready") : flow.screen.title,
                         lead: finished ? tr("Pomocná aplikace je nainstalovaná v \(phoneName).", "Helper app installed on \(phoneName).")
                             : failure ?? flow.screen.lead)
            VStack(spacing: 0) {
                InstallRow(title: tr("Stáhnout nástroje", "Download tools"), state: downloadState, meta: downloadMeta,
                           bar: downloadState == .now ? prep.fraction : nil)
                InstallRow(title: tr("Připravit pomocnou aplikaci", "Prepare the helper app"), state: prepareState, meta: "")
                InstallRow(title: tr("Podepsat ji tvým Apple ID", "Sign it with your Apple ID"), state: partState(.sign),
                           meta: flow.appleIdShown)
                InstallRow(title: tr("Nainstalovat ji do iPhonu", "Install it on your iPhone"), state: partState(.phone),
                           meta: phoneName, last: true)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 18)
            .background(SW.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(SW.border, lineWidth: 1))
            HStack(spacing: 8) {
                Image(systemName: "cable.connector").font(.system(size: 13))
                Text(tr("Nech iPhone připojený. Mac můžeš mezitím používat.", "Keep the iPhone connected. You can use the Mac meanwhile."))
            }
            .foregroundStyle(SW.muted)
        }
    }

    private var phone: some View {
        FitToSpace(size: CGSize(width: 260, height: 542)) {
            VStack(spacing: 14) {
                PhoneCaption(text: tr("Nech ho připojený, nesahej na něj", "Keep it connected, no need to touch it"),
                             color: SW.muted, symbol: "cable.connector")
                SetupPhone(art: .homeBlur, size: .pair) {
                    VStack {
                        Spacer()
                        InstallBanner(text: bannerText, progress: overall)
                    }
                }
            }
            .modifier(PhoneRise(delay: 0.08))
        }
    }

    // MARK: state

    private var downloadMeta: String {
        let total = Int(Self.downloadMB)
        return downloadState == .done ? "\(total) MB" : "\(Int(prep.fraction * Self.downloadMB)) \(tr("z", "of")) \(total) MB"
    }

    private var bannerText: String {
        if finished { return tr("Pomocník IVory nainstalován", "IVory helper installed") }
        if partState(.phone) == .now { return tr("Instaluju pomocníka IVory…", "Installing IVory helper…") }
        return tr("Čekám na IVory…", "Waiting for IVory…")
    }

    private var downloadState: Row {
        switch prep.state {
        case .done: return .done
        case .failed: return .failed
        case .running, .idle: return finished ? .done : .now
        }
    }

    /// Ready to sign once the tools are there; it waits (not spins) while the phone or the Apple ID is missing.
    private var prepareState: Row {
        if finished { return .done }
        guard prep.state == .done else { return .todo }
        if install.state != .idle { return .done }
        return flow.device != nil && flow.paired ? .now : .todo
    }

    private func partState(_ part: HelperInstall.Part) -> Row {
        switch install.state {
        case .done: return .done
        case .running(let p): return p == part ? .now : (install.isDone(part) ? .done : .todo)
        case .failed(let p, _): return install.isDone(part) ? .done : (p == part ? .failed : .todo)
        case .idle: return finished ? .done : .todo
        }
    }

    private var overall: Double {
        let rows = [downloadState, prepareState, partState(.sign), partState(.phone)]
        let done = Double(rows.filter { $0 == .done }.count)
        return min(1, (done + (downloadState == .now ? prep.fraction : 0)) / 4)
    }
}

/// One row of the checklist: its mark, what it does, a figure on the right, and a bar while downloading.
private struct InstallRow: View {
    let title: String
    let state: InstallScreen.Row
    let meta: String
    var bar: Double? = nil
    var last = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Group {
                    switch state {
                    case .done: StepDot(state: .done)
                    case .failed: StepDot(state: .failed)
                    case .now: SetupSpinner(size: 14)
                    case .todo: Circle().strokeBorder(SW.track, lineWidth: 1.5).frame(width: 16, height: 16)
                    }
                }
                .frame(width: 20, height: 20)
                .modifier(SetupPop(on: state == .done, duration: 0.42))
                Text(title).font(.system(size: 14, weight: .medium))
                Spacer(minLength: 8)
                Text(meta).font(.system(size: 12).monospacedDigit()).foregroundStyle(SW.muted).lineLimit(1)
                    .contentTransition(.numericText())
            }
            .foregroundStyle(state == .todo ? SW.muted : SW.text)
            if let bar {
                ProgressCapsule(value: bar).padding(.leading, 32)
            }
        }
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) {
            if !last { Rectangle().fill(SW.border).frame(height: 1) }
        }
        .animation(.easeOut(duration: 0.3), value: state)
    }
}

/// The install notification drawn over the phone's home screen.
private struct InstallBanner: View {
    let text: String
    let progress: Double

    var body: some View {
        HStack(spacing: 10) {
            AppIconView()
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                Text(text).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                ProgressCapsule(value: progress, track: .oklch(0.88, 0.008, 280), fill: .oklch(0.6, 0.2, 260))
            }
        }
        .foregroundStyle(Color.oklch(0.2, 0.02, 278))
        .padding(12)
        .background(Color(nsColor: .oklch(0.97, 0.004, 280, alpha: 0.94)), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 14)
        .padding(.bottom, 44)
    }
}
