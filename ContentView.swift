import SwiftUI
import CoreML
import Combine
import UIKit
import QuartzCore

// MARK: - 1. 原生 Haptic 触觉反馈引擎

final class Haptics {
    static let shared = Haptics()
    private init() {}
    
    func lightImpact() {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.prepare()
        generator.impactOccurred()
    }
    
    func mediumImpact() {
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.prepare()
        generator.impactOccurred()
    }
    
    func heavyImpact() {
        let generator = UIImpactFeedbackGenerator(style: .heavy)
        generator.prepare()
        generator.impactOccurred()
    }
    
    func cascadeWarning() {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.warning)
    }
}

// MARK: - 2. 性能与诊断监控单例

@MainActor
final class PerformanceMonitor: ObservableObject {
    static let shared = PerformanceMonitor()
    
    @Published var cpuUsage: Double = 0.0
    @Published var npuLatencyMs: Double = 0.0
    @Published var isModel1Ready = false
    @Published var model1Message = "未初始化"
    @Published var isModel2Ready = false
    @Published var model2Message = "未初始化"
    @Published var activeWarning: String? = nil
    
    private var timer: Timer?
    
    private init() {
        startCPUMonitoring()
    }
    
    func startCPUMonitoring() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateCPUUsage()
            }
        }
    }
    
    func updateNPULatency(_ latency: Double) {
        self.npuLatencyMs = latency
    }
    
    private func updateCPUUsage() {
        self.cpuUsage = fetchCurrentProcessCPUUsage()
    }
    
    private func fetchCurrentProcessCPUUsage() -> Double {
        var totalUsageOfCPU: Double = 0.0
        var threadsList: thread_act_array_t?
        var threadCount: mach_msg_type_number_t = 0
        
        let kr = task_threads(mach_task_self_, &threadsList, &threadCount)
        if kr != KERN_SUCCESS { return 0.0 }
        
        if let threadsList = threadsList {
            for i in 0..<Int(threadCount) {
                var threadInfo = thread_basic_info()
                var threadInfoCount = mach_msg_type_number_t(THREAD_INFO_MAX)
                
                let result = withUnsafeMutablePointer(to: &threadInfo) {
                    $0.withMemoryRebound(to: integer_t.self, capacity: Int(threadInfoCount)) {
                        thread_info(threadsList[i], thread_flavor_t(THREAD_BASIC_INFO), $0, &threadInfoCount)
                    }
                }
                
                if result == KERN_SUCCESS {
                    if threadInfo.flags & TH_FLAGS_IDLE == 0 {
                        totalUsageOfCPU += (Double(threadInfo.cpu_usage) / Double(TH_USAGE_SCALE)) * 100.0
                    }
                }
            }
            let size = MemoryLayout<thread_act_t>.size * Int(threadCount)
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threadsList)), vm_size_t(size))
        }
        return totalUsageOfCPU
    }
}

// MARK: - 3. 基础数据模型与配置

enum PlayerControlType: String, CaseIterable, Identifiable, Codable {
    case human = "真人"
    case colorWarAI = "ColorWarAI (NPU)"
    case colorWar12x12 = "12x12 AI (NPU)"
    case mathNightmare = "算法-噩梦"
    case enhancedNightmare = "算法-噩梦 (加强版)"
    case disabled = "未加入"
    
    var id: String { rawValue }
    
    var isAI: Bool {
        self != .human && self != .disabled
    }
    
    var isNeuralAI: Bool {
        self == .colorWarAI || self == .colorWar12x12
    }
}

struct PlayerPreset {
    static let maxPlayers = 8
    
    static let defaultColors: [Color] = [
        Color(red: 1.0, green: 0.27, blue: 0.23), // 🔴 红
        Color(red: 0.04, green: 0.52, blue: 1.0), // 🔵 蓝
        Color(red: 0.19, green: 0.82, blue: 0.35), // 🟢 绿
        Color(red: 1.0, green: 0.62, blue: 0.04), // 🟧 橙
        Color(red: 0.69, green: 0.32, blue: 0.87), // 🟣 紫
        Color(red: 0.0, green: 0.78, blue: 0.75), // 🩵 青
        Color(red: 1.0, green: 0.84, blue: 0.04), // 🟡 黄
        Color(red: 0.96, green: 0.44, blue: 0.62)  // 🩷 粉
    ]
    
