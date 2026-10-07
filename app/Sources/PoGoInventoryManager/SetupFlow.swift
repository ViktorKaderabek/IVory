import SwiftUI

/// Where the guide is, what is done, and when it opens and closes (see SetupModel for the rules).
@MainActor
final class SetupFlow: ObservableObject {
    static let shared = SetupFlow()

    @Published private(set) var isOpen = false
    @Published private(set) var screen = SetupScreen.connect
    @Published private(set) var done: Set<SetupStep> = []
    /// A run failed on the phone after the setup was done: "Go through the setup guide?"
    @Published var askGuide = false

    @Published var device: DeviceTools.Device?
    @Published var paired = false
    @Published var developerMode: Bool?

    let prep = SetupPrep()
    let signIn = AppleSignIn()
    let install = HelperInstall()

    /// Opened from Settings just to sign in: no Back, and it closes once that's done.
    private(set) var onlySignIn = false
    /// The Start the guide was opened in front of, run when the guide is finished.
    private var pendingStart: (() -> Void)?

    // read by the phone watching in SetupFlow+Phone
    var poll: Task<Void, Never>?
    var askingPython = false
    var lastAskedPython = Date.distantPast
    var pythonPaired: [String: Bool] = [:]
    var revealing = false
    var revealed: Bool?
    #if DEBUG
    var previewing = false
    #endif

    var step: SetupStep { screen.step }
    var store: ConfigStore? { ConfigStore.current }
    var config: AppConfig { store?.config ?? AppConfig() }

    /// The guide can be closed with Esc only when it was opened on purpose; the first time through it
    /// is the way into the app.
    var canClose: Bool { config.setupDone || onlySignIn }

    /// The Apple ID as the guide shows it (the trust path, the signing row).
    var appleIdShown: String {
        #if DEBUG
        if previewing && config.appleId.isEmpty { return "jan.novak@icloud.com" }
        #endif
        return config.appleId.isEmpty ? "Apple ID" : config.appleId
    }

    // MARK: opening and closing

    /// At launch, once the risk notice is out of the way: the guide until a run has connected.
    func appLaunched() {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        // IVORY_SETUP=live runs the real guide (real phone, real downloads) inside a screenshot session
        if let id = env["IVORY_SETUP"], id != "live" { preview(id); return }
        if env["IVORY_SETUP"] == nil, env["IVORY_PREVIEW"] != nil || env["IVORY_SHOTS"] != nil { return }
        #endif
        guard !isOpen, !config.setupDone else { return }
        resume()
    }

    /// Opens the guide on the first step that isn't done. The steps before the saved one were done then,
    /// except the ticks, which only count while they are still ticked.
    func resume() {
        let saved = SetupStep(rawValue: config.setupStep) ?? .connect
        done = Set(SetupStep.allCases.filter { $0.number < saved.number && !$0.confirmedByHand }).union(confirmed)
        noteSignIn()
        open(at: firstOpen.firstScreen)
    }

    /// The guide once more from step 1 (Settings › Run setup again, or after a failed run). The ticks are
    /// asked again and the helper app is signed afresh – they're what a refused run usually comes down
    /// to; what IVory can check (connection, Developer Mode, the sign-in) passes by itself.
    func rerun() {
        onlySignIn = false
        store?.config.setupConfirmed = []
        store?.config.setupStep = SetupStep.connect.rawValue
        install.reset()
        done = []
        noteSignIn()
        open(at: .connect)
    }

    /// Settings › iPhone › Sign in: the guide's sign-in screen on its own.
    func signInOnly() {
        onlySignIn = true
        open(at: .appleid)
    }

    private func open(at target: SetupScreen) {
        screen = target
        withAnimation(.easeOut(duration: 0.25)) { isOpen = true }
        prep.start()
        startPolling()
        entered()
    }

    func close() {
        stopPolling()
        signIn.reset()
        onlySignIn = false
        pendingStart = nil
        withAnimation(.easeOut(duration: 0.25)) { isOpen = false }
    }

    // MARK: moving

    func go(to target: SetupScreen) {
        guard target != screen else { return }
        withAnimation(.easeOut(duration: 0.34)) { screen = target }
        store?.config.setupStep = target.step.rawValue
        entered()
    }

