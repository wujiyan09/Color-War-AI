from pathlib import Path
import unittest
ACC = (Path(__file__).resolve().parents[1] / "Account.swift").read_text()

class LeaderboardPeriodTests(unittest.TestCase):
    def test_auto_fallback_through_periods(self):
        self.assertIn("for candidate in LeaderboardPeriod.allCases", ACC)
        self.assertIn("if !response.entries.isEmpty { return (candidate, response) }", ACC)
        self.assertEqual(ACC.count("loadLeaderboardWithFallback(store: store, period: period, isAuto: isAutoPeriod"), 2)

    def test_manual_pick_disables_auto(self):
        self.assertIn("isAuto.wrappedValue = false", ACC)
        self.assertEqual(ACC.count("LeaderboardControls(period: manualPeriodBinding($period, isAuto: $isAutoPeriod, boardSize: $boardSize)"), 2)

if __name__ == "__main__":
    unittest.main()

class PeriodsAndStatsTests(unittest.TestCase):
    def test_periods(self):
        self.assertIn("case week, month, all", ACC)
        self.assertIn('case .all: return "总榜"', ACC)
        self.assertNotIn("季榜", ACC)

    def test_stats_refresh_after_upload(self):
        i = ACC.index("func uploadPendingMatches")
        self.assertIn("await refreshMe()", ACC[i:i + 1200])

class FriendsCacheTests(unittest.TestCase):
    def test_friends_cached_and_refreshed_on_open(self):
        self.assertIn('forKey: "CW_Account_CachedFriends"', ACC)
        self.assertIn("decode(FriendsResponse.self, from: data)", ACC)
        self.assertIn("await store.refreshHistory()\n            await store.refreshFriends()", ACC)
