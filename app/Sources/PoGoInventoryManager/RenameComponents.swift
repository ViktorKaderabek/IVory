import SwiftUI

// MARK: - Dílky šablony jména

/// Druhy dílků šablony (stejné klíče čte bot v core/pokecalc.py).
enum NamePiece {
    struct Info {
        let label: String
        let short: String
        var sep: String? = nil
        var glyph: String? = nil
    }

    /// Názvy v aktuálním jazyce (proto počítané, ne konstanta).
    static var all: [String: Info] {
        [
            "iv": Info(label: tr("IV v %", "IV in %"), short: "IV %"),
            "ivs": Info(label: tr("IV hodnoty", "IV values"), short: "IV"),
            "lvl": Info(label: tr("Úroveň", "Level"), short: tr("Úroveň", "Level")),
            "species": Info(label: tr("Druh", "Species"), short: tr("Druh", "Species")),
            "short": Info(label: tr("Druh zkrácený", "Species, short"), short: tr("Druh zkr.", "Sp. short")),
            "evo": Info(label: tr("Poslední evoluce", "Final evolution"), short: tr("Evoluce", "Evolution")),
            "cpEvo": Info(label: tr("CP po evoluci", "CP after evolving"), short: "CP evo"),
            "cpMax": Info(label: "Max CP L50", short: "CP L50"),
            "great": Info(label: "Great League", short: "Great"),
            "ultra": Info(label: "Ultra League", short: "Ultra"),
            "master": Info(label: "Master League", short: "Master"),
            "text": Info(label: tr("Vlastní text", "Custom text"), short: "Text"),
            "space": Info(label: tr("Mezera", "Space"), short: tr("Mezera", "Space"), sep: " ", glyph: "␣"),
            "dash": Info(label: tr("Pomlčka", "Dash"), short: tr("Pomlčka", "Dash"), sep: "-", glyph: "-"),
            "pipe": Info(label: tr("Svislítko", "Pipe"), short: tr("Svislítko", "Pipe"), sep: "|", glyph: "|"),
        ]
    }

    static var groups: [(String, [String])] {
        [
            (tr("Kus", "Pokémon"), ["iv", "ivs", "lvl"]), (tr("Druh", "Species"), ["species", "short", "evo"]),
            (tr("Síla", "Power"), ["cpEvo", "cpMax"]), (tr("PvP pořadí", "PvP rank"), ["great", "ultra", "master"]),
            ("Text", ["text", "space", "dash", "pipe"]),
        ]
    }

    static func info(_ k: String) -> Info { all[k] ?? Info(label: k, short: k) }

    /// Celé jméno podle šablony (bez ořezu na 12 znaků – ten ukazuje náhled).
    static func render(_ tokens: [NameToken], _ values: [String: String]) -> String {
        tokens.map { t in info(t.k).sep ?? (t.k == "text" ? (t.v ?? "") : (values[t.k] ?? "")) }.joined()
    }

    static let maxLength = 12
}

/// Ukázkový kus pro náhled jména.
struct NameSample: Identifiable {
    let id = UUID()
    let name: String
    let iv: [Int]
    let values: [String: String]
    var custom = false

    var pct: Int { Int((Double(iv.reduce(0, +)) / 45 * 100).rounded()) }
    var subtitle: String { percentText(pct) + " · " + iv.map(String.init).joined(separator: "/") }

    /// Ukázky z návrhu, dokud bot inventář nepřečte.
    static let design: [NameSample] = [
        NameSample(name: "Baxcalibur", iv: [14, 13, 14], values: values("Baxcalibur", "Baxcalibur", [14, 13, 14], 15, 1504, 3968, 12, 5, 30)),
        NameSample(name: "Machop", iv: [15, 15, 14], values: values("Machop", "Machamp", [15, 15, 14], 22, 2105, 3420, 48, 3, 98)),
        NameSample(name: "Gible", iv: [13, 15, 15], values: values("Gible", "Garchomp", [13, 15, 15], 20, 2410, 4431, 210, 88, 140)),
        NameSample(name: "Kytka", iv: [12, 14, 13], values: values("Bulbasaur", "Venusaur", [12, 14, 13], 18, 1620, 3075, 7, 19, 64), custom: true),
    ]

