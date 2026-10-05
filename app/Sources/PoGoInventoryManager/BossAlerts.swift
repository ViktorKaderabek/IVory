import AppKit
import UserNotifications

/// Notifications about new raid bosses: when a downloaded boss list has a boss that wasn't in the previous one,
/// IVory says when your party is strong against it, or when you have no good counters. Only while IVory is open
/// (the list is downloaded once a day). Clicking the notification opens Battle on that boss.
@MainActor
enum BossAlerts {
    static let openNote = Notification.Name("IVoryOpenBoss")
    private static let seenKey = "battleSeenBosses"
    /// Settings → Battle tags → "Notify me about new raid bosses" (kept in sync by MainView).
    static var enabled = true
    private static let delegate = Delegate()

    /// Notifications need the app bundle (the bare binary from `swift build` has no bundle and would crash).
    private static var available: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    static func setUp() {
        guard available else { return }
        UNUserNotificationCenter.current().delegate = delegate
    }

    static func requestPermission() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// After a boss list download, once the game data and the storage are loaded (false = not yet, try again
    /// later). The very first list only gets remembered: nothing in it is "new".
    static func check(_ bosses: [RaidBoss], store: BattleStore) -> Bool {
        guard let mons = StatsStore.shared.stats?.mons, !mons.isEmpty else { return false }
        let defaults = UserDefaults.standard
        let seen = Set(defaults.stringArray(forKey: seenKey) ?? [])
        defaults.set(bosses.map(\.name), forKey: seenKey)
        guard !seen.isEmpty, enabled, available else { return true }
        for boss in bosses where !seen.contains(boss.name) {
            guard let message = message(boss, store: store, mons: mons) else { continue }
            post(title: message.title, body: message.body, boss: boss.name)
        }
        return true
    }

    /// A strong party (≥ 75 % with at most 3 players) or no good counters; nothing for the bosses in between.
    private static func message(_ boss: RaidBoss, store: BattleStore, mons: [InventoryStats.Mon]) -> (title: String, body: String)? {
        guard let r = store.counters(boss, weather: "none", mons: mons) else { return nil }
        let title = tr("Nový raid boss: \(boss.name)", "New raid boss: \(boss.name)")
        guard let best = r.counters.first, !r.counters.prefix(3).allSatisfy(\.weak) else {
            return (title, tr("Na tohohle bosse nemáš v úložišti dobré countery: nikdo na něj nemá typovou výhodu.",
                              "You have no good counters for this boss: nobody in your storage has a type advantage."))
        }
        guard let ch = r.chances, let i = ch.firstIndex(where: { $0 >= 75 }), i < 3 else { return nil }
        let players = trCount(i + 1, cs: "hráč", "hráči", "hráčů", en: "player", "players")
        return (title, i == 0
                ? tr("Zvládneš ho sám, šance \(percentText(ch[i])). Nejlepší pick: \(best.mon.name).",
                     "You can beat it alone, \(percentText(ch[i])) chance. Best pick: \(best.mon.name).")
                : tr("Se tvou šesticí stačí \(players) na šanci \(percentText(ch[i])). Nejlepší pick: \(best.mon.name).",
                     "With your six, \(players) give a \(percentText(ch[i])) chance. Best pick: \(best.mon.name)."))
    }

    private static func post(title: String, body: String, boss: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["boss": boss]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "boss-\(boss)", content: content, trigger: nil))
    }

    private final class Delegate: NSObject, UNUserNotificationCenterDelegate {
        /// Shown even while IVory is in front.
        func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
            completionHandler([.banner, .sound])
        }

        func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                    withCompletionHandler completionHandler: @escaping () -> Void) {
            let boss = response.notification.request.content.userInfo["boss"] as? String
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                NotificationCenter.default.post(name: BossAlerts.openNote, object: boss)
            }
            completionHandler()
        }
    }
}
