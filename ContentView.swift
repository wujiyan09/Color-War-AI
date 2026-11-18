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
    case driveBot = "drive-bot"
    case p2pNetwork = "网络玩家"
    case disabled = "未加入"
    
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .human: return "真人"
        case .mathNightmare: return "Bot 1"
        case .enhancedNightmare: return "Bot 2"
        case .driveBot: return "Bot 3"
        case .p2pNetwork: return "网络玩家"
        case .disabled: return "未加入"
        }
    }
    
    var isAI: Bool {
        self == .mathNightmare || self == .enhancedNightmare || self == .driveBot
    }
    
    var isEnabled: Bool {
        self != .disabled
    }
}

struct PlayerPreset: Codable, Identifiable {
    var id: Int
    var name: String
    var hexColor: String
    var emoji: String?
    var controller: PlayerControlType
    var isEliminated: Bool = false
    var hasEntered: Bool = false
    
    var color: Color {
        Color(hex: hexColor)
    }
    
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

struct GameSaveArchive: Codable, Identifiable {
    let id: UUID
    let date: Date
    let boardSize: Int
    let currentPlayer: Int
    let playerNames: [String]
    let playerTypes: [PlayerControlType]
    let colorsHex: [String]
    let emojis: [String?]
    let board: [[Cell]]
    let hasEntered: [Bool]
    let eliminated: [Bool]
    let localDuelMoveCount: Int?
    
    var displaySummary: String {
        let activeCount = playerTypes.filter { $0.isEnabled }.count
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd HH:mm"
        return "\(boardSize)×\(boardSize) 网格 | \(activeCount)人对局 | \(formatter.string(from: date))"
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

// MARK: - 3. 局域网 P2P 网络管理器 (MultipeerConnectivity)

enum P2PAction: String, Codable {
    case hostConfig
    case playerMove
    case syncRequest
    case startGame
    case stateSnapshot
    case playerLeft
    case ping
    case ack
    case joinRoom
    case leaveRoom
    case renamePlayer
    case roomJoined
    case roomRoster
    case roomError
    case roomClosed
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
    var emojis: [String?]? = nil
    var aiLevelRaw: Int? = nil
    var compactBoardSnapshot: [CompactCellSnapshot]? = nil
    var currentTurnIndex: Int? = nil
    var hasEnteredSnapshot: [Bool]? = nil
    var eliminatedSnapshot: [Bool]? = nil
    var roomCode: String? = nil
    var isHost: Bool? = nil
    var message: String? = nil
    var nickname: String? = nil

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
            if !isConnected && !isConnecting && !WebSocketNetworkManager.shared.isConnected {
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
        rebuildPeerID()
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
        rebuildPeerID()
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

// MARK: - 4. 远程 WebSocket 公网中继网络管理器

final class WebSocketNetworkManager: ObservableObject {
    static let shared = WebSocketNetworkManager()
    static let defaultServerURL = "https://colorwar-server.wujiyan2009.workers.dev"

    let packetSubject = PassthroughSubject<P2PPacket, Never>()

    @Published var isConnected = false
    @Published var isConnecting = false
    @Published var currentRoomCode = ""
    @Published var isHost = false
    @Published var playerIndex = 0
    @Published var lastError: String?

    private var webSocketTask: URLSessionWebSocketTask?
    private var sequenceCounter: UInt64 = 0

    private init() {}

    @MainActor
    func getNextSequenceID() -> UInt64 {
        sequenceCounter += 1
        return sequenceCounter
    }

    @MainActor
    func connectAndJoinRoom(roomCode: String, isHost: Bool, nickname: String) {
        disconnect()
        self.isHost = isHost
        self.currentRoomCode = roomCode
        self.isConnecting = true
        self.lastError = nil
        sequenceCounter = 0

        let serverURL = Self.defaultServerURL
        guard var components = URLComponents(string: serverURL),
              let scheme = components.scheme?.lowercased(),
              ["https", "http", "wss", "ws"].contains(scheme),
              components.host != nil else {
            self.isConnecting = false
            self.lastError = "请先填写已部署的 WebSocket 服务地址。"
            return
        }
        if components.scheme == "https" { components.scheme = "wss" }
        if components.scheme == "http" { components.scheme = "ws" }
        components.path = "/ws/\(roomCode)"
        components.queryItems = [
            URLQueryItem(name: "role", value: isHost ? "host" : "player"),
            URLQueryItem(name: "nickname", value: nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "玩家" : nickname)
        ]
        guard let url = components.url else {
            self.isConnecting = false
            self.lastError = "服务地址无效。"
            return
        }

        let task = URLSession(configuration: .default).webSocketTask(with: url)
        webSocketTask = task
        task.resume()
        listenForMessages(task)

    }

    @MainActor
    func disconnect() {
        if let task = webSocketTask, isConnected {
            var leave = P2PPacket(sequenceID: getNextSequenceID(), action: .leaveRoom, senderID: "")
            leave.roomCode = currentRoomCode
            if let data = try? JSONEncoder().encode(leave), let text = String(data: data, encoding: .utf8) {
                task.send(.string(text)) { _ in }
            }
        }
        let task = webSocketTask
        webSocketTask = nil
        task?.cancel(with: .normalClosure, reason: nil)
        isConnected = false
        isConnecting = false
        currentRoomCode = ""
        playerIndex = 0
    }

    func sendPacket(_ packet: P2PPacket) {
        guard let task = webSocketTask,
              let data = try? JSONEncoder().encode(packet),
              let jsonString = String(data: data, encoding: .utf8) else { return }
        task.send(.string(jsonString)) { [weak self] error in
            guard let self, let error else { return }
            DispatchQueue.main.async {
                self.handleSocketFailure(error, task: task)
            }
        }
    }

    private func listenForMessages(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self, weak task] result in
            guard let self, let task else { return }
            switch result {
            case .success(let message):
                if case .string(let text) = message,
                   let data = text.data(using: .utf8),
                   let packet = try? JSONDecoder().decode(P2PPacket.self, from: data) {
                    DispatchQueue.main.async {
                        switch packet.action {
                        case .roomJoined:
                            self.isConnected = true
                            self.isConnecting = false
                            self.isHost = packet.isHost ?? self.isHost
                            self.playerIndex = packet.playerIndex ?? self.playerIndex
                            self.currentRoomCode = packet.roomCode ?? self.currentRoomCode
                            self.lastError = nil
                        case .roomError:
                            self.isConnected = false
                            self.isConnecting = false
                            self.lastError = packet.message ?? "无法加入房间。"
                        case .roomClosed:
                            self.isConnected = false
                            self.isConnecting = false
                            self.lastError = packet.message ?? "房主已离开房间。"
                        default: break
                        }
                        self.packetSubject.send(packet)
                    }
                }
                self.listenForMessages(task)
            case .failure(let error):
                DispatchQueue.main.async {
                    self.handleSocketFailure(error, task: task)
                }
            }
        }
    }

    private func handleSocketFailure(_ error: Error, task: URLSessionWebSocketTask) {
        guard webSocketTask === task else { return }
        let wasConnected = isConnected
        let wasGuest = !isHost
        isConnected = false
        isConnecting = false
        if wasConnected && wasGuest {
            lastError = "远程房间连接中断，对局已结束。"
            var closed = P2PPacket(sequenceID: 0, action: .roomClosed, senderID: "server")
            closed.message = lastError
            packetSubject.send(closed)
        } else {
            lastError = "WebSocket 连接中断：\(error.localizedDescription)"
        }
    }
}

// MARK: - 5. Color 扩展

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

// MARK: - 9. 玩家进度 View

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

// MARK: - 10. 棋盘 View

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
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: PlayerPreset.cardCornerRadius))
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

// MARK: - 11. 单元格 (Equatable)

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

// MARK: - 12. 棋子 View

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

// MARK: - 13. 棋子点阵 View

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

// MARK: - 14. Emoji 选择器 Sheet

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

// MARK: - 15. Tab 0: 单机设置 View

struct LocalGameSetupView: View {
    @ObservedObject var game: GameModel
    let onStartGame: () -> Void
    @State private var selectedPlayerForEmoji: IdentifiableInt? = nil
    
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
                        get: { game.localPlayerNames[safe: idx] ?? "玩家\(idx+1)" },
                        set: { game.updateLocalPlayerName(at: idx, to: $0) }
                    ))
                    .foregroundColor(.white)
                    .font(.subheadline)
                    .bold()
                    .textFieldStyle(.plain)
                    
                    Spacer(minLength: 4)
                    
                    if game.isOnlineMultiplayer {
                        Text(game.playerTypes[safe: idx]?.displayName ?? "未加入")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.65))
                    } else {
                        Picker("控制类型", selection: Binding(
                            get: { game.playerTypes[safe: idx] ?? .disabled },
                            set: { game.updatePlayerType(at: idx, to: $0) }
                        )) {
                            ForEach(game.validSelectableTypes(forPlayerIndex: idx, isInLobby: false)) { type in
                                Text(type.displayName).tag(type)
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(.cyan)
                    }
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
            
            // Keep the player rows in one stable view hierarchy. ViewThatFits previously
            // replaced this subtree with a second copy when the keyboard reduced the
            // available height, which detached the focused TextField and dismissed the
            // keyboard on both iPhone and iPad.
            ScrollView(.vertical, showsIndicators: true) {
                playerRowsContent
            }
            .frame(maxHeight: 220)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: PlayerPreset.cardCornerRadius))
            
            Button(action: {
                guard game.canStartGame else { return }
                onStartGame()
            }) {
                HStack {
                    Image(systemName: "play.fill")
                    Text("开始对决 (\(game.validPlayerCount) 人)").font(.title3).bold()
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .contentShape(Capsule())
                .glassEffect(.regular.tint(game.canStartGame ? .darkNavyBlue : .gray).interactive(), in: .capsule)
            }
            .buttonStyle(.plain)
            .opacity(game.canStartGame ? 1.0 : 0.4)
        }
        .sheet(item: $selectedPlayerForEmoji) { item in
            EmojiPickerSheet(game: game, playerIndex: item.id)
        }
    }
}


