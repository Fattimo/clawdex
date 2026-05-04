# Launch copy

Drafts for the announcement. Pick whichever lands.

## Twitter / X

**v1 — the dry one (recommended)**

> Anthropic shipped Claude Skills first.
> OpenAI cloned the format and shipped pets.
> So I cloned pets back.
>
> `brew install clawdex` — your Codex pet, but it's actually watching Claude Code work.
>
> github.com/danielkempe/clawdex

**v2 — the demo-first one**

> Claude Code now has pets.
>
> Every existing Codex pet works. `npx petdex install noir-webling` and you're done. The pet reacts to thinking, running tools, waiting for permission, finishing tasks.
>
> [GIF: Noir Webling in the corner, animating through review → running → waving as Claude Code edits a file]
>
> github.com/danielkempe/clawdex

**v3 — the spec-respecting one (for the HN crowd)**

> 200 lines of Swift + 60 lines of bash + the openai/skills hatch-pet atlas spec, verbatim.
>
> Result: every Codex pet now lives in Claude Code, reading from `~/.codex/pets/` directly. No format conversion, no fork, no second install.
>
> github.com/danielkempe/clawdex

## Hacker News title

> clawdex: Codex pets, but for Claude Code

(140 chars max, no emoji, terse — HN penalises hype.)

## Hacker News post body

> Built this over a weekend after noticing that Anthropic shipped Skills, OpenAI cloned the format and added pets, and nobody had cloned the pets back.
>
> Format compatibility is verbatim — the daemon reads pets from `~/.codex/pets/` directly using the openai/skills hatch-pet atlas spec (8x9 grid of 192x208 cells, 9 named animation rows with frame-duration tables). Apache-2.0 components are attributed; the Swift overlay and Claude Code hook bridge are MIT.
>
> State mapping: Claude Code's hook events (`PreToolUse`, `Stop`, `Notification`, etc.) drive the animation rows. Sticky vs transient modes so a long-running Bash holds the "running" row, while a finished task plays "waving" once and returns to idle. Heartbeat ticks via the statusline plugin so a crashed agent falls back to idle instead of frozen.
>
> Demo + code: github.com/danielkempe/clawdex

## Show & tell screenshot caption

> The same Noir Webling pet running in two windows: Codex on the left, clawdex on the right. Same atlas file, both reading from `~/.codex/pets/noir-webling/`.

## Reddit r/MacApps

Title: `[Open Source] clawdex — desktop pets for Claude Code (compatible with all Codex pets)`

Body: same as HN post body, plus a screenshot.
