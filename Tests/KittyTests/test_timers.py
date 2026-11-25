"""Isolated sidebar tests; privileged commands are always mocked."""

import ast
import json
import math
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
            json=json, math=math, monotonic=Mock(return_value=1000),
            get_boss=lambda: self.boss, add_timer=Mock(return_value=7),
            remove_timer=Mock(), wcswidth=len, truncate_line=lambda s, n: s[:n],
            subprocess=SimpleNamespace(Popen=self.spawn, DEVNULL=subprocess.DEVNULL,
                                       PIPE=subprocess.PIPE, STDOUT=subprocess.STDOUT),
        )
        exec(compile(functions, str(source), "exec"), self.env)

    def finish(self, code=0, output=""):
        self.process.returncode = code
        self.process.poll.return_value = code
        self.process.communicate.return_value = (output, None)
        self.env["refresh_shutdown"](7)

    def test_schedule_extend_and_cancel(self):
        self.env["change_shutdown"]()
        arguments = self.spawn.call_args.args[0]
        self.assertEqual(arguments[:2], ["/usr/bin/osascript", "-e"])
        self.assertIn("/sbin/shutdown -h +15", arguments[2])
        self.assertIn("with administrator privileges", arguments[2])
        self.assertTrue(self.spawn.call_args.kwargs["start_new_session"])
        self.finish()
        self.assertEqual(self.boss._clawdex_shutdown["deadline"], 1900)
        self.process.poll.return_value = None
        self.env["change_shutdown"]()
        self.assertIn("/sbin/shutdown -h +30", self.spawn.call_args.args[0][2])
        self.finish()
        self.assertEqual(self.boss._clawdex_shutdown["deadline"], 2800)
        self.process.poll.return_value = None
        self.env["change_shutdown"](cancel=True)
        script = self.spawn.call_args.args[0][2]
        self.assertIn("/usr/bin/killall -q -u root shutdown", script)
        self.assertNotIn("/sbin/shutdown", script)
        self.finish()
        self.assertEqual(self.boss._clawdex_shutdown["deadline"], 0)
        self.env["remove_timer"].assert_called_once_with(7)

    def test_pending_auth_does_not_block_or_duplicate(self):
        self.env["change_shutdown"]()
        self.env["change_shutdown"]()
        self.env["refresh_shutdown"](7)
        self.spawn.assert_called_once()
        self.process.communicate.assert_not_called()
        self.assertEqual(self.boss._clawdex_shutdown["deadline"], 0)

    def test_canceling_auth_preserves_schedule(self):
        self.env["shutdown_state"]()["deadline"] = 1900
        self.env["change_shutdown"](cancel=True)
        self.finish(1, "User canceled. (-128)")
        self.assertEqual(self.boss._clawdex_shutdown["deadline"], 1900)
        self.boss.show_error.assert_not_called()

    def test_command_failure_is_reported(self):
        self.env["change_shutdown"]()
        self.finish(1, "shutdown failed")
        self.assertEqual(self.boss._clawdex_shutdown["deadline"], 0)
        self.boss.show_error.assert_called_once()

    def test_spawn_failure_is_reported(self):
        self.spawn.side_effect = OSError("cannot launch")
        self.env["change_shutdown"]()
        self.assertIsNone(self.boss._clawdex_shutdown["pending"])
        self.boss.show_error.assert_called_once()

    def bar(self, columns=24):
        cursor = SimpleNamespace(x=0, y=0, fg=0, bg=0, bold=False, italic=False)
        screen = SimpleNamespace(lines=20, columns=columns, cursor=cursor, draw=Mock())
        return SimpleNamespace(screen=screen)

    def test_footer_hitboxes_and_crowded_sidebar(self):
        bar = self.bar()
        self.env["draw_caffeine_footer"](bar, 10)
        controls = bar._clawdex_caffeine_controls
        self.assertIn(((18, 14, 21, 17), "shutdown"), controls)
        self.assertIn(((18, 17, 21, 20), "caffeine"), controls)
        self.assertFalse(any(action.endswith("-stop") for _, action in controls))
        self.env["shutdown_state"]()["deadline"] = 1900
        self.env["draw_caffeine_footer"](bar, 10)
        self.assertIn(((21, 14, 24, 17), "shutdown-stop"), bar._clawdex_caffeine_controls)
        self.env["draw_caffeine_footer"](bar, 15)
        self.assertTrue(all(action == "caffeine" for _, action in bar._clawdex_caffeine_controls))
        self.env["draw_caffeine_footer"](bar, 18)
        self.assertEqual(bar._clawdex_caffeine_controls, [])
        self.env["draw_caffeine_footer"](self.bar(columns=11), 0)

    def test_pending_authorization_disables_shutdown_hitboxes(self):
        self.env["change_shutdown"]()
        bar = self.bar()
        self.env["draw_caffeine_footer"](bar, 0)
        self.assertTrue(all(action == "caffeine" for _, action in bar._clawdex_caffeine_controls))


if __name__ == "__main__":
    unittest.main()