    private static func values(_ sp: String, _ evo: String, _ iv: [Int], _ lvl: Int, _ cpE: Int, _ cpM: Int,
                               _ g: Int, _ u: Int, _ m: Int) -> [String: String] {
        let pct = Int((Double(iv.reduce(0, +)) / 45 * 100).rounded())
        return ["iv": "\(pct)", "ivs": iv.map(String.init).joined(separator: "/"), "lvl": "L\(lvl)", "species": sp,
                "short": String(sp.prefix(6)), "evo": String(evo.prefix(3)), "cpEvo": "\(cpE)", "cpMax": "\(cpM)",
                "great": "G\(g)", "ultra": "U\(u)", "master": "M\(m)"]
    }
}

/// Poslední přečtený inventář (~/.pogo/last_box.json, zapisuje bot): kolik kusů je v rozsahu IV a ukázky jmen.
struct LastBox {
    struct Item: Decodable {
        let cp: Int?
        let name: String
        let iv: [Int]
        let tags: [String]?
        let custom: Bool?
        let values: [String: String]?

        var pct: Int { Int((Double(iv.reduce(0, +)) / 45 * 100).rounded()) }
    }

    let items: [Item]

    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pogo/last_box.json")

    static func load() -> LastBox? {
        #if DEBUG
        if ProcessInfo.processInfo.environment["IVORY_SHOTS"] != nil { return nil }   // snímky pro README ukazují ukázková jména, ne vlastní box
        #endif
        struct File: Decodable { let items: [Item] }
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data), !file.items.isEmpty else { return nil }
        return LastBox(items: file.items)
    }

    func count(in range: ClosedRange<Int>) -> Int { items.filter { range.contains($0.pct) }.count }

    /// Ukázky: tři nejlepší kusy v rozsahu (se spočítaným druhem) a jeden s vlastní přezdívkou.
    func samples(in range: ClosedRange<Int>) -> [NameSample] {
        let inRange = items.filter { range.contains($0.pct) }.sorted { $0.pct > $1.pct }
        var out = inRange.filter { $0.custom != true && ($0.values?["evo"] != nil) }.prefix(3).map {
            NameSample(name: $0.name, iv: $0.iv, values: $0.values ?? [:])
        }
        if let c = inRange.first(where: { $0.custom == true }) {
            out.append(NameSample(name: c.name, iv: c.iv, values: c.values ?? [:], custom: true))
        }
        return out.isEmpty ? NameSample.design : Array(out)
    }
}

// MARK: - Dvojitý posuvník

/// Posuvník se dvěma úchyty 0–100 (Slider má jen jeden). Tah myší, klik do dráhy, šipky (Shift = po 5).
struct DualRange: View {
    @Binding var lo: Int
    @Binding var hi: Int
    @Environment(\.isEnabled) private var isEnabled
    @State private var dragging: Int?          // 0 = od, 1 = do
    @FocusState private var focus: Int?

