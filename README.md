# clawdex

A Codex-pet-compatible companion overlay for Claude Code and Codex CLI.

> Anthropic shipped Skills first. OpenAI cloned the format and shipped pets. So we cloned pets back. Every Codex pet now lives in Claude Code.

```bash
brew install danielkempe/clawdex/clawdex
clawdex wake
```

If you already have Codex pets in `~/.codex/pets/`, they all work. Drop in, done.

## What it does

`clawdex` runs a tiny floating sprite in the corner of your screen that reacts to what Claude Code or Codex CLI is doing:

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

Codex CLI uses the same core lifecycle hook fields, so the same pet reacts to your Codex sessions. `install.sh` merges clawdex handlers into `~/.codex/hooks.json` (or `$CODEX_HOME/hooks.json`), preserving other hooks. Re-running it replaces existing clawdex handlers; `uninstall.sh` removes them. Automatic merging requires `jq`; without it, the installer prints manual setup instructions.

To enable it after updating this checkout:

1. Run `./install.sh` to build and install the updated integration.
2. Launch Codex CLI and open `/hooks` to review and trust the clawdex hooks. Changed definitions need another review. See the [official hook documentation](https://learn.chatgpt.com/docs/hooks).
3. Run `clawdex wake` and send a prompt in Codex.

Codex sessions get their own switchboard pill, bubble, and accent color (`repo ·cdx`), keeping Claude and Codex in the same repo distinct. Shell commands animate as work, `apply_patch` narrates editing, and `update_plan` shows reviewing. Interrupting a turn returns the pet to idle and lights the pill; closing the CLI removes its pill. Clicking a CLI pill returns to its launching terminal or editor; kitty can focus the exact tab when remote control is configured. Other terminals are brought to the front. Desktop Codex sessions retain their thread deep links.

Verify events with `tail -f ~/.clawdex/hook-trail.log` — look for `"agent":"codex"`. If nothing arrives, check `/hooks` for disabled or untrusted hooks and ensure hooks are enabled in your Codex configuration. The shared hook script uses `jq` for structured payload parsing when available, with a basic shell parser as a fallback.

For kitty, enable `allow_remote_control socket-only` and `listen_on unix:${TMPDIR}/kitty` in `kitty.conf`, then restart kitty if these settings are new. Clawdex mirrors readiness onto the session's tab with a `●`/`○` marker and accent color. Codex can share a server across CLI clients, so its hook's inherited window ID may belong to another tab. Clawdex uses kitty's foreground Codex process and project directory to find the actual client, including one launched from a parent directory such as `projects`. If several Codex clients run in the same project, the mapping is ambiguous; clawdex leaves their tabs unchanged rather than choosing one. Failed updates retry on later events.

## Install

One command, source-from-clone:

```bash
git clone https://github.com/danielkempe/clawdex && cd clawdex && ./install.sh
```

`install.sh` runs `swift build -c release`, symlinks the binaries into a writable PATH dir (`/opt/homebrew/bin`, `/usr/local/bin`, or `~/.clawdex/bin` as a fallback), wires the Claude Code hooks into `~/.claude/settings.json` and Codex hooks into an existing Codex home, and starts the daemon via launchd. Idempotent — safe to re-run.

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
Claude Code / Codex CLI event
        │
        ▼
settings.json / hooks.json
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
- **`hooks/clawdex-hook`** — POSIX shell, optional `jq`. Translates Claude Code and Codex hook payloads to one-line JSON events.
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
python3 -m unittest discover -s Tests/HookTests -v  # isolated hook/config tests (requires jq)
swift test           # macOS app tests, including window tests
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
