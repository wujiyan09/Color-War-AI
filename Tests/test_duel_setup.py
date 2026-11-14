from pathlib import Path
import unittest

SOURCE = Path(__file__).resolve().parents[1] / "ContentView.swift"
TEXT = SOURCE.read_text()


def section(start, end):
    return TEXT[TEXT.index(start):TEXT.index(end, TEXT.index(start))]


class LocalDuelSetupTests(unittest.TestCase):
    def test_duel_starts_directly_without_random_first_player_wheel(self):
        start_game = section("private func startGame(isLocalDuel", "private func startDuelGame")
        self.assertIn("if !isLocalDuel && game.isRandomFirstPlayer", start_game)
        self.assertIn("game.resetGame()", start_game)

    def test_reset_seeds_both_corners_and_red_plays_first_only_for_local_duel(self):
        reset = section("func resetGame(chosenFirstPlayer", "func restartCurrentGame")
        self.assertIn("let isLocalTwoPlayerDuel = isLocalDuelMode && active.count == 2 && !isOnlineMultiplayer", reset)
        self.assertIn("board[0][0] = Cell(owner: first, count: 1)", reset)
        self.assertIn("board[boardSize - 1][boardSize - 1] = Cell(owner: second, count: 1)", reset)
        self.assertIn("hasEntered[first] = true", reset)
        self.assertIn("hasEntered[second] = true", reset)
        self.assertIn("currentPlayer = first", reset)

    def test_duel_game_settings_hide_role_and_thinking_controls_only_for_duel(self):
        sheet = section("struct PlayerTakeoverSheet", "// MARK: - 24. 历史存档恢复导入 Sheet")
        self.assertIn("if !(game.isLocalDuelMode && game.activePlayerIndices.count == 2 && !game.isOnlineMultiplayer)", sheet)
        self.assertIn("AI 思考算力/档位调整", sheet)
        self.assertIn("实时接管控制（AI / 人类代打）", sheet)
        self.assertIn("Picker(\"\", selection:", sheet)

    def test_duel_setup_defaults_both_players_to_human(self):
        menu = section("struct StartMenuView", "private func startGame(isLocalDuel")
        self.assertIn("@State private var duelPlayerOneIsBot = false", menu)
        self.assertIn("@State private var duelPlayerTwoIsBot = false", menu)


if __name__ == "__main__":
    unittest.main()
