#!/usr/bin/env bash
set -euo pipefail

repo_root="${1:-$(pwd)}"

cd "${repo_root}"

python3 - <<'PY'
from __future__ import annotations

from collections import deque
from pathlib import Path

from PIL import Image

CELL_WIDTH = 160
CELL_HEIGHT = 96
MIN_GUTTER = 1
STRIPS = {
    "NibOperationIdleStrip.png": 8,
    "NibOperationIndexingStrip.png": 16,
    "NibOperationSearchingStrip.png": 16,
    "NibOperationSearchRefiningStrip.png": 16,
    "NibOperationOptimizingStrip.png": 16,
    "NibOperationFileChangedStrip.png": 6,
    "NibOperationSuccessStrip.png": 8,
    "NibOperationErrorStrip.png": 6,
    "NibIdleMainLoopStrip.png": 8,
    "NibIdleBlinkFidgetStrip.png": 8,
    "NibIdleAntennaFidgetStrip.png": 8,
    "NibIdleFileFinderSparkStrip.png": 10,
    "NibIdleVictoryBounceStrip.png": 10,
    "NibIntroWelcomeStrip.png": 32,
    "NibFlydownStrip.png": 10,
}


def is_mascot_blue(pixel: tuple[int, int, int, int]) -> bool:
    red, green, blue, alpha = pixel
    if alpha < 20:
        return False
    return blue >= 135 and green >= 100 and red <= 125 and blue - red >= 35


def visible_bounds(image: Image.Image, frame: int) -> tuple[int, int, int, int] | None:
    min_x = CELL_WIDTH
    min_y = CELL_HEIGHT
    max_x = -1
    max_y = -1
    x_offset = frame * CELL_WIDTH
    pixels = image.load()

    for y in range(CELL_HEIGHT):
        for x in range(CELL_WIDTH):
            if pixels[x_offset + x, y][3] <= 7:
                continue
            min_x = min(min_x, x)
            min_y = min(min_y, y)
            max_x = max(max_x, x)
            max_y = max(max_y, y)

    if max_x < min_x or max_y < min_y:
        return None
    return min_x, min_y, max_x, max_y


def largest_blue_bounds(image: Image.Image, frame: int) -> tuple[int, int, int, int] | None:
    x_offset = frame * CELL_WIDTH
    pixels = image.load()
    seen: set[tuple[int, int]] = set()
    largest: list[tuple[int, int]] = []

    for y in range(CELL_HEIGHT):
        for x in range(CELL_WIDTH):
            if (x, y) in seen or not is_mascot_blue(pixels[x_offset + x, y]):
                continue

            component: list[tuple[int, int]] = []
            queue = deque([(x, y)])
            seen.add((x, y))

            while queue:
                current_x, current_y = queue.popleft()
                component.append((current_x, current_y))
                for next_x, next_y in (
                    (current_x - 1, current_y),
                    (current_x + 1, current_y),
                    (current_x, current_y - 1),
                    (current_x, current_y + 1),
                ):
                    if (
                        next_x < 0
                        or next_x >= CELL_WIDTH
                        or next_y < 0
                        or next_y >= CELL_HEIGHT
                        or (next_x, next_y) in seen
                        or not is_mascot_blue(pixels[x_offset + next_x, next_y])
                    ):
                        continue
                    seen.add((next_x, next_y))
                    queue.append((next_x, next_y))

            if len(component) > len(largest):
                largest = component

    if not largest:
        return None

    xs = [point[0] for point in largest]
    ys = [point[1] for point in largest]
    return min(xs), min(ys), max(xs), max(ys)


errors: list[str] = []
for filename, frame_count in STRIPS.items():
    path = Path("Resources") / filename
    if not path.exists():
        errors.append(f"{filename}: missing")
        continue

    image = Image.open(path).convert("RGBA")
    expected_size = (CELL_WIDTH * frame_count, CELL_HEIGHT)
    if image.size != expected_size:
        errors.append(f"{filename}: expected {expected_size}, found {image.size}")
        continue

    body_centers: list[float] = []
    body_widths: list[int] = []
    for frame in range(frame_count):
        bounds = visible_bounds(image, frame)
        if bounds is None:
            errors.append(f"{filename} frame {frame}: empty")
            continue

        min_x, min_y, max_x, max_y = bounds
        if min_x < MIN_GUTTER or min_y < MIN_GUTTER or max_x > CELL_WIDTH - 1 - MIN_GUTTER or max_y > CELL_HEIGHT - 1 - MIN_GUTTER:
            errors.append(f"{filename} frame {frame}: visible pixels touch gutter {bounds}")

        blue_bounds = largest_blue_bounds(image, frame)
        if blue_bounds is None:
            errors.append(f"{filename} frame {frame}: no mascot-blue body component")
            continue

        blue_min_x, _, blue_max_x, _ = blue_bounds
        body_centers.append((blue_min_x + blue_max_x) / 2)
        body_widths.append(blue_max_x - blue_min_x + 1)

    if body_widths:
        median_width = sorted(body_widths)[len(body_widths) // 2]
        if median_width < 69 or median_width > 78:
            errors.append(f"{filename}: median mascot body width {median_width} outside 69...78")
    if body_centers:
        min_center = min(body_centers)
        max_center = max(body_centers)
        if min_center < 79 or max_center > 84 or max_center - min_center > 3:
            errors.append(f"{filename}: mascot body center range {min_center:.1f}...{max_center:.1f} outside expected registration")

if errors:
    for error in errors:
        print(error)
    raise SystemExit(1)

print(f"Validated {len(STRIPS)} Nib animation strips.")
PY

swift test
cmake --build build/cmake
