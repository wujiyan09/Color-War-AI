import SwiftUI
import CoreML
import Combine
import UIKit
import QuartzCore
import MultipeerConnectivity

// MARK: - 1. 原生 Haptic 触觉反馈引擎

final class Haptics {
    static let shared = Haptics()
    private init() {}
    
    func lightImpact() {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.prepare()
        generator.impactOccurred()
    }
    
    func heavyImpact() {
        let generator = UIImpactFeedbackGenerator(style: .heavy)
        generator.prepare()
        generator.impactOccurred()
    }
}

// MARK: - 2. 基础数据模型与配置

enum PlayerControlType: String, CaseIterable, Identifiable, Codable {
    case human = "真人"
    case colorWarAI = "ColorWarAI (NPU)"
    case colorWar12x12 = "12x12 AI (NPU)"
    case mathNightmare = "算法-噩梦"
    case enhancedNightmare = "算法-噩梦 (加强版)"
    case p2pNetwork = "网络玩家 (P2P)"
    case disabled = "未加入"
    
    var id: String { rawValue }
    
    var isAI: Bool {
        self != .human && self != .disabled && self != .p2pNetwork
    }
    
    var isNeuralAI: Bool {
        self == .colorWarAI || self == .colorWar12x12
    }
}

struct PlayerPreset {
    static let maxPlayers = 8
    
    static let defaultColors: [Color] = [
        Color(red: 1.0, green: 0.27, blue: 0.23),
        Color(red: 0.04, green: 0.52, blue: 1.0),
        Color(red: 0.19, green: 0.82, blue: 0.35),
        Color(red: 1.0, green: 0.62, blue: 0.04),
        Color(red: 0.69, green: 0.32, blue: 0.87),
        Color(red: 0.0, green: 0.78, blue: 0.75),
        Color(red: 1.0, green: 0.84, blue: 0.04),
        Color(red: 0.96, green: 0.44, blue: 0.62)
    ]
    
    static let palettePool: [Color] = defaultColors
    
    static let emojiPresets: [String] = [
        "🔴", "🔵", "🟢", "🟧", "🟣", "🩵", "🟡", "🩷",
        "🦁", "🐯", "🐻", "🦊", "🐱", "🐶", "🐼", "🐸",
        "🔥", "⚡️", "💥", "💎", "🚀", "👑", "👻", "🤡"
    ]
    
    static let defaultNames = ["玩家1", "玩家2", "玩家3", "玩家4", "玩家5", "玩家6", "玩家7", "玩家8"]
}

struct Cell: Equatable, Sendable {
    var owner: Int?
    var count: Int
}

struct FlyingOrb: Identifiable, Sendable {
    let id = UUID()
    let player: Int
    let fromRow: Int
    let fromColumn: Int
    let toRow: Int
    let toColumn: Int
    var arrived: Bool = false
}

struct DiscoveredDevice: Identifiable, Hashable {
    let id: MCPeerID
    var displayName: String { id.displayName }
}

// MARK: - 3. 纯 P2P 对战编解码与网络引擎 (本地联机版)

enum P2PAction: String, Codable {
    case hostConfig
    case playerMove
    case syncRequest
    case ping
    case ack
}

struct P2PPacket: Codable {
    let action: P2PAction
    let senderID: String
    let row: Int?
    let col: Int?
    let boardSize: Int?
    let isRandomFirstPlayer: Bool?
    let playerIndex: Int?
    let playerNames: [String]?
    let playerTypes: [PlayerControlType]?
    let colorsHex: [String]?
    let emojis: [String]?
}

final class P2PNetworkManager: NSObject, ObservableObject, @unchecked Sendable {
    static let shared = P2PNetworkManager()
    
    private let serviceType = "colorwar-p2p"
    private var myPeerID: MCPeerID!
    private var serviceAdvertiser: MCNearbyServiceAdvertiser?
    private var serviceBrowser: MCNearbyServiceBrowser?
    private var mcSession: MCSession?
    
    @Published var myNickname: String {
        didSet {
            UserDefaults.standard.set(myNickname, forKey: "CW_Saved_MyNickname")
            rebuildPeerID()
        }
    }
    
    @Published var hostDeviceName: String = ""
    @Published var discoveredDevices: [DiscoveredDevice] = []
    @Published var connectedPeers: [String] = []
    @Published var isHost: Bool = false
    @Published var isConnected: Bool = false
    @Published var isConnecting: Bool = false
    @Published var isSearchingTimeout: Bool = false
    @Published var receivedPacket: P2PPacket? = nil
    
    private var searchTimer: Timer?
    
    override init() {
        let savedName = UserDefaults.standard.string(forKey: "CW_Saved_MyNickname") ?? "玩家\(Int.random(in: 100...999))"
        self.myNickname = savedName
        super.init()
        rebuildPeerID()
    }
    
    private func rebuildPeerID() {
        self.myPeerID = MCPeerID(displayName: myNickname.isEmpty ? "匿名玩家" : myNickname)
        setupMCSession()
    }
    
    private func setupMCSession() {
        mcSession = MCSession(peer: myPeerID, securityIdentity: nil, encryptionPreference: .required)
        mcSession?.delegate = self
    }
    
    @MainActor
    func startLocalHosting() {
        isHost = true
        hostDeviceName = myPeerID.displayName
        mcSession?.disconnect()
        setupMCSession()
        
        serviceAdvertiser = MCNearbyServiceAdvertiser(peer: myPeerID, discoveryInfo: nil, serviceType: serviceType)
        serviceAdvertiser?.delegate = self
        serviceAdvertiser?.startAdvertisingPeer()
    }
    
    @MainActor
    func startLocalBrowsing() {
        isHost = false
        discoveredDevices.removeAll()
        isSearchingTimeout = false
        isConnecting = false
        mcSession?.disconnect()
        setupMCSession()
        
        serviceBrowser = MCNearbyServiceBrowser(peer: myPeerID, serviceType: serviceType)
        serviceBrowser?.delegate = self
        serviceBrowser?.startBrowsingForPeers()
        
        searchTimer?.invalidate()
        searchTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                if let self = self, self.discoveredDevices.isEmpty && !self.isConnected {
                    self.isSearchingTimeout = true
                }
            }
        }
    }
    
    @MainActor
    func connectToDevice(_ device: DiscoveredDevice) {
        guard let browser = serviceBrowser, let session = mcSession else { return }
        isConnecting = true
        hostDeviceName = device.displayName
        browser.invitePeer(device.id, to: session, withContext: nil, timeout: 10)
    }
    
    @MainActor
    func stopP2P() {
        searchTimer?.invalidate()
        searchTimer = nil
        serviceAdvertiser?.stopAdvertisingPeer()
        serviceBrowser?.stopBrowsingForPeers()
        mcSession?.disconnect()
        isConnected = false
        isConnecting = false
        isSearchingTimeout = false
        connectedPeers.removeAll()
        discoveredDevices.removeAll()
        hostDeviceName = ""
    }
    
    func sendPacket(_ packet: P2PPacket) {
        guard let data = try? JSONEncoder().encode(packet) else { return }
        
        if let session = mcSession, !session.connectedPeers.isEmpty {
            try? session.send(data, toPeers: session.connectedPeers, with: .reliable)
        }
    }
}

extension P2PNetworkManager: MCSessionDelegate, MCNearbyServiceAdvertiserDelegate, MCNearbyServiceBrowserDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.connectedPeers = session.connectedPeers.map { $0.displayName }
            self.isConnected = !session.connectedPeers.isEmpty
            if state == .connected {
                self.isConnecting = false
            }
        }
    }
    
    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        if let packet = try? JSONDecoder().decode(P2PPacket.self, from: data) {
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if packet.action == .ping {
                    let ack = P2PPacket(action: .ack, senderID: self.myNickname, row: nil, col: nil, boardSize: nil, isRandomFirstPlayer: nil, playerIndex: nil, playerNames: nil, playerTypes: nil, colorsHex: nil, emojis: nil)
                    self.sendPacket(ack)
                }
                self.receivedPacket = packet
            }
        }
    }
    
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            invitationHandler(true, self.mcSession)
        }
    }
    
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String : String]?) {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            let device = DiscoveredDevice(id: peerID)
            if !self.discoveredDevices.contains(where: { $0.id == peerID }) {
                self.discoveredDevices.append(device)
            }
        }
    }
    
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.discoveredDevices.removeAll(where: { $0.id == peerID })
        }
    }
    
    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

// MARK: - 4. Color 扩展

extension Color {
    static let darkNavyBlue = Color(red: 0.08, green: 0.28, blue: 0.65)
    
    func toHex() -> String {
        let uic = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        uic.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }
    
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: UInt64
        switch hex.count {
        case 6:
            (r, g, b) = ((int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        default:
            (r, g, b) = (255, 0, 0)
        }
        self.init(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: 1)
    }
    
    func isSimilar(to other: Color) -> Bool {
        let c1 = UIColor(self)
        let c2 = UIColor(other)
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        c1.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        c2.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        let dist = sqrt(pow(r1 - r2, 2) + pow(g1 - g2, 2) + pow(b1 - b2, 2))
        return dist < 0.22
    }
}

// MARK: - 5. Core ML 神经网络引擎

final class NeuralAISolver: @unchecked Sendable {
    static let shared = NeuralAISolver()
    
    private static let model1InputKey = "board_input"
    private static let model1OutputKey = "policy_logits"
    private static let model2InputKey = "board_input"
    private static let model2OutputKey = "policy_logits"
    
    private var modelColorWarAI: MLModel?
    private var reuseInputArray1: MLMultiArray?
    
    private var model12x12: MLModel?
    private var reuseInputArray2: MLMultiArray?
    
    private let lock = NSLock()
    
    private init() { reloadModels() }
    
