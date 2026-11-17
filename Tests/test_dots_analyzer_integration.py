from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
SWIFT = (ROOT / "ContentView.swift").read_text()


class NativeAnalyzerTests(unittest.TestCase):
    def test_three_native_tabs_and_party_mode_picker(self):
        self.assertIn("TabView(selection: $selectedTab)", SWIFT)
        self.assertIn('Label("对弈", systemImage: "gamecontroller.fill")', SWIFT)
        self.assertIn('Label("派对", systemImage: "person.3.fill")', SWIFT)
        self.assertIn('Label("分析器", systemImage: "magnifyingglass")', SWIFT)
        self.assertIn('Text("多人").tag(0)', SWIFT)
        self.assertIn('Text("联机").tag(1)', SWIFT)
        self.assertIn('Picker("派对模式", selection: $selectedPartyMode)', SWIFT)

    def test_analyzer_setup_offers_supported_sizes_and_self_color(self):
        self.assertIn("private let supportedSizes = [6, 9, 12]", SWIFT)
        self.assertIn('Text("红色").tag(0)', SWIFT)
        self.assertIn('Text("蓝色").tag(1)', SWIFT)
        self.assertIn('Label("进入分析", systemImage: "sparkle.magnifyingglass")', SWIFT)

    def test_native_board_has_corner_setup_editing_tools_and_responsive_layout(self):
        self.assertIn("initial[0][0] = Cell(owner: 0, count: 1)", SWIFT)
        self.assertIn("initial[boardSize - 1][boardSize - 1] = Cell(owner: 1, count: 1)", SWIFT)
        self.assertIn("private enum AnalyzerBrush", SWIFT)
        self.assertIn("case piece(owner: Int, count: Int)", SWIFT)
        self.assertIn("case eraser", SWIFT)
        self.assertIn("proxy.size.width >= 940", SWIFT)
        self.assertIn("proxy.size.width >= 780", SWIFT)
        self.assertIn("AnalyzerToolPanel", SWIFT)
        self.assertIn(".glassEffect(.regular.interactive()", SWIFT)

    def test_analysis_runs_duel_solver_and_waits_for_opponent(self):
        self.assertIn("isLocalDuelMode: true", SWIFT)
        self.assertIn("let move = await solver.calculateBestMove()", SWIFT)
        self.assertIn("highlightedCell = row * boardSize + column", SWIFT)
        self.assertIn("waitingForOpponent = true", SWIFT)
        self.assertIn("highlightedCell = nil", SWIFT)
        self.assertIn("board[row][column].owner == 1 - selfColor", SWIFT)
        self.assertIn("case let .piece(owner, count): board[row][column] = Cell(owner: owner, count: count)", SWIFT)
        self.assertIn("case .eraser: board[row][column] = Cell(owner: nil, count: 0)", SWIFT)
        self.assertIn(".disabled(isLocked)", SWIFT)

    def test_analyzer_and_duel_show_glass_move_counter_and_old_panel_is_removed(self):
        self.assertIn(r'Label("已走 \(moveCount) 步", systemImage: "arrow.left.arrow.right")', SWIFT)
        self.assertIn(r'Label("已走 \(game.localDuelMoveCount) 步", systemImage: "arrow.left.arrow.right")', SWIFT)
        self.assertIn("@Published private(set) var localDuelMoveCount = 0", SWIFT)
        self.assertNotIn("showDotsAnalyzer", SWIFT)
        self.assertNotIn("DotsAnalyzerWebView", SWIFT)
        self.assertNotIn("struct DotsAnalyzerView", SWIFT)
        self.assertNotIn('Label("打开离线分析器"', SWIFT)


if __name__ == "__main__":
    unittest.main()
