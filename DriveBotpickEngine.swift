import Foundation

/// Faithful Swift port of the Drive worker's `botpick` engine (`Rt`/`ke`/`Et`).
/// The game-policy wrapper (opening book, level timing and optional mistake rate)
/// remains outside this search core, as it is in the Drive online client.
enum DriveBotpickEngine {
    struct Limits {
        let timeMs: Double
        let softTimeMs: Double?
        let minTimeMs: Double
        let maxDepth: Int
    }

    struct Result {
        let move: Int
        let depth: Int
        let score: Int
        let nodes: Int
    }

    struct CascadeFrame {
        let cells: [UInt8]
        let exploding: [Int]
    }

    struct Transition {
        let cells: [UInt8]
        let placementCells: [UInt8]
        let cascadeFrames: [CascadeFrame]
        let nextSide: Int
        let winner: Int?
    }

    static func decodedOwner(_ code: UInt8) -> Int? {
        code == 0 ? nil : owner(code)
    }

    static func decodedCharge(_ code: UInt8) -> Int { charge(code) }

    private static let boardCapacity = 12
    private static let maxPly = 48
    private static let winScore = 1_000_000
    private static let infinity = 1_000_000_000
    private static let zobrist: [UInt64] = {
        var seed: UInt64 = 0xc0ffee
        return (0..<(boardCapacity * boardCapacity * 2 * 8)).map { index in
            seed = splitmix64(seed &+ UInt64(index))
            return seed
        }
    }()
    private static let sideKey = splitmix64(zobrist[zobrist.count - 1] &+ 0xabcdef)

    @inline(__always)
    private static func splitmix64(_ input: UInt64) -> UInt64 {
        var value = input &+ 0x9e3779b97f4a7c15
        value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
        value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
        return value ^ (value >> 31)
    }

    @inline(__always)
    private static func owner(_ code: UInt8) -> Int { code == 0 ? -1 : (code & 0x80 == 0 ? 0 : 1) }
    @inline(__always)
    private static func charge(_ code: UInt8) -> Int { Int(code & 0x0f) }
    @inline(__always)
    private static func encode(_ side: Int, _ amount: Int) -> UInt8 {
        // Drive packs owner in bit 7 independently from charge. In particular,
        // blue/zero-charge is 0x80 (not empty); red/zero-charge aliases 0 just
        // as it does in the JavaScript bitboard representation.
        return UInt8((side == 1 ? 0x80 : 0) | (amount & 0x0f))
    }

    private static func neighbors(_ index: Int, _ size: Int) -> [Int] {
        let row = index / size
        let column = index % size
        var result: [Int] = []
        if column + 1 < size { result.append(index + 1) }
        if column > 0 { result.append(index - 1) }
        if row + 1 < size { result.append(index + size) }
        if row > 0 { result.append(index - size) }
        return result
    }

    private struct CellUndo { let index: Int; let oldValue: UInt8 }
    private struct Frame {
        let undoStart: Int
        let side: Int
        let movesRed: Int
        let movesBlue: Int
        let winner: Int?
        let redCount: Int
        let blueCount: Int
        let hash: UInt64
    }
    private struct Position {
        var cells: [UInt8]
        let size: Int
        var side: Int
        var movesRed: Int
        var movesBlue: Int
        var winner: Int?
        var redCount: Int
        var blueCount: Int
        var hash: UInt64
        var cellUndo: [CellUndo] = []
        var frames: [Frame] = []

        mutating func setCell(_ index: Int, _ value: UInt8) {
            let old = cells[index]
            guard old != value else { return }
            cellUndo.append(CellUndo(index: index, oldValue: old))
            if old != 0 {
                let oldOwner = DriveBotpickEngine.owner(old)
                if oldOwner == 0 { redCount -= 1 } else { blueCount -= 1 }
                hash ^= DriveBotpickEngine.zobristKey(index, old)
            }
            if value != 0 {
                let newOwner = DriveBotpickEngine.owner(value)
                if newOwner == 0 { redCount += 1 } else { blueCount += 1 }
                hash ^= DriveBotpickEngine.zobristKey(index, value)
            }
            cells[index] = value
        }

