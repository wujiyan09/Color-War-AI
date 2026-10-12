import SwiftUI
import Combine
import UIKit
import QuartzCore
import MultipeerConnectivity
import PhotosUI

// MARK: - 1. 触觉反馈引擎

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
    case mathNightmare = "算法-噩梦"
    case enhancedNightmare = "算法-噩梦 (加强版)"
    case p2pNetwork = "网络玩家 (P2P)"
    case disabled = "未加入"
    
    var id: String { rawValue }
    
    var isAI: Bool {
        self == .mathNightmare || self == .enhancedNightmare
    }
}

enum AIDifficultyLevel: Int, CaseIterable, Identifiable, Codable {
    case fast = 1
    case balanced = 2
    case deep = 3
    case extreme = 4
    
    var id: Int { rawValue }
    
    var title: String {
        switch self {
        case .fast: return "1档 · 快手 (极速)"
        case .balanced: return "2档 · 平衡 (推荐)"
        case .deep: return "3档 · 深谋 (算力)"
        case .extreme: return "4档 · 极限 (烧脑)"
        }
    }
    
    var description: String {
        switch self {
        case .fast: return "深度 2-3 层 | 基础评估"
        case .balanced: return "深度 3-5 层 | Alpha-Beta 剪枝"
        case .deep: return "深度 4-6 层 | 置换表+静止搜索"
        case .extreme: return "深度 6-8 层 | 全局链图+极限推理"
        }
    }
    
    func maxSearchDepth(for boardSize: Int) -> Int {
        switch self {
        case .fast:
            return boardSize <= 6 ? 3 : 2
        case .balanced:
            return boardSize <= 6 ? 5 : (boardSize <= 8 ? 4 : 3)
        case .deep:
            return boardSize <= 6 ? 6 : (boardSize <= 8 ? 5 : 4)
        case .extreme:
            return boardSize <= 6 ? 8 : (boardSize <= 8 ? 6 : 5)
        }
    }
    
    var beamWidth: Int {
        switch self {
        case .fast: return 2
        case .balanced: return 3
        case .deep: return 5
        case .extreme: return 8
        }
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
    
    static let cardCornerRadius: CGFloat = 20.0
}

struct Cell: Equatable, Codable, Sendable {
    var owner: Int?
    var count: Int
}

struct CompactCellSnapshot: Codable {
    let r: UInt8
    let c: UInt8
    let owner: Int8
    let count: UInt8
    
    init(r: Int, c: Int, owner: Int?, count: Int) {
        self.r = UInt8(min(255, max(0, r)))
        self.c = UInt8(min(255, max(0, c)))
        if let o = owner, o >= 0 {
            self.owner = Int8(min(127, o))
        } else {
            self.owner = -1
        }
        self.count = UInt8(min(255, max(0, count)))
    }
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

struct IdentifiableInt: Identifiable {
    let id: Int
}

// MARK: - 3. P2P 网络管理器

enum P2PAction: String, Codable {
    case hostConfig
    case playerMove
    case syncRequest
    case startGame
    case stateSnapshot
    case playerLeft
    case ping
    case ack
}

struct P2PPacket: Codable {
    var protocolVersion: Int = 2
    let sequenceID: UInt64
    let action: P2PAction
    let senderID: String
    var row: Int? = nil
    var col: Int? = nil
    var boardSize: Int? = nil
    var isRandomFirstPlayer: Bool? = nil
    var playerIndex: Int? = nil
    var firstPlayerIndex: Int? = nil
    var playerNames: [String]? = nil
    var playerTypes: [PlayerControlType]? = nil
    var colorsHex: [String]? = nil
    var emojis: [String]? = nil
    var aiLevelRaw: Int? = nil
    var compactBoardSnapshot: [CompactCellSnapshot]? = nil
    var currentTurnIndex: Int? = nil
    var hasEnteredSnapshot: [Bool]? = nil
    var eliminatedSnapshot: [Bool]? = nil
    
    init(sequenceID: UInt64, action: P2PAction, senderID: String) {
        self.sequenceID = sequenceID
        self.action = action
        self.senderID = senderID
    }
}

final class P2PNetworkManager: NSObject, ObservableObject, @unchecked Sendable {
    static let shared = P2PNetworkManager()
    
    private let serviceType = "colorwar-p2p"
    private var myPeerID: MCPeerID!
    private var serviceAdvertiser: MCNearbyServiceAdvertiser?
    private var serviceBrowser: MCNearbyServiceBrowser?
    private var mcSession: MCSession?
    
    let packetSubject = PassthroughSubject<P2PPacket, Never>()
    let disconnectSubject = PassthroughSubject<String, Never>()
    
    @Published var myNickname: String {
        didSet {
            guard !myNickname.isEmpty else { return }
            UserDefaults.standard.set(myNickname, forKey: "CW_Saved_MyNickname")
            if !isConnected && !isConnecting {
                rebuildPeerID()
            }
        }
    }
    
    @Published var hostDeviceName: String = ""
    @Published var discoveredDevices: [DiscoveredDevice] = []
    @Published var connectedPeers: [String] = []
    @Published var isHost: Bool = false
    @Published var isConnected: Bool = false
    @Published var isConnecting: Bool = false
    @Published var isSearchingTimeout: Bool = false
    
    private var sequenceCounter: UInt64 = 0
    private var searchTimer: Timer?
    private var heartbeatTimer: Timer?
    private var lastAckTime: Date = Date()
    
    override init() {
        let savedName = UserDefaults.standard.string(forKey: "CW_Saved_MyNickname")
        let nameToUse = (savedName == nil || savedName!.isEmpty) ? "玩家\(Int.random(in: 100...999))" : savedName!
        self.myNickname = nameToUse
        super.init()
        rebuildPeerID()
    }
    
    @MainActor
    func getNextSequenceID() -> UInt64 {
        sequenceCounter += 1
        return sequenceCounter
    }
    
    private func rebuildPeerID() {
        let name = myNickname.trimmingCharacters(in: .whitespacesAndNewlines)
        self.myPeerID = MCPeerID(displayName: name.isEmpty ? "匿名玩家" : String(name.prefix(63)))
        setupMCSession()
    }
    
    private func setupMCSession() {
        mcSession?.disconnect()
        mcSession = MCSession(peer: myPeerID, securityIdentity: nil, encryptionPreference: .none)
        mcSession?.delegate = self
    }
    
    @MainActor
    func startLocalHosting() {
        isHost = true
        hostDeviceName = myPeerID.displayName
        sequenceCounter = 0
        setupMCSession()
        
        serviceAdvertiser = MCNearbyServiceAdvertiser(peer: myPeerID, discoveryInfo: nil, serviceType: serviceType)
        serviceAdvertiser?.delegate = self
        serviceAdvertiser?.startAdvertisingPeer()
        startHeartbeat()
    }
    
    @MainActor
    func startLocalBrowsing() {
        isHost = false
        sequenceCounter = 0
        discoveredDevices.removeAll()
        isSearchingTimeout = false
        isConnecting = false
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
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        
        serviceAdvertiser?.stopAdvertisingPeer()
        serviceAdvertiser = nil
        serviceBrowser?.stopBrowsingForPeers()
        serviceBrowser = nil
        
        mcSession?.disconnect()
        mcSession = nil
        
        isConnected = false
        isConnecting = false
        isSearchingTimeout = false
        connectedPeers.removeAll()
        discoveredDevices.removeAll()
        hostDeviceName = ""
    }
    
    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        lastAckTime = Date()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                guard self.isConnected else { return }
                if Date().timeIntervalSince(self.lastAckTime) > 10.0 {
                    self.stopP2P()
                } else {
                    let packet = P2PPacket(sequenceID: self.getNextSequenceID(), action: .ping, senderID: self.myNickname)
                    self.sendPacket(packet)
                }
            }
        }
    }
    
    @MainActor
    func sendPacket(_ packet: P2PPacket) {
        guard let session = mcSession, !session.connectedPeers.isEmpty else { return }
        guard let data = try? JSONEncoder().encode(packet) else { return }
        try? session.send(data, toPeers: session.connectedPeers, with: .reliable)
    }
}