    static let palettePool: [Color] = [
        Color(red: 1.0, green: 0.27, blue: 0.23),
        Color(red: 0.04, green: 0.52, blue: 1.0),
        Color(red: 0.19, green: 0.82, blue: 0.35),
        Color(red: 1.0, green: 0.62, blue: 0.04),
        Color(red: 0.69, green: 0.32, blue: 0.87),
        Color(red: 0.0, green: 0.78, blue: 0.75),
        Color(red: 1.0, green: 0.84, blue: 0.04),
        Color(red: 0.96, green: 0.44, blue: 0.62)
    ]
    
    static let emojiPresets: [String] = [
        "🔴", "🔵", "🟢", "🟧", "🟣", "🩵", "🟡", "🩷",
        "🦁", "🐯", "🐻", "🦊", "🐱", "🐶", "🐼", "🐸",
        "🔥", "⚡️", "💥", "💎", "🚀", "👑", "👻", "🤡"
    ]
    
    static let names = ["红方", "蓝方", "绿方", "橙方", "紫方", "青方", "黄方", "粉方"]
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

// MARK: - 4. Color 扩展

extension Color {
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
        
        var m1Ready = false, m1Msg = ""
        var m2Ready = false, m2Msg = ""
        
        if let (model, _) = loadModelDetail(named: "ColorWarAI", config: config) {
            do {
                self.reuseInputArray1 = try MLMultiArray(shape: [1, 5, 12, 12], dataType: .float32)
                self.modelColorWarAI = model
                m1Ready = true
                m1Msg = "已就绪 [1,5,12,12]"
            } catch { m1Msg = "张量分配失败" }
        } else { m1Msg = "未找到模型文件" }
        
        if let (model, _) = loadModelDetail(named: "colorwar_12x12_model", config: config) {
            do {
                self.reuseInputArray2 = try MLMultiArray(shape: [1, 4, 12, 12], dataType: .float32)
                self.model12x12 = model
                m2Ready = true
                m2Msg = "已就绪 [1,4,12,12]"
            } catch { m2Msg = "张量分配失败" }
        } else { m2Msg = "未找到模型文件" }
        
        Task { @MainActor in
            PerformanceMonitor.shared.isModel1Ready = m1Ready
            PerformanceMonitor.shared.model1Message = m1Msg
            PerformanceMonitor.shared.isModel2Ready = m2Ready
            PerformanceMonitor.shared.model2Message = m2Msg
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
            Task { @MainActor in
                PerformanceMonitor.shared.activeWarning = "⚠️ 棋盘尺寸超出神经网络限制，已降级"
            }
            return fallback() ?? validMoves.randomElement()
        }
        
        guard let model = activeModel, let inputArray = inputArray else {
            Task { @MainActor in
                PerformanceMonitor.shared.activeWarning = "⚠️ \(playerType.rawValue) 未加载，已降级"
            }
            return fallback() ?? validMoves.randomElement()
        }
        
        lock.lock()
        defer { lock.unlock() }
        
