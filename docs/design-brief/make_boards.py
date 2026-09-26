# Builds the reference boards in docs/design-brief/images/ for the Claude
# Design brief (docs/design-brief/README.md) from the game's own renders and
# colour constants. Run from the repository root with Pillow available, e.g.
#
#     uv run --no-project --with pillow python docs/design-brief/make_boards.py
#
# Fonts: Palatino Linotype (the story book's first choice, BOOK_FONT_NAMES in
# scripts/3d/story_book_3d.gd) with Georgia and Segoe UI from C:\Windows\Fonts.

import os
import random
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), os.pardir, os.pardir))
PREV = os.path.join(ROOT, "assets", "3d", "previews", "styles")
OUT = os.path.join(ROOT, "docs", "design-brief", "images")
os.makedirs(OUT, exist_ok=True)
FONTS = r"C:\Windows\Fonts"

BG = (14, 11, 11)
INK_LIGHT = (214, 200, 178)
INK_DIM = (150, 138, 120)
EMBER = (199, 41, 15)


def font(name, size):
    for candidate in (name, "georgia.ttf"):
        path = os.path.join(FONTS, candidate)
        if os.path.exists(path):
            return ImageFont.truetype(path, size)
    return ImageFont.load_default(size)


TITLE = font("palab.ttf", 44)
HEAD = font("palab.ttf", 26)
BODY = font("pala.ttf", 20)
SMALL = font("segoeui.ttf", 16)
MONO = font("consola.ttf", 15)


def c(r, g, b):
    """Godot UI Color floats (sRGB) to an 8-bit tuple."""
    return tuple(int(round(max(0.0, min(1.0, x)) * 255)) for x in (r, g, b))


def h(hexstr):
    s = hexstr.lstrip("#")
    return tuple(int(s[i:i + 2], 16) for i in (0, 2, 4))


def hexof(rgb):
    return "#%02x%02x%02x" % rgb


def load(name, width=None):
    im = Image.open(os.path.join(PREV, name)).convert("RGB")
    if width:
        im = im.resize((width, round(im.height * width / im.width)), Image.LANCZOS)
    return im


def header(draw, title, subtitle, width):
    draw.text((48, 36), title, font=TITLE, fill=INK_LIGHT)
    draw.text((50, 92), subtitle, font=BODY, fill=INK_DIM)
    draw.line((48, 132, width - 48, 132), fill=(70, 30, 22), width=2)


def caption(draw, xy, text, fill=INK_DIM, fnt=SMALL):
    draw.text(xy, text, font=fnt, fill=fill)


# --------------------------------------------------------------------------
# 1. the look
# --------------------------------------------------------------------------

def board_look():
    W = 1700
    img = Image.new("RGB", (W, 1520), BG)
    d = ImageDraw.Draw(img)
    header(d, "The Bound Three - the look",
           "Painted, pre-rendered dark fantasy scenes with real-time characters, seen from one fixed isometric camera.", W)
    main = load("prerender_crypt_game_zoom.png", 1600)
    img.paste(main, (50, 160))
    caption(d, (50, 160 + main.height + 8),
            "In game at the default camera (orthographic, yaw 45, pitch -35, 14 m of view height, 1600 x 900). "
            "The mage is about 125 px tall.")
    thumbs = [("prerender_crypt_in_doorway.png", "Walls and arches hide characters per pixel"),
              ("prerender_crypt_cast.png", "Magic light reaches the painted scene"),
              ("prerender_crypt_by_brazier.png", "Warm fire against cool moonlight")]
    tw = 520
    y = 160 + main.height + 44
    for i, (name, text) in enumerate(thumbs):
        t = load(name, tw)
        x = 50 + i * (tw + 20)
        img.paste(t, (x, y))
        caption(d, (x, y + t.height + 6), text)
    img = img.crop((0, 0, W, y + round(900 * tw / 1600) + 40))
    img.save(os.path.join(OUT, "01_look.png"))


# --------------------------------------------------------------------------
# 2. the palette
# --------------------------------------------------------------------------