    func reloadModels() {
        let config = MLModelConfiguration()
        config.computeUnits = .all
        
        if let (model, _) = loadModelDetail(named: "ColorWarAI", config: config) {
            self.reuseInputArray1 = try? MLMultiArray(shape: [1, 5, 12, 12], dataType: .float32)
            self.modelColorWarAI = model
        }
        
        if let (model, _) = loadModelDetail(named: "colorwar_12x12_model", config: config) {
            self.reuseInputArray2 = try? MLMultiArray(shape: [1, 4, 12, 12], dataType: .float32)
            self.model12x12 = model
        }
    }
    
    private func loadModelDetail(named name: String, config: MLModelConfiguration) -> (MLModel, String)? {
        if let url = Bundle.main.url(forResource: name, withExtension: "mlmodelc"),
           let m = try? MLModel(contentsOf: url, configuration: config) {
            return (m, "OK")
        }
        let allCompiled = Bundle.main.urls(forResourcesWithExtension: "mlmodelc", subdirectory: nil) ?? []
        if let matchedURL = allCompiled.first(where: { $0.deletingPathExtension().lastPathComponent == name }),
           let m = try? MLModel(contentsOf: matchedURL, configuration: config) {
            return (m, "OK")
        }
        if let rawURL = Bundle.main.url(forResource: name, withExtension: "mlmodel"),
           let compiledURL = try? MLModel.compileModel(at: rawURL),
           let m = try? MLModel(contentsOf: compiledURL, configuration: config) {
            return (m, "OK")
        }
        return nil
    }
    
    func getBestMove(flatBoard: [AISolver.SimCell],
                     boardSize: Int,
                     currentPlayer: Int,
                     playerType: PlayerControlType,
                     validMoves: [(Int, Int)],
                     fallback: () -> (Int, Int)?) -> (Int, Int)? {
        guard !validMoves.isEmpty else { return nil }
        
        let isModel1 = (playerType == .colorWarAI)
        let activeModel = isModel1 ? modelColorWarAI : model12x12
        let inputArray = isModel1 ? reuseInputArray1 : reuseInputArray2
        
        guard boardSize <= 12 else {
            return fallback() ?? validMoves.randomElement()
        }
        
        guard let model = activeModel, let inputArray = inputArray else {
            return fallback() ?? validMoves.randomElement()
        }
        
        lock.lock()
        defer { lock.unlock() }
        
        do {
            let maxDim = 12
            let channelStride = 144
            let numChannels = isModel1 ? 5 : 4
            let totalElements = numChannels * 144
            
            let floatPtr = inputArray.dataPointer.bindMemory(to: Float.self, capacity: totalElements)
            let buffer = UnsafeMutableBufferPointer(start: floatPtr, count: totalElements)
            buffer.initialize(repeating: 0)
            
            var playerChannelMap: [Int: Int] = [:]
            playerChannelMap[currentPlayer] = 0
            
            var enemyChannelIdx = 1
            for cell in flatBoard {
                if let owner = cell.owner, owner != currentPlayer {
                    if playerChannelMap[owner] == nil {
                        if enemyChannelIdx < 4 {
                            playerChannelMap[owner] = enemyChannelIdx
                            enemyChannelIdx += 1
                        } else {
                            playerChannelMap[owner] = 3
                        }
                    }
                }
            }
            
            for r in 0..<boardSize {
                for c in 0..<boardSize {
                    let cell = flatBoard[r * boardSize + c]
                    if let owner = cell.owner, let relChannel = playerChannelMap[owner] {
                        let idx = relChannel * channelStride + r * maxDim + c
                        if idx < totalElements {
                            let normalizedValue = Float(cell.count) / 4.0
                            buffer[idx] = normalizedValue
                        }
                    }
                }
            }
            
            if isModel1 {
                let maskOffset = 4 * channelStride
                for (r, c) in validMoves {
                    let maskIdx = maskOffset + r * maxDim + c
                    if maskIdx < totalElements {
                        buffer[maskIdx] = 1.0
                    }
                }
            }
            
            let inDescs = model.modelDescription.inputDescriptionsByName
            let explicitIn = isModel1 ? Self.model1InputKey : Self.model2InputKey
            let inputKey = inDescs[explicitIn] != nil ? explicitIn : (inDescs.keys.first ?? explicitIn)
            
            let provider = try MLDictionaryFeatureProvider(dictionary: [inputKey: inputArray])
            let prediction = try model.prediction(from: provider)
            
            let outDescs = model.modelDescription.outputDescriptionsByName
            let explicitOut = isModel1 ? Self.model1OutputKey : Self.model2OutputKey
            let outputKey = outDescs[explicitOut] != nil ? explicitOut : (outDescs.keys.first ?? explicitOut)
            
            guard let logits = (prediction.featureValue(for: outputKey) ?? prediction.featureValue(for: "policy_logits") ?? prediction.featureValue(for: "logits"))?.multiArrayValue else {
                return fallback() ?? validMoves.randomElement()
            }
            
            var bestMove = validMoves[0]
            var maxScore: Float = -Float.greatestFiniteMagnitude
            
            let logitsFloatPtr = logits.dataPointer.bindMemory(to: Float.self, capacity: 144)
            let logitsBuffer = UnsafeBufferPointer(start: logitsFloatPtr, count: 144)
            
            for (r, c) in validMoves {
                let offset = r * maxDim + c
                if offset < 144 {
                    let s = logitsBuffer[offset]
                    if s > maxScore {
                        maxScore = s
                        bestMove = (r, c)
                    }
                }
            }
            return bestMove
        } catch {
            return fallback() ?? validMoves.randomElement()
        }
    }
}

// MARK: - 6. Zobrist 散列与置换表缓存

struct TranspositionTable: Sendable {
    enum EntryType: Sendable { case exact, lowerBound, upperBound }
    
    struct Entry: Sendable {
        let depth: Int
        let score: Int
        let type: EntryType
        let bestMove: (Int, Int)?
    }
    
    private var table: [UInt64: Entry] = [:]
    
    mutating func store(hash: UInt64, depth: Int, score: Int, type: EntryType, move: (Int, Int)?) {
        if table.count > 100_000 { table.removeAll(keepingCapacity: true) }
        if let existing = table[hash], existing.depth > depth { return }
        table[hash] = Entry(depth: depth, score: score, type: type, bestMove: move)
    }
    
    func lookup(hash: UInt64, depth: Int, alpha: inout Int, beta: inout Int) -> (Int, (Int, Int)?)? {
        guard let entry = table[hash], entry.depth >= depth else { return nil }
        switch entry.type {
        case .exact:
            return (entry.score, entry.bestMove)
        case .lowerBound:
            alpha = max(alpha, entry.score)
        case .upperBound:
            beta = min(beta, entry.score)
        }
        if alpha >= beta { return (entry.score, entry.bestMove) }
        return nil
    }
}

// MARK: - 7. 综合 AI 解算引擎

struct AISolver: Sendable {
    struct SimCell: Sendable {
        var owner: Int?
        var count: Int
    }
    
    private static let zobristTable: [[[[UInt64]]]] = {
        var rng = SystemRandomNumberGenerator()
        var table = [[[[UInt64]]]](repeating: [[[UInt64]]](repeating: [[UInt64]](repeating: [UInt64](repeating: 0, count: 5), count: 9), count: 12), count: 12)
        for r in 0..<12 {
            for c in 0..<12 {
                for owner in 0..<9 {
                    for count in 0..<5 {
                        table[r][c][owner][count] = rng.next()
                    }
                }
            }
        }
        return table
    }()
    
    private static let neighborLookupTable: [Int: [[Int]]] = {
        var table = [Int: [[Int]]]()
        for size in 5...12 {
            var grid = [[Int]](repeating: [], count: size * size)
            for r in 0..<size {
                for c in 0..<size {
                    let idx = r * size + c
                    var n = [Int]()
                    if r > 0 { n.append((r - 1) * size + c) }
                    if r < size - 1 { n.append((r + 1) * size + c) }
                    if c > 0 { n.append(r * size + (c - 1)) }
                    if c < size - 1 { n.append(r * size + (c + 1)) }
                    grid[idx] = n
                }
            }
            table[size] = grid
        }
        return table
    }()
    
    struct Board: Sendable {
        var cells: [SimCell]
        let size: Int
        
        init(cells: [SimCell], size: Int) {
            self.cells = cells
            self.size = size
        }
        
        subscript(r: Int, _ c: Int) -> SimCell {
            get { cells[r * size + c] }
            set { cells[r * size + c] = newValue }
        }
        
        func computeZobristHash() -> UInt64 {
            var h: UInt64 = 0
            for r in 0..<size {
                for c in 0..<size {
                    let cell = cells[r * size + c]
                    let ownerIdx = (cell.owner ?? -1) + 1
                    let countVal = min(4, max(0, cell.count))
                    h ^= AISolver.zobristTable[r][c][ownerIdx][countVal]
                }
            }
            return h
        }
    }
    
    let boardSize: Int
    let activePlayers: [Int]
    let currentPlayer: Int
    let playerType: PlayerControlType
    let board: Board
    let hasEntered: [Bool]
    let eliminated: [Bool]
    private let neighborsMap: [[Int]]
    
    init(boardSize: Int,
         activePlayers: [Int],
         currentPlayer: Int,
         playerType: PlayerControlType,
         board: [[Cell]],
         hasEntered: [Bool],
         eliminated: [Bool]) {
        self.boardSize = boardSize
        self.activePlayers = activePlayers
        self.currentPlayer = currentPlayer
        self.playerType = playerType
        
        var flat = [SimCell]()
        flat.reserveCapacity(boardSize * boardSize)
        for row in board {
            for cell in row {
                flat.append(SimCell(owner: cell.owner, count: cell.count))
            }
        }
        self.board = Board(cells: flat, size: boardSize)
        self.hasEntered = hasEntered
        self.eliminated = eliminated
        self.neighborsMap = Self.neighborLookupTable[boardSize] ?? []
    }
    