        @discardableResult
        mutating func makeMove(_ index: Int, captureCascade: Bool = false) -> (placementCells: [UInt8], waves: [CascadeFrame])? {
            frames.append(Frame(undoStart: cellUndo.count, side: side,
                                movesRed: movesRed, movesBlue: movesBlue,
                                winner: winner, redCount: redCount,
                                blueCount: blueCount, hash: hash))
            let mover = side
            let targetCharge = DriveBotpickEngine.charge(cells[index]) + 1
            setCell(index, DriveBotpickEngine.encode(mover, targetCharge))
            let placementCells = captureCascade ? cells : []
            var capturedWaves: [CascadeFrame] = []

            var resolved = false
            for _ in 0..<(size * size * 8) {
                let wave = cells.indices.filter { cells[$0] != 0 && DriveBotpickEngine.charge(cells[$0]) >= 4 }
                if wave.isEmpty { break }
                var explodedThisWave: [Int] = []
                for explodingIndex in wave {
                    let source = cells[explodingIndex]
                    guard source != 0 && DriveBotpickEngine.charge(source) >= 4 else { continue }
                    let sourceOwner = DriveBotpickEngine.owner(source)
                    explodedThisWave.append(explodingIndex)
                    setCell(explodingIndex, 0)
                    for adjacent in DriveBotpickEngine.neighbors(explodingIndex, size) {
                        setCell(adjacent, DriveBotpickEngine.encode(sourceOwner,
                                  DriveBotpickEngine.charge(cells[adjacent]) + 1))
                    }
                    if redCount == 0 || blueCount == 0 {
                        resolved = true
                        break
                    }
                }
                if captureCascade && !explodedThisWave.isEmpty {
                    capturedWaves.append(CascadeFrame(cells: cells, exploding: explodedThisWave))
                }
                if resolved { break }
            }

            if mover == 0 { movesRed += 1 } else { movesBlue += 1 }
            if movesRed >= 1 && movesBlue >= 1 {
                if redCount == 0 && blueCount > 0 { winner = 1 }
                else if blueCount == 0 && redCount > 0 { winner = 0 }
            }
            if winner == nil {
                side = 1 - mover
                hash ^= DriveBotpickEngine.sideKey
            }
            return captureCascade ? (placementCells, capturedWaves) : nil
        }

        mutating func unmakeMove() {
            guard let frame = frames.popLast() else { return }
            while cellUndo.count > frame.undoStart {
                let change = cellUndo.removeLast()
                cells[change.index] = change.oldValue
            }
            side = frame.side
            movesRed = frame.movesRed
            movesBlue = frame.movesBlue
            winner = frame.winner
            redCount = frame.redCount
            blueCount = frame.blueCount
            hash = frame.hash
        }
    }

    private static func zobristKey(_ index: Int, _ code: UInt8) -> UInt64 {
        guard code != 0 else { return 0 }
        let side = owner(code)
        let amount = min(8, charge(code))
        guard amount > 0 else { return 0 }
        return zobrist[(index * 2 + side) * 8 + amount - 1]
    }

    private struct Entry {
        let depth: Int
        let score: Int
        let flag: Int // 0 exact, 1 lower bound, 2 upper bound
        let bestMove: Int
    }
    private struct SearchContext {
        let deadline: Double
        var nodes = 0
        var stopped = false
        var table: [UInt64: Entry] = [:]
        var killers = Array(repeating: [-1, -1], count: maxPly + 4)
        var history = Array(repeating: 0, count: 2 * 144)
    }
    private struct NodeResult { let score: Int; let bestMove: Int }

