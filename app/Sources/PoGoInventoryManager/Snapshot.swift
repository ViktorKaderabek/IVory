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
        store.config.steps = Steps(duplicates: true, iv: true, pvp: true, rename: true, battle: true, weak: true)
        let runner = Runner.shared
        var code: Int32 = 0
        for (name, scheme) in [("dark", ColorScheme.dark), ("light", ColorScheme.light)] {
            for state in ["ready", "running", "done"] {
                runner.applyPreview(state == "ready" ? "none" : state)
                for width in [1040.0, 720.0] {        // 720 = the narrowest the content gets (settings open)
                    let view = SnapshotMain()
                        .environmentObject(store).environmentObject(runner)
                        .environment(\.colorScheme, scheme)
                        .frame(width: width)
                    let suffix = width == 1040 ? "" : "_narrow"
                    code |= save(view, scheme, dir.appendingPathComponent("main_\(state)\(suffix)_\(name).png"))
                }
            }
            let saved = UserDefaults.standard.string(forKey: "settingsOpenSections")
            UserDefaults.standard.set("duplicates,iv,pvp,rename,battle,weak", forKey: "settingsOpenSections")
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
            let battleData = InventoryStats.load(removeTag: store.config.removeTag)
            MonImages.reset(for: battleData)
            BattleStore.shared.loadNow(mons: battleData.mons)
            let defaults = UserDefaults.standard
            let savedTab = defaults.string(forKey: "battleTab"), savedLeague = defaults.string(forKey: "battleLeague")
            for (key, tab, league) in [("raid", "raid", "great"), ("pvp_great", "pvp", "great"), ("pvp_ultra", "pvp", "ultra"),
                                       ("pvp_master", "pvp", "master"), ("upgrades", "upgrades", "great"),
                                       ("upgrades_open", "upgrades", "great"), ("upgrades_pvp", "upgrades", "great")] {
                // the last one with the first power-up row open, so its detail is captured too
                let firstUp = BattleStore.shared.data.flatMap { RaidCalc(data: $0).upgrades(mons: battleData.mons, perType: 6).first }
                // one with a raid row open, one with the priciest PvP row (the one with XL candy)
                let firstPvP = BattleStore.shared.teams[.master]?.teams.first?.members.first { $0.powerUp }
                BattleStore.shared.focusUpgrade = key == "upgrades_open" ? firstUp.map { "r-\($0.id)" }
                    : key == "upgrades_pvp" ? firstPvP.map { "p-\($0.id)" } : nil
                defaults.set(tab, forKey: "battleTab")
                defaults.set(league, forKey: "battleLeague")
                for (suffix, data) in [("", battleData), ("_empty", InventoryStats())] where suffix.isEmpty || key == "raid" {
                    let battle = BattleView(preloaded: data) {}
                        .padding(EdgeInsets(top: 22, leading: 28, bottom: 26, trailing: 28))
                        .frame(width: 1040)
                        .background(Theme.bg)
                        .foregroundStyle(Theme.text)
                        .environmentObject(store).environmentObject(runner)
                        .environment(\.colorScheme, scheme)
                    code |= save(battle, scheme, dir.appendingPathComponent("battle_\(key)\(suffix)_\(name).png"))
                }
            }
            defaults.set(savedTab, forKey: "battleTab")
            defaults.set(savedLeague, forKey: "battleLeague")
            // the detail popovers, on their own (ImageRenderer can't open a popover)
            let battle = BattleStore.shared
            if let boss = battle.bosses.first(where: { $0.form != nil }),
               let result = battle.counters(boss, weather: "none", mons: battleData.mons), result.counters.count > 2 {
                let raid = RaidDetail(c: result.counters[2], boss: boss, weather: "none", best: result.counters[0].strength)
                    .background(Theme.chrome).foregroundStyle(Theme.text).environment(\.colorScheme, scheme)
                code |= save(raid, scheme, dir.appendingPathComponent("battle_detail_raid_\(name).png"))
            }
            if let member = battle.teams[.great]?.teams.first?.members.first {
                let pvp = PvPDetail(m: member, league: .great)
                    .background(Theme.chrome).foregroundStyle(Theme.text).environment(\.colorScheme, scheme)
                code |= save(pvp, scheme, dir.appendingPathComponent("battle_detail_pvp_\(name).png"))
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
