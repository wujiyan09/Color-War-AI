import SwiftUI
import CoreML
import QuartzCore

// MARK: - 玩家类型与 AI 选牌枚举
enum PlayerType: String, CaseIterable, Identifiable, Sendable {
    case human = "真人"
    case disabled = "不参加"
    // CoreML / NPU 神经网络
    case colorWarAI = "ColorWarAI (NPU)"
    case colorWar12x12 = "12x12 (NPU)"
    // 纯数学算法
    case mathEasy = "算法-简单"
    case mathNormal = "算法-正常"
    case mathHard = "算法-困难"
    case mathExpert = "算法-专家"
    case mathUltimate = "算法-终极"
    case mathNightmare = "算法-噩梦"
    
    var id: String { rawValue }
    
    var isAI: Bool { self != .human && self != .disabled }
    var isNeuralAI: Bool { self == .colorWarAI || self == .colorWar12x12 }
    var isMathAI: Bool { isAI && !isNeuralAI }
}

// MARK: - 基础数据模型
struct Cell: Equatable, Sendable {
    var owner: Int?
    var count = 0
}

struct FlyingOrb: Identifiable, Equatable, Sendable {
    let id = UUID()
    let fromRow: Int
    let fromColumn: Int
    let toRow: Int
    let toColumn: Int
    let player: Int
    var arrived = false
}

// MARK: - 性能与诊断监控单例
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
    
    // 获取当前进程的 CPU 使用率 (%)
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

// MARK: - Core ML 神经网络引擎 (NPU/GPU)
final class NeuralAISolver: @unchecked Sendable {
    static let shared = NeuralAISolver()
    
    private var modelColorWarAI: MLModel?
    private var reuseInputArray1: MLMultiArray? // [1, 5, 12, 12]
    
    private var model12x12: MLModel?
    private var reuseInputArray2: MLMultiArray? // [1, 4, 12, 12]
    
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
        if let url = Bundle.main.url(forResource: name, withExtension: "mlmodelc") {
            if let m = try? MLModel(contentsOf: url, configuration: config) { return (m, "OK") }
        }
        let allCompiled = Bundle.main.urls(forResourcesWithExtension: "mlmodelc", subdirectory: nil) ?? []
        if let matchedURL = allCompiled.first(where: { $0.deletingPathExtension().lastPathComponent == name }) {
            if let m = try? MLModel(contentsOf: matchedURL, configuration: config) { return (m, "OK") }
        }
        if let rawURL = Bundle.main.url(forResource: name, withExtension: "mlmodel") {
            if let compiledURL = try? MLModel.compileModel(at: rawURL),
               let m = try? MLModel(contentsOf: compiledURL, configuration: config) {
                return (m, "OK")
            }
        }
        return nil
    }
    
    func getBestMove(board: [[AISolver.SimCell]], currentPlayer: Int, playerType: PlayerType, validMoves: [(Int, Int)]) -> (Int, Int)? {
        guard !validMoves.isEmpty else { return nil }
        guard !board.isEmpty && !board[0].isEmpty else { return validMoves.randomElement() }
        
        let isModel1 = (playerType == .colorWarAI)
        let activeModel = isModel1 ? modelColorWarAI : model12x12
        let inputArray = isModel1 ? reuseInputArray1 : reuseInputArray2
        
        guard let model = activeModel, let inputArray = inputArray else {
            Task { @MainActor in PerformanceMonitor.shared.activeWarning = "⚠️ \(playerType.rawValue) 未加载，降级为随机落子" }
            return validMoves.randomElement()
        }
        
        let rows = board.count, cols = board[0].count
        if rows > 12 || cols > 12 {
            Task { @MainActor in PerformanceMonitor.shared.activeWarning = "⚠️ 棋盘尺寸超出神经网络限制" }
            return validMoves.randomElement()
        }
        
        lock.lock()
        defer { lock.unlock() }
        
        do {
            let maxDim = 12, channelStride = 144
            let numChannels = isModel1 ? 5 : 4
            let totalElements = numChannels * 144
            
            let ptr = inputArray.dataPointer.bindMemory(to: Float.self, capacity: totalElements)
            memset(ptr, 0, totalElements * MemoryLayout<Float>.stride)
            
            for r in 0..<rows {
                for c in 0..<cols {
                    let cell = board[r][c]
                    if let owner = cell.owner {
                        let relativeChannel = (owner - currentPlayer + 4) % 4
                        let idx = (relativeChannel * channelStride) + (r * maxDim) + c
                        ptr[idx] = Float(cell.count) / 4.0
                    }
                }
            }
            
            if isModel1 {
                let maskOffset = 4 * channelStride
                for (r, c) in validMoves { ptr[maskOffset + (r * maxDim) + c] = 1.0 }
            }
            
            let startTime = CACurrentMediaTime()
            let inputKey = model.modelDescription.inputDescriptionsByName.keys.first ?? "board_input"
            let inputProvider = try MLDictionaryFeatureProvider(dictionary: [inputKey: inputArray])
            let prediction = try model.prediction(from: inputProvider)
            
            let elapsedTimeMs = (CACurrentMediaTime() - startTime) * 1000.0
            Task { @MainActor in
                PerformanceMonitor.shared.updateNPULatency(elapsedTimeMs)
                PerformanceMonitor.shared.activeWarning = nil
            }
            
            let outputKey = model.modelDescription.outputDescriptionsByName.keys.first ?? "policy_logits"
            guard let logits = (prediction.featureValue(for: outputKey) ?? prediction.featureValue(for: "policy_logits") ?? prediction.featureValue(for: "logits"))?.multiArrayValue else {
                Task { @MainActor in PerformanceMonitor.shared.activeWarning = "❌ 模型缺少 policy_logits 输出节点" }
                return validMoves.randomElement()
            }
            
            let logitsPtr = logits.dataPointer.bindMemory(to: Float.self, capacity: 144)
            var bestMove = validMoves[0]
            var maxScore: Float = -Float.greatestFiniteMagnitude
            
            for (r, c) in validMoves {
                let idx = r * maxDim + c
                let score = logitsPtr[idx]
                if score > maxScore {
                    maxScore = score
                    bestMove = (r, c)
                }
            }
            return bestMove
            
        } catch {
            let errorMsg = error.localizedDescription
            Task { @MainActor in PerformanceMonitor.shared.activeWarning = "❌ CoreML 推理失败: \(errorMsg)" }
            return validMoves.randomElement()
        }
    }
}

