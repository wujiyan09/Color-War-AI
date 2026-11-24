import Foundation

// Bot 3 in party games (3+ seats). New code; Nov15DuelSearch is untouched.
// Paranoid alpha-beta: Bot 3 maximises, every other alive seat is assumed to
// play against Bot 3, turns follow the real seat order. Same move rules,
// evaluation weights, move ordering, TT/killer/history and iterative
// deepening as the 2026-11-15 duel search. When only two seats are left the
// router in AISolver hands over to Nov15DuelSearch unchanged.
struct Nov15ParanoidSearch {
    private static func splitmix64(_ value: UInt64) -> UInt64 {
        var z = value &+ 0x9e3779b97f4a7c15
        z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        return z ^ (z >> 31)
    }
    private static let maxSides = 8
    private static let zobrist: [UInt64] = {
        var seed: UInt64 = 0x9a2a0d
        return (0..<(12 * 12 * maxSides * 8)).map { i in
            seed = splitmix64(seed &+ UInt64(i))
            return seed
        }
    }()
    private static let sideKeys: [UInt64] = (0..<maxSides).map { splitmix64(0x51de &+ UInt64($0)) }
    private static let enteredKeys: [UInt64] = (0..<maxSides).map { splitmix64(0xe7e7 &+ UInt64($0)) }
    private static let deadKeys: [UInt64] = (0..<maxSides).map { splitmix64(0xdead &+ UInt64($0)) }
    private static let winScore = 1_000_000
    private static let maxPly = 64
    private static let infinity = 1_000_000_000

    // Same budgets as Nov15DuelSearch level 3 ("hard").
    private struct SearchParameters {
        let timeMs: Double, softTimeMs: Double, minTimeMs: Double, maxDepth: Int
    }
    private static func parameters(movesPlayed: Int) -> SearchParameters {
        let phase: (timeMs: Double, softTimeMs: Double, minTimeMs: Double, maxDepth: Int) =
            movesPlayed < 30 ? (400, 120, 40, 8) : (5000, 600, 80, 32)
        let timeMs = min(6000, phase.timeMs)
        let softTimeMs = min(phase.softTimeMs, timeMs)
        return SearchParameters(timeMs: timeMs, softTimeMs: softTimeMs,
                                minTimeMs: min(phase.minTimeMs, softTimeMs),
                                maxDepth: min(32, phase.maxDepth))
    }

    private struct Entry { var depth: Int; var score: Int; var flag: Int; var move: Int }
    private struct Context {
        var deadline: Double
        let me: Int
        let sides: Int
        var nodes = 0
        var stopped = false
        var table: [UInt64: Entry] = [:]
        var killers = Array(repeating: [-1, -1], count: maxPly + 1)
        var history: [Int]
    }
    private struct Result { var score: Int; var move: Int }
    struct State {
        var cells: [UInt8]
        var entered: Int   // bit per side
        var dead: Int      // bit per side
    }

