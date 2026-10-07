import Foundation
import Security

/// Everything about the user's Apple ID that IVory touches, in one place.
///
/// The password is never IVory's: it is typed into the setup guide, written once to the stdin of the
/// bundled `altsign-cli`, and that tool talks to Apple alone – `gsa.apple.com` for the sign-in (SRP, so
/// not even Apple's servers see the password itself) and `developerservices2.apple.com` to sign the
/// helper app. The machine data Apple asks for comes from macOS's own AuthKit, not from a third-party
/// server. What stays on the Mac is altsign-cli's session token in
/// `~/Library/Application Support/altsign/` (owner-only), good for about a year.
enum AppleAccount {
    // MARK: - the signing tool

    /// The altsign-cli the password may be handed to, or nil when it can't be trusted.
    ///
    /// In a release build only the copy inside IVory.app counts, and only while the app's code signature
    /// still covers it: anything else on disk is not ours to give a password to. A build run from the
    /// repository (DEBUG) also looks in runtime/ next to the sources.
    static func signingTool() -> Result<String, ToolProblem> {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/runtime/altsign-cli").path
        if FileManager.default.isExecutableFile(atPath: bundled) {
            #if DEBUG
            return .success(bundled)
            #else
            return bundleIsIntact() ? .success(bundled) : .failure(.tampered)
            #endif
        }
        #if DEBUG
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("runtime/altsign-cli").path
        if FileManager.default.isExecutableFile(atPath: repo) { return .success(repo) }
        #endif
        return .failure(.missing)
    }

    enum ToolProblem: Error {
        case missing, tampered

        var text: String {
            switch self {
            case .missing:
                return tr("V aplikaci chybí podepisovací nástroj. Stáhni IVory znovu z oficiální stránky na GitHubu.",
                          "The signing tool is missing from the app. Download IVory again from its official GitHub page.")
            case .tampered:
                return tr("IVory.app se od stažení změnila, takže jí heslo nesvěřím. Smaž ji a stáhni znovu z oficiální stránky na GitHubu.",
                          "IVory.app has changed since it was downloaded, so it won't be given your password. Delete it and download it again from its official GitHub page.")
            }
        }
    }

    /// Does the app's code signature still cover every file in the bundle (the signing tool and the
    /// Python core included)? Checked once per launch; it hashes the whole bundle.
    private static var intact: Bool?

    static func bundleIsIntact() -> Bool {
        if let intact { return intact }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code) == errSecSuccess, let code else {
            intact = false
            return false
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        let ok = SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess
        intact = ok
        return ok
    }

    // MARK: - the cached session

    private static var sessionURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("altsign/session.plist")
    }

    struct Session {
        let appleId: String
        let expires: Date?
        var valid: Bool { expires.map { $0 > Date() } ?? true }
    }

    /// Who altsign-cli is signed in as, read from its session file without asking Apple. Only the Apple
    /// ID and the expiry are read; the token in the same file is left alone.
    static func session() -> Session? {
        guard let dict = NSDictionary(contentsOf: sessionURL),
              let appleId = dict["appleID"] as? String, !appleId.isEmpty else { return nil }
        return Session(appleId: appleId, expires: dict["expirationDate"] as? Date)
    }

    /// Is `appleId` signed in, with a session that hasn't run out?
    static func isSignedIn(_ appleId: String) -> Bool {
        guard let s = session() else { return false }
        return !appleId.isEmpty && s.appleId.caseInsensitiveCompare(appleId) == .orderedSame && s.valid
    }

    /// Forgets the session and the signing certificate's private key, so nothing on this Mac can act on
    /// the account any more. The certificate itself stays with Apple until it runs out (or is revoked at
    /// developer.apple.com); the next sign-in replaces it.
    static func signOut() {
        try? FileManager.default.removeItem(at: sessionURL.deletingLastPathComponent())
    }
}

/// One sign-in to Apple through altsign-cli, as the setup guide shows it: password, then maybe the
/// six-digit code, then success or a reason.
///
/// Neither the password nor the code is ever stored – not in a property, not in `@State`, not on disk.
/// Each is written to the tool's stdin the moment it is typed. The tool's own output can echo account
/// details, so it is only searched for the prompt and the error code and is never shown or logged.
@MainActor
final class AppleSignIn: ObservableObject {
    enum Failure: Equatable {
        case wrongPassword, wrongCode, locked, offline, tool(String), cancelled, other

