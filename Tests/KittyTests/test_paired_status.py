from pathlib import Path
from types import SimpleNamespace
import unittest

# Load the helper without importing the GUI extension modules.
import ast


class PairedStatusTests(unittest.TestCase):
    def test_agent_slots_are_stable_across_updates_and_disconnects(self):
        path = Path(__file__).resolve().parents[2] / "kitty/tab_bar.py"
        node = next(n for n in ast.parse(path.read_text()).body if getattr(n, "name", "") == "paired_status")
        namespace = {}
        exec(compile(ast.Module(body=[node], type_ignores=[]), str(path), "exec"), namespace)
        status = namespace["paired_status"]
        claude = SimpleNamespace(child_title="", user_vars={"clawdex_status": "claude:●:ready:#ff9900"})
        codex = SimpleNamespace(child_title="", user_vars={"clawdex_status": "codex:○:dim:#7777ff"})
        panes = [codex, claude]
        self.assertEqual(status(panes), [("●", True, 0xff9900), ("○", False, 0x7777ff)])
        codex.user_vars["clawdex_status"] = "codex:●:ready:#7777ff"
        codex.child_title = "⠙ Reviewing changes"
        self.assertEqual(status(panes)[1], ("○", False, 0x7777ff))
        codex.user_vars.clear()
        self.assertEqual(status(panes)[1][0], "·")
        self.assertIsNone(status([claude]))