// MARK: - 统一 AI 解算器 (融合神经网络与经典数学算法)
struct AISolver: Sendable {
    struct SimCell: Sendable {
        var owner: Int?
        var count: Int
    }
    
    struct MoveKey: Hashable, Sendable {
        let r: Int
        let c: Int
    }
    
    final class MCTSNode {
        let move: (Int, Int)?
        let player: Int
        weak var parent: MCTSNode?
        var children: [MCTSNode] = []
        var visits: Int = 0
        var wins: Double = 0.0
        
        var boardState: [[SimCell]]
        var unvisitedMoves: [(Int, Int)]
        var hasEnteredState: [Bool]
        var eliminatedState: [Bool]
        
        var isFullyExpanded: Bool { unvisitedMoves.isEmpty }
        
        init(move: (Int, Int)?, player: Int, board: [[SimCell]], unvisitedMoves: [(Int, Int)], hasEntered: [Bool], eliminated: [Bool], parent: MCTSNode? = nil) {
            self.move = move
            self.player = player
            self.boardState = board
            self.unvisitedMoves = unvisitedMoves
            self.hasEnteredState = hasEntered
            self.eliminatedState = eliminated
            self.parent = parent
        }
        
        func selectBestChildUCB(c: Double = 1.414) -> MCTSNode? {
            let logTotal = log(Double(max(visits, 1)))
            return children.max { a, b in
                let scoreA = (a.wins / Double(max(a.visits, 1))) + c * sqrt(logTotal / Double(max(a.visits, 1)))
                let scoreB = (b.wins / Double(max(b.visits, 1))) + c * sqrt(logTotal / Double(max(b.visits, 1)))
                return scoreA < scoreB
            }
        }
    }
    
    let boardSize: Int
    let playerCount: Int
    let currentPlayer: Int
    let playerType: PlayerType
    let board: [[SimCell]]
    let hasEntered: [Bool]
    let eliminated: [Bool]
    
    init(boardSize: Int, playerCount: Int, currentPlayer: Int, playerType: PlayerType, board: [[Cell]], hasEntered: [Bool], eliminated: [Bool]) {
        self.boardSize = boardSize
        self.playerCount = playerCount
        self.currentPlayer = currentPlayer
        self.playerType = playerType
        self.board = board.map { row in row.map { SimCell(owner: $0.owner, count: $0.count) } }
        self.hasEntered = hasEntered
        self.eliminated = eliminated
    }
    
    func calculateBestMove() async -> (Int, Int)? {
        var validMoves = getPlayableCells(for: currentPlayer, on: board)
        guard !validMoves.isEmpty else { return nil }
        
        // 1. 如果是神经网络 AI，直接走 NPU/GPU 推理
        if playerType.isNeuralAI {
            return NeuralAISolver.shared.getBestMove(board: board, currentPlayer: currentPlayer, playerType: playerType, validMoves: validMoves)
        }
        
        // 2. 开局候选解空间剪枝
        let totalOrbs = board.joined().reduce(0) { $0 + $1.count }
        if totalOrbs < 6 {
            let prunedMoves = validMoves.filter { r, c in
                let isCorner = (r == 0 || r == boardSize - 1) && (c == 0 || c == boardSize - 1)
                let isEdge = r == 0 || r == boardSize - 1 || c == 0 || c == boardSize - 1
                let isCenter = (r >= boardSize / 2 - 1 && r <= boardSize / 2 + 1) && (c >= boardSize / 2 - 1 && c <= boardSize / 2 + 1)
                return isCorner || isEdge || isCenter
            }
            if !prunedMoves.isEmpty { validMoves = prunedMoves }
        }
        
        let isMultiplayer = playerCount > 2
        
        // 3. 经典数学算法调度
        switch playerType {
        case .mathEasy:
            return validMoves.randomElement()
        case .mathNormal:
            return validMoves.max { evaluateSingleMoveHeuristic($0, on: board) < evaluateSingleMoveHeuristic($1, on: board) }
        case .mathHard:
            return isMultiplayer ? await runMCTS(iterations: 600, isBiased: false, validMoves: validMoves) : getBestMinimaxMove(depth: 2, validMoves: validMoves)
        case .mathExpert:
            return isMultiplayer ? await runMCTS(iterations: 1200, isBiased: true, validMoves: validMoves) : getBestMinimaxMove(depth: 3, validMoves: validMoves)
        case .mathUltimate:
            return await runMCTS(iterations: 1500, isBiased: true, validMoves: validMoves)
        case .mathNightmare:
            return isMultiplayer ? await runMCTS(iterations: 3000, isBiased: true, validMoves: validMoves) : calculateNightmareMove(validMoves: validMoves)
        default:
            return validMoves.randomElement()
        }
    }
    
    // MARK: - Minimax 算法与 Alpha-Beta 剪枝 (噩梦/困难)
    private func calculateNightmareMove(validMoves: [(Int, Int)]) -> (Int, Int)? {
        let sortedMoves = validMoves.sorted { evaluateTacticalMoveScore($0, on: board, player: currentPlayer) > evaluateTacticalMoveScore($1, on: board, player: currentPlayer) }
        var bestScore = Int.min, bestMove = sortedMoves.first
        let searchDepth = boardSize <= 7 ? 5 : 4
        
        for move in sortedMoves {
            if Task.isCancelled { break }
            let score = minimaxNightmare(boardState: board, hasEnteredState: hasEntered, eliminatedState: eliminated, move: move, depth: searchDepth, alpha: Int.min + 1, beta: Int.max - 1, isMaximizing: false, actingPlayer: currentPlayer)
            if score > bestScore { bestScore = score; bestMove = move }
        }
        return bestMove
    }
    
