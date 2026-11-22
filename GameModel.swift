import SwiftUI
import Combine
import UIKit
import Foundation

// MARK: - 8. GameModel ViewModel

@MainActor
final class GameModel: ObservableObject {
    @Published var boardSize: Int {
        didSet {
            UserDefaults.standard.set(boardSize, forKey: "CW_Saved_BoardSize")
            if oldValue != boardSize && !isApplyingRoomConfiguration {
                syncRoomConfigToPeers()
            }
        }
    }
    @Published var isRandomFirstPlayer: Bool {
        didSet {
            UserDefaults.standard.set(isRandomFirstPlayer, forKey: "CW_Saved_IsRandomFirst")
            if oldValue != isRandomFirstPlayer && !isApplyingRoomConfiguration {
                syncRoomConfigToPeers()
            }
        }
    }
    /// Duel-mode Bot 3 strength slider (1...4, 4 = full Drive hard).
    @Published var duelBotStrength: Int = {
        let saved = UserDefaults.standard.integer(forKey: "CW_Duel_BotStrength")
        return (1...Nov15DuelSearch.maxStrength).contains(saved) ? saved : Nov15DuelSearch.maxStrength
    }() {
        didSet { UserDefaults.standard.set(duelBotStrength, forKey: "CW_Duel_BotStrength") }
    }
    @Published var aiDifficultyLevel: AIDifficultyLevel {
        didSet {
            UserDefaults.standard.set(aiDifficultyLevel.rawValue, forKey: "CW_Saved_AIDifficultyLevel")
            if oldValue != aiDifficultyLevel && !isApplyingRoomConfiguration {
                syncRoomConfigToPeers()
            }
        }
    }

    @Published var board: [[Cell]] = []

    @Published var playerNames: [String]
    @Published private(set) var localPlayerNames: [String]
    @Published var playerTypes: [PlayerControlType] {
        didSet {
            saveSetupPreferences()
            refreshActivePlayers()
        }
    }
    @Published var colors: [Color] {
        didSet { saveSetupPreferences() }
    }
    @Published var emojis: [String?] {
        didSet { saveSetupPreferences() }
    }
    @Published var currentPlayer: Int = 0 {
        didSet { updateCachedPlayableCells() }
    }
    @Published var myPlayerIndex: Int = 0
    @Published var hasEntered: [Bool] = Array(repeating: false, count: PlayerPreset.maxPlayers)
    @Published var eliminated: [Bool] = Array(repeating: false, count: PlayerPreset.maxPlayers) {
        didSet { updateCachedPlayableCells() }
    }
    @Published var isProcessingCascade: Bool = false
    @Published var winnerIndex: Int? = nil
    @Published var showControlSheet: Bool = false
    @Published var showArchivePickerSheet: Bool = false
    @Published var flyingOrbs: [FlyingOrb] = []
    @Published var emphasizedCells: Set<Int> = []
    @Published var showDisconnectedAlert: Bool = false
    @Published var disconnectedMessage: String = "房主已断开连接，对局已自动结束。"
    @Published var activeOnlineMode: ActiveOnlineMode = .none
    var isLocalDuelMode = false
    @Published private(set) var localDuelMoveCount = 0
    @Published private(set) var matchStartedAt: Date = Date()
    @Published private(set) var currentMoveStartedAt: Date = Date()

    @Published var customBackgroundImage: UIImage? = nil
    @Published var shouldNavigateToGame: Bool = false

    @Published private(set) var isGameInPlay: Bool = false
    @Published private(set) var activePlayerIndices: [Int] = []
    @Published private(set) var playableCells: Set<Int> = []
    @Published private(set) var cachedOrbCounts: [Int: Int] = [:]

    private var lastReceivedSeqID: UInt64 = 0
    private var isApplyingRoomConfiguration = false
    private var currentGameSessionID: UUID = UUID()
    private var actionQueue: [(Int, Int, Int)] = []
    private var pendingStateSnapshot: P2PPacket? = nil
    private var onlineSnapshotRetryWorkItem: DispatchWorkItem? = nil
    private var onlineSnapshotRetryCount = 0

    private var wsCancellable: AnyCancellable? = nil
    private var aiTask: Task<Void, Never>? = nil
    private var saveWorkItem: DispatchWorkItem? = nil
    private var isRestoringArchive = false

    var validPlayerCount: Int {
        playerTypes.filter { $0.isEnabled }.count
    }

    var canStartGame: Bool {
        validPlayerCount >= 2
    }

    func beginGame() {
        if !isGameInPlay {
            matchStartedAt = Date()
            currentMoveStartedAt = matchStartedAt
        }
        isGameInPlay = true
        checkAndRunAITurn()
    }

    func endGame() {
        isGameInPlay = false
    }

    private func refreshActivePlayers() {
        self.activePlayerIndices = playerTypes.enumerated().compactMap { $1 != .disabled ? $0 : nil }
    }

    func prepareLobbyForHosting() {
        self.playerTypes = [.human, .disabled, .disabled, .disabled, .disabled, .disabled, .disabled, .disabled]
        self.playerNames[0] = PlayerProfile.shared.myNickname
        self.myPlayerIndex = 0
        self.refreshActivePlayers()
    }

    func updateLocalPlayerName(at index: Int, to name: String) {
        guard (0..<PlayerPreset.maxPlayers).contains(index) else { return }
        var names = localPlayerNames
        names[index] = name
        localPlayerNames = names
        UserDefaults.standard.set(names, forKey: "CW_Saved_PlayerNames")
        if !isOnlineMultiplayer && activeOnlineMode == .none {
            playerNames[index] = name
        }
    }

