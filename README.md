# clawdex

A Codex-pet-compatible companion overlay for Claude Code.

> Anthropic shipped Skills first. OpenAI cloned the format and shipped pets. So we cloned pets back. Every Codex pet now lives in Claude Code.

```bash
brew install danielkempe/clawdex/clawdex
clawdex wake
```

If you already have Codex pets in `~/.codex/pets/`, they all work. Drop in, done.

## What it does

`clawdex` runs a tiny floating sprite in the corner of your screen that reacts to what Claude Code is doing:

| Claude Code is...      | Pet does       |
| ---------------------- | -------------- |
| Thinking about your prompt | reviewing  |
| Running a Bash/Edit/Write tool | running |
| Reading or grepping    | reviewing      |
| Asking for permission  | waiting        |
| Done with a task       | waving         |
| Idle                   | idle / blinking |

State changes are driven by Claude Code [hooks](https://docs.anthropic.com/claude-code/hooks) and the statusline API.

## Install

### Homebrew

```bash
brew install danielkempe/clawdex/clawdex
clawdex install   # registers hooks in ~/.claude/settings.json and starts the daemon
clawdex wake
```

### From source

```bash
git clone https://github.com/danielkempe/clawdex
cd clawdex
swift build -c release
cp .build/release/clawdexd /usr/local/bin/
cp .build/release/clawdex  /usr/local/bin/
./install.sh
```

## Get a pet

`clawdex` reads pets from `~/.codex/pets/` and `~/.clawdex/pets/`. **Existing Codex pets work unmodified.**

Three ways to get one:

1. **petdex** (community catalog of Codex pets):
   ```bash
   npx petdex install noir-webling
   ```
2. **Hatch one in Claude Code.** Drop the `skill/hatch-pet/` folder into your skills directory and ask Claude `hatch a pet that looks like a snow leopard with a tiny laptop`.
3. **Drag-drop your own atlas** at [the web renderer](web/index.html) to verify it works, then copy to `~/.codex/pets/<name>/`.

## How it works

```
Claude Code event
        │
        ▼
~/.claude/settings.json hooks
        │
        ▼
clawdex-hook (stdin JSON → row mapping)
        │
        ▼ (Unix socket: ~/.clawdex/sock)
clawdexd (NSPanel daemon)
        │
        ▼
Animated sprite, Codex 8×9 atlas spec
```

- **`clawdexd`** — Swift NSPanel daemon. Floating, click-through, all-spaces, transparent. ~500 LOC.
- **`clawdex`** — CLI for `wake`/`tuck`/`select`/`list`.
- **`hooks/clawdex-hook`** — POSIX shell, no deps. Translates Claude Code hook payloads to one-line JSON events.
- **`hooks/clawdex-statusline`** — heartbeat tick so the daemon falls back to idle if Claude Code crashes mid-tool-call.

The atlas format, animation row schedule, and validator are spec-compatible with [openai/skills hatch-pet](https://github.com/openai/skills/tree/main/skills/.curated/hatch-pet) (Apache 2.0). See [`skill/hatch-pet/NOTICE`](skill/hatch-pet/NOTICE).

## State mapping

Full table with rationale: [`docs/state-mapping.md`](docs/state-mapping.md).

## Development

```bash
swift build           # builds clawdexd + clawdex
swift run clawdexd     # launch daemon (foreground)
hooks/mock-daemon.sh  # bash stand-in for the daemon, for testing hooks
open web/index.html   # interactive atlas renderer
```

Test the full hook pipeline without the GUI:
```bash
./hooks/mock-daemon.sh &
echo '{"hook_event_name":"PreToolUse","tool_name":"Bash"}' | hooks/clawdex-hook
# → {"event":"PreToolUse","tool":"Bash","row":7,"mode":"sticky","ttl":0,"ts":...}
```

## Compatibility

| Source                            | Works in clawdex | Works in Codex |
| --------------------------------- | :-------------: | :------------: |
| Pets in `~/.codex/pets/`          |        ✓        |        ✓       |
| Pets in `~/.clawdex/pets/`         |        ✓        |        —       |
| `npx petdex install <name>`       |        ✓        |        ✓       |
| `hatch-pet` skill (this repo)     |        ✓        |        ✓       |

## License

MIT for clawdex itself. Apache 2.0 components (`skill/hatch-pet/validate_atlas.py`, animation row spec) carry their upstream notices — see [`skill/hatch-pet/NOTICE`](skill/hatch-pet/NOTICE).