    private func minimaxNightmare(boardState: [[SimCell]], hasEnteredState: [Bool], eliminatedState: [Bool], move: (Int, Int), depth: Int, alpha: Int, beta: Int, isMaximizing: Bool, actingPlayer: Int) -> Int {
        if Task.isCancelled { return 0 }
        var simBoard = boardState, simEntered = hasEnteredState, simEliminated = eliminatedState
        
        simulateMoveBFS(on: &simBoard, move: move, player: actingPlayer, hasEntered: &simEntered)
        updateEliminatedStatus(board: simBoard, hasEntered: simEntered, eliminated: &simEliminated)
        
        if depth == 1 || isGameOverSimulated(eliminated: simEliminated) {
            return evaluateNightmareBoard(simBoard, forPlayer: currentPlayer, eliminated: simEliminated)
        }
        
        let nextPlayer = getNextPlayerSimulated(current: actingPlayer, eliminated: simEliminated)
        let validNextMoves = getPlayableCells(for: nextPlayer, on: simBoard)
        if validNextMoves.isEmpty { return evaluateNightmareBoard(simBoard, forPlayer: currentPlayer, eliminated: simEliminated) }
        
        let sortedNextMoves = validNextMoves.sorted { evaluateTacticalMoveScore($0, on: simBoard, player: nextPlayer) > evaluateTacticalMoveScore($1, on: simBoard, player: nextPlayer) }
        var currentAlpha = alpha, currentBeta = beta
        
        if isMaximizing {
            var maxEval = Int.min
            for nextMove in sortedNextMoves {
                let eval = minimaxNightmare(boardState: simBoard, hasEnteredState: simEntered, eliminatedState: simEliminated, move: nextMove, depth: depth - 1, alpha: currentAlpha, beta: currentBeta, isMaximizing: false, actingPlayer: nextPlayer)
                maxEval = max(maxEval, eval)
                currentAlpha = max(currentAlpha, eval)
                if currentBeta <= currentAlpha { break }
            }
            return maxEval
        } else {
            var minEval = Int.max
            for nextMove in sortedNextMoves {
                let eval = minimaxNightmare(boardState: simBoard, hasEnteredState: simEntered, eliminatedState: simEliminated, move: nextMove, depth: depth - 1, alpha: currentAlpha, beta: currentBeta, isMaximizing: true, actingPlayer: nextPlayer)
                minEval = min(minEval, eval)
                currentBeta = min(currentBeta, eval)
                if currentBeta <= currentAlpha { break }
            }
            return minEval
        }
    }
    
    private func getBestMinimaxMove(depth: Int, validMoves: [(Int, Int)]) -> (Int, Int)? {
        var bestScore = Int.min, bestMove = validMoves.randomElement()
        for move in validMoves {
            if Task.isCancelled { break }
            let score = minimaxRecursive(boardState: board, hasEnteredState: hasEntered, eliminatedState: eliminated, move: move, depth: depth, alpha: Int.min, beta: Int.max, isMaximizing: false, actingPlayer: currentPlayer)
            if score > bestScore { bestScore = score; bestMove = move }
        }
        return bestMove
    }
    
    private func minimaxRecursive(boardState: [[SimCell]], hasEnteredState: [Bool], eliminatedState: [Bool], move: (Int, Int), depth: Int, alpha: Int, beta: Int, isMaximizing: Bool, actingPlayer: Int) -> Int {
        if Task.isCancelled { return 0 }
        var simBoard = boardState, simEntered = hasEnteredState, simEliminated = eliminatedState
        
        simulateMoveBFS(on: &simBoard, move: move, player: actingPlayer, hasEntered: &simEntered)
        updateEliminatedStatus(board: simBoard, hasEntered: simEntered, eliminated: &simEliminated)
        
        if depth == 1 || isGameOverSimulated(eliminated: simEliminated) {
            return evaluateEnhancedBoard(simBoard, forPlayer: currentPlayer, eliminated: simEliminated)
        }
        
        let nextPlayer = getNextPlayerSimulated(current: actingPlayer, eliminated: simEliminated)
        let validNextMoves = getPlayableCells(for: nextPlayer, on: simBoard)
        if validNextMoves.isEmpty { return evaluateEnhancedBoard(simBoard, forPlayer: currentPlayer, eliminated: simEliminated) }
        
        var currentAlpha = alpha, currentBeta = beta
        if isMaximizing {
            var maxEval = Int.min
            for nextMove in validNextMoves {
                let eval = minimaxRecursive(boardState: simBoard, hasEnteredState: simEntered, eliminatedState: simEliminated, move: nextMove, depth: depth - 1, alpha: currentAlpha, beta: currentBeta, isMaximizing: false, actingPlayer: nextPlayer)
                maxEval = max(maxEval, eval)
                currentAlpha = max(currentAlpha, eval)
                if currentBeta <= currentAlpha { break }
            }
            return maxEval
        } else {
            var minEval = Int.max
            for nextMove in validNextMoves {
                let eval = minimaxRecursive(boardState: simBoard, hasEnteredState: simEntered, eliminatedState: simEliminated, move: nextMove, depth: depth - 1, alpha: currentAlpha, beta: currentBeta, isMaximizing: true, actingPlayer: nextPlayer)
                minEval = min(minEval, eval)
                currentBeta = min(currentBeta, eval)
                if currentBeta <= currentAlpha { break }
            }
            return minEval
        }
    }
    
