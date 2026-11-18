from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
TEXT = "\n".join((ROOT / name).read_text() for name in ("ContentView.swift", "GameModel.swift", "AIEngine.swift"))


class LegacyAIBaselineTests(unittest.TestCase):
    def test_search_engine_and_application_views_are_separate_sources(self):
        engine = (ROOT / "AIEngine.swift").read_text()
        app = (ROOT / "ContentView.swift").read_text()
        self.assertIn("struct AISolver: Sendable", engine)
        self.assertIn("private struct DriveDuelSearch", engine)
        self.assertIn("enum AIDifficultyLevel", engine)
        self.assertNotIn("struct AISolver: Sendable", app)
        self.assertNotIn("private struct DriveDuelSearch", app)
        game_model = (ROOT / "GameModel.swift").read_text()
        self.assertIn("final class GameModel: ObservableObject", game_model)
        self.assertNotIn("final class GameModel: ObservableObject", app)

    def test_bot3_uses_drive_search_while_bot1_and_bot2_keep_existing_solvers(self):
        self.assertIn("case driveBot =", TEXT)
        self.assertIn("if playerType == .driveBot && activePlayers.count == 2", TEXT)
        self.assertIn("DriveDuelSearch.bestMove", TEXT)
        self.assertIn("Bot 1", TEXT)
        self.assertIn("Bot 2", TEXT)
        self.assertIn("Bot 3", TEXT)

    def test_all_difficulties_and_legacy_ai_variants_remain_available(self):
        for level in ("fast", "balanced", "deep", "extreme"):
            self.assertIn(f"case {level} =", TEXT)
        self.assertIn("case mathNightmare", TEXT)
        self.assertIn("case enhancedNightmare", TEXT)
        start = TEXT.index("func calculateBestMove() async")
        end = TEXT.index("private func selectOptimalOpeningMove", start)
        section = TEXT[start:end]
        self.assertIn("if playerType == .driveBot && activePlayers.count == 2", section)
        self.assertIn("if isMyFirstTurn {", section)
        self.assertIn("return selectOptimalOpeningMove(validMoves: validMoves)", section)
        self.assertIn("alivePlayerCount > 2", section)
        self.assertLess(section.index("if playerType == .driveBot"), section.index("if isMyFirstTurn {"))
        self.assertIn("playerType == .enhancedNightmare", section)


    def test_drive_wrapper_openings_difficulty_profiles_and_easy_randomness(self):
        book = TEXT[TEXT.index("private enum DriveOpeningBook"):TEXT.index("private struct DriveDuelSearch")]
        self.assertIn("Port of the 13 deterministic opening sequences", book)
        self.assertIn("return [", book)
        self.assertIn("hash % UInt32(patterns.count)", book)
        self.assertIn("for unit in seed.utf16", book)
        self.assertIn("startIndex: movesPlayed / 2", TEXT)
        self.assertIn("if timeLimitOverride == nil && movesPlayed < 30", TEXT)
        self.assertNotIn("level != 1 && movesPlayed < 30", TEXT)
        self.assertIn("case 1: difficulty = (80, 1)", TEXT)
        self.assertIn("case 2: difficulty = (1200, 8)", TEXT)
        self.assertIn("default: difficulty = (6000, 32)", TEXT)
        self.assertIn("phase = (400, 120, 40, 8)", TEXT)
        self.assertIn("phase = (5000, 600, 80, 32)", TEXT)
        self.assertIn("guard [6, 9, 12].contains(size) else { return nil }", book)
        self.assertIn("roll < 0.25", TEXT)
        self.assertIn("roll < 0.70", TEXT)
        self.assertIn("if level == 2 && moves.count > 1", TEXT)
        self.assertIn("Double.random(in: 0..<1) < 0.25", TEXT)
        self.assertIn("context.nodes & 255 == 0", TEXT)
        self.assertIn("ply > 0 && isPV && depth >= 3 && beta - alpha == 1 && sidePieces >= 3", TEXT)
        self.assertIn("ownCapture.best * 18 - enemyCapture.best * 12", TEXT)
        self.assertIn("(ownCapture.second - enemyCapture.second) * 4", TEXT)
        self.assertIn("charge(cells[index]) == 3", TEXT)
        self.assertIn("let extensionDepth = tactical && depth <= 3", TEXT)
        self.assertIn("reduction = searched >= 6 ? 2 : 1", TEXT)
        self.assertIn("private static func connectedComponentSize", TEXT)
        self.assertIn("private static func topCaptureScores", TEXT)

    def test_multiplayer_bot3_falls_through_to_opening_and_maxn_search(self):
        start = TEXT.index("func calculateBestMove() async")
        end = TEXT.index("private func selectOptimalOpeningMove", start)
        section = TEXT[start:end]
        drive_route = section.index("if playerType == .driveBot && activePlayers.count == 2")
        general_moves = section.index("var validMoves = getPlayableCells", drive_route)
        opening = section.index("if isMyFirstTurn && alivePlayerCount > 2", general_moves)
        search = section.index("return calculateAspirationNightmareMove(validMoves: validMoves)", opening)
        self.assertLess(drive_route, general_moves)
        self.assertLess(general_moves, opening)
        self.assertLess(opening, search)
        self.assertIn("isTwoPlayer = (aliveCount == 2)", TEXT)
        self.assertIn("maxNMultiPlayerSearch(", TEXT)

    def test_bot3_is_duel_only_not_party_or_online_add_select_ui(self):
        selectable = TEXT[TEXT.index("func validSelectableTypes("):TEXT.index("private func updateCachedPlayableCells", TEXT.index("func validSelectableTypes("))]
        self.assertIn("if isOnline { return [] }", selectable)
        self.assertIn("return [.human, .mathNightmare, .enhancedNightmare, .disabled]", selectable)
        self.assertNotIn("return [.human, .mathNightmare, .enhancedNightmare, .driveBot", selectable)

        remote_add = TEXT[TEXT.index("func addAIToRemoteLobby(type:"):TEXT.index("func updatePlayerType(", TEXT.index("func addAIToRemoteLobby(type:"))]
        self.assertIn("type != .driveBot", remote_add)
        party_menu = TEXT[TEXT.index('Menu {', TEXT.index('if isHost {', TEXT.index('struct RemoteWebSocketSetupView'))):]
        self.assertIn("ForEach([PlayerControlType.mathNightmare, .enhancedNightmare])", party_menu)
        self.assertNotIn("ForEach([PlayerControlType.mathNightmare, .enhancedNightmare, .driveBot])", party_menu)

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
