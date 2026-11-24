import Foundation

/// Line-by-line Swift port of `ENGINE.pickMove` (minified `zn`) from
/// My Drive/temp/dots/engine.standalone.js, including everything it calls:
/// `qt` (move list), `et` (heuristic annotate), `Ce`/`xt`/`kt` (static eval),
/// `Rn` (terminal check), `Cn` (Zobrist key), `Tn` (move ordering),
/// `_n`/`Pn` (killers + history), `ke` (PVS) and the engine's own
/// `simulateMove`/`chargeOut` wave rules. Used by Bot 3 only.
///
/// Board: flat row-major array, index = y * size + x.
/// Cell value: 0 = empty, +charge = red, -charge = blue.
enum DotsPickEngine {
    enum Color: Int { case red = 0, blue = 1
        var other: Color { self == .red ? .blue : .red }
    }

    enum Difficulty { case easy, medium, hard }

    struct Move: Equatable { let x: Int; let y: Int }

    struct Result { let move: Move; let score: Double; let depth: Int }

    // In = {easy:{80,1,true}, medium:{1200,8,false}, hard:{6000,32,false}}
    private static func preset(_ d: Difficulty) -> (timeMs: Double, maxDepth: Int, randomize: Bool) {
        switch d {
        case .easy: return (80, 1, true)
        case .medium: return (1200, 8, false)
        case .hard: return (6000, 32, false)
        }
    }

    private static let maxPly = 48          // st
    private static let winScore = 1e6       // Te
    private static let dirs = [(1, 0), (-1, 0), (0, 1), (0, -1)]  // DIRS as (dx, dy)
    private static let criticality = 4

    @inline(__always) private static func color(_ v: Int) -> Color? { v == 0 ? nil : (v > 0 ? .red : .blue) }
    @inline(__always) private static func charge(_ v: Int) -> Int { v < 0 ? -v : v }
    @inline(__always) private static func cell(_ c: Color, _ q: Int) -> Int { c == .red ? q : -q }

    private static func nowMs() -> Double { Date().timeIntervalSince1970 * 1000 }

    // MARK: rules (engine-internal, `chargeOut` / `simulateMove`)

    private static func countColors(_ b: [Int]) -> (red: Int, blue: Int) {
        var r = 0, bl = 0
        for v in b where v != 0 { if v > 0 { r += 1 } else { bl += 1 } }
        return (r, bl)
    }

    @inline(__always) private static func count(_ c: (red: Int, blue: Int), _ col: Color) -> Int {
        col == .red ? c.red : c.blue
    }

    private static func chargeOut(_ b: inout [Int], _ n: Int, _ x: Int, _ y: Int) {
        let v = b[y * n + x]
        guard let col = color(v) else { return }
        b[y * n + x] = 0
        for (dx, dy) in dirs {
            let nx = x + dx, ny = y + dy
            guard nx >= 0, ny >= 0, nx < n, ny < n else { continue }
            let t = b[ny * n + nx]
            if t == 0 { b[ny * n + nx] = cell(col, 1) }
            else if color(t) == col { b[ny * n + nx] = cell(col, charge(t) + 1) }
            else { b[ny * n + nx] = cell(col, charge(t) + 1) }
        }
    }

    static func simulateMove(_ board: [Int], _ n: Int, _ x: Int, _ y: Int, _ col: Color) -> [Int] {
        var b = board
        let cur = b[y * n + x]
        b[y * n + x] = cur != 0 ? cell(col, charge(cur) + 1) : cell(col, 1)
        // Color War rules (2026-11-24, same as GameModel executeMove): simultaneous waves, an exploding cell keeps
        // its remainder (count - 4), neighbours become the mover's, cascade runs to the end.
        var wave: [Int] = charge(b[y * n + x]) >= criticality ? [y * n + x] : []
        var guardCount = n * n * 64
        while !wave.isEmpty && guardCount > 0 {
            guardCount -= 1
            let exploding = wave.filter { charge(b[$0]) >= criticality }
            if exploding.isEmpty { break }
            for e in exploding { let left = charge(b[e]) - criticality; b[e] = left > 0 ? cell(col, left) : 0 }
            var changed: [Int] = []
            for e in exploding {
                for (nx, ny) in neighbors(e % n, e / n, n) {
                    let i = ny * n + nx
                    b[i] = cell(col, min(15, charge(b[i]) + 1))
                    if !changed.contains(i) { changed.append(i) }
                }
            }
            wave = changed.filter { charge(b[$0]) >= criticality }
        }
        return b
    }