    // MARK: - 并发 MCTS (蒙特卡洛树搜索 + UCB1)
    private func runMCTS(iterations: Int, isBiased: Bool, validMoves: [(Int, Int)]) async -> (Int, Int)? {
        let taskCount = 4
        let iterationsPerTask = iterations / taskCount
        
        let mergedVisits = await withTaskGroup(of: [MoveKey: Int].self) { group in
            for _ in 0..<taskCount {
                group.addTask {
                    let root = MCTSNode(move: nil, player: self.currentPlayer, board: self.board, unvisitedMoves: validMoves, hasEntered: self.hasEntered, eliminated: self.eliminated)
                    
                    for _ in 0..<iterationsPerTask {
                        if Task.isCancelled { break }
                        var node = root
                        while node.isFullyExpanded && !node.children.isEmpty {
                            if let nextNode = node.selectBestChildUCB() { node = nextNode } else { break }
                        }
                        
                        if !node.unvisitedMoves.isEmpty {
                            let move = node.unvisitedMoves.remove(at: Int.random(in: 0..<node.unvisitedMoves.count))
                            var nextBoard = node.boardState, nextEntered = node.hasEnteredState, nextEliminated = node.eliminatedState
                            
                            self.simulateMoveBFS(on: &nextBoard, move: move, player: node.player, hasEntered: &nextEntered)
                            self.updateEliminatedStatus(board: nextBoard, hasEntered: nextEntered, eliminated: &nextEliminated)
                            
                            let nextPlayer = self.getNextPlayerSimulated(current: node.player, eliminated: nextEliminated)
                            let childMoves = self.getPlayableCells(for: nextPlayer, on: nextBoard)
                            let childNode = MCTSNode(move: move, player: nextPlayer, board: nextBoard, unvisitedMoves: childMoves, hasEntered: nextEntered, eliminated: nextEliminated, parent: node)
                            node.children.append(childNode)
                            node = childNode
                        }
                        
                        let winner = self.simulatePlayout(from: node, isBiased: isBiased)
                        var currNode: MCTSNode? = node
                        while let n = currNode {
                            n.visits += 1
                            if winner == self.currentPlayer { n.wins += 1.0 }
                            else if winner == nil { n.wins += 0.2 }
                            currNode = n.parent
                        }
                    }
                    var visits: [MoveKey: Int] = [:]
                    for child in root.children {
                        if let (r, c) = child.move { visits[MoveKey(r: r, c: c)] = child.visits }
                    }
                    return visits
                }
            }
            var totalVisits: [MoveKey: Int] = [:]
            for await taskVisits in group {
                for (move, visits) in taskVisits { totalVisits[move, default: 0] += visits }
            }
            return totalVisits
        }
        
        if let bestMoveKey = mergedVisits.max(by: { $0.value < $1.value })?.key {
            return (bestMoveKey.r, bestMoveKey.c)
        }
        return validMoves.randomElement()
    }
    
    private func simulatePlayout(from node: MCTSNode, isBiased: Bool) -> Int? {
        var simBoard = node.boardState, simEntered = node.hasEnteredState, simEliminated = node.eliminatedState
        var curr = node.player, step = 0
        let maxSteps = boardSize >= 9 ? 25 : 50
        
        while step < maxSteps {
            step += 1
            let moves = getPlayableCells(for: curr, on: simBoard)
            if moves.isEmpty {
                simEliminated[curr] = true
            } else {
                let move: (Int, Int)
                if isBiased && Double.random(in: 0...1) < 0.75 {
                    move = moves.max { evaluateSingleMoveHeuristic($0, on: simBoard) < evaluateSingleMoveHeuristic($1, on: simBoard) }!
                } else {
                    move = moves.randomElement()!
                }
                simulateMoveBFS(on: &simBoard, move: move, player: curr, hasEntered: &simEntered)
                updateEliminatedStatus(board: simBoard, hasEntered: simEntered, eliminated: &simEliminated)
            }
            let alive = (0..<playerCount).filter { !simEliminated[$0] }
            if alive.count <= 1 { return alive.first }
            curr = getNextPlayerSimulated(current: curr, eliminated: simEliminated)
        }
        var scores = Array(repeating: 0, count: playerCount)
        for r in 0..<boardSize {
            for c in 0..<boardSize {
                if let owner = simBoard[r][c].owner { scores[owner] += simBoard[r][c].count + (simBoard[r][c].count == 3 ? 5 : 0) }
            }
        }
        return scores.enumerated().max(by: { $0.element < $1.element })?.offset
    }
    
    // MARK: - BFS 连锁模拟与估值逻辑
    private func simulateMoveBFS(on simBoard: inout [[SimCell]], move: (Int, Int), player: Int, hasEntered: inout [Bool]) {
        let (r, c) = move
        let isFirst = !hasEntered[player]
        hasEntered[player] = true
        simBoard[r][c].owner = player
        simBoard[r][c].count += isFirst ? 3 : 1
        
        var queue: [(Int, Int)] = simBoard[r][c].count >= 4 ? [(r, c)] : []
        var head = 0
        let dynamicSafetyLimit = boardSize * boardSize * 6
        
        while head < queue.count && head < dynamicSafetyLimit {
            let (er, ec) = queue[head]
            head += 1
            if simBoard[er][ec].count < 4 { continue }
            simBoard[er][ec].count -= 4
            if simBoard[er][ec].count == 0 { simBoard[er][ec].owner = nil }
            
            for (nr, nc) in neighbors(of: er, ec) {
                simBoard[nr][nc].owner = player
                simBoard[nr][nc].count += 1
                if simBoard[nr][nc].count >= 4 { queue.append((nr, nc)) }
            }
        }
    }
    
    private func evaluateNightmareBoard(_ simBoard: [[SimCell]], forPlayer player: Int, eliminated: [Bool]) -> Int {
        if eliminated[player] { return -999999 }
        var score = 0, myOrbs = 0, enemyOrbs = 0
        
        for r in 0..<boardSize {
            for c in 0..<boardSize {
                let cell = simBoard[r][c]
                guard let owner = cell.owner else { continue }
                let isCorner = (r == 0 || r == boardSize - 1) && (c == 0 || c == boardSize - 1)
                let isEdge = r == 0 || r == boardSize - 1 || c == 0 || c == boardSize - 1
                
                var cellValue = cell.count * 15
                if isCorner { cellValue += 45 }
                else if isEdge { cellValue += 20 }
                
                if cell.count == 3 {
                    cellValue += 35
                    for (nr, nc) in neighbors(of: r, c) {
                        if let adjOwner = simBoard[nr][nc].owner, adjOwner != owner, simBoard[nr][nc].count == 3 {
                            if owner == player { cellValue += 50 } else { cellValue -= 60 }
                        }
                    }
                }
                
                if owner == player { myOrbs += cell.count; score += cellValue }
                else { enemyOrbs += cell.count; score -= Int(Double(cellValue) * 1.3) }
            }
        }
        let eliminatedEnemies = (0..<playerCount).filter { $0 != player && eliminated[$0] }.count
        return score + eliminatedEnemies * 50000 + (myOrbs - enemyOrbs) * 20
    }
    
