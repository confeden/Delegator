"""Raster rendering of a benchmark report.

Why not SVG: Telegram treats an .svg as a web document and warns the recipient
that opening it may reveal their IP address — a report meant to be shared must
not scare the people it is shared with. A .png is just an image everywhere.

Drawn at RETINA scale and downscaled, so the text stays crisp when the picture
is opened full-size or screenshotted. Pillow is the only extra dependency of
the core; when it (or a usable font) is missing, the caller falls back to SVG
instead of failing the export.
"""

from __future__ import annotations

import io
from pathlib import Path

# engine imports this module lazily (inside export_report), so there is no cycle.
from .engine import arm_cell, format_points, plural_tasks

# Same palette as the SVG renderer — the two must look like one product.
INK = (28, 28, 28)
MUTED = (107, 107, 107)
GREEN = (46, 125, 50)
RED = (178, 60, 60)
WHITE = (255, 255, 255)
RULE = (221, 221, 221)
GREEN_FILL = (232, 245, 233)
RED_FILL = (253, 236, 234)

# Font faces to try, in order: Segoe UI is the Windows UI font and carries
# Cyrillic; the rest are fallbacks for stripped-down systems.
FONT_CANDIDATES = (
    ("segoeui.ttf", "segoeuib.ttf"),
    ("tahoma.ttf", "tahomabd.ttf"),
    ("arial.ttf", "arialbd.ttf"),
    ("verdana.ttf", "verdanab.ttf"),
    ("DejaVuSans.ttf", "DejaVuSans-Bold.ttf"),
)

SCALE = 2
# Wider than the 0.5.4 layout: every score now carries its constraint count
# («2.3/3 (7/9)») and the picture gained a per-level profile block.
WIDTH_COMPARE = 900
WIDTH_SOLO = 640
ROW_HEIGHT = 27
PROFILE_ROW_HEIGHT = 23


class ImageUnavailable(RuntimeError):
    """Pillow or a usable font is missing; the caller should fall back."""


def _load_fonts():
    try:
        from PIL import ImageFont
    except ImportError as error:  # pragma: no cover - depends on the build
        raise ImageUnavailable("Pillow is not available") from error

    for regular_name, bold_name in FONT_CANDIDATES:
        try:
            regular = ImageFont.truetype(regular_name, 13 * SCALE)
        except OSError:
            continue
        try:
            bold = ImageFont.truetype(bold_name, 13 * SCALE)
        except OSError:
            bold = regular

        def sized(name: str, fallback, size: int):
            try:
                return ImageFont.truetype(name, size * SCALE)
            except OSError:
                return fallback

        return {
            "title": sized(bold_name, bold, 19),
            "meta": sized(regular_name, regular, 11),
            "header": sized(bold_name, bold, 11),
            "row": regular,
            "chip": sized(regular_name, regular, 10),
            "total": sized(bold_name, bold, 14),
            "note": sized(regular_name, regular, 10),
        }
    raise ImageUnavailable("no usable TrueType font was found")


def _wrap(text: str, width: int) -> list[str]:
    words = str(text).split()
    lines: list[str] = []
    current = ""
    for word in words:
        if len(current) + len(word) + 1 > width:
            lines.append(current)
            current = word
        else:
            current = f"{current} {word}".strip()
    if current:
        lines.append(current)
    return lines