        do {
            let maxDim = 12
            let channelStride = 144
            let numChannels = isModel1 ? 5 : 4
            let totalElements = numChannels * 144
            
            let ptr = inputArray.dataPointer.bindMemory(to: Float.self, capacity: totalElements)
            memset(ptr, 0, totalElements * MemoryLayout<Float>.size)
            
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
                            ptr[idx] = normalizedValue
                        }
                    }
                }
            }
            
            if isModel1 {
                let maskOffset = 4 * channelStride
                for (r, c) in validMoves {
                    let maskIdx = maskOffset + r * maxDim + c
                    if maskIdx < totalElements {
                        ptr[maskIdx] = 1.0
                    }
                }
            }
            
            let startTime = CACurrentMediaTime()
            let inDescs = model.modelDescription.inputDescriptionsByName
            let explicitIn = isModel1 ? Self.model1InputKey : Self.model2InputKey
            let inputKey = inDescs[explicitIn] != nil ? explicitIn : (inDescs.keys.first ?? explicitIn)
            
            let provider = try MLDictionaryFeatureProvider(dictionary: [inputKey: inputArray])
            let prediction = try model.prediction(from: provider)
            
            let elapsedTimeMs = (CACurrentMediaTime() - startTime) * 1000.0
            Task { @MainActor in
                PerformanceMonitor.shared.updateNPULatency(elapsedTimeMs)
                PerformanceMonitor.shared.activeWarning = nil
            }
            
            let outDescs = model.modelDescription.outputDescriptionsByName
            let explicitOut = isModel1 ? Self.model1OutputKey : Self.model2OutputKey
            let outputKey = outDescs[explicitOut] != nil ? explicitOut : (outDescs.keys.first ?? explicitOut)
            
            guard let logits = (prediction.featureValue(for: outputKey) ?? prediction.featureValue(for: "policy_logits") ?? prediction.featureValue(for: "logits"))?.multiArrayValue else {
                Task { @MainActor in
                    PerformanceMonitor.shared.activeWarning = "❌ 无法读取模型输出"
                }
                return fallback() ?? validMoves.randomElement()
            }
            
            let logitsPtr = logits.dataPointer.bindMemory(to: Float.self, capacity: 144)
            var bestMove = validMoves[0]
            var maxScore: Float = -Float.greatestFiniteMagnitude
            
            for (r, c) in validMoves {
                let offset = r * maxDim + c
                if offset < 144 {
                    let s = logitsPtr[offset]
                    if s > maxScore {
                        maxScore = s
                        bestMove = (r, c)
                    }
                }
            }
            return bestMove
        } catch {
            let msg = error.localizedDescription
            Task { @MainActor in
                PerformanceMonitor.shared.activeWarning = "❌ CoreML 推理失败: \(msg)"
            }
            return fallback() ?? validMoves.randomElement()
        }
    }
}

// MARK: - 6. Zobrist 散列与置换表缓存 (Transposition Table)

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
        
        let validMoves = getPlayableCells(for: currentPlayer, on: board)
        guard !validMoves.isEmpty else { return nil }
        
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
            if let nOwner = nCell.owner, nOwner != player, nCell.count == 3 {
                priority += 600
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
        
        while !queue.isEmpty {
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
        didSet { UserDefaults.standard.set(boardSize, forKey: "CW_Saved_BoardSize") }
    }
    @Published var isRandomFirstPlayer: Bool {
        didSet { UserDefaults.standard.set(isRandomFirstPlayer, forKey: "CW_Saved_IsRandomFirst") }
    }
    // 💡 新增：性能面板控制开关
    @Published var showPerformanceOverlay: Bool {
        didSet { UserDefaults.standard.set(showPerformanceOverlay, forKey: "CW_Saved_ShowPerfOverlay") }
    }
    @Published var board: [[Cell]] = []
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
    @Published var hasEntered: [Bool] = Array(repeating: false, count: PlayerPreset.maxPlayers)
    @Published var eliminated: [Bool] = Array(repeating: false, count: PlayerPreset.maxPlayers)
    @Published var isProcessingCascade: Bool = false
    @Published var winnerIndex: Int? = nil
    @Published var showControlSheet: Bool = false
    @Published var flyingOrbs: [FlyingOrb] = []
    @Published var emphasizedCells: Set<Int> = []
    
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
        self.showPerformanceOverlay = UserDefaults.standard.bool(forKey: "CW_Saved_ShowPerfOverlay")
        
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
        
        resetGame()
    }
    
    private func debounceSave() {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
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
        NeuralAISolver.shared.reloadModels()
    }
    
    func updatePlayerType(at index: Int, to newType: PlayerControlType) {
        guard index >= 0 && index < PlayerPreset.maxPlayers else { return }
        playerTypes[index] = newType
        
        if index == currentPlayer && newType.isAI && !isProcessingCascade {
            checkAndRunAITurn()
        }
    }
    
    func play(row: Int, column: Int) {
        guard !isProcessingCascade, winnerIndex == nil else { return }
        
        Haptics.shared.lightImpact()
        
        let player = currentPlayer
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

// MARK: - 9. 模型状态展示组件

struct ModelStatusRow: View {
    let name: String
    let isReady: Bool
    let message: String
    
    var body: some View {
        HStack {
            Image(systemName: isReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(isReady ? .green : .red)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.caption.bold()).foregroundColor(.white)
                Text(message).font(.caption2).foregroundColor(.white.opacity(0.7))
            }
            Spacer()
        }
    }
}