    private func evaluateEnhancedBoard(_ simBoard: [[SimCell]], forPlayer player: Int, eliminated: [Bool]) -> Int {
        if eliminated[player] { return -99999 }
        var score = 0, myCount = 0, enemyCount = 0
        for r in 0..<boardSize {
            for c in 0..<boardSize {
                let cell = simBoard[r][c]
                guard let owner = cell.owner else { continue }
                let isCorner = (r == 0 || r == boardSize - 1) && (c == 0 || c == boardSize - 1)
                let isEdge = r == 0 || r == boardSize - 1 || c == 0 || c == boardSize - 1
                let posWeight = isCorner ? 20 : (isEdge ? 10 : 0)
                let val = cell.count * 10 + posWeight + (cell.count == 3 ? 25 : 0)
                if owner == player { myCount += cell.count; score += val }
                else { enemyCount += cell.count; score -= Int(Double(val) * 1.2) }
            }
        }
        return score + ((0..<playerCount).filter { $0 != player && eliminated[$0] }.count) * 1000 + (myCount - enemyCount) * 15
    }
    
    private func evaluateTacticalMoveScore(_ move: (Int, Int), on boardState: [[SimCell]], player: Int) -> Int {
        let (r, c) = move, cell = boardState[r][c]
        let isCorner = (r == 0 || r == boardSize - 1) && (c == 0 || c == boardSize - 1)
        var bonus = 0
        if cell.count == 3 { bonus += 100 }
        if isCorner { bonus += 50 }
        return bonus
    }
    
    private func evaluateSingleMoveHeuristic(_ move: (Int, Int), on boardState: [[SimCell]]) -> Int {
        let (r, c) = move
        let isCorner = (r == 0 || r == boardSize - 1) && (c == 0 || c == boardSize - 1)
        return (boardState[r][c].count == 3 ? 30 : 0) + (isCorner ? 15 : 0) + Int.random(in: 1...3)
    }
    
    private func updateEliminatedStatus(board: [[SimCell]], hasEntered: [Bool], eliminated: inout [Bool]) {
        for p in 0..<playerCount where hasEntered[p] && !eliminated[p] {
            if !board.joined().contains(where: { $0.owner == p }) { eliminated[p] = true }
        }
    }
    
    private func getNextPlayerSimulated(current: Int, eliminated: [Bool]) -> Int {
        var next = (current + 1) % playerCount, count = 0
        while eliminated[next] && count < playerCount { next = (next + 1) % playerCount; count += 1 }
        return next
    }
    
    private func getPlayableCells(for player: Int, on boardState: [[SimCell]]) -> [(Int, Int)] {
        var moves: [(Int, Int)] = []
        let ownsAny = boardState.joined().contains { $0.owner == player }
        for r in 0..<boardSize {
            for c in 0..<boardSize {
                let cell = boardState[r][c]
                if ownsAny ? cell.owner == player : cell.owner == nil { moves.append((r, c)) }
            }
        }
        return moves
    }
    
    private func isGameOverSimulated(eliminated: [Bool]) -> Bool { eliminated.filter { !$0 }.count <= 1 }
    private func neighbors(of row: Int, _ column: Int) -> [(Int, Int)] {
        [(-1,0), (1,0), (0,-1), (0,1)].compactMap { dr, dc in
            let r = row + dr, c = column + dc
            return (0..<boardSize).contains(r) && (0..<boardSize).contains(c) ? (r, c) : nil
        }
    }
}

// MARK: - GameModel
@MainActor
final class GameModel: ObservableObject {
    @Published private(set) var board: [[Cell]] = []
    @Published private(set) var boardSize = 9
    @Published private(set) var currentPlayer = 0
    @Published private(set) var winner: Int?
    @Published private(set) var isResolving = false
    @Published private(set) var emphasizedCells: Set<Int> = []
    @Published private(set) var flyingOrbs: [FlyingOrb] = []
    @Published private(set) var roulettePlayer = 0
    @Published private(set) var rouletteFinished = false
    @Published private(set) var isChoosingStarter = false
    @Published private(set) var playableCells: Set<Int> = []
    @Published var showMenu = true
    
    @Published var playerTypes: [PlayerType] = [.human, .colorWarAI, .mathNightmare, .disabled]
    
    private var starterTask: Task<Void, Never>?
    private var aiTask: Task<Void, Never>?
    private var moveTask: Task<Void, Never>?
    
    private var hasEntered = Array(repeating: false, count: 4)
    private var eliminated = Array(repeating: false, count: 4)
    private var turnNumber = 0
    
    let colors: [Color] = [.red, .blue, .green, .orange]
    let names = ["红方", "蓝方", "绿方", "橙方"]
    
    var activePlayers: [Int] { (0..<4).filter { playerTypes[$0] != .disabled } }
    
    init() { makeEmptyBoard() }
    
    private func makeEmptyBoard() {
        board = Array(repeating: Array(repeating: Cell(owner: nil), count: boardSize), count: boardSize)
    }
    
    private func cancelAllTasks() {
        starterTask?.cancel(); aiTask?.cancel(); moveTask?.cancel()
        starterTask = nil; aiTask = nil; moveTask = nil
    }
    
    private func rebuildPlayableCells() {
        guard !showMenu, !isChoosingStarter, winner == nil, !isResolving, !eliminated[currentPlayer] else {
            playableCells = []
            return
        }
        let ownsAny = board.joined().contains { $0.owner == currentPlayer }
        var result = Set<Int>()
        for row in 0..<boardSize {
            for column in 0..<boardSize {
                let cell = board[row][column]
                if ownsAny ? cell.owner == currentPlayer : cell.owner == nil {
                    result.insert(row * boardSize + column)
                }
            }
        }
        playableCells = result
    }
    
    func prepareGame(size: Int? = nil) {
        guard activePlayers.count >= 2 else { return }
        cancelAllTasks()
        PerformanceMonitor.shared.activeWarning = nil
        if let size { boardSize = min(12, max(5, size)) }
        makeEmptyBoard()
        currentPlayer = activePlayers.first ?? 0
        winner = nil; isResolving = false; emphasizedCells = []; flyingOrbs = []
        hasEntered = Array(repeating: false, count: 4)
        eliminated = Array(repeating: false, count: 4)
        turnNumber = 0; rouletteFinished = false; showMenu = false; playableCells = []
        starterTask = Task { await chooseStarter() }
    }
    
