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
        marker = "if !(game.isLocalDuelMode && game.activePlayerIndices.count == 2 && !game.isOnlineMultiplayer) {"
        self.assertIn(marker, sheet)
        start = sheet.index(marker) + len(marker)
        depth = 1
        end = start
        while depth:
            if sheet[end] == "{":
                depth += 1
            elif sheet[end] == "}":
                depth -= 1
            end += 1
        duel_settings_block = sheet[start:end - 1]
        self.assertNotIn("AI 思考算力/档位调整", duel_settings_block)
        self.assertNotIn("Slider(", duel_settings_block)
        self.assertIn("实时接管控制（AI / 人类代打）", duel_settings_block)
        self.assertIn("Picker(\"\", selection:", duel_settings_block)
        self.assertIn("Haptics.shared.lightImpact()", section("private func playerCard(", "    var body: some View {"))

    def test_duel_setup_defaults_both_players_to_human(self):
        menu = section("struct StartMenuView", "private func startGame(isLocalDuel")
        self.assertIn("@State private var duelPlayerOneType: PlayerControlType = UserDefaults.standard.data(forKey: \"CW_Duel_PlayerOne\")", menu)
        self.assertIn("@State private var duelPlayerTwoType: PlayerControlType = UserDefaults.standard.data(forKey: \"CW_Duel_PlayerTwo\")", menu)
        self.assertIn("private let selectableBotTypes: [PlayerControlType] = [.human, .mathNightmare, .enhancedNightmare, .driveBot]", TEXT)

    def test_duel_board_size_is_limited_to_supported_steps(self):
        setup = section("struct DualPlayerSetupView", "// MARK: - 16. Tab 1: 局域网 P2P Setup View")
        self.assertIn("private let supportedBoardSizes = [6, 9, 12]", setup)
        self.assertIn("in: 6...12", setup)
        self.assertIn("step: 3", setup)
        self.assertIn(".onAppear", setup)
        multiplayer = section("struct LocalGameSetupView", "struct DualPlayerSetupView")
        self.assertIn("in: 5...12", multiplayer)
        self.assertIn("step: 1", multiplayer)


if __name__ == "__main__":
    unittest.main()