struct DualPlayerSetupView: View {
    @ObservedObject var game: GameModel
    @Binding var boardSize: Int
    @Binding var playerOneType: PlayerControlType
    @Binding var playerTwoType: PlayerControlType
    let onStartGame: () -> Void

    private let supportedBoardSizes = [6, 9, 12]

    private func nearestSupportedBoardSize(to size: Int) -> Int {
        supportedBoardSizes.min { abs($0 - size) < abs($1 - size) } ?? 6
    }

    private let selectableBotTypes: [PlayerControlType] = [.human, .mathNightmare, .enhancedNightmare, .driveBot]

    private func playerCard(title: String, type: Binding<PlayerControlType>, color: Color, icon: String) -> some View {
        Button {
            Haptics.shared.lightImpact()
            withAnimation(.spring(response: 0.32, dampingFraction: 0.72)) {
                let current = selectableBotTypes.firstIndex(of: type.wrappedValue) ?? 0
                type.wrappedValue = selectableBotTypes[(current + 1) % selectableBotTypes.count]
            }
        } label: {
            VStack(spacing: 10) {
                Image(systemName: type.wrappedValue.isAI ? "cpu" : icon)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(color)
                Text(title)
                    .font(.headline.bold())
                    .foregroundStyle(.white)
                Text(type.wrappedValue.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.86))
                Text("重复点按切换")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.62))
            }
            .frame(maxWidth: .infinity, minHeight: 150)
            .contentShape(RoundedRectangle(cornerRadius: PlayerPreset.cardCornerRadius))
            .glassEffect(.regular.interactive().tint(color.opacity(0.18)), in: .rect(cornerRadius: PlayerPreset.cardCornerRadius))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title)，\(type.wrappedValue.displayName)，重复点按切换")
    }

    var body: some View {
        VStack(spacing: 14) {
            VStack(spacing: 10) {
                HStack {
                    Text("棋盘大小：\(boardSize) × \(boardSize)")
                        .font(.subheadline.bold())
                        .foregroundColor(.white)
                    Spacer()
                }
                Slider(
                    value: Binding<Double>(
                        get: { Double(nearestSupportedBoardSize(to: boardSize)) },
                        set: { boardSize = nearestSupportedBoardSize(to: Int($0)) }
                    ),
                    in: 6...12,
                    step: 3
                )
                .tint(Color.darkNavyBlue)
            }
            .padding(12)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: PlayerPreset.cardCornerRadius))

            HStack(spacing: 12) {
                playerCard(title: "玩家 1", type: $playerOneType, color: .red, icon: "person.fill")
                playerCard(title: "玩家 2", type: $playerTwoType, color: .cyan, icon: "person.fill")
            }

            Button(action: onStartGame) {
                HStack {
                    Image(systemName: "play.fill")
                    Text("开始对决").font(.title3.bold())
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .contentShape(Capsule())
                .glassEffect(.regular.tint(.darkNavyBlue).interactive(), in: .capsule)
            }
            .buttonStyle(.plain)
        }
        .onAppear {
            let supportedSize = nearestSupportedBoardSize(to: boardSize)
            if boardSize != supportedSize { boardSize = supportedSize }
        }
    }
}

// MARK: - 16. Tab 1: 局域网 P2P Setup View

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

// MARK: - 17. Tab 2: 远程 WebSocket Setup View

struct RemoteWebSocketSetupView: View {
    @ObservedObject var game: GameModel
    @ObservedObject var wsManager = WebSocketNetworkManager.shared
    @ObservedObject var p2pManager = P2PNetworkManager.shared
    let onStartGame: () -> Void

    @State private var inputRoomCode: String = ""

    var body: some View {
        VStack(spacing: 12) {
            if !wsManager.isConnected {
                HStack(spacing: 8) {
                    Text("我的玩家昵称:")
                        .font(.subheadline)
                        .bold()
                        .foregroundColor(.white)
                    TextField("输入昵称", text: $p2pManager.myNickname)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .frame(maxWidth: 180)
                        .submitLabel(.done)
                        .onSubmit { game.renameMyPlayer(to: p2pManager.myNickname) }
                    Button("更新昵称") {
                        game.renameMyPlayer(to: p2pManager.myNickname)
                    }
                    .disabled(p2pManager.myNickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(10)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: PlayerPreset.cardCornerRadius))
            }

            if wsManager.isConnected {
                VStack(spacing: 12) {
                    HStack {
                        Text("房间邀请码: \(wsManager.currentRoomCode)")
                            .font(.title3.bold())
                            .foregroundColor(.cyan)
                        Spacer()
                    }
                    .padding(10)
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: PlayerPreset.cardCornerRadius))

                    RoomLobbyView(game: game, onExitLobby: {
                        wsManager.disconnect()
                        game.activeOnlineMode = .none
                    }, onStartGame: onStartGame)
                }
            } else {
                VStack(spacing: 14) {
                    if wsManager.isConnecting {
                        ProgressView("正在连接房间…").tint(.cyan)
                    }
                    if let error = wsManager.lastError {
                        Text(error).font(.caption).foregroundColor(.orange)
                    }
                    Text("🌍 远程 WebSocket 房间")
                        .font(.headline)
                        .foregroundColor(.white)

                    Button(action: {
                        let randomCode = String(Int.random(in: 100000...999999))
                        inputRoomCode = randomCode
                        game.prepareLobbyForHosting()
                        game.playerTypes[1] = .p2pNetwork
                        game.activeOnlineMode = .remoteWS
                        wsManager.connectAndJoinRoom(roomCode: randomCode, isHost: true, nickname: P2PNetworkManager.shared.myNickname)
                    }) {
                        Text("创建联机房间 (担任房主)")
                            .bold()
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .contentShape(Capsule())
                            .glassEffect(.regular.tint(.darkNavyBlue).interactive(), in: .capsule)
                    }
                    .buttonStyle(.plain)

                    HStack(spacing: 8) {
                        TextField("输入6位房间邀请码", text: Binding(
                            get: { inputRoomCode },
                            set: { inputRoomCode = String($0.filter { $0 >= "0" && $0 <= "9" }.prefix(6)) }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.center)
                        .textContentType(.oneTimeCode)

                        Button(action: {
                            game.activeOnlineMode = .remoteWS
                            wsManager.connectAndJoinRoom(roomCode: inputRoomCode, isHost: false, nickname: P2PNetworkManager.shared.myNickname)
                        }) {
                            Text("加入房间")
                                .bold()
                                .foregroundColor(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                                .contentShape(Capsule())
                                .glassEffect(.regular.interactive(), in: .capsule)
                        }
                        .buttonStyle(.plain)
                        .disabled(inputRoomCode.count != 6)
                        .opacity(inputRoomCode.count == 6 ? 1.0 : 0.5)
                    }
                }
                .padding()
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: PlayerPreset.cardCornerRadius))
            }
        }
    }
}

