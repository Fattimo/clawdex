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
3. Run `clawdex wake`. In kitty, interactive clients register automatically before their first prompt; other terminals register through hooks.

Codex sessions get their own switchboard pill, bubble, and accent color, keeping Claude and Codex in the same repo distinct. Labels use the bare project name; side and color identify the agent. Shell commands animate as work, `apply_patch` narrates editing, and `update_plan` shows reviewing. Interrupting a turn returns the pet to idle and lights the pill; closing the CLI removes its pill. Clicking a CLI pill returns to its launching terminal or editor; kitty can focus the exact tab when remote control is configured. Other terminals are brought to the front. Desktop Codex sessions retain their thread deep links.

Claude Code switches stay on the dog's left in warm colors; Codex switches stay
on the right in cool colors. Bubbles and kitty tabs share each session's accent.
Idle Codex startup and a current-turn Stop light the switch; prompt/tool activity
and structured turn starts dim it. Structured completion records also confirm
readiness; quoted interruption markers in tool output never count as completion.
Session and turn IDs prevent stale terminal events from
changing a newer turn. Internal worktrees stay attached to their original
client's switchboard entry and kitty tab.
Internal Codex agents identified by their rollout metadata cannot change the
foreground session's readiness or animation. Hooks without a transcript from a
different session also cannot take over a busy switch.

Clearing a session (`SessionStart` with source `clear`) keeps a neutral
switchboard entry and kitty tab with an accent dot. Prompt/tool activity returns
it to working; completion lights it again. Late completion hooks cannot light a
freshly cleared session.
Ending a thread alone does not imply clear; exiting the CLI removes its entry
through presence detection. An explicit resume can reactivate the same thread
after a clear and reloads its saved ready/busy state.
Some Codex clears emit no hook until the next prompt. Kitty presence checks
also recognize the exact empty Codex welcome screen, including its project
directory, and neutralize both indicators within the next poll. Newer hook
activity invalidates an older screen sample; retired thread events stay ignored.
For a CLI resumed with an explicit thread ID, readiness follows that thread.
Background forks sharing its repository cannot dim its completed turn; a fork
explicitly resumed in its own client still works normally.

The pet's settings include **Mouse trail in kitty** (off by default). It draws
a short, tapered gradient trail in a transparent, click-through floating layer
over the foreground kitty window. It follows mouse positions without capturing
clicks or keystrokes, and disappears outside kitty or when the pointer stops.

Verify events with `tail -f ~/.clawdex/hook-trail.log` — look for `"agent":"codex"`. If nothing arrives, check `/hooks` for disabled or untrusted hooks and ensure hooks are enabled in your Codex configuration. The shared hook script uses `jq` for structured payload parsing when available, with a basic shell parser as a fallback.

For kitty, enable `allow_remote_control socket-only` and `listen_on unix:${TMPDIR}/kitty` in `kitty.conf`, then restart kitty if these settings are new. Clawdex mirrors readiness onto the session's tab with a `●`/`○` marker and accent color. A local presence check every three seconds registers idle/new/resumed clients without a prompt and removes exited clients. It preserves hook readiness and manually dismissed entries. Codex can share a server across CLI clients, so its hook's inherited window ID may belong to another tab. Clawdex uses kitty's foreground client process, project root, and observed process identity to focus and color the actual tab. If multiple clients in the same project cannot be distinguished, it leaves their tabs unchanged. Failed updates retry on the next presence check or hook.

The author's kitty setup (vertical tab bar that reads these markers, shaders) is versioned in `kitty/`. Run `kitty/sync.sh` to diff it against `~/.config/kitty`, `kitty/sync.sh push` to install it, or `kitty/sync.sh pull` to bring live edits back. Restart kitty after changing `tab_bar.py`.

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

## GitHub PR scorebug

