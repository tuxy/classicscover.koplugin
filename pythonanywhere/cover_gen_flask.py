"""
Minimal Flask API for generating Penguin-style book covers.

Usage:
    pip install flask pillow
    python cover_gen_flask.py
"""

import io
import os
import sys

from flask import Flask, jsonify, request, send_file
from PIL import Image, ImageDraw, ImageFont

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
FONT_ITALIC = os.path.join(BASE_DIR, "fonts", "EBGaramond-Italic.ttf")
FONT_REGULAR = os.path.join(BASE_DIR, "fonts", "JosefinSans-SemiBold.ttf")
DEFAULT_LOGO_PATH = os.path.join(BASE_DIR, "resources", "logo.png")

app = Flask(__name__)
app.config["MAX_CONTENT_LENGTH"] = 20 * 1024 * 1024

SMALL_WORDS = {
    "a", "an", "the", "and", "but", "or", "for", "nor",
    "on", "at", "to", "by", "in", "of", "up", "as", "is",
}

DEFAULT_AUTHOR_FONT_SIZE = 52
DEFAULT_TITLE_FONT_SIZE = 70
MIN_FONT_SIZE = 12
MAX_FONT_SIZE = 160
MAX_TEXT_LENGTH = 200


def smart_title(text: str) -> str:
    words = text.split()
    return " ".join(
        word.capitalize() if index == 0 or word.lower() not in SMALL_WORDS else word.lower()
        for index, word in enumerate(words)
    )


def normalize_text(value: str, field_name: str) -> tuple[str, str | None]:
    text = " ".join(value.split())
    if not text:
        return "", f"{field_name} is required."
    if len(text) > MAX_TEXT_LENGTH:
        return "", f"{field_name} must be {MAX_TEXT_LENGTH} characters or fewer."
    return text, None


def get_text_width_with_spacing(text, font, spacing=0):
    non_spaces = sum(1 for char in text if char != " ")
    return font.getlength(text) + (non_spaces * spacing)


def wrap_text_pixel(text, font, max_width, spacing=0):
    words = text.split()
    lines = []
    current = ""
    for word in words:
        test = current + (" " if current else "") + word
        if get_text_width_with_spacing(test, font, spacing) <= max_width:
            current = test
        else:
            if current:
                lines.append(current)
            current = word
    if current:
        lines.append(current)
    return lines


def get_font_height(font):
    bbox = font.getbbox("Ag")
    return bbox[3] - bbox[1]


def draw_text_with_spacing(draw, position, text, font, fill="white", spacing=5):
    x, y = position
    for char in text:
        if char == " ":
            x += font.getlength(" ")
        else:
            draw.text((x, y), char, font=font, fill=fill)
            x += font.getlength(char) + spacing


def fit_background(bg_image: Image.Image, width: int, strip_y: int) -> Image.Image:
    bg = bg_image.convert("RGB")
    bg_w, bg_h = bg.size

    scale = width / bg_w
    new_h = int(bg_h * scale)
    bg = bg.resize((width, new_h), Image.LANCZOS)

    if new_h >= strip_y:
        top = new_h - strip_y
        bg = bg.crop((0, top, width, new_h))
    else:
        scale = strip_y / bg_h
        new_w = int(bg_w * scale)
        bg = bg.resize((new_w, strip_y), Image.LANCZOS)
        left = (new_w - width) // 2
        bg = bg.crop((left, 0, left + width, strip_y))

    return bg


