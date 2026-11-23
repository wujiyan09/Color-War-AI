from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
BOT = (ROOT / "DuelBeginnerBot.swift").read_text()
GM = (ROOT / "GameModel.swift").read_text()
CV = (ROOT / "ContentView.swift").read_text()
ACC = (ROOT / "Account.swift").read_text()
ENGINE_FILES = ["Nov15DuelSearch.swift", "Nov15ParanoidSearch.swift", "AIEngine.swift",
                "DriveBotpickEngine.swift", "DotsPickEngine.swift"]


class DuelBeginnerTests(unittest.TestCase):
    def test_wrapper_uses_only_public_engine_rules(self):
        self.assertIn("Nov15DuelSearch.applyMove(board: board, row: r, column: c, side: side, entered: entered[side])", BOT)
        self.assertNotIn("Nov15DuelSearch.bestMove(", BOT)

    def test_legality_every_candidate_is_a_legal_validated_move(self):
        self.assertIn("for (r, c) in legalMoves(board, side: side, entered: entered[side])", BOT)
        self.assertIn("guard let next = Nov15DuelSearch.applyMove", BOT)  # illegal -> nil -> skipped
        self.assertIn("entered ? (cell.owner == side && cell.count > 0) : (cell.owner == nil || cell.count == 0)", BOT)
        self.assertIn("noisy.prefix(3).randomElement", BOT)  # random choice only among ranked legal candidates

    def test_distribution_parameters(self):
        self.assertIn("static let noise = 40.0", BOT)
        self.assertIn("static let topRandomChance = 0.3", BOT)

    def test_new_key_and_existing_keys_intact(self):
        self.assertIn('static let aiKey = "bot3-s0"', BOT)
        self.assertIn('aiKey = "bot3-s\\(game.duelBotStrength)"', ACC)
        self.assertIn("aiKey = DuelBeginnerBot.aiKey", ACC)

    def test_routing_and_slider(self):
        self.assertIn("self.duelBotStrength == DuelBeginnerBot.strength", GM)
        self.assertIn("duelStrength: self.duelBotStrength", GM)  # levels 1-4 still go to the engine
        self.assertIn("in: Double(DuelBeginnerBot.strength)...Double(Nov15DuelSearch.maxStrength)", CV)
        self.assertIn('forKey: "CW_Duel_BotBeginner"', GM)

    def test_engine_files_untouched(self):
        out = subprocess.run(["git", "diff", "origin/main", "--stat", "--"] + ENGINE_FILES,
                             cwd=ROOT, capture_output=True, text=True).stdout
        self.assertEqual(out.strip(), "")


if __name__ == "__main__":
    unittest.main()
