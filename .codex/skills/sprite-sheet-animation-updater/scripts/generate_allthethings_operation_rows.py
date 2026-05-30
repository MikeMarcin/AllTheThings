#!/usr/bin/env python3
"""Regenerate AllTheThings Nib operation animation rows.

This script keeps Nib's approved idle/fidget bodies on model and redraws the
indexing/optimizing props as longer, smoother loops inside the fixed cell grid.
"""

from __future__ import annotations

import argparse
from math import cos, pi, sin
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter


CELL_WIDTH = 160
CELL_HEIGHT = 96
ROWS = {
    "indexing": 1,
    "optimizing": 3,
}
SCALE = 4


def load_strip(path: Path) -> list[Image.Image]:
    image = Image.open(path).convert("RGBA")
    return [
        image.crop((index * CELL_WIDTH, 0, (index + 1) * CELL_WIDTH, CELL_HEIGHT))
        for index in range(image.width // CELL_WIDTH)
    ]


def smoothstep(value: float) -> float:
    value = max(0.0, min(1.0, value))
    return value * value * (3 - 2 * value)


def paste_alpha(destination: Image.Image, source: Image.Image, xy: tuple[int, int], alpha_scale: float = 1.0) -> None:
    if alpha_scale < 0.999:
        source = source.copy()
        alpha = source.getchannel("A").point(lambda pixel: int(pixel * alpha_scale))
        source.putalpha(alpha)
    destination.alpha_composite(source, xy)


def draw_shadowed_document(size: tuple[int, int] = (18, 23), angle: float = 0, alpha: float = 1.0) -> Image.Image:
    width, height = size
    pad = 8
    image = Image.new("RGBA", ((width + pad * 2) * SCALE, (height + pad * 2) * SCALE), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    x0 = pad * SCALE
    y0 = pad * SCALE
    x1 = (pad + width) * SCALE
    y1 = (pad + height) * SCALE
    radius = 2 * SCALE

    shadow = Image.new("RGBA", image.size, (0, 0, 0, 0))
    shadow_draw = ImageDraw.Draw(shadow)
    shadow_draw.rounded_rectangle(
        [x0 + 2 * SCALE, y0 + 2 * SCALE, x1 + 2 * SCALE, y1 + 2 * SCALE],
        radius=radius,
        fill=(0, 0, 0, 78),
    )
    image.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(1.2 * SCALE)))

    draw.rounded_rectangle(
        [x0, y0, x1, y1],
        radius=radius,
        fill=(247, 249, 252, 255),
        outline=(205, 208, 212, 255),
        width=SCALE,
    )
    fold = 5 * SCALE
    draw.polygon(
        [(x1 - fold, y0), (x1, y0), (x1, y0 + fold)],
        fill=(232, 233, 235, 255),
        outline=(198, 200, 202, 255),
    )
    for index, line_width in enumerate((10, 12, 8)):
        y = y0 + (8 + index * 4) * SCALE
        draw.rounded_rectangle(
            [x0 + 4 * SCALE, y, x0 + (4 + line_width) * SCALE, y + SCALE],
            radius=max(1, SCALE // 2),
            fill=(156, 158, 161, 210),
        )

    image = image.resize((width + pad * 2, height + pad * 2), Image.Resampling.LANCZOS)
    image = image.rotate(angle, resample=Image.Resampling.BICUBIC, expand=True)
    if alpha < 0.999:
        image.putalpha(image.getchannel("A").point(lambda pixel: int(pixel * alpha)))
    return image


def draw_folder(size: tuple[int, int] = (25, 18), angle: float = 0, alpha: float = 1.0) -> Image.Image:
    width, height = size
    pad = 8
    image = Image.new("RGBA", ((width + pad * 2) * SCALE, (height + pad * 2) * SCALE), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    x0 = pad * SCALE
    y0 = pad * SCALE
    x1 = (pad + width) * SCALE
    y1 = (pad + height) * SCALE
    tab_width = 10 * SCALE
    tab_height = 5 * SCALE

    shadow = Image.new("RGBA", image.size, (0, 0, 0, 0))
    shadow_draw = ImageDraw.Draw(shadow)
    shadow_draw.rounded_rectangle(
        [x0 + 2 * SCALE, y0 + 4 * SCALE, x1 + 2 * SCALE, y1 + 2 * SCALE],
        radius=3 * SCALE,
        fill=(0, 0, 0, 70),
    )
    image.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(1.2 * SCALE)))

    draw.rounded_rectangle(
        [x0, y0 + 3 * SCALE, x1, y1],
        radius=3 * SCALE,
        fill=(255, 196, 83, 255),
        outline=(195, 132, 42, 240),
        width=SCALE,
    )
    draw.rounded_rectangle(
        [x0 + 3 * SCALE, y0, x0 + tab_width, y0 + tab_height],
        radius=2 * SCALE,
        fill=(255, 214, 116, 255),
        outline=(195, 132, 42, 220),
        width=SCALE,
    )
    draw.rounded_rectangle(
        [x0 + 2 * SCALE, y0 + 7 * SCALE, x1 - 2 * SCALE, y1 - 2 * SCALE],
        radius=2 * SCALE,
        fill=(255, 220, 124, 170),
    )

    image = image.resize((width + pad * 2, height + pad * 2), Image.Resampling.LANCZOS)
    image = image.rotate(angle, resample=Image.Resampling.BICUBIC, expand=True)
    if alpha < 0.999:
        image.putalpha(image.getchannel("A").point(lambda pixel: int(pixel * alpha)))
    return image


