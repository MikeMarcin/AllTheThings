#!/usr/bin/env python3
"""Validate fixed-cell sprite sheets for gutters, scale, width, and registration."""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

from PIL import Image


@dataclass(frozen=True)
class Animation:
    name: str
    frames: int


@dataclass(frozen=True)
class Bounds:
    min_x: int
    min_y: int
    max_x: int
    max_y: int

    @property
    def width(self) -> int:
        return self.max_x - self.min_x + 1

    @property
    def height(self) -> int:
        return self.max_y - self.min_y + 1

    @property
    def center_x(self) -> float:
        return (self.min_x + self.max_x) / 2


def parse_animations(value: str) -> list[Animation]:
    animations: list[Animation] = []
    for item in value.split(","):
        if not item.strip():
            continue
        try:
            name, frames = item.split(":", 1)
            animations.append(Animation(name.strip(), int(frames)))
        except ValueError as exc:
            raise argparse.ArgumentTypeError(
                f"invalid animation entry {item!r}; expected name:frames"
            ) from exc
    if not animations:
        raise argparse.ArgumentTypeError("at least one animation is required")
    return animations


def parse_range(value: str) -> tuple[float, float]:
    try:
        low, high = value.split(":", 1)
        return float(low), float(high)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(f"invalid range {value!r}; expected min:max") from exc


def alpha_bounds(image: Image.Image, threshold: int) -> Bounds | None:
    alpha = image.getchannel("A")
    bbox = alpha.point(lambda p: 255 if p > threshold else 0).getbbox()
    if bbox is None:
        return None
    min_x, min_y, max_x_exclusive, max_y_exclusive = bbox
    return Bounds(min_x, min_y, max_x_exclusive - 1, max_y_exclusive - 1)


def is_mascot_blue(r: int, g: int, b: int, a: int) -> bool:
    if a <= 8:
        return False
    return (
        b >= 120
        and g >= 80
        and r <= 145
        and b >= r + 25
        and g >= r + 10
    ) or (g >= 145 and b >= 145 and r <= 120)


def connected_bounds(mask: list[bool], width: int, height: int) -> Bounds | None:
    visited = bytearray(width * height)
    best_area = 0
    best_bounds: Bounds | None = None

    for start in range(width * height):
        if visited[start] or not mask[start]:
            visited[start] = 1
            continue

        stack = [start]
        visited[start] = 1
        area = 0
        min_x = max_x = start % width
        min_y = max_y = start // width

        while stack:
            index = stack.pop()
            area += 1
            x = index % width
            y = index // width
            min_x = min(min_x, x)
            max_x = max(max_x, x)
            min_y = min(min_y, y)
            max_y = max(max_y, y)

            for next_y in range(max(0, y - 1), min(height - 1, y + 1) + 1):
                row_offset = next_y * width
                for next_x in range(max(0, x - 1), min(width - 1, x + 1) + 1):
                    if next_x == x and next_y == y:
                        continue
                    next_index = row_offset + next_x
                    if visited[next_index]:
                        continue
                    visited[next_index] = 1
                    if mask[next_index]:
                        stack.append(next_index)

        if area > best_area:
            best_area = area
            best_bounds = Bounds(min_x, min_y, max_x, max_y)

    return best_bounds


def mascot_blue_bounds(image: Image.Image) -> Bounds | None:
    rgba = image.convert("RGBA")
    width, height = rgba.size
    data = rgba.tobytes()
    mask = [
        is_mascot_blue(data[index], data[index + 1], data[index + 2], data[index + 3])
        for index in range(0, len(data), 4)
    ]
    return connected_bounds(mask, width, height)