// MARK: - 10. 棋盘视图

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
                    GlassPiece(
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
            .glassPanel(cornerRadius: 24)
        }
        .aspectRatio(1, contentMode: .fit)
        .onDisappear {
            game.exitToMenu()
        }
    }
}

// MARK: - 11. 单元格视图

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
                    GlassPiece(
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

// MARK: - 12. 棋子外观视图（修改：去除立体高光/内阴影，采用纯白边缘）

struct GlassPiece: View {
    let color: Color
    let emoji: String?
    let count: Int
    let size: CGFloat
    
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
            
            DotPattern(count: min(4, max(0, count)), diameter: size * 0.16)
        }
        .frame(width: size, height: size)
        // 💡 边缘修改：去高光，改用纯白色边缘描边
        .overlay(
            Circle()
                .stroke(Color.white, lineWidth: max(0.5, size * 0.04))
        )
        .compositingGroup()
        .accessibilityHidden(true)
    }
}

// MARK: - 13. 棋子点数排列视图（修改：确保 1/2/3/4 点均完美居中）

// MARK: - 13. 棋子点数排列视图（精确定位绝对居中版）

// MARK: - 13. 棋子点数排列视图（精确定位与间距修复版）

// MARK: - 13. 棋子点数排列视图（几何形心精准居中版）

// MARK: - 13. 棋子点数排列视图（精确定位与适度间距版）

// MARK: - 13. 棋子点数排列视图（适度缩小圆点 + 舒展间距版）

// MARK: - 13. 棋子点数排列视图（坐标系纠正与间距完全舒展版）

// MARK: - 13. 棋子点数排列视图（3点微调下移版）

struct DotPattern: View {
    let count: Int
    let diameter: CGFloat
    
    var body: some View {
        ZStack {
            ForEach(0..<count, id: \.self) { index in
                Circle()
                    .fill(.white)
                    .frame(width: diameter, height: diameter)
                    .offset(offset(index))
                    .transition(.scale.combined(with: .opacity))
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
            // 💡 增加了向下微调的偏移量 (+step * 0.15)
            let downOffset = step * 0.15
            
            if index == 0 {
                // 顶端点
                return CGSize(width: 0, height: -step * 0.866 + downOffset)
            } else if index == 1 {
                // 左下点
                return CGSize(width: -step * 0.75, height: step * 0.433 + downOffset)
            } else {
                // 右下点
                return CGSize(width: step * 0.75, height: step * 0.433 + downOffset)
            }
            
        default:
            // 4点：2x2 矩阵
            let x = (index % 2 == 0) ? -step * 0.65 : step * 0.65
            let y = (index < 2) ? -step * 0.65 : step * 0.65
            return CGSize(width: x, height: y)
        }
    }
}








// MARK: - 14. 玻璃质感修饰符扩展

private extension View {
    @ViewBuilder 
    func glassPanel(cornerRadius: CGFloat) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius).stroke(.white.opacity(0.15)))
        }
    }
}

