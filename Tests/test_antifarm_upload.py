from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[1]
ACC = (ROOT / "Account.swift").read_text()
GM = (ROOT / "GameModel.swift").read_text()

class AntiFarmUploadTests(unittest.TestCase):
    def test_optional_fields(self):
        for f in ["var moveList: [[Int]]? = nil", "var finalBoard: String? = nil", "var restored: Bool? = nil"]:
            self.assertIn(f, ACC)

    def test_record_fills_seat_row_col(self):
        self.assertIn("moveList: replay.moves.map { [$0.player, $0.row, $0.column] }", ACC)
        self.assertIn("finalBoard: replay.frames.last", ACC)
        self.assertIn("restored: currentRestored ? true : nil", ACC)

    def test_restore_starts_fresh_record(self):
        body = GM[GM.index("func restoreArchive"):GM.index("func deleteArchive")]
        self.assertIn("MatchRecorder.shared.beginRestored(self)", body)
        self.assertIn("func beginRestored(_ game: GameModel)", ACC)

    def test_local_history_is_slim(self):
        self.assertIn("slim.moveList = nil", ACC)

if __name__ == "__main__":
    unittest.main()