    var body: some View {
        VStack(spacing: 2) {
            GeometryReader { geo in
                let w = geo.size.width
                let x = { (v: Int) in CGFloat(v) / 100 * w }
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.track).frame(height: 4).padding(.horizontal, -10)
                    Capsule().fill(Theme.accent)
                        .frame(width: max(0, x(hi) - x(lo)), height: 4)
                        .offset(x: x(lo))
                        .shadow(color: Theme.accent.opacity(0.55), radius: 6)
                    knob(0, at: x(lo))
                    knob(1, at: x(hi))
                }
                .frame(height: 24)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            guard isEnabled else { return }
                            let v = Int((g.location.x / max(1, w) * 100).rounded())
                            if dragging == nil {
                                dragging = abs(v - lo) < abs(v - hi) || (lo == hi && v < lo) ? 0 : 1
                            }
                            set(dragging!, v)
                        }
                        .onEnded { _ in dragging = nil })
            }
            .frame(height: 24)
            .padding(.horizontal, 10)
            GeometryReader { geo in
                ForEach([0, 25, 50, 75, 100], id: \.self) { t in
                    Text("\(t)")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Theme.muted)
                        .fixedSize()
                        .position(x: CGFloat(t) / 100 * geo.size.width, y: 7)
                }
            }
            .frame(height: 14)
            .padding(.horizontal, 10)
        }
        .opacity(isEnabled ? 1 : 0.5)
        .animation(.snappy(duration: 0.15), value: dragging)
    }

    private func knob(_ which: Int, at x: CGFloat) -> some View {
        Circle()
            .fill(Theme.white)
            .frame(width: 20, height: 20)
            .overlay(Circle().strokeBorder(Theme.border))
            .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
            .background(Circle().fill(Theme.accent.opacity(0.3)).padding(dragging == which ? -6 : 0))
            .offset(x: x - 10)
            .zIndex(which == 0 && lo == hi && hi == 100 ? 3 : Double(which + 1))
            .focusable()
            .focused($focus, equals: which)
            .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
                let d = press.key == .leftArrow || press.key == .downArrow ? -1 : 1
                set(which, (which == 0 ? lo : hi) + d * (press.modifiers.contains(.shift) ? 5 : 1))
                return .handled
            }
            .accessibilityLabel(which == 0 ? tr("Od", "From") : tr("Do", "To"))
            .accessibilityValue(percentText(which == 0 ? lo : hi))
    }

    private func set(_ which: Int, _ value: Int) {
        let v = min(100, max(0, value))
        if which == 0 { lo = min(v, hi) } else { hi = max(v, lo) }
    }
}

// MARK: - Počítadlo znaků

/// „11/12“ s dvanácti čárkami; přes limit červeně s výstrahou.
struct CharCounter: View {
    let n: Int
    var max = NamePiece.maxLength

    var body: some View {
        let over = n > max
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                ForEach(0..<max, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(over ? Theme.red : (i < n ? Theme.accent : Theme.track))
                        .frame(width: 3, height: 10)
                }
            }
            if over {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).padding(.trailing, -4)
            }
            Text("\(n)/\(max)").monospacedDigit()
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(over ? Theme.red : Theme.text)
        .padding(.horizontal, 9)
        .frame(height: 24)
        .background(over ? Theme.redTint : Theme.raise, in: Capsule())
        .help(tr("\(n) z \(max) znaků", "\(n) of \(max) characters"))
        .animation(.snappy, value: n)
    }
}

// MARK: - Dílek šablony

/// Dílek v šabloně: úchyt, název, hodnota z ukázky, křížek. Oddělovač je malý čtvereček,
/// vlastní text se píše přímo do dílku.
struct NameChipView: View {
    @Binding var token: NameToken
    let value: String
    var small = false
    var onRemove: (() -> Void)?

    var body: some View {
        let info = NamePiece.info(token.k)
        HStack(spacing: 6) {
            if !small {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.muted)
            }
            if let glyph = info.glyph {
                Text(glyph)
                    .font(.system(size: small ? 11 : 12, weight: .semibold))
                    .frame(minWidth: small ? 14 : 18, minHeight: small ? 16 : 20)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.muted, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
            } else {
                Text(small ? info.short : info.label)
                    .font(.system(size: small ? 11 : 13, weight: .medium))
                    .foregroundStyle(Theme.accentInk)
                if token.k == "text" && !small {
                    TextField("", text: Binding(get: { token.v ?? "" }, set: { token.v = $0 }))
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .frame(width: CGFloat(max(2, (token.v ?? "").count + 1)) * 8)
                        .padding(.horizontal, 5)
                        .frame(height: 20)
                        .background(Theme.input, in: RoundedRectangle(cornerRadius: 5))
                } else if !small {
                    Text(value)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 6)
                        .frame(height: 20)
                        .background(Theme.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 5))
                }
            }
            if let onRemove, !small {
                Button(action: onRemove) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.muted)
                }
                .buttonStyle(.plain)
                .help(tr("Odebrat dílek", "Remove the piece"))

            }
        }
        .foregroundStyle(Theme.text)
        .padding(.horizontal, small ? 7 : 8)
        .frame(height: small ? 22 : 30)
        .background(info.glyph == nil ? Theme.tint : .clear, in: RoundedRectangle(cornerRadius: small ? 6 : 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: small ? 6 : 8, style: .continuous)
            .strokeBorder(info.glyph == nil ? Theme.accent.opacity(0.35) : Theme.border))
    }
}
