from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
WEAK = (ROOT / "Bot2Weak.swift").read_text()
AI = (ROOT / "AIEngine.swift").read_text()
DUEL = (ROOT / "Nov15DuelSearch.swift").read_text()
PARA = (ROOT / "Nov15ParanoidSearch.swift").read_text()


class Bot2WeakTests(unittest.TestCase):
    """Bot 2 in party/online = Bot 3's engines, weakened (2026-11-24). Mirrors web bot2-weak.js."""

    def test_parameters(self):
        self.assertIn("static let mistakeRate = 0.05", WEAK)
        self.assertIn("static let mistakeWindow = 30", WEAK)
        self.assertIn("movesPlayed < 30", WEAK)
        self.assertIn("Limits(timeMs: 150, softTimeMs: 50, minTimeMs: 20, maxDepth: 4)", WEAK)
        self.assertIn("Limits(timeMs: 800, softTimeMs: 250, minTimeMs: 40, maxDepth: 8)", WEAK)
        self.assertIn("let index = Int(rng() * Double(candidates.count))", WEAK)

    def test_routing_party_and_online_only(self):
        self.assertIn("let isWeakBot2 = playerType == .enhancedNightmare && !isLocalDuelMode && !directBotpickSearch", AI)
        block = AI[AI.index("        if isWeakBot2 {"):AI.index("        if playerType == .driveBot && activePlayers.count > 2")]
        self.assertIn("Nov15DuelSearch.bestMove(", block)
        self.assertIn("level: 3, movesPlayed: localDuelMovesPlayed, weak: true)", block)
        self.assertIn("Nov15ParanoidSearch.bestMove(", block)
        self.assertIn("weak: true)", block.split("Nov15ParanoidSearch.bestMove(")[1])
        self.assertNotIn("openingSeed", block)

    def test_bot3_calls_unchanged(self):
        # Bot 3 call sites never pass weak, so the default (false) keeps its old behaviour.
        tail = AI[AI.index("        if playerType == .driveBot && activePlayers.count > 2"):]
        self.assertNotIn("weak:", tail.split("var validMoves")[0])

    def test_weak_paths_in_engines(self):
        for src in (DUEL, PARA):
            self.assertIn("weak: Bool = false, rng: () -> Double = { Double.random(in: 0..<1) }", src)
            self.assertIn("Bot2Weak.limits(movesPlayed: movesPlayed)", src)
            self.assertIn("rng() < Bot2Weak.mistakeRate", src)
            self.assertIn("let cutoff = bestScore - Bot2Weak.mistakeWindow", src)
            self.assertIn("if let picked = Bot2Weak.pick(candidates, rng: rng) { best = picked }", src)
        self.assertIn("if !weak, let seed = openingSeed", DUEL)  # no opening book for Bot 2


if __name__ == "__main__":
    unittest.main()


class Bot0LabelTests(unittest.TestCase):
    """Display-only rename (2026-11-24): duel Bot 3 -> Bot 0 · tier; party Bot 1/2 -> Bot N. Stored keys unchanged."""

    def test_labels(self):
        acct = (ROOT / "Account.swift").read_text()
        cv = (ROOT / "ContentView.swift").read_text()
        self.assertIn('"Bot 0 · " + (strength == DuelBeginnerBot.strength', acct)
        self.assertIn('return "Bot \\(n)"', acct)
        self.assertIn('aiKey = "bot3-s\\(game.duelBotStrength)"', acct)  # stored key unchanged
        self.assertIn('type == .driveBot ? "Bot 0" : type.displayName', cv)
        self.assertIn('Text("Bot 0 难度：', cv)
        self.assertIn('case .driveBot: return "Bot 3"', cv)  # party label unchanged
