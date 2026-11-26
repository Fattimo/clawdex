"""Isolated sidebar tests; privileged commands are always mocked."""

import ast
import json
from functools import lru_cache
from copy import copy
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
        self.boss = SimpleNamespace(os_window_map={}, window_id_map={}, show_error=Mock())
        self.process = Mock(returncode=0)
        self.process.poll.return_value = None
        self.process.communicate.return_value = ("", None)
        self.spawn = Mock(return_value=self.process)
        self.env = dict(
            lru_cache=lru_cache, copy=copy, re=re, json=json, math=math, monotonic=Mock(return_value=1000),
            get_boss=lambda: self.boss, add_timer=Mock(return_value=7),
            remove_timer=Mock(), wcswidth=len, truncate_line=lambda s, n: s[:n],
            subprocess=SimpleNamespace(Popen=self.spawn, DEVNULL=subprocess.DEVNULL,
                                       PIPE=subprocess.PIPE, STDOUT=subprocess.STDOUT),
        )
        exec(compile(functions, str(source), "exec"), self.env)

    def bar(self, columns=24):
        cursor = SimpleNamespace(x=0, y=0, fg=0, bg=0, bold=False, italic=False)
        screen = SimpleNamespace(lines=20, columns=columns, cursor=cursor, draw=Mock())
        return SimpleNamespace(screen=screen, os_window_id=1)

    def test_footer_hitboxes_and_crowded_sidebar(self):
        bar = self.bar()
        self.env["draw_caffeine_footer"](bar, 10)
        controls = bar._clawdex_caffeine_controls
        self.assertEqual({action for _, action in controls}, {"caffeine", "toggle-claude", "toggle-codex", "close-claude", "close-codex"})
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
        self.env["draw_usage_footer"](bar.screen, 0, [], None)
        rows = "".join(call.args[0] for call in bar.screen.draw.call_args_list)
        self.assertEqual(rows, "0%   " + "░" * 13 + " −  × 100% " + "█" * 13 + " −  × ")
        self.boss._clawdex_usage["CC"] = [75, 999]
        self.env["draw_usage_footer"](bar.screen, 0, [], None)
        bar.screen.draw.assert_any_call("—    ")

    def test_close_only_confirmed_original_provider_windows(self):
        class Tab(list):
            id = 1
            windows = SimpleNamespace(num_groups=2)

        def pane(name, pane_id):
            return SimpleNamespace(user_vars={}, title=name, id=pane_id)

        tab = Tab([pane("Claude", 7), pane("Codex", 8)])
        tab.active_window = tab[1]
        manager = SimpleNamespace(tabs=[tab], active_tab=tab, mark_tab_bar_dirty=Mock())
        self.boss.mark_window_for_close = Mock()
        self.boss.confirm = Mock()
        self.env["close_agent_panes"](manager, "claude")
        confirm = self.boss.confirm.call_args.args[1]
        confirm(False)
        self.boss.mark_window_for_close.assert_not_called()
        tab[0] = pane("Claude", 9)
        confirm(True)
        self.boss.mark_window_for_close.assert_not_called()
        self.env["close_agent_panes"](manager, "claude")
        self.boss.confirm.call_args.args[1](True)
        self.boss.mark_window_for_close.assert_called_once_with(tab[0])

    def test_remount_only_missing_configured_panes_once(self):
        class Tab(list):
            def __init__(self, title, agents):
                super().__init__([SimpleNamespace(title=a, user_vars={}) for a in agents])
                self.effective_title = title
                self.active_window = self[0]
                self.goto_layout = Mock()
                self.set_active_window = Mock()

        app = Tab("● app", ["Codex"])
        other = Tab("clawdex", ["Codex"])
        spec = SimpleNamespace(opts=SimpleNamespace(location="default"), args=["zsh"])
        self.env["workspace_launches"] = lambda: {"app": {"claude": spec, "codex": spec}}
        manager = SimpleNamespace(tabs=[app, other], mark_tab_bar_dirty=Mock())
        def launch(boss, opts, args, target_tab, force_target_tab):
            self.assertIs(target_tab, app)
            self.assertEqual(opts.location, "first")
            target_tab.append(SimpleNamespace(title="Claude", user_vars={}))
            return target_tab[-1]
        self.env["launch"] = Mock(side_effect=launch)
        self.env["remount_agent_panes"](manager, "claude")
        self.env["remount_agent_panes"](manager, "claude")
        self.env["launch"].assert_called_once()
        self.assertEqual(spec.opts.location, "default")

    def test_usage_uses_trusted_open_checkout(self):
        self.env["Path"] = Path
        checkout = Path(__file__).resolve().parents[2]
        select = self.env["usage_working_directory"]
        projects = {str(checkout): {"hasTrustDialogAccepted": True}}
        self.assertEqual(select([str(checkout / "Tests")], projects), checkout)
        self.assertIsNone(select([str(checkout.parent)], projects))

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
