from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
SWIFT = "\n".join((ROOT / name).read_text() for name in ("ContentView.swift", "GameModel.swift", "AIEngine.swift"))


class NativeAnalyzerTests(unittest.TestCase):
    def test_app_forces_dark_appearance_at_the_scene_root(self):
        app = (ROOT / "MyApp.swift").read_text()
        self.assertIn("WindowGroup {\n            ContentView()\n                .preferredColorScheme(.dark)", app)

    def test_three_native_tabs_and_party_mode_picker(self):
        self.assertIn("TabView(selection: $selectedTab)", SWIFT)
        self.assertIn('Label("对弈", systemImage: "circle.grid.3x3.fill")', SWIFT)
        self.assertIn('Label("派对", systemImage: "party.popper.fill")', SWIFT)
        self.assertIn('Label("分析器", systemImage: "wrench.and.screwdriver.fill")', SWIFT)
        self.assertIn('.toolbarVisibility(', SWIFT)
        self.assertNotIn('setupTabBar', SWIFT)
        self.assertNotIn('setupTabButton', SWIFT)
        self.assertNotIn('.safeAreaInset(edge: .bottom, spacing: 0)', SWIFT)
        self.assertIn('Text("多人").tag(0)', SWIFT)
        self.assertIn('Text("联机").tag(1)', SWIFT)
        self.assertIn('Picker("派对模式", selection: $selectedPartyMode)', SWIFT)

    def test_native_tabview_is_the_root_mode_container_without_custom_top_switcher(self):
        menu = SWIFT[SWIFT.index("struct StartMenuView"):SWIFT.index("private struct AnalyzerLandingView")]
        root = SWIFT[SWIFT.index("struct ContentView: View"):]
        self.assertIn("private var setupTabs: some View {\n        TabView(selection: $selectedTab)", menu)
        self.assertIn("var body: some View {\n        tabsWithPickersAndSheets", menu)
        self.assertIn("StartMenuView(", root)
        self.assertIn(".tabItem { Label(\"对弈\"", menu)
        self.assertNotIn('Picker("主导航"', menu)
        self.assertNotIn("setupTabButton", menu)
        self.assertNotIn("setupTabBar", menu)

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

    def test_analyzer_entry_uses_native_tabview_and_system_back_navigation(self):
        setup = SWIFT[SWIFT.index("private struct AnalyzerSetupView"):SWIFT.index("private struct AnalyzerBoardView")]
        self.assertIn("Haptics.shared.lightImpact()", setup)
        menu = SWIFT[SWIFT.index("struct StartMenuView"):SWIFT.index("private struct AnalyzerLandingView")]
        landing = SWIFT[SWIFT.index("private struct AnalyzerLandingView"):SWIFT.index("// MARK: - 21.")]
        tabs = menu[menu.index("private var setupTabs"):menu.index("@ToolbarContentBuilder\n    private var setupToolbar")]
        setup_toolbar = menu[menu.index("private var setupToolbar"):menu.index("var body: some View {", menu.index("private var setupToolbar"))]
        analyzer_destination = menu[menu.index("case .analyzerPlay:"):menu.index("\n        }", menu.index("case .analyzerPlay:"))]
        self.assertIn("analyzerNavigationPath.append(.analyzerPlay)", menu)
        self.assertIn("NavigationStack(path: $analyzerNavigationPath)", menu)
        self.assertIn("NavigationStack(path: $duelNavigationPath)", menu)
        self.assertIn("NavigationStack(path: $partyNavigationPath)", menu)
        self.assertIn(".navigationDestination(for: StartMenuDestination.self)", menu)
        self.assertIn("var body: some View {\n        tabsWithPickersAndSheets", menu)
        self.assertNotIn(".toolbar(.hidden, for: .tabBar)", tabs)
        self.assertNotIn('Picker("主导航"', setup_toolbar)
        self.assertIn('Image(systemName: "square.and.arrow.down")', setup_toolbar)
        self.assertIn('.foregroundStyle(.white)', setup_toolbar)
        self.assertNotIn(".navigationBarBackButtonHidden(true)", analyzer_destination)
        self.assertNotIn("ToolbarItem", analyzer_destination)
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

    def test_duel_bot3_and_analyzer_use_the_shared_drive_core(self):
        engine = (ROOT / "AIEngine.swift").read_text()
        drive = (ROOT / "DriveBotpickEngine.swift").read_text()
        self.assertIn("if playerType == .driveBot && activePlayers.count == 2", engine)
        self.assertIn("DriveDuelSearch.bestMove", engine)
        self.assertIn("DriveBotpickEngine.bestMove", engine)
        self.assertNotIn("if level >= 3", engine)
        self.assertIn("static func applyMove(cells inputCells", drive)
        self.assertIn("static func bestMove(cells inputCells", drive)
        analyzer = SWIFT[SWIFT.index("private struct AnalyzerPlayView"):SWIFT.index("struct StartMenuView")]
        self.assertIn("playerType: .driveBot", analyzer)
        self.assertIn("DriveBotpickEngine.applyMove", analyzer)
        self.assertIn("pushUndoSnapshot()", analyzer)

    def test_portrait_hides_both_side_player_indicators(self):
        board = SWIFT[SWIFT.index("struct BoardView"):SWIFT.index("private struct AnalyzerToolPanel")]
        self.assertIn("let showPlayerIndicators = proxy.size.width > proxy.size.height", board)
        self.assertIn("let horizontalSafeInset: CGFloat = 12", board)
        self.assertIn("proxy.size.width - horizontalSafeInset * 2", board)
        self.assertGreaterEqual(board.count("if showPlayerIndicators {"), 2)
        self.assertIn("let orbWidth: CGFloat = showPlayerIndicators ? 52 : 0", board)
        self.assertIn("minDim - innerBorderPadding * 2 - gap * CGFloat(game.boardSize - 1)", board)
        self.assertNotIn(".clipped()", board)

    def test_analyzer_import_size_validation_and_native_tabbar_transition(self):
        menu = SWIFT[SWIFT.index("struct StartMenuView"):SWIFT.index("private struct AnalyzerLandingView")]
        self.assertIn("![6, 9, 12].contains(archive.boardSize)", menu)
        self.assertIn("分析器只支持导入 6×6、9×9 或 12×12 棋盘。", menu)
        self.assertIn(".toolbarVisibility(analyzerNavigationPath.isEmpty ? .visible : .hidden, for: .tabBar)", menu)
        self.assertIn(".animation(.easeInOut(duration: 0.32), value: analyzerNavigationPath.isEmpty)", menu)

    def test_game_over_overlay_displays_moves_and_elapsed_time(self):
        play = SWIFT[SWIFT.index("struct GamePlayView"):]
        self.assertIn("步数", play)
        self.assertIn("game.localDuelMoveCount", play)
        self.assertIn("elapsedGameTime", play)
        self.assertIn("Date().timeIntervalSince(game.matchStartedAt)", play)

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
        self.assertIn('Label("返回", systemImage: "chevron.left")', SWIFT)
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


    def test_analyzer_side_toggle_and_undo_have_full_button_hit_areas(self):
        panel = SWIFT[SWIFT.index("private struct AnalyzerToolPanel"):SWIFT.index("private struct AnalyzerPlayView")]
        self.assertEqual(panel.count(".contentShape(Rectangle())"), 2)
        self.assertIn("onToggleSide()", panel)
        self.assertIn("onUndo()", panel)

    def test_analyzer_four_primary_controls_have_equal_fixed_height(self):
        panel = SWIFT[SWIFT.index("private struct AnalyzerToolPanel"):SWIFT.index("private struct AnalyzerPlayView")]
        self.assertEqual(panel.count(".frame(height: compact ? 46 : 44)"), 4)
        for button in ("startButton", "pauseButton", "onToggleSide()", "onUndo()"):
            self.assertIn(button, panel)

    def test_analyzer_portrait_controls_keep_large_legible_contents(self):
        panel = SWIFT[SWIFT.index("private struct AnalyzerToolPanel"):SWIFT.index("private struct AnalyzerPlayView")]
        compact_font = ".font(compact ? .system(size: 18, weight: .semibold) : .subheadline.bold())"
        self.assertEqual(panel.count(compact_font), 4)
        self.assertEqual(panel.count(".minimumScaleFactor(0.85)"), 4)
        self.assertEqual(panel.count(".frame(height: compact ? 46 : 44)"), 4)
        self.assertIn("minHeight: compact ? 40 : 38", panel)
        self.assertIn("width: compact ? 9 : 6, height: compact ? 9 : 6", panel)
        self.assertIn("proxy.size.height - 374", SWIFT)

    def test_analyzer_uses_deep_search_with_five_second_cap_from_opening(self):
        self.assertIn("timeLimitOverride: TimeInterval? = nil", SWIFT)
        self.assertIn("min(5000, max(20, (timeLimitOverride ?? 5.0) * 1000))", SWIFT)
        self.assertIn("if movesPlayed < 30, ownMoves < 12", SWIFT)
        self.assertIn("DriveOpeningBook.nextOwnedMove", SWIFT)
        self.assertIn("directBotpickSearch: Bool = false", SWIFT)
        analyzer = SWIFT[SWIFT.index("private func runSelfMove()"):SWIFT.index("private func startOrResume()")]
        self.assertIn("aiLevel: .extreme", analyzer)
        self.assertIn("searchTimeLimitOverride: 5.0", analyzer)
        self.assertIn("directBotpickSearch: true", analyzer)

    def test_analyzer_counter_removed_and_gameplay_header_is_compact(self):
        analyzer = SWIFT[SWIFT.index("private struct AnalyzerPlayView"):SWIFT.index("struct StartMenuView")]
        gameplay = SWIFT[SWIFT.index("struct GamePlayView"):SWIFT.index("// MARK: - 23.")]
        self.assertNotIn("moveCounter", analyzer)
        self.assertNotIn("本步", analyzer)
        toolbar = SWIFT[SWIFT.index("private var gameToolbar"):SWIFT.index("private func handleArchiveSelection")]
        self.assertIn(r'Text("\(game.localDuelMoveCount)步")', toolbar)
        self.assertIn("TimelineView(.periodic(from: .now, by: 1))", toolbar)
        self.assertIn('game.currentPlayer == 0 ? "红" : "蓝"', toolbar)
        self.assertIn('Text("·")', toolbar)
        self.assertIn('.accessibilityLabel("设置")', toolbar)
        self.assertNotIn('square.and.arrow.down', toolbar)
        self.assertNotIn('photo.badge.plus', toolbar)
        self.assertNotIn('Image(systemName: "chevron.left")', gameplay)
        self.assertNotIn('Image(systemName: "gearshape.fill")', gameplay)
        self.assertIn(".animation(.easeInOut(duration: 0.45), value: game.currentPlayer)", gameplay)
        self.assertIn("@Published private(set) var localDuelMoveCount = 0", SWIFT)
        self.assertIn("localDuelMoveCount += 1", SWIFT)
        self.assertIn("CW_CustomBackground.jpg", SWIFT)
        self.assertIn(".frame(maxWidth: 440)", SWIFT)
        self.assertNotIn("AI 思考算力/深度", SWIFT)
        self.assertNotIn("🧠 AI 算力等级", SWIFT)


    def test_gameplay_pushes_from_navigation_stack_for_duel_and_party(self):
        menu = SWIFT[SWIFT.index("struct StartMenuView"):SWIFT.index("private struct AnalyzerLandingView")]
        root = SWIFT[SWIFT.index("struct ContentView: View"):]
        self.assertIn("case gamePlay", menu)
        self.assertIn("case .gamePlay:", menu)
        self.assertIn("GamePlayView(game: game", menu)
        self.assertIn("partyNavigationPath.append(.gamePlay)", menu)
        self.assertIn("duelNavigationPath.append(.gamePlay)", menu)
        self.assertIn(".navigationDestination(for: StartMenuDestination.self)", menu)
        self.assertIn("var body: some View {\n        tabsWithPickersAndSheets", menu)
        self.assertIn("StartMenuView(", root)
        self.assertNotIn("Picker(\"主导航\"", menu)
        self.assertIn("startGame(mode: .duel)", menu)
        self.assertIn("onChange(of: game.shouldNavigateToGame)", menu)
        self.assertNotIn("if isGameStarted", root)

    def test_game_toolbar_has_fixed_top_level_navigation_and_tools(self):
        menu = SWIFT[SWIFT.index("struct StartMenuView"):SWIFT.index("private struct AnalyzerLandingView")]
        toolbar = menu[menu.index("private var gameToolbar"):menu.index("private func handleArchiveSelection")]
        self.assertIn("ToolbarItem(placement: .topBarLeading)", toolbar)
        self.assertIn("ToolbarItem(placement: .topBarTrailing)", toolbar)
        self.assertNotIn('Image(systemName: "square.and.arrow.down")', toolbar)
        self.assertNotIn('Image(systemName: "photo.badge.plus")', toolbar)
        self.assertIn('Image(systemName: "gearshape.fill")', toolbar)
        setup = menu[menu.index("private var setupToolbar"):menu.index("var body: some View {", menu.index("private var setupToolbar"))]
        self.assertIn("ToolbarItem(placement: .topBarLeading)", setup)
        self.assertNotIn("ToolbarItem(placement: .principal)", setup)
        self.assertNotIn('Picker("主导航", selection: $selectedTab)', setup)
        self.assertIn('Image(systemName: "square.and.arrow.down")', setup)
        self.assertIn('.foregroundStyle(.white)', setup)
        tabs = menu[menu.index("private var setupTabs"):menu.index("@ToolbarContentBuilder\n    private var setupToolbar")]
        self.assertNotIn(".toolbar(.hidden, for: .tabBar)", tabs)
        self.assertIn(".toolbarVisibility(", menu)
        self.assertNotIn("selectedPartyMode == 0", setup)
        self.assertNotIn("selectedTab == 0", setup)
        self.assertIn(".toolbarBackground(.visible, for: .navigationBar)", menu)

    def test_game_tab_bar_visibility_tracks_navigation_path_in_both_directions(self):
        menu = SWIFT[SWIFT.index("struct StartMenuView"):SWIFT.index("private struct AnalyzerLandingView")]
        destination = menu[menu.index("private func destinationView"):menu.index("private var duelNavigation")]
        duel = menu[menu.index("private var duelNavigation:"):menu.index("private var partyNavigation:")]
        party = menu[menu.index("private var partyNavigation:"):menu.index("private var analyzerNavigation:")]
        self.assertNotIn(".toolbar(.hidden, for: .tabBar)", destination)
        self.assertIn(".toolbarVisibility(duelNavigationPath.last == .gamePlay ? .hidden : .visible, for: .tabBar)", duel)
        self.assertIn(".animation(.easeInOut(duration: 0.32), value: duelNavigationPath.last == .gamePlay)", duel)
        self.assertIn(".toolbarVisibility(partyNavigationPath.last == .gamePlay ? .hidden : .visible, for: .tabBar)", party)
        self.assertIn(".animation(.easeInOut(duration: 0.32), value: partyNavigationPath.last == .gamePlay)", party)
        self.assertIn("duelNavigationPath.removeLast()", menu)
        self.assertIn("partyNavigationPath.removeLast()", menu)

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