    @inline(__always) private static func neighbors(_ x: Int, _ y: Int, _ n: Int) -> [(Int, Int)] {
        var out: [(Int, Int)] = []
        for (dx, dy) in dirs {
            let nx = x + dx, ny = y + dy
            if nx >= 0, ny >= 0, nx < n, ny < n { out.append((nx, ny)) }
        }
        return out
    }

    // MARK: `qt` — own cells in row-major order
    private static func ownCells(_ b: [Int], _ n: Int, _ col: Color) -> [Move] {
        var s: [Move] = []
        for y in 0..<n { for x in 0..<n where color(b[y * n + x]) == col { s.append(Move(x: x, y: y)) } }
        return s
    }

    /// Stable descending sort (JS Array.prototype.sort is stable).
    private static func stableSortDesc<T>(_ items: [T], by key: (T) -> Double) -> [T] {
        items.enumerated().sorted { a, b in
            let ka = key(a.element), kb = key(b.element)
            if ka != kb { return ka > kb }
            return a.offset < b.offset
        }.map { $0.element }
    }

    // MARK: `et` — heuristic move annotation
    static func annotate(_ e: [Int], _ o: Int, _ t: Color, jitter: Bool = true) -> [(move: Move, score: Double)] {
        let i = t.other
        var r: [(Int, Int)] = []
        var M = 0, yCount = 0
        for f in 0..<o { for m in 0..<o {
            let p = e[f * o + m]
            if p != 0 { if color(p) == t { r.append((m, f)); M += 1 } else { yCount += 1 } }
        } }
        if r.isEmpty { return [] }
        let c = M + yCount
        let h = c <= 8, g = c >= 30
        var u = 0, d = 0
        for (f, m) in r {
            let p = e[m * o + f]
            if charge(p) >= criticality - 1 {
                for (A, k) in neighbors(f, m, o) {
                    let I = e[k * o + A]
                    if I != 0 && color(I) == i && charge(I) >= criticality - 1 { u += 1; d += charge(I) }
                }
            }
        }
        let x = u > 0
        var l: [(move: Move, score: Double)] = []
        for (f, m) in r {
            let p = e[m * o + f]
            let A = criticality
            let k = charge(p) + 1
            let I = k >= A
            let E = !I && k >= A - 1
            var a = 0.0
            var w = 0, v = 0, D = 0, T = 0, ge = 0, we = 0, me = 0
            for (C, S) in neighbors(f, m, o) {
                let b = e[S * o + C]
                if b == 0 { D += 1; continue }
                if color(b) == t {
                    v += 1
                    if charge(b) >= criticality - 1 { we += 1 }
                } else {
                    w += 1
                    if charge(b) > me { me = charge(b) }
                    if charge(b) >= criticality - 1 { T += 1 }
                    else if charge(b) >= criticality - 2 { ge += 1 }
                }
            }
            if I {
                let C = simulateMove(e, o, f, m, t)
                let S = countColors(e), b = countColors(C)
                let _n = count(b, t) - count(S, t)
                let q = count(S, i) - count(b, i)
                a += Double(_n) * 18 + Double(q) * 26
                if count(b, i) == 0 && count(S, i) > 0 { a += 5e5 }
                a += Double(w) * 30
                a += Double(T) * 90
                a += Double(D) * 0.4
                if x { a += 280 + Double(d) * 12 }
            } else {
                if T > 0 {
                    var C = 95 + k * 24 + me * 18
                    if E { C += 250 + we * 95 }
                    a -= Double(C)
                }
                if E && ge > 0 { a -= Double(105 * ge) }
                if E && w > 0 { a -= Double(30 * w) }
                if E && w == 0 { a += 22; a += Double(we) * 4 }
                if x { a -= 290 + Double(d) * 12 }
                a += Double(k) * 0.5
                a += Double(4 - A) * 2.5
                a += Double(v) * 1
                a += Double(D) * 0.25
                a -= Double(w) * 2
                if h {
                    let C = o / 2
                    if t == .red { a += Double(max(0, C - (f + m))) * 2.5 }
                    else { a += Double(max(0, C - (2 * (o - 1) - f - m))) * 2.5 }
                }
                if g && E { a -= 8 }
            }
            l.append((Move(x: f, y: m), a))
        }
        if jitter { for idx in l.indices { l[idx].score += (Double.random(in: 0..<1) - 0.5) * 0.01 } }
        return stableSortDesc(l) { $0.score }
    }