    func returnToMenu() {
        cancelAllTasks()
        PerformanceMonitor.shared.activeWarning = nil
        isChoosingStarter = false; isResolving = false; emphasizedCells = []; flyingOrbs = []; playableCells = []
        showMenu = true
        NeuralAISolver.shared.reloadModels()
    }
    
    private func chooseStarter() async {
        isChoosingStarter = true
        let active = activePlayers, selected = active.randomElement() ?? 0
        let totalTicks = 15 + Int.random(in: 0...5)
        
        do {
            var currIndex = 0
            for tick in 0..<totalTicks {
                try Task.checkCancellation()
                currIndex = (currIndex + 1) % active.count
                roulettePlayer = active[currIndex]
                let progress = Double(tick) / Double(totalTicks)
                try await Task.sleep(nanoseconds: UInt64((45 + Int(progress * progress * 140)) * 1_000_000))
            }
            while roulettePlayer != selected {
                try Task.checkCancellation()
                currIndex = (currIndex + 1) % active.count
                roulettePlayer = active[currIndex]
                try await Task.sleep(nanoseconds: 130_000_000)
            }
            currentPlayer = selected
            rouletteFinished = true
            try await Task.sleep(nanoseconds: 560_000_000)
            
            isChoosingStarter = false
            rebuildPlayableCells()
            triggerAIMoveIfNeeded()
        } catch { isChoosingStarter = false }
    }
    
    func play(row: Int, column: Int) {
        let index = row * boardSize + column
        guard !showMenu, !isChoosingStarter, winner == nil, !isResolving,
              !eliminated[currentPlayer], playableCells.contains(index),
              playerTypes[currentPlayer] == .human else { return }
        
        let player = currentPlayer
        aiTask?.cancel(); aiTask = nil; moveTask?.cancel()
        moveTask = Task { @MainActor in await resolveMove(row: row, column: column, player: player) }
    }
    
    private func resolveMove(row: Int, column: Int, player: Int) async {
        isResolving = true
        playableCells = []
        let isPlayersFirstMove = !hasEntered[player]
        hasEntered[player] = true
        
        do {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.62)) {
                board[row][column].owner = player
                board[row][column].count += isPlayersFirstMove ? 3 : 1
                emphasizedCells = [row * boardSize + column]
            }
            try await Task.sleep(nanoseconds: 210_000_000)
            
            var wave: [(Int, Int)] = []
            if board[row][column].count >= 4 { wave = [(row, column)] }
            
            while !wave.isEmpty {
                try Task.checkCancellation()
                let exploding = wave
                emphasizedCells = Set(exploding.map { $0.0 * boardSize + $0.1 })
                try await Task.sleep(nanoseconds: 85_000_000)
                
                var transfers: [FlyingOrb] = []
                for (r, c) in exploding {
                    for (nr, nc) in neighbors(of: r, c) { transfers.append(FlyingOrb(fromRow: r, fromColumn: c, toRow: nr, toColumn: nc, player: player)) }
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
                    for index in flyingOrbs.indices { flyingOrbs[index].arrived = true }
                }
                try await Task.sleep(nanoseconds: 165_000_000)
                
                var changed = Set<Int>()
                withAnimation(.spring(response: 0.18, dampingFraction: 0.68)) {
                    for orb in flyingOrbs {
                        board[orb.toRow][orb.toColumn].owner = player
                        board[orb.toRow][orb.toColumn].count += 1
                        changed.insert(orb.toRow * boardSize + orb.toColumn)
                    }
                    flyingOrbs = []; emphasizedCells = changed
                }
                try await Task.sleep(nanoseconds: 120_000_000)
                
                wave = changed.compactMap { index in
                    let r = index / boardSize, c = index % boardSize
                    return board[r][c].count >= 4 ? (r, c) : nil
                }
            }
            
            turnNumber += 1
            updateGameState()
            emphasizedCells = []; isResolving = false
            if winner == nil {
                advanceTurn()
                rebuildPlayableCells()
                triggerAIMoveIfNeeded()
            }
        } catch {
            isResolving = false; emphasizedCells = []; flyingOrbs = []; rebuildPlayableCells()
        }
    }
    
    private func neighbors(of row: Int, _ column: Int) -> [(Int, Int)] {
        [(-1,0), (1,0), (0,-1), (0,1)].compactMap { dr, dc in
            let r = row + dr, c = column + dc
            return (0..<boardSize).contains(r) && (0..<boardSize).contains(c) ? (r, c) : nil
        }
    }
    
    private func updateGameState() {
        let active = activePlayers
        guard active.allSatisfy({ hasEntered[$0] }) else { return }
        for player in active where hasEntered[player] {
            eliminated[player] = !board.joined().contains { $0.owner == player }
        }
        let alive = active.filter { !eliminated[$0] }
        if alive.count == 1 && turnNumber >= active.count { winner = alive[0] }
    }
    
    private func advanceTurn() {
        var next = (currentPlayer + 1) % 4
        while playerTypes[next] == .disabled || eliminated[next] { next = (next + 1) % 4 }
        currentPlayer = next
    }
    
    private func triggerAIMoveIfNeeded() {
        let pType = playerTypes[currentPlayer]
        guard winner == nil, !showMenu, !isChoosingStarter, !isResolving, pType.isAI else { return }
        
        let bSize = boardSize, activeCount = activePlayers.count
        let currP = currentPlayer, currentBoard = board
        let enteredState = hasEntered, elimState = eliminated
        
        aiTask?.cancel()
        aiTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
                guard !self.isResolving, self.winner == nil, self.currentPlayer == currP else { return }
                
                let bestMove = await Task.detached(priority: .userInitiated) {
                    let solver = AISolver(boardSize: bSize, playerCount: activeCount, currentPlayer: currP, playerType: pType, board: currentBoard, hasEntered: enteredState, eliminated: elimState)
                    return await solver.calculateBestMove()
                }.value
                
                try Task.checkCancellation()
                guard !self.showMenu, !self.isResolving, self.currentPlayer == currP else { return }
                
                if let (r, c) = bestMove {
                    self.moveTask?.cancel()
                    self.moveTask = Task { @MainActor in await self.resolveMove(row: r, column: c, player: currP) }
                }
            } catch {}
        }
    }
}

