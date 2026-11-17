from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
SWIFT = (ROOT / "ContentView.swift").read_text()


class NativeAnalyzerTests(unittest.TestCase):
    def test_three_native_tabs_and_party_mode_picker(self):
        self.assertIn("TabView(selection: $selectedTab)", SWIFT)
        self.assertIn('Label("对弈", systemImage: "circle.grid.3x3.fill")', SWIFT)
        self.assertIn('Label("派对", systemImage: "party.popper.fill")', SWIFT)
        self.assertIn('Label("分析器", systemImage: "wrench.and.screwdriver.fill")', SWIFT)
        self.assertIn('.toolbar(hideAnalyzerTabBar ? .hidden : .visible, for: .tabBar)', SWIFT)
        self.assertIn('Text("多人").tag(0)', SWIFT)
        self.assertIn('Text("联机").tag(1)', SWIFT)
        self.assertIn('Picker("派对模式", selection: $selectedPartyMode)', SWIFT)

    def test_analyzer_setup_offers_supported_sizes_and_self_color(self):
        self.assertIn("private let supportedSizes = [6, 9, 12]", SWIFT)
        self.assertIn('Text("红色").tag(0)', SWIFT)
        self.assertIn('Text("蓝色").tag(1)', SWIFT)
        self.assertIn('Label("进入分析器", systemImage: "sparkle.magnifyingglass")', SWIFT)

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
        self.assertIn("playerType: .driveBot", SWIFT)
        self.assertIn("let move = await solver.calculateBestMove()", SWIFT)
        self.assertIn("highlightedCell = row * boardSize + column", SWIFT)
        self.assertIn("waitingForOpponent = true", SWIFT)
        self.assertIn("highlightedCell = nil", SWIFT)
        self.assertIn("board[row][column].owner == 1 - selfColor", SWIFT)
        self.assertIn("case let .piece(owner, count): board[row][column] = Cell(owner: owner, count: count)", SWIFT)
        self.assertIn("case .eraser: board[row][column] = Cell(owner: nil, count: 0)", SWIFT)
        self.assertIn(".disabled(isLocked)", SWIFT)
        self.assertIn("isLocked: analysisStarted && !isPaused", SWIFT)
        self.assertIn("if !analysisStarted || isPaused", SWIFT)
        self.assertIn("Label(\"返回\", systemImage: \"chevron.left\")", SWIFT)
        self.assertIn(".glassEffect(.regular.interactive().tint(.darkNavyBlue), in: .capsule)", SWIFT)
        self.assertIn(".glassEffect(.regular.interactive(), in: .capsule)", SWIFT)
        self.assertGreaterEqual(SWIFT.count("Haptics.shared.lightImpact()"), 5)
        self.assertIn("Haptics.shared.lightImpact()\n            return", SWIFT)
        self.assertIn("Haptics.shared.lightImpact()\n        highlightedCell = nil", SWIFT)

    def test_analyzer_and_duel_show_glass_move_counter_and_old_panel_is_removed(self):
        self.assertIn(r'Text("已走 \(moveCount) 步")', SWIFT)
        self.assertIn(r'Text("已走 \(game.localDuelMoveCount) 步")', SWIFT)
        self.assertIn(r'Text("本局 \(Self.duration(now.timeIntervalSince(game.matchStartedAt)))")', SWIFT)
        self.assertIn(r'Text("本步 \(Self.duration(now.timeIntervalSince(game.currentMoveStartedAt)))")', SWIFT)
        self.assertIn("@Published private(set) var localDuelMoveCount = 0", SWIFT)
        self.assertIn("localDuelMoveCount += 1", SWIFT)
        self.assertIn("currentMoveStartedAt = Date()", SWIFT)
        self.assertIn("hideTabBar = true", SWIFT)
        self.assertIn("onBack: { started = false; hideTabBar = false }", SWIFT)
        self.assertIn("Bot 1", SWIFT)
        self.assertIn("Bot 2", SWIFT)
        self.assertIn("Bot 3", SWIFT)
        self.assertIn("selectableBotTypes[(current + 1) % selectableBotTypes.count]", SWIFT)
        self.assertIn("ForEach([PlayerControlType.mathNightmare, .enhancedNightmare, .driveBot])", SWIFT)
        self.assertNotIn("AI 思考算力/深度", SWIFT)
        self.assertNotIn("🧠 AI 算力等级", SWIFT)
        self.assertIn(".scaledToFill()", SWIFT)
        self.assertIn(".frame(width: proxy.size.width, height: proxy.size.height)", SWIFT)
        self.assertIn(".clipped()", SWIFT)
        self.assertIn("Color(red: 0.025, green: 0.055, blue: 0.14)", SWIFT)
        self.assertNotIn("showDotsAnalyzer", SWIFT)
        self.assertNotIn("DotsAnalyzerWebView", SWIFT)
        self.assertNotIn("struct DotsAnalyzerView", SWIFT)
        self.assertNotIn('Label("打开离线分析器"', SWIFT)


if __name__ == "__main__":
    unittest.main()