    private static func pieceCount(_ position: Position, _ side: Int) -> Int {
        side == 0 ? position.redCount : position.blueCount
    }

    private static func legalMoves(_ position: Position) -> [Int] {
        guard position.winner == nil else { return [] }
        return position.cells.indices.filter { owner(position.cells[$0]) == position.side }
    }

    // Port of worker.pretty.js `rt()` (the bitboard bot evaluation), not `ie()`/`Ce()`.
    private static func evaluate(_ position: Position) -> Int {
        if let winner = position.winner { return winner == position.side ? winScore : -winScore }
        let side = position.side
        var pieces = [0, 0]
        var totalCharge = [0, 0]
        var critical = [0, 0]
        for code in position.cells where code != 0 {
            let player = owner(code)
            let amount = charge(code)
            pieces[player] += 1
            totalCharge[player] += amount
            if amount == 3 { critical[player] += 1 }
        }
        var exposedCritical = [0, 0]
        var exposedCharge = [0, 0]
        for index in position.cells.indices where position.cells[index] != 0 && charge(position.cells[index]) == 3 {
            let player = owner(position.cells[index])
            var adjacentEnemyCharge = 0
            for adjacent in neighbors(index, position.size) {
                let code = position.cells[adjacent]
                if code != 0 && owner(code) != player { adjacentEnemyCharge += charge(code) }
            }
            if adjacentEnemyCharge > 0 {
                exposedCritical[player] += 1
                exposedCharge[player] += adjacentEnemyCharge
            }
        }
        let opponent = 1 - side
        return (pieces[side] - pieces[opponent]) * 35
            + (totalCharge[side] - totalCharge[opponent]) * 4
            + (critical[side] - critical[opponent]) * 8
            + (exposedCritical[side] - exposedCritical[opponent]) * 60
            + (exposedCharge[side] - exposedCharge[opponent]) * 12
    }

    // Port of worker.pretty.js `Tt()` move ordering, including killers/history.
    private static func moveOrderScore(_ position: Position, move: Int, ttMove: Int,
                                       ply: Int, context: SearchContext) -> Int {
        if move == ttMove { return 1_000_000_000 }
        let side = position.side
        let nextCharge = charge(position.cells[move]) + 1
        let adjacent = neighbors(move, position.size)
        if nextCharge >= 4 {
            var score = 1_000_000
            for index in adjacent {
                let code = position.cells[index]
                if code != 0 && owner(code) != side {
                    let amount = charge(code)
                    score += amount * 10
                    if amount == 3 { score += 200 }
                }
            }
            return score
        }
        let historyScore = context.history[side * 144 + move]
        var score = context.killers[ply][0] == move ? 800_000 : (context.killers[ply][1] == move ? 700_000 : 0)
        score += historyScore
        if nextCharge == 3 { score += 100 }
        score += nextCharge * 2
        for index in adjacent {
            let code = position.cells[index]
            if code != 0 && owner(code) != side && charge(code) == 3 {
                score -= nextCharge == 3 ? 300 : 80
            }
        }
        return score
    }

    private static func recordQuietCutoff(_ context: inout SearchContext, move: Int, side: Int,
                                          depth: Int, ply: Int) {
        if context.killers[ply][0] != move {
            context.killers[ply][1] = context.killers[ply][0]
            context.killers[ply][0] = move
        }
        context.history[side * 144 + move] += depth * depth
    }