// MARK: - 18. 动态房间大厅 (Lobby) View (纯净席位，支持左划删除)

struct RoomLobbyView: View {
    @ObservedObject var game: GameModel
    @ObservedObject var p2pManager = P2PNetworkManager.shared
    @ObservedObject var wsManager = WebSocketNetworkManager.shared
    
    let onExitLobby: () -> Void
    let onStartGame: () -> Void
    
    @State private var selectedPlayerForEmoji: IdentifiableInt? = nil
    
    var isHost: Bool {
        p2pManager.isHost || wsManager.isHost
    }

    
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(isHost ? "🏠 房主房间大厅" : "🔗 已连入房间大厅")
                    .font(.headline)
                    .foregroundColor(.white)
                Spacer()
                Button(game.activeOnlineMode == .remoteWS ? "退出房间" : "解散/离开", action: onExitLobby)
                    .font(.subheadline)
                    .foregroundColor(.red)
            }
            .padding(10)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: PlayerPreset.cardCornerRadius))

            HStack(spacing: 8) {
                TextField("我的玩家昵称", text: $p2pManager.myNickname)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.done)
                    .onSubmit { game.renameMyPlayer(to: p2pManager.myNickname) }
                Button("更新昵称") {
                    game.renameMyPlayer(to: p2pManager.myNickname)
                }
                .disabled(p2pManager.myNickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 10)

            if !isHost {
                Text("房间棋盘：\(game.boardSize) × \(game.boardSize)")
                    .font(.caption.bold())
                    .foregroundColor(.cyan)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
            }

            if isHost {
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
                            set: { value in
                                let selectedSize = Int(value.rounded())
                                guard (5...12).contains(selectedSize), selectedSize != game.boardSize else { return }
                                game.boardSize = selectedSize
                            }
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
            }
            
            VStack(spacing: 8) {
                HStack {
                    Text(game.activeOnlineMode == .remoteWS ? "📋 房间席位配置" : "当前房间成员列表 (\(game.validPlayerCount) 人)")
                        .font(.caption)
                        .bold()
                        .foregroundColor(.white.opacity(0.8))
                    Spacer()
                }
                
                // Swift Native List 实现精美左划删除 (Swipe to Delete)
                List {
                    ForEach(0..<PlayerPreset.maxPlayers, id: \.self) { idx in
                        if game.playerTypes[idx].isEnabled {
                            let isMySeat = (idx == game.myPlayerIndex)
                            HStack {
                                Button(action: {
                                    if isMySeat { selectedPlayerForEmoji = IdentifiableInt(id: idx) }
                                }) {
                                    ZStack {
                                        Circle()
                                            .fill(game.colors[safe: idx] ?? .gray)
                                            .frame(width: 24, height: 24)
                                        
                                        if let em = game.emojis[safe: idx], let emoji = em {
                                            Text(emoji).font(.caption2)
                                        }
                                    }
                                }
                                .disabled(!isMySeat)
                                
                                Text((game.playerNames[safe: idx] ?? "玩家\(idx+1)") + (isMySeat ? " (我)" : ""))
                                    .font(.subheadline)
                                    .bold()
                                    .foregroundColor(isMySeat ? .cyan : .white)
                                
                                Spacer()
                                
                                let selectableTypes = game.validSelectableTypes(forPlayerIndex: idx, isInLobby: true)
                                if isHost && !game.isOnlineMultiplayer && selectableTypes.count > 1 {
                                    Picker("角色", selection: Binding(
                                        get: { game.playerTypes[idx] },
                                        set: { game.updatePlayerType(at: idx, to: $0) }
                                    )) {
                                        ForEach(selectableTypes) { type in
                                            Text(type.displayName).tag(type)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .tint(.cyan)
                                    .frame(maxWidth: 170, alignment: .trailing)
                                } else {
                                    Text(game.playerTypes[idx].displayName)
                                        .font(.caption)
                                        .foregroundColor(.white.opacity(0.6))
                                }
                            }
                            .listRowBackground(Color.white.opacity(0.06))
                        }
                    }
                    .onDelete { indexSet in
                        guard isHost, !game.isOnlineMultiplayer else { return }
                        for idx in indexSet {
                            if idx != game.myPlayerIndex {
                                game.updatePlayerType(at: idx, to: .disabled)
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .frame(height: min(CGFloat(game.validPlayerCount) * 44 + 10, 220))
                .cornerRadius(PlayerPreset.cardCornerRadius - 4)
            }
            .padding(8)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: PlayerPreset.cardCornerRadius))
            
            if isHost {
                if !game.isOnlineMultiplayer || (game.activeOnlineMode == .remoteWS && wsManager.isHost) {
                    Menu {
                        ForEach([PlayerControlType.mathNightmare, .enhancedNightmare]) { type in
                            Button(type.displayName) {
                                Haptics.shared.lightImpact()
                                if game.isOnlineMultiplayer {
                                    _ = game.addAIToRemoteLobby(type: type)
                                } else if let seat = game.playerTypes.firstIndex(of: .disabled) {
                                    game.playerNames[seat] = "\(type.displayName) \(seat + 1)"
                                    game.updatePlayerType(at: seat, to: type)
                                }
                            }
                        }
                    } label: {
                        Label("添加 Bot", systemImage: "plus.circle.fill")
                            .font(.subheadline.bold())
                            .foregroundColor(.cyan)
                    }
                    .disabled(game.playerTypes.allSatisfy { $0 != .disabled } || game.isGameInPlay)
                    .opacity(game.playerTypes.allSatisfy { $0 != .disabled } || game.isGameInPlay ? 0.45 : 1.0)
                }
                
                Button(action: {
                    guard game.canStartGame else { return }
                    onStartGame()
                }) {
                    HStack {
                        Image(systemName: "play.fill")
                        Text(game.activeOnlineMode == .remoteWS ? "全员开始对决" : "全员开始对决 (\(game.validPlayerCount) 人)").bold()
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .contentShape(Capsule())
                    .glassEffect(.regular.tint(game.canStartGame ? .darkNavyBlue : .gray).interactive(), in: .capsule)
                }
                .buttonStyle(.plain)
                .opacity(game.canStartGame ? 1.0 : 0.4)
            } else {
                Text("等待房主启动对局...")
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

// MARK: - 19. 联机综合 Setup View

enum ActiveOnlineMode {
    case none
    case localHost
    case localSearching
    case localJoined
    case remoteWS
}

struct OnlineGameSetupView: View {
    @ObservedObject var game: GameModel
    @ObservedObject var p2pManager = P2PNetworkManager.shared
    let onStartGame: () -> Void
    
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
                    .disabled(p2pManager.isConnecting)
                    .submitLabel(.done)
                    .onSubmit { game.renameMyPlayer(to: p2pManager.myNickname) }
                    .frame(maxWidth: 180)
                Button("更新昵称") { game.renameMyPlayer(to: p2pManager.myNickname) }
                    .disabled(p2pManager.isConnecting || p2pManager.myNickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(10)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: PlayerPreset.cardCornerRadius))
            
            if game.activeOnlineMode == .localHost || game.activeOnlineMode == .localJoined {
                RoomLobbyView(
                    game: game,
                    onExitLobby: {
                        game.activeOnlineMode = .none
                        p2pManager.stopP2P()
                        p2pConnectionSubscription?.cancel()
                        p2pConnectionSubscription = nil
                    },
                    onStartGame: onStartGame
                )
            } else {
                VStack(spacing: 12) {
                    HStack {
                        Text("🌐 本地局域网 P2P 联机")
                            .font(.headline)
                            .foregroundColor(.white)
                        Spacer()
                    }
                    
                    HStack(spacing: 12) {
                        Button(action: {
                            p2pManager.startLocalHosting()
                            game.prepareLobbyForHosting()
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
                    }
                }
                .padding()
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: PlayerPreset.cardCornerRadius))
            }
        }
    }
}

// MARK: - 20. 主菜单与原生标签栏

private enum AnalyzerBrush: Equatable {
    case piece(owner: Int, count: Int)
    case eraser
}

private struct AnalyzerSetupView: View {
    @Binding var boardSize: Int
    @Binding var selfColor: Int
    let onStart: () -> Void

    private let supportedSizes = [6, 9, 12]

    var body: some View {
        VStack(spacing: 14) {
            VStack(spacing: 10) {
                HStack {
                    Text("棋盘大小：\(boardSize) × \(boardSize)")
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                    Spacer()
                }
                Slider(value: Binding(
                    get: { Double(boardSize) },
                    set: { value in
                        boardSize = supportedSizes.min(by: { abs($0 - Int(value)) < abs($1 - Int(value)) }) ?? 6
                    }
                ), in: 6...12, step: 3)
                .tint(.darkNavyBlue)
            }
            .padding(12)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: PlayerPreset.cardCornerRadius))

            VStack(alignment: .leading, spacing: 10) {
                Text("我方棋子")
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                Picker("我方颜色", selection: $selfColor) {
                    Text("红色").tag(0)
                    Text("蓝色").tag(1)
                }
                .pickerStyle(.segmented)
                .tint(selfColor == 0 ? .red : .blue)
            }
            .padding(12)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: PlayerPreset.cardCornerRadius))

            Button {
                Haptics.shared.lightImpact()
                onStart()
            } label: {
                Label("进入分析器", systemImage: "sparkle.magnifyingglass")
                    .font(.title3.bold())
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .contentShape(Capsule())
                    .glassEffect(.regular.tint(.darkNavyBlue).interactive(), in: .capsule)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: 440)
        .padding(.horizontal, 20)
    }
}

