"""Builds a clay-target detection dataset (YOLO format) for shooter mode.

No public, freely downloadable set of labelled clay photos exists, so the training images are
synthetic but realistic:

1. Background photos come from Wikimedia Commons (skies, clouds, countryside, tree lines,
   shooting grounds without targets in view, and birds in flight as "not a clay" examples).
   Licences and authors are written to models/clay_background_credits.csv.
2. Clays are drawn onto them: a 110 mm disc seen at a random angle (from face-on to edge-on),
   with dome shading, a darker rim, real clay colours (mostly orange or black), sizes from a
   few pixels (far) to large (near), motion blur along the flight direction, slight defocus,
   and the background's lighting.
3. The label box is the disc itself without its blur streak, which keeps the box size, and so
   the app's distance, tied to the clay's real diameter.
4. "Not a clay" examples, added after the first model mistook mugs, wine glasses, couch legs and
   Christmas decorations for clays: a quarter of the images are household and clutter photos
   (mostly with no clay), and a third of the others get drawn decoys (balls, rings, plates, cups,
   glowing lights) that are never labelled.

Usage: python training/clays/build_clay_dataset.py [train_images] [val_images]
"""

import csv
import io
import json
import math
import random
import re
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageEnhance

OUT = Path("/tmp/clays")
CREDITS = Path("models/clay_background_credits.csv")
SIZE = 640
USER_AGENT = "BirdTrackerTraining/1.0 (clay-target detector; GitHub Actions)"

QUERIES = [
    "cloudy sky", "blue sky clouds", "overcast sky", "sky over hills", "sunset sky clouds",
    "cumulus clouds", "sky trees silhouette", "countryside field sky", "olive grove landscape",
    "pine forest edge", "mediterranean landscape hills", "Cyprus landscape", "farmland horizon",
    "hedge field", "shooting range landscape", "trap shooting range", "bird in flight sky",
    "pigeon flying", "gull flying sky", "crow flying",
]
PER_QUERY = 45

# "Not a clay" photos: everyday objects the first model mistook for clays (mugs, glasses, furniture,
# Christmas decorations) and outdoor clutter around a shooting ground. Most are used with no clay
# drawn on them, so the model learns to ignore round, bright or curved things that are not clays.
NEGATIVE_QUERIES = [
    "living room interior", "kitchen interior", "dining table set", "coffee mug", "wine glass",
    "drinking glasses table", "sofa living room", "chair legs", "bookshelf room", "office interior",
    "Christmas tree decorations", "Christmas ornaments", "Christmas lights room", "lamp interior",
    "cafe interior people", "people walking street", "street traffic cars", "house garden",
    "playground", "tennis balls", "football ball grass", "plates on table", "oranges fruit",
    "street lights night", "power lines sky", "airplane in sky", "clay pigeon shooting shooter",
    "hunter with shotgun", "dog in field", "car dashboard",
]
NEGATIVE_PER_QUERY = 25
NEGATIVE_SHARE = 0.25          # share of images taken from the "not a clay" photos
NEGATIVE_WITH_CLAY = 0.3       # of those, how many still get a clay (clays seen in front of clutter)
DECOY_SHARE = 0.35             # share of the other images that get drawn round decoys (balls, rings…)

# Real clay colours (RGB): mostly fluorescent orange or black, some white, yellow, green, pink.
COLOURS = [((255, 96, 20), 30), ((245, 120, 30), 14), ((25, 25, 25), 22), ((240, 235, 225), 6),
           ((250, 220, 40), 6), ((60, 170, 70), 4), ((255, 90, 150), 4), ((210, 70, 30), 8)]


def http_json(url):
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    for attempt in range(4):
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                return json.load(r)
        except Exception as exc:  # network hiccups: retry
            print(f"  retry {attempt + 1}: {exc}")
            time.sleep(3 * (attempt + 1))
    return {}


def http_bytes(url):
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, timeout=40) as r:
                return r.read()
        except Exception as exc:
            print(f"  retry {attempt + 1}: {exc}")
            time.sleep(2 * (attempt + 1))
    return None


def strip_html(s):
    return re.sub(r"<[^>]+>", "", s or "").strip()


