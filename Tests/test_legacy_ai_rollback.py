from pathlib import Path
import unittest

SOURCE = Path(__file__).resolve().parents[1] / "ContentView.swift"
TEXT = SOURCE.read_text()


class LegacyAIBaselineTests(unittest.TestCase):
    def test_drive_specific_search_and_opening_are_absent(self):
        self.assertNotIn("driveOpeningMove", TEXT)
        self.assertNotIn("driveCaptureValuesPrecise", TEXT)
        self.assertNotIn("Drive/PVS", TEXT)

    def test_all_difficulties_and_ai_variants_share_legacy_two_player_path(self):
        for level in ("fast", "balanced", "deep", "extreme"):
            self.assertIn(f"case {level} =", TEXT)
        self.assertIn("case mathNightmare", TEXT)
        self.assertIn("case enhancedNightmare", TEXT)
        start = TEXT.index("func calculateBestMove() async")
        end = TEXT.index("private func selectOptimalOpeningMove", start)
        section = TEXT[start:end]
        self.assertIn("if isMyFirstTurn {", section)
        self.assertIn("return selectOptimalOpeningMove(validMoves: validMoves)", section)
        self.assertIn("alivePlayerCount > 2", section)
        self.assertLess(section.index("if isMyFirstTurn {"), section.index("if playerType == .enhancedNightmare"))

    def test_multiplayer_opening_avoids_corners_when_possible(self):
        start = TEXT.index("private func isCornerOpeningMove")
        end = TEXT.index("private func selectOptimalOpeningMove", start)
        predicate = TEXT[start:end]
        self.assertIn("move.0 == 0 || move.0 == boardSize - 1", predicate)
        self.assertIn("move.1 == 0 || move.1 == boardSize - 1", predicate)
        self.assertIn("nonCornerMoves.isEmpty ? validMoves : nonCornerMoves", TEXT)

    def test_independent_ios_search_time_safety_is_retained(self):
        self.assertIn("var searchTimeBudget: TimeInterval", TEXT)
        self.assertIn("ProcessInfo.processInfo.systemUptime >= searchDeadline", TEXT)
        self.assertIn("if searchStopped { break }\n            bestMove = result.move", TEXT)


if __name__ == "__main__":
    unittest.main()
