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

### Codex too

Codex shares Claude Code's hook contract (same event names, same stdin payload), so the same pet reacts to your Codex sessions. `install.sh` writes a clawdex-managed `~/.codex/hooks.json`; Codex sessions are tagged with the `codex` agent so they get their own switchboard pill, bubble, and accent color (`repo ·cdx`) — a Claude and a Codex session in the same repo stay distinct.

One manual step: Codex gates hooks behind a one-time **trust prompt** — approve it on next launch (it can't be safely pre-seeded). Verify it's flowing with `tail -f ~/.clawdex/hook-trail.log` — you should see `"agent":"codex"` lines as Codex works.

## Install

One command, source-from-clone:

```bash
git clone https://github.com/danielkempe/clawdex && cd clawdex && ./install.sh
```

`install.sh` runs `swift build -c release`, symlinks the binaries into a writable PATH dir (`/opt/homebrew/bin`, `/usr/local/bin`, or `~/.clawdex/bin` as a fallback), wires the Claude Code hooks into `~/.claude/settings.json`, and starts the daemon via launchd. Idempotent — safe to re-run.

Homebrew (requires up-to-date Xcode Command Line Tools):

```bash
brew install danielkempe/clawdex/clawdex
$(brew --prefix)/share/clawdex/install.sh
clawdex wake
```

## Get a pet

`clawdex` reads pets from `~/.codex/pets/` and `~/.clawdex/pets/`. **Existing Codex pets work unmodified.**

The fastest way to get one is [petdex](https://github.com/crafter-station/petdex), the community catalog of 467+ Codex-compatible pets:

```bash
npx petdex install noir-webling     # a noir-detective spider
npx petdex install lil-finder-guy   # one of the popular ones
```

Or browse [petdex.crafter.run](https://petdex.crafter.run) to pick.

Already have your own atlas? Drag-drop the `pet.json` + `spritesheet.webp` pair onto [the web renderer](web/index.html) to validate it against the spec, then copy to `~/.codex/pets/<name>/`.

The bundled `skill/hatch-pet/` is the format reference + atlas validator (`validate_atlas.py`). It does not generate sprite images itself — bring your own image-gen tool (MidJourney, DALL-E, hand-drawn pixel art) and use the per-row prompts in [`SKILL.md`](skill/hatch-pet/SKILL.md).

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
