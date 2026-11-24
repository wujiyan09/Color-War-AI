"""Analyzer (DriveBotpickEngine / DotsPickEngine) internal rules == GameModel executeMove (Color War), 2026-11-24.
No Swift toolchain here: assert the Swift source carries the rule, and check a line-by-line Python port of the
analyzer cascade against a port of GameModel's executeMove over thousands of random positions."""
import random, unittest
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
BP = (ROOT / "DriveBotpickEngine.swift").read_text()
DP = (ROOT / "DotsPickEngine.swift").read_text()
GM = (ROOT / "GameModel.swift").read_text()


def game(board, n, r, c, p):  # GameModel executeMove (non-first move)
    board[r][c] = [p, board[r][c][1] + 1]
    wave = [(r, c)] if board[r][c][1] >= 4 else []
    while wave:
        ex = wave
        tr = [(a + dr, b + dc) for a, b in ex for dr, dc in ((-1, 0), (1, 0), (0, -1), (0, 1)) if 0 <= a + dr < n and 0 <= b + dc < n]
        for a, b in ex:
            board[a][b][1] -= 4
            board[a][b][0] = None if board[a][b][1] == 0 else p
        ch = []
        for a, b in tr:
            board[a][b] = [p, board[a][b][1] + 1]
            if (a, b) not in ch: ch.append((a, b))
        wave = [(a, b) for a, b in ch if board[a][b][1] >= 4]


def analyzer(cells, n, idx, mover):  # port of DriveBotpickEngine.makeMove cascade (cells: (owner, charge) or None)
    cells[idx] = (mover, cells[idx][1] + 1)
    wave = [idx] if cells[idx][1] >= 4 else []
    while wave:
        ex = [e for e in wave if cells[e][1] >= 4]
        if not ex: break
        for e in ex:
            left = cells[e][1] - 4
            cells[e] = (mover, left) if left > 0 else None
        ch = []
        for e in ex:
            r, c = divmod(e, n)
            for a in [e + 1 if c + 1 < n else None, e - 1 if c > 0 else None, e + n if r + 1 < n else None, e - n if r > 0 else None]:
                if a is None: continue
                cells[a] = (mover, min(15, (cells[a][1] if cells[a] else 0) + 1))
                if a not in ch: ch.append(a)
        wave = [a for a in ch if cells[a][1] >= 4]


class AnalyzerRules(unittest.TestCase):
    def test_swift_source_uses_color_war_rules(self):
        for src in (BP, DP):
            self.assertIn("Color War rules (2026-11-24", src)
            self.assertIn("- 4", src) if src is BP else self.assertIn("- criticality", src)
        self.assertIn("setCell(e, left > 0 ? DriveBotpickEngine.encode(mover, left) : 0)", BP)
        self.assertIn("b[e] = left > 0 ? cell(col, left) : 0", DP)
        self.assertNotIn("resolved = true", BP)
        self.assertIn("board[r][c].count -= 4", GM)

    def test_port_matches_game(self):
        rnd = random.Random(7); checked = 0
        for t in range(3000):
            n = [3, 4, 5, 6, 9, 12][t % 6]
            board = [[[None, 0] if rnd.random() < .35 else [rnd.randint(0, 1), rnd.randint(1, 6 if rnd.random() < .1 else 3)] for _ in range(n)] for _ in range(n)]
            own = [(r, c) for r in range(n) for c in range(n) if board[r][c][0] == 0]
            if not own: continue
            r, c = rnd.choice(own)
            cells = [None if x[0] is None else (x[0], x[1]) for row in board for x in row]
            game(board, n, r, c, 0)
            if any(x[1] > 15 for row in board for x in row): continue
            analyzer(cells, n, r * n + c, 0)
            self.assertEqual(cells, [None if x[0] is None else (x[0], x[1]) for row in board for x in row])
            checked += 1
        self.assertGreater(checked, 2500)


if __name__ == "__main__":
    unittest.main()
