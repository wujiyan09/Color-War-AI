from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
CV = (ROOT / "ContentView.swift").read_text()
ACC = (ROOT / "Account.swift").read_text()


def section(text, start, end):
    i = text.index(start)
    return text[i:text.index(end, i + len(start))]


class RecentGamesAndAnalyzerImport(unittest.TestCase):
    def test_rolling_five_and_pinned_kept(self):
        trim = section(ACC, "private func trimAndSave", "// MARK: - 头像")
        self.assertIn("if replay.isSaved { return true }", trim)
        self.assertIn("return unsavedKept <= 5", trim)
        card = section(CV, "private struct RecentGamesCard", "// MARK: - 21.")
        self.assertIn("recorder.toggleSaved(replay.id)", card)
        self.assertIn("recorder.delete(replay.id)", card)
        self.assertIn('Text("导入分析器")', card)

    def test_import_only_two_player_games(self):
        self.assertIn("var isAnalyzerImportable: Bool", ACC)
        self.assertIn("duelSeats.count == 2", ACC)
        self.assertIn('Label("导入分析器"', section(ACC, "private struct ReplayView", "private struct ReplayBoard"))

    def test_slider_best_move_and_branch(self):
        an = section(CV, "private struct AnalyzerPlayView", "struct StartMenuView")
        self.assertIn("Slider(value: Binding(get: { Double(replayFrame) }, set: { showReplayFrame(", an)
        self.assertIn("func computeBestMoveForReplay()", an)
        self.assertIn("solver.calculateBestMove()", section(an, "func computeBestMoveForReplay", "func replayButton"))
        # Editing from a scrubbed frame detaches; the imported line itself is never mutated.
        self.assertIn("if onReplayLine { leaveReplayLine() }", an)
        self.assertNotIn("replayLine?.moves", an)
        self.assertNotIn("replayLine?.frames", an)
        self.assertIn("回到导入的对局", an)

    def test_menu_routes_import_to_analyzer_tab(self):
        menu = section(CV, "struct StartMenuView", "private struct AnalyzerLandingView")
        self.assertIn("private func importReplayToAnalyzer", menu)
        self.assertIn("selectedTab = 2", section(menu, "private func importReplayToAnalyzer", "private func openAnalyzer"))
        self.assertIn("onChange(of: matchRecorder.analyzerImportID)", menu)


if __name__ == "__main__":
    unittest.main()