def fetch_backgrounds(queries, per_query, credits, seen):
    """Downloads free-licence photos from Wikimedia Commons. Returns a list of PIL images and adds
    their authors and licences to `credits`."""
    images = []
    for q in queries:
        params = {
            "action": "query", "format": "json", "generator": "search", "gsrnamespace": 6,
            "gsrsearch": f"{q} filetype:bitmap", "gsrlimit": per_query, "prop": "imageinfo",
            "iiprop": "url|mime|size|extmetadata", "iiurlwidth": 1280,
        }
        data = http_json("https://commons.wikimedia.org/w/api.php?" + urllib.parse.urlencode(params))
        pages = (data.get("query") or {}).get("pages", {})
        got = 0
        for page in pages.values():
            info = (page.get("imageinfo") or [{}])[0]
            if info.get("mime") not in ("image/jpeg", "image/png") or info.get("width", 0) < 800:
                continue
            meta = info.get("extmetadata", {})
            licence = strip_html(meta.get("LicenseShortName", {}).get("value", ""))
            if not re.search(r"CC|Public domain|PD", licence, re.I):
                continue
            url = info.get("thumburl") or info.get("url")
            if not url or url in seen:
                continue
            seen.add(url)
            raw = http_bytes(url)
            if not raw:
                continue
            try:
                img = Image.open(io.BytesIO(raw)).convert("RGB")
                img.thumbnail((960, 960))            # keeps ~900 photos within memory
            except Exception:
                continue
            images.append(img)
            credits.append([page.get("title", ""), strip_html(meta.get("Artist", {}).get("value", "")),
                            licence, info.get("descriptionurl", "")])
            got += 1
            time.sleep(0.2)
        print(f"{q}: {got} photos")
    return images


