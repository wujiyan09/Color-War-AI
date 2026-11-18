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
    // Port of Clock.pretty.js opening patterns used by play.local-DNTan253.js.
    // The local client seeds the picker per game session (not per room code).
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
    private struct SearchParameters {
        let timeMs: Double
        let softTimeMs: Double?
        let minTimeMs: Double
        let maxDepth: Int
    }

    fileprivate static func owner(_ code: UInt8) -> Int { code == 0 ? -1 : (code & 0x80 == 0 ? 0 : 1) }

    private static func analyzerParameters(timeLimitOverride: TimeInterval?) -> SearchParameters {
        let hard = min(5000, max(20, (timeLimitOverride ?? 5.0) * 1000))
        // dots-analyzer.html calls botpick directly; unlike the local-game
        // wrapper it supplies no softTimeMs/minTimeMs, so use botpick's 60ms default.
        return SearchParameters(timeMs: hard, softTimeMs: nil,
                                minTimeMs: 60, maxDepth: 32)
    }

    static func timeBudget(movesPlayed: Int = 0,
                           timeLimitOverride: TimeInterval? = nil,
                           directBotpickSearch: Bool = false) -> TimeInterval {
        (directBotpickSearch ? analyzerParameters(timeLimitOverride: timeLimitOverride)
            : onlineHardParameters(movesPlayed: movesPlayed)).timeMs / 1000
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

    static func bestMove(board: AISolver.Board, activePlayers: [Int], currentPlayer: Int,
                         movesPlayed: Int, openingSeed: String,
                         timeLimitOverride: TimeInterval? = nil,
                         directBotpickSearch: Bool = false) -> (Int, Int)? {
        guard (2...12).contains(board.size), activePlayers.count == 2,
              let side = activePlayers.firstIndex(of: currentPlayer) else { return nil }
        let size = board.size
        var cells = [UInt8](repeating: 0, count: size * size)
        for index in cells.indices {
            let value = board.cells[index]
            guard let owner = value.owner,
                  let local = activePlayers.firstIndex(of: owner) else { continue }
            cells[index] = UInt8((local == 1 ? 0x80 : 0) | (min(15, value.count) & 0x0f))
        }
        let legalMoves = cells.indices.filter { owner(cells[$0]) == side }
        guard let first = legalMoves.first else { return nil }
        let firstSide = movesPlayed.isMultiple(of: 2) ? side : 1 - side
        let firstSideMoves = (movesPlayed + 1) / 2
        let secondSideMoves = movesPlayed / 2
        let actualMovesRed = firstSide == 0 ? firstSideMoves : secondSideMoves
        let actualMovesBlue = firstSide == 1 ? firstSideMoves : secondSideMoves

        // Analyzer source (`dots-analyzer.html`) calls botpick directly: no
        // opening-book or fallback policy, and fixed 20/20 move counts.
        if directBotpickSearch {
            let profile = analyzerParameters(timeLimitOverride: timeLimitOverride)
            let result = DriveBotpickEngine.bestMove(
                cells: cells, size: size, side: side, movesRed: 20, movesBlue: 20,
                limits: DriveBotpickEngine.Limits(timeMs: profile.timeMs,
                                                  softTimeMs: nil,
                                                  minTimeMs: profile.minTimeMs,
                                                  maxDepth: profile.maxDepth)
            )
            let selected = result?.move ?? first
            return (selected / size, selected % size)
        }

        // Bot 3 = dots-online.com's live "hard" bot (online._code-CveaxU4E.js),
        // untimed room ("calm"): opening pattern for the bot's first 12 moves while
        // fewer than 30 plies have been played, then botpick (DotsBoard `p`/`Un`):
        //   plies < 30: { timeMs: 400, softTimeMs: 120, minTimeMs: 40, maxDepth: 8 }
        //   otherwise:  { timeMs: 5000, softTimeMs: 1200, minTimeMs: 60, maxDepth: 32 }
        // If botpick returns nothing the site falls back to `Vr()`.
        let ownMoves = side == 0 ? actualMovesRed : actualMovesBlue
        if movesPlayed < 30, ownMoves < 12,
           let opening = DriveOpeningBook.nextOwnedMove(cells: cells, size: size,
                                                        side: side, startIndex: ownMoves,
                                                        seed: openingSeed) {
            return (opening / size, opening % size)
        }
        let profile = onlineHardParameters(movesPlayed: movesPlayed)
        if let result = DriveBotpickEngine.bestMove(
            cells: cells, size: size, side: side,
            movesRed: actualMovesRed, movesBlue: actualMovesBlue,
            limits: DriveBotpickEngine.Limits(timeMs: profile.timeMs,
                                              softTimeMs: profile.softTimeMs,
                                              minTimeMs: profile.minTimeMs,
                                              maxDepth: profile.maxDepth)
        ) {
            return (result.move / size, result.move % size)
        }
        // `Vr()`: pickMove medium 200ms/depth 3, then top heuristic move, then any own cell.
        let engineBoard = cells.map { code -> Int in
            guard code != 0 else { return 0 }
            let charge = Int(code & 0x0f)
            return owner(code) == 0 ? charge : -charge
        }
        let color: DotsPickEngine.Color = side == 0 ? .red : .blue
        if let pick = DotsPickEngine.pickMove(board: engineBoard, size: size, side: color,
                                              difficulty: .medium, timeMs: 200, maxDepth: 3) {
            return (pick.move.y, pick.move.x)
        }
        if let top = DotsPickEngine.annotate(engineBoard, size, color).first {
            return (top.move.y, top.move.x)
        }
        return (first / size, first % size)
    }

    // online._code: humanlike think delay before the bot moves (untimed = "calm").
    // plies < 30: 60 + rand*140 ms; otherwise hard: 350 + rand*400 ms.
    static func onlineThinkDelayMs(movesPlayed: Int) -> Double {
        movesPlayed < 30 ? 60 + Double.random(in: 0..<1) * 140
                         : 350 + Double.random(in: 0..<1) * 400
    }

    private static func onlineHardParameters(movesPlayed: Int) -> SearchParameters {
        if movesPlayed < 30 {
            return SearchParameters(timeMs: 400, softTimeMs: 120,
                                    minTimeMs: 40, maxDepth: 8)
        }
        return SearchParameters(timeMs: 5000, softTimeMs: 1200,
                                minTimeMs: 60, maxDepth: 32)
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
    private let directBotpickSearch: Bool
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
         searchTimeLimitOverride: TimeInterval? = nil,
         directBotpickSearch: Bool = false) {
        self.boardSize = boardSize
        self.activePlayers = activePlayers
        self.currentPlayer = currentPlayer
        self.playerType = playerType
        self.aiLevel = aiLevel
        self.isLocalDuelMode = isLocalDuelMode
        self.localDuelMovesPlayed = localDuelMovesPlayed
        self.openingSeed = openingSeed
        self.searchTimeLimitOverride = searchTimeLimitOverride
        self.directBotpickSearch = directBotpickSearch
        let timeBudget = playerType == .driveBot
            ? DriveDuelSearch.timeBudget(movesPlayed: localDuelMovesPlayed,
                                         timeLimitOverride: searchTimeLimitOverride,
                                         directBotpickSearch: directBotpickSearch)
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
        if playerType != .driveBot && searchStopped { return nil }
        // The Drive botpick search is a two-player zero-sum engine. In party
        // games, continue into the shared multiplayer MaxN path instead of
        // returning nil before the bot can place its opening piece.
        if playerType == .driveBot && activePlayers.count == 2 {
            if !directBotpickSearch {
                // Site think delay minus the 150ms every bot already waits in GameModel.
                let delayMs = DriveDuelSearch.onlineThinkDelayMs(movesPlayed: localDuelMovesPlayed) - 150
                if delayMs > 0 { try? await Task.sleep(nanoseconds: UInt64(delayMs * 1_000_000)) }
                if Task.isCancelled { return nil }
            }
            return DriveDuelSearch.bestMove(board: board, activePlayers: activePlayers,
                                            currentPlayer: currentPlayer,
                                            movesPlayed: localDuelMovesPlayed, openingSeed: openingSeed,
                                            timeLimitOverride: searchTimeLimitOverride,
                                            directBotpickSearch: directBotpickSearch)
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