    func calculateBestMove() async -> (Int, Int)? {
        if Task.isCancelled { return nil }
        
        var validMoves = getPlayableCells(for: currentPlayer, on: board)
        guard !validMoves.isEmpty else { return nil }
        
        let totalOrbsOnBoard = board.cells.reduce(0) { $0 + $1.count }
        if totalOrbsOnBoard < 12 {
            let safeMoves = validMoves.filter { move in
                let idx = move.0 * boardSize + move.1
                for nIdx in neighborsMap[idx] {
                    let nCell = board.cells[nIdx]
                    if let nOwner = nCell.owner, nOwner != currentPlayer, nCell.count >= 2 {
                        return false
                    }
                }
                return true
            }
            if !safeMoves.isEmpty {
                validMoves = safeMoves
            }
        }
        
        if playerType.isNeuralAI {
            return NeuralAISolver.shared.getBestMove(
                flatBoard: board.cells,
                boardSize: boardSize,
                currentPlayer: currentPlayer,
                playerType: playerType,
                validMoves: validMoves,
                fallback: { calculateStandardNightmareMove(validMoves: validMoves) }
            )
        }
        
        if playerType == .enhancedNightmare {
            if let strikeMove = findCriticalThreatMove(validMoves: validMoves) {
                return strikeMove
            }
        }
        
        let aliveCount = activePlayers.filter { !isPlayerEliminated($0, in: eliminated) }.count
        
        if aliveCount == 2 {
            if playerType == .enhancedNightmare {
                return calculateIterativeNightmareMove(validMoves: validMoves)
            } else {
                return calculateStandardNightmareMove(validMoves: validMoves)
            }
        } else {
            return runParanoidMCTS(iterations: 1200, validMoves: validMoves)
        }
    }
    
    private func findCriticalThreatMove(validMoves: [(Int, Int)]) -> (Int, Int)? {
        var bestMove: (Int, Int)? = nil
        var maxSwallowedEnemies = 0
        
        for move in validMoves {
            let idx = move.0 * boardSize + move.1
            let cell = board.cells[idx]
            
            if cell.count == 3 || cell.owner == nil {
                var enemy3Count = 0
                for nIdx in neighborsMap[idx] {
                    let nCell = board.cells[nIdx]
                    if let nOwner = nCell.owner, nOwner != currentPlayer, nCell.count == 3 {
                        enemy3Count += 1
                    }
                }
                
                if enemy3Count > maxSwallowedEnemies {
                    maxSwallowedEnemies = enemy3Count
                    bestMove = move
                }
            }
        }
        
        return bestMove
    }
    
    private func calculateIterativeNightmareMove(validMoves: [(Int, Int)]) -> (Int, Int)? {
        var bestMove = validMoves.first
        let maxDepth = boardSize <= 7 ? 7 : 5
        var tt = TranspositionTable()
        
        var sortedMoves = validMoves.sorted {
            evaluateMoveTacticalPriority($0, on: board, player: currentPlayer)
            > evaluateMoveTacticalPriority($1, on: board, player: currentPlayer)
        }
        
        for currentDepth in 2...maxDepth {
            if Task.isCancelled { break }
            
            var bestScore = Int.min
            var currentLevelBestMove: (Int, Int)? = nil
            var alpha = Int.min + 1
            let beta = Int.max - 1
            
            for move in sortedMoves {
                if Task.isCancelled { break }
                
                let score = minimaxNightmare(
                    boardState: board,
                    hasEnteredState: hasEntered,
                    eliminatedState: eliminated,
                    move: move,
                    depth: currentDepth,
                    alpha: alpha,
                    beta: beta,
                    isMaximizing: false,
                    turnPlayer: currentPlayer,
                    isEnhanced: true,
                    tt: &tt
                )
                
                if score > bestScore {
                    bestScore = score
                    currentLevelBestMove = move
                    alpha = max(alpha, score)
                }
            }
            
            if let move = currentLevelBestMove {
                bestMove = move
                sortedMoves.removeAll(where: { $0.0 == move.0 && $0.1 == move.1 })
                sortedMoves.insert(move, at: 0)
            }
        }
        
        return bestMove
    }
    
    private func calculateStandardNightmareMove(validMoves: [(Int, Int)]) -> (Int, Int)? {
        let sorted = validMoves.sorted {
            evaluateMoveTacticalPriority($0, on: board, player: currentPlayer)
            > evaluateMoveTacticalPriority($1, on: board, player: currentPlayer)
        }
        var bestScore = Int.min
        var bestMoves: [(Int, Int)] = []
        let depth = boardSize <= 7 ? 5 : 4
        var tt = TranspositionTable()
        
        var alpha = Int.min + 1
        let beta = Int.max - 1
        
        for move in sorted {
            if Task.isCancelled { break }
            let s = minimaxNightmare(
                boardState: board,
                hasEnteredState: hasEntered,
                eliminatedState: eliminated,
                move: move,
                depth: depth,
                alpha: alpha,
                beta: beta,
                isMaximizing: false,
                turnPlayer: currentPlayer,
                isEnhanced: false,
                tt: &tt
            )
            if s > bestScore {
                bestScore = s
                bestMoves = [move]
                alpha = max(alpha, s)
            } else if s == bestScore {
                bestMoves.append(move)
            }
        }
        return bestMoves.randomElement() ?? sorted.first
    }
    
    private func minimaxNightmare(boardState: Board,
                                  hasEnteredState: [Bool],
                                  eliminatedState: [Bool],
                                  move: (Int, Int),
                                  depth: Int,
                                  alpha: Int,
                                  beta: Int,
                                  isMaximizing: Bool,
                                  turnPlayer: Int,
                                  isEnhanced: Bool,
                                  tt: inout TranspositionTable) -> Int {
        if Task.isCancelled { return 0 }
        
        var a = alpha
        var bVal = beta
        
        let hash = boardState.computeZobristHash()
        if let (cachedScore, _) = tt.lookup(hash: hash, depth: depth, alpha: &a, beta: &bVal) {
            return cachedScore
        }
        
        var b = boardState
        var h = hasEnteredState
        var e = eliminatedState
        
        let cascadeWaves = simulateMoveBFSWithWaveDepth(on: &b, move: move, player: turnPlayer, hasEntered: &h)
        updateEliminatedStatus(board: b, hasEntered: h, eliminated: &e)
        
        if depth <= 1 || isGameOverSimulated(eliminated: e) {
            let val = isEnhanced
            ? evaluateAdvancedBoard(b, forPlayer: currentPlayer, eliminated: e, currentTurn: turnPlayer, lastCascadeWaves: cascadeWaves)
            : evaluateStandardBoard(b, forPlayer: currentPlayer, eliminated: e)
            tt.store(hash: hash, depth: depth, score: val, type: .exact, move: move)
            return val
        }
        
        let nextPlayer = getNextPlayerSimulated(current: turnPlayer, eliminated: e)
        let nextMoves = getPlayableCells(for: nextPlayer, on: b)
        if nextMoves.isEmpty {
            let val = isEnhanced
            ? evaluateAdvancedBoard(b, forPlayer: currentPlayer, eliminated: e, currentTurn: turnPlayer, lastCascadeWaves: cascadeWaves)
            : evaluateStandardBoard(b, forPlayer: currentPlayer, eliminated: e)
            tt.store(hash: hash, depth: depth, score: val, type: .exact, move: move)
            return val
        }
        
        let sorted = nextMoves.sorted {
            evaluateMoveTacticalPriority($0, on: b, player: nextPlayer)
            > evaluateMoveTacticalPriority($1, on: b, player: nextPlayer)
        }
        
        if isMaximizing {
            var maxEval = Int.min
            var bestMoveLocal: (Int, Int)? = nil
            for m in sorted {
                if Task.isCancelled { break }
                let v = minimaxNightmare(boardState: b, hasEnteredState: h, eliminatedState: e, move: m, depth: depth - 1, alpha: a, beta: bVal, isMaximizing: false, turnPlayer: nextPlayer, isEnhanced: isEnhanced, tt: &tt)
                if v > maxEval {
                    maxEval = v
                    bestMoveLocal = m
                }
                a = max(a, v)
                if bVal <= a { break }
            }
            tt.store(hash: hash, depth: depth, score: maxEval, type: maxEval >= beta ? .lowerBound : .exact, move: bestMoveLocal)
            return maxEval
        } else {
            var minEval = Int.max
            var bestMoveLocal: (Int, Int)? = nil
            for m in sorted {
                if Task.isCancelled { break }
                let v = minimaxNightmare(boardState: b, hasEnteredState: h, eliminatedState: e, move: m, depth: depth - 1, alpha: a, beta: bVal, isMaximizing: true, turnPlayer: nextPlayer, isEnhanced: isEnhanced, tt: &tt)
                if v < minEval {
                    minEval = v
                    bestMoveLocal = m
                }
                bVal = min(bVal, v)
                if bVal <= a { break }
            }
            tt.store(hash: hash, depth: depth, score: minEval, type: minEval <= alpha ? .upperBound : .exact, move: bestMoveLocal)
            return minEval
        }
    }
    
    private func runParanoidMCTS(iterations: Int, validMoves: [(Int, Int)]) -> (Int, Int)? {
        var scores: [Int: Double] = [:]
        
        for move in validMoves {
            let idx = move.0 * boardSize + move.1
            var score = 0.0
            
            var b = self.board
            var h = self.hasEntered
            var e = self.eliminated
            let waveCount = simulateMoveBFSWithWaveDepth(on: &b, move: move, player: currentPlayer, hasEntered: &h)
            updateEliminatedStatus(board: b, hasEntered: h, eliminated: &e)
            
            let remainingEnemies = activePlayers.filter { $0 != currentPlayer && !isPlayerEliminated($0, in: e) }
            score += Double(evaluateAdvancedBoard(b, forPlayer: currentPlayer, eliminated: e, currentTurn: currentPlayer, lastCascadeWaves: waveCount))
            score -= Double(remainingEnemies.count * 150)
            
            scores[idx] = score
        }
        
        if let bestIdx = scores.max(by: { $0.value < $1.value })?.key {
            return (bestIdx / boardSize, bestIdx % boardSize)
        }
        
        return validMoves.randomElement()
    }
    