def median(values: Iterable[float]) -> float:
    sorted_values = sorted(values)
    if not sorted_values:
        raise ValueError("cannot compute median of empty values")
    return sorted_values[len(sorted_values) // 2]


def make_preview(sheet: Image.Image, path: Path, checker_size: int = 16) -> None:
    preview = Image.new("RGBA", sheet.size, (255, 255, 255, 255))
    pixels = preview.load()
    for y in range(preview.height):
        for x in range(preview.width):
            shade = 232 if ((x // checker_size + y // checker_size) % 2 == 0) else 250
            pixels[x, y] = (shade, shade, shade, 255)
    preview.alpha_composite(sheet)
    path.parent.mkdir(parents=True, exist_ok=True)
    preview.save(path)


def format_bounds(bounds: Bounds | None) -> dict[str, float | int] | None:
    if bounds is None:
        return None
    return {
        "minX": bounds.min_x,
        "minY": bounds.min_y,
        "maxX": bounds.max_x,
        "maxY": bounds.max_y,
        "width": bounds.width,
        "height": bounds.height,
        "centerX": bounds.center_x,
    }


def validate(args: argparse.Namespace) -> int:
    sheet = Image.open(args.sheet).convert("RGBA")
    expected_size = (args.columns * args.cell_width, args.rows * args.cell_height)
    issues: list[str] = []
    metrics: dict[str, object] = {
        "sheet": str(args.sheet),
        "size": {"width": sheet.width, "height": sheet.height},
        "expectedSize": {"width": expected_size[0], "height": expected_size[1]},
        "animations": {},
    }

    if sheet.size != expected_size:
        issues.append(f"sheet size is {sheet.size}, expected {expected_size}")

    if len(args.animations) > args.rows:
        issues.append(f"{len(args.animations)} animations exceed configured row count {args.rows}")

    for row, animation in enumerate(args.animations):
        if animation.frames > args.columns:
            issues.append(
                f"{animation.name}: {animation.frames} frames exceed configured columns {args.columns}"
            )

        row_metrics: dict[str, object] = {"frames": []}
        centers: list[float] = []
        widths: list[int] = []
        heights: list[int] = []

        for frame in range(animation.frames):
            x0 = frame * args.cell_width
            y0 = row * args.cell_height
            cell = sheet.crop((x0, y0, x0 + args.cell_width, y0 + args.cell_height))
            visible = alpha_bounds(cell, args.alpha_threshold)
            body = None if args.no_body_check else mascot_blue_bounds(cell)
            row_metrics["frames"].append(
                {
                    "frame": frame,
                    "visible": format_bounds(visible),
                    "body": format_bounds(body),
                }
            )

            if visible is None:
                issues.append(f"{animation.name} frame {frame + 1}: empty active frame")
                continue

            gutters = (
                visible.min_x,
                visible.min_y,
                args.cell_width - 1 - visible.max_x,
                args.cell_height - 1 - visible.max_y,
            )
            if min(gutters) < args.min_gutter:
                issues.append(
                    f"{animation.name} frame {frame + 1}: gutter {gutters} below {args.min_gutter}"
                )

            if not args.no_body_check:
                if body is None:
                    issues.append(f"{animation.name} frame {frame + 1}: mascot body not detected")
                    continue
                centers.append(body.center_x)
                widths.append(body.width)
                heights.append(body.height)

                if not (args.body_width_range[0] <= body.width <= args.body_width_range[1]):
                    issues.append(
                        f"{animation.name} frame {frame + 1}: body width {body.width} "
                        f"outside {args.body_width_range}"
                    )
                if not (args.body_height_range[0] <= body.height <= args.body_height_range[1]):
                    issues.append(
                        f"{animation.name} frame {frame + 1}: body height {body.height} "
                        f"outside {args.body_height_range}"
                    )
                if not (args.body_center_range[0] <= body.center_x <= args.body_center_range[1]):
                    issues.append(
                        f"{animation.name} frame {frame + 1}: body center {body.center_x:.1f} "
                        f"outside {args.body_center_range}"
                    )

        if centers:
            drift = max(centers) - min(centers)
            row_metrics["bodySummary"] = {
                "centerMin": min(centers),
                "centerMax": max(centers),
                "centerDrift": drift,
                "medianWidth": median(widths),
                "medianHeight": median(heights),
            }
            if drift > args.max_center_drift:
                issues.append(
                    f"{animation.name}: body center drift {drift:.1f} exceeds {args.max_center_drift}"
                )

        metrics["animations"][animation.name] = row_metrics

    if args.preview:
        make_preview(sheet, args.preview)
        metrics["preview"] = str(args.preview)

    if args.json:
        print(json.dumps({"ok": not issues, "issues": issues, "metrics": metrics}, indent=2))
    else:
        if issues:
            print("Sprite sheet validation failed:", file=sys.stderr)
            for issue in issues:
                print(f"- {issue}", file=sys.stderr)
        else:
            print("Sprite sheet validation passed.")
        if args.preview:
            print(f"Preview: {args.preview}")

    return 1 if issues else 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sheet", type=Path, required=True)
    parser.add_argument("--cell-width", type=int, required=True)
    parser.add_argument("--cell-height", type=int, required=True)
    parser.add_argument("--columns", type=int, required=True)
    parser.add_argument("--rows", type=int, required=True)
    parser.add_argument("--animations", type=parse_animations, required=True)
    parser.add_argument("--alpha-threshold", type=int, default=8)
    parser.add_argument("--min-gutter", type=int, default=1)
    parser.add_argument("--body-color", choices=["mascot-blue"], default="mascot-blue")
    parser.add_argument("--body-width-range", type=parse_range, default=(69.0, 78.0))
    parser.add_argument("--body-height-range", type=parse_range, default=(78.0, 90.0))
    parser.add_argument("--body-center-range", type=parse_range, default=(79.0, 84.0))
    parser.add_argument("--max-center-drift", type=float, default=3.0)
    parser.add_argument("--no-body-check", action="store_true")
    parser.add_argument("--preview", type=Path)
    parser.add_argument("--json", action="store_true")
    return parser


def main() -> int:
    return validate(build_parser().parse_args())


if __name__ == "__main__":
    raise SystemExit(main())