// MARK: - 主界面视图
struct ContentView: View {
    @StateObject private var game = GameModel()
    var body: some View {
        ZStack {
            background.ignoresSafeArea()
            if game.showMenu { StartMenuView(game: game) } else { GameView(game: game) }
        }
        .preferredColorScheme(.dark)
    }
    
    private var background: some View {
        let activeColor = game.showMenu ? Color.indigo : game.colors[game.currentPlayer]
        return ZStack {
            Color(red: 0.08, green: 0.08, blue: 0.10)
            activeColor.opacity(0.28).animation(.easeInOut(duration: 0.25), value: activeColor)
        }
    }
}

// MARK: - 菜单视图
struct StartMenuView: View {
    @ObservedObject var game: GameModel
    @ObservedObject private var monitor = PerformanceMonitor.shared
    @State private var boardSize = 9
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "circle.grid.3x3.fill").font(.system(size: 56)).symbolRenderingMode(.hierarchical)
            Text("Color War").font(.system(size: 36, weight: .bold, design: .rounded))
            
            VStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    ModelStatusRow(name: "ColorWarAI (5通道)", isReady: monitor.isModel1Ready, message: monitor.model1Message)
                    ModelStatusRow(name: "colorwar_12x12 (4通道)", isReady: monitor.isModel2Ready, message: monitor.model2Message)
                }
                .padding(12)
                .background(Color.white.opacity(0.05))
                .cornerRadius(12)
                
                Divider().background(Color.white.opacity(0.2))
                
                VStack(spacing: 10) {
                    ForEach(0..<4, id: \.self) { p in
                        HStack {
                            Circle().fill(game.colors[p]).frame(width: 12, height: 12)
                            Text(game.names[p]).font(.subheadline.bold())
                            Spacer()
                            
                            Picker("", selection: $game.playerTypes[p]) {
                                ForEach(PlayerType.allCases) { type in Text(type.rawValue).tag(type) }
                            }
                            .pickerStyle(.menu)
                            .buttonStyle(.bordered)
                            .tint(typeColor(game.playerTypes[p]))
                        }
                    }
                }
                
                VStack(spacing: 6) {
                    HStack {
                        Text("棋盘大小").font(.subheadline).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(boardSize) × \(boardSize)").font(.subheadline.monospacedDigit().bold())
                    }
                    Slider(value: Binding(get: { Double(boardSize) }, set: { boardSize = Int($0) }), in: 5...12, step: 1)
                        .tint(.indigo)
                }
                
                Button { game.prepareGame(size: boardSize) } label: {
                    Label("抽取先手并开始", systemImage: "shuffle").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(.indigo)
                .disabled(game.activePlayers.count < 2)
            }
            .padding(18)
            .glassPanel(cornerRadius: 24)
            .frame(maxWidth: 440)
        }
        .padding(20)
        .overlay(PerformanceOverlayView().padding(.top, 16).padding(.trailing, 16), alignment: .topTrailing)
        .onAppear { NeuralAISolver.shared.reloadModels() }
    }
    
    private func typeColor(_ type: PlayerType) -> Color {
        if type == .human { return .green }
        if type == .disabled { return .gray }
        if type.isNeuralAI { return .orange }
        return .cyan
    }
}

struct ModelStatusRow: View {
    let name: String, isReady: Bool, message: String
    var body: some View {
        HStack {
            Image(systemName: isReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill").foregroundStyle(isReady ? .green : .red)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.caption.bold())
                Text(message).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

// MARK: - 游戏界面与组件
struct GameView: View {
    @ObservedObject var game: GameModel
    @ObservedObject private var monitor = PerformanceMonitor.shared
    
    var body: some View {
        GeometryReader { proxy in
            let boardSide = min(proxy.size.width - 30, proxy.size.height - 115, 730)
            ZStack {
                VStack(spacing: 10) {
                    HStack {
                        Button(action: game.returnToMenu) { Image(systemName: "chevron.left") }.buttonStyle(.bordered).clipShape(Circle())
                        Spacer()
                        Text("\(game.names[game.currentPlayer]) (\(game.playerTypes[game.currentPlayer].rawValue)) 回合 · \(game.boardSize)×\(game.boardSize)")
                            .font(.headline).padding(.horizontal, 16).padding(.vertical, 10).glassPanel(cornerRadius: 22)
                        Spacer()
                        Button { game.prepareGame(size: game.boardSize) } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.bordered).clipShape(Circle())
                    }.frame(maxWidth: boardSide)
                    
                    if let warning = monitor.activeWarning {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                            Text(warning).font(.caption.bold()).foregroundStyle(.white)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Color.red.opacity(0.85)).cornerRadius(8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    
                    BoardView(game: game).frame(width: boardSide, height: boardSide)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity).padding(12)
                
                PlayerCornerIndicators(game: game).allowsHitTesting(false)
                if game.isChoosingStarter { StarterRouletteView(game: game) }
            }
        }
        .overlay(PerformanceOverlayView().padding(.top, 16).padding(.trailing, 16), alignment: .topTrailing)
        .overlay { if let winner = game.winner { WinnerView(game: game, player: winner) } }
    }
}

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
                                
                                CellView(cell: cell, color: cell.owner.map { game.colors[$0] }, active: game.emphasizedCells.contains(index))
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
                    GlassPiece(color: game.colors[orb.player], count: 1, size: max(8, side * 0.40))
                        .position(
                            x: 6 + side / 2 + CGFloat(orb.arrived ? orb.toColumn : orb.fromColumn) * (side + gap),
                            y: 6 + side / 2 + CGFloat(orb.arrived ? orb.toRow : orb.fromRow) * (side + gap)
                        )
                        .zIndex(10).allowsHitTesting(false)
                }
            }
            .glassPanel(cornerRadius: 24)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

struct CellView: View, Equatable {
    let cell: Cell, color: Color?, active: Bool
    static func == (lhs: CellView, rhs: CellView) -> Bool {
        lhs.cell == rhs.cell && lhs.color == rhs.color && lhs.active == rhs.active
    }
    
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                RoundedRectangle(cornerRadius: max(4, proxy.size.width * 0.17), style: .continuous)
                    .fill(Color.white.opacity(0.05))
                    .overlay(RoundedRectangle(cornerRadius: max(4, proxy.size.width * 0.17)).stroke(Color.white.opacity(0.12), lineWidth: 0.7))
                
                if cell.count > 0 {
                    GlassPiece(color: color ?? .clear, count: cell.count, size: proxy.size.width * 0.76)
                        .scaleEffect(active ? 1.09 : 1)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.21, dampingFraction: 0.62), value: cell.count)
            .animation(.spring(response: 0.18, dampingFraction: 0.65), value: active)
        }
    }
}