    // MARK: `xt`
    private static func moveGain(_ e: [Int], _ n: Int, _ x: Int, _ y: Int, _ s: Color) -> Double {
        let o = countColors(e)
        let i = simulateMove(e, n, x, y, s)
        let r = countColors(i)
        let M = s.other
        let yv = count(r, s) - count(o, s)
        let c = count(o, M) - count(r, M)
        return count(r, M) == 0 && count(o, M) > 0 ? 1e6 : Double(yv) + Double(c) * 1.4
    }

    // MARK: `kt` — largest orthogonally connected group
    private static func largestGroup(_ e: [Int], _ n: Int, _ t: Color) -> Int {
        var seen = [Bool](repeating: false, count: n * n)
        var best = 0
        for i in 0..<n { for r in 0..<n {
            if seen[i * n + r] { continue }
            let v = e[i * n + r]
            if v == 0 || color(v) != t { continue }
            var size = 0
            var stack = [(r, i)]
            while let (h, g) = stack.popLast() {
                let u = g * n + h
                if seen[u] { continue }
                let d = e[u]
                if d == 0 || color(d) != t { continue }
                seen[u] = true; size += 1
                for (dx, dy) in dirs {
                    let f = h + dx, m = g + dy
                    if f >= 0, m >= 0, f < n, m < n, !seen[m * n + f] { stack.append((f, m)) }
                }
            }
            if size > best { best = size }
        } }
        return best
    }

    // MARK: `Ce` — static evaluation
    static func evaluate(_ e: [Int], _ s: Int, _ t: Color, _ n: Color) -> Double {
        let o = t.other
        var i = 0, r = 0, c = 0, h = 0, g = 0, u = 0
        let M = 0.0, y = 0.0   // (4 - criticality) * 1.5 summed: always 0
        var d: [(Int, Int)] = [], x: [(Int, Int)] = []
        for a in 0..<s { for w in 0..<s {
            let v = e[a * s + w]
            if v == 0 { continue }
            let q = charge(v)
            let T = q >= criticality - 1
            let le = !T && q >= criticality - 2
            if color(v) == t {
                i += q
                if T { c += 1; d.append((w, a)) } else if le { g += 1 }
            } else {
                r += q
                if T { h += 1; x.append((w, a)) } else if le { u += 1 }
            }
        }
        }
        if r == 0 && i > 0 { return 1e6 }
        if i == 0 && r > 0 { return -1e6 }
        var l = 0.0, f = 0.0
        for (a, w) in d {
            let v = moveGain(e, s, a, w, t)
            if v > l { f = l; l = v } else if v > f { f = v }
        }
        var m = 0.0, p = 0.0
        for (a, w) in x {
            let v = moveGain(e, s, a, w, o)
            if v > m { p = m; m = v } else if v > p { p = v }
        }
        var A = n == t ? l * 18 - m * 12 : l * 12 - m * 18
        A += f * 4 - p * 4
        let k = largestGroup(e, s, t), I = largestGroup(e, s, o)
        let E = n == t ? 5.0 : -5.0
        var total = Double(i - r) * 4
        total += Double(c - h) * 18
        total += Double(g - u) * 6
        total += (M - y) * 1
        total += Double(k - I) * 3
        total += A
        total += E
        return total
    }

    // MARK: `Cn` — Zobrist key (16x16 cells, 2 colours, 16 charges)
    private static let zobristKeys: [UInt64] = {
        var rng = SystemRandomNumberGenerator()
        return (0..<(16 * 16 * 2 * 16)).map { _ in rng.next() }
    }()
    private static let blueKey: UInt64 = {
        var rng = SystemRandomNumberGenerator()
        return rng.next()
    }()

