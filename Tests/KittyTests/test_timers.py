"""Isolated sidebar tests; privileged commands are always mocked."""

import ast
import json
import math
import re
from pathlib import Path
import subprocess
from types import SimpleNamespace
import unittest
from unittest.mock import Mock


class SidebarTimerTests(unittest.TestCase):
    def setUp(self):
        source = Path(__file__).resolve().parents[2] / "kitty/tab_bar.py"
        tree = ast.parse(source.read_text())
        functions = ast.Module(
            body=[node for node in tree.body if isinstance(node, ast.FunctionDef)],
            type_ignores=[],
        )
        self.boss = SimpleNamespace(os_window_map={}, show_error=Mock())
        self.process = Mock(returncode=0)
        self.process.poll.return_value = None
        self.process.communicate.return_value = ("", None)
        self.spawn = Mock(return_value=self.process)
        self.env = dict(
            re=re, json=json, math=math, monotonic=Mock(return_value=1000),
            get_boss=lambda: self.boss, add_timer=Mock(return_value=7),
            remove_timer=Mock(), wcswidth=len, truncate_line=lambda s, n: s[:n],
            subprocess=SimpleNamespace(Popen=self.spawn, DEVNULL=subprocess.DEVNULL,
                                       PIPE=subprocess.PIPE, STDOUT=subprocess.STDOUT),
        )
        exec(compile(functions, str(source), "exec"), self.env)

    def bar(self, columns=24):
        cursor = SimpleNamespace(x=0, y=0, fg=0, bg=0, bold=False, italic=False)
        screen = SimpleNamespace(lines=20, columns=columns, cursor=cursor, draw=Mock())
        return SimpleNamespace(screen=screen)

    def test_footer_hitboxes_and_crowded_sidebar(self):
        bar = self.bar()
        self.env["draw_caffeine_footer"](bar, 10)
        controls = bar._clawdex_caffeine_controls
        self.assertEqual({action for _, action in controls}, {"caffeine"})
        self.assertIn(((18, 17, 21, 20), "caffeine"), controls)
        drawn = "".join(call.args[0] for call in bar.screen.draw.call_args_list)
        for label in ("Weekly used", "CC", "Codex"):
            self.assertNotIn(label, drawn)
        self.env["draw_caffeine_footer"](bar, 18)
        self.assertEqual(bar._clawdex_caffeine_controls, [])
        self.env["draw_caffeine_footer"](self.bar(columns=11), 0)

    def test_weekly_bars_and_expired_window(self):
        self.env["time"] = lambda: 1000
        self.boss._clawdex_usage = {"CC": [0, 2000], "Codex": (100, 2000)}
        bar = self.bar()
        self.env["draw_usage_footer"](bar.screen, 0)
        rows = "".join(call.args[0] for call in bar.screen.draw.call_args_list)
        self.assertEqual(rows, "0%   " + "░" * 19 + "100% " + "█" * 19)
        self.boss._clawdex_usage["CC"] = [75, 999]
        self.env["draw_usage_footer"](bar.screen, 0)
        bar.screen.draw.assert_any_call("—    ")

    def test_claude_usage_matches_only_all_models_week(self):
        parse = self.env["claude_weekly_percent"]
        other = b"Current session\r 50% used\r Current week (Fable)\r 0% used"
        self.assertIsNone(parse(other))
        self.assertEqual(parse(b"Current\x1b[11Gweek (all models)\r  99% used\r" + other), 99)
        self.assertIsNone(parse(b"Current week (all models)\r Loading\r" + other))

    def test_usage_pauses_until_any_window_returns(self):
        state = self.boss._clawdex_usage = {}
        self.boss.os_window_map = {1: Mock(), 2: Mock()}
        hidden = {1, 2}
        thread = Mock()
        thread.return_value.is_alive.return_value = False
        path = Mock()
        path.home.side_effect = OSError()
        self.env.update(Thread=thread, Path=path, os_window_is_invisible=hidden.__contains__)
        tick = self.env["refresh_usage"]
        tick(1)
        path.home.assert_not_called()
        thread.assert_not_called()
        hidden.remove(2)
        tick(1)
        tick(1)
        self.assertEqual(thread.call_count, 2)
        hidden.add(2)
        self.env["monotonic"].return_value += 200
        tick(1)
        self.assertEqual(thread.call_count, 2)
        hidden.remove(1)
        tick(1)
        self.assertEqual(thread.call_count, 4)
        thread.return_value.is_alive.return_value = True
        self.env["monotonic"].return_value += 1000
        tick(1)
        self.assertEqual(thread.call_count, 4)

    def test_codex_week_can_be_either_window(self):
        week = {"windowDurationMins": 10080, "usedPercent": 37, "resetsAt": 2000}
        for key in ("primary", "secondary"):
            result = {"rateLimits": {key: week}}
            self.assertEqual(self.env["codex_weekly_window"](result), (37, 2000))
        self.assertIsNone(self.env["codex_weekly_window"]({"rateLimits": {
            "primary": {"windowDurationMins": 300}}}))


if __name__ == "__main__":
    unittest.main()
