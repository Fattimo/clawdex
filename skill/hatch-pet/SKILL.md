---
name: hatch-pet
description: Hatch a Codex-format animated pet from a concept, image, or hand-drawn sprite atlas, then install it for clawdex (the Claude Code companion overlay) and Codex. Use when a user wants to "hatch a pet", "make a Claude Code pet", "create a clawdex pet", or convert an existing 8x9 sprite sheet into a `pet.json` package. The skill produces a `pet.json` + `spritesheet.webp` pair under `~/.codex/pets/<name>/` (compatible with both clawdex and Codex). Image generation is delegated to whatever the user has on hand — Claude's web tools, MidJourney, hand drawing, or a pre-made atlas.
---

# Hatch Pet (clawdex edition)

Build a [Codex-format](https://github.com/openai/skills/blob/main/skills/.curated/hatch-pet/references/codex-pet-contract.md) animated pet that works in **both** clawdex and the Codex desktop app. Same atlas, same `pet.json`, same install path — drop-in compatible.

## What we're producing

A folder under `~/.codex/pets/<pet-name>/` containing exactly two files:

```
~/.codex/pets/<pet-name>/
├── pet.json
└── spritesheet.webp
```

`pet.json` shape:

```json
{
  "id": "pet-name",
  "displayName": "Pet Name",
  "description": "One short sentence.",
  "spritesheetPath": "spritesheet.webp"
}
```

Spritesheet: PNG or WebP, **1536×1872**, transparent background, 8 columns × 9 rows of 192×208 cells. Unused cells (after the last used frame in each row) must be fully transparent.

## The nine animation rows

Source: [openai/skills `animation-rows.md`](https://github.com/openai/skills/blob/main/skills/.curated/hatch-pet/references/animation-rows.md). The Codex app and clawdex both read this exact layout — **do not deviate**.

| Row | State          | Cols used | Frame durations (ms)                |
| --- | -------------- | --------- | ----------------------------------- |
|  0  | idle           | 0–5       | 280, 110, 110, 140, 140, 320        |
|  1  | running-right  | 0–7       | 120 ×7, final 220                   |
|  2  | running-left   | 0–7       | 120 ×7, final 220                   |
|  3  | waving         | 0–3       | 140 ×3, final 280                   |
|  4  | jumping        | 0–4       | 140 ×4, final 280                   |
|  5  | failed         | 0–7       | 140 ×7, final 240                   |
|  6  | waiting        | 0–5       | 150 ×5, final 260                   |
|  7  | running        | 0–5       | 120 ×5, final 220                   |
|  8  | review         | 0–5       | 150 ×5, final 280                   |

What each row should depict (terse — see upstream contract for full guidance):

- **idle**: neutral breathing/blinking loop. Used as the reduced-motion poster frame.
- **running-right** / **running-left**: locomotion, 8-frame loop, directional. Don't auto-mirror unless the design is symmetric.
- **waving**: greeting gesture — clear start, raised paw, return.
- **jumping**: anticipation, lift, peak, descent, settle.
- **failed**: sad/deflated — readable but not noisy.
- **waiting**: patient idle variant — glance, small bounce, prop motion.
- **running**: generic in-place run loop (front-facing).
- **review**: focused/inspecting/thinking loop.

## Style guidance

Match the Codex built-in pet aesthetic: small chibi proportions, chunky readable silhouettes, thick 1–2 px outlines, limited palette, flat cel shading, simple expressive faces. Avoid: polished illustration, painterly rendering, 3D, glossy app-icon treatment, soft gradients, antialiased detail.

**Effects rules** (these protect transparency cleanup):

- No detached effects: speed lines, motion arcs, cast shadows, floating sparkles, dust clouds, drop shadows, halos, glow. Anything that doesn't physically touch the pet sprite is forbidden.
- Allowed only if attached to the silhouette: tear on the face, smoke puff touching the head, stars overlapping the pet during `failed`.
- No wave marks around `waving`. No floor shadow under `jumping`. No magnifying glass / paper / code under `review` unless that prop is part of the pet's base identity.
- Unused cells must be fully transparent. No background colour, no checkerboard, no chroma-key residue.

## Workflow

### 1. Choose a concept

If the user gave one, use it. If not, ask once — keep it short. Good built-in style examples: `Codex` (the original), `Dewey` (a tidy duck), `Noir Webling` (a noir-detective spider). Names should be 1–2 words, lowercase-slug-friendly.

### 2. Generate the base pet image

Generate a single front-facing portrait in the Codex chibi style. This becomes the canonical reference for every row. Use whatever image-gen tool the user has — Claude (via the API or Web Fetch), MidJourney, DALL-E, hand-drawn pixel art. The skill is intentionally backend-agnostic.

Prompt template:

```
A small chibi pixel-art-adjacent mascot, [concept]. Compact proportions,
chunky silhouette, thick 1-2 px dark outline, limited palette, flat cel
shading, simple expressive face, tiny limbs. Transparent background.
Front-facing portrait, single character, no effects, no shadow, no text.
```

### 3. Generate the nine row strips

For each row, produce a horizontal strip at exactly **(192 × cols-used) × 208** showing the frames in sequence. Pass the base image as a reference so identity stays consistent.

Per-row prompt suffixes (append to the base prompt, replacing `[concept]`):

```
row 0 idle:           neutral breathing/blinking, 6 frames, in-place
row 1 running-right:  running rightward, 8-frame cycle, directional
row 2 running-left:   running leftward, 8-frame cycle, mirrored or redrawn
row 3 waving:         waving paw, 4 frames: rest, raise, hold, return
row 4 jumping:        jump, 5 frames: anticipate, lift, peak, descend, land
row 5 failed:         deflated/sad reaction, 8 frames
row 6 waiting:        patient idle, 6 frames, small glance or prop motion
row 7 running:        in-place run loop, 6 frames, front-facing
row 8 review:         focused inspect/think loop, 6 frames, lean and blink
```

### 4. Compose the atlas

Paste each row strip into a 1536×1872 transparent canvas at row offset `(0, row_index × 208)`. Pad unused trailing cells with transparency. Save as `spritesheet.webp` (or `.png`).

### 5. Validate

Run the bundled validator:

```bash
python3 validate_atlas.py path/to/spritesheet.webp
```

It checks: dimensions, alpha channel, used-cell content, unused-cell transparency, and warns on near-opaque cells (a sign of leftover background). Exit 0 = ship it.

### 6. Package

Write `pet.json` next to the spritesheet, then move both into `~/.codex/pets/<pet-name>/`:

```bash
mkdir -p ~/.codex/pets/<pet-name>
cp spritesheet.webp pet.json ~/.codex/pets/<pet-name>/
```

That's it. clawdex (if running) will pick it up on its next pet-list refresh, and Codex will show it in Settings → Appearance → Pets.

## Notes & attribution

The atlas spec, animation row schedule, validation logic, and effect-cleanup guidance are all from [openai/skills `hatch-pet`](https://github.com/openai/skills/tree/main/skills/.curated/hatch-pet) (Apache 2.0). This skill is a Claude-Code-flavored adaptation: image generation is delegated to whichever tool the user has (rather than a Codex-internal `$imagegen`), and the SKILL.md is rewritten for the Claude Code triggering style.

`validate_atlas.py` is a verbatim copy of the upstream script. See [LICENSE](./LICENSE) and [NOTICE](./NOTICE).