    private func evaluateAdvancedBoard(_ b: Board, forPlayer player: Int, eliminated: [Bool], currentTurn: Int, lastCascadeWaves: Int) -> Int {
        if isPlayerEliminated(player, in: eliminated) { return -999_999 }
        
        var score = 0
        var myOrbs = 0
        var enemyOrbs = 0
        
        for r in 0..<boardSize {
            for c in 0..<boardSize {
                let idx = r * boardSize + c
                let cell = b.cells[idx]
                guard let owner = cell.owner else { continue }
                
                let isCorner = (r == 0 || r == boardSize - 1) && (c == 0 || c == boardSize - 1)
                let isEdge = r == 0 || r == boardSize - 1 || c == 0 || c == boardSize - 1
                
                var cellVal = cell.count * 15
                if isCorner { cellVal += 45 }
                else if isEdge { cellVal += 20 }
                
                if cell.count == 3 {
                    cellVal += 35
                    for nIdx in neighborsMap[idx] {
                        let nCell = b.cells[nIdx]
                        if let nOwner = nCell.owner, nOwner != owner, nCell.count == 3 {
                            if currentTurn != owner {
                                cellVal -= (owner == player ? 400 : -400)
                            } else {
                                cellVal += (owner == player ? 300 : -300)
                            }
                        }
                    }
                }
                
                if owner == player {
                    myOrbs += cell.count
                    score += cellVal
                } else {
                    enemyOrbs += cell.count
                    score -= Int(Double(cellVal) * 1.3)
                }
            }
        }
        
        score += lastCascadeWaves * 60
        let eliminatedEnemies = activePlayers.filter { $0 != player && isPlayerEliminated($0, in: eliminated) }.count
        return score + eliminatedEnemies * 1200 + (myOrbs - enemyOrbs) * 25
    }
    
    private func evaluateStandardBoard(_ b: Board, forPlayer player: Int, eliminated: [Bool]) -> Int {
        if isPlayerEliminated(player, in: eliminated) { return -999_999 }
        var score = 0
        for r in 0..<boardSize {
            for c in 0..<boardSize {
                let idx = r * boardSize + c
                let cell = b.cells[idx]
                guard let owner = cell.owner else { continue }
                let isCorner = (r == 0 || r == boardSize - 1) && (c == 0 || c == boardSize - 1)
                let isEdge = r == 0 || r == boardSize - 1 || c == 0 || c == boardSize - 1
                var v = cell.count * 15
                if isCorner { v += 45 } else if isEdge { v += 20 }
                if owner == player { score += v } else { score -= Int(Double(v) * 1.3) }
            }
        }
        return score
    }
    
    private func evaluateMoveTacticalPriority(_ move: (Int, Int), on b: Board, player: Int) -> Int {
        let (r, c) = move
        let idx = r * boardSize + c
        let cell = b[r, c]
        
        var priority = 0
        if cell.count == 3 { priority += 250 }
        
        for nIdx in neighborsMap[idx] {
            let nCell = b.cells[nIdx]
            if let nOwner = nCell.owner, nOwner != player {
                if nCell.count >= 2 {
                    priority -= 600
                }
                if nCell.count == 3 {
                    priority += 800
                }
            }
        }
        
        let isCorner = (r == 0 || r == boardSize - 1) && (c == 0 || c == boardSize - 1)
        if isCorner { priority += 100 }
        
        return priority
    }
    
    @discardableResult
    private func simulateMoveBFSWithWaveDepth(on simBoard: inout Board, move: (Int, Int), player: Int, hasEntered: inout [Bool]) -> Int {
        let flatIndex = move.0 * boardSize + move.1
        let isFirst = !hasEntered[player]
        hasEntered[player] = true
        
        simBoard.cells[flatIndex].owner = player
        simBoard.cells[flatIndex].count += isFirst ? 3 : 1
        
        guard simBoard.cells[flatIndex].count >= 4 else { return 0 }
        
        var queue = [Int]()
        queue.append(flatIndex)
        var waveCount = 0
        let maxWaveCount = 100
        
        while !queue.isEmpty && waveCount < maxWaveCount {
            waveCount += 1
            let count = queue.count
            for _ in 0..<count {
                let currIdx = queue.removeFirst()
                if simBoard.cells[currIdx].count < 4 { continue }
                
                simBoard.cells[currIdx].count -= 4
                if simBoard.cells[currIdx].count == 0 {
                    simBoard.cells[currIdx].owner = nil
                }
                
                for nIdx in neighborsMap[currIdx] {
                    simBoard.cells[nIdx].owner = player
                    simBoard.cells[nIdx].count += 1
                    if simBoard.cells[nIdx].count >= 4 {
                        queue.append(nIdx)
                    }
                }
            }
        }
        return waveCount
    }
    
    private func updateEliminatedStatus(board b: Board, hasEntered: [Bool], eliminated: inout [Bool]) {
        var appears = [Bool](repeating: false, count: PlayerPreset.maxPlayers)
        for cell in b.cells {
            if let o = cell.owner, o >= 0, o < PlayerPreset.maxPlayers {
                appears[o] = true
            }
        }
        for p in activePlayers where hasEntered[p] && !eliminated[p] {
            if !appears[p] {
                eliminated[p] = true
            }
        }
    }
    
    private func getNextPlayerSimulated(current: Int, eliminated: [Bool]) -> Int {
        guard let idx = activePlayers.firstIndex(of: current) else { return current }
        let n = activePlayers.count
        var i = (idx + 1) % n
        var count = 0
        while isPlayerEliminated(activePlayers[i], in: eliminated) && count < n {
            i = (i + 1) % n
            count += 1
        }
        return activePlayers[i]
    }
    
    private func getPlayableCells(for player: Int, on b: Board) -> [(Int, Int)] {
        let ownsAny = b.cells.contains { $0.owner == player }
        var moves: [(Int, Int)] = []
        moves.reserveCapacity(b.size * b.size)
        
        for r in 0..<boardSize {
            for c in 0..<boardSize {
                let owner = b[r, c].owner
                if ownsAny ? (owner == player) : (owner == nil) {
                    moves.append((r, c))
                }
            }
        }
        return moves
    }
    
    private func isGameOverSimulated(eliminated: [Bool]) -> Bool {
        activePlayers.filter { !isPlayerEliminated($0, in: eliminated) }.count <= 1
    }
    
    private func isPlayerEliminated(_ player: Int, in eliminatedArray: [Bool]) -> Bool {
        guard player >= 0 && player < eliminatedArray.count else { return true }
        return eliminatedArray[player]
    }
}

// MARK: - 8. GameModel ViewModel

@MainActor
final class GameModel: ObservableObject {
    @Published var boardSize: Int {
        didSet {
            UserDefaults.standard.set(boardSize, forKey: "CW_Saved_BoardSize")
            syncRoomConfigToPeers()
        }
    }
    @Published var isRandomFirstPlayer: Bool {
        didSet {
            UserDefaults.standard.set(isRandomFirstPlayer, forKey: "CW_Saved_IsRandomFirst")
            syncRoomConfigToPeers()
        }
    }
    @Published var board: [[Cell]] = []
    @Published var playerNames: [String] {
        didSet { debounceSave() }
    }
    @Published var playerTypes: [PlayerControlType] {
        didSet { debounceSave() }
    }
    @Published var colors: [Color] {
        didSet { debounceSave() }
    }
    @Published var emojis: [String?] {
        didSet { debounceSave() }
    }
    @Published var currentPlayer: Int = 0
    @Published var myPlayerIndex: Int = 0
    @Published var hasEntered: [Bool] = Array(repeating: false, count: PlayerPreset.maxPlayers)
    @Published var eliminated: [Bool] = Array(repeating: false, count: PlayerPreset.maxPlayers)
    @Published var isProcessingCascade: Bool = false
    @Published var winnerIndex: Int? = nil
    @Published var showControlSheet: Bool = false
    @Published var flyingOrbs: [FlyingOrb] = []
    @Published var emphasizedCells: Set<Int> = []
    
    private var p2pCancellable: AnyCancellable? = nil
    private var aiTask: Task<Void, Never>? = nil
    private var saveWorkItem: DispatchWorkItem? = nil
    
    var activePlayerIndices: [Int] {
        playerTypes.enumerated().compactMap { $1 != .disabled ? $0 : nil }
    }
    
    var playableCells: Set<Int> {
        let ownsAny = board.flatMap { $0 }.contains { $0.owner == currentPlayer }
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
        return indices
    }
    
    init() {
        let savedSize = UserDefaults.standard.integer(forKey: "CW_Saved_BoardSize")
        self.boardSize = (savedSize >= 5 && savedSize <= 12) ? savedSize : 8
        self.isRandomFirstPlayer = UserDefaults.standard.object(forKey: "CW_Saved_IsRandomFirst") as? Bool ?? true
        
        if let data = UserDefaults.standard.data(forKey: "CW_Saved_PlayerTypes"),
           let decoded = try? JSONDecoder().decode([PlayerControlType].self, from: data),
           decoded.count == PlayerPreset.maxPlayers {
            self.playerTypes = decoded
        } else {
            self.playerTypes = [
                .human, .colorWarAI, .enhancedNightmare, .colorWar12x12,
                .disabled, .disabled, .disabled, .disabled
            ]
        }
        
        if let namesArray = UserDefaults.standard.stringArray(forKey: "CW_Saved_PlayerNames"),
           namesArray.count == PlayerPreset.maxPlayers {
            self.playerNames = namesArray
        } else {
            self.playerNames = PlayerPreset.defaultNames
        }
        
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
        
        setupP2PListener()
        resetGame()
    }
    
