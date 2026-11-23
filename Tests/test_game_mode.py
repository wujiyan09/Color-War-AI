"""Game mode is the single source of truth (duel / party / online).

Covers the 2026-11-23 regression: after playing online, a preserved WebSocket
session made isOnlineMultiplayer true and the local duel lost its diagonal opening.
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
GM = (ROOT / "GameModel.swift").read_text()
CV = (ROOT / "ContentView.swift").read_text()
ACC = (ROOT / "Account.swift").read_text()


def section(text, start, end):
    i = text.index(start)
    return text[i:text.index(end, i + len(start))]


class GameModeSourceOfTruth(unittest.TestCase):
    def test_enum_and_single_published_mode(self):
        self.assertIn("enum GameMode: String, Equatable", CV)
        for case in ("case duel", "case party", "case online"):
            self.assertIn(case, section(CV, "enum GameMode", "enum ActiveOnlineMode"))
        self.assertIn("@Published private(set) var gameMode: GameMode = .duel", GM)
        self.assertIn("var isLocalDuelMode: Bool { gameMode == .duel }", GM)
        self.assertIn("var isOnlineMultiplayer: Bool { gameMode == .online }", GM)
        self.assertNotIn("isLocalDuelMode = ", CV + GM)

    def test_connection_state_never_implies_online_mode(self):
        self.assertIn("var isOnlineLinked: Bool { gameMode == .online && WebSocketNetworkManager.shared.isConnected }", GM)
        # Inside GameModel, raw connection state is only read by isOnlineLinked and when leaving a room.
        raw = [l for l in GM.splitlines() if "WebSocketNetworkManager.shared.isConnected" in l]
        self.assertEqual(len(raw), 2, raw)

    def test_diagonal_opening_depends_only_on_mode(self):
        reset = section(GM, "func resetGame(chosenFirstPlayer", "func restartCurrentGame")
        self.assertIn("let isLocalTwoPlayerDuel = gameMode == .duel && active.count == 2", reset)
        self.assertNotIn("isConnected", section(reset, "let isLocalTwoPlayerDuel", "\n"))
        self.assertIn("board[0][0] = Cell(owner: first, count: 1)", reset)
        self.assertIn("board[boardSize - 1][boardSize - 1] = Cell(owner: second, count: 1)", reset)

    def test_local_game_cannot_send_or_receive_room_traffic(self):
        reset = section(GM, "func resetGame(chosenFirstPlayer", "func restartCurrentGame")
        self.assertIn("let isConn = isOnlineLinked", reset)
        handler = section(GM, "private func handleIncomingPacket", "if packet.action == .roomJoined")
        self.assertIn("guard gameMode == .online else { return }", handler)

    def test_online_to_duel_and_party_leave_room(self):
        enter_local = section(GM, "func enterLocalMode", "func enterOnlineMode")
        self.assertIn("leaveOnlineMode()", enter_local)
        self.assertIn("gameMode = mode", enter_local)
        duel = section(CV, "private func startDuelGame", "private var background")
        self.assertIn("game.enterLocalMode(.duel)", duel)
        self.assertIn("startGame(mode: .duel)", duel)
        start = section(CV, "private func startGame(mode: GameMode", "private func startDuelGame")
        self.assertIn("game.enterLocalMode(mode)", start)
        self.assertIn('forKey: "CW_Party_PlayerTypes"', start)  # online -> party restores local seats
        self.assertIn("startGame(mode: .party)", CV)

    def test_duel_to_online_and_rejoin_set_mode(self):
        self.assertGreaterEqual(CV.count("game.enterOnlineMode()"), 4)  # host, join, invite join, invite host
        self.assertNotIn("game.activeOnlineMode = .remoteWS", CV)
        self.assertIn("startGame(mode: .online)", CV)
        leave = section(GM, "func leaveOnlineMode", "private var lastLocalMode")
        self.assertIn("WebSocketNetworkManager.shared.disconnect()", leave)
        self.assertIn("if gameMode == .online { gameMode = lastLocalMode }", leave)
        self.assertIn("game.leaveOnlineMode()", section(CV, "RoomLobbyView(game: game, onExitLobby:", "onStartGame"))
        exit_menu = section(GM, "func exitToMenu", "func addAIToRemoteLobby")
        self.assertIn("leaveOnlineMode()", exit_menu)

    def test_background_and_mid_game_reconnect_stay_online(self):
        # Reconnect/foreground only touch networking; mode stays .online so the room is resumed, not a local game.
        self.assertIn("func resumeRemoteRoomIfNeeded()", GM)
        resume = section(GM, "func resumeRemoteRoomIfNeeded", "func exitToMenu")
        self.assertNotIn("gameMode =", resume)
        preserve = section(GM, "func returnToMenuPreservingOnlineSession", "private var isRemoteSessionSuspended")
        self.assertNotIn("gameMode =", preserve)

    def test_uploads_and_bot_delete_read_mode(self):
        self.assertIn("let isOnline = game.gameMode == .online", ACC)
        self.assertIn(".deleteDisabled(game.isOnlineMultiplayer", CV)


if __name__ == "__main__":
    unittest.main()