    private static func key(_ e: [Int], _ n: Int, _ t: Color) -> UInt64 {
        var h: UInt64 = 0
        for r in 0..<n { for m in 0..<n {
            let v = e[r * n + m]
            if v == 0 { continue }
            let s = min(charge(v), 15)
            let o = color(v) == .red ? 0 : 1
            h ^= zobristKeys[((r * 16 + m) * 2 + o) * 16 + s]
        } }
        if t == .blue { h ^= blueKey }
        return h
    }

    // MARK: search context (`En`)
    private enum Flag { case exact, lower, upper }
    private struct TTEntry { let depth: Int; let score: Double; let flag: Flag; let best: Move? }

    private final class Context {
        var killers: [[Move?]] = Array(repeating: [nil, nil], count: DotsPickEngine.maxPly + 4)
        var history: [Int: Double] = [:]
        var tt: [UInt64: TTEntry] = [:]
        let deadline: Double
        var nodes = 0
        var abort = false
        init(deadline: Double) { self.deadline = deadline }
    }

    @inline(__always) private static func historyKey(_ c: Color, _ m: Move) -> Int { (c.rawValue * 16 + m.x) * 16 + m.y }

    // `_n`
    private static func recordCutoff(_ e: Context, _ t: Int, _ n: Color, _ s: Move, _ o: Int) {
        if e.killers[t][0] == nil || e.killers[t][0]! != s {
            e.killers[t][1] = e.killers[t][0]
            e.killers[t][0] = s
        }
        let r = historyKey(n, s)
        e.history[r] = (e.history[r] ?? 0) + Double(o * o)
    }

    // `Pn`
    private static func isKiller(_ e: Context, _ t: Int, _ n: Move) -> Bool {
        e.killers[t][0] == n || e.killers[t][1] == n
    }

    // `Tn`
    private static func orderedMoves(_ e: [Int], _ n: Int, _ t: Color, _ ctx: Context, _ ply: Int, _ ttBest: Move?) -> [(move: Move, tactical: Bool)] {
        let i = ownCells(e, n, t)
        if i.isEmpty { return [] }
        let r = annotate(e, n, t, jitter: false)
        var M: [Int: Double] = [:]
        for c in r { M[c.move.y * n + c.move.x] = c.score }
        let y: [(move: Move, tactical: Bool, score: Double)] = i.map { c in
            let u = charge(e[c.y * n + c.x]) + 1 >= criticality
            var d = M[c.y * n + c.x] ?? 0
            if let o = ttBest, o == c { d += 1e9 }
            else if u { d += 1e6 }
            else if isKiller(ctx, ply, c) { d += 5e5 }
            else { d += ctx.history[historyKey(t, c)] ?? 0 }
            return (c, u, d)
        }
        return stableSortDesc(y) { $0.score }.map { ($0.move, $0.tactical) }
    }

    // `Rn`
    private static func terminal(_ e: [Int], _ t: Color) -> Double? {
        let c = countColors(e)
        if t == .red {
            if c.blue == 0 && c.red > 0 { return winScore }
            if c.red == 0 && c.blue > 0 { return -winScore }
        } else {
            if c.red == 0 && c.blue > 0 { return winScore }
            if c.blue == 0 && c.red > 0 { return -winScore }
        }
        return nil
    }

