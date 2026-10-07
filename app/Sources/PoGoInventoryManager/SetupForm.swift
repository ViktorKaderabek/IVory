import AppKit
import SwiftUI

/// The Apple ID typed into the form, and the password field it doesn't keep.
///
/// The password lives only in the NSSecureTextField itself – never in a property, `@State` or a
/// binding – and is read out of it once, at the moment it is handed to the signing tool, which empties
/// the field. The six-digit code is held while typed (the boxes have to show it) and cleared once sent;
/// it is single-use and expires in minutes.
@MainActor
final class SetupForm: ObservableObject {
    static let shared = SetupForm()

    @Published var appleId = ""
    @Published var hasPassword = false
    @Published var code = ""
    weak var passwordField: NSSecureTextField?

    var ready: Bool { appleId.contains("@") && hasPassword }

    func submit(_ signIn: AppleSignIn) {
        guard ready, let field = passwordField else { return }
        let password = field.stringValue
        field.stringValue = ""
        hasPassword = false
        signIn.start(appleId: appleId.trimmingCharacters(in: .whitespaces), password: password)
    }

    func submitCode(_ signIn: AppleSignIn) {
        let digits = code
        code = ""
        signIn.submit(code: digits)
    }
}

/// The password field, AppKit's own secure field so the text never passes through SwiftUI.
struct PasswordField: NSViewRepresentable {
    let placeholder: String
    let onSubmit: () -> Void

    func makeNSView(context: Context) -> NSSecureTextField {
        let field = NSSecureTextField()
        field.placeholderString = placeholder
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.submit)
        field.contentType = .password
        SetupForm.shared.passwordField = field
        return field
    }

    func updateNSView(_ field: NSSecureTextField, context: Context) {
        context.coordinator.onSubmit = onSubmit
        field.isEnabled = context.environment.isEnabled           // .disabled() doesn't reach AppKit
    }

    static func dismantleNSView(_ field: NSSecureTextField, coordinator: Coordinator) {
        field.stringValue = ""
        SetupForm.shared.hasPassword = false
    }

    func makeCoordinator() -> Coordinator { Coordinator(onSubmit: onSubmit) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var onSubmit: () -> Void
        init(onSubmit: @escaping () -> Void) { self.onSubmit = onSubmit }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            let has = !field.stringValue.isEmpty
            MainActor.assumeIsolated {
                if SetupForm.shared.hasPassword != has { SetupForm.shared.hasPassword = has }
            }
        }

        @objc func submit() { onSubmit() }
    }
}