    private func setupP2PListener() {
        p2pCancellable = P2PNetworkManager.shared.$receivedPacket
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] packet in
                guard let self = self else { return }
                if packet.action == .playerMove, let r = packet.row, let c = packet.col {
                    self.play(row: r, column: c)
                } else if packet.action == .hostConfig {
                    if let names = packet.playerNames { self.playerNames = names }
                    if let types = packet.playerTypes { self.playerTypes = types }
                    if let hexes = packet.colorsHex { self.colors = hexes.map { Color(hex: $0) } }
                    if let ems = packet.emojis { self.emojis = ems.map { $0.isEmpty ? nil : $0 } }
                    if let sz = packet.boardSize { self.boardSize = sz }
                    if let rnd = packet.isRandomFirstPlayer { self.isRandomFirstPlayer = rnd }
                }
            }
    }
    
    func syncRoomConfigToPeers() {
        guard P2PNetworkManager.shared.isHost && P2PNetworkManager.shared.isConnected else { return }
        let packet = P2PPacket(
            action: .hostConfig,
            senderID: P2PNetworkManager.shared.myNickname,
            row: nil, col: nil,
            boardSize: boardSize,
            isRandomFirstPlayer: isRandomFirstPlayer,
            playerIndex: nil,
            playerNames: playerNames,
            playerTypes: playerTypes,
            colorsHex: colors.map { $0.toHex() },
            emojis: emojis.map { $0 ?? "" }
        )
        P2PNetworkManager.shared.sendPacket(packet)
    }
    
    private func debounceSave() {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            UserDefaults.standard.set(self.playerNames, forKey: "CW_Saved_PlayerNames")
            if let encoded = try? JSONEncoder().encode(self.playerTypes) {
                UserDefaults.standard.set(encoded, forKey: "CW_Saved_PlayerTypes")
            }
            let hexes = self.colors.map { $0.toHex() }
            UserDefaults.standard.set(hexes, forKey: "CW_Saved_PlayerColors")
            
            let stringArray = self.emojis.map { $0 ?? "" }
            UserDefaults.standard.set(stringArray, forKey: "CW_Saved_PlayerEmojis")
        }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }
    
    func tryUpdatePlayerEmoji(at index: Int, newEmoji: String?) -> Bool {
        if let emoji = newEmoji, !emoji.isEmpty {
            for i in 0..<PlayerPreset.maxPlayers where i != index {
                if emojis[i] == emoji {
                    return false
                }
            }
        }
        emojis[index] = newEmoji
        syncRoomConfigToPeers()
        return true
    }
    
    func updatePlayerColor(at index: Int, newColor: Color) {
        colors[index] = newColor
        for otherIdx in 0..<PlayerPreset.maxPlayers where otherIdx != index {
            if colors[otherIdx].isSimilar(to: newColor) {
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
        aiTask?.cancel()
        aiTask = nil
        flyingOrbs.removeAll()
        emphasizedCells.removeAll()
        board = [[Cell]](repeating: [Cell](repeating: Cell(owner: nil, count: 0), count: boardSize), count: boardSize)
        hasEntered = Array(repeating: false, count: PlayerPreset.maxPlayers)
        eliminated = Array(repeating: false, count: PlayerPreset.maxPlayers)
        winnerIndex = nil
        isProcessingCascade = false
        
        let active = activePlayerIndices
        guard !active.isEmpty else { return }
        
        if let chosen = chosenFirstPlayer, active.contains(chosen) {
            currentPlayer = chosen
        } else if isRandomFirstPlayer {
            currentPlayer = active.randomElement() ?? active[0]
        } else {
            currentPlayer = active[0]
        }
        
        checkAndRunAITurn()
    }
    
    func exitToMenu() {
        aiTask?.cancel()
        aiTask = nil
        flyingOrbs.removeAll()
        emphasizedCells.removeAll()
        isProcessingCascade = false
        winnerIndex = nil
        P2PNetworkManager.shared.stopP2P()
        NeuralAISolver.shared.reloadModels()
    }
    
    func updatePlayerType(at index: Int, to newType: PlayerControlType) {
        guard index >= 0 && index < PlayerPreset.maxPlayers else { return }
        playerTypes[index] = newType
        syncRoomConfigToPeers()
        
        if index == currentPlayer && newType.isAI && !isProcessingCascade {
            checkAndRunAITurn()
        }
    }
    
    func play(row: Int, column: Int) {
        guard !isProcessingCascade, winnerIndex == nil else { return }
        
        Haptics.shared.lightImpact()
        
        let player = currentPlayer
        
        if P2PNetworkManager.shared.isConnected {
            let packet = P2PPacket(action: .playerMove, senderID: P2PNetworkManager.shared.myNickname, row: row, col: column, boardSize: boardSize, isRandomFirstPlayer: nil, playerIndex: player, playerNames: nil, playerTypes: nil, colorsHex: nil, emojis: nil)
            P2PNetworkManager.shared.sendPacket(packet)
        }
        
        aiTask?.cancel()
        aiTask = nil
        
        Task { @MainActor in
            await resolveMove(row: row, column: column, player: player)
        }
    }
    
    private func resolveMove(row: Int, column: Int, player: Int) async {
        isProcessingCascade = true
        let isFirst = !hasEntered[player]
        hasEntered[player] = true
        
        do {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.62)) {
                board[row][column].owner = player
                board[row][column].count += isFirst ? 3 : 1
                emphasizedCells = [row * boardSize + column]
            }
            try await Task.sleep(nanoseconds: 210_000_000)
            
            var wave: [(Int, Int)] = board[row][column].count >= 4 ? [(row, column)] : []
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
                        board[r][c].count -= 4
                        board[r][c].owner = board[r][c].count == 0 ? nil : player
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
                        board[orb.toRow][orb.toColumn].owner = player
                        board[orb.toRow][orb.toColumn].count += 1
                        changed.insert(orb.toRow * boardSize + orb.toColumn)
                    }
                    flyingOrbs = []
                    emphasizedCells = changed
                }
                try await Task.sleep(nanoseconds: 120_000_000)
                
                wave = changed.compactMap {
                    let r = $0 / boardSize
                    let c = $0 % boardSize
                    return board[r][c].count >= 4 ? (r, c) : nil
                }
            }
            
            emphasizedCells = []
            isProcessingCascade = false
            
            updateEliminationStatus()
            if checkGameOver() { return }
            
            advanceToNextTurn()
        } catch {
            isProcessingCascade = false
            emphasizedCells = []
            flyingOrbs = []
        }
    }
    
    private func updateEliminationStatus() {
        var appears = [Bool](repeating: false, count: PlayerPreset.maxPlayers)
        for row in board {
            for cell in row {
                if let o = cell.owner { appears[o] = true }
            }
        }
        for p in activePlayerIndices {
            if hasEntered[p] && !appears[p] {
                eliminated[p] = true
            }
        }
    }
    
    private func checkGameOver() -> Bool {
        let alive = activePlayerIndices.filter { !eliminated[$0] }
        let allEntered = activePlayerIndices.allSatisfy { hasEntered[$0] }
        
        if allEntered && alive.count <= 1 {
            winnerIndex = alive.first
            Haptics.shared.heavyImpact()
            return true
        }
        return false
    }
    
    private func advanceToNextTurn() {
        let active = activePlayerIndices
        guard let idx = active.firstIndex(of: currentPlayer) else { return }
        
        var nextIdx = (idx + 1) % active.count
        var count = 0
        while eliminated[active[nextIdx]] && count < active.count {
            nextIdx = (nextIdx + 1) % active.count
            count += 1
        }
        
        currentPlayer = active[nextIdx]
        checkAndRunAITurn()
    }
    
    private func checkAndRunAITurn() {
        aiTask?.cancel()
        let currentType = playerTypes[currentPlayer]
        guard currentType.isAI && winnerIndex == nil else { return }
        
        aiTask = Task(priority: .userInitiated) {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
            
            let solver = AISolver(
                boardSize: boardSize,
                activePlayers: activePlayerIndices,
                currentPlayer: currentPlayer,
                playerType: currentType,
                board: board,
                hasEntered: hasEntered,
                eliminated: eliminated
            )
            
            if let bestMove = await solver.calculateBestMove() {
                if !Task.isCancelled {
                    play(row: bestMove.0, column: bestMove.1)
                }
            }
        }
    }
}

// MARK: - 9. 棋盘视图

struct BoardView: View {
    @ObservedObject var game: GameModel
    private let gap: CGFloat = 3
    
    var body: some View {
        GeometryReader { proxy in
            let side = (proxy.size.width - 12 - gap * CGFloat(game.boardSize - 1)) / CGFloat(game.boardSize)
            
            ZStack(alignment: .topLeading) {
                VStack(spacing: gap) {
                    ForEach(0..<game.boardSize, id: \.self) { r in
                        HStack(spacing: gap) {
                            ForEach(0..<game.boardSize, id: \.self) { c in
                                let index = r * game.boardSize + c
                                let cell = game.board[r][c]
                                
                                CellView(
                                    cell: cell,
                                    color: cell.owner.map { game.colors[$0] },
                                    emoji: cell.owner.flatMap { game.emojis[$0] },
                                    active: game.emphasizedCells.contains(index)
                                )
                                .equatable()
                                .frame(width: side, height: side)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if game.playerTypes[game.currentPlayer] == .human && game.playableCells.contains(index) {
                                        game.play(row: r, column: c)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(6)
                
                ForEach(game.flyingOrbs) { orb in
                    PieceView(
                        color: game.colors[orb.player],
                        emoji: game.emojis[orb.player],
                        count: 1,
                        size: max(8, side * 0.40)
                    )
                    .position(
                        x: 6 + side / 2 + CGFloat(orb.arrived ? orb.toColumn : orb.fromColumn) * (side + gap),
                        y: 6 + side / 2 + CGFloat(orb.arrived ? orb.toRow : orb.fromRow) * (side + gap)
                    )
                    .zIndex(10)
                    .allowsHitTesting(false)
                }
            }
            .glassEffect(.regular, in: .rect(cornerRadius: 16))
        }
        .aspectRatio(1, contentMode: .fit)
        .onDisappear {
            game.exitToMenu()
        }
    }
}

// MARK: - 10. 单元格视图

struct CellView: View, Equatable {
    let cell: Cell
    let color: Color?
    let emoji: String?
    let active: Bool
    
    static func == (lhs: CellView, rhs: CellView) -> Bool {
        lhs.cell == rhs.cell && lhs.color == rhs.color && lhs.emoji == rhs.emoji && lhs.active == rhs.active
    }
    
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                RoundedRectangle(cornerRadius: max(4, proxy.size.width * 0.17), style: .continuous)
                    .fill(Color.white.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: max(4, proxy.size.width * 0.17))
                            .stroke(Color.white.opacity(0.12), lineWidth: 0.7)
                    )
                
                if cell.count > 0 {
                    PieceView(
                        color: color ?? .clear,
                        emoji: emoji,
                        count: cell.count,
                        size: proxy.size.width * 0.76
                    )
                    .scaleEffect(active ? 1.09 : 1.0)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.21, dampingFraction: 0.62), value: cell.count)
            .animation(.spring(response: 0.18, dampingFraction: 0.65), value: active)
        }
    }
}

// MARK: - 11. 棋子外观视图

struct PieceView: View {
    let color: Color
    let emoji: String?
    let count: Int
    let size: CGFloat
    
