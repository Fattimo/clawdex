"""Isolated hook/config checks: python3 -m unittest discover -s Tests/HookTests."""
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(shutil.which("jq"), "jq is required for config merging")
class CodexHooksTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="clawdex-hooks-")
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.config = self.home / "codex" / "hooks.json"
        self.hook = self.home / "pet's hooks $(touch nope)" / "clawdex-hook"

    def manage(self, action="install", check=True):
        return subprocess.run(
            ["sh", str(ROOT / "hooks/manage-codex-hooks"), action,
             str(self.config), str(self.hook)],
            capture_output=True, text=True, check=check, timeout=5,
        )

    def write_config(self, value):
        self.config.parent.mkdir(parents=True, exist_ok=True)
        self.config.write_text(json.dumps(value))

    def test_install_preserves_other_handlers_and_is_idempotent(self):
        other = {"type": "command", "command": "/policy/check"}
        group = {"matcher": "Bash", "hooks": [other, {
            "type": "command", "command": "/old/clawdex-hook codex"}]}
        self.write_config({"description": "my hooks", "hooks": {"PreToolUse": [group]}})
        self.manage()
        first = self.config.read_text()
        data = json.loads(first)
        self.assertEqual(data["description"], "my hooks")
        self.assertEqual(data["hooks"]["PreToolUse"][0], {"matcher": "Bash", "hooks": [other]})
        for event in ("Interrupt", "SessionEnd", "SubagentStart", "Stop"):
            self.assertIn(event, data["hooks"])
        command = data["hooks"]["Stop"][0]["hooks"][0]["command"]
        self.assertEqual(shlex.split(command), [str(self.hook), "codex"])
        self.manage()
        self.assertEqual(self.config.read_text(), first)
        self.manage("remove")
        self.assertEqual(json.loads(self.config.read_text()), {
            "description": "my hooks", "hooks": {
                "PreToolUse": [{"matcher": "Bash", "hooks": [other]}]}})

    def test_new_install_and_remove(self):
        self.manage()
        self.assertIn("UserPromptSubmit", json.loads(self.config.read_text())["hooks"])
        self.manage("remove")
        self.assertEqual(json.loads(self.config.read_text()), {})

    def test_remove_missing_config_is_noop(self):
        self.manage("remove")
        self.assertFalse(self.config.exists())

    def test_invalid_json_is_left_untouched(self):
        self.config.parent.mkdir()
        self.config.write_text('{"hooks": broken')
        for action in ("install", "remove"):
            result = self.manage(action, check=False)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(self.config.read_text(), '{"hooks": broken')
        self.assertEqual(list(self.config.parent.iterdir()), [self.config])

    def test_unexpected_config_documents_are_left_untouched(self):
        self.config.parent.mkdir()
        for value in ("null", "[]", "{} {}"):
            self.config.write_text(value)
            result = self.manage(check=False)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(self.config.read_text(), value)

    def test_empty_unrelated_matcher_group_is_preserved(self):
        group = {"matcher": "unused", "hooks": []}
        self.write_config({"hooks": {"PreToolUse": [group]}})
        self.manage()
        self.manage("remove")
        self.assertEqual(json.loads(self.config.read_text()), {"hooks": {"PreToolUse": [group]}})

    def event(self, name, agent="codex", project_dir=None, **fields):
        (self.home / ".clawdex").mkdir(exist_ok=True)
        env = dict(os.environ, HOME=str(self.home), CLAWDEX_SOCK=str(self.home / "no-socket"))
        env.pop("CLAWDEX_NO_TRAIL", None)
        env.pop("CLAWDEX_AGENT", None)
        env.pop("CLAUDE_PROJECT_DIR", None)
        if project_dir is not None:
            env["CLAUDE_PROJECT_DIR"] = project_dir
        result = subprocess.run(
            ["sh", str(ROOT / "hooks/clawdex-hook"), agent],
            input=json.dumps({"hook_event_name": name, "cwd": str(self.home), **fields}),
            capture_output=True, text=True, env=env, check=True, timeout=5,
        )
        self.assertEqual(result.stdout, "")
        return json.loads((self.home / ".clawdex/hook-trail.log").read_text().splitlines()[-1].split(" ", 1)[1])

    def test_codex_native_tools(self):
        for tool, text, row in (("apply_patch", "Editing files", 7),
                                ("update_plan", "Updating the plan", 8),
                                ("spawn_agent", "Running a subagent…", 7)):
            data = self.event("PreToolUse", tool_name=tool, tool_input={})
            self.assertEqual((data["agent"], data["row"], data["text"]), ("codex", row, text))

    def test_escaped_payload_and_nested_metadata(self):
        transcript = str(self.home / 'a "quoted" rollout.jsonl')
        data = self.event("PreToolUse", tool_name="Bash", transcript_path=transcript,
                          tool_input={"command": 'echo "hi"', "cwd": "/wrong", "tool_name": "wrong"})
        self.assertEqual(data["text"], 'echo "hi"')
        self.assertEqual(data["tool"], "Bash")
        self.assertEqual(data["transcript"], transcript)
        self.assertEqual(data["root"], str(self.home))

    def test_claude_session_keeps_launch_project_after_cd(self):
        launch = self.home / "appcopy"
        other = self.home / "demo-redate-issues"
        for repo in (launch, other):
            (repo / ".git").mkdir(parents=True)
        (other / "src").mkdir()
        data = self.event("PreToolUse", agent="claude", project_dir=str(launch),
                          cwd=str(other / "src"), tool_name="Bash", tool_input={"command": "ls"})
        self.assertEqual((data["source"], data["root"]), ("appcopy", str(launch)))
        # Codex can inherit CLAUDE_PROJECT_DIR from a parent Claude; it keeps its cwd.
        data = self.event("PreToolUse", agent="codex", project_dir=str(launch),
                          cwd=str(other / "src"), tool_name="Bash", tool_input={"command": "ls"})
        self.assertEqual(data["source"], "demo-redate-issues")

    def test_interrupt_and_session_end_release_work(self):
        for name in ("Interrupt", "SessionEnd"):
            data = self.event(name)
            self.assertEqual((data["event"], data["row"], data["mode"]), (name, 0, "release"))

    def test_session_identity_and_resume_source_survive_translation(self):
        data = self.event("SessionStart", session_id='session-"quoted"', source="resume", turn_id="turn-123")
        self.assertEqual(data["session_id"], 'session-"quoted"')
        self.assertEqual(data["session_source"], "resume")
        self.assertEqual(data["turn_id"], "turn-123")
        self.assertEqual(data["source"], self.home.name)

    def test_claude_still_uses_original_mapping(self):
        data = self.event("PreToolUse", agent="claude", tool_name="Read",
                          tool_input={"file_path": "/tmp/example.swift"})
        self.assertEqual((data["agent"], data["row"], data["text"]),
                         ("claude", 8, "Reading example.swift"))


if __name__ == "__main__":
    unittest.main()