PALETTE = [
    ("World - the painted scenes", [
        ("Flagstone dark", h("#34362f")), ("Flagstone light", h("#5a5a51")), ("Wall stone", h("#5e5b52")),
        ("Mortar", h("#1d1c19")), ("Moss", h("#1f2a18")), ("Soil", h("#2c271f")),
        ("Moonlight", c(0.6, 0.7, 1.0)), ("Firelight", c(1.0, 0.5, 0.2)), ("Fire core", h("#fff1b0")),
        ("Sigil crimson", h("#ff1a0a")), ("Banner red", h("#5c1016")), ("Night void", h("#030304")),
    ]),
    ("Characters - the dark mage", [
        ("Robe charcoal", h("#2b272c")), ("Robe shadow", h("#18151a")), ("Under-robe oxblood", h("#4a151a")),
        ("Tarnished embroidery", h("#6b5836")), ("Mantle", h("#332d31")), ("Ashen skin", h("#8c8078")),
        ("Beard grey", h("#9d9891")), ("Leather", h("#3d2c20")), ("Bone", h("#b9ad90")),
        ("Staff wood", h("#231c17")), ("Crimson glow", h("#ff2a14")), ("Tarnished brass", h("#7a6843")),
    ]),
    ("Interface - the story book", [
        ("Leather", c(0.055, 0.040, 0.038)), ("Leather edge", c(0.20, 0.17, 0.15)), ("Iron", c(0.24, 0.23, 0.22)),
        ("Iron shade", c(0.08, 0.075, 0.07)), ("Iron rivet", c(0.46, 0.43, 0.39)), ("Parchment", c(0.71, 0.62, 0.47)),
        ("Stain", c(0.44, 0.32, 0.20)), ("Scorch", c(0.07, 0.04, 0.03)), ("Ink", c(0.10, 0.06, 0.05)),
        ("Ember ink", c(0.78, 0.16, 0.06)), ("Heat", c(1.0, 0.80, 0.42)), ("Blood", c(0.40, 0.05, 0.04)),
    ]),
    ("Gameplay signals - keep these readable", [
        ("Knight soul", c(0.58, 0.74, 1.0)), ("Rogue soul", c(0.55, 0.93, 0.60)), ("Mage soul", c(0.80, 0.62, 1.0)),
        ("Fire", c(1.0, 0.55, 0.2)), ("Frost", c(0.62, 0.88, 1.0)), ("Poison", c(0.55, 0.95, 0.35)),
        ("Damage dealt", c(1.0, 0.93, 0.62)), ("Damage taken", c(1.0, 0.36, 0.36)), ("Heal", c(0.55, 0.95, 0.6)),
        ("Experience", c(0.72, 0.62, 1.0)), ("Player turn", c(0.66, 0.9, 0.7)), ("Enemy turn", c(0.95, 0.52, 0.5)),
    ]),
]


def board_palette():
    W = 1700
    cols, sw, gap = 6, 240, 20
    rows_per_group = 2
    group_h = 64 + rows_per_group * (sw * 0.45 + 58)
    img = Image.new("RGB", (W, int(160 + len(PALETTE) * group_h + 40)), BG)
    d = ImageDraw.Draw(img)
    header(d, "The Bound Three - palette",
           "Values from the game's generators and UI code. Muted, dark and worn; saturation is kept for light, magic and gameplay signals.", W)
    y = 160
    for title, swatches in PALETTE:
        d.text((50, y), title, font=HEAD, fill=INK_LIGHT)
        y += 44
        for i, (name, rgb) in enumerate(swatches):
            r, k = divmod(i, cols)
            x = 50 + k * (sw + gap)
            yy = y + r * (sw * 0.45 + 58)
            d.rectangle((x, yy, x + sw, yy + sw * 0.45), fill=rgb, outline=(60, 52, 46))
            d.text((x, yy + sw * 0.45 + 6), name, font=SMALL, fill=INK_LIGHT)
            d.text((x, yy + sw * 0.45 + 28), hexof(rgb).upper(), font=MONO, fill=INK_DIM)
        y += rows_per_group * (sw * 0.45 + 58) + 20
    img.save(os.path.join(OUT, "02_palette.png"))


# --------------------------------------------------------------------------
# 3. characters
# --------------------------------------------------------------------------