    var isEmojiPiece: Bool {
        if let em = emoji, !em.isEmpty { return true }
        return false
    }
    
    var body: some View {
        ZStack {
            if let emojiStr = emoji, !emojiStr.isEmpty {
                Circle()
                    .fill(color.opacity(0.25))
                    .overlay(Circle().stroke(Color.white, lineWidth: max(0.5, size * 0.04)))
                
                Text(emojiStr)
                    .font(.system(size: size * 0.70))
                    .drawingGroup()
            } else {
                Circle().fill(
                    LinearGradient(
                        colors: [color.opacity(0.95), color.opacity(0.65)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            }
            
            DotPattern(count: min(4, max(0, count)), diameter: size * 0.16, isEmoji: isEmojiPiece)
        }
        .frame(width: size, height: size)
        .overlay(
            Circle()
                .stroke(Color.white, lineWidth: max(0.5, size * 0.04))
        )
        .compositingGroup()
        .accessibilityHidden(true)
    }
}

// MARK: - 12. 棋子点数排列视图

struct DotPattern: View {
    let count: Int
    let diameter: CGFloat
    let isEmoji: Bool
    
    var body: some View {
        ZStack {
            ForEach(0..<count, id: \.self) { index in
                if isEmoji {
                    Circle()
                        .fill(.white)
                        .overlay(
                            Circle()
                                .stroke(Color.black.opacity(0.65), lineWidth: max(0.8, diameter * 0.14))
                        )
                        .shadow(color: Color.black.opacity(0.75), radius: max(1, diameter * 0.18), x: 0, y: 1)
                        .frame(width: diameter, height: diameter)
                        .offset(offset(index))
                        .transition(.scale.combined(with: .opacity))
                } else {
                    Circle()
                        .fill(.white)
                        .frame(width: diameter, height: diameter)
                        .offset(offset(index))
                        .transition(.scale.combined(with: .opacity))
                }
            }
        }
        .animation(.spring(response: 0.20, dampingFraction: 0.60), value: count)
    }
    
    private func offset(_ index: Int) -> CGSize {
        let step = diameter * 1.25
        
        switch count {
        case 0, 1:
            return .zero
            
        case 2:
            let x = (index == 0) ? -step * 0.7 : step * 0.7
            return CGSize(width: x, height: 0)
            
        case 3:
            let downOffset = step * 0.15
            if index == 0 {
                return CGSize(width: 0, height: -step * 0.866 + downOffset)
            } else if index == 1 {
                return CGSize(width: -step * 0.75, height: step * 0.433 + downOffset)
            } else {
                return CGSize(width: step * 0.75, height: step * 0.433 + downOffset)
            }
            
        default:
            let x = (index % 2 == 0) ? -step * 0.65 : step * 0.65
            let y = (index < 2) ? -step * 0.65 : step * 0.65
            return CGSize(width: x, height: y)
        }
    }
}

// MARK: - 13. Emoji 选择器 Sheet

struct EmojiPickerSheet: View {
    @ObservedObject var game: GameModel
    let playerIndex: Int
    @Environment(\.dismiss) private var dismiss
    @State private var customEmojiText: String = ""
    @State private var errorMessage: String? = nil
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if let err = errorMessage {
                    Text(err)
                        .foregroundColor(.red)
                        .font(.caption)
                        .bold()
                }
                
                Button(action: {
                    _ = game.tryUpdatePlayerEmoji(at: playerIndex, newEmoji: nil)
                    dismiss()
                }) {
                    HStack {
                        Image(systemName: "paintpalette.fill")
                        Text("使用默认纯色/拟态棋子")
                    }
                    .font(.subheadline)
                    .bold()
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .contentShape(Capsule())
                    .glassEffect(.regular.interactive(), in: .capsule)
                }
                .buttonStyle(.plain)
                .padding(.top)
                
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 16) {
                    ForEach(PlayerPreset.emojiPresets, id: \.self) { emoji in
                        let isOccupied = game.emojis.enumerated().contains { $0.offset != playerIndex && $0.element == emoji }
                        
                        Button(action: {
                            if game.tryUpdatePlayerEmoji(at: playerIndex, newEmoji: emoji) {
                                dismiss()
                            } else {
                                errorMessage = "‘\(emoji)’ 已被占用！"
                            }
                        }) {
                            ZStack {
                                Circle()
                                    .fill(isOccupied ? Color.red.opacity(0.2) : Color.white.opacity(0.1))
                                Text(emoji)
                                    .font(.title2)
                            }
                            .frame(width: 44, height: 44)
                            .overlay(
                                Circle().stroke(isOccupied ? Color.red.opacity(0.6) : Color.white.opacity(0.2), lineWidth: 1)
                            )
                        }
                    }
                }
                .padding()
                
                Divider().background(Color.white.opacity(0.2))
                
                HStack {
                    TextField("输入任意 Emoji", text: $customEmojiText)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 180)
                    
                    Button(action: {
                        let trimmed = customEmojiText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            if game.tryUpdatePlayerEmoji(at: playerIndex, newEmoji: String(trimmed.prefix(1))) {
                                dismiss()
                            } else {
                                errorMessage = "该 Emoji 已被占用！"
                            }
                        }
                    }) {
                        Text("设定")
                            .font(.subheadline)
                            .bold()
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .contentShape(Capsule())
                            .glassEffect(.regular.tint(.darkNavyBlue).interactive(), in: .capsule)
                    }
                    .buttonStyle(.plain)
                }
                
                Spacer()
            }
            .navigationTitle("选择 \(game.playerNames[playerIndex]) 的棋子样式")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("取消") { dismiss() }
            }
        }
        .presentationBackground(.thinMaterial)
    }
}

// MARK: - 14. 单机/本地设置 View

struct LocalGameSetupView: View {
    @ObservedObject var game: GameModel
    let onStartGame: () -> Void
    @State private var selectedPlayerForEmoji: Int? = nil
    
    var isPlayerCountValid: Bool {
        game.activePlayerIndices.count >= 2
    }
    
    var localAvailableTypes: [PlayerControlType] {
        PlayerControlType.allCases.filter { $0 != .p2pNetwork }
    }
    
    var body: some View {
        VStack(spacing: 14) {
            VStack(spacing: 12) {
                HStack {
                    Text("网格尺寸: \(game.boardSize) × \(game.boardSize)")
                        .font(.subheadline)
                        .bold()
                        .foregroundColor(.white)
                    Spacer()
                }
                
                Slider(
                    value: Binding<Double>(
                        get: { Double(game.boardSize) },
                        set: { game.boardSize = Int($0) }
                    ),
                    in: 5...12,
                    step: 1
                )
                .tint(Color.darkNavyBlue)
                
                Toggle(isOn: $game.isRandomFirstPlayer) {
                    Text("随机挑选先手").foregroundColor(.white).font(.caption).bold()
                }
                .tint(Color.darkNavyBlue)
            }
            .padding()
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
            
            VStack(spacing: 10) {
                ForEach(0..<PlayerPreset.maxPlayers, id: \.self) { idx in
                    HStack(spacing: 10) {
                        Button(action: { selectedPlayerForEmoji = idx }) {
                            ZStack {
                                Circle()
                                    .fill(game.colors[idx])
                                    .frame(width: 28, height: 28)
                                
                                if let em = game.emojis[idx], !em.isEmpty {
                                    Text(em).font(.caption)
                                }
                            }
                        }
                        
                        ColorPicker("", selection: Binding(
                            get: { game.colors[idx] },
                            set: { game.updatePlayerColor(at: idx, newColor: $0) }
                        ))
                        .labelsHidden()
                        
                        TextField("名称", text: $game.playerNames[idx])
                            .foregroundColor(.white)
                            .font(.subheadline)
                            .bold()
                            .textFieldStyle(.plain)
                        
                        Spacer()
                        
                        Picker("Player Type", selection: Binding(
                            get: { game.playerTypes[idx] },
                            set: { game.updatePlayerType(at: idx, to: $0) }
                        )) {
                            ForEach(localAvailableTypes) { type in
                                Text(type.rawValue).tag(type)
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(.white)
                    }
                    .padding(.horizontal, 8)
                }
            }
            .padding(12)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
            
            Button(action: onStartGame) {
                HStack {
                    Image(systemName: "play.fill")
                    Text("开始对决").font(.title3).bold()
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .contentShape(Capsule())
                .glassEffect(.regular.tint(.darkNavyBlue).interactive(), in: .capsule)
            }
            .buttonStyle(.plain)
            .opacity(isPlayerCountValid ? 1.0 : 0.4)
            .disabled(!isPlayerCountValid)
        }
        .sheet(item: Binding<Int?>(
            get: { selectedPlayerForEmoji },
            set: { selectedPlayerForEmoji = $0 }
        )) { idx in
            EmojiPickerSheet(game: game, playerIndex: idx)
        }
    }
}

// MARK: - 15. 近场搜寻内嵌式菜单 View

struct LocalDeviceBrowserInlineView: View {
    @ObservedObject var p2pManager = P2PNetworkManager.shared
    let onSelectDevice: (DiscoveredDevice) -> Void
    let onCancel: () -> Void
    
    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text("🌐 附近的 Color War 房间列表")
                    .font(.subheadline)
                    .bold()
                    .foregroundColor(.white)
                Spacer()
                Button("取消搜寻", action: onCancel)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.8))
            }
            
