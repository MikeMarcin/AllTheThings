---
name: sprite-sheet-animation-updater
description: Generate, update, integrate, and validate fixed-cell sprite-sheet animations for app/game mascots. Use when Codex is asked to create new sprite animation rows, replace or repair existing sprite-sheet animations, preserve a character's model/identity across frames, assemble a master sprite sheet, add standalone animation strips, or add regression tests for sprite dimensions, transparent gutters, body scale, width, baseline, or horizontal registration.
---

# Sprite Sheet Animation Updater

Use this workflow for fixed-cell mascot sprite sheets where visual consistency matters as much as frame count. Preserve the approved character model first; effects and props are secondary.

## Core Workflow

1. **Identify the model reference.** Use the cleanest approved frame or row as the character model. Do not average across generated rows if some are off model.
2. **Record the runtime layout.** Capture cell size, row order, frame counts, padded columns, sheet dimensions, and resource name used by app code.
3. **Generate or edit one row at a time.** If using image generation, prompt for the exact frame count, a single horizontal row, fixed cell size, consistent baseline/scale, and no text/borders/background scene.
4. **Post-process deterministically.** Remove background, crop/pad into fixed cells, and keep transparent gutters. Never let confetti, papers, gears, or other props determine mascot body scale.
5. **Check model metrics before integrating.** Validate active frames for nonempty alpha, gutters, body height, body width, and body center registration. For Nib-style blue mascot sheets, use `scripts/validate_sprite_sheet.py`.
6. **Integrate the asset.** Update app resource references, bundle scripts, animation metadata, and tests together. Remove obsolete sheet assets only after references are gone.
7. **Run regression tests and build.** Run the validator, the project tests, and the app/resource build path that copies the sheet into the bundle.

## Rules To Preserve Character Model

- Anchor scale and width to the mascot body, not total visible pixels. Props/effects can be wider or taller than the body.
- Keep the mascot body horizontally registered across every active frame in every row unless the animation explicitly includes body travel.
- Keep baseline stable across rows. Hop/bounce rows may move vertically, but should return to the baseline and remain inside the cell.
- If generated frames drift off model, prefer body-locking/compositing from an approved idle/reference body over manual per-pixel patches.
- For prop-heavy rows, verify the prop motion separately from mascot body registration. The magnifying glass can move; the mascot body should not slide unless intended.
- Use transparent PNGs for runtime assets. Checkerboard previews are for inspection only and must not be referenced by app code.
- Do not rely only on visual-frame width/height; those include props and can hide a narrow or drifting mascot body.

## Idle Clip Pattern

When an idle system has a base loop, subtle fidgets, and rare flourishes, prefer a single weighted selection table rolled at the end of each base idle loop. Keep the base loop heavily weighted, fidgets light, and flourishes rare. Avoid separate random timers for each idle class unless the product explicitly needs wall-clock scheduling; timers can overlap and make the behavior harder to reason about.

For standalone idle strips:

- Use the same fixed-cell contract as master-sheet rows; name and bundle each strip explicitly.
- Body-lock fidgets by compositing from the approved neutral body, then move only the intended parts or props. For example, an antenna wiggle should redraw only antennae; the body, feet, eyes, and baseline stay fixed.
- Do not reuse generated row frames for body-locked fidgets without measuring them. Even a 1-2 px body or foot shift reads as an unintended hop.
- For blink fidgets, keep the foot baseline identical between open-eye and closed-eye frames. Closing eyes should not lift the body.
- For rare flourishes, keep body travel intentional and documented. A victory bounce may move vertically; a file/sparkle flourish should keep the body registered while only props/effects move.

Add project tests for standalone strips, not just the master sheet:

- dimensions equal `cellWidth * frameCount` by `cellHeight`
- transparent gutters remain clear on every frame
- mascot body width and horizontal center stay in range
- body center and foot baseline are exact or near-exact for body-locked fidgets
- baseline drift is allowed only for clips that intentionally bounce or travel

## Validator

Run the bundled validator from the repo skill directory:

```bash
python3 .codex/skills/sprite-sheet-animation-updater/scripts/validate_sprite_sheet.py \
  --sheet Resources/NibGeneratedMasterSheet.png \
  --cell-width 160 \
  --cell-height 96 \
  --columns 10 \
  --rows 7 \
  --animations idle:8,indexing:10,searching:10,optimizing:10,file_changed:6,success:8,error:6 \
  --body-color mascot-blue \
  --min-gutter 1 \
  --body-width-range 69:78 \
  --body-height-range 78:90 \
  --body-center-range 79:84 \
  --max-center-drift 3 \
  --preview /tmp/sprite-sheet-preview.png
```

Use `--no-body-check` for non-blue characters or when a sheet does not have a detectable mascot-color component. In that case, add a project-specific test or script for the character model before shipping.

The validator checks:

- sheet dimensions equal `columns * cellWidth` by `rows * cellHeight`
- active frames are nonempty
- active frames keep transparent gutters
- optional mascot-blue body component width and height stay within bounds
- optional mascot-blue body center stays within bounds and has limited per-row drift
- inactive padded cells are allowed to be empty

## AllTheThings / Nib Defaults

For this repository's Nib mascot, use:

- runtime asset: `Resources/NibGeneratedMasterSheet.png`
- sheet size: `1600 x 672`
- cell size: `160 x 96`
- columns: `10`
- rows/frame counts:
  - `idle`: row 0, 8 frames, loops
  - `indexing`: row 1, 10 frames, loops
  - `searching`: row 2, 10 frames, loops
  - `optimizing`: row 3, 10 frames, loops
  - `file_changed`: row 4, 6 frames, one-shot
  - `success`: row 5, 8 frames, one-shot
  - `error`: row 6, 6 frames, one-shot

After changing the sheet in AllTheThings, run:

```bash
.codex/skills/sprite-sheet-animation-updater/scripts/validate_allthethings_nib.sh .
```

Also keep or update Swift regression tests that check sprite metadata, slicing, transparent gutters, body height, body width, and horizontal body registration.