    func prepareLocalPlayerNamesForGame() {
        guard !isOnlineMultiplayer else { return }
        playerNames = localPlayerNames
    }

    var isOnlineMultiplayer: Bool {
        WebSocketNetworkManager.shared.isConnected
    }

    func validSelectableTypes(forPlayerIndex idx: Int, isInLobby: Bool = false) -> [PlayerControlType] {
        guard idx >= 0 && idx < playerTypes.count else { return [] }
        let isOnline = isOnlineMultiplayer
        // Online seats are assigned by the room; no participant may change a seat's role.
        if isOnline { return [] }

        if !isOnline && !isInLobby && !isGameInPlay {
            // Bot 3 is offered in local party setup too (paranoid search for
            // 3+ seats, Nov15 duel search when two remain). Not online.
            return [.human, .mathNightmare, .enhancedNightmare, .driveBot, .disabled]
        }

        let isSeat0 = (idx == 0)
        let isMySeat = isOnline && (idx == myPlayerIndex)
        return PlayerControlType.allCases.filter { type in
            if (isSeat0 || isMySeat) && type == .disabled { return false }
            if isGameInPlay { return type == playerTypes[idx] || type.isAI || type == .human }
            if type == .p2pNetwork { return isOnline || isInLobby }
            return true
        }
    }

    private func updateCachedPlayableCells() {
        guard boardSize > 0, board.count == boardSize, board.first?.count == boardSize else {
            self.playableCells = []
            return
        }

        guard currentPlayer >= 0 && currentPlayer < PlayerPreset.maxPlayers,
              currentPlayer < eliminated.count,
              !eliminated[currentPlayer] else {
            self.playableCells = []
            return
        }

        let ownsAny = board.contains { $0.contains { $0.owner == currentPlayer } }
        var indices = Set<Int>()
        for r in 0..<boardSize {
            for c in 0..<boardSize {
                let cell = board[r][c]
                let idx = r * boardSize + c
                if ownsAny ? (cell.owner == currentPlayer) : (cell.owner == nil) {
                    indices.insert(idx)
                }
            }
        }
        self.playableCells = indices
    }

    private func recalculateOrbCounts() {
        var counts = [Int: Int]()
        for row in board {
            for cell in row {
                if let o = cell.owner {
                    counts[o, default: 0] += cell.count
                }
            }
        }
        if self.cachedOrbCounts != counts {
            self.cachedOrbCounts = counts
        }
    }

    private func adjustOrbCount(for player: Int?, delta: Int) {
        guard let p = player else { return }
        let current = cachedOrbCounts[p, default: 0]
        let newValue = current + delta
        cachedOrbCounts[p] = max(0, newValue)
    }

    init() {
        let savedSize = UserDefaults.standard.integer(forKey: "CW_Saved_BoardSize")
        self.boardSize = (savedSize >= 5 && savedSize <= 12) ? savedSize : 8
        self.isRandomFirstPlayer = UserDefaults.standard.object(forKey: "CW_Saved_IsRandomFirst") as? Bool ?? true

        let savedAILevel = UserDefaults.standard.integer(forKey: "CW_Saved_AIDifficultyLevel")
        self.aiDifficultyLevel = AIDifficultyLevel(rawValue: savedAILevel) ?? .balanced

        if let data = UserDefaults.standard.data(forKey: "CW_Saved_PlayerTypes"),
           let decoded = try? JSONDecoder().decode([PlayerControlType].self, from: data),
           decoded.count == PlayerPreset.maxPlayers {
            self.playerTypes = decoded.map { type in
                (type.rawValue.contains("NPU")) ? .enhancedNightmare : type
            }
        } else {
            self.playerTypes = [
                .human, .mathNightmare, .disabled, .disabled,
                .disabled, .disabled, .disabled, .disabled
            ]
        }

        let savedPlayerNames: [String]
        if let namesArray = UserDefaults.standard.stringArray(forKey: "CW_Saved_PlayerNames"),
           namesArray.count == PlayerPreset.maxPlayers {
            savedPlayerNames = namesArray
        } else {
            savedPlayerNames = PlayerPreset.defaultNames
        }
        self.localPlayerNames = savedPlayerNames
        self.playerNames = savedPlayerNames

        if let hexArray = UserDefaults.standard.stringArray(forKey: "CW_Saved_PlayerColors"),
           hexArray.count == PlayerPreset.maxPlayers {
            self.colors = hexArray.map { Color(hex: $0) }
        } else {
            self.colors = PlayerPreset.defaultColors
        }

        if let savedEmojis = UserDefaults.standard.stringArray(forKey: "CW_Saved_PlayerEmojis"),
           savedEmojis.count == PlayerPreset.maxPlayers {
            self.emojis = savedEmojis.map { $0.isEmpty ? nil : $0 }
        } else {
            self.emojis = Array(repeating: nil, count: PlayerPreset.maxPlayers)
        }

        let backgroundURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CW_CustomBackground.jpg")
        if let imgData = try? Data(contentsOf: backgroundURL), let img = UIImage(data: imgData) {
            self.customBackgroundImage = img
        } else if let legacyData = UserDefaults.standard.data(forKey: "CW_Saved_CustomBackground"),
                  let img = UIImage(data: legacyData) {
            self.customBackgroundImage = img
        } else {
            self.customBackgroundImage = nil
        }

        self.activePlayerIndices = self.playerTypes.enumerated().compactMap { $1 != .disabled ? $0 : nil }
        self.playableCells = []

        setupWebSocketListener()
        resetGame()
    }

