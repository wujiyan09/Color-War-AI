import Foundation

// MARK: - AI difficulty configuration

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

    var webTitle: String {
        switch self {
        case .fast: return "1档 · 快手"
        case .balanced: return "2档 · 平衡"
        case .deep: return "3档 · 深谋"
        case .extreme: return "4档 · 极限"
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

    // Bound local search work so large boards cannot monopolize the iOS process.
    var searchTimeBudget: TimeInterval {
        switch self {
        case .fast: return 0.08
        case .balanced: return 0.25
        case .deep: return 1.2
        case .extreme: return 6.0
        }
    }
}


// MARK: - 6. Zobrist 与启发式算力结构

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

private enum DriveOpeningBook {
    // Port of the 13 deterministic opening sequences used by Drive's online bot.
    // Local games use their session UUID in place of a server room code.
    static func patterns(size: Int) -> [[(Int, Int)]]? {
        guard [6, 9, 12].contains(size) else { return nil }
        let edge = size - 1
        let corners: [(Int, Int, Int, Int)] = [
            (0, 0, 1, 1), (edge, 0, -1, 1), (0, edge, 1, -1), (edge, edge, -1, -1)
        ]
        let cornerPatterns = corners.map { corner in
            let (x, y, dx, dy) = corner
            return [(x, y), (x + dx, y), (x, y + dy), (x + dx, y + dy),
                    (x, y), (x + dx, y + dy), (x + 2 * dx, y), (x, y + 2 * dy),
                    (x + 2 * dx, y + dy), (x + dx, y + 2 * dy), (x + 2 * dx, y + 2 * dy), (x + dx, y)]
        }
        func repeated(_ values: [(Int, Int)]) -> [(Int, Int)] {
            Array((values + values).prefix(12))
        }
        func diagonal(reverse: Bool) -> [(Int, Int)] {
            let line = (0..<size).map { i in reverse ? (i, edge - i) : (i, i) }
            var ordered: [(Int, Int)] = []
            for i in 0..<((size + 1) / 2) {
                ordered.append(line[i])
                if edge - i != i { ordered.append(line[edge - i]) }
            }
            return repeated(ordered)
        }
        func edgeLine(_ side: String) -> [(Int, Int)] {
            let line = (0..<size).map { i -> (Int, Int) in
                switch side {
                case "top": return (i, 0)
                case "bottom": return (i, edge)
                case "left": return (0, i)
                default: return (edge, i)
                }
            }
            var ordered = [line[0], line[edge]]
            if size / 2 > 1 {
                for i in 1..<(size / 2) { ordered += [line[i], line[edge - i]] }
            }
            if size % 2 == 1 { ordered.append(line[size / 2]) }
            return repeated(ordered)
        }
        let middle = size / 2 - 1
        let next = middle + 1
        let center = [(middle, middle), (next, next), (middle, next), (next, middle),
                      (middle, middle), (next, next), (middle - 1, middle), (next + 1, next),
                      (middle, middle - 1), (next, next + 1), (next + 1, middle), (middle - 1, next),
                      (next, middle), (middle, next)].filter {
            $0.0 >= 0 && $0.0 < size && $0.1 >= 0 && $0.1 < size
        }
        let cornerCycle = [(0, 0), (edge, edge), (0, 0), (edge, edge), (0, 0), (edge, edge),
                           (1, 0), (edge - 1, edge), (0, 1), (edge, edge - 1), (1, 1), (edge - 1, edge - 1)]
        return [
            [(0, 0), (edge, edge), (edge, 0), (0, edge), (1, 0), (edge - 1, edge),
             (edge, 1), (0, edge - 1), (1, 1), (edge - 1, edge - 1), (edge - 1, 1), (1, edge - 1)],
            cornerPatterns[0], cornerPatterns[1], cornerPatterns[2], cornerPatterns[3],
            diagonal(reverse: false), diagonal(reverse: true), edgeLine("top"), edgeLine("bottom"),
            edgeLine("left"), edgeLine("right"), Array(center.prefix(12)), cornerCycle
        ]
    }

    static func nextOwnedMove(cells: [UInt8], size: Int, side: Int, startIndex: Int, seed: String) -> Int? {
        guard let patterns = patterns(size: size), !patterns.isEmpty else { return nil }
        var hash: UInt32 = 2_166_136_261
        for unit in seed.utf16 {
            hash ^= UInt32(unit)
            hash = hash &* 16_777_619
        }
        let pattern = patterns[Int(hash % UInt32(patterns.count))]
        guard startIndex < pattern.count else { return nil }
        for (x, y) in pattern.dropFirst(max(0, startIndex)) {
            let index = y * size + x
            if index >= 0 && index < cells.count && DriveDuelSearch.owner(cells[index]) == side {
                return index
            }
        }
        return nil
    }
}

private struct DriveDuelSearch {
    private static let mask64 = UInt64.max
    private static func splitmix64(_ value: UInt64) -> UInt64 {
        var z = value &+ 0x9e3779b97f4a7c15
        z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        return z ^ (z >> 31)
    }
    private static let zobrist: [UInt64] = {
        var seed: UInt64 = 0xc0ffee
        return (0..<(12 * 12 * 2 * 8)).map { i in
            seed = splitmix64(seed &+ UInt64(i))
            return seed
        }
    }()
    private static let sideKey = splitmix64(zobrist.last! &+ 0xabcdef)
    private static let enteredKeys = [splitmix64(zobrist.last! &+ 0x111111), splitmix64(zobrist.last! &+ 0x222222)]
    private static let directions = [1, -1] // horizontal; vertical neighbors are appended by index
    private static let winScore = 1_000_000
    private static let maxPly = 48
    private static let infinity = 1_000_000_000

    // Drive's difficulty budgets and local-phase scheduler are independent
    // constraints. Use the stricter time/depth cap and preserve phase soft limits.
    private struct SearchParameters {
        let timeMs: Double
        let softTimeMs: Double
        let minTimeMs: Double
        let maxDepth: Int
    }
    private static func parameters(level: Int, movesPlayed: Int, timeLimitOverride: TimeInterval? = nil) -> SearchParameters {
        if let timeLimitOverride {
            let timeMs = min(5000, max(80, timeLimitOverride * 1000))
            return SearchParameters(timeMs: timeMs,
                                    softTimeMs: timeMs,
                                    minTimeMs: min(500, timeMs * 0.8),
                                    maxDepth: 32)
        }
        let difficulty: (timeMs: Double, maxDepth: Int)
        // Match the Drive engine profile; local-game phase limits are applied below.
        // The online wrapper has a separate 250ms/depth-3 medium cap, but this
        // two-player local path uses the engine's 1200ms/depth-8 medium profile.
        switch level {
        case 1: difficulty = (80, 1)
        case 2: difficulty = (1200, 8)
        default: difficulty = (6000, 32)
        }
        let phase: (timeMs: Double, softTimeMs: Double, minTimeMs: Double, maxDepth: Int)
        if movesPlayed < 30 {
            phase = (400, 120, 40, 8)
        } else {
            // Values from Drive's local play wrapper.
            phase = (5000, 600, 80, 32)
        }
        let timeMs = min(difficulty.timeMs, phase.timeMs)
        let softTimeMs = min(phase.softTimeMs, timeMs)
        return SearchParameters(
            timeMs: timeMs,
            softTimeMs: softTimeMs,
            minTimeMs: min(phase.minTimeMs, softTimeMs),
            maxDepth: min(difficulty.maxDepth, phase.maxDepth)
        )
    }
    static func timeBudget(level: Int, movesPlayed: Int = 0, timeLimitOverride: TimeInterval? = nil) -> TimeInterval {
        parameters(level: level, movesPlayed: movesPlayed, timeLimitOverride: timeLimitOverride).timeMs / 1000
    }

    private struct Entry {
        var depth: Int
        var score: Int
        var flag: Int // 0 exact, 1 lower, 2 upper
        var move: Int
    }
    private struct Context {
        let deadline: Double
        var nodes = 0
        var stopped = false
        var table: [UInt64: Entry] = [:]
        var killers = Array(repeating: [-1, -1], count: maxPly + 1)
        var history = Array(repeating: 0, count: 2 * 144)
    }
    private struct Result { var score: Int; var move: Int }

    fileprivate static func owner(_ code: UInt8) -> Int { code == 0 ? -1 : Int(code >> 4) - 1 }
    private static func charge(_ code: UInt8) -> Int { Int(code & 15) }
    private static func encode(_ owner: Int, _ charge: Int) -> UInt8 {
        guard charge > 0 else { return 0 }
        return UInt8(((owner + 1) << 4) | charge)
    }
    private static func neighbors(_ index: Int, _ size: Int) -> [Int] {
        let row = index / size, column = index % size
        var result: [Int] = []
        if column + 1 < size { result.append(index + 1) }
        if column > 0 { result.append(index - 1) }
        if row + 1 < size { result.append(index + size) }
        if row > 0 { result.append(index - size) }
        return result
    }
    private static func key(_ cells: [UInt8], _ side: Int, _ enteredMask: Int) -> UInt64 {
        var value: UInt64 = 0
        for (i, code) in cells.enumerated() where code != 0 {
            let player = owner(code), count = min(8, charge(code))
            value ^= zobrist[(i * 2 + player) * 8 + count - 1]
        }
        if side == 1 { value ^= sideKey }
        if enteredMask & 1 != 0 { value ^= enteredKeys[0] }
        if enteredMask & 2 != 0 { value ^= enteredKeys[1] }
        return value
    }
    private static func legalMoves(_ cells: [UInt8], _ side: Int, _ enteredMask: Int, _ size: Int) -> [Int] {
        if enteredMask & (1 << side) == 0 { return cells.indices.filter { cells[$0] == 0 } }
        return cells.indices.filter { owner(cells[$0]) == side }
    }
    private static func counts(_ cells: [UInt8]) -> [Int] {
        var value = [0, 0]
        for code in cells where code != 0 { value[owner(code)] += 1 }
        return value
    }
    private static func terminal(_ cells: [UInt8], _ side: Int, _ enteredMask: Int, _ depth: Int) -> Int? {
        guard enteredMask == 3 else { return nil }
        let pieces = counts(cells)
        if pieces[0] == 0 && pieces[1] > 0 { return side == 1 ? winScore + depth : -winScore - depth }
        if pieces[1] == 0 && pieces[0] > 0 { return side == 0 ? winScore + depth : -winScore - depth }
        return nil
    }
    private static func connectedComponentSize(_ cells: [UInt8], _ side: Int, _ size: Int) -> Int {
        var seen = Set<Int>()
        var largest = 0
        for start in cells.indices where owner(cells[start]) == side && !seen.contains(start) {
            var stack = [start]
            seen.insert(start)
            var count = 0
            while let index = stack.popLast() {
                count += 1
                for neighbor in neighbors(index, size)
                where owner(cells[neighbor]) == side && seen.insert(neighbor).inserted {
                    stack.append(neighbor)
                }
            }
            largest = max(largest, count)
        }
        return largest
    }

    private static func captureScore(_ cells: [UInt8], _ move: Int, _ side: Int, _ enteredMask: Int, _ size: Int) -> Double {
        let before = counts(cells)
        let after = counts(simulate(cells, move, side, enteredMask, size).cells)
        let opponent = 1 - side
        if after[opponent] == 0 && before[opponent] > 0 { return Double(winScore) }
        let gain = after[side] - before[side]
        let loss = before[opponent] - after[opponent]
        return Double(gain) + Double(loss) * 1.4
    }

    private static func topCaptureScores(_ cells: [UInt8], _ side: Int, _ enteredMask: Int, _ size: Int) -> (best: Double, second: Double) {
        guard enteredMask & (1 << side) != 0 else { return (0, 0) }
        var best = 0.0, second = 0.0
        for index in cells.indices where owner(cells[index]) == side && charge(cells[index]) == 3 {
            let score = captureScore(cells, index, side, enteredMask, size)
            if score > best { second = best; best = score }
            else if score > second { second = score }
        }
        return (best, second)
    }

    private static func evaluate(_ cells: [UInt8], _ side: Int, _ enteredMask: Int) -> Int {
        if let result = terminal(cells, side, enteredMask, 0) { return result }
        let opponent = 1 - side
        let size = Int(Double(cells.count).squareRoot())
        var totalCharge = [0, 0], critical = [0, 0], nearCritical = [0, 0]
        for code in cells where code != 0 {
            let player = owner(code), amount = charge(code)
            totalCharge[player] += amount
            if amount >= 3 { critical[player] += 1 }
            else if amount >= 2 { nearCritical[player] += 1 }
        }
        let ownCapture = topCaptureScores(cells, side, enteredMask, size)
        let enemyCapture = topCaptureScores(cells, opponent, enteredMask, size)
        // Drive Ce(board, evalSide, sideToMove) uses 18/12 best-capture weights
        // from the side-to-move perspective, then a 4x second-best risk term.
        let captureValue = ownCapture.best * 18 - enemyCapture.best * 12
            + (ownCapture.second - enemyCapture.second) * 4
        let connected = connectedComponentSize(cells, side, size) - connectedComponentSize(cells, opponent, size)
        let score = Double(totalCharge[side] - totalCharge[opponent]) * 4
            + Double(critical[side] - critical[opponent]) * 18
            + Double(nearCritical[side] - nearCritical[opponent]) * 6
            + Double(connected) * 3
            + captureValue + 5
        return Int(score.rounded())
    }
    private static func simulate(_ cells: [UInt8], _ move: Int, _ side: Int, _ enteredMask: Int, _ size: Int) -> (cells: [UInt8], entered: Int) {
        var next = cells
        let increment = enteredMask & (1 << side) == 0 ? 3 : 1
        next[move] = encode(side, charge(next[move]) + increment)
        var newMask = enteredMask | (1 << side)
        // Drive bitboard reference resolves queued waves sequentially in flat-index order.
        for _ in 0..<(size * size * 8) {
            let wave = next.indices.filter { next[$0] != 0 && charge(next[$0]) >= 4 }
            if wave.isEmpty { break }
            for index in wave {
                let code = next[index]
                guard code != 0 && charge(code) >= 4 else { continue }
                let sourceOwner = owner(code)
                next[index] = encode(sourceOwner, charge(code) - 4)
                for neighbor in neighbors(index, size) {
                    next[neighbor] = encode(sourceOwner, charge(next[neighbor]) + 1)
                }
            }
        }
        return (next, newMask)
    }
    private static func criticalChain(_ cells: [UInt8], _ side: Int, _ size: Int) -> (pairs: Int, charge: Int) {
        let opponent = 1 - side
        var pairs = 0, chargeTotal = 0
        for index in cells.indices where owner(cells[index]) == side && charge(cells[index]) >= 3 {
            for neighbor in neighbors(index, size)
            where owner(cells[neighbor]) == opponent && charge(cells[neighbor]) >= 3 {
                pairs += 1
                chargeTotal += charge(cells[neighbor])
            }
        }
        return (pairs, chargeTotal)
    }

    private static func moveOrderScore(_ cells: [UInt8], _ move: Int, _ side: Int, _ enteredMask: Int, _ size: Int, _ ply: Int, _ ttMove: Int, _ context: Context) -> Double {
        let isFirst = enteredMask & (1 << side) == 0
        let nextCharge = charge(cells[move]) + (isFirst ? 3 : 1)
        var score = quietHeuristic(cells, move, side, enteredMask, size)
        if move == ttMove { score += 1_000_000_000 }
        else if nextCharge >= 4 { score += 1_000_000 }
        else if context.killers[ply][0] == move || context.killers[ply][1] == move { score += 500_000 }
        else { score += Double(context.history[side * 144 + move]) }
        return score
    }
    private static func quietHeuristic(_ cells: [UInt8], _ move: Int, _ side: Int, _ enteredMask: Int, _ size: Int) -> Double {
        let code = cells[move]
        let isFirst = enteredMask & (1 << side) == 0
        let newCharge = charge(code) + (isFirst ? 3 : 1)
        let enemy = 1 - side
        let adjacent = neighbors(move, size)
        var enemyCount = 0, enemy3 = 0, maxEnemy = 0, enemy2 = 0, own3 = 0, ownCount = 0, empty = 0, enemyCharge = 0
        for n in adjacent {
            let near = cells[n]
            if near == 0 { empty += 1; continue }
            let p = owner(near), q = charge(near)
            if p == side { ownCount += 1; if q == 3 { own3 += 1 } }
            else { enemyCount += 1; enemyCharge += q; maxEnemy = max(maxEnemy, q); if q == 3 { enemy3 += 1 }; if q == 2 { enemy2 += 1 } }
        }
        if newCharge >= 4 {
            let next = simulate(cells, move, side, enteredMask, size).cells
            let before = counts(cells), after = counts(next)
            var score = Double((after[side] - before[side]) * 18 + (before[enemy] - after[enemy]) * 26)
            if after[enemy] == 0 && before[enemy] > 0 { score += 500_000 }
            score += Double(enemyCount * 30 + enemy3 * 90) + Double(empty) * 0.4
            let readyThreat = criticalChain(cells, side, size)
            if readyThreat.pairs > 0 { score += 280 + Double(readyThreat.charge) * 12 }
            return score
        }
        var score = 0.0
        if enemy3 > 0 {
            score -= Double(95 + newCharge * 24 + maxEnemy * 18)
            if newCharge == 3 { score -= Double(250 + own3 * 95) }
        }
        if newCharge == 3 && enemy2 > 0 { score -= Double(105 * enemy2) }
        if newCharge == 3 && enemyCount > 0 { score -= Double(30 * enemyCount) }
        if newCharge == 3 && enemyCount == 0 { score += Double(22 + own3 * 4) }
        let exposed = criticalChain(cells, side, size)
        if exposed.pairs > 0 { score -= 290 + Double(exposed.charge) * 12 }
        score += Double(newCharge) * 0.5 + Double(4 - newCharge) * 2.5 + Double(ownCount) + Double(empty) * 0.25 - Double(enemyCount * 2)
        let total = counts(cells).reduce(0, +)
        if total <= 8 && !isFirst {
            let row = move / size, column = move % size, center = size / 2
            let distance = side == 0 ? row + column : 2 * (size - 1) - row - column
            score += Double(max(0, center - distance)) * 2.5
        }
        if total >= 30 && newCharge == 3 { score -= 8 }
        return score
    }
    private static func search(_ cells: [UInt8], _ side: Int, _ enteredMask: Int, _ depth: Int,
                               _ alphaIn: Int, _ beta: Int, _ ply: Int,
                               _ context: inout Context, _ size: Int, isPV: Bool = true) -> Result {
        context.nodes += 1
        if context.nodes & 255 == 0 && ProcessInfo.processInfo.systemUptime >= context.deadline {
            context.stopped = true
        }
        if context.stopped || ply >= maxPly { return Result(score: evaluate(cells, side, enteredMask), move: -1) }
        if let result = terminal(cells, side, enteredMask, depth) { return Result(score: result, move: -1) }
        let hash = key(cells, side, enteredMask), cached = context.table[hash]
        let ttMove = cached?.move ?? -1
        let oldAlpha = alphaIn
        var alpha = alphaIn
        if let cached, cached.depth >= depth {
            if cached.flag == 0 { return Result(score: cached.score, move: cached.move) }
            if cached.flag == 1 && cached.score >= beta { return Result(score: cached.score, move: cached.move) }
            if cached.flag == 2 && cached.score <= alpha { return Result(score: cached.score, move: cached.move) }
        }
        if depth <= 0 { return Result(score: evaluate(cells, side, enteredMask), move: -1) }

        let sidePieces = cells.reduce(0) { $0 + (owner($1) == side ? 1 : 0) }
        if ply > 0 && isPV && depth >= 3 && beta - alpha == 1 && sidePieces >= 3 {
            let reduction = depth >= 6 ? 3 : 2
            let nullChild = search(cells, 1 - side, enteredMask, depth - 1 - reduction,
                                   -beta, -beta + 1, ply + 1, &context, size, isPV: false)
            let nullScore = -nullChild.score
            if context.stopped { return Result(score: evaluate(cells, side, enteredMask), move: -1) }
            if nullScore >= beta { return Result(score: nullScore, move: -1) }
        }

        let moves = legalMoves(cells, side, enteredMask, size).sorted {
            moveOrderScore(cells, $0, side, enteredMask, size, ply, ttMove, context)
                > moveOrderScore(cells, $1, side, enteredMask, size, ply, ttMove, context)
        }
        guard !moves.isEmpty else { return Result(score: evaluate(cells, side, enteredMask), move: -1) }
        let originalBeta = beta
        var best = -infinity, bestMove = moves[0], searched = 0
        for move in moves {
            let isFirst = enteredMask & (1 << side) == 0
            let nextCharge = charge(cells[move]) + (isFirst ? 3 : 1)
            let tactical = nextCharge >= 4
            let extension = tactical && depth <= 3 && ply < maxPly - 4 ? 1 : 0
            let next = simulate(cells, move, side, enteredMask, size)
            let childDepth = depth - 1 + extension
            var child: Result
            var score: Int
            if searched == 0 {
                child = search(next.cells, 1 - side, next.entered, childDepth,
                               -beta, -alpha, ply + 1, &context, size, isPV: true)
                score = -child.score
            } else {
                var reduction = 0
                if !tactical && extension == 0 && depth >= 3 && searched >= 3 {
                    reduction = searched >= 6 ? 2 : 1
                    reduction = min(reduction, max(0, depth - 2))
                }
                child = search(next.cells, 1 - side, next.entered, childDepth - reduction,
                               -alpha - 1, -alpha, ply + 1, &context, size, isPV: true)
                score = -child.score
                if !context.stopped && score > alpha && (reduction > 0 || beta - alpha > 1) {
                    child = search(next.cells, 1 - side, next.entered, childDepth,
                                   -beta, -alpha, ply + 1, &context, size, isPV: true)
                    score = -child.score
                }
            }
            if score > best { best = score; bestMove = move }
            if score > alpha { alpha = score }
            searched += 1
            if alpha >= beta {
                if !tactical {
                    if context.killers[ply][0] != move {
                        context.killers[ply][1] = context.killers[ply][0]
                        context.killers[ply][0] = move
                    }
                    let index = side * 144 + move
                    context.history[index] += depth * depth
                }
                break
            }
            if context.stopped { break }
        }
        guard !context.stopped, best != -infinity else {
            return Result(score: best == -infinity ? evaluate(cells, side, enteredMask) : best, move: bestMove)
        }
        let flag = best <= oldAlpha ? 2 : (best >= originalBeta ? 1 : 0)
        context.table[hash] = Entry(depth: depth, score: best, flag: flag, move: bestMove)
        return Result(score: best, move: bestMove)
    }

    static func bestMove(board: AISolver.Board, activePlayers: [Int], currentPlayer: Int, hasEntered: [Bool], level: Int, movesPlayed: Int, openingSeed: String, timeLimitOverride: TimeInterval? = nil) -> (Int, Int)? {
        guard (2...12).contains(board.size), activePlayers.count == 2, let side = activePlayers.firstIndex(of: currentPlayer) else { return nil }
        let size = board.size
        var cells = [UInt8](repeating: 0, count: size * size)
        for index in cells.indices {
            let value = board.cells[index]
            guard let local = activePlayers.firstIndex(of: value.owner ?? -1), value.count > 0 else { continue }
            cells[index] = encode(local, min(15, value.count))
        }
        var enteredMask = 0
        for sideIndex in 0..<2 {
            let player = activePlayers[sideIndex]
            if player < hasEntered.count && hasEntered[player] { enteredMask |= 1 << sideIndex }
        }
        let moves = legalMoves(cells, side, enteredMask, size)
        guard let first = moves.first else { return nil }
        if terminal(cells, side, enteredMask, 0) != nil { return nil }
        let searchParameters = parameters(level: level, movesPlayed: movesPlayed, timeLimitOverride: timeLimitOverride)
        // Drive's opening book applies to ordinary matches. The Analyzer deliberately
        // skips it so its chosen time budget is spent searching from the first move.
        if timeLimitOverride == nil && movesPlayed < 30,
           let opening = DriveOpeningBook.nextOwnedMove(
                cells: cells, size: size, side: side, startIndex: movesPlayed / 2, seed: openingSeed
           ) {
            return (opening / size, opening % size)
        }
        if level == 1 {
            let ranked = moves.map { ($0, quietHeuristic(cells, $0, side, enteredMask, size)) }.sorted { $0.1 > $1.1 }
            guard let best = ranked.first else { return nil }
            let roll = Double.random(in: 0..<1)
            let selected: Int
            if roll < 0.25 && moves.count > 1 {
                selected = moves.randomElement()!
            } else if roll < 0.70 && moves.count > 1 {
                selected = ranked[Int.random(in: 0..<max(2, (ranked.count + 1) / 2))].0
            } else {
                selected = best.0
            }
            return (selected / size, selected % size)
        }
        if moves.count == 1 { return (first / size, first % size) }
        let maxDepth = searchParameters.maxDepth
        let startTime = ProcessInfo.processInfo.systemUptime
        var context = Context(deadline: startTime + searchParameters.timeMs / 1000)
        let ordered = moves.sorted {
            moveOrderScore(cells, $0, side, enteredMask, size, 0, -1, context)
                > moveOrderScore(cells, $1, side, enteredMask, size, 0, -1, context)
        }
        var best = ordered[0], depthCompleted = 0
        var completedMoves: [Int] = [], completedScores: [Int] = []
        for depth in 1...maxDepth {
            if ProcessInfo.processInfo.systemUptime >= context.deadline || Task.isCancelled { break }
            context.stopped = false
            var alpha = depth >= 4 ? completedScores.last.map { $0 - 50 } ?? -infinity : -infinity
            var beta = depth >= 4 ? completedScores.last.map { $0 + 50 } ?? infinity : infinity
            var window = 50
            var result: Result?
            while !context.stopped && !Task.isCancelled {
                let attempt = search(cells, side, enteredMask, depth, alpha, beta, 0, &context, size)
                if context.stopped || Task.isCancelled { break }
                if attempt.score <= alpha && alpha > -infinity {
                    window *= 2
                    if window > 4000 { alpha = -infinity; beta = infinity }
                    else { alpha = attempt.score - window; beta = attempt.score + 1 }
                    continue
                }
                if attempt.score >= beta && beta < infinity {
                    window *= 2
                    if window > 4000 { alpha = -infinity; beta = infinity }
                    else { alpha = attempt.score - 1; beta = attempt.score + window }
                    continue
                }
                result = attempt
                break
            }
            guard let result, !context.stopped, !Task.isCancelled, result.move >= 0 else { break }
            best = result.move; depthCompleted = depth
            completedMoves.append(result.move); completedScores.append(result.score)
            if abs(result.score) >= winScore - 1000 { break }
            let elapsedMs = (ProcessInfo.processInfo.systemUptime - startTime) * 1000
            if depth >= 6 && elapsedMs >= searchParameters.softTimeMs && elapsedMs >= searchParameters.minTimeMs && completedMoves.count >= 3 {
                let recentMoves = completedMoves.suffix(3)
                let scoreDelta = abs(result.score - completedScores[completedScores.count - 3])
                if let stableMove = recentMoves.first,
                   recentMoves.allSatisfy({ $0 == stableMove }), scoreDelta <= 8 { break }
            }
        }
        _ = depthCompleted
        // Drive's Medium mode deliberately plays the heuristic runner-up 25%
        // of the time; deeper modes keep the best searched move.
        if level == 2 && moves.count > 1 && Double.random(in: 0..<1) < 0.25 {
            let ranked = moves.map { ($0, quietHeuristic(cells, $0, side, enteredMask, size)) }.sorted { $0.1 > $1.1 }
            if ranked.count > 1 { best = ranked[1].0 }
        }
        return (best / size, best % size)
    }
}


// MARK: - 7. AI 算法引擎

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
    let isLocalDuelMode: Bool
    let localDuelMovesPlayed: Int
    let openingSeed: String
    private let searchTimeLimitOverride: TimeInterval?
    private let searchDeadline: TimeInterval
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
         eliminated: [Bool],
         isLocalDuelMode: Bool = false,
         localDuelMovesPlayed: Int = 0,
         openingSeed: String = "local",
         searchTimeLimitOverride: TimeInterval? = nil) {
        self.boardSize = boardSize
        self.activePlayers = activePlayers
        self.currentPlayer = currentPlayer
        self.playerType = playerType
        self.aiLevel = aiLevel
        self.isLocalDuelMode = isLocalDuelMode
        self.localDuelMovesPlayed = localDuelMovesPlayed
        self.openingSeed = openingSeed
        self.searchTimeLimitOverride = searchTimeLimitOverride
        let timeBudget = playerType == .driveBot
            ? DriveDuelSearch.timeBudget(level: aiLevel.rawValue, movesPlayed: localDuelMovesPlayed,
                                         timeLimitOverride: searchTimeLimitOverride)
            : aiLevel.searchTimeBudget
        self.searchDeadline = ProcessInfo.processInfo.systemUptime + timeBudget

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

    private var searchStopped: Bool {
        Task.isCancelled || ProcessInfo.processInfo.systemUptime >= searchDeadline
    }

    func calculateBestMove() async -> (Int, Int)? {
        if searchStopped { return nil }
        // The Drive botpick search is a two-player zero-sum engine. In party
        // games, continue into the shared multiplayer MaxN path instead of
        // returning nil before the bot can place its opening piece.
        if playerType == .driveBot && activePlayers.count == 2 {
            return DriveDuelSearch.bestMove(board: board, activePlayers: activePlayers, currentPlayer: currentPlayer,
                                            hasEntered: hasEntered, level: aiLevel.rawValue,
                                            movesPlayed: localDuelMovesPlayed, openingSeed: openingSeed,
                                            timeLimitOverride: searchTimeLimitOverride)
        }

        var validMoves = getPlayableCells(for: currentPlayer, on: board)
        guard !validMoves.isEmpty else { return nil }

        let isMyFirstTurn = (currentPlayer < hasEntered.count) ? !hasEntered[currentPlayer] : true
        let alivePlayerCount = activePlayers.filter { !isPlayerEliminated($0, in: eliminated) }.count
        if isMyFirstTurn && alivePlayerCount > 2 {
            let nonCornerMoves = validMoves.filter { !isCornerOpeningMove($0) }
            return selectOptimalOpeningMove(validMoves: nonCornerMoves.isEmpty ? validMoves : nonCornerMoves)
        }

        if isMyFirstTurn {
            return selectOptimalOpeningMove(validMoves: validMoves)
        }

        if playerType == .enhancedNightmare {
            if let strikeMove = findCriticalThreatMove(validMoves: validMoves) {
                return strikeMove
            }
        }

        return calculateAspirationNightmareMove(validMoves: validMoves)
    }

    private func isCornerOpeningMove(_ move: (Int, Int)) -> Bool {
        (move.0 == 0 || move.0 == boardSize - 1) &&
        (move.1 == 0 || move.1 == boardSize - 1)
    }

    private func selectOptimalOpeningMove(validMoves: [(Int, Int)]) -> (Int, Int)? {
        var occupiedIndices = Set<Int>()
        for idx in 0..<board.cells.count {
            if board.cells[idx].owner != nil {
                occupiedIndices.insert(idx)
            }
        }

        if occupiedIndices.isEmpty {
            let center = Double(boardSize - 1) / 2.0
            return validMoves.min(by: { m1, m2 in
                let dist1 = abs(Double(m1.0) - center) + abs(Double(m1.1) - center)
                let dist2 = abs(Double(m2.0) - center) + abs(Double(m2.1) - center)
                return dist1 < dist2
            })
        }

        let safe8Moves = validMoves.filter { move in
            let r = move.0
            let c = move.1
            for dr in -1...1 {
                for dc in -1...1 {
                    if dr == 0 && dc == 0 { continue }
                    let nr = r + dr
                    let nc = c + dc
                    if nr >= 0 && nr < boardSize && nc >= 0 && nc < boardSize {
                        let nIdx = nr * boardSize + nc
                        if occupiedIndices.contains(nIdx) {
                            return false
                        }
                    }
                }
            }
            return true
        }

        let safe4Moves: [(Int, Int)]
        if !safe8Moves.isEmpty {
            safe4Moves = safe8Moves
        } else {
            safe4Moves = validMoves.filter { move in
                let idx = move.0 * boardSize + move.1
                let neighbors = idx < neighborsMap.count ? neighborsMap[idx] : []
                return !neighbors.contains { occupiedIndices.contains($0) }
            }
        }

        let candidates = safe4Moves.isEmpty ? validMoves : safe4Moves
        let center = Double(boardSize - 1) / 2.0

        return candidates.max(by: { m1, m2 in
            let score1 = evaluateOpeningCandidateScore(move: m1, occupiedIndices: occupiedIndices, center: center)
            let score2 = evaluateOpeningCandidateScore(move: m2, occupiedIndices: occupiedIndices, center: center)
            return score1 < score2
        })
    }

    private func evaluateOpeningCandidateScore(move: (Int, Int), occupiedIndices: Set<Int>, center: Double) -> Double {
        let (r, c) = move
        let idx = r * boardSize + c

        let neighborsCount = idx < neighborsMap.count ? neighborsMap[idx].count : 2
        var score = Double(neighborsCount) * 100.0

        var minDistance = Double(boardSize * 2)
        for occIdx in occupiedIndices {
            let or = occIdx / boardSize
            let oc = occIdx % boardSize
            let chebyshevDist = max(abs(r - or), abs(c - oc))
            if Double(chebyshevDist) < minDistance {
                minDistance = Double(chebyshevDist)
            }
        }
        score += minDistance * 150.0

        let distToCenter = abs(Double(r) - center) + abs(Double(c) - center)
        score -= distToCenter * 20.0

        return score
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
            if searchStopped { break }

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
            if searchStopped { break }

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

            if searchStopped { break }
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
        if searchStopped { return 0 }

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
            if searchStopped { break }

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
        if searchStopped || qsDepth <= 0 {
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
        if searchStopped || depth <= 0 || isGameOverSimulated(eliminated: eliminatedState) {
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
            if searchStopped { break }

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
