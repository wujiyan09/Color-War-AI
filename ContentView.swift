import SwiftUI
import CoreML

// MARK: - 玩家类型
enum PlayerType: String, CaseIterable, Identifiable, Sendable {
    case human = "真人"
    case disabled = "不参加"
    case colorWarAI = "ColorWarAI (NPU)"
    case colorWar12x12 = "12x12 (NPU)"
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

// MARK: - 模型加载状态
@MainActor
final class ModelStatus: ObservableObject {
    static let shared = ModelStatus()
    @Published var isModel1Ready = false
    @Published var model1Message = "未初始化"
    @Published var isModel2Ready = false
    @Published var model2Message = "未初始化"
    @Published var activeWarning: String? = nil
    private init() {}
}

// MARK: - 估值权重
enum EvalWeights {
    static let orbValue = 15
    static let cornerBonus = 45
    static let edgeBonus = 20
    static let threeStackBonus = 35
    static let adjacentThreeAllyBonus = 50
    static let adjacentThreeEnemyPenalty = -60
    static let enemyMultiplier = 1.3
    static let eliminatedEnemyBonus = 800
    static let orbBalanceWeight = 20
    static let nightmareLoseScore = -999_999

    static let enhancedOrbValue = 10
    static let enhancedCornerBonus = 20
    static let enhancedEdgeBonus = 10
    static let enhancedThreeStack = 25
    static let enhancedEnemyMultiplier = 1.2
    static let enhancedEliminatedEnemy = 800
    static let enhancedOrbBalance = 15
    static let enhancedLoseScore = -99_999

    static let tacticalThreeStack = 100
    static let tacticalCorner = 50
    static let heuristicThreeStack = 30
    static let heuristicCorner = 15
}

// MARK: - Core ML 神经网络引擎
final class NeuralAISolver: @unchecked Sendable {
    static let shared = NeuralAISolver()

    private static let model1InputKey = "board_input"
    private static let model1OutputKey = "policy_logits"
    private static let model2InputKey = "board_input"
    private static let model2OutputKey = "policy_logits"

    private var modelColorWarAI: MLModel?
    private var model12x12: MLModel?

    private init() { reloadModels() }

    func reloadModels() {
        let config = MLModelConfiguration()
        config.computeUnits = .all

        var m1Ready = false
        var m1Msg = ""
        var m2Ready = false
        var m2Msg = ""

        if let (model, _) = loadModelDetail(named: "ColorWarAI", config: config) {
            self.modelColorWarAI = model
            m1Ready = true
            m1Msg = "已就绪 [1,5,12,12]"
        } else {
            m1Msg = "未找到模型文件"
        }

        if let (model, _) = loadModelDetail(named: "colorwar_12x12_model", config: config) {
            self.model12x12 = model
            m2Ready = true
            m2Msg = "已就绪 [1,4,12,12]"
        } else {
            m2Msg = "未找到模型文件"
        }

        Task { @MainActor in
            ModelStatus.shared.isModel1Ready = m1Ready
            ModelStatus.shared.model1Message = m1Msg
            ModelStatus.shared.isModel2Ready = m2Ready
            ModelStatus.shared.model2Message = m2Msg
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
                     playerType: PlayerType,
                     validMoves: [(Int, Int)],
                     fallback: () -> (Int, Int)?) -> (Int, Int)? {
        guard !validMoves.isEmpty else { return nil }

        let isModel1 = (playerType == .colorWarAI)
        let activeModel = isModel1 ? modelColorWarAI : model12x12

        guard boardSize <= 12 else {
            Task { @MainActor in
                ModelStatus.shared.activeWarning = "⚠️ 棋盘尺寸超出神经网络限制，降级为启发式"
            }
            return fallback() ?? validMoves.randomElement()
        }

        guard let model = activeModel else {
            Task { @MainActor in
                ModelStatus.shared.activeWarning = "⚠️ \(playerType.rawValue) 未加载，降级为启发式"
            }
            return fallback() ?? validMoves.randomElement()
        }

        do {
            let maxDim = 12
            let channelStride = 144
            let numChannels = isModel1 ? 5 : 4
            let totalElements = numChannels * 144

            let shape: [NSNumber] = [
                NSNumber(value: 1),
                NSNumber(value: numChannels),
                NSNumber(value: 12),
                NSNumber(value: 12)
            ]
            let inputArray = try MLMultiArray(shape: shape, dataType: .float32)
            let ptr = inputArray.dataPointer.bindMemory(to: Float.self, capacity: totalElements)
            memset(ptr, 0, totalElements * MemoryLayout<Float>.size)

            for r in 0..<boardSize {
                for c in 0..<boardSize {
                    let cell = flatBoard[r * boardSize + c]
                    if let owner = cell.owner {
                        let rel = (owner - currentPlayer + 4) % 4
                        let idx = rel * channelStride + r * maxDim + c
                        ptr[idx] = Float(cell.count) / 4.0
                    }
                }
            }

            if isModel1 {
                let maskOffset = 4 * channelStride
                for (r, c) in validMoves {
                    ptr[maskOffset + r * maxDim + c] = 1.0
                }
            }

            let inDescs = model.modelDescription.inputDescriptionsByName
            let explicitIn = isModel1 ? Self.model1InputKey : Self.model2InputKey
            let inputKey: String
            if inDescs[explicitIn] != nil {
                inputKey = explicitIn
            } else if inDescs.count == 1, let only = inDescs.keys.first {
                inputKey = only
            } else {
                Task { @MainActor in
                    ModelStatus.shared.activeWarning = "❌ 模型缺少输入节点 \(explicitIn)"
                }
                return fallback() ?? validMoves.randomElement()
            }

            let provider = try MLDictionaryFeatureProvider(dictionary: [inputKey: inputArray])
            let prediction = try model.prediction(from: provider)

            Task { @MainActor in ModelStatus.shared.activeWarning = nil }

            let outDescs = model.modelDescription.outputDescriptionsByName
            let explicitOut = isModel1 ? Self.model1OutputKey : Self.model2OutputKey
            let outputKey: String
            if outDescs[explicitOut] != nil {
                outputKey = explicitOut
            } else if outDescs.count == 1, let only = outDescs.keys.first {
                outputKey = only
            } else {
                Task { @MainActor in
                    ModelStatus.shared.activeWarning = "❌ 模型缺少输出节点 \(explicitOut)"
                }
                return fallback() ?? validMoves.randomElement()
            }

            guard let logits = prediction.featureValue(for: outputKey)?.multiArrayValue else {
                Task { @MainActor in
                    ModelStatus.shared.activeWarning = "❌ 无法读取模型输出 \(outputKey)"
                }
                return fallback() ?? validMoves.randomElement()
            }

            let logitsPtr = logits.dataPointer.bindMemory(to: Float.self, capacity: 144)
            var bestMove = validMoves[0]
            var maxScore: Float = -Float.greatestFiniteMagnitude
            for (r, c) in validMoves {
                let s = logitsPtr[r * maxDim + c]
                if s > maxScore {
                    maxScore = s
                    bestMove = (r, c)
                }
            }
            return bestMove
        } catch {
            let msg = error.localizedDescription
            Task { @MainActor in
                ModelStatus.shared.activeWarning = "❌ CoreML 推理失败: \(msg)"
            }
            return fallback() ?? validMoves.randomElement()
        }
    }
}

// MARK: - AI 解算器
struct AISolver: Sendable {
    struct SimCell: Sendable {
        var owner: Int?
        var count: Int
    }