def board_characters():
    W = 1700
    img = Image.new("RGB", (W, 900), BG)
    d = ImageDraw.Draw(img)
    header(d, "The Bound Three - characters",
           "Adult proportions (head about 1/7.5 of the height), silhouette first, one strong accent colour per character.", W)
    shots = [("mage_dark_front.png", "Front"), ("mage_dark_side.png", "Side"), ("mage_dark_back.png", "Back"),
             ("mage_dark_walk.png", "Walk"), ("mage_dark_cast.png", "Cast")]
    tw = 270
    for i, (name, label) in enumerate(shots):
        t = load(name, tw)
        x = 50 + i * (tw + 20)
        img.paste(t, (x, 160))
        d.text((x, 160 + t.height + 8), label, font=HEAD, fill=INK_LIGHT)
    notes = ("The dark mage: 1.95 m to the hood tip, torn charcoal robe over an oxblood under-robe, ragged mantle, "
             "gaunt face in shadow with glowing eyes, claw staff with a crimson crystal.")
    d.text((50, 160 + 360 + 56), notes, font=BODY, fill=INK_DIM)
    d.text((50, 160 + 360 + 86), "At the game camera he is about 125 px tall: the pointed hood, the torn hem and the "
                                 "crimson crystal carry him, not the fine detail.", font=BODY, fill=INK_DIM)
    small = load("prerender_crypt_game_zoom.png")
    crop = small.crop((700, 560, 900, 720)).resize((200, 160), Image.NEAREST)
    img.paste(crop, (1500, 160 + 360 - 160))
    caption(d, (1500, 160 + 360 + 6), "Actual size in game, 2x")
    img = img.crop((0, 0, W, 160 + 360 + 130))
    img.save(os.path.join(OUT, "03_characters.png"))


# --------------------------------------------------------------------------
# 4. UI materials and type
# --------------------------------------------------------------------------