    private static func owner(_ code: UInt8) -> Int { code == 0 ? -1 : Int(code >> 4) - 1 }
    private static func charge(_ code: UInt8) -> Int { Int(code & 15) }
    private static func encode(_ owner: Int, _ charge: Int) -> UInt8 {
        guard charge > 0 else { return 0 }
        return UInt8(((owner + 1) << 4) | min(15, charge))
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
    private static func key(_ s: State, _ side: Int) -> UInt64 {
        var value: UInt64 = sideKeys[side]
        for (i, code) in s.cells.enumerated() where code != 0 {
            value ^= zobrist[(i * maxSides + owner(code)) * 8 + min(8, charge(code)) - 1]
        }
        for p in 0..<maxSides {
            if s.entered & (1 << p) != 0 { value ^= enteredKeys[p] }
            if s.dead & (1 << p) != 0 { value ^= deadKeys[p] }
        }
        return value
    }
    private static func legalMoves(_ s: State, _ side: Int) -> [Int] {
        if s.entered & (1 << side) == 0 { return s.cells.indices.filter { s.cells[$0] == 0 } }
        return s.cells.indices.filter { owner(s.cells[$0]) == side }
    }
    private static func counts(_ cells: [UInt8], _ sides: Int) -> [Int] {
        var value = Array(repeating: 0, count: sides)
        for code in cells where code != 0 { value[owner(code)] += 1 }
        return value
    }
    private static func aliveCount(_ s: State, _ sides: Int) -> Int {
        (0..<sides).filter { s.dead & (1 << $0) == 0 }.count
    }
    private static func nextSide(_ side: Int, _ s: State, _ sides: Int) -> Int {
        for step in 1...sides {
            let p = (side + step) % sides
            if s.dead & (1 << p) == 0 { return p }
        }
        return side
    }
    // Score from Bot 3's view, or nil if not over.
    private static func terminal(_ s: State, _ me: Int, _ sides: Int, _ depth: Int) -> Int? {
        if s.dead & (1 << me) != 0 { return -winScore - depth }
        if aliveCount(s, sides) == 1 { return winScore + depth }
        return nil
    }
    private static func sideScore(_ p: Int, piece: [Int], totalCharge: [Int], three: [Int], exposedThree: [Int], exposedCharge: [Int]) -> Int {
        piece[p] * 35 + totalCharge[p] * 4 + three[p] * 8 + exposedThree[p] * 60 + exposedCharge[p] * 12
    }
    // Nov15 weights; "opponent" = the strongest alive opponent.
    private static func evaluate(_ s: State, _ me: Int, _ sides: Int) -> Int {
        if let result = terminal(s, me, sides, 0) { return result }
        let cells = s.cells
        var piece = Array(repeating: 0, count: sides), totalCharge = piece, three = piece, exposedThree = piece, exposedCharge = piece
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
        let mine = sideScore(me, piece: piece, totalCharge: totalCharge, three: three, exposedThree: exposedThree, exposedCharge: exposedCharge)
        var strongest = Int.min
        for p in 0..<sides where p != me && s.dead & (1 << p) == 0 {
            strongest = max(strongest, sideScore(p, piece: piece, totalCharge: totalCharge, three: three, exposedThree: exposedThree, exposedCharge: exposedCharge))
        }
        return mine - (strongest == Int.min ? 0 : strongest)
    }
    // Game rules: +3 first placement / +1 after; >=4 bursts, keeps count-4,
    // pushes 1 to each orthogonal neighbour and captures it. Then any side
    // that has entered and owns nothing is eliminated.
    private static func simulate(_ s: State, _ move: Int, _ side: Int, _ size: Int, _ sides: Int) -> State {
        var next = s.cells
        let increment = s.entered & (1 << side) == 0 ? 3 : 1
        next[move] = encode(side, charge(next[move]) + increment)
        let newEntered = s.entered | (1 << side)
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
        var dead = s.dead
        let pieces = counts(next, sides)
        for p in 0..<sides where newEntered & (1 << p) != 0 && pieces[p] == 0 { dead |= 1 << p }
        return State(cells: next, entered: newEntered, dead: dead)
    }
    private static func moveOrderScore(_ s: State, _ move: Int, _ side: Int, _ size: Int, _ ply: Int, _ ttMove: Int, _ context: Context) -> Int {
        if move == ttMove { return 1_000_000_000 }
        let cells = s.cells, code = cells[move]
        let first = s.entered & (1 << side) == 0
        let nextCharge = charge(code) + (first ? 3 : 1)
        let isOwn = first ? code == 0 : owner(code) == side
        guard isOwn else { return -infinity }
        let adjacent = neighbors(move, size)
        if nextCharge >= 4 {
            var score = 1_000_000
            for n in adjacent where cells[n] != 0 && owner(cells[n]) != side {
                let enemyCharge = charge(cells[n])
                score += 10 * enemyCharge
                if enemyCharge == 3 { score += 200 }
                if side != context.me && owner(cells[n]) == context.me { score += 50 }
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
    private static func search(_ s: State, _ side: Int, _ depth: Int, _ alphaIn: Int, _ betaIn: Int, _ ply: Int, _ context: inout Context, _ size: Int) -> Result {
        let me = context.me, sides = context.sides
        context.nodes += 1
        if context.nodes & 4095 == 0 && ProcessInfo.processInfo.systemUptime >= context.deadline { context.stopped = true }
        if let result = terminal(s, me, sides, depth) { return Result(score: result, move: -1) }
        if context.stopped || ply >= maxPly || depth <= 0 { return Result(score: evaluate(s, me, sides), move: -1) }
        let hash = key(s, side), cached = context.table[hash]
        let ttMove = cached?.move ?? -1
        var alpha = alphaIn, beta = betaIn
        if let cached, cached.depth >= depth {
            if cached.flag == 0 { return Result(score: cached.score, move: cached.move) }
            if cached.flag == 1 { alpha = max(alpha, cached.score) }
            if cached.flag == 2 { beta = min(beta, cached.score) }
            if alpha >= beta { return Result(score: cached.score, move: cached.move) }
        }
        let moves = legalMoves(s, side).sorted {
            moveOrderScore(s, $0, side, size, ply, ttMove, context) > moveOrderScore(s, $1, side, size, ply, ttMove, context)
        }
        guard !moves.isEmpty else { return Result(score: evaluate(s, me, sides), move: -1) }
        let maximizing = side == me
        let a0 = alpha, b0 = beta
        var best = maximizing ? -infinity : infinity, bestMove = moves[0]
        for move in moves {
            let next = simulate(s, move, side, size, sides)
            let score = search(next, nextSide(side, next, sides), depth - 1, alpha, beta, ply + 1, &context, size).score
            if maximizing {
                if score > best { best = score; bestMove = move }
                alpha = max(alpha, score)
            } else {
                if score < best { best = score; bestMove = move }
                beta = min(beta, score)
            }
            if alpha >= beta {
                let newCharge = charge(s.cells[move]) + (s.entered & (1 << side) == 0 ? 3 : 1)
                if newCharge < 4 {
                    if context.killers[ply][0] != move {
                        context.killers[ply][1] = context.killers[ply][0]
                        context.killers[ply][0] = move
                    }
                    let index = side * 144 + move
                    context.history[index] = min(2_000_000, context.history[index] + depth * depth)
                }
                break
            }
            if context.stopped { break }
        }
        if !context.stopped {
            let flag = best <= a0 ? 2 : (best >= b0 ? 1 : 0)
            context.table[hash] = Entry(depth: depth, score: best, flag: flag, move: bestMove)
        }
        return Result(score: best, move: bestMove)
    }

    static func bestMove(board: AISolver.Board, players: [Int], currentPlayer: Int, hasEntered: [Bool], eliminated: [Bool], movesPlayed: Int, weak: Bool = false, rng: () -> Double = { Double.random(in: 0..<1) }) -> (Int, Int)? {
        guard (2...12).contains(board.size), (3...maxSides).contains(players.count),
              let me = players.firstIndex(of: currentPlayer) else { return nil }
        let size = board.size, sides = players.count
        var cells = [UInt8](repeating: 0, count: size * size)
        for index in cells.indices {
            let value = board.cells[index]
            guard let local = players.firstIndex(of: value.owner ?? -1), value.count > 0 else { continue }
            cells[index] = encode(local, value.count)
        }
        var entered = 0, dead = 0
        for (i, p) in players.enumerated() {
            if p < hasEntered.count && hasEntered[p] { entered |= 1 << i }
            if p < eliminated.count && eliminated[p] { dead |= 1 << i }
        }
        let root = State(cells: cells, entered: entered, dead: dead)
        let moves = legalMoves(root, me)
        guard let first = moves.first else { return nil }
        if moves.count == 1 { return (first / size, first % size) }
        let params: SearchParameters
        if weak {
            // Bot 2 (party/online): weakened budgets.
            let w = Bot2Weak.limits(movesPlayed: movesPlayed)
            params = SearchParameters(timeMs: w.timeMs, softTimeMs: w.softTimeMs, minTimeMs: w.minTimeMs, maxDepth: w.maxDepth)
        } else {
            params = parameters(movesPlayed: movesPlayed)
        }
        let startTime = ProcessInfo.processInfo.systemUptime
        var context = Context(deadline: startTime + params.timeMs / 1000, me: me, sides: sides,
                              history: Array(repeating: 0, count: sides * 144))
        let ordered = moves.sorted { moveOrderScore(root, $0, me, size, 0, -1, context) > moveOrderScore(root, $1, me, size, 0, -1, context) }
        var best = ordered[0]
        var completedMoves: [Int] = [], completedScores: [Int] = []
        for depth in 1...params.maxDepth {
            if ProcessInfo.processInfo.systemUptime >= context.deadline || Task.isCancelled { break }
            context.stopped = false
            let result = search(root, me, depth, -infinity, infinity, 0, &context, size)
            if context.stopped || Task.isCancelled || result.move < 0 { break }
            best = result.move
            completedMoves.append(result.move); completedScores.append(result.score)
            if abs(result.score) >= winScore - 1000 { break }
            let elapsedMs = (ProcessInfo.processInfo.systemUptime - startTime) * 1000
            if depth >= 6 && elapsedMs >= params.softTimeMs && elapsedMs >= params.minTimeMs && completedMoves.count >= 3 {
                let recent = completedMoves.suffix(3)
                let delta = abs(result.score - completedScores[completedScores.count - 3])
                if let stable = recent.first, recent.allSatisfy({ $0 == stable }), delta <= 8 { break }
            }
        }
        let depthCompleted = completedMoves.count
        if weak, depthCompleted > 0, let bestScore = completedScores.last, rng() < Bot2Weak.mistakeRate {
            // Bot 2 mistake: null-window test of every other root move at the
            // last completed depth; keep those scoring >= best - window.
            let cutoff = bestScore - Bot2Weak.mistakeWindow
            context.deadline = ProcessInfo.processInfo.systemUptime + params.timeMs / 1000
            context.stopped = false
            var candidates: [Int] = []
            for move in ordered where move != best {
                let next = simulate(root, move, me, size, sides)
                let score = search(next, nextSide(me, next, sides), depthCompleted - 1, cutoff - 1, cutoff, 1, &context, size).score
                if context.stopped || Task.isCancelled { break }
                if score >= cutoff { candidates.append(move) }
            }
            if let picked = Bot2Weak.pick(candidates, rng: rng) { best = picked }
        }
        return (best / size, best % size)
    }
}
