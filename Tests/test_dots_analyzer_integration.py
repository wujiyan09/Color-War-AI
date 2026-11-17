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
        self.assertIn('.toolbar(.hidden, for: .tabBar)', SWIFT)
        self.assertNotIn('setupTabBar', SWIFT)
        self.assertNotIn('setupTabButton', SWIFT)
        self.assertNotIn('.safeAreaInset(edge: .bottom, spacing: 0)', SWIFT)
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
        self.assertIn("initial[size - 1][size - 1] = Cell(owner: 1, count: 1)", SWIFT)
        self.assertIn("private enum AnalyzerBrush", SWIFT)
        self.assertIn("case piece(owner: Int, count: Int)", SWIFT)
        self.assertIn("case eraser", SWIFT)
        self.assertIn("proxy.size.width >= 900 && proxy.size.height >= 620", SWIFT)
        analyzer = SWIFT[SWIFT.index("private struct AnalyzerPlayView"):SWIFT.index("struct StartMenuView")]
        self.assertNotIn("ScrollView", analyzer)
        self.assertIn("AnalyzerToolPanel", SWIFT)
        self.assertIn(".glassEffect(.regular.interactive()", SWIFT)

    def test_analyzer_entry_hides_tabs_has_haptics_and_fixed_toolbar_back(self):
        setup = SWIFT[SWIFT.index("private struct AnalyzerSetupView"):SWIFT.index("private struct AnalyzerBoardView")]
        self.assertIn("Haptics.shared.lightImpact()", setup)
        menu = SWIFT[SWIFT.index("struct StartMenuView"):SWIFT.index("private struct AnalyzerLandingView")]
        landing = SWIFT[SWIFT.index("private struct AnalyzerLandingView"):SWIFT.index("// MARK: - 21.")]
        self.assertIn("navigationPath.append(.analyzerPlay)", menu)
        self.assertIn("NavigationStack(path: $navigationPath)", menu)
        self.assertIn(".navigationDestination(for: StartMenuDestination.self)", menu)
        self.assertIn('ToolbarItem(placement: .topBarLeading)', menu)
        self.assertIn('Label("返回", systemImage: "chevron.left")', menu)
        self.assertIn('.navigationBarBackButtonHidden(true)', menu)
        self.assertIn("onStart: openAnalyzer", menu)
        self.assertIn("AnalyzerSetupView(boardSize: $boardSize, selfColor: $selfColor, onStart: onStart)", landing)

    def test_analyzer_archive_import_does_not_restore_live_game(self):
        archive_sheet = SWIFT[SWIFT.index("struct ArchivePickerSheet"):SWIFT.index("// MARK: - 25.")]
        self.assertIn("var onSelect: ((GameSaveArchive) -> Bool)? = nil", archive_sheet)
        self.assertIn("if onSelect(archive) { dismiss() }", archive_sheet)
        self.assertIn("unsupportedMessage", archive_sheet)
        self.assertIn("activeCount > 2", SWIFT)
        self.assertIn("分析器暂不支持多人棋局存档", SWIFT)
        analyzer = SWIFT[SWIFT.index("private struct AnalyzerPlayView"):SWIFT.index("struct StartMenuView")]
        self.assertIn("loadArchiveIntoAnalyzer", analyzer)
        self.assertIn("Self.makeBoard(size: archive.boardSize", analyzer)
        self.assertIn("switch selectedTab {", SWIFT)
        self.assertIn("pendingAnalyzerArchive = archive", SWIFT)
        self.assertIn("game.shouldNavigateToGame = true", SWIFT)

    def test_party_mode_picker_keeps_order_and_centers_content(self):
        party = SWIFT[SWIFT.index("private var partyTab: some View"):SWIFT.index("private func restoreSetupPreferences")]
        self.assertLess(party.index('Picker("派对模式"'), party.index('Text("COLOR WAR")'))
        self.assertIn("alignment: .center", party)

    def test_analyzer_uses_fixed_non_scroll_adaptive_centered_layout(self):
        analyzer = SWIFT[SWIFT.index("private struct AnalyzerPlayView"):SWIFT.index("struct StartMenuView")]
        self.assertIn("Color(red: 0.025, green: 0.055, blue: 0.14)", analyzer)
        self.assertIn(".ignoresSafeArea()", analyzer)
        self.assertIn("proxy.size.width >= 900 && proxy.size.height >= 620", analyzer)
        self.assertNotIn("ScrollView", analyzer)
        self.assertGreaterEqual(analyzer.count("maxHeight: .infinity, alignment: .center"), 2)
        panel = SWIFT[SWIFT.index("private struct AnalyzerToolPanel"):SWIFT.index("private struct AnalyzerPlayView")]
        self.assertIn("HStack(spacing: 8)", panel)
        self.assertIn("ForEach(1...3", panel)
        self.assertIn('Label("橡皮擦"', panel)

    def test_menu_background_uses_blue_base_and_persisted_photo(self):
        menu = SWIFT[SWIFT.index("struct StartMenuView"):SWIFT.index("private struct AnalyzerLandingView")]
        self.assertIn("Color(red: 0.025, green: 0.055, blue: 0.14)", menu)
        self.assertIn(".background(background)", menu)
        self.assertIn(".scaledToFill()", menu)
        self.assertIn("CW_CustomBackground.jpg", SWIFT)
        self.assertIn("compressionQuality: 0.72", SWIFT)

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
        self.assertIn('Image(systemName: "chevron.left")', SWIFT)
        self.assertIn(".glassEffect(.regular.interactive().tint(.darkNavyBlue), in: .capsule)", SWIFT)
        self.assertIn(".glassEffect(.regular.interactive(), in: .capsule)", SWIFT)
        self.assertGreaterEqual(SWIFT.count("Haptics.shared.lightImpact()"), 5)
        self.assertIn("Haptics.shared.lightImpact()\n            return", SWIFT)
        self.assertIn("pushUndoSnapshot()\n        highlightedCell = nil", SWIFT)
        self.assertIn("private func undoPreviousAction()", SWIFT)
        self.assertIn("onUndo: undoPreviousAction", SWIFT)
        self.assertIn("onToggleSide: toggleSelfColor", SWIFT)
        self.assertIn("@Binding var selfColor: Int", SWIFT)
        self.assertIn(".frame(maxHeight: .infinity, alignment: .center)", SWIFT)

    def test_analyzer_counter_removed_and_gameplay_header_is_compact(self):
        analyzer = SWIFT[SWIFT.index("private struct AnalyzerPlayView"):SWIFT.index("struct StartMenuView")]
        gameplay = SWIFT[SWIFT.index("struct GamePlayView"):SWIFT.index("// MARK: - 23.")]
        self.assertNotIn("moveCounter", analyzer)
        self.assertNotIn("本步", analyzer)
        self.assertIn(r'Text("\(game.localDuelMoveCount)步")', gameplay)
        self.assertIn("TimelineView(.periodic(from: .now, by: 1))", gameplay)
        self.assertIn('game.currentPlayer == 0 ? "红" : "蓝"', gameplay)
        self.assertIn('Text("·")', gameplay)
        self.assertIn(".animation(.easeInOut(duration: 0.45), value: game.currentPlayer)", gameplay)
        self.assertIn("@Published private(set) var localDuelMoveCount = 0", SWIFT)
        self.assertIn("localDuelMoveCount += 1", SWIFT)
        self.assertIn("CW_CustomBackground.jpg", SWIFT)
        self.assertIn(".frame(maxWidth: 440)", SWIFT)
        self.assertNotIn("AI 思考算力/深度", SWIFT)
        self.assertNotIn("🧠 AI 算力等级", SWIFT)

    def test_setup_preferences_are_persisted_per_mode_and_archives_do_not_overwrite_them(self):
        self.assertIn("CW_Duel_BoardSize", SWIFT)
        self.assertIn("CW_Party_BoardSize", SWIFT)
        self.assertIn("CW_Duel_PlayerOne", SWIFT)
        self.assertIn("CW_Duel_PlayerTwo", SWIFT)
        self.assertIn("CW_Party_PlayerTypes", SWIFT)
        self.assertIn("CW_SelectedPartyMode", SWIFT)
        self.assertIn("CW_Analyzer_BoardSize", SWIFT)
        self.assertIn("CW_Analyzer_SelfColor", SWIFT)
        self.assertIn("func flushSetupPreferences()", SWIFT)
        for key in ("duelBoardSize", "duelPlayerOneType", "duelPlayerTwoType", "partyBoardSize", "selectedPartyMode", "analyzerBoardSize", "analyzerSelfColor"):
            self.assertIn(f".onChange(of: {key})", SWIFT)
        self.assertIn("if !game.isOnlineMultiplayer {", SWIFT)
        self.assertIn("CW_Saved_PlayerColors", SWIFT)
        self.assertIn("CW_Saved_PlayerEmojis", SWIFT)
        self.assertIn("CW_Saved_PlayerNames", SWIFT)
        restore = SWIFT[SWIFT.index("func restoreArchive("):SWIFT.index("func deleteArchive(")]
        self.assertIn("isRestoringArchive = true", restore)
        self.assertIn("defer { isRestoringArchive = false }", restore)
        self.assertIn("guard !isRestoringArchive else { return }", SWIFT)
        self.assertIn(".onDisappear { game.flushSetupPreferences() }", SWIFT)


if __name__ == "__main__":
    unittest.main()
