#!/usr/bin/env python3
"""Frame a real simulator recording for the README. Requires Pillow and ffmpeg.

Each --chapter is START:END in source-video seconds, in this order:
sorting/undo, HTML reading, language selection, batch complete.
Use synthetic demo mail only. No app screens are recreated by this renderer.
"""

import argparse
import math
import subprocess
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parents[1]
WIDTH, HEIGHT, FPS = 1000, 700, 24
SCREEN_W, SCREEN_H = 274, 594
INK, GREEN, MUTED = "#223e33", "#315e47", "#748177"
CHAPTERS = [
    ("01 / SORT", "A swipe. A little space.", "Right for useful. Left for not useful.\nChanged your mind? Just undo.", "TEN EMAILS AT A TIME"),
    ("02 / READ", "The whole story.", "Open the original email, beautifully\nformatted. Then pick up where you left off.", "HTML EMAIL READER"),
    ("03 / LANGUAGE", "Feels like your language.", "English or Simplified Chinese.\nChoose your own, or follow your system.", "ENGLISH + 简体中文"),
    ("04 / DONE", "Ten down. Exhale.", "Your choices are Gmail labels.\nYour original messages stay untouched.", "LABELS ONLY. ALWAYS."),
]


def run(*args):
    subprocess.run(args, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("--chapter", action="append", required=True, help="START:END (four chapters)")
    parser.add_argument("--output", type=Path, default=ROOT / "docs/assets/smail-demo.mp4")
    parser.add_argument("--font-dir", type=Path, default=Path("/System/Library/Fonts/Supplemental"))
    args = parser.parse_args()
    spans = [tuple(map(float, value.split(":"))) for value in args.chapter]
    if len(spans) != 4 or any(len(span) != 2 or span[1] <= span[0] for span in spans):
        parser.error("Provide four increasing START:END ranges.")
    if not args.output.parent.is_dir():
        parser.error("The output directory must already exist.")

    def font(name, size):
        return ImageFont.truetype(str(args.font_dir / name), size)

    sans = font("Arial.ttf", 19)
    bold = font("Arial Bold.ttf", 26)
    small = font("Arial.ttf", 12)
    label = font("Arial Bold.ttf", 12)
    serif = font("Georgia.ttf", 53)
    unicode_font = font("Arial Unicode.ttf", 13)

    background = Image.new("RGB", (WIDTH, HEIGHT), "#f5f3eb")
    draw = ImageDraw.Draw(background)
    draw.ellipse((488, -170, 1110, 505), fill="#e5ebdf")
    draw.ellipse((810, 484, 1220, 894), fill="#eee4c8")
    draw.arc((544, 175, 1072, 703), 34, 300, fill="#d8dfd1", width=1)
    for y in range(540, 643, 18):
        for x in range(535, 609, 18):
            draw.ellipse((x, y, x + 2, y + 2), fill="#c8d2c3")

    icon = Image.open(ROOT / "Smail/Assets.xcassets/AppIcon.appiconset/Icon.png").convert("RGB").resize((44, 44), Image.Resampling.LANCZOS)
    icon_mask = Image.new("L", icon.size)
    ImageDraw.Draw(icon_mask).rounded_rectangle((0, 0, 43, 43), radius=12, fill=255)
    background.paste(icon, (58, 48), icon_mask)
    draw.text((116, 51), "Smail", font=font("Arial Bold.ttf", 30), fill=INK)
    draw.text((58, 119), "A SMALLER WAY TO SORT GMAIL", font=label, fill=MUTED)
    draw.multiline_text((54, 164), "Less inbox.\nMore headspace.", font=serif, fill=INK, spacing=10)
    draw.line((58, 321, 452, 321), fill="#d7ddd0", width=1)
    draw.text((58, 638), "NATIVE iOS  /  NO SERVER  /  NO AI PROCESSING", font=small, fill=MUTED)
    draw.text((648, 665), "Actual app · Synthetic demo mail", font=small, fill=MUTED)

    scenes = []
    for tag, title, description, badge in CHAPTERS:
        scene = background.copy()
        draw = ImageDraw.Draw(scene)
        draw.text((58, 356), tag, font=label, fill=GREEN)
        draw.text((57, 394), title, font=bold, fill=INK)
        draw.multiline_text((58, 437), description, font=sans, fill=MUTED, spacing=9)
        draw.rounded_rectangle((58, 516, 313, 552), radius=18, fill="#e5ebdf")
        draw.text((75, 524), badge, font=unicode_font, fill=GREEN)
        scenes.append(scene)

    screen_mask = Image.new("L", (SCREEN_W, SCREEN_H))
    ImageDraw.Draw(screen_mask).rounded_rectangle((0, 0, SCREEN_W - 1, SCREEN_H - 1), radius=35, fill=255)
    shadow = Image.new("RGBA", (WIDTH, HEIGHT))
    ImageDraw.Draw(shadow).rounded_rectangle((640, 60, 947, 655), radius=48, fill=(33, 55, 39, 50))
    shadow = shadow.filter(ImageFilter.GaussianBlur(18))

    encoder = subprocess.Popen([
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgb24",
        "-s", f"{WIDTH}x{HEIGHT}", "-r", str(FPS), "-i", "-", "-an", "-c:v", "libx264", "-crf", "20",
        "-pix_fmt", "yuv420p", "-movflags", "+faststart", str(args.output),
    ], stdin=subprocess.PIPE)
    previous_screen = None
    elapsed = 0
    try:
        for index, (start, end) in enumerate(spans):
            # Decode before trimming: simulator recordings have sparse/variable frame timing.
            decoder = subprocess.Popen([
                "ffmpeg", "-hide_banner", "-loglevel", "error", "-i", str(args.source),
                "-vf", f"trim=start={start}:end={end},setpts=PTS-STARTPTS,fps={FPS},scale={SCREEN_W}:{SCREEN_H}",
                "-f", "rawvideo", "-pix_fmt", "rgb24", "-",
            ], stdout=subprocess.PIPE)
            count = 0
            frame_size = SCREEN_W * SCREEN_H * 3
            last = None
            try:
                while True:
                    raw = decoder.stdout.read(frame_size)
                    if not raw:
                        break
                    if len(raw) != frame_size:
                        raise RuntimeError("Incomplete decoded frame")
                    screen = Image.frombytes("RGB", (SCREEN_W, SCREEN_H), raw)
                    last = screen
                    transition = min(1, count / (FPS * 0.3))
                    scene = scenes[index].copy()
                    if index and transition < 1:
                        scene = Image.blend(scenes[index - 1], scene, transition)
                        screen = Image.blend(previous_screen, screen, transition)
                    scene = Image.alpha_composite(scene.convert("RGBA"), shadow).convert("RGB")
                    y = 46 + round(2 * math.sin(elapsed / FPS * 0.65))
                    draw = ImageDraw.Draw(scene)
                    draw.rounded_rectangle((632, y - 8, 923, y + SCREEN_H + 8), radius=44, fill="#1d2822", outline="#718174", width=2)
                    draw.rounded_rectangle((628, y + 112, 632, y + 164), radius=2, fill="#59675d")
                    draw.rounded_rectangle((923, y + 152, 927, y + 219), radius=2, fill="#59675d")
                    scene.paste(screen, (641, y), screen_mask)
                    for part in range(4):
                        x = 58 + part * 100
                        draw.rounded_rectangle((x, 595, x + 87, 599), radius=2, fill="#dce2d6")
                        progress = 1 if part < index else min(1, count / max(1, (end - start) * FPS - 1)) if part == index else 0
                        if progress:
                            draw.rounded_rectangle((x, 595, x + max(3, round(87 * progress)), 599), radius=2, fill=GREEN)
                    encoder.stdin.write(scene.tobytes())
                    count += 1
                    elapsed += 1
            finally:
                decoder.stdout.close()
                if decoder.wait() != 0:
                    raise RuntimeError("Video decoding failed")
            if last is None:
                raise RuntimeError(f"No frames in chapter {index + 1}")
            previous_screen = last
        # Let the completed batch breathe before the GIF loops back to the cards.
        for _ in range(FPS * 2):
            encoder.stdin.write(scene.tobytes())
            elapsed += 1
    finally:
        encoder.stdin.close()
        if encoder.wait() != 0:
            raise RuntimeError("Video encoding failed")

    run("ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", str(args.output),
        "-filter_complex", "fps=12,scale=800:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=sierra2_4a",
        "-loop", "0", str(args.output.with_suffix(".gif")))
    run("ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", str(args.output),
        "-frames:v", "1", str(args.output.with_suffix(".png")))
    print(f"Rendered {elapsed / FPS:.1f}s: {args.output}")


if __name__ == "__main__":
    main()