struct NativeLiquidGlassModifier: ViewModifier {
    var cornerRadius: CGFloat = 20
    
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(.regular.tint(Color.white.opacity(0.12)).interactive(), in: .rect(cornerRadius: cornerRadius))
        } else {
            content
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Material.ultraThinMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .stroke(
                                    LinearGradient(
                                        colors: [.white.opacity(0.5), .white.opacity(0.1)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 1
                                )
                        )
                )
        }
    }
}

extension View {
    func nativeLiquidGlass(cornerRadius: CGFloat = 20) -> some View {
        self.modifier(NativeLiquidGlassModifier(cornerRadius: cornerRadius))
    }
}

// MARK: - 15. 随机先手轮盘抽签

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
                            
                            Text(PlayerPreset.names[pIdx])
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
            .nativeLiquidGlass(cornerRadius: 28)
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

// MARK: - 16. Emoji 选择器 Sheet

struct EmojiPickerSheet: View {
    @ObservedObject var game: GameModel
    let playerIndex: Int
    @Environment(\.dismiss) private var dismiss
    @State private var customEmojiText: String = ""
    @State private var errorMessage: String? = nil
    
    var body: some View {
        NavigationView {
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
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.blue.opacity(0.8)))
                }
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
                    
                    Button("设定") {
                        let trimmed = customEmojiText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            if game.tryUpdatePlayerEmoji(at: playerIndex, newEmoji: String(trimmed.prefix(1))) {
                                dismiss()
                            } else {
                                errorMessage = "该 Emoji 已被占用！"
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                
                Spacer()
            }
            .navigationTitle("选择 \(PlayerPreset.names[playerIndex]) 的棋子样式")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("取消") { dismiss() }
            }
        }
    }
}