private struct AnalyzerBoardView: View {
    let boardSize: Int
    let board: [[Cell]]
    let highlightedCell: Int?
    let maxSide: CGFloat
    let onTap: (Int, Int) -> Void

    private let gap: CGFloat = 3
    private let border: CGFloat = 6

    var body: some View {
        let side = max(10, (maxSide - border * 2 - gap * CGFloat(boardSize - 1)) / CGFloat(boardSize))
        VStack(spacing: gap) {
            ForEach(0..<boardSize, id: \.self) { row in
                HStack(spacing: gap) {
                    ForEach(0..<boardSize, id: \.self) { column in
                        let index = row * boardSize + column
                        let cell = board[row][column]
                        ZStack {
                            RoundedRectangle(cornerRadius: max(4, side * 0.17), style: .continuous)
                                .fill(index == highlightedCell ? Color.yellow.opacity(0.42) : Color.white.opacity(0.05))
                                .overlay(RoundedRectangle(cornerRadius: max(4, side * 0.17)).stroke(
                                    index == highlightedCell ? Color.yellow.opacity(0.85) : Color.white.opacity(0.12),
                                    lineWidth: index == highlightedCell ? 1.5 : 0.7
                                ))
                            if cell.count > 0 {
                                PieceView(color: cell.owner == 0 ? .red : .blue, emoji: nil, count: cell.count, size: side * 0.76)
                            }
                        }
                        .frame(width: side, height: side)
                        .contentShape(Rectangle())
                        .onTapGesture { onTap(row, column) }
                        .animation(.spring(response: 0.2, dampingFraction: 0.68), value: cell)
                    }
                }
            }
        }
        .padding(border)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: PlayerPreset.cardCornerRadius))
        .frame(width: side * CGFloat(boardSize) + gap * CGFloat(boardSize - 1) + border * 2,
               height: side * CGFloat(boardSize) + gap * CGFloat(boardSize - 1) + border * 2)
    }
}

private struct AnalyzerToolPanel: View {
    let compact: Bool
    @Binding var brush: AnalyzerBrush
    let isLocked: Bool
    let isStarted: Bool
    let isPaused: Bool
    let isThinking: Bool
    let selfColor: Int
    let canUndo: Bool
    let onStart: () -> Void
    let onPause: () -> Void
    let onUndo: () -> Void
    let onToggleSide: () -> Void

    private func brushButton(owner: Int, count: Int) -> some View {
        let color: Color = owner == 0 ? .red : .blue
        let selected = brush == .piece(owner: owner, count: count)
        return Button {
            brush = .piece(owner: owner, count: count)
            Haptics.shared.lightImpact()
        } label: {
            VStack(spacing: 3) {
                HStack(spacing: 2) {
                    ForEach(0..<count, id: \.self) { _ in
                        Circle().fill(color).frame(width: compact ? 9 : 6, height: compact ? 9 : 6)
                    }
                }
                Text("\(count)点")
                    .font(compact ? .caption.weight(.semibold) : .caption2.weight(.semibold))
                    .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity, minHeight: compact ? 40 : 38)
            .glassEffect(.regular.interactive().tint(selected ? color.opacity(0.20) : .clear), in: .rect(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(isLocked)
    }

    private var startButton: some View {
        Button {
            Haptics.shared.lightImpact()
            onStart()
        } label: {
            Label(isThinking ? "计算中…" : (isStarted && isPaused ? (compact ? "继续" : "继续分析") : (compact ? "开始" : "开始分析")),
                  systemImage: isThinking ? "hourglass" : "play.fill")
                .font(compact ? .system(size: 18, weight: .semibold) : .subheadline.bold())
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity)
                .frame(height: compact ? 56 : 48)
                .contentShape(Capsule())
                .glassEffect(.regular.interactive().tint(.darkNavyBlue), in: .capsule)
        }
        .buttonStyle(.plain)
        .disabled(isThinking || (isStarted && !isPaused))
        .opacity(isThinking || (isStarted && !isPaused) ? 0.55 : 1)
    }

    private var pauseButton: some View {
        Button {
            Haptics.shared.lightImpact()
            onPause()
        } label: {
            Label(compact ? "暂停" : "暂停分析", systemImage: "pause.fill")
                .font(compact ? .system(size: 18, weight: .semibold) : .subheadline.bold())
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity)
                .frame(height: compact ? 56 : 48)
                .contentShape(Capsule())
                .glassEffect(.regular.interactive(), in: .capsule)
        }
        .buttonStyle(.plain)
        .disabled(!isStarted || isPaused)
        .opacity(!isStarted || isPaused ? 0.5 : 1)
    }

    var body: some View {
        VStack(spacing: compact ? 6 : 10) {
            VStack(alignment: .leading, spacing: compact ? 6 : 10) {
                Text("画笔")
                    .font(compact ? .subheadline.bold() : .headline.bold())
                    .foregroundStyle(.white)
                ForEach(0..<2, id: \.self) { owner in
                    HStack(spacing: compact ? 4 : 5) {
                        Circle().fill(owner == 0 ? Color.red : Color.blue).frame(width: 10, height: 10)
                        Text(owner == 0 ? "红" : "蓝")
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                            .frame(width: 22, alignment: .leading)
                        ForEach(1...3, id: \.self) { count in
                            brushButton(owner: owner, count: count)
                        }
                    }
                }
                Button {
                    brush = .eraser
                    Haptics.shared.lightImpact()
                } label: {
                    Label("橡皮擦", systemImage: "eraser.fill")
                        .font(compact ? .caption.bold() : .subheadline.bold())
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: compact ? 40 : 38)
                        .contentShape(Capsule())
                        .glassEffect(.regular.interactive().tint(brush == .eraser ? .gray.opacity(0.35) : .clear), in: .capsule)
                }
                .buttonStyle(.plain)
                .disabled(isLocked)
            }
            .padding(compact ? 8 : 12)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: PlayerPreset.cardCornerRadius))
            .opacity(isLocked ? 0.52 : 1)

            if compact {
                HStack(spacing: 8) {
                    startButton
                    pauseButton
                }
            } else {
                startButton
                pauseButton
            }