    struct MoveKey: Hashable, Sendable {
        let r: Int
        let c: Int
    }

    struct Board: Sendable {
        var cells: [SimCell]
        let size: Int

        init(size: Int) {
            self.size = size
            self.cells = Array(repeating: SimCell(owner: nil, count: 0), count: size * size)
        }
        init(flat: [SimCell], size: Int) {
            self.size = size
            self.cells = flat
        }
        subscript(r: Int, _ c: Int) -> SimCell {
            get { cells[r * size + c] }
            set { cells[r * size + c] = newValue }
        }
        var totalOrbs: Int { cells.reduce(0) { $0 + $1.count } }
    }

    final class MCTSNode {
        let move: (Int, Int)?
        let player: Int
        weak var parent: MCTSNode?
        var children: [MCTSNode] = []
        var visits: Int = 0
        var wins: Double = 0.0
        var boardState: Board
        var unvisitedMoves: [(Int, Int)]
        var hasEnteredState: [Bool]
        var eliminatedState: [Bool]

        var isFullyExpanded: Bool { unvisitedMoves.isEmpty }

        init(move: (Int, Int)?,
             player: Int,
             board: Board,
             unvisitedMoves: [(Int, Int)],
             hasEntered: [Bool],
             eliminated: [Bool],
             parent: MCTSNode? = nil) {
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
                let sa = (a.wins / Double(max(a.visits, 1))) + c * sqrt(logTotal / Double(max(a.visits, 1)))
                let sb = (b.wins / Double(max(b.visits, 1))) + c * sqrt(logTotal / Double(max(b.visits, 1)))
                return sa < sb
            }
        }
    }

    let boardSize: Int
    let activePlayers: [Int]
    let currentPlayer: Int
    let playerType: PlayerType
    let board: Board
    let hasEntered: [Bool]
    let eliminated: [Bool]

    init(boardSize: Int,
         activePlayers: [Int],
         currentPlayer: Int,
         playerType: PlayerType,
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
        self.board = Board(flat: flat, size: boardSize)
        self.hasEntered = hasEntered
        self.eliminated = eliminated
    }

    func calculateBestMove() async -> (Int, Int)? {
        var validMoves = getPlayableCells(for: currentPlayer, on: board)
        guard !validMoves.isEmpty else { return nil }

        if playerType.isNeuralAI {
            let flat = board.cells
            return NeuralAISolver.shared.getBestMove(
                flatBoard: flat,
                boardSize: boardSize,
                currentPlayer: currentPlayer,
                playerType: playerType,
                validMoves: validMoves,
                fallback: { heuristicBestMove(validMoves: validMoves) }
            )
        }

        if board.totalOrbs < 6 {
            let pruned = validMoves.filter { r, c in
                let isCorner = (r == 0 || r == boardSize - 1) && (c == 0 || c == boardSize - 1)
                let isEdge = r == 0 || r == boardSize - 1 || c == 0 || c == boardSize - 1
                let isCenter = (r >= boardSize / 2 - 1 && r <= boardSize / 2 + 1) &&
                               (c >= boardSize / 2 - 1 && c <= boardSize / 2 + 1)
                return isCorner || isEdge || isCenter
            }
            if !pruned.isEmpty {
                validMoves = pruned
            }
        }

        let isMultiplayer = activePlayers.count > 2

        switch playerType {
        case .mathEasy:
            return validMoves.randomElement()

        case .mathNormal:
            return heuristicBestMove(validMoves: validMoves)

        case .mathHard:
            return isMultiplayer
                ? await runMCTS(iterations: 600, isBiased: false, validMoves: validMoves)
                : getBestMinimaxMove(depth: 2, validMoves: validMoves)

        case .mathExpert:
            return isMultiplayer
                ? await runMCTS(iterations: 1200, isBiased: true, validMoves: validMoves)
                : getBestMinimaxMove(depth: 3, validMoves: validMoves)

        case .mathUltimate:
            return await runMCTS(iterations: 1500, isBiased: true, validMoves: validMoves)

        case .mathNightmare:
            return isMultiplayer
                ? await runMCTS(iterations: 3000, isBiased: true, validMoves: validMoves)
                : calculateNightmareMove(validMoves: validMoves)

        default:
            return validMoves.randomElement()
        }
    }