            if p2pManager.isConnecting {
                VStack(spacing: 10) {
                    ProgressView()
                        .scaleEffect(1.1)
                        .tint(Color.darkNavyBlue)
                    Text("正在加入 \(p2pManager.hostDeviceName) 的房间...")
                        .font(.caption)
                        .foregroundColor(.white)
                }
                .padding()
            } else if p2pManager.isSearchingTimeout && p2pManager.discoveredDevices.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.title2)
                        .foregroundColor(.yellow)
                    Text("未搜寻到附近的 Color War 房间")
                        .font(.caption)
                        .foregroundColor(.white)
                    
                    Button(action: {
                        p2pManager.startLocalBrowsing()
                    }) {
                        Text("重新搜寻")
                            .font(.caption)
                            .bold()
                            .foregroundColor(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .contentShape(Capsule())
                            .glassEffect(.regular.interactive(), in: .capsule)
                    }
                    .buttonStyle(.plain)
                }
                .padding()
            } else {
                if p2pManager.discoveredDevices.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView()
                            .scaleEffect(0.9)
                            .tint(Color.darkNavyBlue)
                        Text("正在扫描局域网房间信号...")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                    .padding()
                } else {
                    VStack(spacing: 8) {
                        ForEach(p2pManager.discoveredDevices) { device in
                            Button(action: { onSelectDevice(device) }) {
                                HStack {
                                    Image(systemName: "bonjour")
                                        .foregroundColor(.green)
                                    Text(device.displayName)
                                        .bold()
                                        .foregroundColor(.white)
                                    Spacer()
                                    Text("点击加入")
                                        .font(.caption)
                                        .foregroundColor(.cyan)
                                }
                                .padding(12)
                                .contentShape(Rectangle())
                                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding()
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }
}

// MARK: - 16. 4 人房间大厅 View

struct RoomLobbyView: View {
    @ObservedObject var game: GameModel
    @ObservedObject var p2pManager = P2PNetworkManager.shared
    let onExitLobby: () -> Void
    let onStartGame: () -> Void
    
    @State private var selectedPlayerForEmoji: Int? = nil
    
    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text(p2pManager.isHost ? "🏠 房主房间: \(p2pManager.myNickname)" : "🔗 已加入房间: \(p2pManager.hostDeviceName)")
                    .font(.headline)
                    .foregroundColor(.white)
                Spacer()
                Button(action: {
                    p2pManager.stopP2P()
                    onExitLobby()
                }) {
                    Text(p2pManager.isHost ? "解散房间" : "退出房间")
                        .font(.subheadline)
                        .bold()
                        .foregroundColor(.white.opacity(0.8))
                }
            }
            .padding(12)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
            
            if p2pManager.isHost {
                VStack(spacing: 10) {
                    HStack {
                        Text("网格尺寸: \(game.boardSize) × \(game.boardSize)")
                            .font(.caption)
                            .bold()
                            .foregroundColor(.white)
                        Spacer()
                    }
                    
                    Slider(
                        value: Binding<Double>(
                            get: { Double(game.boardSize) },
                            set: { game.boardSize = Int($0) }
                        ),
                        in: 5...12,
                        step: 1
                    )
                    .tint(Color.darkNavyBlue)
                    
                    Toggle(isOn: $game.isRandomFirstPlayer) {
                        Text("随机挑选先手").foregroundColor(.white).font(.caption).bold()
                    }
                    .tint(Color.darkNavyBlue)
                }
                .padding(12)
                .glassEffect(.regular, in: .rect(cornerRadius: 18))
            } else {
                HStack {
                    Text("房主设定尺寸: \(game.boardSize) × \(game.boardSize)")
                    Spacer()
                    Text(game.isRandomFirstPlayer ? "随机先手" : "顺序先手")
                }
                .font(.caption)
                .bold()
                .foregroundColor(.cyan)
                .padding(12)
                .glassEffect(.regular, in: .rect(cornerRadius: 18))
            }
            
            VStack(spacing: 10) {
                ForEach(0..<min(4, PlayerPreset.maxPlayers), id: \.self) { idx in
                    let isMySeat = (idx == game.myPlayerIndex)
                    
                    HStack {
                        Button(action: {
                            if isMySeat { selectedPlayerForEmoji = idx }
                        }) {
                            ZStack {
                                Circle()
                                    .fill(game.colors[idx])
                                    .frame(width: 28, height: 28)
                                
                                if let em = game.emojis[idx] {
                                    Text(em).font(.caption)
                                }
                            }
                        }
                        .disabled(!isMySeat)
                        
                        if isMySeat {
                            ColorPicker("", selection: Binding(
                                get: { game.colors[idx] },
                                set: { game.updatePlayerColor(at: idx, newColor: $0) }
                            ))
                            .labelsHidden()
                        }
                        
                        Text(game.playerNames[idx] + (isMySeat ? " (我)" : ""))
                            .font(.subheadline)
                            .bold()
                            .foregroundColor(isMySeat ? .cyan : .white)
                        
                        Spacer()
                        
                        if p2pManager.isHost {
                            Picker("", selection: Binding(
                                get: { game.playerTypes[idx] },
                                set: { game.updatePlayerType(at: idx, to: $0) }
                            )) {
                                ForEach(PlayerControlType.allCases) { type in
                                    Text(type.rawValue).tag(type)
                                }
                            }
                            .pickerStyle(.menu)
                            .tint(.white)
                        } else {
                            Text(game.playerTypes[idx].rawValue)
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                    }
                    .padding(10)
                    .glassEffect(.regular, in: .rect(cornerRadius: 18))
                }
            }
            
            if p2pManager.isHost {
                Button(action: onStartGame) {
                    HStack {
                        Image(systemName: "play.fill")
                        Text("全员开始对决").bold()
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .contentShape(Capsule())
                    .glassEffect(.regular.tint(.darkNavyBlue).interactive(), in: .capsule)
                }
                .buttonStyle(.plain)
            } else {
                Text("等待房主 \(p2pManager.hostDeviceName) 启动对局...")
                    .font(.subheadline)
                    .foregroundColor(.cyan)
                    .padding()
            }
        }
        .sheet(item: Binding<Int?>(
            get: { selectedPlayerForEmoji },
            set: { selectedPlayerForEmoji = $0 }
        )) { idx in
            EmojiPickerSheet(game: game, playerIndex: idx)
        }
    }
}

// MARK: - 17. 联机设置 View

enum ActiveOnlineMode {
    case none
    case localHost
    case localSearching
    case localJoined
}

struct OnlineGameSetupView: View {
    @ObservedObject var game: GameModel
    @ObservedObject var p2pManager = P2PNetworkManager.shared
    let onStartGame: () -> Void
    
    @State private var activeMode: ActiveOnlineMode = .none
    @State private var showAlertError: Bool = false
    
    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text("我的玩家昵称:")
                    .font(.subheadline)
                    .bold()
                    .foregroundColor(.white)
                
                TextField("输入昵称", text: $p2pManager.myNickname)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 180)
            }
            .padding(10)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
            
            if activeMode == .localHost || activeMode == .localJoined {
                RoomLobbyView(
                    game: game,
                    onExitLobby: {
                        activeMode = .none
                    },
                    onStartGame: onStartGame
                )
            } else {
                VStack(spacing: 14) {
                    HStack {
                        Text("🌐 本地局域网联机")
                            .font(.headline)
                            .foregroundColor(.white)
                        Spacer()
                    }
                    
                    HStack(spacing: 12) {
                        Button(action: {
                            p2pManager.startLocalHosting()
                            game.playerNames[0] = p2pManager.myNickname
                            game.myPlayerIndex = 0
                            activeMode = .localHost
                        }) {
                            Text("创建房间")
                                .bold()
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .contentShape(Capsule())
                                .glassEffect(.regular.tint(.darkNavyBlue).interactive(), in: .capsule)
                        }
                        .buttonStyle(.plain)
                        
                        Button(action: {
                            p2pManager.startLocalBrowsing()
                            activeMode = .localSearching
                        }) {
                            Text("搜索加入")
                                .bold()
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .contentShape(Capsule())
                                .glassEffect(.regular.interactive(), in: .capsule)
                        }
                        .buttonStyle(.plain)
                    }
                    
                    if activeMode == .localSearching {
                        LocalDeviceBrowserInlineView(
                            onSelectDevice: { device in
                                p2pManager.connectToDevice(device)
                                let cancellable = p2pManager.$isConnected
                                    .filter { $0 }
                                    .sink { _ in
                                        Task { @MainActor in
                                            game.playerNames[1] = p2pManager.myNickname
                                            game.myPlayerIndex = 1
                                            activeMode = .localJoined
                                        }
                                    }
                                _ = cancellable
                            },
                            onCancel: {
                                p2pManager.stopP2P()
                                activeMode = .none
                            }
                        )
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .padding()
                .glassEffect(.regular, in: .rect(cornerRadius: 18))
            }
        }
        .alert("连接失败", isPresented: $showAlertError) {
            Button("确定", role: .cancel) { }
        } message: {
            Text("房间不存在或网络连接超时！")
        }
    }
}

// MARK: - 18. 主菜单