// MARK: - 17. 主界面 ContentView 与 StartMenuView

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
                GamePlayView(game: game, isGameStarted: $isGameStarted)
            } else {
                StartMenuView(
                    game: game,
                    isGameStarted: $isGameStarted,
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

struct StartMenuView: View {
    @ObservedObject var game: GameModel
    @ObservedObject private var monitor = PerformanceMonitor.shared
    @Binding var isGameStarted: Bool
    @Binding var isSpinningRandomWheel: Bool
    @State private var selectedPlayerForEmoji: Int? = nil
    
    var isPlayerCountValid: Bool {
        game.activePlayerIndices.count >= 2
    }
    
    var body: some View {
        VStack(spacing: 20) {
            Text("COLOR WAR")
                .font(.system(size: 38, weight: .black, design: .rounded))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.white, .white.opacity(0.65)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            
            VStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    ModelStatusRow(name: "ColorWarAI (5通道)",
                                   isReady: monitor.isModel1Ready,
                                   message: monitor.model1Message)
                    ModelStatusRow(name: "colorwar_12x12 (4通道)",
                                   isReady: monitor.isModel2Ready,
                                   message: monitor.model2Message)
                }
                .padding(10)
                .background(Color.white.opacity(0.08))
                .cornerRadius(12)
                
                HStack {
                    Text("网格尺寸")
                        .foregroundColor(.white.opacity(0.85))
                        .font(.headline)
                    
                    Spacer()
                    
                    Text("\(game.boardSize) × \(game.boardSize)")
                        .font(.system(.title3, design: .rounded))
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                }
                
                Slider(
                    value: Binding<Double>(
                        get: { Double(game.boardSize) },
                        set: { game.boardSize = Int($0) }
                    ),
                    in: 5...12,
                    step: 1
                )
                .tint(.white)
                
                Divider().background(Color.white.opacity(0.2))
                
                Toggle(isOn: $game.isRandomFirstPlayer) {
                    HStack {
                        Image(systemName: "shuffle")
                            .foregroundColor(.yellow)
                        Text("随机挑选先手玩家")
                            .foregroundColor(.white)
                            .font(.subheadline)
                            .bold()
                    }
                }
                .tint(.blue)
                
                // 💡 修改 1：设置菜单中增加“性能监控悬浮窗”开关
                Toggle(isOn: $game.showPerformanceOverlay) {
                    HStack {
                        Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                            .foregroundColor(.cyan)
                        Text("显示 CPU/NPU 性能监控")
                            .foregroundColor(.white)
                            .font(.subheadline)
                            .bold()
                    }
                }
                .tint(.blue)
            }
            .padding()
            .nativeLiquidGlass(cornerRadius: 16)
            .frame(maxWidth: 420)
            
            ScrollView {
                VStack(spacing: 12) {
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
                            
                            Text(PlayerPreset.names[idx])
                                .foregroundColor(.white)
                                .font(.subheadline)
                                .bold()
                            
                            Spacer()
                            
                            Picker("Player Type", selection: $game.playerTypes[idx]) {
                                ForEach(PlayerControlType.allCases) { type in
                                    Text(type.rawValue).tag(type)
                                }
                            }
                            .pickerStyle(.menu)
                            .tint(.white)
                        }
                        .padding(.horizontal, 8)
                    }
                }
            }
            .padding()
            .frame(maxHeight: 240)
            .nativeLiquidGlass(cornerRadius: 20)
            .frame(maxWidth: 420)
            
            if !isPlayerCountValid {
                Text("⚠️ 请至少保留 2 位参赛玩家")
                    .font(.caption)
                    .foregroundColor(.yellow)
                    .bold()
            }
            
            Button(action: {
                guard isPlayerCountValid else { return }
                if game.isRandomFirstPlayer {
                    isSpinningRandomWheel = true
                } else {
                    game.resetGame()
                    withAnimation(.spring()) { isGameStarted = true }
                }
            }) {
                HStack {
                    Image(systemName: "play.fill")
                    Text("开始对决")
                        .font(.title3)
                        .bold()
                }
                .foregroundColor(.white)
                .padding(.vertical, 14)
                .frame(maxWidth: 320)
            }
            .nativeLiquidGlass(cornerRadius: 28)
            .opacity(isPlayerCountValid ? 1.0 : 0.4)
            .disabled(!isPlayerCountValid)
        }
        .padding()
        // 💡 修改 2：监控面板调至左上方，避免遮挡设置按钮
        .overlay(
            Group {
                if game.showPerformanceOverlay {
                    PerformanceOverlayView()
                        .padding(.top, 16)
                        .padding(.leading, 16)
                }
            },
            alignment: .topLeading
        )
        .onAppear {
            NeuralAISolver.shared.reloadModels()
        }
        .sheet(item: Binding<Int?>(
            get: { selectedPlayerForEmoji },
            set: { selectedPlayerForEmoji = $0 }
        )) { idx in
            EmojiPickerSheet(game: game, playerIndex: idx)
        }
    }
}

extension Int: @retroactive Identifiable {
    public var id: Int { self }
}

// MARK: - 18. 对局视图与胜利结算 Overlay

