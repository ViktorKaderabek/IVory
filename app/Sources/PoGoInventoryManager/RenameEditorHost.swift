import AppKit
import SwiftUI
import UniformTypeIdentifiers

// The renaming editor as a sheet: how it is opened, measured and laid out.

/// Finds the height of the window the sheet hangs over and keeps tracking it when the window is resized.
struct ParentHeightReader: NSViewRepresentable {
    @Binding var height: CGFloat?

    func makeNSView(context: Context) -> NSView {
        let view = ReaderView()
        view.report = { h in DispatchQueue.main.async { if height != h { height = h } } }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ReaderView: NSView {
        var report: ((CGFloat) -> Void)?
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard window != nil else { return }
            // at this point the sheet may not be attached to the window yet (sheetParent is nil)
            DispatchQueue.main.async { [weak self] in self?.attach() }
        }

        private func attach() {
            guard let sheet = window,
                  let parent = sheet.sheetParent ?? NSApp.windows.first(where: { $0.attachedSheet === sheet })
                    ?? NSApp.mainWindow.flatMap({ $0 === sheet ? nil : $0 }) else { return }
            report?(parent.contentLayoutRect.height)
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: parent,
                                                              queue: .main) { [weak self, weak parent] _ in
                if let parent { self?.report?(parent.contentLayoutRect.height) }
            }
        }

        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }
}

/// Filled button in the accent color (Done).
struct FilledButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 16)
            .frame(height: 32)
            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// A row that wraps (template pieces, the piece menu).
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    /// The pieces never change size on their own, so they are measured once per layout pass instead of
    /// twice for every subview (once to size the row, once to place it).
    struct Cache {
        var sizes: [CGSize] = []
    }

    func makeCache(subviews: Subviews) -> Cache { Cache(sizes: subviews.map { $0.sizeThatFits(.unspecified) }) }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache.sizes = subviews.map { $0.sizeThatFits(.unspecified) }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxX: CGFloat = 0
        for (i, _) in subviews.enumerated() {
            let size = cache.sizes[i]
            if x > 0 && x + size.width > width {
                x = 0
                y += rowH + spacing
                rowH = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowH = max(rowH, size.height)
        }
        return CGSize(width: proposal.width ?? maxX, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for (i, s) in subviews.enumerated() {
            let size = cache.sizes[i]
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowH + spacing
                rowH = 0
            }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowH = max(rowH, size.height)
        }
    }
}

final class RenameEditorModel: ObservableObject {
    static let shared = RenameEditorModel()
    @Published private(set) var open = false

    func show() { withAnimation(.design(0.22)) { open = true } }
    func close() { withAnimation(.design(0.18)) { open = false } }
}

/// The editor over the window: the scrim and the panel. Clicking beside it, or Esc, closes it.
struct RenameEditorHost: View {
    @EnvironmentObject private var store: ConfigStore
    @ObservedObject private var model = RenameEditorModel.shared

    var body: some View {
        ZStack {
            if model.open {
                Theme.bg.opacity(0.55)
                    .contentShape(Rectangle())
                    .onTapGesture { model.close() }
                    .transition(.opacity)
                RenameEditor(config: $store.config.rename, samples: samples) { model.close() }
                    .transition(.modifier(active: EditorIn(y: -16, opacity: 0),
                                          identity: EditorIn(y: 0, opacity: 1)))
                Button("") { model.close() }
                    .keyboardShortcut(.cancelAction)
                    .opacity(0).frame(width: 0, height: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var samples: [NameSample] {
        LastBox.load()?.samples(in: store.config.rename.min...store.config.rename.max) ?? NameSample.design
    }
}

struct EditorIn: ViewModifier {
    let y: CGFloat
    let opacity: Double

    func body(content: Content) -> some View { content.offset(y: y).opacity(opacity) }
}
