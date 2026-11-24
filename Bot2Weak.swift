import Foundation

// Bot 2 in party / online games (2026-11-24): Bot 3's engines, weakened.
// 3+ alive -> Nov15ParanoidSearch, 2 alive -> Nov15DuelSearch (no opening book),
// both called with `weak: true`. Same evaluation weights and move ordering as
// Bot 3; only the budgets below and a small root mistake are different.
// Mirrored on the web in bot2-weak.js (keep the numbers identical).
enum Bot2Weak {
    /// Chance per move to play a near-best root move instead of the best one.
    static let mistakeRate = 0.15
    /// A root move qualifies for a mistake when it scores >= best - mistakeWindow.
    static let mistakeWindow = 30

    struct Limits { let timeMs: Double; let softTimeMs: Double; let minTimeMs: Double; let maxDepth: Int }

    /// < 30 plies: depth 4, 150 ms. Later: depth 8, 800 ms.
    static func limits(movesPlayed: Int) -> Limits {
        movesPlayed < 30
            ? Limits(timeMs: 150, softTimeMs: 50, minTimeMs: 20, maxDepth: 4)
            : Limits(timeMs: 800, softTimeMs: 250, minTimeMs: 40, maxDepth: 8)
    }

    /// Picks uniformly among qualifying near-best moves (rng in [0, 1)).
    static func pick(_ candidates: [Int], rng: () -> Double) -> Int? {
        guard !candidates.isEmpty else { return nil }
        let index = Int(rng() * Double(candidates.count))
        return candidates[max(0, min(candidates.count - 1, index))]
    }
}