struct StartMenuView: View {
    @ObservedObject var game: GameModel
    @Binding var isSpinningRandomWheel: Bool
    
    @State private var selectedTab: Int = 0
    
    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.04, green: 0.12, blue: 0.32),
                        Color(red: 0.03, green: 0.05, blue: 0.12)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
                
                VStack(spacing: 0) {
                    Spacer()
                    
                    GlassEffectContainer {
                        VStack(spacing: 18) {
                            Text("COLOR WAR")
                                .font(.system(size: 38, weight: .black, design: .rounded))
                                .foregroundStyle(
                                    LinearGradient(
                                        colors: [.white, .white.opacity(0.7)],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                            
                            if selectedTab == 0 {
                                LocalGameSetupView(game: game) {
                                    isSpinningRandomWheel = true
                                }
                                .transition(.opacity.combined(with: .scale(scale: 0.98)))
                            } else {
                                OnlineGameSetupView(game: game) {
                                    isSpinningRandomWheel = true
                                }
                                .transition(.opacity.combined(with: .scale(scale: 0.98)))
                            }
                        }
                    }
                    .frame(maxWidth: 420)
                    
                    Spacer()
                }
                .padding(.horizontal)
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Game Mode", selection: $selectedTab) {
                        Text("单机模式").tag(0)
                        Text("P2P 联机").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 210)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
        }
        .onAppear {
            NeuralAISolver.shared.reloadModels()
        }
    }
}

extension Int: @retroactive Identifiable {
    public var id: Int { self }
}

// MARK: - 19. 随机先手轮盘抽签 Overlay (采用精准原样参考代码动画)

struct RandomPlayerWheelOverlay: View {
    @ObservedObject var game: GameModel
    let activeIndices: [Int]
    let onFinished: (Int) -> Void
    
    @State private var highlightedIndex: Int = 0
    
    var body: some View {
        ZStack {
            Color.black.opacity(0.75)
                .ignoresSafeArea()
            
            VStack(spacing: 24) {
                Text("随机抽取先手玩家")
                    .font(.title2)
                    .bold()
                    .foregroundColor(.white)
                
                HStack(spacing: 12) {
                    ForEach(activeIndices, id: \.self) { pIdx in
                        let isHighlighted = (activeIndices[highlightedIndex] == pIdx)
                        VStack(spacing: 6) {
                            ZStack {
                                Circle()
                                    .fill(game.colors[pIdx])
                                    .frame(width: 48, height: 48)
                                
                                if let em = game.emojis[pIdx], !em.isEmpty {
                                    Text(em).font(.title2)
                                }
                            }
                            .scaleEffect(isHighlighted ? 1.25 : 0.95)
                            
                            Text(game.playerNames[pIdx])
                                .font(.caption2)
                                .bold()
                                .foregroundColor(isHighlighted ? .white : .gray)
                        }
                        .animation(.spring(response: 0.12, dampingFraction: 0.6), value: isHighlighted)
                    }
                }
                .padding(.horizontal)
            }
            .padding(32)
            .glassEffect(.regular, in: .rect(cornerRadius: 28))
            .frame(maxWidth: 380)
        }
        .onAppear {
            startFastWheelSpin()
        }
    }
    
    private func startFastWheelSpin() {
        let count = activeIndices.count
        guard count > 0 else { return }
        
        let targetWinner = activeIndices.randomElement()!
        let totalSteps = 16
        
        Task {
            var currentStep = 0
            var delayMs: UInt64 = 25_000_000
            
            while currentStep < totalSteps {
                try? await Task.sleep(nanoseconds: delayMs)
                highlightedIndex = (highlightedIndex + 1) % count
                currentStep += 1
                Haptics.shared.lightImpact()
                
                if totalSteps - currentStep < 6 {
                    delayMs += 20_000_000
                }
            }
            
            if let winnerPos = activeIndices.firstIndex(of: targetWinner) {
                highlightedIndex = winnerPos
            }
            
            try? await Task.sleep(nanoseconds: 150_000_000)
            onFinished(targetWinner)
        }
    }
}

// MARK: - 20. 主对局视图

struct GamePlayView: View {
    @ObservedObject var game: GameModel
    @Binding var isGameStarted: Bool
    @Binding var isSpinningRandomWheel: Bool
    
    var body: some View {
        ZStack {
            VStack {
                HStack {
                    Button(action: {
                        game.exitToMenu()
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            isGameStarted = false
                        }
                    }) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 36, height: 36)
                            .contentShape(Circle())
                            .glassEffect(.regular.interactive(), in: .circle)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("返回菜单")
                    
                    Spacer()
                    
                    HStack(spacing: 8) {
                        ZStack {
                            Circle()
                                .fill(game.colors[game.currentPlayer])
                                .frame(width: 14, height: 14)
                            
                            if let em = game.emojis[game.currentPlayer], !em.isEmpty {
                                Text(em).font(.caption2)
                            }
                        }
                        
                        Text("\(game.playerNames[game.currentPlayer]) 回合")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .glassEffect(.regular, in: Capsule())
                    
                    Spacer()
                    
                    Button(action: { game.showControlSheet = true }) {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 36, height: 36)
                            .contentShape(Circle())
                            .glassEffect(.regular.interactive(), in: .circle)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 8)
                
                Spacer()
                
                BoardView(game: game)
                
                Spacer()
            }
            .padding()
            
            if let wIdx = game.winnerIndex {
                Color.black.opacity(0.8).ignoresSafeArea()
                
                VStack(spacing: 24) {
                    ZStack {
                        Circle()
                            .fill(game.colors[wIdx].opacity(0.3))
                            .frame(width: 90, height: 90)
                        
                        Circle()
                            .stroke(game.colors[wIdx], lineWidth: 3)
                            .frame(width: 80, height: 80)
                        
                        if let em = game.emojis[wIdx], !em.isEmpty {
                            Text(em).font(.system(size: 42))
                        } else {
                            Image(systemName: "crown.fill")
                                .font(.system(size: 38))
                                .foregroundColor(.yellow)
                        }
                    }
                    
                    Text("\(game.playerNames[wIdx]) 获得胜利！")
                        .font(.title)
                        .bold()
                        .foregroundColor(.white)
                    
                    VStack(spacing: 12) {
                        Button(action: {
                            isSpinningRandomWheel = true
                        }) {
                            HStack {
                                Image(systemName: "arrow.clockwise")
                                Text("再来一局")
                            }
                            .font(.subheadline)
                            .bold()
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .contentShape(Capsule())
                            .glassEffect(.regular.tint(.darkNavyBlue).interactive(), in: .capsule)
                        }
                        .buttonStyle(.plain)
                        
                        Button(action: {
                            game.exitToMenu()
                            withAnimation(.spring()) { isGameStarted = false }
                        }) {
                            Text("返回主菜单")
                                .font(.subheadline)
                                .foregroundColor(.white.opacity(0.9))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .contentShape(Capsule())
                                .glassEffect(.regular.interactive(), in: .capsule)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(28)
                .glassEffect(.regular, in: .rect(cornerRadius: 24))
                .frame(maxWidth: 420)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .sheet(isPresented: $game.showControlSheet) {
            PlayerTakeoverSheet(game: game)
        }
    }
}

// MARK: - 21. 控制面板 Sheet

struct PlayerTakeoverSheet: View {
    @ObservedObject var game: GameModel
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button(action: {
                        game.resetGame()
                        dismiss()
                    }) {
                        HStack {
                            Spacer()
                            Image(systemName: "arrow.clockwise.circle.fill").font(.title3)
                            Text("重新开始本局").font(.headline).bold()
                            Spacer()
                        }
                        .foregroundColor(.white.opacity(0.9))
                    }
                }
                
                Section(header: Text("实时接管控制（AI / P2P 代打）")) {
                    ForEach(game.activePlayerIndices, id: \.self) { idx in
                        HStack {
                            Circle().fill(game.colors[idx]).frame(width: 16, height: 16)
                            Text(game.playerNames[idx]).font(.body)
                            Spacer()
                            
                            Picker("", selection: Binding(
                                get: { game.playerTypes[idx] },
                                set: { game.updatePlayerType(at: idx, to: $0) }
                            )) {
                                ForEach(PlayerControlType.allCases.filter { $0 != .disabled }) { type in
                                    Text(type.rawValue).tag(type)
                                }
                            }
                            .pickerStyle(.menu)
                        }
                    }
                }
            }
            .navigationTitle("对局控制面板")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("完成") { dismiss() }
            }
        }
        .presentationBackground(.thinMaterial)
    }
}

// MARK: - 22. 根视图 ContentView

struct ContentView: View {
    @StateObject private var game = GameModel()
    @State private var isGameStarted = false
    @State private var isSpinningRandomWheel = false
    
    var body: some View {
        ZStack {
            Color(red: 0.05, green: 0.06, blue: 0.09)
                .ignoresSafeArea()
            
            RadialGradient(
                colors: [
                    isGameStarted
                    ? game.colors[game.currentPlayer].opacity(0.25)
                    : Color(red: 0.04, green: 0.12, blue: 0.32).opacity(0.85),
                    Color.clear
                ],
                center: .center,
                startRadius: 40,
                endRadius: 450
            )
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.8), value: isGameStarted ? game.currentPlayer : -1)
            
            if isGameStarted {
                GamePlayView(
                    game: game,
                    isGameStarted: $isGameStarted,
                    isSpinningRandomWheel: $isSpinningRandomWheel
                )
            } else {
                StartMenuView(
                    game: game,
                    isSpinningRandomWheel: $isSpinningRandomWheel
                )
            }
            
            if isSpinningRandomWheel {
                RandomPlayerWheelOverlay(
                    game: game,
                    activeIndices: game.activePlayerIndices,
                    onFinished: { chosenWinner in
                        game.resetGame(chosenFirstPlayer: chosenWinner)
                        isSpinningRandomWheel = false
                        withAnimation(.spring()) {
                            isGameStarted = true
                        }
                    }
                )
            }
        }
    }
}