    // `ke` — PVS
    private static func search(_ e: [Int], _ size: Int, _ t: Color, _ n: Int, _ alpha: Double, _ o: Double,
                               _ i: Context, _ r: Int, _ M: Bool) -> Double {
        var s = alpha
        i.nodes += 1
        if (i.nodes & 255) == 0 && nowMs() > i.deadline { i.abort = true }
        if i.abort || r >= maxPly { return evaluate(e, size, t, t) }
        let y = t.other
        if let c = terminal(e, t) { return c }
        let g = key(e, size, t)
        let u = i.tt[g]
        var d: Move? = nil
        if let u = u, u.depth >= n,
           u.flag == .exact || (u.flag == .lower && u.score >= o) || (u.flag == .upper && u.score <= s) {
            return u.score
        }
        if let u = u { d = u.best }
        if n <= 0 { return evaluate(e, size, t, t) }
        if M && n >= 3 && o - s == 1 {
            let c = countColors(e)
            if count(c, t) >= 4 {
                let a = n >= 6 ? 3 : 2
                let w = -search(e, size, y, n - 1 - a, -o, -o + 1, i, r + 1, false)
                if i.abort { return evaluate(e, size, t, t) }
                if w >= o { return w }
            }
        }
        let x = orderedMoves(e, size, t, i, r, d)
        if x.isEmpty { return evaluate(e, size, t, t) }
        let l = s
        var f = -Double.infinity
        var m: Move? = nil
        var p = 0
        for (k, I) in x {
            let E = simulateMove(e, size, k.x, k.y, t)
            let a = I && n <= 3 && r < maxPly - 4 ? 1 : 0
            var w: Double
            if p == 0 {
                w = -search(E, size, y, n - 1 + a, -o, -s, i, r + 1, true)
            } else {
                var v = 0
                if !I && a == 0 && n >= 3 && p >= 3 {
                    v = p >= 6 ? 2 : 1
                    if v >= n - 1 { v = n - 2 }
                    if v < 0 { v = 0 }
                }
                w = -search(E, size, y, n - 1 + a - v, -s - 1, -s, i, r + 1, true)
                if !i.abort && w > s && (v > 0 || o - s > 1) {
                    w = -search(E, size, y, n - 1 + a, -o, -s, i, r + 1, true)
                }
            }
            if i.abort { return f == -Double.infinity ? evaluate(e, size, t, t) : f }
            if w > f { f = w; m = k }
            if f > s { s = f }
            if s >= o {
                if !I { recordCutoff(i, r, t, k, n) }
                break
            }
            p += 1
        }
        let flag: Flag = f <= l ? .upper : (f >= o ? .lower : .exact)
        i.tt[g] = TTEntry(depth: n, score: f, flag: flag, best: m)
        return f
    }

    // MARK: `zn` — ENGINE.pickMove
    static func pickMove(board e: [Int], size: Int, side t: Color, difficulty: Difficulty = .medium,
                         timeMs: Double? = nil, maxDepth: Int? = nil) -> Result? {
        let s = preset(difficulty)
        let o = timeMs ?? s.timeMs
        let i = maxDepth ?? s.maxDepth
        let r = ownCells(e, size, t)
        if r.isEmpty { return nil }
        if s.randomize && i <= 1 {
            let l = annotate(e, size, t)
            if l.isEmpty { return nil }
            let f = Array(l.prefix(min(3, l.count)))
            let m = Double.random(in: 0..<1) < 0.3 ? f[Int(Double.random(in: 0..<1) * Double(f.count))] : f[0]
            return Result(move: m.move, score: m.score, depth: 1)
        }
        let M = nowMs() + max(40, o)
        let y = t.other
        let c = Context(deadline: M)
        var h = r[0]
        var g = 0.0
        var u = 0
        var d = annotate(e, size, t, jitter: false).map { $0.move }
        if d.isEmpty { d = r }
        let x = 50.0
        var l = 1
        while l <= i && !(nowMs() > M) {
            var f = l >= 4 ? g - x : -Double.infinity
            var m = l >= 4 ? g + x : Double.infinity
            var p = x
            var A = d[0]
            var k = -Double.infinity
            var I = false
            while true {
                k = -Double.infinity
                A = d[0]
                var E = f
                let a = m
                var w = true
                var v = false
                for D in d {
                    if nowMs() > M { c.abort = true; break }
                    let child = simulateMove(e, size, D.x, D.y, t)
                    var T: Double
                    if w {
                        T = -search(child, size, y, l - 1, -a, -E, c, 1, true)
                        w = false
                    } else {
                        T = -search(child, size, y, l - 1, -E - 1, -E, c, 1, true)
                        if !c.abort && T > E && T < a {
                            T = -search(child, size, y, l - 1, -a, -E, c, 1, true)
                        }
                    }
                    if c.abort { break }
                    if T > k { k = T; A = D }
                    if T > E { E = T }
                }
                if c.abort { break }
                if k <= f {
                    p *= 2; f = k - p; m = k + 1
                    if p > 4e3 { f = -Double.infinity; m = Double.infinity }
                    v = true
                } else if k >= m {
                    p *= 2; f = k - 1; m = k + p
                    if p > 4e3 { f = -Double.infinity; m = Double.infinity }
                    v = true
                }
                if !v { I = true; break }
            }
            if I {
                h = A; g = k; u = l
                d = [A] + d.filter { $0 != A }
                if g >= winScore - 1e3 { break }
            } else { break }
            l += 1
        }
        return Result(move: h, score: g, depth: u)
    }
}