def make_penguin_cover(
    title: str,
    author: str,
    bg_image: Image.Image,
    logo_path: str,
    title_font_size: int | None = None,
    author_font_size: int | None = None,
) -> io.BytesIO:
    width, height = 1236, 1648
    cover = Image.new("RGB", (width, height), (255, 255, 255))

    black_h = 580
    black_y = height - black_h
    strip_h = 110
    strip_y = black_y - strip_h

    cover.paste(fit_background(bg_image, width, strip_y), (0, 0))
    draw = ImageDraw.Draw(cover)

    font_author = ImageFont.truetype(FONT_REGULAR, author_font_size or DEFAULT_AUTHOR_FONT_SIZE)
    font_title = ImageFont.truetype(FONT_ITALIC, title_font_size or DEFAULT_TITLE_FONT_SIZE)
    font_strip = ImageFont.truetype(FONT_REGULAR, 36)

    padding = 80

    overlay = Image.new("RGBA", (width, black_h), (0, 0, 0, 255))
    cover.paste(overlay, (0, black_y), overlay)

    strip = Image.new("RGBA", (width, strip_h), (255, 255, 255, 255))
    cover.paste(strip, (0, strip_y), strip)

    rule_h = 3
    rule = Image.new("RGBA", (width, rule_h), (0, 0, 0, 255))
    cover.paste(rule, (0, strip_y), rule)
    cover.paste(rule, (0, strip_y + strip_h - rule_h), rule)

    with Image.open(logo_path) as logo_image:
        logo = logo_image.convert("RGBA")
    logo_h = strip_h - 60
    logo_w = int(logo.width * logo_h / logo.height)
    logo = logo.resize((logo_w, logo_h), Image.LANCZOS)

    left_text = "CLASSICS"
    right_text = " EDITION"
    gap = 30

    left_w = get_text_width_with_spacing(left_text, font_strip, spacing=10)
    right_w = get_text_width_with_spacing(right_text, font_strip, spacing=10)
    strip_cy = strip_y + strip_h / 2

    text_h = font_strip.getbbox("A")[3] - font_strip.getbbox("A")[1]
    text_y = strip_cy - text_h / 2

    total_w = left_w + gap + logo_w + gap + right_w
    start_x = (width - total_w) / 2

    draw_text_with_spacing(draw, (start_x, text_y), left_text, font_strip, fill="black", spacing=10)

    logo_x = int(start_x + left_w + gap)
    logo_y = int(strip_cy - logo_h / 2)
    cover.paste(logo, (logo_x, logo_y), logo)

    right_x = logo_x + logo_w + gap
    draw_text_with_spacing(draw, (right_x, text_y), right_text, font_strip, fill="black", spacing=10)

    author_upper = author.upper()
    author_lines = wrap_text_pixel(author_upper, font_author, width - padding * 2, spacing=8)
    author_fh = font_author.getbbox("A")[3] - font_author.getbbox("A")[1]
    author_line_gap = 24

    author_y = black_y + 160
    for line in author_lines:
        line_width = get_text_width_with_spacing(line, font_author, spacing=8)
        offset = font_author.getbbox(line)[1]
        draw_text_with_spacing(
            draw,
            ((width - line_width) / 2, author_y - offset),
            line,
            font_author,
            fill=(230, 103, 37),
            spacing=8,
        )
        author_y += author_fh + author_line_gap

    title = smart_title(title)
    title_lines = wrap_text_pixel(title, font_title, width - padding * 2, spacing=2)
    title_fh = get_font_height(font_title)
    line_gap = 32
    total_title_h = len(title_lines) * title_fh + (len(title_lines) - 1) * line_gap

    title_area_top = author_y + 10
    title_area_bot = height - 10
    start_y = title_area_top + (title_area_bot - title_area_top - total_title_h) / 2

    for line in title_lines:
        line_width = get_text_width_with_spacing(line, font_title, spacing=2)
        offset = font_title.getbbox(line)[1]
        draw_text_with_spacing(
            draw,
            ((width - line_width) / 2, start_y - offset),
            line,
            font_title,
            fill="white",
            spacing=2,
        )
        start_y += title_fh + line_gap

    buf = io.BytesIO()
    cover.save(buf, format="PNG")
    buf.seek(0)
    return buf


def validate_dependencies():
    errors = []

    if not os.path.isfile(DEFAULT_LOGO_PATH):
        errors.append(f"Penguin logo not found at: {DEFAULT_LOGO_PATH}")

    for path in (FONT_ITALIC, FONT_REGULAR):
        if not os.path.isfile(path):
            errors.append(f"Font not found: {path}")

    return errors


def parse_optional_font_size(field_name: str) -> tuple[int | None, str | None]:
    value = request.form.get(field_name, "").strip()
    if not value:
        return None, None

    try:
        size = int(value)
    except ValueError:
        return None, f"{field_name.replace('_', ' ').capitalize()} must be an integer."

    if size < MIN_FONT_SIZE or size > MAX_FONT_SIZE:
        return None, (
            f"{field_name.replace('_', ' ').capitalize()} must be between "
            f"{MIN_FONT_SIZE} and {MAX_FONT_SIZE}."
        )

    return size, None


@app.route("/generate", methods=["POST"])
def generate():
    title, title_error = normalize_text(request.form.get("title", ""), "Title")
    author, author_error = normalize_text(request.form.get("author", ""), "Author")
    image = request.files.get("image")
    title_font_size, title_font_error = parse_optional_font_size("title_font_size")
    author_font_size, author_font_error = parse_optional_font_size("author_font_size")

    errors = []
    if title_error:
        errors.append(title_error)
    if author_error:
        errors.append(author_error)
    if not image or image.filename == "":
        errors.append("Background image is required.")
    if title_font_error:
        errors.append(title_font_error)
    if author_font_error:
        errors.append(author_font_error)

    errors.extend(validate_dependencies())
    if errors:
        status = 400 if len(errors) <= 3 else 500
        return jsonify({"errors": errors}), status

    try:
        with Image.open(image.stream) as uploaded_image:
            bg_image = uploaded_image.convert("RGB")
        buf = make_penguin_cover(
            title,
            author,
            bg_image,
            DEFAULT_LOGO_PATH,
            title_font_size=title_font_size,
            author_font_size=author_font_size,
        )
        safe_title = "".join(char if char.isalnum() or char in " _-" else "_" for char in title)
        filename = f"cover_{safe_title[:40].strip()}.png"
        return send_file(buf, mimetype="image/png", as_attachment=True, download_name=filename)
    except Exception as exc:
        app.logger.exception("Cover generation failed")
        return jsonify({"errors": [f"Cover generation failed: {exc}"]}), 500


if __name__ == "__main__":
    missing = validate_dependencies()
    if missing:
        print("Warning: missing required files:", file=sys.stderr)
        for item in missing:
            print(f"  {item}", file=sys.stderr)

    print("Cover generator listening on http://0.0.0.0:5000/generate")
    app.run(debug=False, host="0.0.0.0", port=5000)