def write_credits(credits):
    CREDITS.parent.mkdir(parents=True, exist_ok=True)
    with CREDITS.open("w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["file", "author", "licence", "source"])
        w.writerows(credits)


def procedural_sky(rng):
    """Fallback background: vertical sky gradient with soft cloud noise and a dark ground band."""
    top = np.array([rng.uniform(60, 140), rng.uniform(110, 180), rng.uniform(170, 240)])
    bottom = np.array([rng.uniform(170, 230), rng.uniform(190, 235), rng.uniform(210, 250)])
    t = np.linspace(0, 1, SIZE)[:, None, None]
    img = top * (1 - t) + bottom * t
    img = np.repeat(img, SIZE, axis=1)
    noise = Image.fromarray((rng.random((40, 40)) * 255).astype(np.uint8)).resize((SIZE, SIZE), Image.BICUBIC)
    clouds = np.asarray(noise.filter(ImageFilter.GaussianBlur(20)), dtype=float)[..., None] / 255
    img = img * (1 - 0.5 * clouds) + 250 * 0.5 * clouds
    if rng.random() < 0.6:
        h = int(rng.uniform(0.6, 0.95) * SIZE)
        img[h:] = np.array([rng.uniform(40, 90), rng.uniform(60, 100), rng.uniform(30, 60)])
    return Image.fromarray(np.clip(img, 0, 255).astype(np.uint8))


def background_crop(backgrounds, rng, allow_sky=True):
    if not backgrounds or (allow_sky and rng.random() < 0.08):
        return procedural_sky(rng)
    img = backgrounds[rng.integers(len(backgrounds))]
    scale = SIZE / min(img.size) * rng.uniform(1.0, 1.8)
    w, h = int(img.width * scale) + 1, int(img.height * scale) + 1
    img = img.resize((w, h), Image.BILINEAR)
    x, y = rng.integers(0, w - SIZE + 1), rng.integers(0, h - SIZE + 1)
    crop = img.crop((x, y, x + SIZE, y + SIZE))
    if rng.random() < 0.5:
        crop = crop.transpose(Image.FLIP_LEFT_RIGHT)
    return crop


def pick_colour(rng):
    total = sum(w for _, w in COLOURS)
    r = rng.uniform(0, total)
    for c, w in COLOURS:
        r -= w
        if r <= 0:
            return np.array(c, dtype=float)
    return np.array(COLOURS[0][0], dtype=float)


def render_clay(diameter, rng, light):
    """RGBA patch of one clay, and the disc's box inside the patch (before blur)."""
    ss = 4                                       # supersampling
    d = diameter * ss
    # Seen from face-on (round) to edge-on (a thin lozenge: a clay is about 25 mm thick).
    tilt = rng.uniform(0, 85) if rng.random() < 0.85 else rng.uniform(80, 90)
    minor = max(0.24, abs(math.cos(math.radians(tilt)))) * d
    pad = int(d * 0.3) + 4
    W = H = int(d + 2 * pad)
    patch = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    draw = ImageDraw.Draw(patch)
    colour = pick_colour(rng) * light
    dark = np.clip(colour * 0.55, 0, 255)
    bright = np.clip(colour * 1.25 + 15, 0, 255)
    cx, cy = W / 2, H / 2
    box = (cx - d / 2, cy - minor / 2, cx + d / 2, cy + minor / 2)
    draw.ellipse(box, fill=tuple(int(v) for v in dark) + (255,))                # rim / shadow side
    inner = (cx - d * 0.42, cy - minor * 0.46, cx + d * 0.42, cy + minor * 0.30)
    draw.ellipse(inner, fill=tuple(int(v) for v in colour) + (255,))            # dome
    if minor > 0.35 * d:
        hl = (cx - d * 0.25, cy - minor * 0.38, cx + d * 0.18, cy - minor * 0.02)
        draw.ellipse(hl, fill=tuple(int(v) for v in bright) + (200,))           # light on the dome
    angle = rng.uniform(0, 180)
    patch = patch.rotate(angle, resample=Image.BICUBIC, expand=False)
    patch = patch.resize((max(3, W // ss), max(3, H // ss)), Image.LANCZOS)

    # Disc box after rotation (ellipse extents), in the downsampled patch.
    a, b, t = d / 2 / ss, minor / 2 / ss, math.radians(angle)
    half_w = math.sqrt((a * math.cos(t)) ** 2 + (b * math.sin(t)) ** 2)
    half_h = math.sqrt((a * math.sin(t)) ** 2 + (b * math.cos(t)) ** 2)
    pc = (patch.width / 2, patch.height / 2)
    return patch, (pc[0] - half_w, pc[1] - half_h, pc[0] + half_w, pc[1] + half_h)


def motion_blur(patch, length, angle, rng):
    """Smears the patch along its flight direction (sum of shifted copies)."""
    if length < 1:
        return patch, (0, 0)
    steps = max(2, int(length))
    dx, dy = math.cos(angle), math.sin(angle)
    pad = int(length) + 2
    big = Image.new("RGBA", (patch.width + 2 * pad, patch.height + 2 * pad), (0, 0, 0, 0))
    acc = np.zeros((big.height, big.width, 4), dtype=float)
    src = np.asarray(patch, dtype=float)
    for i in range(steps):
        s = (i / (steps - 1) - 0.5) * length
        ox, oy = int(round(pad + s * dx)), int(round(pad + s * dy))
        acc[oy:oy + patch.height, ox:ox + patch.width] += src
    acc /= steps
    return Image.fromarray(np.clip(acc, 0, 255).astype(np.uint8), "RGBA"), (pad, pad)


def place_clays(img, rng):
    labels = []
    n = rng.choice([1, 1, 1, 2, 2, 3])
    arr = np.asarray(img, dtype=float)
    for _ in range(n):
        # Mostly small (far) clays: log-uniform 5–90 px.
        diameter = math.exp(rng.uniform(math.log(5), math.log(90)))
        light = rng.uniform(0.7, 1.1) * (0.6 + 0.4 * arr.mean() / 160)
        patch, disc = render_clay(diameter, rng, light)
        blur_len = rng.uniform(0, 1.6) * diameter if rng.random() < 0.7 else 0
        patch, (ox, oy) = motion_blur(patch, blur_len, rng.uniform(0, math.pi), rng)
        disc = (disc[0] + ox, disc[1] + oy, disc[2] + ox, disc[3] + oy)
        if rng.random() < 0.4:
            patch = patch.filter(ImageFilter.GaussianBlur(rng.uniform(0.3, 1.2)))
        x = int(rng.uniform(-disc[0] + 2, SIZE - disc[2] - 2))
        y = int(rng.uniform(-disc[1] + 2, SIZE - disc[3] - 2))
        box = (x + disc[0], y + disc[1], x + disc[2], y + disc[3])
        if any(iou(box, other) > 0.1 for other in labels):
            continue
        img.paste(patch, (x, y), patch)
        labels.append(box)
    return img, labels


def render_decoy(size, rng, light):
    """RGBA patch of something round that is NOT a clay: a ball (always a full circle, shaded like
    a sphere), a ring or bauble outline, a plate (pale with a thin rim), a cup or glass seen from the
    side (taller than wide), or a soft glowing light."""
    ss = 4
    d = size * ss
    pad = int(d * 0.2) + 4
    W = H = int(d + 2 * pad)
    patch = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    draw = ImageDraw.Draw(patch)
    cx, cy = W / 2, H / 2
    kind = rng.choice(["ball", "ring", "plate", "cup", "glow"], p=[0.35, 0.15, 0.15, 0.2, 0.15])
    colour = np.array([rng.uniform(0, 255), rng.uniform(0, 255), rng.uniform(0, 255)]) * light
    if kind == "ball":
        # Radial shading from a highlight towards a dark edge: a sphere, never a flat disc.
        steps = 14
        hx, hy = rng.uniform(-0.25, 0.25) * d, rng.uniform(-0.3, 0.0) * d
        for i in range(steps):
            f = 1 - i / steps
            r = d / 2 * f
            shade = np.clip(colour * (0.45 + 0.75 * (1 - f)) + 40 * (1 - f) ** 3, 0, 255)
            ox, oy = hx * (1 - f), hy * (1 - f)
            draw.ellipse((cx + ox - r, cy + oy - r, cx + ox + r, cy + oy + r),
                         fill=tuple(int(v) for v in shade) + (255,))
    elif kind == "ring":
        width = max(ss, int(d * rng.uniform(0.04, 0.12)))
        draw.ellipse((cx - d / 2, cy - d / 2, cx + d / 2, cy + d / 2),
                     outline=tuple(int(v) for v in colour) + (255,), width=width)
    elif kind == "plate":
        minor = d * rng.uniform(0.3, 1.0)
        pale = np.clip(np.array([235, 232, 225]) * light, 0, 255)
        draw.ellipse((cx - d / 2, cy - minor / 2, cx + d / 2, cy + minor / 2),
                     fill=tuple(int(v) for v in pale) + (255,),
                     outline=tuple(int(v) for v in colour) + (255,), width=max(ss, int(d * 0.03)))
    elif kind == "cup":
        cw = d * rng.uniform(0.45, 0.65)
        alpha = 255 if rng.random() < 0.6 else 110            # mug, or a see-through glass
        draw.rectangle((cx - cw / 2, cy - d / 2 + cw * 0.15, cx + cw / 2, cy + d / 2),
                       fill=tuple(int(v) for v in colour) + (alpha,))
        draw.ellipse((cx - cw / 2, cy - d / 2, cx + cw / 2, cy - d / 2 + cw * 0.3),
                     fill=tuple(int(v * 0.7) for v in colour) + (alpha,))
    else:  # glow
        for i in range(10):
            r = d / 2 * (1 - i / 10)
            a = int(25 + 23 * i)
            draw.ellipse((cx - r, cy - r, cx + r, cy + r),
                         fill=(255, int(220 + 3 * i), int(150 + 10 * i), min(255, a)))
    patch = patch.rotate(rng.uniform(-25, 25), resample=Image.BICUBIC, expand=False)
    return patch.resize((max(3, W // ss), max(3, H // ss)), Image.LANCZOS)


def place_decoys(img, rng, avoid):
    for _ in range(rng.choice([1, 1, 2, 3])):
        size = math.exp(rng.uniform(math.log(6), math.log(120)))
        light = rng.uniform(0.6, 1.1)
        patch = render_decoy(size, rng, light)
        if rng.random() < 0.3:
            patch = patch.filter(ImageFilter.GaussianBlur(rng.uniform(0.3, 1.5)))
        x = int(rng.uniform(0, SIZE - patch.width))
        y = int(rng.uniform(0, SIZE - patch.height))
        box = (x, y, x + patch.width, y + patch.height)
        if any(iou(box, other) > 0.0 for other in avoid):
            continue                                   # never cover a labelled clay
        img.paste(patch, (x, y), patch)
    return img


def iou(a, b):
    ix = max(0, min(a[2], b[2]) - max(a[0], b[0]))
    iy = max(0, min(a[3], b[3]) - max(a[1], b[1]))
    inter = ix * iy
    union = (a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - inter
    return inter / union if union > 0 else 0


def finish(img, rng):
    """Camera-like degradation: exposure, contrast, sensor noise, defocus, JPEG."""
    img = ImageEnhance.Brightness(img).enhance(rng.uniform(0.75, 1.2))
    img = ImageEnhance.Contrast(img).enhance(rng.uniform(0.8, 1.15))
    if rng.random() < 0.3:
        img = img.filter(ImageFilter.GaussianBlur(rng.uniform(0.3, 0.9)))
    arr = np.asarray(img, dtype=float)
    arr += rng.normal(0, rng.uniform(1, 6), arr.shape)
    img = Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8))
    buf = io.BytesIO()
    img.save(buf, "JPEG", quality=int(rng.uniform(55, 95)))
    return Image.open(io.BytesIO(buf.getvalue())).convert("RGB")


def write_split(name, count, backgrounds, negatives, rng):
    (OUT / "images" / name).mkdir(parents=True, exist_ok=True)
    (OUT / "labels" / name).mkdir(parents=True, exist_ok=True)
    boxes = 0
    for i in range(count):
        labels = []
        if negatives and rng.random() < NEGATIVE_SHARE:
            # Household / clutter photo: mostly no clay at all.
            img = background_crop(negatives, rng, allow_sky=False)
            if rng.random() < NEGATIVE_WITH_CLAY:
                img, labels = place_clays(img, rng)
        else:
            img = background_crop(backgrounds, rng)
            if rng.random() > 0.12:                   # 12 % of sky images have no clay at all
                img, labels = place_clays(img, rng)
            if rng.random() < DECOY_SHARE:
                img = place_decoys(img, rng, labels)
        img = finish(img, rng)
        img.save(OUT / "images" / name / f"{i:05d}.jpg", quality=92)
        with open(OUT / "labels" / name / f"{i:05d}.txt", "w") as f:
            for x1, y1, x2, y2 in labels:
                x1, y1, x2, y2 = max(0, x1), max(0, y1), min(SIZE, x2), min(SIZE, y2)
                f.write(f"0 {(x1 + x2) / 2 / SIZE:.6f} {(y1 + y2) / 2 / SIZE:.6f} "
                        f"{(x2 - x1) / SIZE:.6f} {(y2 - y1) / SIZE:.6f}\n")
        boxes += len(labels)
    return boxes


def main():
    n_train = int(sys.argv[1]) if len(sys.argv) > 1 else 2400
    n_val = int(sys.argv[2]) if len(sys.argv) > 2 else 300
    rng = np.random.default_rng(7)
    credits, seen = [], set()
    backgrounds = fetch_backgrounds(QUERIES, PER_QUERY, credits, seen)
    negatives = fetch_backgrounds(NEGATIVE_QUERIES, NEGATIVE_PER_QUERY, credits, seen)
    write_credits(credits)
    print(f"{len(backgrounds)} background photos, {len(negatives)} 'not a clay' photos")
    random.Random(7).shuffle(backgrounds)
    random.Random(8).shuffle(negatives)
    cut = max(1, len(backgrounds) // 8)
    ncut = max(1, len(negatives) // 8) if negatives else 0
    val_bg, train_bg = backgrounds[:cut], backgrounds[cut:]     # val uses unseen photos
    val_neg, train_neg = negatives[:ncut], negatives[ncut:]
    stats = {
        "backgrounds": len(backgrounds), "negative_photos": len(negatives),
        "train_images": n_train, "train_boxes": write_split("train", n_train, train_bg, train_neg, rng),
        "val_images": n_val, "val_boxes": write_split("val", n_val, val_bg, val_neg, rng),
    }
    (OUT / "data.yaml").write_text(f"path: {OUT}\ntrain: images/train\nval: images/val\nnames:\n  0: clay\n")
    Path("models").mkdir(exist_ok=True)
    Path("models/clay_dataset.json").write_text(json.dumps(stats, indent=2))
    print(stats)


if __name__ == "__main__":
    main()
