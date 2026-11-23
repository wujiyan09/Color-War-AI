from pathlib import Path
import unittest
ACC = (Path(__file__).resolve().parents[1] / "Account.swift").read_text()

class AntiCheatUploadTests(unittest.TestCase):
    def test_record_has_replay_fields(self):
        for f in ["var moveList: [[Int]]? = nil", "var seats: [Int]? = nil", "var mySeat: Int? = nil", "var start: String? = nil", "var roomCode: String? = nil"]:
            self.assertIn(f, ACC)

    def test_finish_fills_them(self):
        self.assertIn("moveList: replay.moves.map { [$0.row, $0.column, $0.player] }", ACC)
        self.assertIn('start: game.gameMode == .duel && active.count == 2 ? "duel" : "empty"', ACC)
        self.assertIn("roomCode: isOnline ? WebSocketNetworkManager.shared.currentRoomCode : nil", ACC)

if __name__ == "__main__":
    unittest.main()
