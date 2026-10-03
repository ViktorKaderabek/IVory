#if DEBUG
import AppKit
import SwiftUI

/// Only for checking the look without a window: `PoGoInventoryManager --snapshot <folder>` renders the main window,
/// the settings, the Stats screen and the template editor to PNG (light and dark appearance). Settings aren't saved.
enum SnapshotExport {
    @MainActor static func run(to folder: String) -> Int32 {
        let dir = URL(fileURLWithPath: folder)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = ConfigStore(readOnly: true)
        store.config.steps = Steps(duplicates: true, iv: true, pvp: true, rename: true)
        let runner = Runner.shared
        var code: Int32 = 0
        for (name, scheme) in [("dark", ColorScheme.dark), ("light", ColorScheme.light)] {
            for state in ["ready", "running", "done"] {
                runner.applyPreview(state == "ready" ? "none" : state)
                let view = SnapshotMain()
                    .environmentObject(store).environmentObject(runner)
                    .environment(\.colorScheme, scheme)
                    .frame(width: 1040)
                code |= save(view, scheme, dir.appendingPathComponent("main_\(state)_\(name).png"))
            }
            let saved = UserDefaults.standard.string(forKey: "settingsOpenSections")
            UserDefaults.standard.set("duplicates,iv,pvp,rename", forKey: "settingsOpenSections")
            let settings = SettingsContent()
                .frame(width: 420)
                .background(Theme.chrome)
                .environmentObject(store).environmentObject(runner)
                .environment(\.colorScheme, scheme)
            code |= save(settings, scheme, dir.appendingPathComponent("settings_\(name).png"))
            UserDefaults.standard.set(saved, forKey: "settingsOpenSections")
            for (suffix, data) in [("", InventoryStats.load(removeTag: store.config.removeTag)), ("_empty", InventoryStats())] {
                MonImages.reset(for: data)
                let stats = StatsView(preloaded: data) {}
                    .padding(EdgeInsets(top: 22, leading: 28, bottom: 26, trailing: 28))
                    .frame(width: 1040)
                    .background(Theme.bg)
                    .foregroundStyle(Theme.text)
                    .environmentObject(store).environmentObject(runner)
                    .environment(\.colorScheme, scheme)
                code |= save(stats, scheme, dir.appendingPathComponent("stats\(suffix)_\(name).png"))
                guard !data.isEmpty else { continue }
                let sheets: [(String, StatsSheet)] = [("hundo", .hundo), ("pvp", .pvp), ("species", .species(data.topSpecies.first?.name ?? "")),
                                                      ("coverage", .coverage), ("run", .run(data.runs.last?.id ?? ""))]
                for (key, sheet) in sheets {
                    let panel = StatsSheetPanel(def: .make(sheet, data, store.config), stats: data, startRun: {}, scrolls: false)
                        .frame(width: 940, height: 660)
                        .padding(24)
                        .background(Theme.bg)
                        .foregroundStyle(Theme.text)
                        .environmentObject(store).environmentObject(runner)
                        .environment(\.colorScheme, scheme)
                    code |= save(panel, scheme, dir.appendingPathComponent("stats_sheet_\(key)_\(name).png"))
                }
            }
            let editor = RenameEditor(config: .constant(store.config.rename), samples: NameSample.design)
                .environment(\.colorScheme, scheme)
            code |= save(editor, scheme, dir.appendingPathComponent("editor_\(name).png"))
        }
        return code
    }

    @MainActor private static func save<V: View>(_ view: V, _ scheme: ColorScheme, _ url: URL) -> Int32 {
        NSApplication.shared.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        guard let cg = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return 1 }
        do { try png.write(to: url) } catch { return 1 }
        return 0
    }
}

/// The main window without the toolbar and the settings panel (ImageRenderer can't render those).
private struct SnapshotMain: View {
    var body: some View {
        MainColumn(fresh: .constant(false))
            .padding(EdgeInsets(top: 22, leading: 28, bottom: 26, trailing: 28))
            .background(Theme.bg)
            .foregroundStyle(Theme.text)
    }
}

#endif