        var text: String {
            switch self {
            case .wrongPassword:
                return tr("Apple ID nebo heslo nesedí. Pozor: po několika chybných pokusech Apple účet z bezpečnostních důvodů dočasně zamkne.",
                          "The Apple ID or the password is wrong. Careful: after a few wrong attempts Apple locks the account for a while, for its safety.")
            case .wrongCode:
                return tr("Kód nesouhlasil nebo vypršel. Zadej heslo znovu a Apple pošle nový kód.",
                          "The code was wrong or expired. Enter the password again and Apple sends a new code.")
            case .locked:
                return tr("Apple účet z bezpečnostních důvodů zamkl. Odemkni ho na iforgot.apple.com a pak to zkus znovu.",
                          "Apple has locked the account for its safety. Unlock it at iforgot.apple.com, then try again.")
            case .offline:
                return tr("Nedá se spojit s Applem. Zkontroluj připojení k internetu.",
                          "Can't reach Apple. Check your internet connection.")
            case .tool(let why):
                return why
            case .cancelled:
                return tr("Přihlášení zrušeno.", "Sign-in cancelled.")
            case .other:
                return tr("Apple přihlášení odmítl. Zkus to prosím znovu za chvíli.",
                          "Apple refused the sign-in. Please try again in a moment.")
            }
        }
    }

    enum State: Equatable {
        case idle, working, needsCode, verifying, ok
        case failed(Failure)
    }

    @Published private(set) var state = State.idle

    private var process: Process?
    private var input: FileHandle?
    /// The tail of the tool's output, searched for the code prompt and the error code. Never shown.
    private var transcript = ""

    var busy: Bool { state == .working || state == .verifying }

    func start(appleId: String, password: String) {
        guard !busy, state != .needsCode else { return }
        let cli: String
        switch AppleAccount.signingTool() {
        case .success(let path): cli = path
        case .failure(let problem):
            state = .failed(.tool(problem.text))
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = ["list", "--apple-id", appleId]
        let stdin = Pipe(), output = Pipe()
        process.standardInput = stdin
        process.standardOutput = output
        process.standardError = output
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in self?.heard(text) }
        }
        process.terminationHandler = { [weak self] finished in
            let code = finished.terminationStatus
            Task { @MainActor in
                // let the last of the output arrive before it is read for the reason
                try? await Task.sleep(nanoseconds: 150_000_000)
                self?.ended(code)
            }
        }
        transcript = ""
        state = .working
        do { try process.run() } catch {
            state = .failed(.tool(tr("Podepisovací nástroj se nepodařilo spustit.", "Couldn't start the signing tool.")))
            return
        }
        self.process = process
        input = stdin.fileHandleForWriting
        write(password)
    }

    func submit(code: String) {
        guard state == .needsCode else { return }
        let digits = code.filter(\.isNumber)
        guard digits.count == 6 else { return }
        state = .verifying
        write(digits)
    }

    func cancel() {
        if let process {
            // its end must not be read as a failed sign-in afterwards
            process.terminationHandler = nil
            (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
            if process.isRunning { process.terminate() }
        }
        process = nil
        try? input?.close()
        input = nil
        if state != .ok { state = .failed(.cancelled) }
    }

    func reset() {
        if busy || state == .needsCode { cancel() }
        state = .idle
    }

    #if DEBUG
    func setPreview(_ s: State) { state = s }
    #endif

    private func write(_ value: String) {
        // A tool that already quit closes the pipe; a write then must fail quietly, not raise.
        try? input?.write(contentsOf: Data((value + "\n").utf8))
    }

    private func heard(_ text: String) {
        transcript = String((transcript + text).suffix(8192))
        if state == .working, transcript.lowercased().contains("enter code") {
            state = .needsCode
        }
    }

    private func ended(_ status: Int32) {
        process = nil
        try? input?.close()
        input = nil
        defer { transcript = "" }
        if status == 0 { state = .ok; return }
        let low = transcript.lowercased()
        if low.contains("-20101") || low.contains("-22406") || low.contains("incorrect") {
            state = .failed(.wrongPassword)
        } else if low.contains("-21669") || low.contains("[2fa] validation failed") {
            state = .failed(.wrongCode)
        } else if low.contains("-20209") || low.contains("-20283") || low.contains("locked") {
            state = .failed(.locked)
        } else if low.contains("nsurlerrordomain") {
            state = .failed(.offline)
        } else {
            state = .failed(.other)
        }
    }
}