    private func heuristicBestMove(validMoves: [(Int, Int)]) -> (Int, Int)? {
        guard !validMoves.isEmpty else { return nil }
        let scored = validMoves.map { ($0, evaluateSingleMoveHeuristic($0, on: board)) }
        guard let maxScore = scored.map({ $0.1 }).max() else {
            return validMoves.randomElement()
        }
        return scored.filter { $0.1 == maxScore }.randomElement()?.0
    }

    private func calculateNightmareMove(validMoves: [(Int, Int)]) -> (Int, Int)? {
        let sorted = validMoves.sorted {
            evaluateTacticalMoveScore($0, on: board, player: currentPlayer)
                > evaluateTacticalMoveScore($1, on: board, player: currentPlayer)
        }
        var bestScore = Int.min
        var bestMoves: [(Int, Int)] = []
        let depth = boardSize <= 7 ? 5 : 4

        for move in sorted {
            if Task.isCancelled { break }
            let s = minimaxNightmare(
                boardState: board,
                hasEnteredState: hasEntered,
                eliminatedState: eliminated,
                move: move,
                depth: depth,
                alpha: Int.min + 1,
                beta: Int.max - 1,
                isMaximizing: false,
                turnPlayer: currentPlayer
            )
            if s > bestScore {
                bestScore = s
                bestMoves = [move]
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
                                  turnPlayer: Int) -> Int {
        if Task.isCancelled { return 0 }

        var b = boardState
        var h = hasEnteredState
        var e = eliminatedState

        simulateMoveBFS(on: &b, move: move, player: turnPlayer, hasEntered: &h)
        updateEliminatedStatus(board: b, hasEntered: h, eliminated: &e)

        if depth == 1 || isGameOverSimulated(eliminated: e) {
            return evaluateNightmareBoard(b, forPlayer: currentPlayer, eliminated: e)
        }

        let nextPlayer = getNextPlayerSimulated(current: turnPlayer, eliminated: e)
        let nextMoves = getPlayableCells(for: nextPlayer, on: b)
        if nextMoves.isEmpty {
            return evaluateNightmareBoard(b, forPlayer: currentPlayer, eliminated: e)
        }

        let sorted = nextMoves.sorted {
            evaluateTacticalMoveScore($0, on: b, player: nextPlayer)
                > evaluateTacticalMoveScore($1, on: b, player: nextPlayer)
        }

        var a = alpha
        var betaV = beta

        if isMaximizing {
            var maxEval = Int.min
            for m in sorted {
                let v = minimaxNightmare(
                    boardState: b,
                    hasEnteredState: h,
                    eliminatedState: e,
                    move: m,
                    depth: depth - 1,
                    alpha: a,
                    beta: betaV,
                    isMaximizing: false,
                    turnPlayer: nextPlayer
                )
                maxEval = max(maxEval, v)
                a = max(a, v)
                if betaV <= a { break }
            }
            return maxEval
        } else {
            var minEval = Int.max
            for m in sorted {
                let v = minimaxNightmare(
                    boardState: b,
                    hasEnteredState: h,
                    eliminatedState: e,
                    move: m,
                    depth: depth - 1,
                    alpha: a,
                    beta: betaV,
                    isMaximizing: true,
                    turnPlayer: nextPlayer
                )
                minEval = min(minEval, v)
                betaV = min(betaV, v)
                if betaV <= a { break }
            }
            return minEval
        }
    }

    private func getBestMinimaxMove(depth: Int, validMoves: [(Int, Int)]) -> (Int, Int)? {
        var bestScore = Int.min
        var bestMoves: [(Int, Int)] = []

        for move in validMoves {
            if Task.isCancelled { break }
            let s = minimaxRecursive(
                boardState: board,
                hasEnteredState: hasEntered,
                eliminatedState: eliminated,
                move: move,
                depth: depth,
                alpha: Int.min,
                beta: Int.max,
                isMaximizing: false,
                turnPlayer: currentPlayer
            )
            if s > bestScore {
                bestScore = s
                bestMoves = [move]
            } else if s == bestScore {
                bestMoves.append(move)
            }
        }
        return bestMoves.randomElement() ?? validMoves.randomElement()
    }

    private func minimaxRecursive(boardState: Board,
                                  hasEnteredState: [Bool],
                                  eliminatedState: [Bool],
                                  move: (Int, Int),
                                  depth: Int,
                                  alpha: Int,
                                  beta: Int,
                                  isMaximizing: Bool,
                                  turnPlayer: Int) -> Int {
        if Task.isCancelled { return 0 }

        var b = boardState
        var h = hasEnteredState
        var e = eliminatedState

        simulateMoveBFS(on: &b, move: move, player: turnPlayer, hasEntered: &h)
        updateEliminatedStatus(board: b, hasEntered: h, eliminated: &e)

        if depth == 1 || isGameOverSimulated(eliminated: e) {
            return evaluateEnhancedBoard(b, forPlayer: currentPlayer, eliminated: e)
        }

        let nextPlayer = getNextPlayerSimulated(current: turnPlayer, eliminated: e)
        let nextMoves = getPlayableCells(for: nextPlayer, on: b)
        if nextMoves.isEmpty {
            return evaluateEnhancedBoard(b, forPlayer: currentPlayer, eliminated: e)
        }

        var a = alpha
        var betaV = beta

        if isMaximizing {
            var maxEval = Int.min
            for m in nextMoves {
                let v = minimaxRecursive(
                    boardState: b,
                    hasEnteredState: h,
                    eliminatedState: e,
                    move: m,
                    depth: depth - 1,
                    alpha: a,
                    beta: betaV,
                    isMaximizing: false,
                    turnPlayer: nextPlayer
                )
                maxEval = max(maxEval, v)
                a = max(a, v)
                if betaV <= a { break }
            }
            return maxEval
        } else {
            var minEval = Int.max
            for m in nextMoves {
                let v = minimaxRecursive(
                    boardState: b,
                    hasEnteredState: h,
                    eliminatedState: e,
                    move: m,
                    depth: depth - 1,
                    alpha: a,
                    beta: betaV,
                    isMaximizing: true,
                    turnPlayer: nextPlayer
                )
                minEval = min(minEval, v)
                betaV = min(betaV, v)
                if betaV <= a { break }
            }
            return minEval
        }
    }

    private func runMCTS(iterations: Int, isBiased: Bool, validMoves: [(Int, Int)]) async -> (Int, Int)? {
        let taskCount = 4
        let perTask = iterations / taskCount

        let merged = await withTaskGroup(of: [MoveKey: Int].self) { group in
            for _ in 0..<taskCount {
                group.addTask {
                    let root = MCTSNode(
                        move: nil,
                        player: self.currentPlayer,
                        board: self.board,
                        unvisitedMoves: validMoves,
                        hasEntered: self.hasEntered,
                        eliminated: self.eliminated
                    )

                    for _ in 0..<perTask {
                        if Task.isCancelled { break }

                        var node = root
                        while node.isFullyExpanded && !node.children.isEmpty {
                            if let nx = node.selectBestChildUCB() {
                                node = nx
                            } else {
                                break
                            }
                        }

                        if !node.unvisitedMoves.isEmpty {
                            let move = node.unvisitedMoves.remove(at: Int.random(in: 0..<node.unvisitedMoves.count))
                            var b = node.boardState
                            var h = node.hasEnteredState
                            var e = node.eliminatedState
                            self.simulateMoveBFS(on: &b, move: move, player: node.player, hasEntered: &h)
                            self.updateEliminatedStatus(board: b, hasEntered: h, eliminated: &e)

                            let np = self.getNextPlayerSimulated(current: node.player, eliminated: e)
                            let child = MCTSNode(
                                move: move,
                                player: np,
                                board: b,
                                unvisitedMoves: self.getPlayableCells(for: np, on: b),
                                hasEntered: h,
                                eliminated: e,
                                parent: node
                            )
                            node.children.append(child)
                            node = child
                        }

                        let winner = self.simulatePlayout(from: node, isBiased: isBiased)

                        var cur: MCTSNode? = node
                        while let n = cur {
                            n.visits += 1
                            if winner == self.currentPlayer {
                                n.wins += 1.0
                            } else if winner == nil {
                                n.wins += 0.2
                            }
                            cur = n.parent
                        }
                    }

                    var visits: [MoveKey: Int] = [:]
                    for child in root.children {
                        if let (r, c) = child.move {
                            visits[MoveKey(r: r, c: c)] = child.visits
                        }
                    }
                    return visits
                }
            }

            var total: [MoveKey: Int] = [:]
            for await v in group {
                for (k, n) in v {
                    total[k, default: 0] += n
                }
            }
            return total
        }

        if let best = merged.max(by: { $0.value < $1.value })?.key {
            return (best.r, best.c)
        }
        return validMoves.randomElement()
    }

    private func simulatePlayout(from node: MCTSNode, isBiased: Bool) -> Int? {
        var b = node.boardState
        var h = node.hasEnteredState
        var e = node.eliminatedState
        var cur = node.player
        var step = 0

        let maxSteps = boardSize >= 9 ? 25 : 50

        while step < maxSteps {
            step += 1
            let moves = getPlayableCells(for: cur, on: b)
            if moves.isEmpty {
                e[cur] = true
            } else {
                let move: (Int, Int)
                if isBiased && Double.random(in: 0...1) < 0.75 {
                    move = biasedPick(moves, on: b) ?? moves.randomElement()!
                } else {
                    move = moves.randomElement()!
                }
                simulateMoveBFS(on: &b, move: move, player: cur, hasEntered: &h)
                updateEliminatedStatus(board: b, hasEntered: h, eliminated: &e)
            }

            let alive = activePlayers.filter { !e[$0] }
            if alive.count <= 1 { return alive.first }
            cur = getNextPlayerSimulated(current: cur, eliminated: e)
        }

        var scores = [Int](repeating: 0, count: 4)
        for r in 0..<boardSize {
            for c in 0..<boardSize {
                if let o = b[r, c].owner {
                    scores[o] += b[r, c].count + (b[r, c].count == 3 ? 5 : 0)
                }
            }
        }

        let activeScores = activePlayers.map { (player: $0, score: scores[$0]) }
        guard let maxScore = activeScores.map({ $0.score }).max() else { return nil }
        let leaders = activeScores.filter { $0.score == maxScore }
        return leaders.count == 1 ? leaders[0].player : nil
    }

    private func biasedPick(_ moves: [(Int, Int)], on b: Board) -> (Int, Int)? {
        guard !moves.isEmpty else { return nil }
        let scored = moves.map { ($0, evaluateSingleMoveHeuristic($0, on: b)) }
        guard let maxScore = scored.map({ $0.1 }).max() else {
            return moves.randomElement()
        }
        return scored.filter { $0.1 == maxScore }.randomElement()?.0
    }

    private func simulateMoveBFS(on simBoard: inout Board,
                                 move: (Int, Int),
                                 player: Int,
                                 hasEntered: inout [Bool]) {
        let (r, c) = move
        let isFirst = !hasEntered[player]
        hasEntered[player] = true

        simBoard[r, c].owner = player
        simBoard[r, c].count += isFirst ? 3 : 1

        var queue: [(Int, Int)] = simBoard[r, c].count >= 4 ? [(r, c)] : []
        var head = 0
        let safety = boardSize * boardSize * 6

        while head < queue.count && head < safety {
            let (er, ec) = queue[head]
            head += 1
            if simBoard[er, ec].count < 4 { continue }

            simBoard[er, ec].count -= 4
            if simBoard[er, ec].count == 0 {
                simBoard[er, ec].owner = nil
            }

            for (nr, nc) in neighbors(of: er, ec) {
                simBoard[nr, nc].owner = player
                simBoard[nr, nc].count += 1
                if simBoard[nr, nc].count >= 4 {
                    queue.append((nr, nc))
                }
            }
        }
    }

    private func evaluateNightmareBoard(_ b: Board, forPlayer player: Int, eliminated: [Bool]) -> Int {
        if eliminated[player] { return EvalWeights.nightmareLoseScore }

        var score = 0
        var myOrbs = 0
        var enemyOrbs = 0

        for r in 0..<boardSize {
            for c in 0..<boardSize {
                let cell = b[r, c]
                guard let owner = cell.owner else { continue }

                let isCorner = (r == 0 || r == boardSize - 1) && (c == 0 || c == boardSize - 1)
                let isEdge = r == 0 || r == boardSize - 1 || c == 0 || c == boardSize - 1

                var v = cell.count * EvalWeights.orbValue
                if isCorner {
                    v += EvalWeights.cornerBonus
                } else if isEdge {
                    v += EvalWeights.edgeBonus
                }

                if cell.count == 3 {
                    v += EvalWeights.threeStackBonus
                    for (nr, nc) in neighbors(of: r, c) {
                        if let ao = b[nr, nc].owner, ao != owner, b[nr, nc].count == 3 {
                            v += (owner == player
                                  ? EvalWeights.adjacentThreeAllyBonus
                                  : EvalWeights.adjacentThreeEnemyPenalty)
                        }
                    }
                }

                if owner == player {
                    myOrbs += cell.count
                    score += v
                } else {
                    enemyOrbs += cell.count
                    score -= Int(Double(v) * EvalWeights.enemyMultiplier)
                }
            }
        }

        let eliminatedEnemies = activePlayers.filter { $0 != player && eliminated[$0] }.count
        return score
            + eliminatedEnemies * EvalWeights.eliminatedEnemyBonus
            + (myOrbs - enemyOrbs) * EvalWeights.orbBalanceWeight
    }

    private func evaluateEnhancedBoard(_ b: Board, forPlayer player: Int, eliminated: [Bool]) -> Int {
        if eliminated[player] { return EvalWeights.enhancedLoseScore }

        var score = 0
        var myCount = 0
        var enemyCount = 0

        for r in 0..<boardSize {
            for c in 0..<boardSize {
                let cell = b[r, c]
                guard let owner = cell.owner else { continue }

                let isCorner = (r == 0 || r == boardSize - 1) && (c == 0 || c == boardSize - 1)
                let isEdge = r == 0 || r == boardSize - 1 || c == 0 || c == boardSize - 1
                let pos = isCorner
                    ? EvalWeights.enhancedCornerBonus
                    : (isEdge ? EvalWeights.enhancedEdgeBonus : 0)

                let v = cell.count * EvalWeights.enhancedOrbValue
                    + pos
                    + (cell.count == 3 ? EvalWeights.enhancedThreeStack : 0)

                if owner == player {
                    myCount += cell.count
                    score += v
                } else {
                    enemyCount += cell.count
                    score -= Int(Double(v) * EvalWeights.enhancedEnemyMultiplier)
                }
            }
        }

        let eliminatedEnemies = activePlayers.filter { $0 != player && eliminated[$0] }.count
        return score
            + eliminatedEnemies * EvalWeights.enhancedEliminatedEnemy
            + (myCount - enemyCount) * EvalWeights.enhancedOrbBalance
    }

    private func evaluateTacticalMoveScore(_ move: (Int, Int), on b: Board, player: Int) -> Int {
        let (r, c) = move
        let isCorner = (r == 0 || r == boardSize - 1) && (c == 0 || c == boardSize - 1)
        return (b[r, c].count == 3 ? EvalWeights.tacticalThreeStack : 0)
            + (isCorner ? EvalWeights.tacticalCorner : 0)
    }

    private func evaluateSingleMoveHeuristic(_ move: (Int, Int), on b: Board) -> Int {
        let (r, c) = move
        let isCorner = (r == 0 || r == boardSize - 1) && (c == 0 || c == boardSize - 1)
        return (b[r, c].count == 3 ? EvalWeights.heuristicThreeStack : 0)
            + (isCorner ? EvalWeights.heuristicCorner : 0)
    }

    private func updateEliminatedStatus(board b: Board, hasEntered: [Bool], eliminated: inout [Bool]) {
        var appears = [Bool](repeating: false, count: 4)
        let cells = b.cells
        for i in 0..<cells.count {
            if let o = cells[i].owner, o >= 0, o < 4 {
                appears[o] = true
            }
        }
        for p in 0..<4 where hasEntered[p] && !eliminated[p] {
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
        while eliminated[activePlayers[i]] && count < n {
            i = (i + 1) % n
            count += 1
        }
        return activePlayers[i]
    }

    private func getPlayableCells(for player: Int, on b: Board) -> [(Int, Int)] {
        var ownsAny = false
        let cells = b.cells
        for i in 0..<cells.count {
            if cells[i].owner == player {
                ownsAny = true
                break
            }
        }

        var moves: [(Int, Int)] = []
        moves.reserveCapacity(b.size * b.size)
        for r in 0..<boardSize {
            for c in 0..<boardSize {
                let owner = b[r, c].owner
                if ownsAny {
                    if owner == player {
                        moves.append((r, c))
                    }
                } else {
                    if owner == nil {
                        moves.append((r, c))
                    }
                }
            }
        }
        return moves
    }

    private func isGameOverSimulated(eliminated: [Bool]) -> Bool {
        activePlayers.filter { !eliminated[$0] }.count <= 1
    }

    private func neighbors(of row: Int, _ col: Int) -> [(Int, Int)] {
        [(-1, 0), (1, 0), (0, -1), (0, 1)].compactMap { dr, dc in
            let r = row + dr
            let c = col + dc
            guard (0..<boardSize).contains(r), (0..<boardSize).contains(c) else { return nil }
            return (r, c)
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
        starterTask?.cancel()
        aiTask?.cancel()
        moveTask?.cancel()
        starterTask = nil
        aiTask = nil
        moveTask = nil
    }

    private func resetTransientState() {
        emphasizedCells = []
        flyingOrbs = []
        playableCells = []
        ModelStatus.shared.activeWarning = nil
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
        resetTransientState()
        if let size { boardSize = min(12, max(5, size)) }
        makeEmptyBoard()
        currentPlayer = activePlayers.first ?? 0
        winner = nil
        isResolving = false
        hasEntered = Array(repeating: false, count: 4)
        eliminated = Array(repeating: false, count: 4)
        turnNumber = 0
        rouletteFinished = false
        showMenu = false
        starterTask = Task { await chooseStarter() }
    }

    func returnToMenu() {
        cancelAllTasks()
        resetTransientState()
        isChoosingStarter = false
        isResolving = false
        showMenu = true
        NeuralAISolver.shared.reloadModels()
    }

    private func chooseStarter() async {
        isChoosingStarter = true
        let active = activePlayers
        let selected = active.randomElement() ?? 0
        let totalTicks = 15 + Int.random(in: 0...5)

        do {
            var curr = 0
            for tick in 0..<totalTicks {
                try Task.checkCancellation()
                curr = (curr + 1) % active.count
                roulettePlayer = active[curr]
                let progress = Double(tick) / Double(totalTicks)
                try await Task.sleep(nanoseconds: UInt64((45 + Int(progress * progress * 140)) * 1_000_000))
            }
            while roulettePlayer != selected {
                try Task.checkCancellation()
                curr = (curr + 1) % active.count
                roulettePlayer = active[curr]
                try await Task.sleep(nanoseconds: 130_000_000)
            }
            currentPlayer = selected
            rouletteFinished = true
            try await Task.sleep(nanoseconds: 560_000_000)
            isChoosingStarter = false
            rebuildPlayableCells()
            triggerAIMoveIfNeeded()
        } catch {
            isChoosingStarter = false
        }
    }

    func play(row: Int, column: Int) {
        let index = row * boardSize + column
        guard !showMenu,
              !isChoosingStarter,
              winner == nil,
              !isResolving,
              !eliminated[currentPlayer],
              playableCells.contains(index),
              playerTypes[currentPlayer] == .human else { return }

        let player = currentPlayer
        aiTask?.cancel()
        aiTask = nil
        moveTask?.cancel()
        moveTask = Task { @MainActor in
            await resolveMove(row: row, column: column, player: player)
        }
    }

    private func resolveMove(row: Int, column: Int, player: Int) async {
        isResolving = true
        playableCells = []
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

            while !wave.isEmpty {
                try Task.checkCancellation()
                let exploding = wave
                emphasizedCells = Set(exploding.map { $0.0 * boardSize + $0.1 })
                try await Task.sleep(nanoseconds: 85_000_000)

                var transfers: [FlyingOrb] = []
                for (r, c) in exploding {
                    for (nr, nc) in neighbors(of: r, c) {
                        transfers.append(FlyingOrb(
                            fromRow: r,
                            fromColumn: c,
                            toRow: nr,
                            toColumn: nc,
                            player: player
                        ))
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

            turnNumber += 1
            updateGameState()
            emphasizedCells = []
            isResolving = false

            if winner == nil {
                advanceTurn()
                rebuildPlayableCells()
                triggerAIMoveIfNeeded()
            }
        } catch {
            isResolving = false
            emphasizedCells = []
            flyingOrbs = []
            rebuildPlayableCells()
        }
    }

    private func neighbors(of row: Int, _ col: Int) -> [(Int, Int)] {
        [(-1, 0), (1, 0), (0, -1), (0, 1)].compactMap { dr, dc in
            let r = row + dr
            let c = col + dc
            guard (0..<boardSize).contains(r), (0..<boardSize).contains(c) else { return nil }
            return (r, c)
        }
    }

    private func updateGameState() {
        let active = activePlayers
        guard active.allSatisfy({ hasEntered[$0] }) else { return }
        for p in active where hasEntered[p] {
            eliminated[p] = !board.joined().contains { $0.owner == p }
        }
        let alive = active.filter { !eliminated[$0] }
        if alive.count == 1 && turnNumber >= active.count {
            winner = alive[0]
        }
    }

    private func advanceTurn() {
        var next = (currentPlayer + 1) % 4
        while playerTypes[next] == .disabled || eliminated[next] {
            next = (next + 1) % 4
        }
        currentPlayer = next
    }

    private func triggerAIMoveIfNeeded() {
        let pType = playerTypes[currentPlayer]
        guard winner == nil, !showMenu, !isChoosingStarter, !isResolving, pType.isAI else { return }

        let bSize = boardSize
        let active = activePlayers
        let currP = currentPlayer
        let currentBoard = board
        let enteredState = hasEntered
        let elimState = eliminated

        aiTask?.cancel()
        aiTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
                guard !self.isResolving, self.winner == nil, self.currentPlayer == currP else { return }

                let bestMove = await Task.detached(priority: .userInitiated) {
                    let solver = AISolver(
                        boardSize: bSize,
                        activePlayers: active,
                        currentPlayer: currP,
                        playerType: pType,
                        board: currentBoard,
                        hasEntered: enteredState,
                        eliminated: elimState
                    )
                    return await solver.calculateBestMove()
                }.value

                try Task.checkCancellation()
                guard !self.showMenu, !self.isResolving, self.currentPlayer == currP else { return }

                if let (r, c) = bestMove {
                    self.moveTask?.cancel()
                    self.moveTask = Task { @MainActor [weak self] in
                        await self?.resolveMove(row: r, column: c, player: currP)
                    }
                }
            } catch {}
        }
    }
}

// MARK: - 主界面
struct ContentView: View {
    @StateObject private var game = GameModel()

    var body: some View {
        ZStack {
            background.ignoresSafeArea()
            if game.showMenu {
                StartMenuView(game: game)
            } else {
                GameView(game: game)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var background: some View {
        let activeColor = game.showMenu ? Color.indigo : game.colors[game.currentPlayer]
        return ZStack {
            Color(red: 0.08, green: 0.08, blue: 0.10)
            activeColor.opacity(0.28)
                .animation(.easeInOut(duration: 0.25), value: activeColor)
        }
    }
}

// MARK: - 菜单
struct StartMenuView: View {
    @ObservedObject var game: GameModel
    @ObservedObject private var status = ModelStatus.shared
    @State private var boardSize = 9

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "circle.grid.3x3.fill")
                .font(.system(size: 56))
                .symbolRenderingMode(.hierarchical)
            Text("Color War")
                .font(.system(size: 36, weight: .bold, design: .rounded))

            VStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    ModelStatusRow(name: "ColorWarAI (5通道)",
                                   isReady: status.isModel1Ready,
                                   message: status.model1Message)
                    ModelStatusRow(name: "colorwar_12x12 (4通道)",
                                   isReady: status.isModel2Ready,
                                   message: status.model2Message)
                }
                .padding(12)
                .glassEffect(.regular, in: .rect(cornerRadius: 12))

                VStack(spacing: 10) {
                    ForEach(0..<4, id: \.self) { p in
                        HStack {
                            Circle()
                                .fill(game.colors[p])
                                .frame(width: 12, height: 12)
                            Text(game.names[p]).font(.subheadline.bold())
                            Spacer()
                            Picker("", selection: $game.playerTypes[p]) {
                                ForEach(PlayerType.allCases) { t in
                                    Text(t.rawValue).tag(t)
                                }
                            }
                            .pickerStyle(.menu)
                            .tint(typeColor(game.playerTypes[p]))
                        }
                    }
                }

                VStack(spacing: 6) {
                    HStack {
                        Text("棋盘大小")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(boardSize) × \(boardSize)")
                            .font(.subheadline.monospacedDigit().bold())
                    }
                    Slider(
                        value: Binding(
                            get: { Double(boardSize) },
                            set: { boardSize = Int($0) }
                        ),
                        in: 5...12,
                        step: 1
                    )
                    .tint(.indigo)
                }

                Button {
                    game.prepareGame(size: boardSize)
                } label: {
                    Label("抽取先手并开始", systemImage: "shuffle")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
                .tint(.indigo)
                .disabled(game.activePlayers.count < 2)
            }
            .padding(18)
            .glassEffect(.regular, in: .rect(cornerRadius: 24))
            .frame(maxWidth: 440)
        }
        .padding(20)
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
    let name: String
    let isReady: Bool
    let message: String

    var body: some View {
        HStack {
            Image(systemName: isReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(isReady ? .green : .red)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.caption.bold())
                Text(message).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

// MARK: - 游戏界面
struct GameView: View {
    @ObservedObject var game: GameModel
    @ObservedObject private var status = ModelStatus.shared

    var body: some View {
        GeometryReader { proxy in
            let boardSide = min(proxy.size.width - 30, proxy.size.height - 115, 730)

            ZStack {
                VStack(spacing: 10) {
                    HStack {
                        Button(action: game.returnToMenu) {
                            Image(systemName: "chevron.left")
                        }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)

                        Spacer()

                        Text("\(game.names[game.currentPlayer]) (\(game.playerTypes[game.currentPlayer].rawValue)) 回合 · \(game.boardSize)×\(game.boardSize)")
                            .font(.headline)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .glassEffect(.regular, in: .capsule)

                        Spacer()

                        Button {
                            game.prepareGame(size: game.boardSize)
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                    }
                    .frame(maxWidth: boardSide)

                    if let warning = status.activeWarning {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.yellow)
                            Text(warning).font(.caption.bold())
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .glassEffect(.regular.tint(.red), in: .capsule)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    BoardView(game: game)
                        .frame(width: boardSide, height: boardSide)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(12)

                PlayerCornerIndicators(game: game).allowsHitTesting(false)

                if game.isChoosingStarter {
                    StarterRouletteView(game: game)
                }
            }
        }
        .overlay {
            if let winner = game.winner {
                WinnerView(game: game, player: winner)
            }
        }
    }
}

// MARK: - 棋盘
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
                                let isPlayable = game.playableCells.contains(index)

                                CellView(
                                    cell: cell,
                                    color: cell.owner.map { game.colors[$0] },
                                    active: game.emphasizedCells.contains(index),
                                    isPlayable: isPlayable,
                                    onTap: {
                                        if game.playerTypes[game.currentPlayer] == .human, isPlayable {
                                            game.play(row: r, column: c)
                                        }
                                    }
                                )
                                .equatable()
                                .frame(width: side, height: side)
                            }
                        }
                    }
                }
                .padding(6)

                ForEach(game.flyingOrbs) { orb in
                    GlassPiece(
                        color: game.colors[orb.player],
                        count: 1,
                        size: max(8, side * 0.40),
                        interactive: false
                    )
                    .position(
                        x: 6 + side / 2 + CGFloat(orb.arrived ? orb.toColumn : orb.fromColumn) * (side + gap),
                        y: 6 + side / 2 + CGFloat(orb.arrived ? orb.toRow : orb.fromRow) * (side + gap)
                    )
                    .zIndex(10)
                    .allowsHitTesting(false)
                }
            }
            .glassEffect(.regular, in: .rect(cornerRadius: 24))
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

// MARK: - 格子
struct CellView: View, Equatable {
    let cell: Cell
    let color: Color?
    let active: Bool
    let isPlayable: Bool
    let onTap: () -> Void

    static func == (lhs: CellView, rhs: CellView) -> Bool {
        lhs.cell == rhs.cell
            && lhs.color == rhs.color
            && lhs.active == rhs.active
            && lhs.isPlayable == rhs.isPlayable
    }

    var body: some View {
        GeometryReader { proxy in
            let pieceSize = proxy.size.width * 0.76

            ZStack {
                RoundedRectangle(cornerRadius: max(4, proxy.size.width * 0.17), style: .continuous)
                    .fill(Color.white.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: max(4, proxy.size.width * 0.17))
                            .stroke(Color.white.opacity(0.12), lineWidth: 0.7)
                    )

                if cell.count > 0, let color {
                    GlassPiece(color: color, count: cell.count, size: pieceSize, interactive: true)
                        .scaleEffect(active ? 1.09 : 1)
                        .transition(.scale.combined(with: .opacity))
                } else if isPlayable {
                    Circle()
                        .fill(.clear)
                        .frame(width: pieceSize, height: pieceSize)
                        .glassEffect(.regular.interactive(), in: .circle)
                        .opacity(0.35)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if isPlayable { onTap() }
            }
            .animation(.spring(response: 0.21, dampingFraction: 0.62), value: cell.count)
            .animation(.spring(response: 0.18, dampingFraction: 0.65), value: active)
        }
    }
}

// MARK: - 玻璃棋子
struct GlassPiece: View {
    let color: Color
    let count: Int
    let size: CGFloat
    var interactive: Bool = false

    var body: some View {
        if interactive {
            pieceShape
                .glassEffect(.regular.tint(color).interactive(), in: .circle)
        } else {
            pieceShape
                .glassEffect(.regular.tint(color), in: .circle)
        }
    }

    private var pieceShape: some View {
        Circle()
            .fill(.clear)
            .frame(width: size, height: size)
            .overlay {
                DotPattern(count: min(4, max(0, count)), diameter: size * 0.16)
            }
            .shadow(color: color.opacity(0.35), radius: size * 0.1, y: size * 0.03)
            .accessibilityHidden(true)
    }
}

// MARK: - 点数图案
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
        let d = diameter * 0.86
        switch count {
        case 0, 1:
            return .zero
        case 2:
            return CGSize(width: index == 0 ? -d : d, height: 0)
        case 3:
            let angle = -Double.pi / 2 + Double(index) * (2 * Double.pi / 3)
            return CGSize(width: cos(angle) * d, height: sin(angle) * d)
        default:
            let angle = Double.pi / 4 + Double(index) * (Double.pi / 2)
            return CGSize(width: cos(angle) * d, height: sin(angle) * d)
        }
    }
}

// MARK: - 四角玩家指示器
struct PlayerCornerIndicators: View {
    @ObservedObject var game: GameModel