struct GamePlayView: View {
    @ObservedObject var game: GameModel
    @ObservedObject private var monitor = PerformanceMonitor.shared
    @Binding var isGameStarted: Bool
    
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
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 15, weight: .bold))
                            Text("菜单")
                                .font(.system(size: 15, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    }
                    .nativeLiquidGlass(cornerRadius: 20)
                    
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
                        
                        Text("\(PlayerPreset.names[game.currentPlayer]) 回合")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .nativeLiquidGlass(cornerRadius: 20)
                    
                    Spacer()
                    
                    Button(action: { game.showControlSheet = true }) {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(11)
                    }
                    .nativeLiquidGlass(cornerRadius: 20)
                }
                .padding(.horizontal, 8)
                
                if let warning = monitor.activeWarning {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                        Text(warning)
                            .font(.caption.bold())
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.red.opacity(0.8))
                    .cornerRadius(16)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                
                Spacer()
                
                BoardView(game: game)
                
                Spacer()
            }
            .padding()
            
            if let wIdx = game.winnerIndex {
                Color.black.opacity(0.8)
                    .ignoresSafeArea()
                
                VStack(spacing: 24) {
                    ZStack {
                        Circle()
                            .fill(game.colors[wIdx].opacity(0.3))
                            .frame(width: 90, height: 90)
                        
                        Circle()
                            .stroke(game.colors[wIdx], lineWidth: 3)
                            .frame(width: 80, height: 80)
                        
                        if let em = game.emojis[wIdx], !em.isEmpty {
                            Text(em)
                                .font(.system(size: 42))
                        } else {
                            Image(systemName: "crown.fill")
                                .font(.system(size: 38))
                                .foregroundColor(.yellow)
                        }
                    }
                    
                    Text("\(PlayerPreset.names[wIdx]) 获得胜利！")
                        .font(.title)
                        .bold()
                        .foregroundColor(.white)
                    
                    HStack(spacing: 16) {
                        // 💡 修改 3：胜利结算弹窗按钮全量采用液态玻璃材质（.nativeLiquidGlass）
                        Button(action: {
                            game.resetGame()
                        }) {
                            HStack {
                                Image(systemName: "arrow.clockwise")
                                Text("再来一局")
                            }
                            .font(.headline)
                            .foregroundColor(.white)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                        }
                        .nativeLiquidGlass(cornerRadius: 24)
                        
                        Button(action: {
                            game.exitToMenu()
                            withAnimation(.spring()) {
                                isGameStarted = false
                            }
                        }) {
                            Text("返回主菜单")
                                .font(.headline)
                                .foregroundColor(.white.opacity(0.9))
                                .padding(.horizontal, 20)
                                .padding(.vertical, 12)
                        }
                        .nativeLiquidGlass(cornerRadius: 24)
                    }
                }
                .padding(32)
                .nativeLiquidGlass(cornerRadius: 28)
                .frame(maxWidth: 380)
                .transition(.scale.combined(with: .opacity))
            }
        }
        // 💡 修改 2：对局界面监控悬浮窗放置在左上方（在左侧返回菜单按钮下方呈列，不挡右侧设置与圆圈提示）
        .overlay(
            Group {
                if game.showPerformanceOverlay {
                    PerformanceOverlayView()
                        .padding(.top, 64)
                        .padding(.leading, 16)
                }
            },
            alignment: .topLeading
        )
        .sheet(isPresented: $game.showControlSheet) {
            PlayerTakeoverSheet(game: game)
        }
    }
}

// MARK: - 19. 控制面板 Sheet

struct PlayerTakeoverSheet: View {
    @ObservedObject var game: GameModel
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            List {
                Section {
                    Button(action: {
                        game.resetGame()
                        dismiss()
                    }) {
                        HStack {
                            Spacer()
                            Image(systemName: "arrow.clockwise.circle.fill")
                                .font(.title3)
                            Text("重新开始本局")
                                .font(.headline)
                                .bold()
                            Spacer()
                        }
                        .foregroundColor(.red)
                    }
                }
                
                Section(header: Text("实时接管控制（AI 代打）")) {
                    ForEach(game.activePlayerIndices, id: \.self) { idx in
                        HStack {
                            Circle()
                                .fill(game.colors[idx])
                                .frame(width: 16, height: 16)
                            
                            Text(PlayerPreset.names[idx])
                                .font(.body)
                            
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
    }
}

// MARK: - 20. 性能监控悬浮窗 (CPU 与 NPU 联合监控)

struct PerformanceOverlayView: View {
    @ObservedObject var monitor = PerformanceMonitor.shared
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("CPU 占用:")
                Spacer()
                Text(String(format: "%.1f%%", monitor.cpuUsage))
                    .bold()
                    .foregroundColor(monitor.cpuUsage > 80.0 ? .red : .green)
            }
            HStack {
                Text("NPU 延时:")
                Spacer()
                Text(String(format: "%.2f ms", monitor.npuLatencyMs))
                    .bold()
                    .foregroundColor(.cyan)
            }
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(8)
        .background(Color.black.opacity(0.75))
        .cornerRadius(8)
        .frame(width: 145)
    }
}