            Button {
                Haptics.shared.lightImpact()
                onToggleSide()
            } label: {
                Label("我方：\(selfColor == 0 ? "红" : "蓝") · 切换", systemImage: "arrow.left.arrow.right")
                    .font(compact ? .system(size: 18, weight: .semibold) : .subheadline.bold())
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .frame(maxWidth: .infinity)
                    .frame(height: compact ? 56 : 48)
                    .contentShape(Rectangle())
                    .glassEffect(.regular.interactive(), in: .capsule)
            }
            .buttonStyle(.plain)
            .disabled(isThinking || (isStarted && !isPaused))
            .opacity(isThinking || (isStarted && !isPaused) ? 0.5 : 1)

            Button {
                Haptics.shared.lightImpact()
                onUndo()
            } label: {
                Label("撤销上一步", systemImage: "arrow.uturn.backward")
                    .font(compact ? .system(size: 18, weight: .semibold) : .subheadline.bold())
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .frame(maxWidth: .infinity)
                    .frame(height: compact ? 56 : 48)
                    .contentShape(Rectangle())
                    .glassEffect(.regular.interactive(), in: .capsule)
            }
            .buttonStyle(.plain)
            .disabled(!canUndo || isThinking)
            .opacity(!canUndo || isThinking ? 0.5 : 1)
        }
    }
}

private struct AnalyzerPlayView: View {
    @ObservedObject var game: GameModel
    @State private var boardSize: Int
    @Binding var selfColor: Int
    @Binding var importedArchive: GameSaveArchive?
    @State private var board: [[Cell]]
    @State private var selectedBrush: AnalyzerBrush = .piece(owner: 0, count: 1)
    @State private var analysisStarted = false
    @State private var isPaused = false
    @State private var isThinking = false
    @State private var waitingForOpponent = false
    @State private var moveCount = 0
    @State private var highlightedCell: Int?
    private struct UndoState { let board: [[Cell]]; let moveCount: Int; let waitingForOpponent: Bool; let highlightedCell: Int? }
    @State private var undoStack: [UndoState] = []
    @State private var aiTask: Task<Void, Never>?

    init(game: GameModel, boardSize: Int, selfColor: Binding<Int>,
         importedArchive: Binding<GameSaveArchive?>, initialArchive: GameSaveArchive?) {
        self.game = game
        let initialSize = initialArchive?.boardSize ?? boardSize
        self._boardSize = State(initialValue: initialSize)
        self._selfColor = selfColor
        self._importedArchive = importedArchive
        _board = State(initialValue: Self.makeBoard(size: initialSize, selfColor: selfColor.wrappedValue, archive: initialArchive))
        _moveCount = State(initialValue: initialArchive?.localDuelMoveCount ?? 0)
    }

    private static func makeBoard(size: Int, selfColor: Int, archive: GameSaveArchive?) -> [[Cell]] {
        guard let archive else {
            var initial = Array(repeating: Array(repeating: Cell(owner: nil, count: 0), count: size), count: size)
            initial[0][0] = Cell(owner: 0, count: 1)
            initial[size - 1][size - 1] = Cell(owner: 1, count: 1)
            return initial
        }
        return (0..<size).map { row in
            (0..<size).map { column in
                guard archive.board.indices.contains(row), archive.board[row].indices.contains(column) else {
                    return Cell(owner: nil, count: 0)
                }
                let source = archive.board[row][column]
                guard let owner = source.owner, source.count > 0 else { return Cell(owner: nil, count: 0) }
                let mappedOwner = owner == archive.currentPlayer ? selfColor : 1 - selfColor
                return Cell(owner: mappedOwner, count: source.count)
            }
        }
    }

    private func loadArchiveIntoAnalyzer(_ archive: GameSaveArchive) {
        aiTask?.cancel()
        boardSize = archive.boardSize
        board = Self.makeBoard(size: archive.boardSize, selfColor: selfColor, archive: archive)
        moveCount = archive.localDuelMoveCount ?? 0
        highlightedCell = nil
        undoStack.removeAll()
        waitingForOpponent = false
        isThinking = false
        analysisStarted = false
        isPaused = false
    }

    private func tapCell(row: Int, column: Int) {
        if !analysisStarted || isPaused {
            pushUndoSnapshot()
            switch selectedBrush {
            case let .piece(owner, count): board[row][column] = Cell(owner: owner, count: count)
            case .eraser: board[row][column] = Cell(owner: nil, count: 0)
            }
            Haptics.shared.lightImpact()
            return
        }
        guard !isPaused, !isThinking, waitingForOpponent,
              board[row][column].owner == 1 - selfColor else { return }
        Haptics.shared.lightImpact()
        pushUndoSnapshot()
        highlightedCell = nil
        applyMove(row: row, column: column, owner: 1 - selfColor)
        waitingForOpponent = false
        moveCount += 1
        runSelfMove()
    }

    private func applyMove(row: Int, column: Int, owner: Int) {
        if board[row][column].owner == owner {
            board[row][column].count += 1
        } else {
            board[row][column] = Cell(owner: owner, count: board[row][column].count + 1)
        }
        var iterations = 0
        while iterations < boardSize * boardSize * 8 {
            iterations += 1
            let exploding = (0..<boardSize).flatMap { r in
                (0..<boardSize).compactMap { c -> (Int, Int, Int)? in
                    let cell = board[r][c]
                    guard cell.count >= 4, let source = cell.owner else { return nil }
                    return (r, c, source)
                }
            }
            guard !exploding.isEmpty else { break }
            for (r, c, _) in exploding {
                board[r][c].count -= 4
                if board[r][c].count == 0 { board[r][c].owner = nil }
            }
            for (r, c, source) in exploding {
                for (dr, dc) in [(0, 1), (0, -1), (1, 0), (-1, 0)] {
                    let nr = r + dr, nc = c + dc
                    guard (0..<boardSize).contains(nr), (0..<boardSize).contains(nc) else { continue }
                    board[nr][nc].owner = source
                    board[nr][nc].count += 1
                }
            }
        }
    }

    private func runSelfMove() {
        guard analysisStarted, !isPaused, !isThinking else { return }
        isThinking = true
        let solver = AISolver(
            boardSize: boardSize,
            activePlayers: [0, 1],
            currentPlayer: selfColor,
            playerType: .driveBot,
            aiLevel: .extreme,
            board: board,
            hasEntered: [true, true],
            eliminated: [false, false],
            isLocalDuelMode: true,
            localDuelMovesPlayed: moveCount,
            searchTimeLimitOverride: 5.0
        )
        aiTask = Task {
            let move = await solver.calculateBestMove()
            guard !Task.isCancelled else {
                isThinking = false
                return
            }
            guard !isPaused, let (row, column) = move else {
                isThinking = false
                waitingForOpponent = false
                return
            }
            pushUndoSnapshot()
            applyMove(row: row, column: column, owner: selfColor)
            highlightedCell = row * boardSize + column
            moveCount += 1
            waitingForOpponent = true
            isThinking = false
        }
    }

    private func startOrResume() {
        if !analysisStarted {
            analysisStarted = true
            isPaused = false
            selectedBrush = .piece(owner: 0, count: 1)
            runSelfMove()
        } else if isPaused {
            isPaused = false
            if !waitingForOpponent { runSelfMove() }
        }
    }

    private func pushUndoSnapshot() {
        undoStack.append(UndoState(board: board, moveCount: moveCount,
                                   waitingForOpponent: waitingForOpponent, highlightedCell: highlightedCell))
    }

    private func undoPreviousAction() {
        guard let previous = undoStack.popLast() else { return }
        aiTask?.cancel()
        board = previous.board
        moveCount = previous.moveCount
        waitingForOpponent = previous.waitingForOpponent
        highlightedCell = previous.highlightedCell
        isThinking = false
        isPaused = true
    }

    private func toggleSelfColor() {
        guard !isThinking && (!analysisStarted || isPaused) else { return }
        selfColor = 1 - selfColor
    }

    private func pause() {
        guard analysisStarted else { return }
        isPaused = true
        aiTask?.cancel()
        isThinking = false
    }