Clawdex can watch your PR chains in a compact scorebug below the dog. It
discovers your open PRs by repository and groups branches whose base points to
another PR's head. Cached chain membership survives parent merges and GitHub
retargeting. Single PRs get their own entry; explicit chains can also be named.
The scorebug uses one opaque neutral card, 38 points tall, with a vertically
centered status dot on the left: green when the displayed PR is ready, yellow
while checks or review are pending, red for failed checks or blocked merging,
and gray for drafts and unknown states. Failed CI takes priority over drafts.
Its first row gives the displayed PR's number and title the full width.
The subtitle shows time since its last update and the date it opened, with
stack position and a numeric review conversation count plus comment icon on
the right.
Unavailable review counts show a dash rather than zero. Each recent open PR
gets its own ticker entry, retaining its position within the full tracked stack.
It sits 4 points below the dog and spans the dog
and both session columns. Claude Code switches stack on the left and Codex on the right,
each as wide as the dog; the latest chat update appears centered above it.
The ticker shows up to four open PRs updated between now and three business
days ago (Monday–Friday, at the same local time of day). An absent update date
falls back to the creation date; unknown dates are excluded. It rotates every
eight seconds and pauses while hovered. A bottom border has one equal-width
segment per PR, colored by its state; the currently displayed PR's segment is
taller. Cached entries age out locally without extra GitHub requests. All PRs
remain tracked. Click to open the displayed PR directly at GitHub's merge
section. Hover for the full status; hide and refresh remain available through
the CLI. The companion stays within the
screen edges when dragged or resized. Scorebug visibility is independent in Settings.

Install `gh` and sign in with `gh auth login`. GitHub tracking polls directly
through `gh` every two minutes; no ngrok, public endpoint or hosted backend is
needed. Startup, wake and manual Refresh also fetch current state. Refreshes
are serialized, and polling stops while this Mac sleeps or tracking is disabled.
Updates may take up to two minutes plus the API fetch time to appear.

```bash
clawdex github setup owner/repo
clawdex github status
```

Existing configurations also switch to polling. Clawdex deactivates only the
repository webhook IDs recorded by this installation, retaining their definitions
for optional reuse. A failed deactivation is shown by `github status` and retried
on subsequent refreshes. GitHub credentials remain in `gh`. Polling uses your
account's shared GitHub API quota; it creates no ngrok requests.

For optional instant webhook updates, install and authenticate `ngrok`, then run:

```bash
clawdex github setup owner/repo --webhooks
# Optionally add --url https://your-ngrok-domain or --auto-url.
# Once ngrok connects:
clawdex github hook owner/repo
```

Webhook mode requires repository webhook administration permission and uses
ngrok's standard local auth configuration. The daemon supervises the tunnel,
updates only its owned hook on reconnect, and stops the receiver before sleep.
The local receiver binds to `127.0.0.1:47839`, validates HMAC-SHA256 signatures,
rejects oversized/ambiguous requests and deduplicates deliveries. Signing secrets
stay in `~/.clawdex/github/config.json` with owner-only permissions. Incoming
payloads invalidate data; GitHub API results determine readiness. Repository-wide
webhook traffic can exhaust ngrok's free request allowance on busy repositories.
Run setup again without `--webhooks` to return to polling.

```bash
clawdex github refresh
clawdex github track 'billing' https://github.com/owner/repo/pull/123 https://github.com/owner/repo/pull/124
clawdex github hide 'owner/repo#123'  # IDs are listed by github status
clawdex github show 'owner/repo#123'
clawdex github disable
```

Manual stack PR URLs must be from the same repository, in base-to-tip order.
“Ready” requires every remaining PR to have completed checks, no required
review outstanding and a clean GitHub merge state. Passing checks alone does
not make a blocked PR ready. In webhook mode, disconnected receivers and missing setup display offline status.
Incomplete data and failed API refreshes display offline/unknown status rather
than a green pill. After the entire chain merges, its pill disappears and its
history remains cached. This version opens PRs in GitHub; it does not merge them.

Core tests (no pet/window tests):

```bash
swift test --jobs 2 --filter GitHubTests
```

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