    // Port of worker.pretty.js `ke()` (full negamax/alpha-beta, TT and NMP).
    private static func search(_ position: inout Position, depth: Int, alpha inputAlpha: Int,
                               beta: Int, ply: Int, context: inout SearchContext,
                               pvNode: Bool) -> NodeResult {
        context.nodes += 1
        if context.nodes & 4095 == 0 && ProcessInfo.processInfo.systemUptime >= context.deadline {
            context.stopped = true
        }
        if context.stopped { return NodeResult(score: 0, bestMove: -1) }
        if let winner = position.winner {
            let score = winner == position.side ? winScore + depth : -winScore - depth
            return NodeResult(score: score, bestMove: -1)
        }

        let hash = position.hash
        let cached = context.table[hash]
        let ttMove = cached?.bestMove ?? -1
        var alpha = inputAlpha
        if let cached, cached.depth >= depth {
            if cached.flag == 0 { return NodeResult(score: cached.score, bestMove: cached.bestMove) }
            if cached.flag == 1 && cached.score >= beta { return NodeResult(score: cached.score, bestMove: cached.bestMove) }
            if cached.flag == 2 && cached.score <= alpha { return NodeResult(score: cached.score, bestMove: cached.bestMove) }
        }
        if depth <= 0 { return NodeResult(score: evaluate(position), bestMove: -1) }

        let side = position.side
        if pvNode && depth >= 3 && beta - alpha == 1 && pieceCount(position, side) >= 3 {
            let oldSide = position.side
            position.side = 1 - oldSide
            position.hash ^= sideKey
            let reduction = depth >= 6 ? 3 : 2
            let nullResult = search(&position, depth: depth - 1 - reduction,
                                    alpha: -beta, beta: -beta + 1,
                                    ply: ply + 1, context: &context, pvNode: false)
            let nullScore = -nullResult.score
            position.side = oldSide
            position.hash ^= sideKey
            if context.stopped { return NodeResult(score: 0, bestMove: -1) }
            if nullScore >= beta { return NodeResult(score: nullScore, bestMove: -1) }
        }

        var moves = legalMoves(position)
        guard !moves.isEmpty else { return NodeResult(score: evaluate(position), bestMove: -1) }
        var ordered = moves.map { (move: $0, score: moveOrderScore(position, move: $0, ttMove: ttMove, ply: ply, context: context)) }
        // Match the reference engine's stable insertion sort: equal scores keep row-major order.
        if ordered.count > 1 {
            for index in 1..<ordered.count {
                let item = ordered[index]
                var destination = index - 1
                while destination >= 0 && ordered[destination].score < item.score {
                    ordered[destination + 1] = ordered[destination]
                    destination -= 1
                }
                ordered[destination + 1] = item
            }
        }
        moves = ordered.map(\.move)
        let originalAlpha = alpha
        var bestScore = -infinity
        var bestMove = moves[0]
        for move in moves {
            let quiet = charge(position.cells[move]) + 1 < 4
            position.makeMove(move)
            let score: Int
            if let winner = position.winner {
                score = winner == side ? winScore + depth : -winScore - depth
            } else {
                let child = search(&position, depth: depth - 1, alpha: -beta, beta: -alpha,
                                   ply: ply + 1, context: &context, pvNode: true)
                score = -child.score
            }
            position.unmakeMove()
            if context.stopped { return NodeResult(score: 0, bestMove: -1) }
            if score > bestScore { bestScore = score; bestMove = move }
            if score > alpha { alpha = score }
            if alpha >= beta {
                if quiet { recordQuietCutoff(&context, move: move, side: side, depth: depth, ply: ply) }
                break
            }
        }
        let flag = bestScore <= originalAlpha ? 2 : (bestScore >= beta ? 1 : 0)
        context.table[hash] = Entry(depth: depth, score: bestScore, flag: flag, bestMove: bestMove)
        return NodeResult(score: bestScore, bestMove: bestMove)
    }

