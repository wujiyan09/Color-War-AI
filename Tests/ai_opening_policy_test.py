"""Source-level regression checks for iOS opening/search routing (SwiftUI toolchain unavailable here)."""
from pathlib import Path
import unittest

SOURCE = (Path(__file__).resolve().parents[1] / "ContentView.swift").read_text()


def function_body(signature: str) -> str:
    start = SOURCE.index(signature)
    opening = SOURCE.index("{", start)
    depth = 0
    for index in range(opening, len(SOURCE)):
        if SOURCE[index] == "{":
            depth += 1
        elif SOURCE[index] == "}":
            depth -= 1
            if depth == 0:
                return SOURCE[opening + 1:index]
    raise AssertionError(f"Unclosed function: {signature}")


class OpeningPolicyTests(unittest.TestCase):
    def test_multiplayer_first_move_uses_legacy_noncorner_selector(self):
        body = function_body("func calculateBestMove() async -> (Int, Int)?")
        multiplayer = body.index("if isMyFirstTurn && alivePlayerCount > 2")
        drive_opening = body.index("driveOpeningMove(validMoves: validMoves)")
        self.assertLess(multiplayer, drive_opening)
        branch = body[multiplayer:drive_opening]
        self.assertIn("validMoves.filter { !isCornerOpeningMove($0) }", branch)
        self.assertIn("nonCornerMoves.isEmpty ? validMoves : nonCornerMoves", branch)
        self.assertIn("selectOptimalOpeningMove", branch)

    def test_later_turns_keep_drive_search_and_corner_predicate_is_exact(self):
        body = function_body("func calculateBestMove() async -> (Int, Int)?")
        self.assertIn("return calculateAspirationNightmareMove(validMoves: validMoves)", body)
        corner = function_body("private func isCornerOpeningMove(_ move: (Int, Int)) -> Bool")
        self.assertIn("row == 0 || row == boardSize - 1", corner)
        self.assertIn("column == 0 || column == boardSize - 1", corner)


if __name__ == "__main__":
    unittest.main()