    private let positions: [(Alignment, Edge.Set)] = [
        (.topLeading, [.top, .leading]),
        (.topTrailing, [.top, .trailing]),
        (.bottomTrailing, [.bottom, .trailing]),
        (.bottomLeading, [.bottom, .leading])
    ]

    var body: some View {
        ZStack {
            ForEach(0..<4, id: \.self) { player in
                let type = game.playerTypes[player]
                if type != .disabled {
                    let isActive = game.currentPlayer == player
                    VStack(spacing: 4) {
                        GlassPiece(color: game.colors[player], count: 1, size: 28, interactive: false)
                        Text("\(game.names[player]) (\(type.rawValue))")
                            .font(.caption2.bold())
                    }
                    .padding(8)
                    .glassEffect(.regular, in: .rect(cornerRadius: 17))
                    .scaleEffect(isActive ? 1.08 : 0.88)
                    .offset(cornerInwardOffset(for: player, isActive: isActive))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: positions[player].0)
                    .padding(positions[player].1, 12)
                    .opacity(isActive ? 1.0 : 0.50)
                }
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.68), value: game.currentPlayer)
    }

    private func cornerInwardOffset(for player: Int, isActive: Bool) -> CGSize {
        guard isActive else { return .zero }
        let d: CGFloat = 12
        switch player {
        case 0: return CGSize(width: d, height: d)
        case 1: return CGSize(width: -d, height: d)
        case 2: return CGSize(width: -d, height: -d)
        case 3: return CGSize(width: d, height: -d)
        default: return .zero
        }
    }
}

// MARK: - 先手轮盘
struct StarterRouletteView: View {
    @ObservedObject var game: GameModel