    static func applyMove(cells inputCells: [UInt8], size: Int, side: Int,
                          movesRed: Int, movesBlue: Int, move: Int) -> Transition? {
        guard (2...boardCapacity).contains(size), inputCells.count == size * size,
              side == 0 || side == 1, inputCells.indices.contains(move) else { return nil }
        var redCount = 0, blueCount = 0, hash: UInt64 = 0
        for index in inputCells.indices where inputCells[index] != 0 {
            let code = inputCells[index]
            if owner(code) == 0 { redCount += 1 } else { blueCount += 1 }
            hash ^= zobristKey(index, code)
        }
        if side == 1 { hash ^= sideKey }
        var position = Position(cells: inputCells, size: size, side: side,
                                movesRed: movesRed, movesBlue: movesBlue, winner: nil,
                                redCount: redCount, blueCount: blueCount, hash: hash)
        guard legalMoves(position).contains(move) else { return nil }
        guard let trace = position.makeMove(move, captureCascade: true) else { return nil }
        return Transition(cells: position.cells, placementCells: trace.placementCells,
                          cascadeFrames: trace.waves, nextSide: position.side, winner: position.winner)
    }

    static func bestMove(cells inputCells: [UInt8], size: Int, side: Int,
                         movesRed: Int, movesBlue: Int, limits: Limits) -> Result? {
        guard (2...boardCapacity).contains(size), inputCells.count == size * size,
              side == 0 || side == 1 else { return nil }
        let cells = Array(inputCells.prefix(size * size))
        var redCount = 0, blueCount = 0
        var hash: UInt64 = 0
        for index in cells.indices where cells[index] != 0 {
            let code = cells[index]
            if owner(code) == 0 { redCount += 1 } else { blueCount += 1 }
            hash ^= zobristKey(index, code)
        }
        if side == 1 { hash ^= sideKey }
        var winner: Int?
        if movesRed >= 1 && movesBlue >= 1 {
            if redCount == 0 && blueCount > 0 { winner = 1 }
            else if blueCount == 0 && redCount > 0 { winner = 0 }
        }
        if winner != nil { return nil }
        var position = Position(cells: cells, size: size, side: side,
                                movesRed: movesRed, movesBlue: movesBlue,
                                winner: nil, redCount: redCount, blueCount: blueCount, hash: hash)
        let rootMoves = legalMoves(position)
        guard let first = rootMoves.first else { return nil }
        if rootMoves.count == 1 { return Result(move: first, depth: 1, score: 0, nodes: 0) }

        let started = ProcessInfo.processInfo.systemUptime
        var context = SearchContext(deadline: started + max(0, limits.timeMs) / 1000)
        var bestMove = -1
        var bestScore = 0
        var completedDepth = 0
        var priorMoves: [Int] = []
        var priorScores: [Int] = []
        let hardDeadline = started + max(0, limits.timeMs) / 1000
        let softDeadline = limits.softTimeMs.map { started + min($0, limits.timeMs) / 1000 } ?? hardDeadline
        let minDeadline = limits.softTimeMs.map { started + min(limits.minTimeMs, $0) / 1000 } ?? started

        if limits.maxDepth > 0 {
            for depth in 1...limits.maxDepth {
                if ProcessInfo.processInfo.systemUptime >= hardDeadline || Task.isCancelled { break }
                context.stopped = false
                let result = search(&position, depth: depth, alpha: -infinity, beta: infinity,
                                    ply: 0, context: &context, pvNode: true)
                if context.stopped || Task.isCancelled { break }
                bestMove = result.bestMove
                bestScore = result.score
                completedDepth = depth
                priorMoves.append(result.bestMove)
                priorScores.append(result.score)
                if result.score > 900_000 || result.score < -900_000 { break }

                if limits.softTimeMs != nil && depth >= 6 {
                    let now = ProcessInfo.processInfo.systemUptime
                    if now >= minDeadline && now >= softDeadline && priorMoves.count >= 3 {
                        let recent = Array(priorMoves.suffix(3))
                        let scoreChange = abs(bestScore - priorScores[priorScores.count - 3])
                        if recent.allSatisfy({ $0 == recent[0] }) && scoreChange <= 8 { break }
                    }
                }
            }
        }
        if bestMove < 0 { bestMove = first }
        return Result(move: bestMove, depth: completedDepth, score: bestScore, nodes: context.nodes)
    }
}
