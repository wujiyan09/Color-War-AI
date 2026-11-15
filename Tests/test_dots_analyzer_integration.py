from html.parser import HTMLParser
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
SWIFT = (ROOT / "ContentView.swift").read_text()
HTML = (ROOT / "Resources" / "DotsAnalyzer.html").read_text()
PACKAGE = (ROOT / "Package.swift").read_text()


class InlineScripts(HTMLParser):
    def __init__(self):
        super().__init__()
        self.scripts = []
        self.current = None

    def handle_starttag(self, tag, attrs):
        if tag == "script":
            self.current = []

    def handle_data(self, data):
        if self.current is not None:
            self.current.append(data)

    def handle_endtag(self, tag):
        if tag == "script" and self.current is not None:
            self.scripts.append("".join(self.current))
            self.current = None


class DotsAnalyzerIntegrationTests(unittest.TestCase):
    def test_html_is_bundled_as_app_resource(self):
        self.assertIn('.process("Resources")', PACKAGE)
        self.assertTrue((ROOT / "Resources" / "DotsAnalyzer.html").is_file())
        self.assertIn('forResource: "DotsAnalyzer", withExtension: "html"', SWIFT)

    def test_analyzer_is_separate_offline_webview_not_native_ai_replacement(self):
        self.assertIn("import WebKit", SWIFT)
        self.assertIn("struct DotsAnalyzerWebView: UIViewRepresentable", SWIFT)
        self.assertIn("webView.loadFileURL", SWIFT)
        self.assertIn("navigationAction.request.url?.isFileURL == true ? .allow : .cancel", SWIFT)
        self.assertIn("window.__dots.importStateCode(code, true); window.__dots.compute();", SWIFT)
        self.assertIn("不会写回原对局", SWIFT)

    def test_live_position_export_is_limited_to_stable_supported_two_player_boards(self):
        self.assertIn("[6, 9, 12].contains(game.boardSize)", SWIFT)
        self.assertIn("game.activePlayerIndices.count == 2", SWIFT)
        self.assertIn("!game.isProcessingCascade", SWIFT)
        self.assertIn("(1...3).contains(cell.count)", SWIFT)
        self.assertIn('"DOTS1|\\(game.boardSize)|\\(turn)|', SWIFT)
        self.assertIn('pieces.append("\\(column),\\(row),\\(color),\\(cell.count)")', SWIFT)

    def test_imported_analyzer_has_no_external_scraper_or_userscript(self):
        lowered = HTML.lower()
        for forbidden in ("userscript", "dotscapture", "dots-online.com", "copy-userscript", "scrape("):
            self.assertNotIn(forbidden, lowered)
        self.assertNotRegex(lowered, r'<(?:script|link)[^>]+(?:src|href)=["\']https?://')

    def test_analyzer_keeps_its_own_local_copy_and_state_import(self):
        self.assertIn("function importStateCode(code, quiet)", HTML)
        self.assertIn("window.__dots = {", HTML)
        self.assertIn("state.board = parsed.board", HTML)
        self.assertIn("state.turn = parsed.turn", HTML)
        self.assertIn("state.board = out.board", HTML)
        self.assertIn("此页中的编辑和“应用此手”仅作用于分析副本", HTML)

    def test_inline_scripts_are_present_and_closed(self):
        parser = InlineScripts()
        parser.feed(HTML)
        self.assertIsNone(parser.current)
        self.assertGreaterEqual(len(parser.scripts), 2)
        self.assertTrue(all(script.strip() for script in parser.scripts))


if __name__ == "__main__":
    unittest.main()
