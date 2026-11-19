from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
AI = (ROOT / "AIEngine.swift").read_text()
DRIVE = (ROOT / "DriveBotpickEngine.swift").read_text()
APP = (ROOT / "ContentView.swift").read_text()
MODEL = (ROOT / "GameModel.swift").read_text()


class Bot3DriveParityTests(unittest.TestCase):
    def test_drive_source_functions_have_one_shared_swift_port(self):
        self.assertIn("My Drive/temp/dots/DotsBoard-CHX_Vctr.js", DRIVE)
        for source_fn in ("wt()", "wn()", "ze()"):
            self.assertIn(f"DotsBoard-CHX_Vctr.js `{source_fn}`", DRIVE)
        self.assertIn("static func bestMove(cells inputCells", DRIVE)
        self.assertIn("static func applyMove(cells inputCells", DRIVE)
        self.assertIn("online._code-CveaxU4E.js", AI)

    def test_drive_evaluator_weights_and_terminal_counts_match_source(self):
        for expression in (
            "(pieces[side] - pieces[opponent]) * 35",
            "(totalCharge[side] - totalCharge[opponent]) * 4",
            "(critical[side] - critical[opponent]) * 8",
            "(exposedCritical[side] - exposedCritical[opponent]) * 60",
            "(exposedCharge[side] - exposedCharge[opponent]) * 12",
        ):
            self.assertIn(expression, DRIVE)
        self.assertIn("movesRed >= 1 && movesBlue >= 1", DRIVE)
        self.assertIn("movesRed += 1", DRIVE)
        self.assertIn("movesBlue += 1", DRIVE)
        self.assertIn("if let winner = position.winner", DRIVE)

    def test_bitboard_preserves_blue_owner_bit_at_zero_charge(self):
        encode_start = DRIVE.index("private static func encode(_ side: Int, _ amount: Int)")
        encode_end = DRIVE.index("\n    }", encode_start) + len("\n    }")
        encode = DRIVE[encode_start:encode_end]
        self.assertIn("(side == 1 ? 0x80 : 0) | (amount & 0x0f)", encode)
        self.assertNotIn("guard amount > 0", encode)
        # Drive packs blue/zero-charge as 0x80, while red/zero aliases empty.
        self.assertEqual((0x80 | (0 & 0x0f)), 0x80)
        self.assertEqual((0x00 | (0 & 0x0f)), 0x00)
        analyzer = APP[APP.index("private struct AnalyzerPlayView"):APP.index("struct StartMenuView")]
        self.assertIn("guard let side = cell.owner else { return 0 }", analyzer)
        wrapper_start = AI.index("static func bestMove(board: AISolver.Board")
        wrapper_end = AI.index("// MARK: - 7.", wrapper_start)
        wrapper = AI[wrapper_start:wrapper_end]
        self.assertIn("guard let owner = value.owner", wrapper)
        self.assertNotIn("value.count > 0 else { continue }", wrapper)
        # The move search preserves zero-charge ownership; animation is now the
        # pre-port GameModel path rather than a snapshot-based transition.
        resolver_start = MODEL.index("private func resolveMove(")
        resolver_end = MODEL.index("private func updateEliminationStatus()", resolver_start)
        resolver = MODEL[resolver_start:resolver_end]
        self.assertIn("flyingOrbs = transfers", resolver)
        self.assertNotIn("animateDriveBotTransition", MODEL)

    def test_drive_transition_uses_source_charge_reset_and_queue_order(self):
        self.assertIn("DriveBotpickEngine.neighbors(explodingIndex, size)", DRIVE)
        self.assertIn("let wave = cells.indices.filter", DRIVE)
        self.assertIn("setCell(explodingIndex, 0)", DRIVE)
        self.assertIn("DriveBotpickEngine.charge(cells[adjacent]) + 1", DRIVE)
        self.assertIn("if redCount == 0 || blueCount == 0", DRIVE)
        self.assertIn("captureCascade", DRIVE)
        self.assertIn("cascadeFrames: trace.waves", DRIVE)

    def test_search_matches_drive_pruning_order_and_budget_stopping(self):
        for fragment in (
            "position.side = 1 - oldSide",  # source bitboard null-move pruning
            "depth >= 6 ? 3 : 2",
            "alpha: -beta, beta: -alpha",
            "context.nodes & 4095 == 0",
            "stable insertion sort",
            "limits.maxDepth > 0",
            "context.table[hash] = Entry",
            "if quiet { recordQuietCutoff",
        ):
            self.assertIn(fragment, DRIVE)
        self.assertNotIn("PVS", DRIVE)
        self.assertNotIn("LMR", DRIVE)
        self.assertNotIn("tactical extension", DRIVE)

    def test_all_two_player_bot3_levels_route_through_drive_wrapper_and_core(self):
        route_start = AI.index("func calculateBestMove() async")
        route_end = AI.index("var validMoves = getPlayableCells", route_start)
        route = AI[route_start:route_end]
        self.assertIn("playerType == .driveBot && activePlayers.count == 2", route)
        self.assertIn("DriveDuelSearch.bestMove", route)
        wrapper = AI[AI.index("private struct DriveDuelSearch"):AI.index("// MARK: - 7.")]
        self.assertIn("DriveBotpickEngine.bestMove", wrapper)
        self.assertNotIn("if level >= 3", wrapper)
        self.assertNotIn("private static func evaluate(_ cells", wrapper)
        self.assertIn("maxNMultiPlayerSearch(", AI)

    def test_drive_wrapper_has_opening_modes_move_counts_and_budgets(self):
        wrapper = AI[AI.index("enum DriveOpeningBook"):AI.index("// MARK: - 7.")]
        for fragment in (
            "guard [6, 9, 12].contains(size)",
            "2_166_136_261",
            "16_777_619",
            "movesRed: 20, movesBlue: 20",
            "if movesPlayed < 30, ownMoves < 12",
            "timeMs: 400, softTimeMs: 120",
            "minTimeMs: 40, maxDepth: 8",
            "timeMs: 5000, softTimeMs: 1200",
            "minTimeMs: 60, maxDepth: 32",
            "difficulty: .medium, timeMs: 200, maxDepth: 3",
            "350 + Double.random(in: 0..<1) * 400",
            "directBotpickSearch",
        ):
            self.assertIn(fragment, wrapper)
        self.assertNotIn("if level <= 1", wrapper)
        self.assertNotIn("if level == 2", wrapper)
        self.assertIn("let actualMovesRed = firstSide == 0 ? firstSideMoves : secondSideMoves", wrapper)

    def test_analyzer_and_duel_share_search_and_move_transition_with_five_second_cap(self):
        analyzer = APP[APP.index("private struct AnalyzerPlayView"):APP.index("struct StartMenuView")]
        self.assertIn("playerType: .driveBot", analyzer)
        self.assertIn("aiLevel: .extreme", analyzer)
        self.assertIn("activePlayers: [0, 1]", analyzer)
        self.assertIn("searchTimeLimitOverride: 5.0", analyzer)
        self.assertIn("DriveBotpickEngine.applyMove", analyzer)
        self.assertIn("selfColor", analyzer)
        self.assertIn("moveCount", analyzer)
        self.assertIn("pushUndoSnapshot()", analyzer)
        self.assertIn("undoStack", analyzer)
        self.assertIn("selectedBrush", analyzer)

        self.assertIn("DriveBotpickEngine.bestMove", AI)
        resolver_start = MODEL.index("private func resolveMove(")
        resolver_end = MODEL.index("private func updateEliminationStatus()", resolver_start)
        resolver = MODEL[resolver_start:resolver_end]
        for fragment in (
            "Task.sleep(nanoseconds: 210_000_000)",
            "Task.sleep(nanoseconds: 85_000_000)",
            "flyingOrbs = transfers",
            ".easeIn(duration: 0.07)",
            ".easeOut(duration: 0.16)",
            ".spring(response: 0.18, dampingFraction: 0.68)",
            "Task.sleep(nanoseconds: 165_000_000)",
            "Task.sleep(nanoseconds: 120_000_000)",
        ):
            self.assertIn(fragment, resolver)
        self.assertNotIn("animateDriveBotTransition", MODEL)

    def test_analyzer_budget_override_cannot_exceed_drive_hard_cap(self):
        wrapper = AI[AI.index("private struct DriveDuelSearch"):AI.index("// MARK: - 7.")]
        self.assertIn("min(5000, max(20, (timeLimitOverride ?? 5.0) * 1000))", wrapper)
        self.assertIn("directBotpickSearch: true", APP)
        self.assertIn("softTimeMs: nil", wrapper)
        self.assertIn("let hardDeadline", DRIVE)
        self.assertIn("limits.timeMs", DRIVE)


if __name__ == "__main__":
    unittest.main()


class Bot3Nov15RestoreTests(unittest.TestCase):
    def test_bot3_routes_to_nov15_search(self):
        import pathlib
        root = pathlib.Path(__file__).resolve().parents[1]
        ai = (root / "AIEngine.swift").read_text()
        n15 = (root / "Nov15DuelSearch.swift").read_text()
        self.assertIn("return Nov15DuelSearch.bestMove(board: board", ai)
        self.assertIn("Nov15DuelSearch.timeBudget(level: 3", ai)
        self.assertIn("phase = (5000, 600, 80, 32)", n15)
        self.assertIn("default: difficulty = (6000, 32, false)", n15)