def render_png(report: dict, level_label, arm_model: str, arm_delegator: str) -> bytes:
    """PNG bytes of the report table. Raises ImageUnavailable when it cannot draw."""
    from PIL import Image, ImageDraw

    fonts = _load_fonts()
    compare = report.get("mode") == "compare"
    rows = report.get("tasks", [])
    profile = report.get("profile") or {}
    groups = list(profile.get("byLevel") or []) + list(profile.get("byCategory") or [])
    width = WIDTH_COMPARE if compare else WIDTH_SOLO
    verdict_lines = _wrap(report.get("verdict", ""), 108 if compare else 76)
    height = (
        150
        + ROW_HEIGHT * (len(rows) + 2)
        + (26 + PROFILE_ROW_HEIGHT * len(groups) + 12 if groups else 0)
        + 20 * len(verdict_lines)
        + 30
    )
    model_x, delegator_x, winner_x = 430, 590, 730

    image = Image.new("RGB", (width * SCALE, height * SCALE), WHITE)
    draw = ImageDraw.Draw(image)

    def text(x: int, y: int, value: str, font, fill=INK) -> None:
        draw.text((x * SCALE, y * SCALE), str(value), font=font, fill=fill)

    text(24, 24, "Delegator — результаты бенчмарка", fonts["title"])
    text(
        24, 54,
        "Delegator v%s · набор задач v%s · seed %s"
        % (report.get("delegatorVersion"), report.get("benchmarkVersion"), report.get("seed")),
        fonts["meta"], MUTED,
    )
    text(
        24, 72,
        "%s · модель IDE: %s" % (report.get("finishedAt"), report.get("modelLabel")),
        fonts["meta"], MUTED,
    )

    columns = [(24, "Задача"), (330, "Уровень"), (model_x, "Модель")]
    if compare:
        columns += [(delegator_x, "Delegator"), (winner_x, "Лучше")]
    for x, label in columns:
        text(x, 104, label, fonts["header"], MUTED)
    draw.line(
        [(24 * SCALE, 122 * SCALE), ((width - 24) * SCALE, 122 * SCALE)],
        fill=RULE, width=SCALE,
    )

    y = 132
    for row in rows:
        model = row.get(arm_model) or {}
        text(24, y, "%d. %s" % (row["index"], row["title"]), fonts["row"])
        text(330, y, level_label(row.get("level", "")), fonts["row"], MUTED)
        text(
            model_x, y, arm_cell(model, row["points"]),
            fonts["row"], GREEN if model.get("passed") else RED,
        )
        if compare:
            delegator = row.get(arm_delegator) or {}
            text(
                delegator_x, y, arm_cell(delegator, row["points"]),
                fonts["row"], GREEN if delegator.get("passed") else RED,
            )
            winner = row.get("winner")
            if winner in (arm_model, arm_delegator):
                label = "Delegator" if winner == arm_delegator else "модель"
                fill = GREEN_FILL if winner == arm_delegator else RED_FILL
                stroke = GREEN if winner == arm_delegator else RED
                draw.rounded_rectangle(
                    [((winner_x - 2) * SCALE, (y - 3) * SCALE),
                     ((width - 24) * SCALE, (y + 17) * SCALE)],
                    radius=4 * SCALE, fill=fill, outline=stroke, width=SCALE,
                )
                text(winner_x + 6, y + 1, label, fonts["chip"], stroke)
            else:
                text(winner_x + 6, y + 1, "поровну", fonts["chip"], MUTED)
        y += ROW_HEIGHT

    draw.line(
        [(24 * SCALE, (y + 2) * SCALE), ((width - 24) * SCALE, (y + 2) * SCALE)],
        fill=RULE, width=SCALE,
    )
    y += 12
    totals = report.get("totals", {})
    model_total = totals.get(arm_model) or 0
    text(24, y, "Итого", fonts["total"])
    text(model_x, y, "%s/%s" % (format_points(model_total), report.get("maxPoints")), fonts["total"])
    if compare:
        delegator_total = totals.get(arm_delegator) or 0
        colour = GREEN if delegator_total > model_total else (RED if delegator_total < model_total else INK)
        text(
            delegator_x, y,
            "%s/%s" % (format_points(delegator_total), report.get("maxPoints")),
            fonts["total"], colour,
        )
    y += 34

    # Per level and per capability: the answer to «где отставание или опережение»,
    # which no single total can give.
    if groups:
        text(24, y, "Где сильнее и где слабее", fonts["header"], INK)
        y += 26
        for group in groups:
            tasks = int(group.get("tasks", 0))
            text(24, y, "%s · %d %s" % (group.get("label", ""), tasks, plural_tasks(tasks)),
                 fonts["row"], MUTED)
            text(model_x, y, "%s/%s" % (format_points(group.get(arm_model)),
                                        group.get("maxPoints", 0)), fonts["row"])
            if compare:
                text(delegator_x, y, "%s/%s" % (format_points(group.get(arm_delegator)),
                                                group.get("maxPoints", 0)), fonts["row"])
            y += PROFILE_ROW_HEIGHT
        y += 12

    for line in verdict_lines:
        text(24, y, line, fonts["row"])
        y += 20
    text(
        24, y + 6,
        "Оценка механическая: задача разбита на именованные проверки, балл — доля пройденных "
        "(в скобках их число). Модели ответы не оценивали.",
        fonts["note"], MUTED,
    )

    image = image.resize((width, height), Image.LANCZOS)
    buffer = io.BytesIO()
    image.save(buffer, format="PNG", optimize=True)
    return buffer.getvalue()


def write_png(path: Path, report: dict, level_label, arm_model: str, arm_delegator: str) -> None:
    Path(path).write_bytes(render_png(report, level_label, arm_model, arm_delegator))
