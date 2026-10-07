import SwiftUI

/// Sign-in on the Mac: the form on the left and why IVory asks on the right; then the code, typed here
/// while the phone beside it shows where it comes from.
struct AppleIdScreen: View {
    @ObservedObject var flow: SetupFlow
    @ObservedObject var signIn: AppleSignIn
    @ObservedObject private var form = SetupForm.shared
    @EnvironmentObject private var store: ConfigStore
    @FocusState private var codeFocused: Bool

    private var isCode: Bool { flow.screen == .appleidCode }
    /// Signed in, and nothing new being typed: the tick instead of the form.
    private var signedIn: Bool { flow.done.contains(.appleid) && !signIn.busy && !form.hasPassword }

    var body: some View {
        HStack(alignment: .center, spacing: 56) {
            CenteredColumn {
                VStack(alignment: .leading, spacing: 22) {
                    SetupHeading(title: flow.screen.title, lead: flow.screen.lead)
                    if signedIn {
                        SignedIn(appleId: store.config.appleId)
                    } else if isCode {
                        code
                    } else {
                        fields
                    }
                }
                .frame(maxWidth: 400, alignment: .leading)
            }
            .frame(maxWidth: .infinity)
            if isCode {
                FitToSpace(size: CGSize(width: 244, height: 542)) {
                    VStack(spacing: 14) {
                        PhoneCaption(text: tr("Kód je na iPhonu", "The code is on your iPhone"))
                        SetupPhone(art: .appleCode, size: .pair)
                    }
                    .modifier(PhoneRise(delay: 0.08))
                }
                .frame(maxWidth: .infinity)
            } else {
                AppleIdWhy().frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.leading, 48)
        .padding(.trailing, 56)
        .onAppear {
            if form.appleId.isEmpty { form.appleId = store.config.appleId }
            if isCode { form.code = ""; codeFocused = true }
        }
        .onDisappear { if isCode { form.code = "" } }
    }

    // MARK: the form

    private var failure: AppleSignIn.Failure? {
        if case .failed(let f) = signIn.state, f != .cancelled { return f }
        return nil
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 12) {
            field("Apple ID", error: false) {
                TextField(tr("jmeno@icloud.com", "name@icloud.com"), text: $form.appleId)
                    .textFieldStyle(.plain)
                    .textContentType(.username)
            }
            field(tr("Heslo", "Password"), error: failure == .wrongPassword) {
                PasswordField(placeholder: "") { form.submit(signIn) }
                    .frame(height: 18)
            }
            if let failure {
                SignInNote(symbol: "exclamationmark.circle.fill", color: SW.red, background: SW.redTint,
                       text: failure == .wrongPassword
                           ? tr("Apple tohle Apple ID nebo heslo nepřijal. Zkontroluj obojí a zkus to znovu. Po moc pokusech se účet může na chvíli zamknout.",
                                "Apple didn’t accept this Apple ID or password. Check both and try again. Too many tries can lock the account for a while.")
                           : failure.text)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .disabled(signIn.busy)
        .animation(.easeOut(duration: 0.25), value: signIn.state)
    }

    private func field<F: View>(_ label: String, error: Bool, @ViewBuilder content: () -> F) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 12)).foregroundStyle(SW.muted)
            content()
                .font(.system(size: 13))
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(SW.input, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(error ? SW.red : SW.border, lineWidth: 1))
        }
    }

    // MARK: the code

    /// Six boxes over an invisible field: typing fills them, the sixth digit sends the code.
    private var code: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(tr("Zadej šestimístný kód z iPhonu", "Enter the 6-digit code from your iPhone")).font(.system(size: 14, weight: .medium))
            ZStack(alignment: .leading) {
                TextField("", text: $form.code)
                    .textFieldStyle(.plain)
                    .focused($codeFocused)
                    .opacity(0.01)
                    .textContentType(.oneTimeCode)
                    .onChange(of: form.code) { _, new in
                        let digits = String(new.filter(\.isNumber).prefix(6))
                        if digits != new { form.code = digits }
                        if digits.count == 6 { form.submitCode(signIn) }
                    }
                HStack(spacing: 8) {
                    let chars = Array(form.code)
                    ForEach(0..<6, id: \.self) { i in
                        let current = i == min(chars.count, 5) && signIn.state == .needsCode
                        Text(i < chars.count ? String(chars[i]) : "")
                            .font(.system(size: 22, weight: .medium).monospacedDigit())
                            .frame(width: 44, height: 52)
                            .background(SW.input, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(current ? SW.accent : SW.border, lineWidth: current ? 1.5 : 1))
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { codeFocused = true }
            }
            .disabled(signIn.state != .needsCode)
            SignInNote(symbol: "iphone", color: SW.ink, background: SW.tint,
                   text: tr("iPhone nejdřív ukáže upozornění na přihlášení. Klepni na Povolit a kód napiš sem.",
                            "Your iPhone shows a sign-in alert first. Tap Allow, then type the code here."))
        }
    }
}

/// The form's place once signed in: a green tick that pops in, and the account.
private struct SignedIn: View {
    let appleId: String
    @State private var shown = false

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(SW.green)
                Image(systemName: "checkmark").font(.system(size: 20, weight: .heavy)).foregroundStyle(SW.onAccent)
            }
            .frame(width: 44, height: 44)
            .modifier(SetupPop(on: shown, duration: 0.42))
            VStack(alignment: .leading, spacing: 2) {
                Text(tr("Přihlášeno", "Signed in")).font(.system(size: 15, weight: .medium))
                Text(appleId).foregroundStyle(SW.muted).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .background(SW.greenTint, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onAppear { shown = true }
        .accessibilityElement(children: .combine)
    }
}

/// Why IVory asks for the Apple ID, beside the form.
private struct AppleIdWhy: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(tr("Proč to IVory potřebuje", "Why IVory asks for this")).font(.system(size: 15, weight: .medium))
            reason("signature", tr("IVory ovládá iPhone přes malou pomocnou aplikaci. Tu podepisuje tvoje Apple ID.",
                                   "IVory controls your iPhone through a small helper app. Your Apple ID signs that app."))
            reason("lock", tr("Apple dovolí aplikaci ovládat jen iPhone, který patří k účtu, jenž ji podepsal. Cizí podpis iPhone odmítne, takže jinak to nejde.",
                              "Apple only lets an app control an iPhone that belongs to the account that signed it. A signature from anyone else is refused, so there is no way around this step."))
            reason("paperplane", tr("Heslo jde rovnou Applu. IVory ho neukládá a nikam jinam neposílá.",
                                    "Your password goes straight to Apple. IVory doesn’t save it and doesn’t send it anywhere else."))
            reason("calendar.badge.checkmark", tr("Přihlášení vydrží asi rok. Podpis platí 7 dní a IVory si ho obnovuje samo.",
                                                  "You stay signed in for about a year. The signature lasts 7 days and IVory renews it on its own."),
                   muted: true)
                .padding(.top, 16)
                .overlay(alignment: .top) { Rectangle().fill(SW.border).frame(height: 1) }
        }
        .padding(24)
        .frame(maxWidth: 440, alignment: .leading)
        .background(SW.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(SW.border, lineWidth: 1))
    }

    private func reason(_ symbol: String, _ text: String, muted: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(muted ? SW.muted : SW.ink).frame(width: 20)
            Text(text).foregroundStyle(muted ? SW.muted : SW.text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

/// An icon and a line on a tinted background: the sign-in error, the hint about the code.
private struct SignInNote: View {
    let symbol: String
    let color: Color
    let background: Color
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(color).padding(.top, 1)
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