    func saveCustomBackground(_ image: UIImage?) {
        self.customBackgroundImage = image
        let backgroundURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CW_CustomBackground.jpg")
        if let image, let data = image.jpegData(compressionQuality: 0.72) {
            if (try? data.write(to: backgroundURL, options: .atomic)) != nil {
                UserDefaults.standard.removeObject(forKey: "CW_Saved_CustomBackground")
            }
        } else {
            UserDefaults.standard.removeObject(forKey: "CW_Saved_CustomBackground")
            try? FileManager.default.removeItem(at: backgroundURL)
        }
    }

    func saveCurrentGameArchive() {
        let archive = GameSaveArchive(
            id: UUID(),
            date: Date(),
            boardSize: boardSize,
            currentPlayer: currentPlayer,
            playerNames: playerNames,
            playerTypes: playerTypes,
            colorsHex: colors.map { $0.toHex() },
            emojis: emojis,
            board: board,
            hasEntered: hasEntered,
            eliminated: eliminated,
            localDuelMoveCount: localDuelMoveCount
        )
        var list = loadAllArchives()
        list.insert(archive, at: 0)
        if let encoded = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(encoded, forKey: "CW_Saved_Game_Archives")
        }
    }

    func loadAllArchives() -> [GameSaveArchive] {
        guard let data = UserDefaults.standard.data(forKey: "CW_Saved_Game_Archives"),
              let list = try? JSONDecoder().decode([GameSaveArchive].self, from: data) else {
            return []
        }
        return list
    }

    func restoreArchive(_ archive: GameSaveArchive) {
        isRestoringArchive = true
        defer { isRestoringArchive = false }
        self.boardSize = archive.boardSize
        self.currentPlayer = archive.currentPlayer
        self.playerNames = archive.playerNames
        self.playerTypes = archive.playerTypes
        self.colors = archive.colorsHex.map { Color(hex: $0) }
        self.emojis = archive.emojis
        self.board = archive.board
        self.hasEntered = archive.hasEntered
        self.eliminated = archive.eliminated
        self.localDuelMoveCount = archive.localDuelMoveCount ?? 0
        self.recalculateOrbCounts()
        self.refreshActivePlayers()
        self.updateCachedPlayableCells()
        self.beginGame()
    }

    func deleteArchive(at indexSet: IndexSet) {
        var list = loadAllArchives()
        list.remove(atOffsets: indexSet)
        if let encoded = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(encoded, forKey: "CW_Saved_Game_Archives")
        }
    }

    private func setupWebSocketListener() {
        wsCancellable?.cancel()
        wsCancellable = WebSocketNetworkManager.shared.packetSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] packet in
                self?.handleIncomingPacket(packet)
            }
    }

    private func handleIncomingPacket(_ packet: P2PPacket) {
        if packet.action == .roomJoined {
            // A new room has a new sequence stream; reset before applying its first packet.
            lastReceivedSeqID = 0
        }
        if packet.action != .ping && packet.action != .ack && packet.action != .roomClosed {
            guard packet.sequenceID > self.lastReceivedSeqID else { return }
            self.lastReceivedSeqID = packet.sequenceID
        }

        switch packet.action {
        case .roomJoined:
            guard let seat = packet.playerIndex else { return }
            self.myPlayerIndex = seat
            if WebSocketNetworkManager.shared.isHost {
                if seat > 0 { self.playerTypes[seat] = .p2pNetwork }
            } else {
                self.playerTypes[seat] = .human
            }
            if let names = packet.playerNames { self.playerNames = names }
            if let types = packet.playerTypes {
                for i in 0..<min(types.count, self.playerTypes.count) where i != seat {
                    if WebSocketNetworkManager.shared.isHost, types[i] == .p2pNetwork { self.playerTypes[i] = .p2pNetwork }
                }
            }
            self.refreshActivePlayers()
            if WebSocketNetworkManager.shared.isHost { self.syncRoomConfigToPeers() }

        case .roomRoster:
            if let names = packet.playerNames {
                for i in 0..<min(names.count, self.playerNames.count) where !names[i].isEmpty { self.playerNames[i] = names[i] }
            }
            if let types = packet.playerTypes {
                for i in 0..<min(types.count, self.playerTypes.count) {
                    if WebSocketNetworkManager.shared.isHost {
                        if types[i] == .p2pNetwork { self.playerTypes[i] = .p2pNetwork }
                    } else if i == self.myPlayerIndex {
                        self.playerTypes[i] = .human
                    }
                }
            }
            self.refreshActivePlayers()
            if WebSocketNetworkManager.shared.isHost { self.syncRoomConfigToPeers() }

        case .renamePlayer:
            if let seat = packet.playerIndex, seat >= 0, seat < self.playerNames.count,
               let nickname = packet.nickname?.trimmingCharacters(in: .whitespacesAndNewlines), !nickname.isEmpty {
                self.playerNames[seat] = String(nickname.prefix(32))
            }

        case .playerLeft:
            if let seat = packet.playerIndex, seat >= 0, seat < self.playerTypes.count, WebSocketNetworkManager.shared.isHost {
                self.playerTypes[seat] = self.isGameInPlay ? .mathNightmare : .disabled
                self.playerNames[seat] = self.isGameInPlay ? "AI 玩家\(seat + 1)" : PlayerPreset.defaultNames[seat]
                self.refreshActivePlayers()
                self.syncRoomConfigToPeers()
                if self.currentPlayer == seat && !self.isProcessingCascade { self.checkAndRunAITurn() }
            }

        case .roomClosed:
            self.disconnectedMessage = packet.message ?? "房主已断开连接，对局已自动结束。"
            self.showDisconnectedAlert = true
            self.exitToMenu()

        case .roomError:
            break

        case .playerMove:
            if let r = packet.row, let c = packet.col, let pIdx = packet.playerIndex,
               pIdx == self.currentPlayer,
               r >= 0, r < self.boardSize, c >= 0, c < self.boardSize,
               self.playableCells.contains(r * self.boardSize + c) {
                if WebSocketNetworkManager.shared.isConnected && !WebSocketNetworkManager.shared.isHost {
                    self.beginOnlineSnapshotRecovery()
                }
                self.enqueueNetworkMove(row: r, column: c, player: pIdx)
            } else if WebSocketNetworkManager.shared.isHost {
                self.broadcastFullStateSnapshot()
            }

        case .syncRequest:
            if (WebSocketNetworkManager.shared.isHost) && !self.isProcessingCascade {
                self.broadcastFullStateSnapshot()
            }

        case .hostConfig:
            // The server echoes its canonical config to every client, including the host.
            // Applying that echo must not send another hostConfig and create a feedback loop.
            isApplyingRoomConfiguration = true
            if let names = packet.playerNames { self.playerNames = names }
            if let types = packet.playerTypes { self.playerTypes = types }
            if WebSocketNetworkManager.shared.isConnected && !WebSocketNetworkManager.shared.isHost,
               self.myPlayerIndex >= 0, self.myPlayerIndex < self.playerTypes.count {
                self.playerTypes[self.myPlayerIndex] = .human
            }
            if let hexes = packet.colorsHex { self.colors = hexes.map { Color(hex: $0) } }
            if let ems = packet.emojis { self.emojis = ems }
            // WebSocket hosts own their pending lobby selection. The server echoes each
            // canonical hostConfig to everyone, including the host; a delayed older echo
            // must not roll the host's slider back while guests still consume that config.
            if !(WebSocketNetworkManager.shared.isConnected && WebSocketNetworkManager.shared.isHost),
               let sz = packet.boardSize, (5...12).contains(sz) {
                self.boardSize = sz
            }
            if let rnd = packet.isRandomFirstPlayer { self.isRandomFirstPlayer = rnd }
            if let aiLvl = packet.aiLevelRaw, let level = AIDifficultyLevel(rawValue: aiLvl) { self.aiDifficultyLevel = level }
            isApplyingRoomConfiguration = false
            self.refreshActivePlayers()

        case .startGame:
            if let size = packet.boardSize, (5...12).contains(size) {
                self.boardSize = size
            }
            if let names = packet.playerNames {
                self.playerNames = names
            }
            if let types = packet.playerTypes {
                self.playerTypes = types
            }
            // The server roster describes connected remote seats as network players;
            // locally, this device must control its own seat as a human.
            if WebSocketNetworkManager.shared.isConnected,
               !WebSocketNetworkManager.shared.isHost,
               self.myPlayerIndex >= 0, self.myPlayerIndex < self.playerTypes.count {
                self.playerTypes[self.myPlayerIndex] = .human
            }
            self.refreshActivePlayers()
            if let firstP = packet.firstPlayerIndex {
                self.resetGame(chosenFirstPlayer: firstP)
                self.beginGame()
                self.shouldNavigateToGame = true
            }

        case .stateSnapshot:
            if packet.compactBoardSnapshot != nil && packet.currentTurnIndex != nil {
                stopOnlineSnapshotRecovery()
            }
            if isProcessingCascade {
                pendingStateSnapshot = packet
            } else {
                applyAuthoritativeSnapshot(packet)
            }

        default:
            break
        }
    }

    func renameMyPlayer(to proposedName: String) {
        let name = String(proposedName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(32))
        guard !name.isEmpty else { return }
        PlayerProfile.shared.myNickname = name
        let seat = WebSocketNetworkManager.shared.isConnected
            ? WebSocketNetworkManager.shared.playerIndex
            : myPlayerIndex
        guard seat >= 0 && seat < playerNames.count else { return }
        myPlayerIndex = seat
        if isOnlineMultiplayer {
            playerNames[seat] = name
        } else {
            updateLocalPlayerName(at: seat, to: name)
        }

        if WebSocketNetworkManager.shared.isConnected {
            let sequence = WebSocketNetworkManager.shared.getNextSequenceID()
            var packet = P2PPacket(sequenceID: sequence, action: .renamePlayer, senderID: name)
            packet.playerIndex = seat
            packet.nickname = name
            WebSocketNetworkManager.shared.sendPacket(packet)
        }
    }

    private func beginOnlineSnapshotRecovery() {
        guard WebSocketNetworkManager.shared.isConnected, !WebSocketNetworkManager.shared.isHost else { return }
        onlineSnapshotRetryWorkItem?.cancel()
        onlineSnapshotRetryCount = 0
        scheduleOnlineSnapshotRetry()
    }

    private func scheduleOnlineSnapshotRetry() {
        guard WebSocketNetworkManager.shared.isConnected, !WebSocketNetworkManager.shared.isHost,
              onlineSnapshotRetryCount < 6 else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, WebSocketNetworkManager.shared.isConnected,
                  !WebSocketNetworkManager.shared.isHost else { return }
            self.onlineSnapshotRetryCount += 1
            var packet = P2PPacket(
                sequenceID: WebSocketNetworkManager.shared.getNextSequenceID(),
                action: .syncRequest,
                senderID: PlayerProfile.shared.myNickname
            )
            packet.roomCode = WebSocketNetworkManager.shared.currentRoomCode
            WebSocketNetworkManager.shared.sendPacket(packet)
            self.scheduleOnlineSnapshotRetry()
        }
        onlineSnapshotRetryWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func stopOnlineSnapshotRecovery() {
        onlineSnapshotRetryWorkItem?.cancel()
        onlineSnapshotRetryWorkItem = nil
        onlineSnapshotRetryCount = 0
    }

    private func applyAuthoritativeSnapshot(_ packet: P2PPacket) {
        guard let compactSnap = packet.compactBoardSnapshot, let turnP = packet.currentTurnIndex,
              (0..<PlayerPreset.maxPlayers).contains(turnP) else { return }
        stopOnlineSnapshotRecovery()
        if let size = packet.boardSize, (5...12).contains(size), size != boardSize {
            boardSize = size
            updateCachedPlayableCells()
        }
        if let names = packet.playerNames { self.playerNames = names }
        if let types = packet.playerTypes { self.playerTypes = types }
        if WebSocketNetworkManager.shared.isConnected && !WebSocketNetworkManager.shared.isHost,
           self.myPlayerIndex >= 0, self.myPlayerIndex < self.playerTypes.count {
            self.playerTypes[self.myPlayerIndex] = .human
        }
        var grid = [[Cell]](repeating: [Cell](repeating: Cell(owner: nil, count: 0), count: self.boardSize), count: self.boardSize)
        for item in compactSnap {
            let r = Int(item.r)
            let c = Int(item.c)
            if r >= 0 && r < self.boardSize && c >= 0 && c < self.boardSize {
                grid[r][c] = Cell(owner: item.owner < 0 ? nil : Int(item.owner), count: Int(item.count))
            }
        }
        self.board = grid
        if let entered = packet.hasEnteredSnapshot { self.hasEntered = entered }
        if let elim = packet.eliminatedSnapshot { self.eliminated = elim }
        self.refreshActivePlayers()
        self.recalculateOrbCounts()
        self.currentPlayer = turnP
        if WebSocketNetworkManager.shared.isHost {
            self.checkAndRunAITurn()
        }
    }

    func syncRoomConfigToPeers() {
        let isHost = WebSocketNetworkManager.shared.isHost
        let isConn = WebSocketNetworkManager.shared.isConnected
        guard isHost && isConn else { return }

        let seq = UInt64.random(in: 1...999999)
        var packet = P2PPacket(sequenceID: seq, action: .hostConfig, senderID: PlayerProfile.shared.myNickname)
        packet.boardSize = boardSize
        packet.isRandomFirstPlayer = isRandomFirstPlayer
        packet.playerNames = playerNames
        packet.playerTypes = playerTypes
        packet.colorsHex = colors.map { $0.toHex() }
        packet.emojis = emojis
        packet.aiLevelRaw = aiDifficultyLevel.rawValue

        if WebSocketNetworkManager.shared.isConnected {
            WebSocketNetworkManager.shared.sendPacket(packet)
        }
    }

    private func broadcastFullStateSnapshot() {
        let isHost = WebSocketNetworkManager.shared.isHost
        let isConn = WebSocketNetworkManager.shared.isConnected
        guard isHost && isConn else { return }

        var compactList = [CompactCellSnapshot]()
        for r in 0..<boardSize {
            for c in 0..<boardSize {
                let cell = board[r][c]
                if cell.count > 0 {
                    compactList.append(CompactCellSnapshot(r: r, c: c, owner: cell.owner, count: cell.count))
                }
            }
        }

        let seq = UInt64.random(in: 1...999999)
        var packet = P2PPacket(sequenceID: seq, action: .stateSnapshot, senderID: PlayerProfile.shared.myNickname)
        packet.playerNames = playerNames
        packet.playerTypes = playerTypes
        packet.compactBoardSnapshot = compactList
        packet.currentTurnIndex = currentPlayer
        packet.hasEnteredSnapshot = hasEntered
        packet.eliminatedSnapshot = eliminated

        if WebSocketNetworkManager.shared.isConnected {
            WebSocketNetworkManager.shared.sendPacket(packet)
        }
    }

    func flushSetupPreferences() { saveSetupPreferences() }

    private func saveSetupPreferences() {
        guard !isRestoringArchive else { return }
        if !isLocalDuelMode, let encoded = try? JSONEncoder().encode(playerTypes) {
            UserDefaults.standard.set(encoded, forKey: "CW_Saved_PlayerTypes")
        }
        UserDefaults.standard.set(colors.map { $0.toHex() }, forKey: "CW_Saved_PlayerColors")
        UserDefaults.standard.set(emojis.map { $0 ?? "" }, forKey: "CW_Saved_PlayerEmojis")
    }

    private func debounceSave() { saveSetupPreferences() }

    func tryUpdatePlayerEmoji(at index: Int, newEmoji: String?) -> Bool {
        guard index >= 0 && index < PlayerPreset.maxPlayers, index < emojis.count else { return false }
        if let rawEmoji = newEmoji, !rawEmoji.isEmpty {
            let normalized = rawEmoji.precomposedStringWithCanonicalMapping
            for i in 0..<PlayerPreset.maxPlayers where i != index {
                if let existing = emojis[safe: i], let existingStr = existing, existingStr.precomposedStringWithCanonicalMapping == normalized {
                    return false
                }
            }
            emojis[index] = normalized
        } else {
            emojis[index] = nil
        }
        syncRoomConfigToPeers()
        return true
    }

    func updatePlayerColor(at index: Int, newColor: Color) {
        guard index >= 0 && index < colors.count else { return }
        colors[index] = newColor
        for otherIdx in 0..<PlayerPreset.maxPlayers where otherIdx != index {
            if colors[safe: otherIdx]?.isSimilar(to: newColor) == true {
                if let alternative = PlayerPreset.palettePool.first(where: { poolColor in
                    !colors.contains(where: { $0.isSimilar(to: poolColor) })
                }) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        colors[otherIdx] = alternative
                    }
                }
            }
        }
        syncRoomConfigToPeers()
    }

    func resetGame(chosenFirstPlayer: Int? = nil) {
        currentGameSessionID = UUID()
        stopOnlineSnapshotRecovery()
        pendingStateSnapshot = nil
        aiTask?.cancel()
        aiTask = nil
        actionQueue.removeAll()
        flyingOrbs.removeAll()
        emphasizedCells.removeAll()
        board = [[Cell]](repeating: [Cell](repeating: Cell(owner: nil, count: 0), count: boardSize), count: boardSize)
        hasEntered = Array(repeating: false, count: PlayerPreset.maxPlayers)
        eliminated = Array(repeating: false, count: PlayerPreset.maxPlayers)
        winnerIndex = nil
        isProcessingCascade = false
        localDuelMoveCount = 0
        matchStartedAt = Date()
        currentMoveStartedAt = matchStartedAt

        let active = activePlayerIndices
        guard !active.isEmpty else { return }
        let isLocalTwoPlayerDuel = isLocalDuelMode && active.count == 2 && !isOnlineMultiplayer
        if isLocalTwoPlayerDuel {
            let first = active[0]
            let second = active[1]
            board[0][0] = Cell(owner: first, count: 1)
            board[boardSize - 1][boardSize - 1] = Cell(owner: second, count: 1)
            hasEntered[first] = true
            hasEntered[second] = true
            currentPlayer = first
        } else if let chosen = chosenFirstPlayer, active.contains(chosen) {
            currentPlayer = chosen
        } else if isRandomFirstPlayer {
            currentPlayer = active.randomElement() ?? active[0]
        } else {
            currentPlayer = active[0]
        }
        recalculateOrbCounts()

        let isHost = WebSocketNetworkManager.shared.isHost
        let isConn = WebSocketNetworkManager.shared.isConnected
        if isHost && isConn {
            let seq = UInt64.random(in: 1...999999)
            var startPacket = P2PPacket(sequenceID: seq, action: .startGame, senderID: PlayerProfile.shared.myNickname)
            startPacket.firstPlayerIndex = currentPlayer
            startPacket.boardSize = boardSize
            if WebSocketNetworkManager.shared.isConnected {
                WebSocketNetworkManager.shared.sendPacket(startPacket)
            }
        }

        updateCachedPlayableCells()
        checkAndRunAITurn()
    }

    func restartCurrentGame() {
        resetGame()
        beginGame()
    }

    func returnToMenuPreservingOnlineSession() {
        shouldNavigateToGame = false
        guard !(isOnlineMultiplayer && activeOnlineMode != .none) else { return }
        exitToMenu()
    }

    func exitToMenu() {
        currentGameSessionID = UUID()
        stopOnlineSnapshotRecovery()
        pendingStateSnapshot = nil
        aiTask?.cancel()
        aiTask = nil
        actionQueue.removeAll()
        flyingOrbs.removeAll()
        emphasizedCells.removeAll()
        isProcessingCascade = false
        endGame()
        shouldNavigateToGame = false
        winnerIndex = nil
        activeOnlineMode = .none
        WebSocketNetworkManager.shared.disconnect()
    }

    @discardableResult
    func addAIToRemoteLobby() -> Bool {
        guard activeOnlineMode == .remoteWS,
              WebSocketNetworkManager.shared.isConnected,
              WebSocketNetworkManager.shared.isHost,
              !isGameInPlay,
              let seat = playerTypes.firstIndex(of: .disabled) else { return false }

        return addAIToRemoteLobby(type: .mathNightmare)
    }

    @discardableResult
    func addAIToRemoteLobby(type: PlayerControlType) -> Bool {
        guard type.isAI, type != .driveBot,
              activeOnlineMode == .remoteWS,
              WebSocketNetworkManager.shared.isConnected,
              WebSocketNetworkManager.shared.isHost,
              !isGameInPlay,
              let seat = playerTypes.firstIndex(of: .disabled) else { return false }
        playerNames[seat] = "\(type.displayName) \(seat + 1)"
        playerTypes[seat] = type
        syncRoomConfigToPeers()
        return true
    }

    func updatePlayerType(at index: Int, to newType: PlayerControlType, forceInternal: Bool = false) {
        guard index >= 0 && index < PlayerPreset.maxPlayers else { return }
        // Protect the model as well as the UI. Internal disconnect/recovery handling may still update a seat.
        if !forceInternal && isOnlineMultiplayer { return }

        if !forceInternal {
            guard newType != .driveBot || !isOnlineMultiplayer else { return }
            let valids = validSelectableTypes(forPlayerIndex: index, isInLobby: !isGameInPlay)
            guard valids.contains(newType) else { return }
        }

        if index == currentPlayer {
            aiTask?.cancel()
            aiTask = nil
        }

        playerTypes[index] = newType
        syncRoomConfigToPeers()

        if index == currentPlayer && newType.isAI && !isProcessingCascade {
            checkAndRunAITurn()
        }
    }

    func play(row: Int, column: Int, isAIMove: Bool = false) {
        let flatIdx = row * boardSize + column
        guard !isProcessingCascade,
              winnerIndex == nil,
              playableCells.contains(flatIdx),
              playerTypes.indices.contains(currentPlayer) else { return }

        let player = currentPlayer
        // Board taps are human input; they must never impersonate the AI during its turn.
        guard playerTypes[player].isAI == isAIMove else { return }
        let isConn = WebSocketNetworkManager.shared.isConnected
        let isHost = WebSocketNetworkManager.shared.isHost

        if isConn {
            let isMyTurnToControl = (playerTypes[player] == .human && myPlayerIndex == player) || (isHost && playerTypes[player].isAI)
            guard isMyTurnToControl else { return }

            let seq = UInt64.random(in: 1...999999)
            var packet = P2PPacket(sequenceID: seq, action: .playerMove, senderID: PlayerProfile.shared.myNickname)
            packet.row = row
            packet.col = column
            packet.playerIndex = player

            if WebSocketNetworkManager.shared.isConnected {
                WebSocketNetworkManager.shared.sendPacket(packet)
                if !WebSocketNetworkManager.shared.isHost { beginOnlineSnapshotRecovery() }
            }
        } else {
            guard playerTypes[player] == .human || playerTypes[player].isAI else { return }
        }

        enqueueNetworkMove(row: row, column: column, player: player)
    }

    private func enqueueNetworkMove(row: Int, column: Int, player: Int) {
        actionQueue.append((row, column, player))
        processActionQueue()
    }

    private func processActionQueue() {
        guard !isProcessingCascade && winnerIndex == nil else { return }

        Task { @MainActor in
            while !actionQueue.isEmpty && !isProcessingCascade && winnerIndex == nil {
                let (r, c, p) = actionQueue.removeFirst()
                Haptics.shared.lightImpact()
                await resolveMove(row: r, column: c, player: p)
                if !isProcessingCascade, let snapshot = pendingStateSnapshot {
                    pendingStateSnapshot = nil
                    applyAuthoritativeSnapshot(snapshot)
                }
            }
        }
    }

    private func resolveMove(row: Int, column: Int, player: Int) async {
        isProcessingCascade = true

        guard player >= 0 && player < hasEntered.count else {
            isProcessingCascade = false
            return
        }

        let boardBackup = self.board
        let hasEnteredBackup = self.hasEntered
        let isFirst = !hasEntered[player]
        hasEntered[player] = true

        do {
            let addCount = isFirst ? 3 : 1
            withAnimation(.spring(response: 0.22, dampingFraction: 0.62)) {
                if row < board.count && column < board[row].count {
                    let oldOwner = board[row][column].owner
                    if oldOwner != player {
                        adjustOrbCount(for: oldOwner, delta: -board[row][column].count)
                        adjustOrbCount(for: player, delta: board[row][column].count + addCount)
                    } else {
                        adjustOrbCount(for: player, delta: addCount)
                    }

                    board[row][column].owner = player
                    board[row][column].count += addCount
                    emphasizedCells = [row * boardSize + column]
                }
            }

            try await Task.sleep(nanoseconds: 210_000_000)

            var wave: [(Int, Int)] = (row < board.count && column < board[row].count && board[row][column].count >= 4) ? [(row, column)] : []
            let dirs = [(-1,0), (1,0), (0,-1), (0,1)]

            while !wave.isEmpty {
                try Task.checkCancellation()
                let exploding = wave
                emphasizedCells = Set(exploding.map { $0.0 * boardSize + $0.1 })
                try await Task.sleep(nanoseconds: 85_000_000)

                var transfers: [FlyingOrb] = []
                for (r, c) in exploding {
                    for (dr, dc) in dirs {
                        let nr = r + dr, nc = c + dc
                        if (0..<boardSize).contains(nr) && (0..<boardSize).contains(nc) {
                            transfers.append(FlyingOrb(
                                player: player,
                                fromRow: r, fromColumn: c,
                                toRow: nr, toColumn: nc
                            ))
                        }
                    }
                }

                withAnimation(.easeIn(duration: 0.07)) {
                    for (r, c) in exploding {
                        if r < board.count && c < board[r].count {
                            board[r][c].count -= 4
                            let newOwner = board[r][c].count == 0 ? nil : player
                            board[r][c].owner = newOwner
                            adjustOrbCount(for: player, delta: -4)
                        }
                    }
                    flyingOrbs = transfers
                }
                try await Task.sleep(nanoseconds: 30_000_000)

                withAnimation(.easeOut(duration: 0.16)) {
                    for i in flyingOrbs.indices {
                        flyingOrbs[i].arrived = true
                    }
                }
                try await Task.sleep(nanoseconds: 165_000_000)

                var changed = Set<Int>()
                withAnimation(.spring(response: 0.18, dampingFraction: 0.68)) {
                    for orb in flyingOrbs {
                        if orb.toRow < board.count && orb.toColumn < board[orb.toRow].count {
                            let oldOwner = board[orb.toRow][orb.toColumn].owner
                            let oldCount = board[orb.toRow][orb.toColumn].count

                            if oldOwner != player {
                                adjustOrbCount(for: oldOwner, delta: -oldCount)
                                adjustOrbCount(for: player, delta: oldCount + 1)
                            } else {
                                adjustOrbCount(for: player, delta: 1)
                            }

                            board[orb.toRow][orb.toColumn].owner = player
                            board[orb.toRow][orb.toColumn].count += 1
                            changed.insert(orb.toRow * boardSize + orb.toColumn)
                        }
                    }
                    flyingOrbs = []
                    emphasizedCells = changed
                }
                try await Task.sleep(nanoseconds: 120_000_000)

                wave = changed.compactMap {
                    let r = $0 / boardSize
                    let c = $0 % boardSize
                    if r < board.count && c < board[r].count {
                        return board[r][c].count >= 4 ? (r, c) : nil
                    }
                    return nil
                }
            }

            emphasizedCells = []
            updateEliminationStatus()
            recalculateOrbCounts()

            isProcessingCascade = false
            localDuelMoveCount += 1
            currentMoveStartedAt = Date()

            if checkGameOver() {
                endGame()
            } else {
                advanceToNextTurn()
            }
            if WebSocketNetworkManager.shared.isHost && WebSocketNetworkManager.shared.isConnected {
                broadcastFullStateSnapshot()
            }
        } catch {
            self.board = boardBackup
            self.hasEntered = hasEnteredBackup
            emphasizedCells = []
            flyingOrbs = []
            recalculateOrbCounts()
            isProcessingCascade = false
        }
    }

    private func updateEliminationStatus() {
        var appears = [Bool](repeating: false, count: PlayerPreset.maxPlayers)
        for row in board {
            for cell in row {
                if let o = cell.owner, o >= 0, o < PlayerPreset.maxPlayers { appears[o] = true }
            }
        }
        for p in activePlayerIndices {
            if p < hasEntered.count && p < eliminated.count {
                if hasEntered[p] && !appears[p] {
                    eliminated[p] = true
                }
            }
        }
    }

    private func checkGameOver() -> Bool {
        let alive = activePlayerIndices.filter { $0 < eliminated.count && !eliminated[$0] }
        let allEnteredOrEliminated = activePlayerIndices.allSatisfy { $0 < hasEntered.count && $0 < eliminated.count && (hasEntered[$0] || eliminated[$0]) }

        if allEnteredOrEliminated && alive.count <= 1 {
            winnerIndex = alive.first
            Haptics.shared.heavyImpact()
            return true
        }
        return false
    }

    private func advanceToNextTurn() {
        let active = activePlayerIndices
        guard !active.isEmpty, let idx = active.firstIndex(of: currentPlayer) else { return }

        var nextIdx = (idx + 1) % active.count
        var loopCount = 0

        while loopCount < active.count {
            let p = active[nextIdx]
            if p < eliminated.count && p < playerTypes.count {
                if !eliminated[p] && playerTypes[p] != .disabled {
                    break
                }
            }
            nextIdx = (nextIdx + 1) % active.count
            loopCount += 1
        }

        currentPlayer = active[nextIdx]
        checkAndRunAITurn()
    }

    private func checkAndRunAITurn() {
        aiTask?.cancel()

        guard isGameInPlay else { return }

        let isWS = WebSocketNetworkManager.shared.isConnected
        if isWS && !WebSocketNetworkManager.shared.isHost {
            return
        }

        guard winnerIndex == nil else { return }
        guard currentPlayer < playerTypes.count else { return }
        let currentType = playerTypes[currentPlayer]
        guard currentType.isAI else { return }

        let sessionID = self.currentGameSessionID
        let targetPlayer = self.currentPlayer

        aiTask = Task(priority: .userInitiated) {
            try? await Task.sleep(nanoseconds: 150_000_000)
            if Task.isCancelled { return }

            let isCurrentTurnValid = await MainActor.run {
                return self.currentGameSessionID == sessionID &&
                       self.currentPlayer == targetPlayer &&
                       self.isGameInPlay &&
                       !self.isProcessingCascade
            }
            guard isCurrentTurnValid else { return }

            let solver = AISolver(
                boardSize: boardSize,
                activePlayers: activePlayerIndices,
                currentPlayer: targetPlayer,
                playerType: currentType,
                aiLevel: aiDifficultyLevel,
                board: board,
                hasEntered: hasEntered,
                eliminated: eliminated,
                isLocalDuelMode: self.isLocalDuelMode && !isP2P && !isWS && activePlayerIndices.count == 2,
                localDuelMovesPlayed: self.localDuelMoveCount,
                duelStrength: self.duelBotStrength,
                openingSeed: "local-\(self.currentGameSessionID.uuidString)"
            )

            if let bestMove = await solver.calculateBestMove() {
                if !Task.isCancelled {
                    await MainActor.run {
                        if self.currentGameSessionID == sessionID && self.currentPlayer == targetPlayer && self.isGameInPlay {
                            self.play(row: bestMove.0, column: bestMove.1, isAIMove: true)
                        }
                    }
                }
            }
        }
    }

    func playerOrbPercentage(for playerIndex: Int) -> Double {
        let playerOrbs = cachedOrbCounts[playerIndex, default: 0]
        let totalOrbs = cachedOrbCounts.values.reduce(0, +)
        guard totalOrbs > 0 else { return 0.0 }
        return Double(playerOrbs) / Double(totalOrbs)
    }
}