    var body: some View {
        ZStack {
            Color(red: 0.025, green: 0.055, blue: 0.14)
                .ignoresSafeArea()
            GeometryReader { proxy in
                let horizontal = proxy.size.width >= 900 && proxy.size.height >= 620
                if horizontal {
                    let boardSide = max(96, min(680, min(proxy.size.width - 280, proxy.size.height - 24)))
                    HStack(spacing: 16) {
                        AnalyzerBoardView(boardSize: boardSize, board: board, highlightedCell: highlightedCell,
                                          maxSide: boardSide) { row, column in tapCell(row: row, column: column) }
                        AnalyzerToolPanel(compact: false,
                                          brush: $selectedBrush,
                                          isLocked: analysisStarted && !isPaused,
                                          isStarted: analysisStarted,
                                          isPaused: isPaused,
                                          isThinking: isThinking,
                                          selfColor: selfColor,
                                          canUndo: !undoStack.isEmpty,
                                          onStart: startOrResume,
                                          onPause: pause,
                                          onUndo: undoPreviousAction,
                                          onToggleSide: toggleSelfColor)
                            .frame(width: 220)
                            .frame(maxHeight: .infinity, alignment: .center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .padding(.horizontal, 12)
                } else {
                    let boardSide = max(96, min(proxy.size.width - 24, proxy.size.height - 374))
                    VStack(spacing: 8) {
                        AnalyzerBoardView(boardSize: boardSize, board: board, highlightedCell: highlightedCell,
                                          maxSide: boardSide) { row, column in tapCell(row: row, column: column) }
                        AnalyzerToolPanel(compact: true,
                                          brush: $selectedBrush,
                                          isLocked: analysisStarted && !isPaused,
                                          isStarted: analysisStarted,
                                          isPaused: isPaused,
                                          isThinking: isThinking,
                                          selfColor: selfColor,
                                          canUndo: !undoStack.isEmpty,
                                          onStart: startOrResume,
                                          onPause: pause,
                                          onUndo: undoPreviousAction,
                                          onToggleSide: toggleSelfColor)
                            .frame(maxWidth: min(proxy.size.width - 24, 600))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .padding(.horizontal, 12)
                }
            }
        }
        .onChange(of: importedArchive?.id) { _, _ in
            if let archive = importedArchive { loadArchiveIntoAnalyzer(archive) }
        }
        .onDisappear { aiTask?.cancel() }
    }
}

struct StartMenuView: View {
    @ObservedObject var game: GameModel
    @Binding var selectedTab: Int
    @Binding var isSpinningRandomWheel: Bool
    @State private var selectedPartyMode = UserDefaults.standard.integer(forKey: "CW_SelectedPartyMode")
    @State private var duelBoardSize: Int = {
        let value = UserDefaults.standard.integer(forKey: "CW_Duel_BoardSize")
        if [6, 9, 12].contains(value) { return value }
        let legacy = UserDefaults.standard.integer(forKey: "CW_Saved_BoardSize")
        return [6, 9, 12].min(by: { abs($0 - (legacy == 0 ? 6 : legacy)) < abs($1 - (legacy == 0 ? 6 : legacy)) }) ?? 6
    }()
    @State private var partyBoardSize: Int = {
        let value = UserDefaults.standard.integer(forKey: "CW_Party_BoardSize")
        if (5...12).contains(value) { return value }
        let legacy = UserDefaults.standard.integer(forKey: "CW_Saved_BoardSize")
        return (5...12).contains(legacy) ? legacy : 8
    }()
    @State private var duelPlayerOneType: PlayerControlType = UserDefaults.standard.data(forKey: "CW_Duel_PlayerOne")
        .flatMap { try? JSONDecoder().decode(PlayerControlType.self, from: $0) } ?? .human
    @State private var duelPlayerTwoType: PlayerControlType = UserDefaults.standard.data(forKey: "CW_Duel_PlayerTwo")
        .flatMap { try? JSONDecoder().decode(PlayerControlType.self, from: $0) } ?? .human
    @State private var duelNavigationPath: [StartMenuDestination] = []
    @State private var partyNavigationPath: [StartMenuDestination] = []
    @State private var analyzerNavigationPath: [StartMenuDestination] = []
    @State private var showPhotoPicker = false
    @State private var selectedPhotosItem: PhotosPickerItem?
    @State private var analyzerBoardSize = {
        let value = UserDefaults.standard.integer(forKey: "CW_Analyzer_BoardSize")
        return [6, 9, 12].contains(value) ? value : 6
    }()
    @State private var analyzerSelfColor = UserDefaults.standard.integer(forKey: "CW_Analyzer_SelfColor") == 1 ? 1 : 0
    @State private var pendingAnalyzerArchive: GameSaveArchive?
    @State private var unsupportedArchiveMessage: String?

    private func startGame(isLocalDuel: Bool = false) {
        game.isLocalDuelMode = isLocalDuel
        if !isLocalDuel && game.isRandomFirstPlayer {
            isSpinningRandomWheel = true
        } else {
            game.resetGame()
            game.beginGame()
            game.shouldNavigateToGame = true
        }
    }

    private func startDuelGame() {
        UserDefaults.standard.set(duelBoardSize, forKey: "CW_Duel_BoardSize")
        UserDefaults.standard.set(partyBoardSize, forKey: "CW_Party_BoardSize")
        game.isLocalDuelMode = true
        game.boardSize = duelBoardSize
        let first = duelPlayerOneType
        let second = duelPlayerTwoType
        game.playerTypes = [first, second] + Array(repeating: .disabled, count: max(0, PlayerPreset.maxPlayers - 2))
        game.prepareLocalPlayerNamesForGame()
        startGame(isLocalDuel: true)
    }

    private var background: some View {
        GeometryReader { proxy in
            ZStack {
                Color(red: 0.025, green: 0.055, blue: 0.14)
                if let customImg = game.customBackgroundImage {
                    Image(uiImage: customImg)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                        .overlay(Color(red: 0.015, green: 0.035, blue: 0.09).opacity(0.24))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private var duelTab: some View {
        VStack(spacing: 16) {
            Text("COLOR WAR")
                .font(.system(size: 36, weight: .black, design: .rounded))
                .foregroundStyle(.white)
            DualPlayerSetupView(game: game,
                                boardSize: $duelBoardSize,
                                playerOneType: $duelPlayerOneType,
                                playerTwoType: $duelPlayerTwoType,
                                onStartGame: startDuelGame)
                .frame(maxWidth: 440)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 20)
    }

    private var partyTab: some View {
        VStack(alignment: .center, spacing: 10) {
            Picker("派对模式", selection: $selectedPartyMode) {
                Text("多人").tag(0)
                Text("联机").tag(1)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 440)
            Text("COLOR WAR")
                .font(.system(size: 36, weight: .black, design: .rounded))
                .foregroundStyle(.white)
            if selectedPartyMode == 0 {
                LocalGameSetupView(game: game) {
                    game.prepareLocalPlayerNamesForGame()
                    startGame()
                }
                .frame(maxWidth: 440)
            } else {
                RemoteWebSocketSetupView(game: game) { startGame() }
                    .frame(maxWidth: 440)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(.horizontal, 20)
    }

    private func restoreSetupPreferences() {
        selectedPartyMode = min(1, selectedPartyMode)
        if !game.isOnlineMultiplayer {
            if let saved = UserDefaults.standard.data(forKey: "CW_Party_PlayerTypes"),
               let values = try? JSONDecoder().decode([PlayerControlType].self, from: saved),
               values.count == PlayerPreset.maxPlayers {
                game.isLocalDuelMode = false
                game.playerTypes = values
            } else if let data = try? JSONEncoder().encode(game.playerTypes) {
                UserDefaults.standard.set(data, forKey: "CW_Party_PlayerTypes")
            }
            game.boardSize = selectedTab == 0 ? duelBoardSize : partyBoardSize
        }
        game.flushSetupPreferences()
    }

    private func handleTabChange(from oldValue: Int, to newValue: Int) {
        if oldValue == 0 { save(duelBoardSize, forKey: "CW_Duel_BoardSize") }
        if oldValue == 1 {
            partyBoardSize = game.boardSize
            save(partyBoardSize, forKey: "CW_Party_BoardSize")
        }
        guard !game.isOnlineMultiplayer else { return }
        if newValue == 0 {
            game.isLocalDuelMode = false
            game.boardSize = duelBoardSize
        } else if newValue == 1 {
            if let saved = UserDefaults.standard.data(forKey: "CW_Party_PlayerTypes"),
               let values = try? JSONDecoder().decode([PlayerControlType].self, from: saved),
               values.count == PlayerPreset.maxPlayers {
                game.isLocalDuelMode = false
                game.playerTypes = values
            }
            game.boardSize = partyBoardSize
        }
    }

    private func save<T: Encodable>(_ value: T, forKey key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private func save(_ value: Int, forKey key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    private func savePartyPlayerTypes(_ value: [PlayerControlType]) {
        guard selectedTab == 1, !game.isLocalDuelMode, !game.isOnlineMultiplayer else { return }
        save(value, forKey: "CW_Party_PlayerTypes")
    }

    private func openAnalyzer() {
        guard !analyzerNavigationPath.contains(.analyzerPlay) else { return }
        analyzerNavigationPath.append(.analyzerPlay)
    }

    private func openGame() {
        game.shouldNavigateToGame = false
        if selectedTab == 1 {
            guard !partyNavigationPath.contains(.gamePlay) else { return }
            partyNavigationPath.append(.gamePlay)
        } else {
            guard !duelNavigationPath.contains(.gamePlay) else { return }
            duelNavigationPath.append(.gamePlay)
        }
    }

    private func leaveGame() {
        game.returnToMenuPreservingOnlineSession()
        if selectedTab == 1, partyNavigationPath.last == .gamePlay {
            partyNavigationPath.removeLast()
        } else if selectedTab != 1, duelNavigationPath.last == .gamePlay {
            duelNavigationPath.removeLast()
        }
    }

    private func chooseBackground() {
        showPhotoPicker = true
    }

    @ToolbarContentBuilder
    private var gameToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button(action: leaveGame) {
                Label("返回", systemImage: "chevron.left")
            }
            .accessibilityLabel("返回")
        }
        ToolbarItem(placement: .principal) {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                HStack(spacing: 6) {
                    Text(String(format: "%02d:%02d", max(0, Int(timeline.date.timeIntervalSince(game.matchStartedAt))) / 60,
                                max(0, Int(timeline.date.timeIntervalSince(game.matchStartedAt))) % 60))
                    Text("·").foregroundStyle(.white.opacity(0.55))
                    Text(game.activePlayerIndices.count == 2
                         ? "\(game.currentPlayer == 0 ? "红" : "蓝")回合"
                         : "\(game.playerNames[safe: game.currentPlayer] ?? "玩家")回合")
                    Text("·").foregroundStyle(.white.opacity(0.55))
                    Text("\(game.localDuelMoveCount)步")
                }
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white)
                .fixedSize()
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { game.showControlSheet = true } label: {
                Image(systemName: "gearshape.fill")
            }
            .accessibilityLabel("设置")
        }
    }

    private func handleArchiveSelection(_ archive: GameSaveArchive) -> Bool {
        let activeCount = archive.playerTypes.filter { $0.isEnabled }.count
        if (selectedTab == 0 || selectedTab == 2) && activeCount > 2 {
            unsupportedArchiveMessage = selectedTab == 0
                ? "这是多人棋局，请切换到「派对」模式后再导入。"
                : "分析器暂不支持多人棋局存档，请选择双人存档。"
            return false
        }
        switch selectedTab {
        case 2:
            pendingAnalyzerArchive = archive
            openAnalyzer()
        case 0:
            game.isLocalDuelMode = true
            game.restoreArchive(archive)
            game.shouldNavigateToGame = true
        default:
            game.isLocalDuelMode = false
            game.restoreArchive(archive)
            game.shouldNavigateToGame = true
        }
        return true
    }

    private func loadSelectedBackground(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            if let data = try? await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                await MainActor.run { game.saveCustomBackground(image) }
            }
        }
    }

    @ViewBuilder
    private func destinationView(_ destination: StartMenuDestination) -> some View {
        switch destination {
        case .gamePlay:
            GamePlayView(game: game,
                         isSpinningRandomWheel: $isSpinningRandomWheel,
                         onExit: leaveGame)
                .navigationBarBackButtonHidden(true)
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbar(.hidden, for: .tabBar)
                .toolbar { gameToolbar }
        case .analyzerPlay:
            AnalyzerPlayView(game: game, boardSize: analyzerBoardSize,
                             selfColor: $analyzerSelfColor,
                             importedArchive: $pendingAnalyzerArchive,
                             initialArchive: pendingAnalyzerArchive)
                .toolbar(.hidden, for: .tabBar)
                .onDisappear { pendingAnalyzerArchive = nil }
        }
    }

    private var duelNavigation: some View {
        NavigationStack(path: $duelNavigationPath) {
            duelTab
                .background(background)
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbar { setupToolbar }
                .navigationDestination(for: StartMenuDestination.self) { destinationView($0) }
        }
    }

    private var partyNavigation: some View {
        NavigationStack(path: $partyNavigationPath) {
            partyTab
                .background(background)
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbar { setupToolbar }
                .navigationDestination(for: StartMenuDestination.self) { destinationView($0) }
        }
    }

    private var analyzerNavigation: some View {
        NavigationStack(path: $analyzerNavigationPath) {
            AnalyzerLandingView(game: game,
                                boardSize: $analyzerBoardSize,
                                selfColor: $analyzerSelfColor,
                                onStart: openAnalyzer)
                .background(background)
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbar { setupToolbar }
                .navigationDestination(for: StartMenuDestination.self) { destinationView($0) }
        }
    }

    // The native TabView is the app's root mode navigation. Each tab owns its
    // own NavigationStack so pushing a game or Analyzer never leaks into another tab.
    private var setupTabs: some View {
        TabView(selection: $selectedTab) {
            duelNavigation
                .tabItem { Label("对弈", systemImage: "circle.grid.3x3.fill") }
                .tag(0)
            partyNavigation
                .tabItem { Label("派对", systemImage: "party.popper.fill") }
                .tag(1)
            analyzerNavigation
                .tabItem { Label("分析器", systemImage: "wrench.and.screwdriver.fill") }
                .tag(2)
        }
        .background(Color.clear)
    }

    @ToolbarContentBuilder
    private var setupToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { game.showArchivePickerSheet = true } label: {
                Image(systemName: "square.and.arrow.down")
                    .foregroundStyle(.white)
            }
            .accessibilityLabel("导入存档")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button { showPhotoPicker = true } label: {
                    Label("从相册选择背景", systemImage: "photo.on.rectangle")
                }
                if game.customBackgroundImage != nil {
                    Button(role: .destructive) { game.saveCustomBackground(nil) } label: {
                        Label("清除自定义背景", systemImage: "trash")
                    }
                }
            } label: {
                Image(systemName: "photo.badge.plus")
                    .foregroundStyle(.white)
                    .font(.system(size: 16, weight: .medium))
            }
            .accessibilityLabel("背景")
        }
    }

    private var tabsWithCorePreferences: some View {
        setupTabs
            .onAppear(perform: restoreSetupPreferences)
            .onChange(of: selectedTab) { oldValue, newValue in
                handleTabChange(from: oldValue, to: newValue)
            }
            .onChange(of: duelBoardSize) { _, value in save(value, forKey: "CW_Duel_BoardSize") }
            .onChange(of: duelPlayerOneType) { _, value in save(value, forKey: "CW_Duel_PlayerOne") }
            .onChange(of: duelPlayerTwoType) { _, value in save(value, forKey: "CW_Duel_PlayerTwo") }
    }

    private var tabsWithPartyPreferences: some View {
        tabsWithCorePreferences
            .onChange(of: partyBoardSize) { _, value in save(value, forKey: "CW_Party_BoardSize") }
            .onChange(of: game.boardSize) { _, value in
                guard selectedTab == 1 else { return }
                partyBoardSize = value
                save(value, forKey: "CW_Party_BoardSize")
            }
            .onChange(of: game.playerTypes) { _, value in savePartyPlayerTypes(value) }
            .onChange(of: selectedPartyMode) { _, value in save(value, forKey: "CW_SelectedPartyMode") }
    }

    private var tabsWithAnalyzerPreferences: some View {
        tabsWithPartyPreferences
            .onChange(of: analyzerBoardSize) { _, value in save(value, forKey: "CW_Analyzer_BoardSize") }
            .onChange(of: analyzerSelfColor) { _, value in save(value, forKey: "CW_Analyzer_SelfColor") }
            .onDisappear { game.flushSetupPreferences() }
    }

    private var tabsWithPickersAndSheets: some View {
        tabsWithAnalyzerPreferences
            .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhotosItem, matching: .images)
            .sheet(isPresented: $game.showArchivePickerSheet) {
                ArchivePickerSheet(game: game, unsupportedMessage: $unsupportedArchiveMessage,
                                   onSelect: handleArchiveSelection)
            }
            .onChange(of: selectedPhotosItem) { _, item in loadSelectedBackground(item) }
    }

    var body: some View {
        tabsWithPickersAndSheets
            .onChange(of: game.shouldNavigateToGame) { _, shouldNavigate in
                if shouldNavigate { openGame() }
            }
    }

}

private enum StartMenuDestination: Hashable {
    case analyzerPlay
    case gamePlay
}

private struct AnalyzerLandingView: View {
    @ObservedObject var game: GameModel
    @Binding var boardSize: Int
    @Binding var selfColor: Int
    let onStart: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("COLOR WAR")
                .font(.system(size: 36, weight: .black, design: .rounded))
                .foregroundStyle(.white)
            AnalyzerSetupView(boardSize: $boardSize, selfColor: $selfColor, onStart: onStart)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
    }
}

// MARK: - 21. 轮盘 Overlay

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

// MARK: - 22. 游戏对局 View (背景随玩家回合平滑变幻)

struct GamePlayView: View {
    @ObservedObject var game: GameModel
    @Binding var isSpinningRandomWheel: Bool
    let onExit: () -> Void
    
