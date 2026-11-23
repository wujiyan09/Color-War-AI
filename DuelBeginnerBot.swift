import Foundation

/// 双人模式 Bot 3「入门」（强度 0）：包在 Bot 3 规则外面的弱化外壳，不改任何引擎 / 搜索代码。
///
/// 引擎 `Nov15DuelSearch.bestMove` 只返回一步、不给候选排名，最低档（强度 1）也有深度 4，
/// 所以这里自己排名：每个合法步用引擎公开的 `Nov15DuelSearch.applyMove`（同一套对局规则）
/// 走出来，做 2 层（我走一步 → 对手最好的回应）评估，再给分数加随机噪声，
/// 并有 30% 概率在前 3 名里随机挑一个。所有候选都来自合法步，并且都通过了 applyMove 校验。
enum DuelBeginnerBot {
    static let strength = 0
    static let name = "入门"
    static let detail = "只看两步 · 带随机失误"
    static let aiKey = "bot3-s0"
    static let aiLabel = "Bot 3 · 入门"

    static let noise = 40.0          // 分数随机噪声 ±40（约等于一颗子的价值）
    static let topRandomChance = 0.3 // 30% 在前 3 名里随机挑
    static let maxRepliesChecked = 48 // 对手回应太多时只看前 48 个，保证很快

    struct Candidate { let row: Int; let column: Int; let score: Double }

    static func displayName(_ strength: Int) -> String {
        strength == self.strength ? name : Nov15DuelSearch.strengthName(strength)
    }
    static func displayDetail(_ strength: Int) -> String {
        strength == self.strength ? detail : Nov15DuelSearch.strengthDetail(strength)
    }

    /// 合法步：已入场就是自己的格子，否则是空格（和引擎规则一致）。
    static func legalMoves(_ board: [[Cell]], side: Int, entered: Bool) -> [(Int, Int)] {
        var out: [(Int, Int)] = []
        for r in board.indices {
            for c in board[r].indices {
                let cell = board[r][c]
                if entered ? (cell.owner == side && cell.count > 0) : (cell.owner == nil || cell.count == 0) {
                    out.append((r, c))
                }
            }
        }
        return out
    }

    private static func evaluate(_ board: [[Cell]], side: Int) -> Double {
        var pieces = [0, 0], charge = [0, 0]
        for row in board { for cell in row where cell.count > 0 {
            if let o = cell.owner, o == 0 || o == 1 { pieces[o] += 1; charge[o] += cell.count }
        } }
        let opp = 1 - side
        if pieces[opp] == 0 && pieces[side] > 0 { return 1_000_000 }
        if pieces[side] == 0 && pieces[opp] > 0 { return -1_000_000 }
        return Double((pieces[side] - pieces[opp]) * 35 + (charge[side] - charge[opp]) * 4)
    }

    /// 2 层评估后的候选（不含噪声），分数高的在前。
    static func rankedCandidates(board: [[Cell]], side: Int, entered: [Bool]) -> [Candidate] {
        let opp = 1 - side
        var result: [Candidate] = []
        for (r, c) in legalMoves(board, side: side, entered: entered[side]) {
            guard let next = Nov15DuelSearch.applyMove(board: board, row: r, column: c, side: side, entered: entered[side]) else { continue }
            var score = evaluate(next, side: side)
            if abs(score) < 900_000 {
                let replies = legalMoves(next, side: opp, entered: entered[opp]).prefix(maxRepliesChecked)
                var worst = score
                for (rr, cc) in replies {
                    if let after = Nov15DuelSearch.applyMove(board: next, row: rr, column: cc, side: opp, entered: entered[opp]) {
                        worst = min(worst, evaluate(after, side: side))
                    }
                }
                score = worst
            }
            result.append(Candidate(row: r, column: c, score: score))
        }
        return result.sorted { $0.score > $1.score }
    }

    /// 选一步。`random` 可注入，方便测试。
    static func pick<G: RandomNumberGenerator>(board: [[Cell]], activePlayers: [Int], currentPlayer: Int,
                                               hasEntered: [Bool], using random: inout G) -> (Int, Int)? {
        guard activePlayers.count == 2, let side = activePlayers.firstIndex(of: currentPlayer) else { return nil }
        // 映射成引擎的 0/1 两方
        let local: [[Cell]] = board.map { row in row.map { cell in
            guard let o = cell.owner, cell.count > 0, let s = activePlayers.firstIndex(of: o) else { return Cell(owner: nil, count: 0) }
            return Cell(owner: s, count: cell.count)
        } }
        let entered = activePlayers.map { $0 < hasEntered.count && hasEntered[$0] }
        let noisy = rankedCandidates(board: local, side: side, entered: entered)
            .map { Candidate(row: $0.row, column: $0.column, score: $0.score + Double.random(in: -noise...noise, using: &random)) }
            .sorted { $0.score > $1.score }
        guard let best = noisy.first else { return nil }
        if noisy.count > 1, Double.random(in: 0..<1, using: &random) < topRandomChance {
            let pick = noisy.prefix(3).randomElement(using: &random) ?? best
            return (pick.row, pick.column)
        }
        return (best.row, best.column)
    }

    static func pick(board: [[Cell]], activePlayers: [Int], currentPlayer: Int, hasEntered: [Bool]) -> (Int, Int)? {
        var g = SystemRandomNumberGenerator()
        return pick(board: board, activePlayers: activePlayers, currentPlayer: currentPlayer, hasEntered: hasEntered, using: &g)
    }
}