def draw_antenna_glow(canvas: Image.Image, strength: float) -> None:
    if strength <= 0.04:
        return
    draw = ImageDraw.Draw(canvas)
    for cx, cy in ((61, 11), (93, 11)):
        for ring, alpha_scale in ((6, 0.42), (10, 0.18)):
            alpha = int(180 * strength * alpha_scale)
            color = (235, 248, 255, alpha)
            draw.ellipse([cx - ring, cy - ring, cx + ring, cy + ring], outline=color, width=2)


def draw_motion_lines(canvas: Image.Image, side: str, strength: float) -> None:
    if strength <= 0.04:
        return
    draw = ImageDraw.Draw(canvas)
    alpha = int(130 * strength)
    color = (210, 235, 247, alpha)
    if side == "left":
        arcs = [((33, 38, 43, 65), 110, 245), ((28, 43, 37, 61), 105, 235)]
    else:
        arcs = [((118, 38, 128, 65), -65, 65), ((124, 43, 133, 61), -55, 55)]
    for box, start, end in arcs:
        draw.arc(box, start=start, end=end, fill=color, width=2)


def draw_mitten(canvas: Image.Image, center: tuple[int, int], angle: float = 0, alpha: float = 1.0) -> None:
    size = 18
    image = Image.new("RGBA", (size * SCALE, size * SCALE), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    draw.ellipse(
        [3 * SCALE, 4 * SCALE, 13 * SCALE, 14 * SCALE],
        fill=(225, 245, 255, int(245 * alpha)),
        outline=(172, 184, 194, int(210 * alpha)),
        width=SCALE,
    )
    draw.ellipse(
        [9 * SCALE, 9 * SCALE, 16 * SCALE, 15 * SCALE],
        fill=(213, 239, 252, int(235 * alpha)),
        outline=(172, 184, 194, int(190 * alpha)),
        width=max(1, SCALE // 2),
    )
    image = image.resize((size, size), Image.Resampling.LANCZOS)
    image = image.rotate(angle, resample=Image.Resampling.BICUBIC, expand=True)
    paste_alpha(canvas, image, (int(center[0] - image.width / 2), int(center[1] - image.height / 2)))


def draw_mouth(canvas: Image.Image, center: tuple[int, int], smile: float = 1.0, alpha: float = 1.0) -> None:
    draw = ImageDraw.Draw(canvas)
    cx, cy = center
    if smile >= 0:
        draw.arc(
            [cx - 5, cy - 3, cx + 5, cy + 6],
            start=20,
            end=160,
            fill=(74, 42, 52, int(230 * alpha)),
            width=2,
        )
        if smile > 0.6:
            draw.ellipse([cx - 2, cy + 2, cx + 2, cy + 5], fill=(224, 61, 70, int(215 * alpha)))
    else:
        draw.arc(
            [cx - 5, cy + 1, cx + 5, cy + 8],
            start=200,
            end=340,
            fill=(74, 42, 52, int(220 * alpha)),
            width=2,
        )


def draw_cheeks(canvas: Image.Image, strength: float) -> None:
    if strength <= 0.05:
        return
    draw = ImageDraw.Draw(canvas)
    fill = (255, 139, 153, int(90 * strength))
    draw.ellipse([58, 62, 66, 67], fill=fill)
    draw.ellipse([95, 62, 103, 67], fill=fill)


def operation_body_frames(strips: dict[str, list[Image.Image]], operation: str, frame_index: int) -> tuple[Image.Image, tuple[int, int]]:
    antenna_cycle = [0, 1, 3, 5, 6, 7, 6, 5, 3, 1, 0, 1, 3, 5, 6, 0]
    if operation == "indexing":
        frame = strips["antenna"][antenna_cycle[frame_index % len(antenna_cycle)]]
        y_offsets = [0, 0, 0, 0, 0, 0, 1, 1, 0, 0, 0, 0, 0, 1, 1, 0]
        return frame, (0, y_offsets[frame_index % len(y_offsets)])

    frame = strips["antenna"][antenna_cycle[(frame_index + 3) % len(antenna_cycle)]]
    y_offsets = [0, 0, 0, 0, 0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 1, 1]
    return frame, (0, y_offsets[frame_index % len(y_offsets)])


def draw_indexing_stack(canvas: Image.Image, frame_index: int, frame_count: int) -> None:
    wobble = sin((frame_index / frame_count) * 2 * pi) * 1.0
    base_x = 116
    base_y = 62
    for index in range(5):
        angle = [-5, 3, -2, 2, -3][index]
        document = draw_shadowed_document(size=(21, 15), angle=angle, alpha=0.95)
        x = int(base_x + index * 1.1 - document.width / 2)
        y = int(base_y + 2.4 * index + wobble - document.height / 2)
        paste_alpha(canvas, document, (x, y))


def draw_indexing_frame(strips: dict[str, list[Image.Image]], frame_index: int, frame_count: int) -> Image.Image:
    canvas = Image.new("RGBA", (CELL_WIDTH, CELL_HEIGHT), (0, 0, 0, 0))
    loop_phase = frame_index / frame_count
    theta = loop_phase * 2 * pi
    glow = smoothstep(sin(loop_phase * 2 * pi - pi / 2) * 0.5 + 0.5)

    # Every document follows a closed path so the operation can loop without
    # papers teleporting at the seam.
    folder = draw_folder(size=(24, 17), angle=-7 + 7 * sin(theta + 0.5), alpha=0.82)
    folder_x = 31 + 4 * cos(theta + 0.4)
    folder_y = 66 + 3 * sin(theta + 0.4)
    paste_alpha(canvas, folder, (int(folder_x - folder.width / 2), int(folder_y - folder.height / 2)))

    for phase_offset, scale, base_angle, center_x, center_y, radius_x, radius_y in (
        (0.00, 0.86, -18, 38, 43, 14, 11),
        (0.25, 0.74, 13, 47, 30, 11, 8),
        (0.50, 0.80, -7, 118, 34, 12, 9),
        (0.75, 0.70, 18, 127, 54, 9, 10),
    ):
        phase = theta + phase_offset * 2 * pi
        x = center_x + radius_x * cos(phase)
        y = center_y + radius_y * sin(phase)
        angle = base_angle + 15 * sin(phase)
        document = draw_shadowed_document(size=(int(17 * scale), int(22 * scale)), angle=angle, alpha=0.58)
        paste_alpha(canvas, document, (int(x - document.width / 2), int(y - document.height / 2)))

    body, offset = operation_body_frames(strips, "indexing", frame_index)
    paste_alpha(canvas, body, offset)
    draw_antenna_glow(canvas, 0.75 if frame_index in (1, 2, 3, 4, 10, 11, 12) else 0.25 * glow)
    draw_motion_lines(canvas, "left", smoothstep(sin(theta + pi / 2) * 0.5 + 0.5) * 0.35)
    draw_motion_lines(canvas, "right", smoothstep(sin(theta - pi / 2) * 0.5 + 0.5) * 0.35)

    held_sway = sin(theta)
    held = draw_shadowed_document(size=(13, 18), angle=-4 + 7 * held_sway, alpha=0.92)
    paste_alpha(canvas, held, (52 + int(round(2 * cos(theta))), int(56 + 2 * held_sway)))
    draw_mitten(canvas, (53 + int(round(cos(theta))), 73), angle=-18)
    draw_mitten(canvas, (108 + int(round(sin(theta))), 72), angle=18)

    if frame_index in (4, 5, 12, 13, 14):
        draw_mouth(canvas, (82, 65), smile=1.0, alpha=0.9)
        draw_cheeks(canvas, 0.9)

    draw_indexing_stack(canvas, frame_index, frame_count)

    sparkle_strength = smoothstep(sin((frame_index / frame_count) * 2 * pi - pi / 2) * 0.5 + 0.5)
    if sparkle_strength > 0.08:
        draw = ImageDraw.Draw(canvas)
        cx, cy = 140, 45
        radius = 2 + sparkle_strength * 2.5
        fill = (255, 225, 82, int(210 * sparkle_strength))
        draw.line([(cx - radius, cy), (cx + radius, cy)], fill=fill, width=1)
        draw.line([(cx, cy - radius), (cx, cy + radius)], fill=fill, width=1)
    if frame_index in (3, 4, 11, 12, 13, 14):
        draw_sparkle(canvas, (28, 36), ((frame_index % 8) / 8), max_radius=3)
        draw_sparkle(canvas, (134, 33), (((frame_index + 3) % 8) / 8), max_radius=3)

    return canvas


def gear_image(radius: int = 15, teeth: int = 10, angle: float = 0.0) -> Image.Image:
    pad = 8
    size = (radius + pad) * 2
    image = Image.new("RGBA", (size * SCALE, size * SCALE), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    center = size * SCALE / 2

    shadow = Image.new("RGBA", image.size, (0, 0, 0, 0))
    shadow_draw = ImageDraw.Draw(shadow)
    shadow_points: list[tuple[float, float]] = []
    for index in range(teeth * 2):
        radial = (radius + (3 if index % 2 == 0 else -1)) * SCALE
        point_angle = angle + index * pi / teeth
        shadow_points.append((center + 2 * SCALE + cos(point_angle) * radial, center + 2 * SCALE + sin(point_angle) * radial))
    shadow_draw.polygon(shadow_points, fill=(0, 0, 0, 94))
    image.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(1.2 * SCALE)))

    points: list[tuple[float, float]] = []
    for index in range(teeth * 2):
        radial = (radius + (3 if index % 2 == 0 else -1)) * SCALE
        point_angle = angle + index * pi / teeth
        points.append((center + cos(point_angle) * radial, center + sin(point_angle) * radial))

    draw.polygon(points, fill=(181, 181, 186, 255), outline=(132, 132, 138, 255))
    draw.ellipse(
        [center - (radius - 5) * SCALE, center - (radius - 5) * SCALE, center + (radius - 5) * SCALE, center + (radius - 5) * SCALE],
        fill=(214, 214, 219, 255),
        outline=(136, 136, 142, 255),
        width=SCALE,
    )
    for spoke_angle in (angle, angle + 2 * pi / 3, angle + 4 * pi / 3):
        inner = 6 * SCALE
        outer = (radius - 5) * SCALE
        draw.line(
            [
                (center + cos(spoke_angle) * inner, center + sin(spoke_angle) * inner),
                (center + cos(spoke_angle) * outer, center + sin(spoke_angle) * outer),
            ],
            fill=(138, 138, 144, 220),
            width=max(1, SCALE),
        )
    marker_angle = angle + pi / 4
    marker_radius = (radius - 2) * SCALE
    marker_x = center + cos(marker_angle) * marker_radius
    marker_y = center + sin(marker_angle) * marker_radius
    draw.ellipse(
        [marker_x - 2 * SCALE, marker_y - 2 * SCALE, marker_x + 2 * SCALE, marker_y + 2 * SCALE],
        fill=(255, 219, 72, 235),
        outline=(178, 131, 30, 190),
        width=max(1, SCALE // 2),
    )
    draw.ellipse(
        [center - 5 * SCALE, center - 5 * SCALE, center + 5 * SCALE, center + 5 * SCALE],
        fill=(144, 144, 150, 255),
        outline=(104, 104, 110, 255),
        width=SCALE,
    )
    return image.resize((size, size), Image.Resampling.LANCZOS)


def draw_sparkle(canvas: Image.Image, center: tuple[int, int], phase: float, max_radius: int = 5) -> None:
    strength = smoothstep(1 - abs(phase - 0.5) * 2)
    if strength <= 0.05:
        return
    draw = ImageDraw.Draw(canvas)
    cx, cy = center
    radius = 1.5 + max_radius * strength
    fill = (255, 225, 82, int(230 * strength))
    draw.line([(cx - radius, cy), (cx + radius, cy)], fill=fill, width=1)
    draw.line([(cx, cy - radius), (cx, cy + radius)], fill=fill, width=1)
    draw.ellipse([cx - 1, cy - 1, cx + 1, cy + 1], fill=fill)


def draw_energy_arc(canvas: Image.Image, center: tuple[int, int], phase: float, radius: int = 30) -> None:
    draw = ImageDraw.Draw(canvas)
    start = phase * 360
    bbox = [center[0] - radius, center[1] - radius, center[0] + radius, center[1] + radius]
    for offset, alpha in ((0, 130), (10, 65)):
        draw.arc(bbox, start=start + offset, end=start + 54 + offset, fill=(255, 219, 72, alpha), width=2)


def draw_optimizing_frame(strips: dict[str, list[Image.Image]], frame_index: int, frame_count: int) -> Image.Image:
    canvas = Image.new("RGBA", (CELL_WIDTH, CELL_HEIGHT), (0, 0, 0, 0))
    rotation = (frame_index / frame_count) * 2 * pi

    draw_energy_arc(canvas, (118, 60), frame_index / frame_count, radius=33)
    small_gear = gear_image(radius=9, teeth=7, angle=-rotation * 1.4)
    paste_alpha(canvas, small_gear, (101, 38), alpha_scale=0.62)

    body, offset = operation_body_frames(strips, "optimizing", frame_index)
    paste_alpha(canvas, body, offset)
    draw_antenna_glow(canvas, 0.45 + 0.35 * smoothstep(sin(rotation - pi / 2) * 0.5 + 0.5))
    if frame_index in (3, 4, 5, 11, 12):
        draw_mouth(canvas, (82, 65), smile=1.0, alpha=0.9)
        draw_cheeks(canvas, 0.7)
    if frame_index in (6, 7, 8):
        draw_mouth(canvas, (82, 66), smile=-1.0, alpha=0.7)

    main_gear = gear_image(radius=16, teeth=9, angle=rotation * 1.25)
    gear_x = 106 + int(round(sin(rotation) * 1.2))
    gear_y = 47 + int(round(cos(rotation) * 1.2))
    paste_alpha(canvas, main_gear, (gear_x, gear_y))
    draw_mitten(canvas, (110 + int(round(sin(rotation) * 1.2)), 71), angle=-26, alpha=0.95)
    draw_mitten(canvas, (135 + int(round(cos(rotation) * 1.0)), 70), angle=24, alpha=0.95)
    small_front = gear_image(radius=7, teeth=7, angle=-rotation * 1.8)
    paste_alpha(canvas, small_front, (124, 63), alpha_scale=0.8)
    draw_sparkle(canvas, (138, 43), (frame_index % frame_count) / frame_count, max_radius=4)
    draw_sparkle(canvas, (111, 52), ((frame_index + frame_count // 2) % frame_count) / frame_count, max_radius=3)
    draw_sparkle(canvas, (132, 76), ((frame_index + frame_count // 4) % frame_count) / frame_count, max_radius=3)
    if frame_index in (4, 5, 12, 13):
        draw_motion_lines(canvas, "right", 0.55)
    return canvas


def save_contact_sheet(output_path: Path, frames: list[Image.Image]) -> None:
    scale = 2
    gap = 8
    label_height = 22
    width = len(frames) * CELL_WIDTH * scale + (len(frames) + 1) * gap
    height = CELL_HEIGHT * scale + label_height + gap * 2
    background = Image.new("RGBA", (width, height), (30, 30, 30, 255))
    draw = ImageDraw.Draw(background)
    for index, frame in enumerate(frames):
        x = gap + index * (CELL_WIDTH * scale + gap)
        y = gap + label_height
        checker = Image.new("RGBA", (CELL_WIDTH * scale, CELL_HEIGHT * scale), (0, 0, 0, 0))
        checker_draw = ImageDraw.Draw(checker)
        square = 16
        for yy in range(0, CELL_HEIGHT * scale, square):
            for xx in range(0, CELL_WIDTH * scale, square):
                color = (62, 62, 62, 255) if ((xx // square + yy // square) % 2 == 0) else (48, 48, 48, 255)
                checker_draw.rectangle([xx, yy, xx + square - 1, yy + square - 1], fill=color)
        checker.alpha_composite(frame.resize((CELL_WIDTH * scale, CELL_HEIGHT * scale), Image.Resampling.NEAREST))
        background.alpha_composite(checker, (x, y))
        draw.text((x + 4, 4), f"{index:02d}", fill=(230, 230, 230, 255))
    background.convert("RGB").save(output_path)


def save_preview_gif(output_path: Path, frames: list[Image.Image]) -> None:
    preview_frames = []
    for frame in frames:
        background = Image.new("RGBA", (CELL_WIDTH, CELL_HEIGHT), (30, 30, 30, 255))
        background.alpha_composite(frame)
        preview_frames.append(background.convert("P", palette=Image.Palette.ADAPTIVE))
    preview_frames[0].save(output_path, save_all=True, append_images=preview_frames[1:], duration=170, loop=0, disposal=2)


def generate(repo_root: Path, frame_count: int, columns: int, write_artifacts: bool) -> None:
    if columns < frame_count:
        raise ValueError("--columns must be greater than or equal to --frames")

    resources = repo_root / "Resources"
    sheet_path = resources / "NibGeneratedMasterSheet.png"
    original_sheet = Image.open(sheet_path).convert("RGBA")
    strips = {
        "idle": load_strip(resources / "NibIdleMainLoopStrip.png"),
        "blink": load_strip(resources / "NibIdleBlinkFidgetStrip.png"),
        "antenna": load_strip(resources / "NibIdleAntennaFidgetStrip.png"),
    }

    rows = original_sheet.height // CELL_HEIGHT
    updated_sheet = Image.new("RGBA", (columns * CELL_WIDTH, rows * CELL_HEIGHT), (0, 0, 0, 0))
    updated_sheet.alpha_composite(original_sheet.crop((0, 0, min(original_sheet.width, updated_sheet.width), updated_sheet.height)), (0, 0))

    generated_rows = {
        "indexing": [draw_indexing_frame(strips, index, frame_count) for index in range(frame_count)],
        "optimizing": [draw_optimizing_frame(strips, index, frame_count) for index in range(frame_count)],
    }

    artifact_dir = repo_root / "artifacts" / "mascot-animation" / "operation-row-previews"
    frame_dir = repo_root / "artifacts" / "mascot-animation" / "reference-frames"
    if write_artifacts:
        artifact_dir.mkdir(parents=True, exist_ok=True)
        frame_dir.mkdir(parents=True, exist_ok=True)

    for name, frames in generated_rows.items():
        row = ROWS[name]
        if write_artifacts:
            original_sheet.crop((0, row * CELL_HEIGHT, original_sheet.width, (row + 1) * CELL_HEIGHT)).save(
                artifact_dir / f"{name}-before-strip.png"
            )

        strip = Image.new("RGBA", (columns * CELL_WIDTH, CELL_HEIGHT), (0, 0, 0, 0))
        if write_artifacts:
            operation_frame_dir = frame_dir / f"NibOperation{name.capitalize()}"
            operation_frame_dir.mkdir(parents=True, exist_ok=True)
        for index, frame in enumerate(frames):
            strip.alpha_composite(frame, (index * CELL_WIDTH, 0))
            if write_artifacts:
                frame.save(operation_frame_dir / f"frame-{index:02d}.png")

        updated_sheet.paste(strip, (0, row * CELL_HEIGHT))

        if write_artifacts:
            strip.save(artifact_dir / f"{name}-strip.png")
            save_contact_sheet(artifact_dir / f"{name}-contact-sheet.png", frames)
            save_preview_gif(artifact_dir / f"{name}.gif", frames)

    updated_sheet.save(sheet_path)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, default=Path.cwd())
    parser.add_argument("--frames", type=int, default=16)
    parser.add_argument("--columns", type=int, default=16)
    parser.add_argument("--no-artifacts", action="store_true")
    args = parser.parse_args()

    generate(args.repo_root.resolve(), args.frames, args.columns, not args.no_artifacts)


if __name__ == "__main__":
    main()