    /// Continue: on to the next step that isn't done yet.
    func advance() {
        markDone(step)
        noteSignIn()
        if onlySignIn {
            close()
            return
        }
        var next = step.next
        while let n = next, done.contains(n), n != .ready { next = n.next }
        if let next { go(to: next.firstScreen) }
    }

    /// The sidebar: done steps and the one in front can be revisited.
    func canVisit(_ s: SetupStep) -> Bool { !onlySignIn && (done.contains(s) || s == step || s == firstOpen) }

    private var firstOpen: SetupStep { SetupStep.allCases.first { !done.contains($0) } ?? .ready }

    func markDone(_ s: SetupStep) {
        guard !done.contains(s) else { return }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.55)) { _ = done.insert(s) }
    }

    func unmarkDone(_ s: SetupStep) { done.remove(s) }

    /// A valid Apple ID session makes the sign-in step done, wherever the guide is.
    private func noteSignIn() {
        if AppleAccount.isSignedIn(config.appleId) { done.insert(.appleid) }
    }

    /// Whatever a screen needs to get going when it opens.
    private func entered() {
        if screen == .install { startInstallIfReady() }
        evaluate()
    }

    // MARK: the ticks

    private var confirmed: Set<SetupStep> {
        Set(config.setupConfirmed.compactMap(SetupStep.init(rawValue:)))
    }

    func isConfirmed(_ s: SetupStep) -> Bool { confirmed.contains(s) }

    func setConfirmed(_ s: SetupStep, _ on: Bool) {
        var list = Set(config.setupConfirmed)
        if on { list.insert(s.rawValue) } else { list.remove(s.rawValue) }
        store?.config.setupConfirmed = list.sorted()
        if !on { done.remove(s) }
        objectWillChange.send()
    }

    // MARK: Apple ID

    func signInSucceeded(appleId: String) {
        store?.config.appleId = appleId.trimmingCharacters(in: .whitespaces)
        markDone(.appleid)
    }

    // MARK: installing

    func startInstallIfReady() {
        guard screen == .install, prep.state == .done, install.state == .idle,
              let udid = device?.udid, paired, !config.appleId.isEmpty else { return }
        install.start(udid: udid, appleId: config.appleId)
    }

    func prepFinished() { evaluate() }

    func installSucceeded() { markDone(.install) }

    func retryInstall() {
        install.reset()
        prep.start()
        startInstallIfReady()
    }

    // MARK: runs

    /// Start in the main window: until a run has connected, the guide comes first and the Start waits
    /// for its last step.
    func beforeStart(_ start: @escaping () -> Void) {
        #if DEBUG
        if ProcessInfo.processInfo.environment["IVORY_PREVIEW"] != nil { start(); return }
        #endif
        if config.setupDone { start(); return }
        resume()
        pendingStart = start
    }

    /// The last step's Start: the guide closes and the first run begins. The setup counts as done only
    /// once that run has connected to the iPhone (runConnected).
    func finishAndStart() {
        markDone(.ready)
        store?.config.setupStep = SetupStep.ready.rawValue
        store?.save()
        let start = pendingStart ?? defaultStart
        close()
        start()
    }

    private func defaultStart() {
        guard let store, !Runner.shared.isRunning, store.config.steps.count > 0 else { return }
        store.prepareRun()
        Runner.shared.start(steps: store.config.steps, fresh: false)
    }

    /// A run got as far as controlling the iPhone: everything the guide is for works.
    func runConnected() {
        guard let store, !store.config.setupDone else { return }
        store.config.setupDone = true
        store.save()
    }

    /// A run ended before it could control the iPhone. Before the first connected run the guide comes
    /// straight back; afterwards IVory asks whether to go through it.
    func runFailedOnPhone() {
        guard !isOpen else { return }
        if config.setupDone { askGuide = true } else { rerun() }
    }

    #if DEBUG
    func showForPreview(_ target: SetupScreen) {
        screen = target
        isOpen = true
    }
    #endif

    /// When the app quits mid-download.
    func terminate() {
        prep.stop()
        install.reset()
        signIn.cancel()
    }
}