extension P2PNetworkManager: MCSessionDelegate, MCNearbyServiceAdvertiserDelegate, MCNearbyServiceBrowserDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.connectedPeers = session.connectedPeers.map { $0.displayName }
            self.isConnected = !session.connectedPeers.isEmpty
            
            if state == .notConnected {
                self.disconnectSubject.send(peerID.displayName)
            } else if state == .connected {
                self.isConnecting = false
                self.startHeartbeat()
            }
        }
    }
    
    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        if let packet = try? JSONDecoder().decode(P2PPacket.self, from: data) {
            guard packet.protocolVersion == 2 else { return }
            
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.lastAckTime = Date()
                if packet.action == .ping {
                    let ack = P2PPacket(sequenceID: self.getNextSequenceID(), action: .ack, senderID: self.myNickname)
                    self.sendPacket(ack)
                }
                self.packetSubject.send(packet)
            }
        }
    }
    
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        Task { @MainActor in
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
        return String(format: "#%02X%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255), Int(a * 255))
    }
    
    init(hex: String) {
        let hexStr = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hexStr).scanHexInt64(&int)
        let r, g, b, a: UInt64
        switch hexStr.count {
        case 6:
            (r, g, b, a) = ((int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF, 255)
        case 8:
            (r, g, b, a) = ((int >> 24) & 0xFF, (int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        default:
            (r, g, b, a) = (255, 0, 0, 255)
        }
        self.init(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: Double(a) / 255)
    }
    
    func isSimilar(to other: Color) -> Bool {
        var h1: CGFloat = 0, s1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var h2: CGFloat = 0, s2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        
        UIColor(self).getHue(&h1, saturation: &s1, brightness: &b1, alpha: &a1)
        UIColor(other).getHue(&h2, saturation: &s2, brightness: &b2, alpha: &a2)
        
        let hueDiff = min(abs(h1 - h2), 1.0 - abs(h1 - h2))
        let brightnessDiff = abs(b1 - b2)
        
        return hueDiff < 0.08 && brightnessDiff < 0.35
    }
}

// MARK: - 5. Zobrist 与启发式算力结构

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
    
    func lookup(hash: UInt64, depth: Int, alpha: Int, beta: Int) -> (score: Int, move: (Int, Int)?, hitCutoff: Bool, newAlpha: Int, newBeta: Int)? {
        guard let entry = table[hash], entry.depth >= depth else { return nil }
        var a = alpha
        var b = beta
        
        switch entry.type {
        case .exact:
            return (entry.score, entry.bestMove, true, a, b)
        case .lowerBound:
            a = max(a, entry.score)
        case .upperBound:
            b = min(b, entry.score)
        }
        
        if a >= b {
            return (entry.score, entry.bestMove, true, a, b)
        }
        return (entry.score, entry.bestMove, false, a, b)
    }
}

struct MoveOrderingTable: Sendable {
    private var killerMoves: [[(Int, Int)?]]
    private var historyTable: [[Int]]
    
    init(maxDepth: Int = 16) {
        self.killerMoves = Array(repeating: [nil, nil], count: maxDepth + 1)
        self.historyTable = Array(repeating: Array(repeating: 0, count: 12), count: 12)
    }
    
    mutating func recordCutoff(move: (Int, Int), depth: Int) {
        let (r, c) = move
        guard r >= 0 && r < 12 && c >= 0 && c < 12 else { return }
        historyTable[r][c] += depth * depth
        
        let validDepth = min(depth, killerMoves.count - 1)
        if killerMoves[validDepth][0]?.0 != r || killerMoves[validDepth][0]?.1 != c {
            killerMoves[validDepth][1] = killerMoves[validDepth][0]
            killerMoves[validDepth][0] = move
        }
    }
    
    func getOrderingScore(move: (Int, Int), depth: Int) -> Int {
        let (r, c) = move
        guard r >= 0 && r < 12 && c >= 0 && c < 12 else { return 0 }
        var score = historyTable[r][c]
        
        let validDepth = min(depth, killerMoves.count - 1)
        if let k1 = killerMoves[validDepth][0], k1 == move { score += 10_000 }
        if let k2 = killerMoves[validDepth][1], k2 == move { score += 5_000 }
        
        return score
    }
}

enum TacticalRiskMode {
    case dominant
    case balanced
    case desperate
}

// MARK: - 6. AI 算法引擎

struct AISolver: Sendable {
    struct SimCell: Sendable {
        var owner: Int?
        var count: Int
    }
    
    static let zobristTable: [[[[UInt64]]]] = {
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
        private(set) var cells: [SimCell]
        let size: Int
        var zobristHash: UInt64 = 0
        
        init(cells: [SimCell], size: Int) {
            self.cells = cells
            self.size = size
            self.zobristHash = computeFullZobristHash()
        }
        
        subscript(r: Int, _ c: Int) -> SimCell {
            cells[r * size + c]
        }
        
        private func computeFullZobristHash() -> UInt64 {
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
        
        mutating func updateCell(index: Int, oldOwner: Int?, oldCount: Int, newOwner: Int?, newCount: Int) {
            let r = index / size
            let c = index % size
            
            let oldOIdx = (oldOwner ?? -1) + 1
            let oldCVal = min(4, max(0, oldCount))
            let newOIdx = (newOwner ?? -1) + 1
            let newCVal = min(4, max(0, newCount))
            
            zobristHash ^= AISolver.zobristTable[r][c][oldOIdx][oldCVal]
            zobristHash ^= AISolver.zobristTable[r][c][newOIdx][newCVal]
            cells[index] = SimCell(owner: newOwner, count: newCount)
        }
    }
    
    let boardSize: Int
    let activePlayers: [Int]
    let currentPlayer: Int
    let playerType: PlayerControlType
    let aiLevel: AIDifficultyLevel
    let board: Board
    let hasEntered: [Bool]
    let eliminated: [Bool]
    private let neighborsMap: [[Int]]
    
    init(boardSize: Int,
         activePlayers: [Int],
         currentPlayer: Int,
         playerType: PlayerControlType,
         aiLevel: AIDifficultyLevel,
         board: [[Cell]],
         hasEntered: [Bool],
         eliminated: [Bool]) {
        self.boardSize = boardSize
        self.activePlayers = activePlayers
        self.currentPlayer = currentPlayer
        self.playerType = playerType
        self.aiLevel = aiLevel
        
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
    
    @inline(__always)
    private func getNextPlayerFast(current: Int, eliminated: [Bool]) -> Int {
        let alive = activePlayers.filter { !isPlayerEliminated($0, in: eliminated) }
        guard !alive.isEmpty else { return current }
        if let idx = alive.firstIndex(of: current) {
            return alive[(idx + 1) % alive.count]
        }
        return alive.first(where: { $0 > current }) ?? alive[0]
    }
    
    func calculateBestMove() async -> (Int, Int)? {
        if Task.isCancelled { return nil }
        
        var validMoves = getPlayableCells(for: currentPlayer, on: board)
        guard !validMoves.isEmpty else { return nil }
        
        let totalOrbsOnBoard = board.cells.reduce(0) { $0 + $1.count }
        let isMyFirstTurn = (currentPlayer < hasEntered.count) ? !hasEntered[currentPlayer] : true
        
        if totalOrbsOnBoard == 0 || (isMyFirstTurn && totalOrbsOnBoard <= boardSize) {
            let center = Double(boardSize - 1) / 2.0
            return validMoves.min(by: { m1, m2 in
                let dist1 = abs(Double(m1.0) - center) + abs(Double(m1.1) - center)
                let dist2 = abs(Double(m2.0) - center) + abs(Double(m2.1) - center)
                return dist1 < dist2
            })
        }
        
        if playerType == .enhancedNightmare {
            if let strikeMove = findCriticalThreatMove(validMoves: validMoves) {
                return strikeMove
            }
        }
        
        return calculateAspirationNightmareMove(validMoves: validMoves)
    }
    
    private func findCriticalThreatMove(validMoves: [(Int, Int)]) -> (Int, Int)? {
        var bestMove: (Int, Int)? = nil
        var maxSwallowedEnemies = 0
        
        for move in validMoves {
            let idx = move.0 * boardSize + move.1
            guard idx < board.cells.count else { continue }
            let cell = board.cells[idx]
            
            if cell.count == 3 || cell.owner == nil {
                var enemy3Count = 0
                if idx < neighborsMap.count {
                    for nIdx in neighborsMap[idx] {
                        let nCell = board.cells[nIdx]
                        if let nOwner = nCell.owner, nOwner != currentPlayer, nCell.count == 3 {
                            enemy3Count += 1
                        }
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
    
    private struct RootSearchResult {
        let move: (Int, Int)
        let score: Int
    }
    
    private func searchRoot(
        boardState: Board,
        hasEnteredState: [Bool],
        eliminatedState: [Bool],
        depth: Int,
        alpha: Int,
        beta: Int,
        isTwoPlayer: Bool,
        candidates: [(Int, Int)],
        tt: inout TranspositionTable,
        ordering: inout MoveOrderingTable
    ) -> RootSearchResult {
        var bestMoveLocal = candidates.first!
        var bestScoreLocal: Int? = nil
        var currentAlpha = alpha
        
        for move in candidates {
            if Task.isCancelled { break }
            
            var b = boardState
            var h = hasEnteredState
            var e = eliminatedState
            
            let (cascadeWaves, affectedEnemies) = simulateMoveBFSWithWaveDepthTracking(on: &b, move: move, player: currentPlayer, hasEntered: &h)
            updateEliminatedStatus(board: b, hasEntered: h, eliminated: &e)
            let nextP = getNextPlayerFast(current: currentPlayer, eliminated: e)
            
            var score: Int
            if isTwoPlayer {
                score = enhancedAlphaBetaNode(
                    boardState: b,
                    hasEnteredState: h,
                    eliminatedState: e,
                    depth: depth - 1,
                    alpha: currentAlpha,
                    beta: beta,
                    turnPlayer: nextP,
                    tt: &tt,
                    ordering: &ordering,
                    allowNullMove: true,
                    nmpCooldown: 0,
                    lastWaveCount: cascadeWaves
                )
            } else {
                let vec = maxNMultiPlayerSearch(
                    boardState: b,
                    hasEnteredState: h,
                    eliminatedState: e,
                    depth: depth - 1,
                    turnPlayer: nextP,
                    beamWidth: aiLevel.beamWidth
                )
                score = vec[currentPlayer, default: -999_999]
            }
            
            let psychBonus = computeMultiTargetThreatScore(move: move, waveCount: cascadeWaves, affectedEnemies: affectedEnemies, b: boardState)
            score += psychBonus
            
            if bestScoreLocal == nil || score > bestScoreLocal! {
                bestScoreLocal = score
                bestMoveLocal = move
            }
            
            currentAlpha = max(currentAlpha, score)
            if beta <= currentAlpha { break }
        }
        
        return RootSearchResult(
            move: bestMoveLocal,
            score: bestScoreLocal ?? (Int.min + 1)
        )
    }
    
    private func calculateAspirationNightmareMove(validMoves: [(Int, Int)]) -> (Int, Int)? {
        let maxDepth = aiLevel.maxSearchDepth(for: boardSize)
        
        let aliveCount = activePlayers.filter { !isPlayerEliminated($0, in: eliminated) }.count
        let isTwoPlayer = (aliveCount == 2)
        
        var tt = TranspositionTable()
        var ordering = MoveOrderingTable(maxDepth: maxDepth)
        
        var sortedMoves = validMoves.sorted {
            evaluateMoveTacticalPriority($0, on: board, player: currentPlayer)
            > evaluateMoveTacticalPriority($1, on: board, player: currentPlayer)
        }
        
        var bestMove = sortedMoves.first
        var lastGuess = 0
        let windowDelta = 120
        
        for depth in 2...maxDepth {
            if Task.isCancelled { break }
            
            let result: RootSearchResult
            if depth == 2 {
                result = searchRoot(boardState: board, hasEnteredState: hasEntered, eliminatedState: eliminated, depth: depth, alpha: Int.min + 1, beta: Int.max - 1, isTwoPlayer: isTwoPlayer, candidates: sortedMoves, tt: &tt, ordering: &ordering)
            } else {
                let alpha = lastGuess - windowDelta
                let beta = lastGuess + windowDelta
                let tempResult = searchRoot(boardState: board, hasEnteredState: hasEntered, eliminatedState: eliminated, depth: depth, alpha: alpha, beta: beta, isTwoPlayer: isTwoPlayer, candidates: sortedMoves, tt: &tt, ordering: &ordering)
                
                if tempResult.score <= alpha || tempResult.score >= beta {
                    result = searchRoot(boardState: board, hasEnteredState: hasEntered, eliminatedState: eliminated, depth: depth, alpha: Int.min + 1, beta: Int.max - 1, isTwoPlayer: isTwoPlayer, candidates: sortedMoves, tt: &tt, ordering: &ordering)
                } else {
                    result = tempResult
                }
            }
            
            bestMove = result.move
            lastGuess = result.score
            
            if let bm = bestMove {
                sortedMoves.removeAll(where: { $0.0 == bm.0 && $0.1 == bm.1 })
                sortedMoves.insert(bm, at: 0)
            }
        }
        return bestMove
    }
    
    private func enhancedAlphaBetaNode(boardState: Board,
                                       hasEnteredState: [Bool],
                                       eliminatedState: [Bool],
                                       depth: Int,
                                       alpha: Int,
                                       beta: Int,
                                       turnPlayer: Int,
                                       tt: inout TranspositionTable,
                                       ordering: inout MoveOrderingTable,
                                       allowNullMove: Bool,
                                       nmpCooldown: Int,
                                       lastWaveCount: Int = 0) -> Int {
        if Task.isCancelled { return 0 }
        
        var a = alpha
        var bVal = beta
        
        let hash = boardState.zobristHash
        if let res = tt.lookup(hash: hash, depth: depth, alpha: a, beta: bVal) {
            a = res.newAlpha
            bVal = res.newBeta
            if res.hitCutoff { return res.score }
        }
        
        let myOrbCount = boardState.cells.filter { $0.owner == turnPlayer }.reduce(0) { $0 + $1.count }
        let isZugzwangRisk = myOrbCount <= 3
        
        let R = 2
        if allowNullMove && !isZugzwangRisk && nmpCooldown == 0 && depth > R + 1 && !isGameOverSimulated(eliminated: eliminatedState) {
            let isTacticalField = boardState.cells.contains { $0.count == 3 }
            if !isTacticalField {
                let nextP = getNextPlayerFast(current: turnPlayer, eliminated: eliminatedState)
                let nullVal = -enhancedAlphaBetaNode(
                    boardState: boardState,
                    hasEnteredState: hasEnteredState,
                    eliminatedState: eliminatedState,
                    depth: depth - 1 - R,
                    alpha: -bVal,
                    beta: -bVal + 1,
                    turnPlayer: nextP,
                    tt: &tt,
                    ordering: &ordering,
                    allowNullMove: false,
                    nmpCooldown: 3,
                    lastWaveCount: 0
                )
                if nullVal >= bVal {
                    return bVal
                }
            }
        }
        
        if depth <= 1 || isGameOverSimulated(eliminated: eliminatedState) {
            let qsDepth = (aiLevel == .extreme) ? 4 : ((aiLevel == .deep) ? 3 : 2)
            let val = quiescenceSearch(boardState: boardState, hasEnteredState: hasEnteredState, eliminatedState: eliminatedState, alpha: a, beta: bVal, turnPlayer: turnPlayer, qsDepth: qsDepth, tt: &tt)
            tt.store(hash: hash, depth: depth, score: val, type: .exact, move: nil)
            return val
        }
        
        let validMoves = getPlayableCells(for: turnPlayer, on: boardState)
        if validMoves.isEmpty {
            let nextP = getNextPlayerFast(current: turnPlayer, eliminated: eliminatedState)
            return enhancedAlphaBetaNode(
                boardState: boardState,
                hasEnteredState: hasEnteredState,
                eliminatedState: eliminatedState,
                depth: depth - 1,
                alpha: a,
                beta: bVal,
                turnPlayer: nextP,
                tt: &tt,
                ordering: &ordering,
                allowNullMove: true,
                nmpCooldown: max(0, nmpCooldown - 1),
                lastWaveCount: lastWaveCount
            )
        }
        
        let sorted = validMoves.sorted { m1, m2 in
            let p1 = evaluateMoveTacticalPriority(m1, on: boardState, player: turnPlayer) + ordering.getOrderingScore(move: m1, depth: depth)
            let p2 = evaluateMoveTacticalPriority(m2, on: boardState, player: turnPlayer) + ordering.getOrderingScore(move: m2, depth: depth)
            return p1 > p2
        }
        
        var maxEval = Int.min
        var bestMoveLocal: (Int, Int)? = nil
        let nextCooldown = max(0, nmpCooldown - 1)
        
        for (index, move) in sorted.enumerated() {
            if Task.isCancelled { break }
            
            var b = boardState
            var h = hasEnteredState
            var e = eliminatedState
            
            let (waves, _) = simulateMoveBFSWithWaveDepthTracking(on: &b, move: move, player: turnPlayer, hasEntered: &h)
            updateEliminatedStatus(board: b, hasEntered: h, eliminated: &e)
            let nextP = getNextPlayerFast(current: turnPlayer, eliminated: e)
            
            var eval = Int.min
            
            if index >= 3 && depth >= 3 && boardState[move.0, move.1].count < 3 {
                eval = -enhancedAlphaBetaNode(boardState: b, hasEnteredState: h, eliminatedState: e, depth: depth - 2, alpha: -a - 1, beta: -a, turnPlayer: nextP, tt: &tt, ordering: &ordering, allowNullMove: true, nmpCooldown: nextCooldown, lastWaveCount: waves)
                if eval > a {
                    eval = -enhancedAlphaBetaNode(boardState: b, hasEnteredState: h, eliminatedState: e, depth: depth - 1, alpha: -bVal, beta: -a, turnPlayer: nextP, tt: &tt, ordering: &ordering, allowNullMove: true, nmpCooldown: nextCooldown, lastWaveCount: waves)
                }
            } else {
                eval = -enhancedAlphaBetaNode(boardState: b, hasEnteredState: h, eliminatedState: e, depth: depth - 1, alpha: -bVal, beta: -a, turnPlayer: nextP, tt: &tt, ordering: &ordering, allowNullMove: true, nmpCooldown: nextCooldown, lastWaveCount: waves)
            }
            
            if eval > maxEval {
                maxEval = eval
                bestMoveLocal = move
            }
            a = max(a, eval)
            if bVal <= a {
                ordering.recordCutoff(move: move, depth: depth)
                break
            }
        }
        
        tt.store(hash: hash, depth: depth, score: maxEval, type: maxEval >= beta ? .lowerBound : .exact, move: bestMoveLocal)
        return maxEval
    }
    
    private func quiescenceSearch(boardState: Board,
                                  hasEnteredState: [Bool],
                                  eliminatedState: [Bool],
                                  alpha: Int,
                                  beta: Int,
                                  turnPlayer: Int,
                                  qsDepth: Int,
                                  tt: inout TranspositionTable) -> Int {
        if Task.isCancelled || qsDepth <= 0 {
            return evaluateAdvancedBoard(boardState, forPlayer: currentPlayer, eliminated: eliminatedState, currentTurn: turnPlayer, lastCascadeWaves: 0)
        }
        
        var a = alpha
        let standPat = evaluateAdvancedBoard(boardState, forPlayer: currentPlayer, eliminated: eliminatedState, currentTurn: turnPlayer, lastCascadeWaves: 0)
        if standPat >= beta { return beta }
        if standPat > a { a = standPat }
        
        let tacticalMoves = getTacticalForcingMoves(on: boardState, player: turnPlayer)
        if tacticalMoves.isEmpty { return standPat }
        
        for move in tacticalMoves {
            var b = boardState
            var h = hasEnteredState
            var e = eliminatedState
            
            _ = simulateMoveBFSWithWaveDepthTracking(on: &b, move: move, player: turnPlayer, hasEntered: &h)
            updateEliminatedStatus(board: b, hasEntered: h, eliminated: &e)
            
            let score = -quiescenceSearch(boardState: b,
                                          hasEnteredState: h,
                                          eliminatedState: e,
                                          alpha: -beta,
                                          beta: -a,
                                          turnPlayer: getNextPlayerFast(current: turnPlayer, eliminated: e),
                                          qsDepth: qsDepth - 1,
                                          tt: &tt)
            if score >= beta { return beta }
            if score > a { a = score }
        }
        return a
    }
    
    private func getTacticalForcingMoves(on b: Board, player: Int) -> [(Int, Int)] {
        var forcingMoves: [(Int, Int)] = []
        let validMoves = getPlayableCells(for: player, on: b)
        
        for move in validMoves {
            let idx = move.0 * boardSize + move.1
            guard idx < b.cells.count else { continue }
            let cell = b.cells[idx]
            
            if cell.count == 3 {
                forcingMoves.append(move)
                continue
            }
            
            var reachesEnemy3 = false
            if idx < neighborsMap.count {
                for nIdx in neighborsMap[idx] {
                    let nCell = b.cells[nIdx]
                    if let nOwner = nCell.owner, nOwner != player, nCell.count == 3 {
                        reachesEnemy3 = true
                        break
                    }
                }
            }
            if reachesEnemy3 { forcingMoves.append(move) }
        }
        return forcingMoves
    }
    
    private func maxNMultiPlayerSearch(boardState: Board,
                                       hasEnteredState: [Bool],
                                       eliminatedState: [Bool],
                                       depth: Int,
                                       turnPlayer: Int,
                                       beamWidth: Int) -> [Int: Int] {
        if Task.isCancelled || depth <= 0 || isGameOverSimulated(eliminated: eliminatedState) {
            return evaluateMultiPlayerVector(boardState, eliminated: eliminatedState)
        }
        
        let moves = getPlayableCells(for: turnPlayer, on: boardState)
        if moves.isEmpty {
            let nextP = getNextPlayerFast(current: turnPlayer, eliminated: eliminatedState)
            return maxNMultiPlayerSearch(boardState: boardState, hasEnteredState: hasEnteredState, eliminatedState: eliminatedState, depth: depth - 1, turnPlayer: nextP, beamWidth: beamWidth)
        }
        
        let sorted = moves.sorted {
            evaluateMoveTacticalPriority($0, on: boardState, player: turnPlayer)
            > evaluateMoveTacticalPriority($1, on: boardState, player: turnPlayer)
        }
        let candidates = Array(sorted.prefix(beamWidth))
        
        var bestVector: [Int: Int] = [:]
        var maxPlayerVal = -Int.max
        
        for m in candidates {
            if Task.isCancelled { break }
            
            var b = boardState
            var h = hasEnteredState
            var e = eliminatedState
            
            _ = simulateMoveBFSWithWaveDepthTracking(on: &b, move: m, player: turnPlayer, hasEntered: &h)
            updateEliminatedStatus(board: b, hasEntered: h, eliminated: &e)
            
            let nextP = getNextPlayerFast(current: turnPlayer, eliminated: e)
            let resultVector = maxNMultiPlayerSearch(boardState: b, hasEnteredState: h, eliminatedState: e, depth: depth - 1, turnPlayer: nextP, beamWidth: beamWidth)
            
            let pScore = resultVector[turnPlayer, default: -999_999]
            if pScore > maxPlayerVal {
                maxPlayerVal = pScore
                bestVector = resultVector
            }
        }
        
        return bestVector
    }
    
    private func evaluateMultiPlayerVector(_ b: Board, eliminated: [Bool]) -> [Int: Int] {
        var orbCounts = [Int](repeating: 0, count: PlayerPreset.maxPlayers)
        var scores = [Int](repeating: 0, count: PlayerPreset.maxPlayers)
        
        for idx in 0..<(boardSize * boardSize) {
            guard idx < b.cells.count else { continue }
            let cell = b.cells[idx]
            guard let owner = cell.owner, owner >= 0 && owner < PlayerPreset.maxPlayers else { continue }
            
            let neighbors = idx < neighborsMap.count ? neighborsMap[idx] : []
            var val = cell.count * 15 + neighbors.count * 5
            
            if cell.count == 3 {
                val += 35
                for nIdx in neighbors {
                    let nCell = b.cells[nIdx]
                    if let nOwner = nCell.owner, nOwner != owner {
                        if nCell.count == 3 {
                            val -= 1500
                        }
                    }
                }
            }
            
            orbCounts[owner] += cell.count
            scores[owner] += val
        }
        
        let maxOrbCount = orbCounts.max() ?? 0
        let leaderIndex = orbCounts.firstIndex(of: maxOrbCount)
        
        var vectorResult: [Int: Int] = [:]
        for p in activePlayers {
            if isPlayerEliminated(p, in: eliminated) {
                vectorResult[p] = -999_999
            } else {
                var finalScore = scores[p]
                if let leader = leaderIndex, leader != p && maxOrbCount > 5 {
                    let leaderOrbDiff = orbCounts[leader] - orbCounts[p]
                    finalScore -= Int(Double(leaderOrbDiff) * 35.0)
                }
                vectorResult[p] = finalScore
            }
        }
        return vectorResult
    }
    
    private func evaluateAdvancedBoard(_ b: Board, forPlayer player: Int, eliminated: [Bool], currentTurn: Int, lastCascadeWaves: Int) -> Int {
        if isPlayerEliminated(player, in: eliminated) { return -999_999 }
        
        var score = 0
        var myOrbs = 0
        var maxEnemyOrbs = 0
        var enemyThreat3Count = 0
        let totalCells = min(b.cells.count, boardSize * boardSize)
        
        var enemyOrbsMap = [Int: Int]()
        
        for idx in 0..<totalCells {
            let cell = b.cells[idx]
            guard let owner = cell.owner else { continue }
            
            let neighbors = idx < neighborsMap.count ? neighborsMap[idx] : []
            let neighborCount = neighbors.count
            
            var cellVal = cell.count * 15 + neighborCount * 5
            
            if cell.count == 3 {
                cellVal += 35
                
                for nIdx in neighbors {
                    let nCell = b.cells[nIdx]
                    if let nOwner = nCell.owner, nOwner != owner {
                        if nCell.count == 3 {
                            if owner == player { enemyThreat3Count += 1 }
                            if currentTurn == owner {
                                cellVal += (owner == player) ? 3000 : -3000
                            } else {
                                cellVal -= (owner == player) ? 3500 : -3500
                            }
                        } else if nCell.count == 2 {
                            cellVal += (owner == player) ? 400 : -400
                        }
                    }
                }
            } else if cell.count <= 2 {
                for nIdx in neighbors {
                    let nCell = b.cells[nIdx]
                    if let nOwner = nCell.owner, nOwner != owner, nCell.count == 3 {
                        cellVal -= (owner == player) ? 800 : -800
                    }
                }
            }
            
            if owner == player {
                myOrbs += cell.count
                score += cellVal
            } else {
                enemyOrbsMap[owner, default: 0] += cell.count
                score -= Int(Double(cellVal) * 1.25)
            }
        }
        
        maxEnemyOrbs = enemyOrbsMap.values.max() ?? 0
        
        let chainScore = computeChainGraphPotentials(on: b, player: player)
        score += chainScore
        
        let ratio = Double(myOrbs) / Double(max(1, maxEnemyOrbs))
        let riskMode: TacticalRiskMode = ratio >= 1.35 ? .dominant : (ratio <= 0.65 ? .desperate : .balanced)
        
        switch riskMode {
        case .dominant:
            score -= enemyThreat3Count * 1200
            score += lastCascadeWaves * 30
        case .desperate:
            score -= enemyThreat3Count * 200
            score += lastCascadeWaves * 250
        case .balanced:
            score -= enemyThreat3Count * 600
            score += lastCascadeWaves * 80
        }
        
        let eliminatedEnemies = activePlayers.filter { $0 != player && isPlayerEliminated($0, in: eliminated) }.count
        return score + eliminatedEnemies * 2000 + (myOrbs - maxEnemyOrbs) * 25
    }
    
    private func computeChainGraphPotentials(on b: Board, player: Int) -> Int {
        var visited = Array(repeating: false, count: b.cells.count)
        var score = 0
        
        for idx in 0..<b.cells.count {
            let cell = b.cells[idx]
            guard !visited[idx], cell.count == 3, let owner = cell.owner else { continue }
            
            var componentSize = 0
            var queue = [idx]
            visited[idx] = true
            
            while !queue.isEmpty {
                let curr = queue.removeFirst()
                componentSize += 1
                
                if curr < neighborsMap.count {
                    for nIdx in neighborsMap[curr] {
                        if nIdx < b.cells.count {
                            let nCell = b.cells[nIdx]
                            if !visited[nIdx] && nCell.count == 3 && nCell.owner == owner {
                                visited[nIdx] = true
                                queue.append(nIdx)
                            }
                        }
                    }
                }
            }
            
            let graphVal = componentSize * componentSize * 50
            if owner == player {
                score += graphVal
            } else {
                score -= Int(Double(graphVal) * 1.3)
            }
        }
        return score
    }
    
    private func computeMultiTargetThreatScore(move: (Int, Int), waveCount: Int, affectedEnemies: Set<Int>, b: Board) -> Int {
        var score = 0
        
        if affectedEnemies.count >= 2 {
            score += affectedEnemies.count * 450
        }
        
        if waveCount >= 2 {
            let (r, c) = move
            var maxDistance = 0
            for targetIdx in 0..<b.cells.count {
                let cell = b.cells[targetIdx]
                if let owner = cell.owner, owner != currentPlayer, cell.count == 3 {
                    let tr = targetIdx / boardSize
                    let tc = targetIdx % boardSize
                    let dist = abs(r - tr) + abs(c - tc)
                    if dist > maxDistance { maxDistance = dist }
                }
            }
            if maxDistance >= 3 {
                score += maxDistance * 160 + waveCount * 100
            }
        }
        return score
    }
    
    private func evaluateMoveTacticalPriority(_ move: (Int, Int), on b: Board, player: Int) -> Int {
        let (r, c) = move
        let idx = r * boardSize + c
        guard idx < b.cells.count else { return 0 }
        let cell = b[r, c]
        
        var priority = 0
        let neighbors = idx < neighborsMap.count ? neighborsMap[idx] : []
        
        if cell.count == 3 || cell.owner == nil {
            for nIdx in neighbors {
                let nCell = b.cells[nIdx]
                if let nOwner = nCell.owner, nOwner != player, nCell.count == 3 {
                    priority += 4000
                }
            }
        }
        
        if cell.count < 3 {
            for nIdx in neighbors {
                let nCell = b.cells[nIdx]
                if let nOwner = nCell.owner, nOwner != player, nCell.count == 3 {
                    priority -= 2000
                }
            }
        }
        
        priority += neighbors.count * 10
        if cell.count == 3 { priority += 500 }
        
        return priority
    }
    
    private func simulateMoveBFSWithWaveDepthTracking(on simBoard: inout Board, move: (Int, Int), player: Int, hasEntered: inout [Bool]) -> (Int, Set<Int>) {
        let flatIndex = move.0 * boardSize + move.1
        guard flatIndex < simBoard.cells.count, player >= 0 && player < hasEntered.count else { return (0, []) }
        
        let isFirst = !hasEntered[player]
        hasEntered[player] = true
        
        let oldCell = simBoard.cells[flatIndex]
        simBoard.updateCell(index: flatIndex, oldOwner: oldCell.owner, oldCount: oldCell.count, newOwner: player, newCount: oldCell.count + (isFirst ? 3 : 1))
        
        guard simBoard.cells[flatIndex].count >= 4 else { return (0, []) }
        
        var queue = [Int]()
        queue.append(flatIndex)
        var waveCount = 0
        let maxWaveCount = 100
        var affectedEnemies = Set<Int>()
        
        while !queue.isEmpty && waveCount < maxWaveCount {
            waveCount += 1
            let count = queue.count
            for _ in 0..<count {
                let currIdx = queue.removeFirst()
                guard currIdx < simBoard.cells.count else { continue }
                let currCell = simBoard.cells[currIdx]
                if currCell.count < 4 { continue }
                
                let remCount = currCell.count - 4
                let nextOwner = remCount == 0 ? nil : player
                simBoard.updateCell(index: currIdx, oldOwner: currCell.owner, oldCount: currCell.count, newOwner: nextOwner, newCount: remCount)
                
                if currIdx < neighborsMap.count {
                    for nIdx in neighborsMap[currIdx] {
                        if nIdx < simBoard.cells.count {
                            let nCell = simBoard.cells[nIdx]
                            if let nOwner = nCell.owner, nOwner != player {
                                affectedEnemies.insert(nOwner)
                            }
                            simBoard.updateCell(index: nIdx, oldOwner: nCell.owner, oldCount: nCell.count, newOwner: player, newCount: nCell.count + 1)
                            if simBoard.cells[nIdx].count >= 4 {
                                queue.append(nIdx)
                            }
                        }
                    }
                }
            }
        }
        return (waveCount, affectedEnemies)
    }
    
    private func updateEliminatedStatus(board b: Board, hasEntered: [Bool], eliminated: inout [Bool]) {
        var appears = [Bool](repeating: false, count: PlayerPreset.maxPlayers)
        for cell in b.cells {
            if let o = cell.owner, o >= 0, o < PlayerPreset.maxPlayers {
                appears[o] = true
            }
        }
        for p in activePlayers where p >= 0 && p < hasEntered.count && p < eliminated.count {
            if hasEntered[p] && !eliminated[p] {
                if !appears[p] {
                    eliminated[p] = true
                }
            }
        }
    }
    
    private func getPlayableCells(for player: Int, on b: Board) -> [(Int, Int)] {
        let ownsAny = b.cells.contains { $0.owner == player }
        var moves: [(Int, Int)] = []
        moves.reserveCapacity(b.size * b.size)
        
        for r in 0..<boardSize {
            for c in 0..<boardSize {
                let idx = r * boardSize + c
                if idx < b.cells.count {
                    let owner = b.cells[idx].owner
                    if ownsAny ? (owner == player) : (owner == nil) {
                        moves.append((r, c))
                    }
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

// MARK: - 7. GameModel ViewModel

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
    @Published var aiDifficultyLevel: AIDifficultyLevel {
        didSet {
            UserDefaults.standard.set(aiDifficultyLevel.rawValue, forKey: "CW_Saved_AIDifficultyLevel")
            syncRoomConfigToPeers()
        }
    }
    
    @Published var board: [[Cell]] = []
    
    @Published var playerNames: [String] {
        didSet { debounceSave() }
    }
    @Published var playerTypes: [PlayerControlType] {
        didSet {
            debounceSave()
            refreshActivePlayers()
        }
    }
    @Published var colors: [Color] {
        didSet { debounceSave() }
    }
    @Published var emojis: [String?] {
        didSet { debounceSave() }
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
    @Published var flyingOrbs: [FlyingOrb] = []
    @Published var emphasizedCells: Set<Int> = []
    @Published var showDisconnectedAlert: Bool = false
    @Published var activeOnlineMode: ActiveOnlineMode = .none
    
    @Published var customBackgroundImage: UIImage? = nil
    
    // ✅ 隐藏3控制标识：用于通知 UI 侧（特别是 P2P 客户端）跳转切屏
    @Published var shouldNavigateToGame: Bool = false
    
    @Published private(set) var isGameInPlay: Bool = false
    @Published private(set) var activePlayerIndices: [Int] = []
    @Published private(set) var playableCells: Set<Int> = []
    @Published private(set) var cachedOrbCounts: [Int: Int] = [:]
    
    private var lastReceivedSeqID: UInt64 = 0
    private var currentGameSessionID: UUID = UUID()
    private var actionQueue: [(Int, Int, Int)] = []
    
    private var p2pCancellable: AnyCancellable? = nil
    private var disconnectCancellable: AnyCancellable? = nil
    private var aiTask: Task<Void, Never>? = nil
    private var saveWorkItem: DispatchWorkItem? = nil
    
    func beginGame() {
        isGameInPlay = true
    }
    
    func endGame() {
        isGameInPlay = false
    }
    
    private func refreshActivePlayers() {
        self.activePlayerIndices = playerTypes.enumerated().compactMap { $1 != .disabled ? $0 : nil }
    }
    
    func validSelectableTypes(forPlayerIndex idx: Int, isInLobby: Bool = false) -> [PlayerControlType] {
        let isP2PConnected = P2PNetworkManager.shared.isConnected
        let isSeat0 = (idx == 0)
        let isMySeat = (isP2PConnected && idx == myPlayerIndex)
        
        return PlayerControlType.allCases.filter { type in
            if (isSeat0 || isMySeat) && type == .disabled { return false }
            
            if isGameInPlay {
                return type == playerTypes[idx]
            }
            
            if type == .p2pNetwork {
                return isP2PConnected || isInLobby
            }
            
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
        
        #if DEBUG
        if newValue < 0 {
            print("⚠️ [OrbCount Warning] 玩家 \(p) 计数值修正前出现负数: \(newValue)")
        }
        #endif
        
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
                .human, .mathNightmare, .enhancedNightmare, .human,
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
        
        if let imgData = UserDefaults.standard.data(forKey: "CW_Saved_CustomBackground"),
           !imgData.isEmpty,
           let img = UIImage(data: imgData) {
            self.customBackgroundImage = img
        } else {
            self.customBackgroundImage = nil
        }
        
        self.activePlayerIndices = self.playerTypes.enumerated().compactMap { $1 != .disabled ? $0 : nil }
        self.playableCells = []
        
        setupP2PListener()
        resetGame()
    }
    
    func saveCustomBackground(_ image: UIImage?) {
        self.customBackgroundImage = image
        if let img = image, let data = img.jpegData(compressionQuality: 0.8) {
            UserDefaults.standard.set(data, forKey: "CW_Saved_CustomBackground")
        } else {
            UserDefaults.standard.removeObject(forKey: "CW_Saved_CustomBackground")
        }
    }
    
    private func setupP2PListener() {
        p2pCancellable?.cancel()
        p2pCancellable = P2PNetworkManager.shared.packetSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] packet in
                guard let self = self else { return }
                
                if packet.action != .ping && packet.action != .ack {
                    guard packet.sequenceID > self.lastReceivedSeqID else { return }
                    self.lastReceivedSeqID = packet.sequenceID
                }
                
                switch packet.action {
                case .playerMove:
                    if let r = packet.row, let c = packet.col, let pIdx = packet.playerIndex {
                        self.enqueueNetworkMove(row: r, column: c, player: pIdx)
                    }
                    
                case .syncRequest:
                    if P2PNetworkManager.shared.isHost {
                        self.broadcastFullStateSnapshot()
                    }
                    
                case .hostConfig:
                    if let names = packet.playerNames { self.playerNames = names }
                    if let types = packet.playerTypes { self.playerTypes = types }
                    if let hexes = packet.colorsHex { self.colors = hexes.map { Color(hex: $0) } }
                    if let ems = packet.emojis { self.emojis = ems.map { $0.isEmpty ? nil : $0 } }
                    if let sz = packet.boardSize { self.boardSize = sz }
                    if let rnd = packet.isRandomFirstPlayer { self.isRandomFirstPlayer = rnd }
                    if let aiLvl = packet.aiLevelRaw, let level = AIDifficultyLevel(rawValue: aiLvl) { self.aiDifficultyLevel = level }
                    
                case .startGame:
                    // ✅ 隐患 3 修复：客户端收到 .startGame 时，重置+开启对局并主动唤醒界面导航
                    if let firstP = packet.firstPlayerIndex {
                        self.resetGame(chosenFirstPlayer: firstP)
                        self.beginGame()
                        self.shouldNavigateToGame = true
                    }
                    
                case .stateSnapshot:
                    if let names = packet.playerNames { self.playerNames = names }
                    if let types = packet.playerTypes { self.playerTypes = types }
                    
                    if let compactSnap = packet.compactBoardSnapshot, let turnP = packet.currentTurnIndex {
                        var grid = [[Cell]](repeating: [Cell](repeating: Cell(owner: nil, count: 0), count: self.boardSize), count: self.boardSize)
                        for item in compactSnap {
                            let r = Int(item.r)
                            let c = Int(item.c)
                            if r < self.boardSize && c < self.boardSize {
                                grid[r][c] = Cell(owner: item.owner < 0 ? nil : Int(item.owner), count: Int(item.count))
                            }
                        }
                        self.board = grid
                        if let entered = packet.hasEnteredSnapshot { self.hasEntered = entered }
                        if let elim = packet.eliminatedSnapshot { self.eliminated = elim }
                        self.recalculateOrbCounts()
                        self.currentPlayer = turnP
                        
                        if P2PNetworkManager.shared.isHost {
                            self.checkAndRunAITurn()
                        }
                    }
                    
                default:
                    break
                }
            }
        
        disconnectCancellable?.cancel()
        disconnectCancellable = P2PNetworkManager.shared.disconnectSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] disconnectedPeerName in
                guard let self = self else { return }
                if P2PNetworkManager.shared.isHost {
                    for i in 0..<PlayerPreset.maxPlayers {
                        if self.playerNames[safe: i] == disconnectedPeerName && self.playerTypes[safe: i] == .p2pNetwork {
                            self.updatePlayerType(at: i, to: .mathNightmare, forceInternal: true)
                            self.broadcastFullStateSnapshot()
                            if self.currentPlayer == i && !self.isProcessingCascade {
                                self.checkAndRunAITurn()
                            }
                        }
                    }
                } else {
                    if disconnectedPeerName == P2PNetworkManager.shared.hostDeviceName {
                        self.showDisconnectedAlert = true
                        self.exitToMenu()
                    }
                }
            }
    }
    
    func syncRoomConfigToPeers() {
        guard P2PNetworkManager.shared.isHost && P2PNetworkManager.shared.isConnected else { return }
        var packet = P2PPacket(sequenceID: P2PNetworkManager.shared.getNextSequenceID(), action: .hostConfig, senderID: P2PNetworkManager.shared.myNickname)
        packet.boardSize = boardSize
        packet.isRandomFirstPlayer = isRandomFirstPlayer
        packet.playerNames = playerNames
        packet.playerTypes = playerTypes
        packet.colorsHex = colors.map { $0.toHex() }
        packet.emojis = emojis.map { $0 ?? "" }
        packet.aiLevelRaw = aiDifficultyLevel.rawValue
        P2PNetworkManager.shared.sendPacket(packet)
    }
    
    private func broadcastFullStateSnapshot() {
        guard P2PNetworkManager.shared.isHost && P2PNetworkManager.shared.isConnected else { return }
        
        var compactList = [CompactCellSnapshot]()
        for r in 0..<boardSize {
            for c in 0..<boardSize {
                let cell = board[r][c]
                if cell.count > 0 {
                    compactList.append(CompactCellSnapshot(r: r, c: c, owner: cell.owner, count: cell.count))
                }
            }
        }
        
        var packet = P2PPacket(sequenceID: P2PNetworkManager.shared.getNextSequenceID(), action: .stateSnapshot, senderID: P2PNetworkManager.shared.myNickname)
        packet.playerNames = playerNames
        packet.playerTypes = playerTypes
        packet.compactBoardSnapshot = compactList
        packet.currentTurnIndex = currentPlayer
        packet.hasEnteredSnapshot = hasEntered
        packet.eliminatedSnapshot = eliminated
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
    
    // ✅ 隐患 1 修复：resetGame 只负责数据重置，不强制更改 isGameInPlay，且内部调用 checkAndRunAITurn 时受 isGameInPlay 守卫保护
    func resetGame(chosenFirstPlayer: Int? = nil) {
        currentGameSessionID = UUID()
        lastReceivedSeqID = 0
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
        recalculateOrbCounts()
        
        let active = activePlayerIndices
        guard !active.isEmpty else { return }
        
        if let chosen = chosenFirstPlayer, active.contains(chosen) {
            currentPlayer = chosen
        } else if isRandomFirstPlayer {
            currentPlayer = active.randomElement() ?? active[0]
        } else {
            currentPlayer = active[0]
        }
        
        if P2PNetworkManager.shared.isHost && P2PNetworkManager.shared.isConnected {
            var startPacket = P2PPacket(sequenceID: P2PNetworkManager.shared.getNextSequenceID(), action: .startGame, senderID: P2PNetworkManager.shared.myNickname)
            startPacket.firstPlayerIndex = currentPlayer
            P2PNetworkManager.shared.sendPacket(startPacket)
        }
        
        updateCachedPlayableCells()
        checkAndRunAITurn()
    }
    
    // ✅ 隐患 2 修复：为“重新开始本局”提供明确的方法，保证重置后重新标记 beginGame，再驱动 AI
    func restartCurrentGame() {
        resetGame()
        beginGame()
        checkAndRunAITurn()
    }
    
    func exitToMenu() {
        currentGameSessionID = UUID()
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
        P2PNetworkManager.shared.stopP2P()
    }
    
    func updatePlayerType(at index: Int, to newType: PlayerControlType, forceInternal: Bool = false) {
        guard index >= 0 && index < PlayerPreset.maxPlayers else { return }
        
        if !forceInternal {
            let valids = validSelectableTypes(forPlayerIndex: index, isInLobby: true)
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
    
    func play(row: Int, column: Int) {
        let flatIdx = row * boardSize + column
        guard !isProcessingCascade, winnerIndex == nil, playableCells.contains(flatIdx) else { return }
        
        let player = currentPlayer
        let isP2P = P2PNetworkManager.shared.isConnected
        
        if isP2P {
            let isMyTurnToControl = (playerTypes[player] == .human && myPlayerIndex == player) || (P2PNetworkManager.shared.isHost && playerTypes[player].isAI)
            guard isMyTurnToControl else { return }
            
            var packet = P2PPacket(sequenceID: P2PNetworkManager.shared.getNextSequenceID(), action: .playerMove, senderID: P2PNetworkManager.shared.myNickname)
            packet.row = row
            packet.col = column
            packet.playerIndex = player
            P2PNetworkManager.shared.sendPacket(packet)
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
            
            if checkGameOver() {
                endGame()
            } else {
                advanceToNextTurn()
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
        
        // ✅ 隐患 1 核心修复：只有真的在对局中（isGameInPlay == true）时，才允许启动 AI 唤起
        guard isGameInPlay else { return }
        
        if P2PNetworkManager.shared.isConnected && !P2PNetworkManager.shared.isHost {
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
                eliminated: eliminated
            )
            
            if let bestMove = await solver.calculateBestMove() {
                if !Task.isCancelled {
                    await MainActor.run {
                        if self.currentGameSessionID == sessionID && self.currentPlayer == targetPlayer && self.isGameInPlay {
                            self.play(row: bestMove.0, column: bestMove.1)
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

// MARK: - 8. 玩家进度 View

struct PlayerProgressOrbView: View {
    @ObservedObject var game: GameModel
    let playerIndex: Int
    let size: CGFloat = 46
    
    var isCurrentTurn: Bool {
        game.currentPlayer == playerIndex
    }
    
    var isEliminated: Bool {
        game.eliminated[safe: playerIndex] ?? false
    }
    
    var body: some View {
        let percent = game.playerOrbPercentage(for: playerIndex)
        let color = game.colors[safe: playerIndex] ?? .gray
        let emoji = game.emojis[safe: playerIndex] ?? nil
        let name = game.playerNames[safe: playerIndex] ?? "玩家"
        
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .fill(color.opacity(isEliminated ? 0.05 : 0.2))
                
                Circle()
                    .trim(from: 0, to: isEliminated ? 0 : CGFloat(percent))
                    .stroke(
                        color,
                        style: StrokeStyle(lineWidth: 3.5, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .padding(3)
                
                if let em = emoji, !em.isEmpty {
                    Text(em)
                        .font(.system(size: size * 0.42))
                        .opacity(isEliminated ? 0.3 : 1.0)
                } else {
                    Circle()
                        .fill(color.opacity(isEliminated ? 0.2 : 0.85))
                        .frame(width: size * 0.38, height: size * 0.38)
                }
            }
            .frame(width: size, height: size)
            .glassEffect(.regular.interactive(), in: .circle)
            .scaleEffect(isCurrentTurn ? 1.15 : 1.0)
            .shadow(color: isCurrentTurn ? color.opacity(0.8) : .clear, radius: 10, x: 0, y: 0)
            .animation(.spring(response: 0.25, dampingFraction: 0.65), value: isCurrentTurn)
            .animation(.easeInOut(duration: 0.3), value: percent)
            
            Text(name)
                .font(.system(size: 10, weight: isCurrentTurn ? .bold : .medium, design: .rounded))
                .foregroundColor(isCurrentTurn ? .white : .white.opacity(0.6))
                .lineLimit(1)
                .frame(width: size + 8)
        }
        .opacity(isEliminated ? 0.35 : 1.0)
    }
}

// MARK: - 9. 棋盘 View

struct BoardView: View {
    @ObservedObject var game: GameModel
    let onBoardDimensionCalculated: (CGFloat) -> Void
    
    private let gap: CGFloat = 3
    private let innerBorderPadding: CGFloat = 6
    
    var leftPlayers: [Int] {
        let active = game.activePlayerIndices
        let mid = (active.count + 1) / 2
        return Array(active.prefix(mid))
    }
    
    var rightPlayers: [Int] {
        let active = game.activePlayerIndices
        let mid = (active.count + 1) / 2
        return Array(active.suffix(from: mid))
    }
    
    var body: some View {
        GeometryReader { proxy in
            let orbWidth: CGFloat = 52
            let availableWidth = max(10, proxy.size.width - orbWidth * 2 - 16)
            let availableHeight = max(10, proxy.size.height - 24)
            let minDim = min(availableWidth, availableHeight)
            
            let side = (minDim - gap * CGFloat(game.boardSize - 1)) / CGFloat(game.boardSize)
            let actualBoardDimension = side * CGFloat(game.boardSize) + gap * CGFloat(game.boardSize - 1) + innerBorderPadding * 2
            
            HStack(spacing: 8) {
                VStack(spacing: 12) {
                    ForEach(leftPlayers, id: \.self) { pIdx in
                        PlayerProgressOrbView(game: game, playerIndex: pIdx)
                    }
                }
                .frame(width: orbWidth)
                
                ZStack(alignment: .topLeading) {
                    VStack(spacing: gap) {
                        ForEach(0..<game.boardSize, id: \.self) { r in
                            HStack(spacing: gap) {
                                ForEach(0..<game.boardSize, id: \.self) { c in
                                    let index = r * game.boardSize + c
                                    let cell = (r < game.board.count && c < game.board[r].count) ? game.board[r][c] : Cell(owner: nil, count: 0)
                                    
                                    CellView(
                                        cell: cell,
                                        color: cell.owner.flatMap { game.colors[safe: $0] },
                                        emoji: cell.owner.flatMap { game.emojis[safe: $0] ?? nil },
                                        active: game.emphasizedCells.contains(index)
                                    )
                                    .equatable()
                                    .frame(width: max(0, side), height: max(0, side))
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        if game.playableCells.contains(index) {
                                            game.play(row: r, column: c)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(innerBorderPadding)
                    
                    ForEach(game.flyingOrbs) { orb in
                        PieceView(
                            color: game.colors[safe: orb.player] ?? .gray,
                            emoji: game.emojis[safe: orb.player] ?? nil,
                            count: 1,
                            size: max(8, side * 0.40)
                        )
                        .position(
                            x: innerBorderPadding + side / 2 + CGFloat(orb.arrived ? orb.toColumn : orb.fromColumn) * (side + gap),
                            y: innerBorderPadding + side / 2 + CGFloat(orb.arrived ? orb.toRow : orb.fromRow) * (side + gap)
                        )
                        .zIndex(10)
                        .allowsHitTesting(false)
                    }
                }
                .glassEffect(.regular, in: .rect(cornerRadius: PlayerPreset.cardCornerRadius))
                .frame(width: actualBoardDimension, height: actualBoardDimension)
                
                VStack(spacing: 12) {
                    ForEach(rightPlayers, id: \.self) { pIdx in
                        PlayerProgressOrbView(game: game, playerIndex: pIdx)
                    }
                }
                .frame(width: orbWidth)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .onAppear { onBoardDimensionCalculated(actualBoardDimension) }
            .onChange(of: actualBoardDimension) { _, newDim in
                onBoardDimensionCalculated(newDim)
            }
        }
        .clipped()
    }
}

// MARK: - 10. 单元格 (Equatable)

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

// MARK: - 11. 棋子 View

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

// MARK: - 12. 棋子点阵 View

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
            ScrollView {
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
                    .padding(.horizontal)
                    
                    Divider().background(Color.white.opacity(0.2))
                    
                    HStack {
                        TextField("输入任意 Emoji", text: $customEmojiText)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 180)
                        
                        Button(action: {
                            let trimmed = customEmojiText.trimmingCharacters(in: .whitespacesAndNewlines)
                            if let firstEmojiChar = trimmed.first {
                                let fullEmojiStr = String(firstEmojiChar)
                                if game.tryUpdatePlayerEmoji(at: playerIndex, newEmoji: fullEmojiStr) {
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
                }
                .padding(.bottom, 20)
            }
            .navigationTitle("选择 \(game.playerNames[safe: playerIndex] ?? "玩家") 的棋子样式")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("取消") { dismiss() }
            }
        }
        .presentationBackground(.thinMaterial)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - 14. 单机设置 View

struct LocalGameSetupView: View {
    @ObservedObject var game: GameModel
    let onStartGame: () -> Void
    @State private var selectedPlayerForEmoji: IdentifiableInt? = nil
    
    var isPlayerCountValid: Bool {
        game.activePlayerIndices.count >= 2
    }
    
    @ViewBuilder
    private var playerRowsContent: some View {
        LazyVStack(spacing: 10) {
            ForEach(0..<min(game.playerNames.count, PlayerPreset.maxPlayers), id: \.self) { idx in
                HStack(spacing: 8) {
                    Button(action: { selectedPlayerForEmoji = IdentifiableInt(id: idx) }) {
                        ZStack {
                            Circle()
                                .fill(game.colors[safe: idx] ?? .gray)
                                .frame(width: 26, height: 26)
                            
                            if let em = game.emojis[safe: idx], let emoji = em, !emoji.isEmpty {
                                Text(emoji).font(.caption2)
                            }
                        }
                    }
                    
                    ColorPicker("", selection: Binding(
                        get: { game.colors[safe: idx] ?? .red },
                        set: { game.updatePlayerColor(at: idx, newColor: $0) }
                    ))
                    .labelsHidden()
                    
                    TextField("名称", text: Binding(
                        get: { game.playerNames[safe: idx] ?? "玩家\(idx+1)" },
                        set: { if idx < game.playerNames.count { game.playerNames[idx] = $0 } }
                    ))
                    .foregroundColor(.white)
                    .font(.subheadline)
                    .bold()
                    .textFieldStyle(.plain)
                    
                    Spacer(minLength: 4)
                    
                    Picker("Player Type", selection: Binding(
                        get: { game.playerTypes[safe: idx] ?? .disabled },
                        set: { game.updatePlayerType(at: idx, to: $0) }
                    )) {
                        ForEach(game.validSelectableTypes(forPlayerIndex: idx, isInLobby: false)) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(.white)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 2)
            }
        }
        .padding(.vertical, 10)
    }
    
    var body: some View {
        VStack(spacing: 14) {
            VStack(spacing: 10) {
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
            .padding(12)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: PlayerPreset.cardCornerRadius))
            
            VStack(spacing: 8) {
                HStack {
                    Text("🧠 AI 思考算力/深度:")
                        .font(.subheadline)
                        .bold()
                        .foregroundColor(.white)
                    Spacer()
                    Text(game.aiDifficultyLevel.title)
                        .font(.caption)
                        .bold()
                        .foregroundColor(.cyan)
                }
                
                Slider(
                    value: Binding<Double>(
                        get: { Double(game.aiDifficultyLevel.rawValue) },
                        set: { game.aiDifficultyLevel = AIDifficultyLevel(rawValue: Int($0)) ?? .balanced }
                    ),
                    in: 1...4,
                    step: 1
                )
                .tint(Color.darkNavyBlue)
                
                Text(game.aiDifficultyLevel.description)
                    .font(.caption2)
                    .foregroundColor(.gray)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: PlayerPreset.cardCornerRadius))
            
            ViewThatFits(in: .vertical) {
                playerRowsContent
                
                ScrollView(.vertical, showsIndicators: true) {
                    playerRowsContent
                }
                .frame(maxHeight: 200)
            }
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: PlayerPreset.cardCornerRadius))
            
            Button(action: onStartGame) {
                HStack {
                    Image(systemName: "play.fill")
                    Text("开始对决").font(.title3).bold()
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .contentShape(Capsule())
                .glassEffect(.regular.tint(.darkNavyBlue).interactive(), in: .capsule)
            }
            .buttonStyle(.plain)
            .opacity(isPlayerCountValid ? 1.0 : 0.4)
            .disabled(!isPlayerCountValid)
        }
        .sheet(item: $selectedPlayerForEmoji) { item in
            EmojiPickerSheet(game: game, playerIndex: item.id)
        }
    }
}

// MARK: - 15. 本地搜寻 Inline View

struct LocalDeviceBrowserInlineView: View {
    @ObservedObject var p2pManager = P2PNetworkManager.shared
    let onSelectDevice: (DiscoveredDevice) -> Void
    let onCancel: () -> Void
    
    var body: some View {
        VStack(spacing: 12) {
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
                    ScrollView(.vertical, showsIndicators: true) {
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
                                    .padding(10)
                                    .contentShape(Rectangle())
                                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: PlayerPreset.cardCornerRadius - 6))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(maxHeight: 180)
                }
            }
        }
        .padding()
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: PlayerPreset.cardCornerRadius))
    }
}

// MARK: - 16. 联机大厅 View

struct RoomLobbyView: View {
    @ObservedObject var game: GameModel
    @ObservedObject var p2pManager = P2PNetworkManager.shared
    let onExitLobby: () -> Void
    let onStartGame: () -> Void
    
    @State private var selectedPlayerForEmoji: IdentifiableInt? = nil
    
    @ViewBuilder
    private var roomPlayerRowsContent: some View {
        VStack(spacing: 8) {
            ForEach(0..<min(game.playerNames.count, 4), id: \.self) { idx in
                let isMySeat = (idx == game.myPlayerIndex)
                
                HStack {
                    Button(action: {
                        if isMySeat { selectedPlayerForEmoji = IdentifiableInt(id: idx) }
                    }) {
                        ZStack {
                            Circle()
                                .fill(game.colors[safe: idx] ?? .gray)
                                .frame(width: 26, height: 26)
                            
                            if let em = game.emojis[safe: idx], let emoji = em {
                                Text(emoji).font(.caption2)
                            }
                        }
                    }
                    .disabled(!isMySeat)
                    
                    if isMySeat {
                        ColorPicker("", selection: Binding(
                            get: { game.colors[safe: idx] ?? .red },
                            set: { game.updatePlayerColor(at: idx, newColor: $0) }
                        ))
                        .labelsHidden()
                    }
                    
                    Text((game.playerNames[safe: idx] ?? "玩家\(idx+1)") + (isMySeat ? " (我)" : ""))
                        .font(.subheadline)
                        .bold()
                        .foregroundColor(isMySeat ? .cyan : .white)
                    
                    Spacer()
                    
                    if p2pManager.isHost {
                        Picker("", selection: Binding(
                            get: { game.playerTypes[safe: idx] ?? .disabled },
                            set: { game.updatePlayerType(at: idx, to: $0) }
                        )) {
                            ForEach(game.validSelectableTypes(forPlayerIndex: idx, isInLobby: true)) { type in
                                Text(type.rawValue).tag(type)
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(.white)
                    } else {
                        Text((game.playerTypes[safe: idx] ?? .disabled).rawValue)
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                }
                .padding(8)
            }
        }
        .padding(6)
    }
    
    var body: some View {
        VStack(spacing: 12) {
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
            .padding(10)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: PlayerPreset.cardCornerRadius))
            
            if p2pManager.isHost {
                VStack(spacing: 8) {
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
                .padding(10)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: PlayerPreset.cardCornerRadius))
            } else {
                HStack {
                    Text("房主设定尺寸: \(game.boardSize) × \(game.boardSize)")
                    Spacer()
                    Text(game.isRandomFirstPlayer ? "随机先手" : "顺序先手")
                }
                .font(.caption)
                .bold()
                .foregroundColor(.cyan)
                .padding(10)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: PlayerPreset.cardCornerRadius))
            }
            
            ViewThatFits(in: .vertical) {
                roomPlayerRowsContent
                
                ScrollView(.vertical, showsIndicators: true) {
                    roomPlayerRowsContent
                }
                .frame(maxHeight: 180)
            }
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: PlayerPreset.cardCornerRadius))
            
            if p2pManager.isHost {
                Button(action: onStartGame) {
                    HStack {
                        Image(systemName: "play.fill")
                        Text("全员开始对决").bold()
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .contentShape(Capsule())
                    .glassEffect(.regular.tint(.darkNavyBlue).interactive(), in: .capsule)
                }
                .buttonStyle(.plain)
            } else {
                Text("等待房主 \(p2pManager.hostDeviceName) 启动对局...")
                    .font(.subheadline)
                    .foregroundColor(.cyan)
                    .padding(.vertical, 6)
            }
        }
        .sheet(item: $selectedPlayerForEmoji) { item in
            EmojiPickerSheet(game: game, playerIndex: item.id)
        }
    }
}

// MARK: - 17. 联机 Setup View

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
    
    @State private var showAlertError: Bool = false
    @State private var p2pConnectionSubscription: AnyCancellable? = nil
    
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("我的玩家昵称:")
                    .font(.subheadline)
                    .bold()
                    .foregroundColor(.white)
                
                TextField("输入昵称", text: $p2pManager.myNickname)
                    .textFieldStyle(.roundedBorder)
                    .disabled(p2pManager.isConnected || p2pManager.isConnecting)
                    .frame(maxWidth: 180)
            }
            .padding(10)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: PlayerPreset.cardCornerRadius))
            
            if game.activeOnlineMode == .localHost || game.activeOnlineMode == .localJoined {
                RoomLobbyView(
                    game: game,
                    onExitLobby: {
                        game.activeOnlineMode = .none
                        p2pConnectionSubscription?.cancel()
                        p2pConnectionSubscription = nil
                    },
                    onStartGame: onStartGame
                )
            } else {
                VStack(spacing: 12) {
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
                            game.activeOnlineMode = .localHost
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
                            game.activeOnlineMode = .localSearching
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
                    
                    if game.activeOnlineMode == .localSearching {
                        LocalDeviceBrowserInlineView(
                            onSelectDevice: { device in
                                p2pManager.connectToDevice(device)
                                p2pConnectionSubscription?.cancel()
                                p2pConnectionSubscription = p2pManager.$isConnected
                                    .filter { $0 }
                                    .first()
                                    .receive(on: DispatchQueue.main)
                                    .sink { _ in
                                        game.playerNames[1] = p2pManager.myNickname
                                        game.myPlayerIndex = 1
                                        game.activeOnlineMode = .localJoined
                                        let syncPacket = P2PPacket(sequenceID: p2pManager.getNextSequenceID(), action: .syncRequest, senderID: p2pManager.myNickname)
                                        p2pManager.sendPacket(syncPacket)
                                    }
                            },
                            onCancel: {
                                p2pManager.stopP2P()
                                p2pConnectionSubscription?.cancel()
                                p2pConnectionSubscription = nil
                                game.activeOnlineMode = .none
                            }
                        )
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .padding()
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: PlayerPreset.cardCornerRadius))
            }
        }
        .alert("连接失败", isPresented: $showAlertError) {
            Button("确定", role: .cancel) { }
        } message: {
            Text("房间不存在或网络连接超时！")
        }
    }
}

// MARK: - 18. 主菜单 View

struct StartMenuView: View {
    @ObservedObject var game: GameModel
    @Binding var isSpinningRandomWheel: Bool
    
    @State private var selectedTab: Int = 0
    @State private var showPhotoPicker: Bool = false
    @State private var selectedPhotosItem: PhotosPickerItem? = nil
    
    var body: some View {
        NavigationStack {
            ZStack {
                if let customImg = game.customBackgroundImage {
                    Image(uiImage: customImg)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                        .ignoresSafeArea()
                        .overlay(Color.black.opacity(0.35))
                } else {
                    LinearGradient(
                        colors: [
                            Color(red: 0.08, green: 0.28, blue: 0.65).opacity(0.85),
                            Color(red: 0.03, green: 0.05, blue: 0.10)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .ignoresSafeArea()
                }
                
                VStack(spacing: 0) {
                    Spacer()
                    
                    VStack(spacing: 16) {
                        Text("COLOR WAR")
                            .font(.system(size: 36, weight: .black, design: .rounded))
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
                    .frame(maxWidth: 440)
                    
                    Spacer()
                }
                .padding(.horizontal, 20)
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Game Mode", selection: $selectedTab) {
                        Text("单机模式").tag(0)
                        Text("P2P 联机").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                }
                
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showPhotoPicker = true
                        } label: {
                            Label("从相册选择背景", systemImage: "photo.on.rectangle")
                        }
                        
                        if game.customBackgroundImage != nil {
                            Button(role: .destructive) {
                                game.saveCustomBackground(nil)
                            } label: {
                                Label("清除自定义背景", systemImage: "trash")
                            }
                        }
                    } label: {
                        Image(systemName: "photo.badge.plus")
                            .foregroundColor(.white)
                            .font(.system(size: 16, weight: .medium))
                    }
                }
            }
            .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhotosItem, matching: .images)
            .onChange(of: selectedPhotosItem) { _, newItem in
                guard let newItem = newItem else { return }
                Task {
                    if let data = try? await newItem.loadTransferable(type: Data.self),
                       let uiImage = UIImage(data: data) {
                        await MainActor.run {
                            game.saveCustomBackground(uiImage)
                        }
                    }
                }
            }
            .onChange(of: selectedTab) { _, newTab in
                if newTab == 0 && !P2PNetworkManager.shared.isConnected {
                    P2PNetworkManager.shared.stopP2P()
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
        }
    }
}

// MARK: - 19. 轮盘 Overlay

struct RandomPlayerWheelOverlay: View {
    @ObservedObject var game: GameModel
    let activeIndices: [Int]
    let onFinished: (Int) -> Void
    
    @State private var highlightedPos: Int = 0
    
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
                    ForEach(activeIndices.indices, id: \.self) { pos in
                        let pIdx = activeIndices[pos]
                        let isHighlighted = (pos == highlightedPos)
                        
                        VStack(spacing: 6) {
                            ZStack {
                                Circle()
                                    .fill(game.colors[safe: pIdx] ?? .gray)
                                    .frame(width: 48, height: 48)
                                
                                if let em = game.emojis[safe: pIdx], let emoji = em, !emoji.isEmpty {
                                    Text(emoji).font(.title2)
                                }
                            }
                            .scaleEffect(isHighlighted ? 1.25 : 0.95)
                            
                            Text(game.playerNames[safe: pIdx] ?? "玩家")
                                .font(.caption2)
                                .bold()
                                .foregroundColor(isHighlighted ? .white : .gray)
                        }
                        .animation(.spring(response: 0.12, dampingFraction: 0.6), value: isHighlighted)
                    }
                }
                .padding(.horizontal)
            }
            .padding(28)
            .glassEffect(.regular, in: .rect(cornerRadius: PlayerPreset.cardCornerRadius))
            .frame(maxWidth: 380)
            .padding(.horizontal, 20)
        }
        .onAppear {
            startSmoothWheelDeceleration()
        }
    }
    
    private func startSmoothWheelDeceleration() {
        let count = activeIndices.count
        guard count > 0, let targetWinner = activeIndices.randomElement(),
              let targetPos = activeIndices.firstIndex(of: targetWinner) else {
            onFinished(0)
            return
        }
        
        let rounds = 3
        let totalSteps = rounds * count + targetPos
        
        Task {
            var currentStep = 0
            var delayMs: UInt64 = 30_000_000
            
            while currentStep < totalSteps {
                try? await Task.sleep(nanoseconds: delayMs)
                currentStep += 1
                highlightedPos = currentStep % count
                
                if currentStep % 2 == 0 {
                    Haptics.shared.lightImpact()
                }
                
                let progress = Double(currentStep) / Double(totalSteps)
                if progress > 0.6 {
                    let nextDelay = Double(delayMs) * 1.25
                    delayMs = UInt64(min(nextDelay, 250_000_000))
                }
            }
            
            try? await Task.sleep(nanoseconds: 200_000_000)
            onFinished(targetWinner)
        }
    }
}

// MARK: - 20. 游戏对局 View

struct GamePlayView: View {
    @ObservedObject var game: GameModel
    @Binding var isGameStarted: Bool
    @Binding var isSpinningRandomWheel: Bool
    
    @State private var calculatedBoardWidth: CGFloat = 320
    
    var body: some View {
        ZStack {
            if let customImg = game.customBackgroundImage {
                Image(uiImage: customImg)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                    .ignoresSafeArea()
                    .overlay(Color.black.opacity(0.35))
            } else {
                LinearGradient(
                    colors: [
                        (game.colors[safe: game.currentPlayer] ?? .blue).opacity(0.35),
                        Color(red: 0.03, green: 0.05, blue: 0.10)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.8), value: game.currentPlayer)
            }
            
            VStack(spacing: 8) {
                HStack {
                    Button(action: {
                        game.exitToMenu()
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            isGameStarted = false
                        }
                    }) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 34, height: 34)
                            .contentShape(Circle())
                            .glassEffect(.regular.interactive(), in: .circle)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("返回菜单")
                    
                    Spacer()
                    
                    HStack(spacing: 8) {
                        ZStack {
                            Circle()
                                .fill(game.colors[safe: game.currentPlayer] ?? .blue)
                                .frame(width: 12, height: 12)
                            
                            if let em = game.emojis[safe: game.currentPlayer], let emoji = em, !emoji.isEmpty {
                                Text(emoji).font(.caption2)
                            }
                        }
                        
                        Text("\(game.playerNames[safe: game.currentPlayer] ?? "玩家") 回合")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .glassEffect(.regular, in: Capsule())
                    
                    Spacer()
                    
                    Button(action: { game.showControlSheet = true }) {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 34, height: 34)
                            .contentShape(Circle())
                            .glassEffect(.regular.interactive(), in: .circle)
                    }
                    .buttonStyle(.plain)
                }
                .frame(width: calculatedBoardWidth)
                .padding(.top, 10)
                
                Spacer(minLength: 4)
                
                BoardView(game: game) { actualWidth in
                    self.calculatedBoardWidth = actualWidth
                }
                .padding(.horizontal, 8)
                
                Spacer(minLength: 8)
            }
            
            if let wIdx = game.winnerIndex {
                Color.black.opacity(0.8).ignoresSafeArea()
                
                VStack(spacing: 24) {
                    ZStack {
                        Circle()
                            .fill((game.colors[safe: wIdx] ?? .yellow).opacity(0.3))
                            .frame(width: 90, height: 90)
                        
                        Circle()
                            .stroke(game.colors[safe: wIdx] ?? .yellow, lineWidth: 3)
                            .frame(width: 80, height: 80)
                        
                        if let em = game.emojis[safe: wIdx], let emoji = em, !emoji.isEmpty {
                            Text(emoji).font(.system(size: 42))
                        } else {
                            Image(systemName: "crown.fill")
                                .font(.system(size: 38))
                                .foregroundColor(.yellow)
                        }
                    }
                    
                    Text("\(game.playerNames[safe: wIdx] ?? "玩家") 获得胜利！")
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
                .glassEffect(.regular, in: .rect(cornerRadius: PlayerPreset.cardCornerRadius))
                .frame(maxWidth: 420)
                .padding(.horizontal, 20)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .sheet(isPresented: $game.showControlSheet) {
            PlayerTakeoverSheet(game: game)
        }
        .alert("连接断开", isPresented: $game.showDisconnectedAlert) {
            Button("确定", role: .cancel) {
                withAnimation(.spring()) { isGameStarted = false }
            }
        } message: {
            Text("房主已断开连接，对局已自动结束。")
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
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
                        // ✅ 隐患 2 修复：使用 restartCurrentGame 显式保证 isGameInPlay = true 并唤起 AI
                        game.restartCurrentGame()
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
                
                Section(header: Text("AI 思考算力/档位调整")) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(game.aiDifficultyLevel.title)
                                .font(.subheadline)
                                .bold()
                            Spacer()
                        }
                        
                        Slider(
                            value: Binding<Double>(
                                get: { Double(game.aiDifficultyLevel.rawValue) },
                                set: { game.aiDifficultyLevel = AIDifficultyLevel(rawValue: Int($0)) ?? .balanced }
                            ),
                            in: 1...4,
                            step: 1
                        )
                        .tint(Color.darkNavyBlue)
                        
                        Text(game.aiDifficultyLevel.description)
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                    .padding(.vertical, 4)
                }
                
                Section(header: Text("实时接管控制（AI / P2P 代打）")) {
                    ForEach(game.activePlayerIndices, id: \.self) { idx in
                        HStack {
                            Circle().fill(game.colors[safe: idx] ?? .gray).frame(width: 16, height: 16)
                            Text(game.playerNames[safe: idx] ?? "玩家\(idx+1)").font(.body)
                            Spacer()
                            
                            Picker("", selection: Binding(
                                get: { game.playerTypes[safe: idx] ?? .disabled },
                                set: { game.updatePlayerType(at: idx, to: $0) }
                            )) {
                                ForEach(game.validSelectableTypes(forPlayerIndex: idx, isInLobby: false)) { type in
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
            Color(red: 0.03, green: 0.05, blue: 0.10)
                .ignoresSafeArea()
            
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
                        game.beginGame()
                        isSpinningRandomWheel = false
                        withAnimation(.spring()) {
                            isGameStarted = true
                        }
                    }
                )
            }
        }
        // ✅ 隐患 3 修复：监听到 P2P 客户端收到 startGame 信号时，联动切换 UI 状态至 GamePlayView
        .onChange(of: game.shouldNavigateToGame) { _, shouldNav in
            if shouldNav {
                withAnimation(.spring()) {
                    isGameStarted = true
                }
            }
        }
    }
}
