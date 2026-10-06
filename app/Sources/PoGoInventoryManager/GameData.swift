import AppKit
import Foundation

// ~/.pogo/pokedata.json as the app reads it (written by core/pokedata.py).

/// ~/.pogo/pokedata.json as the Battle screen reads it: the CP multipliers, the evolution lines and the "battle"
/// part (core/pokedata.py): every form with its moves, the raid stats of the moves, the type chart, weather
/// boosts and the PvPoke league rankings. None of it ships with IVory; the bot downloads it once a week.
struct GameData: Decodable {
    struct Species: Decodable {
        let name: String
        let evolutions: [String]
    }

    struct Form: Decodable {
        let name: String
        let dex: Int
        let stats: [Int]          // attack, defense, HP
        let types: [String]
        let fast: [String]
        let charged: [String]
        let elite: [String]?
    }

    /// A move's raid stats: power, duration in seconds, energy gained (fast) or spent (charged).
    struct Move: Decodable {
        let name: String
        let type: String
        let power: Double
        let duration: Double
        let energy: Double
    }

    struct TypeChart: Decodable {
        let order: [String]
        let chart: [String: [Double]]
    }

    /// One species in a league: PvPoke score 0–100, roles (lead, closer, switch, charger, attacker, consistency),
    /// the recommended moveset (fast first) and the 5 opponents it beats and loses to.
    struct Ranking: Decodable {
        let score: Double
        let roles: [Double]
        let moveset: [String]
        let beats: [String]
        let loses: [String]
    }

    /// Power-up costs from the game master: stardust and candy per power-up at each level, XL candy from level 40.
    struct Upgrades: Decodable {
        let stardust: [Int]
        let candy: [Int]
        let xl: [Int]

        /// One power-up (half a level) at this level.
        private func step(_ l: Double) -> Price {
            let i = Int(l)
            let dust = i >= 1 && i - 1 < stardust.count ? stardust[i - 1] : 0
            if l < 40 {
                return Price(stardust: dust, candy: i >= 1 && i - 1 < candy.count ? candy[i - 1] : 0, xl: 0)
            }
            return Price(stardust: dust, candy: 0, xl: i - 40 < xl.count ? xl[i - 40] : 0)
        }

        /// From one level to another in half levels, as in the game (regular Pokémon: lucky ones pay half the
        /// stardust, shadow ones 20 % more).
        func cost(from: Double, to: Double) -> Price {
            var total = Price(), l = from
            while l < to - 0.01 {
                total += step(l)
                l += 0.5
            }
            return total
        }

        /// The same cost split into the stretches where one power-up costs the same ("L15 → L20 · 11,000 dust").
        func steps(from: Double, to: Double) -> [(from: Double, to: Double, price: Price)] {
            var out: [(from: Double, to: Double, price: Price)] = []
            var l = from
            while l < to - 0.01 {
                let one = step(l)
                var end = l, run = Price()
                while end < to - 0.01, step(end) == one {
                    run += one
                    end += 0.5
                }
                out.append((l, end, run))
                l = end
            }
            return out
        }
    }

    struct Battle: Decodable {
        let pokemon: [String: Form]
        let moves: [String: Move]
        let types: TypeChart
        let weather: [String: [String]]
        let leagues: [String: [String: Ranking]]
        let upgrades: Upgrades?
    }

    /// What a power-up costs: stardust, candy and (from level 40) XL candy.
    struct Price: Equatable {
        var stardust = 0
        var candy = 0
        var xl = 0

        static func += (lhs: inout Price, rhs: Price) {
            lhs = Price(stardust: lhs.stardust + rhs.stardust, candy: lhs.candy + rhs.candy, xl: lhs.xl + rhs.xl)
        }
    }

    let cpm: [Double]
    let species: [String: Species]
    let battle: Battle?

    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pogo/pokedata.json")

    /// CP multiplier at a level in half steps (1, 1.5, 2 …): half levels are the root of the mean of the squares.
    func cpm(at level: Double) -> Double {
        let lo = max(1, min(Int(level), cpm.count))
        if level == Double(Int(level)) || lo >= cpm.count { return cpm[lo - 1] }
        let a = cpm[lo - 1], b = cpm[lo]
        return ((a * a + b * b) / 2).squareRoot()
    }

    /// CP like in the game: (attack · √defense · √HP) · CPM² / 10, at least 10.
    func cp(_ stats: [Int], _ iv: [Int], level: Double) -> Int {
        let m = cpm(at: level)
        let a = Double(stats[0] + iv[0]), d = Double(stats[1] + iv[1]), h = Double(stats[2] + iv[2])
        return max(10, Int((a * d.squareRoot() * h.squareRoot() * m * m / 10).rounded(.down)))
    }

    /// The species and all of its further evolutions that have no evolution of their own (every branch).
    func finalForms(_ sid: String) -> [String] {
        var seen: [String] = [], todo = [sid]
        while let x = todo.first {
            todo.removeFirst()
            guard !seen.contains(x) else { continue }
            seen.append(x)
            todo += species[x]?.evolutions ?? []
        }
        let leaves = seen.filter { (species[$0]?.evolutions ?? []).isEmpty }
        return leaves.isEmpty ? [sid] : leaves
    }
}
