import Foundation

// Bot 3 algorithm restored verbatim from commit 644af44 (2026-11-15 09:33 HKT,
// release build-111), where it lived as `DriveDuelSearch` in ContentView.swift.
// Only the type name changed. Bot 3 always uses its level-3+ ("hard") branch.
struct Nov15DuelSearch {
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
        let randomize: Bool
    }
    private static func parameters(level: Int, movesPlayed: Int) -> SearchParameters {
        let difficulty: (timeMs: Double, maxDepth: Int, randomize: Bool)
        switch level {
        case 1: difficulty = (80, 1, true)
        case 2: difficulty = (1200, 8, false)
        default: difficulty = (6000, 32, false)
        }
        let phase: (timeMs: Double, softTimeMs: Double, minTimeMs: Double, maxDepth: Int)
        // Drive / dots-online hard bot phase budgets.
        if movesPlayed < 30 {
            phase = (400, 120, 40, 8)
        } else {
            phase = (5000, 1200, 60, 32)
        }
        let timeMs = min(difficulty.timeMs, phase.timeMs)
        let softTimeMs = min(phase.softTimeMs, timeMs)
        return SearchParameters(
            timeMs: timeMs,
            softTimeMs: softTimeMs,
            minTimeMs: min(phase.minTimeMs, softTimeMs),
            maxDepth: min(difficulty.maxDepth, phase.maxDepth),
            randomize: difficulty.randomize
        )
    }
    // Duel slider. Each level caps the Drive hard budget (time, soft stop, depth);
    // the opening phase (<30 plies: 400ms / depth 8) is capped the same way.
    static let maxStrength = 4
    private static let strengthCaps: [(timeMs: Double, softTimeMs: Double, maxDepth: Int)] = [
        (300, 80, 4), (1000, 300, 10), (2500, 700, 20), (5000, 1200, 32)
    ]
    static func strengthName(_ strength: Int) -> String {
        ["简单", "中等", "困难", "Drive 原版"][max(1, min(maxStrength, strength)) - 1]
    }
    static func strengthDetail(_ strength: Int) -> String {
        let cap = strengthCaps[max(1, min(maxStrength, strength)) - 1]
        return String(format: "每步最多 %.1f 秒 · 深度 %d", cap.timeMs / 1000, cap.maxDepth)
    }
    private static func capped(_ p: SearchParameters, strength: Int) -> SearchParameters {
        let cap = strengthCaps[max(1, min(maxStrength, strength)) - 1]
        let timeMs = min(p.timeMs, cap.timeMs)
        let softTimeMs = min(p.softTimeMs, cap.softTimeMs, timeMs)
        return SearchParameters(timeMs: timeMs, softTimeMs: softTimeMs,
                                minTimeMs: min(p.minTimeMs, softTimeMs),
                                maxDepth: min(p.maxDepth, cap.maxDepth), randomize: p.randomize)
    }
    static func timeBudget(level: Int, movesPlayed: Int = 0) -> TimeInterval {
        parameters(level: level, movesPlayed: movesPlayed).timeMs / 1000
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

    private static func owner(_ code: UInt8) -> Int { code == 0 ? -1 : Int(code >> 4) - 1 }
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
    private static func evaluate(_ cells: [UInt8], _ side: Int, _ enteredMask: Int) -> Int {
        if let result = terminal(cells, side, enteredMask, 0) { return result }
        let opponent = 1 - side
        var piece = [0, 0], totalCharge = [0, 0], three = [0, 0], exposedThree = [0, 0], exposedCharge = [0, 0]
        for code in cells where code != 0 {
            let p = owner(code), amount = charge(code)
            piece[p] += 1; totalCharge[p] += amount
            if amount == 3 { three[p] += 1 }
        }
        let size = Int(Double(cells.count).squareRoot())
        for i in cells.indices where cells[i] != 0 && charge(cells[i]) == 3 {
            let p = owner(cells[i])
            var enemyCharge = 0
            for n in neighbors(i, size) where cells[n] != 0 && owner(cells[n]) != p { enemyCharge += charge(cells[n]) }
            if enemyCharge > 0 { exposedThree[p] += 1; exposedCharge[p] += enemyCharge }
        }
        return (piece[side] - piece[opponent]) * 35
            + (totalCharge[side] - totalCharge[opponent]) * 4
            + (three[side] - three[opponent]) * 8
            + (exposedThree[side] - exposedThree[opponent]) * 60
            + (exposedCharge[side] - exposedCharge[opponent]) * 12
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
    private static func moveOrderScore(_ cells: [UInt8], _ move: Int, _ side: Int, _ enteredMask: Int, _ size: Int, _ ply: Int, _ ttMove: Int, _ context: Context) -> Int {
        if move == ttMove { return 1_000_000_000 }
        let code = cells[move]
        let nextCharge = charge(code) + (enteredMask & (1 << side) == 0 ? 3 : 1)
        let isOwn = enteredMask & (1 << side) == 0 ? code == 0 : owner(code) == side
        guard isOwn else { return -infinity }
        let adjacent = neighbors(move, size)
        if nextCharge >= 4 {
            var score = 1_000_000
            for n in adjacent where cells[n] != 0 && owner(cells[n]) != side {
                let enemyCharge = charge(cells[n])
                score += 10 * enemyCharge
                if enemyCharge == 3 { score += 200 }
            }
            return score
        }
        var score = 0
        if context.killers[ply][0] == move { score += 800_000 }
        else if context.killers[ply][1] == move { score += 700_000 }
        score += context.history[side * 144 + move]
        if nextCharge == 3 { score += 100 }
        score += nextCharge * 2
        for n in adjacent where cells[n] != 0 && owner(cells[n]) != side && charge(cells[n]) == 3 {
            score -= nextCharge == 3 ? 300 : 80
        }
        return score
    }
    private static func exposedThreat(_ cells: [UInt8], _ side: Int, _ size: Int) -> (count: Int, charge: Int) {
        var count = 0, total = 0
        for i in cells.indices where cells[i] != 0 && owner(cells[i]) == side && charge(cells[i]) == 3 {
            var adjacentCharge = 0
            for n in neighbors(i, size) where cells[n] != 0 && owner(cells[n]) != side { adjacentCharge += charge(cells[n]) }
            if adjacentCharge > 0 { count += 1; total += adjacentCharge }
        }
        return (count, total)
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
            let readyThreat = exposedThreat(cells, side, size)
            if readyThreat.count > 0 { score += 280 + Double(readyThreat.charge) * 12 }
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
        let exposed = exposedThreat(cells, side, size)
        if exposed.count > 0 { score -= 290 + Double(exposed.charge) * 12 }
        score += Double(newCharge) * 0.5 + Double(4 - newCharge) * 2.5 + Double(ownCount) + Double(empty) * 0.25 - Double(enemyCount * 2)
        let total = counts(cells).reduce(0, +)
        if total <= 8 && !isFirst {
            let row = move / size, column = move % size, center = size / 2
            let distance = side == 0 ? row + column : 2 * (size - 1) - row - column
            score += Double(max(0, center - distance)) * 2.5
        }
        if total >= 30 && newCharge == 3 { score -= 8 }
        return score + Double.random(in: -0.005...0.005)
    }
    private static func pieceCount(_ cells: [UInt8], _ side: Int) -> Int {
        var n = 0
        for code in cells where code != 0 && owner(code) == side { n += 1 }
        return n
    }
    // Search follows Drive's bitboard `ze()`: TT, null-move pruning, stable
    // move ordering, killers/uncapped history, no TT store when time runs out.
    // Move rules (subtract-4 bursts, full chain then win check, +3 first move)
    // stay Color War's via simulate()/terminal().
    private static func search(_ cells: [UInt8], _ side: Int, _ enteredMask: Int, _ depth: Int, _ alphaIn: Int, _ beta: Int, _ ply: Int, _ context: inout Context, _ size: Int, _ allowNull: Bool) -> Result {
        context.nodes += 1
        if context.nodes & 4095 == 0 && ProcessInfo.processInfo.systemUptime >= context.deadline { context.stopped = true }
        if context.stopped { return Result(score: 0, move: -1) }
        if let result = terminal(cells, side, enteredMask, depth) { return Result(score: result, move: -1) }
        if ply >= maxPly { return Result(score: evaluate(cells, side, enteredMask), move: -1) }
        let hash = key(cells, side, enteredMask), cached = context.table[hash]
        let ttMove = cached?.move ?? -1, oldAlpha = alphaIn
        var alpha = alphaIn
        if let cached, cached.depth >= depth {
            if cached.flag == 0 { return Result(score: cached.score, move: cached.move) }
            if cached.flag == 1 && cached.score >= beta { return Result(score: cached.score, move: cached.move) }
            if cached.flag == 2 && cached.score <= alpha { return Result(score: cached.score, move: cached.move) }
        }
        if depth <= 0 { return Result(score: evaluate(cells, side, enteredMask), move: -1) }
        if allowNull && depth >= 3 && beta - alpha == 1 && pieceCount(cells, side) >= 3 {
            let reduction = depth >= 6 ? 3 : 2
            let nullScore = -search(cells, 1 - side, enteredMask, depth - 1 - reduction, -beta, -beta + 1, ply + 1, &context, size, false).score
            if context.stopped { return Result(score: 0, move: -1) }
            if nullScore >= beta { return Result(score: nullScore, move: -1) }
        }
        var ordered = legalMoves(cells, side, enteredMask, size).map { (move: $0, score: moveOrderScore(cells, $0, side, enteredMask, size, ply, ttMove, context)) }
        guard !ordered.isEmpty else { return Result(score: evaluate(cells, side, enteredMask), move: -1) }
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
        let moves = ordered.map(\.move)
        var best = -infinity, bestMove = moves[0]
        for move in moves {
            let next = simulate(cells, move, side, enteredMask, size)
            let score: Int
            if let result = terminal(next.cells, 1 - side, next.entered, depth) {
                score = -result
            } else {
                score = -search(next.cells, 1 - side, next.entered, depth - 1, -beta, -alpha, ply + 1, &context, size, true).score
            }
            if context.stopped { return Result(score: 0, move: -1) }
            if score > best { best = score; bestMove = move }
            if score > alpha { alpha = score }
            if alpha >= beta {
                let newCharge = charge(cells[move]) + (enteredMask & (1 << side) == 0 ? 3 : 1)
                if newCharge < 4 {
                    if context.killers[ply][0] != move {
                        context.killers[ply][1] = context.killers[ply][0]
                        context.killers[ply][0] = move
                    }
                    context.history[side * 144 + move] += depth * depth
                }
                break
            }
        }
        let flag = best <= oldAlpha ? 2 : (best >= beta ? 1 : 0)
        context.table[hash] = Entry(depth: depth, score: best, flag: flag, move: bestMove)
        return Result(score: best, move: bestMove)
    }

    /// Applies one move with Color War's local-duel rules (same as GameModel.play):
    /// +3 on a side's first entry, subtract-4 bursts with leftovers kept, full chain.
    /// Returns nil for an illegal move. Used by the analyzer so it matches the duel game.
    static func applyMove(board: [[Cell]], row: Int, column: Int, side: Int, entered: Bool) -> [[Cell]]? {
        let size = board.count
        guard (2...12).contains(size), side == 0 || side == 1,
              (0..<size).contains(row), (0..<size).contains(column) else { return nil }
        var cells = [UInt8](repeating: 0, count: size * size)
        for r in 0..<size {
            for c in 0..<min(size, board[r].count) {
                let cell = board[r][c]
                guard let owner = cell.owner, owner == 0 || owner == 1, cell.count > 0 else { continue }
                cells[r * size + c] = encode(owner, min(15, cell.count))
            }
        }
        let enteredMask = entered ? (1 << side) : 0
        let index = row * size + column
        guard legalMoves(cells, side, enteredMask, size).contains(index) else { return nil }
        let next = simulate(cells, index, side, enteredMask, size).cells
        return (0..<size).map { r in
            (0..<size).map { c in
                let code = next[r * size + c]
                return code == 0 ? Cell(owner: nil, count: 0) : Cell(owner: owner(code), count: charge(code))
            }
        }
    }

    static func bestMove(board: AISolver.Board, activePlayers: [Int], currentPlayer: Int, hasEntered: [Bool], level: Int, movesPlayed: Int, openingSeed: String? = nil, strength: Int = maxStrength) -> (Int, Int)? {
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
        let searchParameters = capped(parameters(level: level, movesPlayed: movesPlayed), strength: strength)
        if searchParameters.randomize {
            let ranked = moves.map { ($0, quietHeuristic(cells, $0, side, enteredMask, size)) }.sorted { $0.1 > $1.1 }
            let candidates = Array(ranked.prefix(3))
            let selected = Double.random(in: 0..<1) < 0.3 ? candidates.randomElement()!.0 : candidates[0].0
            return (selected / size, selected % size)
        }
        if moves.count == 1 { return (first / size, first % size) }
        // Drive's 12-move opening book (local duel only: both sides start entered
        // with one piece in opposite corners, exactly like dots-online).
        if let seed = openingSeed, enteredMask == 3, movesPlayed < 30 {
            let firstSide = movesPlayed.isMultiple(of: 2) ? side : 1 - side
            let ownMoves = side == firstSide ? (movesPlayed + 1) / 2 : movesPlayed / 2
            if ownMoves < 12 {
                let driveCells = cells.map { code -> UInt8 in
                    code == 0 ? 0 : UInt8((owner(code) == 1 ? 0x80 : 0) | (Int(code) & 0x0f))
                }
                if let opening = DriveOpeningBook.nextOwnedMove(cells: driveCells, size: size, side: side,
                                                                startIndex: ownMoves, seed: seed),
                   moves.contains(opening) {
                    return (opening / size, opening % size)
                }
            }
        }
        let maxDepth = searchParameters.maxDepth
        let startTime = ProcessInfo.processInfo.systemUptime
        var context = Context(deadline: startTime + searchParameters.timeMs / 1000)
        let ordered = moves.sorted { moveOrderScore(cells, $0, side, enteredMask, size, 0, -1, context) > moveOrderScore(cells, $1, side, enteredMask, size, 0, -1, context) }
        var best = ordered[0], depthCompleted = 0
        var completedMoves: [Int] = [], completedScores: [Int] = []
        for depth in 1...maxDepth {
            if ProcessInfo.processInfo.systemUptime >= context.deadline || Task.isCancelled { break }
            context.stopped = false
            let result = search(cells, side, enteredMask, depth, -infinity, infinity, 0, &context, size, true)
            if context.stopped || Task.isCancelled || result.move < 0 { break }
            best = result.move; depthCompleted = depth
            completedMoves.append(result.move); completedScores.append(result.score)
            if result.score > 900_000 || result.score < -900_000 { break }
            let elapsedMs = (ProcessInfo.processInfo.systemUptime - startTime) * 1000
            if depth >= 6 && elapsedMs >= searchParameters.softTimeMs && elapsedMs >= searchParameters.minTimeMs && completedMoves.count >= 3 {
                let recentMoves = completedMoves.suffix(3)
                let scoreDelta = abs(result.score - completedScores[completedScores.count - 3])
                if let stableMove = recentMoves.first,
                   recentMoves.allSatisfy({ $0 == stableMove }), scoreDelta <= 8 { break }
            }
        }
        _ = depthCompleted
        return (best / size, best % size)
    }
}