    var body: some View {
        VStack(spacing: 18) {
            Text(game.rouletteFinished ? "先手玩家" : "正在抽取先手")
                .font(.headline)
                .foregroundStyle(.secondary)

            GlassPiece(color: game.colors[game.roulettePlayer], count: 1, size: 84, interactive: false)
                .id(game.roulettePlayer)
                .transition(.scale.combined(with: .opacity))

            Text("\(game.names[game.roulettePlayer]) (\(game.playerTypes[game.roulettePlayer].rawValue))")
                .font(.title.bold())
        }
        .padding(34)
        .glassEffect(.regular, in: .rect(cornerRadius: 32))
        .animation(.spring(response: 0.20, dampingFraction: 0.68), value: game.roulettePlayer)
    }
}

// MARK: - 胜者
struct WinnerView: View {
    @ObservedObject var game: GameModel
    let player: Int

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "crown.fill")
                .font(.system(size: 56))
                .foregroundStyle(game.colors[player])
            Text("\(game.names[player])获胜！").font(.largeTitle.bold())
            HStack {
                Button("返回菜单") {
                    game.returnToMenu()
                }
                .buttonStyle(.glass)

                Button("再来一局") {
                    game.prepareGame(size: game.boardSize)
                }
                .buttonStyle(.glassProminent)
            }
        }
        .padding(32)
        .glassEffect(.regular, in: .rect(cornerRadius: 30))
        .padding(24)
    }
}