    var body: some View {
        ZStack {
            GeometryReader { proxy in
                ZStack {
                    LinearGradient(
                        colors: [
                            (game.colors[safe: game.currentPlayer] ?? .blue).opacity(0.35),
                            Color(red: 0.025, green: 0.055, blue: 0.14)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    if let customImg = game.customBackgroundImage {
                        Image(uiImage: customImg)
                            .resizable()
                            .scaledToFill()
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .clipped()
                            .overlay(Color(red: 0.015, green: 0.035, blue: 0.09).opacity(0.48))
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .animation(.easeInOut(duration: 0.45), value: game.currentPlayer)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            
            VStack(spacing: 8) {
                Spacer(minLength: 4)
                BoardView(game: game) { _ in }
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
                            if game.isRandomFirstPlayer {
                                isSpinningRandomWheel = true
                            } else {
                                game.restartCurrentGame()
                            }
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
                        
                        Button(action: onExit) {
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
            Button("确定", role: .cancel, action: onExit)
        } message: {
            Text(game.disconnectedMessage)
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }
}

// MARK: - 23. 控制面板 Sheet (内置“保存当前棋局”入口)

struct PlayerTakeoverSheet: View {
    @ObservedObject var game: GameModel
    @ObservedObject var p2pManager = P2PNetworkManager.shared
    @ObservedObject var wsManager = WebSocketNetworkManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showSavedToast: Bool = false
    var body: some View {
        NavigationStack {
            List {
                if p2pManager.isConnected || wsManager.isConnected {
                    Section(header: Text("我的联机昵称")) {
                        HStack {
                            TextField("输入昵称", text: $p2pManager.myNickname)
                            Button("更新") { game.renameMyPlayer(to: p2pManager.myNickname) }
                                .disabled(p2pManager.myNickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }

                Section {
                    Button(action: {
                        game.saveCurrentGameArchive()
                        showSavedToast = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            showSavedToast = false
                        }
                    }) {
                        HStack {
                            Spacer()
                            Image(systemName: "square.and.arrow.down.fill").font(.title3)
                            Text("💾 保存当前棋局到本地").font(.headline).bold()
                            Spacer()
                        }
                        .foregroundColor(.cyan)
                    }
                    
                    if showSavedToast {
                        Text("✅ 棋局已成功保存！")
                            .font(.caption)
                            .foregroundColor(.green)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    
                    Button(action: {
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
                
                if !(game.isLocalDuelMode && game.activePlayerIndices.count == 2 && !game.isOnlineMultiplayer) {
                    Section(header: Text("实时接管控制（AI / 人类代打）")) {
                        ForEach(game.activePlayerIndices, id: \.self) { idx in
                            HStack {
                                Circle().fill(game.colors[safe: idx] ?? .gray).frame(width: 16, height: 16)
                                Text(game.playerNames[safe: idx] ?? "玩家\(idx+1)").font(.body)
                                Spacer()
                            
                                if game.isOnlineMultiplayer {
                                    Text(game.playerTypes[safe: idx]?.displayName ?? "未加入")
                                        .font(.caption)
                                        .foregroundColor(.white.opacity(0.65))
                                } else {
                                    Picker("", selection: Binding(
                                        get: { game.playerTypes[safe: idx] ?? .disabled },
                                        set: { game.updatePlayerType(at: idx, to: $0) }
                                    )) {
                                        ForEach(game.validSelectableTypes(forPlayerIndex: idx, isInLobby: false)) { type in
                                            Text(type.displayName).tag(type)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                }
                            }
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

// MARK: - 24. 历史存档恢复导入 Sheet

struct ArchivePickerSheet: View {
    @ObservedObject var game: GameModel
    @Binding var unsupportedMessage: String?
    var onSelect: ((GameSaveArchive) -> Bool)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var archives: [GameSaveArchive] = []
    
    var body: some View {
        NavigationStack {
            List {
                if archives.isEmpty {
                    Text("暂无保存的历史棋局存档")
                        .foregroundColor(.gray)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding()
                } else {
                    ForEach(archives) { archive in
                        Button(action: {
                            if let onSelect {
                                if onSelect(archive) { dismiss() }
                            } else {
                                game.restoreArchive(archive)
                                game.shouldNavigateToGame = true
                                dismiss()
                            }
                        }) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(archive.displaySummary)
                                    .font(.headline)
                                    .foregroundColor(.white)
                                
                                HStack(spacing: 8) {
                                    ForEach(0..<archive.playerTypes.count, id: \.self) { idx in
                                        if archive.playerTypes[idx].isEnabled {
                                            HStack(spacing: 2) {
                                                Circle()
                                                    .fill(Color(hex: archive.colorsHex[safe: idx] ?? "#FFFFFF"))
                                                    .frame(width: 10, height: 10)
                                                if let em = archive.emojis[safe: idx], let emoji = em {
                                                    Text(emoji).font(.caption2)
                                                }
                                                Text(archive.playerNames[safe: idx] ?? "玩家")
                                                    .font(.caption2)
                                                    .foregroundColor(.gray)
                                            }
                                        }
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .onDelete { indexSet in
                        game.deleteArchive(at: indexSet)
                        archives = game.loadAllArchives()
                    }
                }
            }
            .navigationTitle("恢复历史对局")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("关闭") { dismiss() }
            }
            .onAppear {
                archives = game.loadAllArchives()
            }
            .alert("无法导入此存档", isPresented: Binding(
                get: { unsupportedMessage != nil },
                set: { if !$0 { unsupportedMessage = nil } }
            )) {
                Button("好", role: .cancel) { unsupportedMessage = nil }
            } message: {
                Text(unsupportedMessage ?? "")
            }
        }
        .presentationBackground(.thinMaterial)
    }
}

// MARK: - 25. 根视图 ContentView

struct ContentView: View {
    @StateObject private var game = GameModel()
    @State private var isSpinningRandomWheel = false
    @State private var selectedSetupTab = 0
    
    var body: some View {
        StartMenuView(
            game: game,
            selectedTab: $selectedSetupTab,
            isSpinningRandomWheel: $isSpinningRandomWheel
        )
        .overlay {
            if isSpinningRandomWheel {
                RandomPlayerWheelOverlay(
                    game: game,
                    activeIndices: game.activePlayerIndices,
                    onFinished: { chosenWinner in
                        game.resetGame(chosenFirstPlayer: chosenWinner)
                        game.beginGame()
                        isSpinningRandomWheel = false
                        game.shouldNavigateToGame = true
                    }
                )
            }
        }
    }
}