def noise_tile(size, base, dark, light, grain, seed, blur=1.2):
    rnd = random.Random(seed)
    w, hgt = size
    small = Image.new("L", (w // 8 + 1, hgt // 8 + 1))
    small.putdata([rnd.randint(0, 255) for _ in range(small.width * small.height)])
    low = small.resize(size, Image.BICUBIC).filter(ImageFilter.GaussianBlur(6))
    fine = Image.new("L", size)
    fine.putdata([rnd.randint(0, 255) for _ in range(w * hgt)])
    fine = fine.filter(ImageFilter.GaussianBlur(blur))
    out = Image.new("RGB", size, base)
    px = out.load()
    lp, fp = low.load(), fine.load()
    for y in range(hgt):
        for x in range(w):
            t = (lp[x, y] / 255.0 - 0.5) * 1.6 + (fp[x, y] / 255.0 - 0.5) * grain
            col = dark if t < 0 else light
            k = min(1.0, abs(t))
            px[x, y] = tuple(int(base[i] + (col[i] - base[i]) * k) for i in range(3))
    return out


def board_ui():
    W = 1700
    img = Image.new("RGB", (W, 980), BG)
    d = ImageDraw.Draw(img)
    header(d, "The Bound Three - interface materials and type",
           "Direction from the in-game story book (scripts/3d/story_book_3d.gd): black leather, dark iron, scorched parchment, ember-red ink.", W)
    leather = c(0.055, 0.040, 0.038)
    parchment = c(0.71, 0.62, 0.47)
    tiles = [
        ("Black leather", noise_tile((360, 240), leather, (4, 3, 3), c(0.20, 0.17, 0.15), 0.8, 1)),
        ("Dark iron", noise_tile((360, 240), c(0.24, 0.23, 0.22), c(0.08, 0.075, 0.07), c(0.46, 0.43, 0.39), 0.5, 2, 0.6)),
        ("Scorched parchment", noise_tile((360, 240), parchment, c(0.44, 0.32, 0.20), (222, 204, 170), 0.5, 3)),
    ]
    for i, (label, tile) in enumerate(tiles):
        x = 50 + i * 380
        if label == "Dark iron":
            td = ImageDraw.Draw(tile)
            for rx, ry in ((18, 18), (342, 18), (18, 222), (342, 222)):
                td.ellipse((rx - 7, ry - 7, rx + 7, ry + 7), fill=c(0.46, 0.43, 0.39), outline=c(0.08, 0.075, 0.07))
        if label == "Scorched parchment":
            edge = Image.new("L", tile.size, 0)
            ed = ImageDraw.Draw(edge)
            ed.rectangle((0, 0, tile.width, tile.height), outline=255, width=14)
            edge = edge.filter(ImageFilter.GaussianBlur(10))
            tile = Image.composite(Image.new("RGB", tile.size, c(0.07, 0.04, 0.03)), tile, edge)
        img.paste(tile, (x, 160))
        d.text((x, 408), label, font=HEAD, fill=INK_LIGHT)
    # a sample leaf: heading and body in the book font, ember ink cooling to ink
    leaf = noise_tile((500, 330), parchment, c(0.44, 0.32, 0.20), (222, 204, 170), 0.5, 7)
    ld = ImageDraw.Draw(leaf)
    ld.text((34, 28), "Arcane Burst", font=font("palab.ttf", 40), fill=c(0.78, 0.16, 0.06))
    ld.text((36, 90), "A bolt that bursts on impact, hitting", font=font("pala.ttf", 22), fill=c(0.10, 0.06, 0.05))
    ld.text((36, 120), "every enemy near the target.", font=font("pala.ttf", 22), fill=c(0.10, 0.06, 0.05))
    ld.text((36, 172), "Damage 14   Radius 2.5 m", font=font("pala.ttf", 20), fill=c(0.30, 0.20, 0.15))
    ld.text((36, 250), "Words burn in ember and cool to ink.", font=font("palai.ttf", 20), fill=c(0.40, 0.05, 0.04))
    img.paste(leaf, (1150, 160))
    d.text((1150, 500), "Sample leaf: the real Arcane Burst text (scripts/soul.gd); direction, not a layout", font=SMALL, fill=INK_DIM)
    # type specimen
    y = 470
    d.text((50, y), "Type", font=HEAD, fill=INK_LIGHT)
    d.text((50, y + 44), "Palatino Linotype - headings and story text (fallbacks: Palatino, Constantia, Book Antiqua, Georgia)",
           font=BODY, fill=INK_DIM)
    d.text((50, y + 80), "The Bound Three", font=font("palab.ttf", 56), fill=INK_LIGHT)
    d.text((50, y + 150), "Three souls share one body. Only one may lead at a time.", font=font("pala.ttf", 28), fill=INK_DIM)
    d.text((50, y + 200), "Small interface numbers need a clear sans for legibility: damage 12, 6 m, 3 turns",
           font=font("segoeui.ttf", 22), fill=INK_DIM)
    # gameplay chips on leather
    chip_y = y + 260
    chips = [("Knight", c(0.58, 0.74, 1.0)), ("Rogue", c(0.55, 0.93, 0.60)), ("Mage", c(0.80, 0.62, 1.0)),
             ("Fire", c(1.0, 0.55, 0.2)), ("Frost", c(0.62, 0.88, 1.0)), ("Poison", c(0.55, 0.95, 0.35)),
             ("Heal", c(0.55, 0.95, 0.6)), ("Damage", c(1.0, 0.36, 0.36))]
    strip = noise_tile((W - 100, 80), leather, (4, 3, 3), c(0.20, 0.17, 0.15), 0.8, 9)
    sd = ImageDraw.Draw(strip)
    for i, (label, col) in enumerate(chips):
        x = 20 + i * 196
        sd.rounded_rectangle((x, 18, x + 176, 62), radius=6, outline=col, width=2, fill=(20, 15, 14))
        sd.text((x + 16, 26), label, font=font("segoeui.ttf", 20), fill=col)
    img.paste(strip, (50, chip_y))
    d.text((50, chip_y + 90), "Gameplay colours stay saturated so they read on the dark frame; everything else stays muted.",
           font=SMALL, fill=INK_DIM)
    img = img.crop((0, 0, W, chip_y + 130))
    img.save(os.path.join(OUT, "04_interface.png"))


board_look()
board_palette()
board_characters()
board_ui()
print("BOARDS OK", sorted(os.listdir(OUT)))