struct GlassPiece: View {
    let color: Color, count: Int, size: CGFloat
    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [color.opacity(0.95), color.opacity(0.65)], startPoint: .topLeading, endPoint: .bottomTrailing))
            DotPattern(count: min(4, max(0, count)), diameter: size * 0.16)
        }
        .frame(width: size, height: size)
        .overlay(Circle().stroke(Color.white.opacity(0.4), lineWidth: max(0.5, size * 0.04)))
        .shadow(color: color.opacity(0.4), radius: size * 0.1, y: size * 0.03)
        .accessibilityHidden(true)
    }
}

struct DotPattern: View {
    let count: Int, diameter: CGFloat
    var body: some View {
        ZStack {
            ForEach(0..<count, id: \.self) { index in
                Circle().fill(.white).frame(width: diameter, height: diameter)
                    .offset(offset(index)).transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.20, dampingFraction: 0.60), value: count)
    }
    
    private func offset(_ index: Int) -> CGSize {
        let d = diameter * 0.86
        switch count {
        case 0, 1: return .zero
        case 2: return CGSize(width: index == 0 ? -d : d, height: 0)
        case 3: return [CGSize(width: 0, height: -d), CGSize(width: -d, height: d), CGSize(width: d, height: d)][index]
        default: return [CGSize(width: -d, height: -d), CGSize(width: d, height: -d), CGSize(width: -d, height: d), CGSize(width: d, height: d)][index]
        }
    }
}

struct PlayerCornerIndicators: View {
    @ObservedObject var game: GameModel
    private let positions: [(Alignment, Edge.Set)] = [
        (.topLeading, [.top, .leading]), (.topTrailing, [.top, .trailing]),
        (.bottomTrailing, [.bottom, .trailing]), (.bottomLeading, [.bottom, .leading])
    ]
    var body: some View {
        ZStack {
            ForEach(0..<4, id: \.self) { player in
                let type = game.playerTypes[player]
                if type != .disabled {
                    let isActive = game.currentPlayer == player
                    VStack(spacing: 4) {
                        GlassPiece(color: game.colors[player], count: 1, size: 28)
                        Text("\(game.names[player]) (\(type.rawValue))").font(.caption2.bold())
                    }
                    .padding(8).glassPanel(cornerRadius: 17)
                    .scaleEffect(isActive ? 1.08 : 0.88)
                    .offset(cornerInwardOffset(for: player, isActive: isActive))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: positions[player].0)
                    .padding(positions[player].1, 12).opacity(isActive ? 1.0 : 0.50)
                }
            }
        }.animation(.spring(response: 0.28, dampingFraction: 0.68), value: game.currentPlayer)
    }
    
    private func cornerInwardOffset(for player: Int, isActive: Bool) -> CGSize {
        guard isActive else { return .zero }
        let d: CGFloat = 12
        switch player { case 0: return CGSize(width: d, height: d); case 1: return CGSize(width: -d, height: d); case 2: return CGSize(width: -d, height: -d); case 3: return CGSize(width: d, height: -d); default: return .zero }
    }
}

struct StarterRouletteView: View {
    @ObservedObject var game: GameModel
    var body: some View {
        VStack(spacing: 18) {
            Text(game.rouletteFinished ? "先手玩家" : "正在抽取先手").font(.headline).foregroundStyle(.secondary)
            GlassPiece(color: game.colors[game.roulettePlayer], count: 1, size: 84).id(game.roulettePlayer).transition(.scale.combined(with: .opacity))
            Text("\(game.names[game.roulettePlayer]) (\(game.playerTypes[game.roulettePlayer].rawValue))").font(.title.bold())
        }.padding(34).glassPanel(cornerRadius: 32).animation(.spring(response: 0.20, dampingFraction: 0.68), value: game.roulettePlayer)
    }
}

struct WinnerView: View {
    @ObservedObject var game: GameModel
    let player: Int
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "crown.fill").font(.system(size: 56)).foregroundStyle(game.colors[player])
            Text("\(game.names[player])获胜！").font(.largeTitle.bold())
            HStack {
                Button("返回菜单") { game.returnToMenu() }.buttonStyle(.bordered)
                Button("再来一局") { game.prepareGame(size: game.boardSize) }.buttonStyle(.borderedProminent)
            }
        }.padding(32).glassPanel(cornerRadius: 30).padding(24)
    }
}

private extension View {
    @ViewBuilder func glassPanel(cornerRadius: CGFloat) -> some View {
        self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).stroke(Color.white.opacity(0.15), lineWidth: 0.8))
    }
}

// MARK: - 性能监控悬浮窗 (CPU 与 NPU 联合监控)
struct PerformanceOverlayView: View {
    @ObservedObject var monitor = PerformanceMonitor.shared
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("CPU 占用:")
                Spacer()
                Text(String(format: "%.1f%%", monitor.cpuUsage))
                    .bold()
                    .foregroundStyle(monitor.cpuUsage > 80.0 ? .red : .green)
            }
            HStack {
                Text("NPU 延时:")
                Spacer()
                Text(String(format: "%.2f ms", monitor.npuLatencyMs))
                    .bold()
                    .foregroundStyle(.cyan)
            }
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(8)
        .background(Color.black.opacity(0.75))
        .cornerRadius(8)
        .frame(width: 145)
    }
}
