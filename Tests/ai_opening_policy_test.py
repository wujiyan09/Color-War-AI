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
        multiplayer = body.index("if isMyFirstTurn && !isTwoPlayerGame")
        drive_opening = body.index("driveOpeningMove(validMoves: validMoves, moveCount: moveCounts[currentPlayer])")
        self.assertLess(multiplayer, drive_opening)
        branch = body[multiplayer:drive_opening]
        self.assertIn("let nonCornerMoves = validMoves.filter { !isCornerOpeningMove($0) }", branch)
        self.assertIn("nonCornerMoves.isEmpty ? validMoves : nonCornerMoves", branch)
        self.assertIn("selectOptimalOpeningMove", branch)

    def test_later_turns_keep_drive_search_and_corner_predicate_is_exact(self):
        body = function_body("func calculateBestMove() async -> (Int, Int)?")
        self.assertIn("return calculateAspirationNightmareMove(validMoves: validMoves)", body)
        self.assertIn("totalMovesPlayed < 30", body)
        self.assertIn("moveCounts[currentPlayer] < 12", body)
        self.assertIn("for index in max(0, moveCount)..<pattern.count", SOURCE)
        self.assertIn("best * 1_800 - enemyBest * 1_200", SOURCE)
        self.assertIn("driveCaptureValuesPrecise", SOURCE)
        self.assertIn("(mine.charge - theirs.charge) * 400", SOURCE)
        self.assertIn("+ Int(((mine.potential - theirs.potential) * 100).rounded())", SOURCE)
        self.assertNotIn("value *= 100", function_body("private func evaluateAdvancedBoard("))
        self.assertIn("if isTwoPlayerPosition && hasCriticalLink", SOURCE)
        self.assertIn("if boardSize == 5 {", SOURCE)
        self.assertIn("aiLevel != .fast || (boardSize == 5 && currentPlayer < moveCounts.count && moveCounts[currentPlayer] == 0)", body)
        diagonal_opening = function_body("private func fiveByFiveDiagonalOpeningMove(")
        self.assertIn("moveCount == 0", diagonal_opening)
        self.assertIn("distanceA > distanceB", diagonal_opening)
        self.assertIn("if cornerA != cornerB { return cornerA }", diagonal_opening)
        self.assertIn("guard [6, 9, 12].contains(n) else { return nil }", SOURCE)
        self.assertIn("? nil : WebSocketNetworkManager.shared.currentRoomCode", SOURCE)
        self.assertIn("score = -enhancedAlphaBetaNode(", SOURCE)
        search = function_body("private func enhancedAlphaBetaNode(")
        self.assertIn("myOwnedCellCount >= 3", search)
        self.assertIn("let R = depth >= 6 ? 3 : 2", search)
        self.assertIn("if index == 0", search)
        self.assertIn("alpha: -a - 1, beta: -a", search)
        self.assertIn("if eval > a && (reduction > 0 || bVal - a > 1)", search)
        self.assertIn("depth - 1 - reduction", search)
        corner = function_body("private func isCornerOpeningMove(_ move: (Int, Int)) -> Bool")
        self.assertIn("row == 0 || row == boardSize - 1", corner)
        self.assertIn("column == 0 || column == boardSize - 1", corner)


class DriveParitySearchTests(unittest.TestCase):
    def test_ios_search_has_difficulty_time_budgets_and_cooperative_deadline(self):
        self.assertIn("case .fast: return 0.08", SOURCE)
        self.assertIn("case .balanced: return 0.25", SOURCE)
        self.assertIn("case .deep: return 1.2", SOURCE)
        self.assertIn("case .extreme: return 6.0", SOURCE)
        self.assertIn("ProcessInfo.processInfo.systemUptime + aiLevel.searchTimeBudget", SOURCE)
        self.assertIn("Task.isCancelled || ProcessInfo.processInfo.systemUptime >= searchDeadline", SOURCE)
        search = function_body("private func calculateAspirationNightmareMove(")
        self.assertIn("if searchStopped", search)
        self.assertLess(search.index("if searchStopped { break }"), search.index("bestMove = result.move"))

    def test_ios_drive_ordering_and_scaled_aspiration_constants(self):
        ordering = function_body("func getOrderingScore(move: (Int, Int), depth: Int) -> Int")
        self.assertIn("if isTwoPlayer {", ordering)
        self.assertIn("score += 80_000_000", ordering)
        self.assertIn("score += 70_000_000", ordering)
        self.assertIn("score += 10_000", ordering)
        self.assertIn("score += 5_000", ordering)
        node = function_body("private func enhancedAlphaBetaNode(")
        self.assertIn("isTwoPlayerGame ? 1_000_000_000 : 1_000_000", node)
        self.assertIn("return nextCharge >= 4 ? 100_000_000 : 0", SOURCE)
        search = function_body("private func calculateAspirationNightmareMove(")
        self.assertIn("let scale = isTwoPlayer ? 100 : 1", search)
        self.assertIn("var delta = 50 * scale", search)
        self.assertIn("if delta > 4_000 * scale", search)
        self.assertIn("if isTwoPlayer {", search)
        self.assertIn("alpha = result.score - delta", search)
        self.assertIn("beta = result.score + scale", search)
        self.assertIn("alpha = result.score - scale", search)
        self.assertIn("beta = result.score + delta", search)
        self.assertIn("alpha = lastGuess - delta", search)
        self.assertIn("beta = lastGuess + delta", search)

    def test_multiplayer_policy_remains_outside_two_player_priority(self):
        bonus = function_body("private func twoPlayerTacticalOrderingBonus(")
        self.assertIn("guard activePlayers.count == 2 else { return 0 }", bonus)
        body = function_body("func calculateBestMove() async -> (Int, Int)?")
        self.assertIn("if isMyFirstTurn && !isTwoPlayerGame", body)


if __name__ == "__main__":
    unittest.main()
