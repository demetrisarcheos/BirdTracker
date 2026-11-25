"""
Build the Cyprus bird-species training set from iNaturalist.

Classes: Wood Pigeon, Song Thrush, Chukar Partridge, Eurasian Skylark, Hooded Crow, Other Bird.

For every photo the stock YOLO26 detector finds the bird and the crop is made exactly the way
the app crops it (square, 1.3x margin, stretched to 224x224), so training matches what the model
sees on the phone. Crops with a wide box (wings spread → usually in flight) are preferred, and
part of the training images get extra copies that are blurred/downscaled to mimic distant,
moving birds.

Output:
    dataset/train/<class>/*.jpg, dataset/val/<class>/*.jpg
    models/species_photo_credits.csv   (photo licence + attribution for every image used)

Usage:  python training/build_dataset.py
"""
import csv
import io
import json
import random
import sys
import time
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from PIL import Image, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "dataset"
CREDITS = ROOT / "models" / "species_photo_credits.csv"

API = "https://api.inaturalist.org/v1"
HEADERS = {"User-Agent": "BirdTrackerDatasetBuilder/1.0"}
LICENSES = "cc0,cc-by,cc-by-nc,cc-by-sa,cc-by-nc-sa,cc-by-nd,cc-by-nc-nd"

TARGETS = {
    "Wood Pigeon": "Columba palumbus",
    "Song Thrush": "Turdus philomelos",
    "Chukar Partridge": "Alectoris chukar",
    "Eurasian Skylark": "Alauda arvensis",
    "Hooded Crow": "Corvus cornix",
}
# Look-alikes that must end up in "Other Bird" rather than being mistaken for a target.
CONFUSERS = [
    "Columba livia", "Streptopelia decaocto", "Spilopelia senegalensis", "Columba oenas",
    "Turdus viscivorus", "Turdus merula", "Turdus pilaris", "Turdus iliacus",
    "Galerida cristata", "Lullula arborea", "Melanocorypha calandra", "Calandrella brachydactyla",
    "Francolinus francolinus", "Alectoris graeca", "Coturnix coturnix",
    "Corvus monedula", "Corvus corone", "Corvus frugilegus", "Corvus corax", "Pica pica",
    "Garrulus glandarius", "Sturnus vulgaris",
]
OTHER = "Other Bird"

KEEP_PER_CLASS = 700        # images kept per target species
CANDIDATES_PER_CLASS = 1400 # photos downloaded per target species (best ones kept)
PER_CONFUSER = 60           # photos per look-alike species in "Other Bird"
OTHER_RANDOM = 900          # random Cyprus bird photos (non-target) in "Other Bird"
VAL_FRACTION = 0.15
AUG_FRACTION = 0.35         # share of training crops that get an extra blurred copy
CROP_SIZE = 224
WIDE_ASPECT = 1.35          # box width / height above this ≈ wings spread

random.seed(42)
_last_call = 0.0


def api(path, **params):
    """iNaturalist API call, rate-limited to ~1 request/second as iNaturalist asks."""
    global _last_call
    url = f"{API}/{path}?{urllib.parse.urlencode(params)}"
    for attempt in range(5):
        wait = 1.1 - (time.time() - _last_call)
        if wait > 0:
            time.sleep(wait)
        _last_call = time.time()
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers=HEADERS), timeout=60) as r:
                return json.load(r)
        except Exception as exc:  # noqa: BLE001
            print(f"  API retry {attempt + 1}: {exc}")
            time.sleep(5 * (attempt + 1))
    raise RuntimeError(f"iNaturalist API failed: {url}")


def taxon_id(scientific_name):
    for t in api("taxa", q=scientific_name, rank="species", per_page=10)["results"]:
        if t["name"].lower() == scientific_name.lower():
            return t["id"]
    raise RuntimeError(f"Taxon not found: {scientific_name}")


def cyprus_place_ids():
    ids = [p["id"] for p in api("places/autocomplete", q="Cyprus", per_page=10)["results"]
           if p.get("admin_level") == 0 and "cyprus" in p.get("display_name", "").lower()]
    if not ids:
        raise RuntimeError("Cyprus place not found")
    return ",".join(str(i) for i in ids)


def collect_photos(limit, photos_per_obs=2, **filters):
    """Photo records (url, ids, licence, attribution) from research-grade observations."""
    out, page = [], 1
    while len(out) < limit and page <= 50:
        res = api("observations", quality_grade="research", photos="true", photo_license=LICENSES,
                  per_page=200, page=page, order_by="id", order="desc", **filters)
        if not res["results"]:
            break
        for obs in res["results"]:
            # Extra photos of one observation are often flight shots.
            for photo in obs.get("photos", [])[:photos_per_obs]:
                if not photo.get("license_code") or "square" not in photo.get("url", ""):
                    continue
                out.append({
                    "obs": obs["id"],
                    "photo": photo["id"],
                    "url": photo["url"].replace("square", "medium"),
                    "license": photo["license_code"],
                    "attribution": photo.get("attribution", ""),
                    "taxon": (obs.get("taxon") or {}).get("name", ""),
                })
        page += 1
    random.shuffle(out)
    return out[:limit]


def download(rec):
    for attempt in range(3):
        try:
            with urllib.request.urlopen(urllib.request.Request(rec["url"], headers=HEADERS), timeout=60) as r:
                return rec, Image.open(io.BytesIO(r.read())).convert("RGB")
        except Exception:  # noqa: BLE001
            time.sleep(2 * (attempt + 1))
    return rec, None


def app_crop(img, box):
    """Same crop as SpeciesClassifier.swift: square, 1.3x margin, clipped, stretched."""
    x1, y1, x2, y2 = box
    side = max(x2 - x1, y2 - y1) * 1.3
    cx, cy = (x1 + x2) / 2, (y1 + y2) / 2
    left, top = max(0, cx - side / 2), max(0, cy - side / 2)
    right, bottom = min(img.width, cx + side / 2), min(img.height, cy + side / 2)
    return img.crop((int(left), int(top), int(right), int(bottom))).resize((CROP_SIZE, CROP_SIZE), Image.BILINEAR)


def degrade(img):
    """Mimic a distant or moving bird: downscale, then blur or motion-blur."""
    small = random.randint(40, 110)
    out = img.resize((small, small), Image.BILINEAR).resize((CROP_SIZE, CROP_SIZE), Image.BILINEAR)
    if random.random() < 0.5:
        out = out.filter(ImageFilter.GaussianBlur(random.uniform(0.4, 1.4)))
    else:
        horizontal = random.random() < 0.7
        k = [0] * 25
        for i in range(5):
            k[(2 * 5 + i) if horizontal else (i * 5 + 2)] = 1
        out = out.filter(ImageFilter.Kernel((5, 5), k, scale=5))
    return out


def crops_for(records, detector, label):
    """Download, detect the bird, crop. Returns list of (record, crop, is_wide)."""
    print(f"[{label}] downloading {len(records)} photos")
    with ThreadPoolExecutor(8) as pool:
        downloaded = [(r, im) for r, im in pool.map(download, records) if im is not None]
    results = []
    for i in range(0, len(downloaded), 32):
        chunk = downloaded[i:i + 32]
        preds = detector.predict([im for _, im in chunk], classes=[14], conf=0.25, imgsz=640, verbose=False)
        for (rec, im), pred in zip(chunk, preds):
            boxes = pred.boxes
            if boxes is None or len(boxes) == 0:
                continue
            xyxy = boxes.xyxy.cpu().numpy()
            areas = (xyxy[:, 2] - xyxy[:, 0]) * (xyxy[:, 3] - xyxy[:, 1])
            x1, y1, x2, y2 = xyxy[areas.argmax()].tolist()
            if min(x2 - x1, y2 - y1) < 24:
                continue
            results.append((rec, app_crop(im, (x1, y1, x2, y2)), (x2 - x1) / max(1.0, y2 - y1) > WIDE_ASPECT))
    print(f"[{label}] {len(results)} usable crops, {sum(w for *_, w in results)} wide (flight-like)")
    return results


def save_class(label, items, writer):
    """Split by observation (no leakage), save, add degraded copies to train."""
    obs_ids = sorted({rec["obs"] for rec, *_ in items})
    random.shuffle(obs_ids)
    val_obs = set(obs_ids[:max(1, int(len(obs_ids) * VAL_FRACTION))])
    counts = {"train": 0, "val": 0}
    for rec, crop, _ in items:
        split = "val" if rec["obs"] in val_obs else "train"
        folder = OUT / split / label
        folder.mkdir(parents=True, exist_ok=True)
        crop.save(folder / f"{rec['photo']}.jpg", quality=92)
        counts[split] += 1
        if split == "train" and random.random() < AUG_FRACTION:
            degrade(crop).save(folder / f"{rec['photo']}_d.jpg", quality=85)
            counts["train"] += 1
        writer.writerow([label, rec["taxon"], rec["photo"],
                         f"https://www.inaturalist.org/observations/{rec['obs']}",
                         rec["license"], rec["attribution"]])
    print(f"[{label}] saved train={counts['train']} val={counts['val']}")
    return counts


def main():
    from ultralytics import YOLO

    detector = YOLO("yolo26n.pt")
    CREDITS.parent.mkdir(parents=True, exist_ok=True)
    summary = {}
    target_ids = {}

    with open(CREDITS, "w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow(["class", "taxon", "photo_id", "observation", "license", "attribution"])

        for label, sci in TARGETS.items():
            tid = taxon_id(sci)
            target_ids[label] = tid
            crops = crops_for(collect_photos(CANDIDATES_PER_CLASS, taxon_id=tid), detector, label)
            crops.sort(key=lambda c: not c[2])        # flight-like crops first
            summary[label] = save_class(label, crops[:KEEP_PER_CLASS], writer)

        other = []
        for sci in CONFUSERS:
            try:
                other += collect_photos(PER_CONFUSER, photos_per_obs=1, taxon_id=taxon_id(sci))
            except RuntimeError as exc:
                print(f"  skipping {sci}: {exc}")
        exclude = ",".join(str(i) for i in target_ids.values())
        other += collect_photos(OTHER_RANDOM, photos_per_obs=1, taxon_id=3,   # 3 = all birds
                                place_id=cyprus_place_ids(), without_taxon_id=exclude)
        seen, unique = set(), []
        for rec in other:
            if rec["photo"] not in seen:
                seen.add(rec["photo"])
                unique.append(rec)
        summary[OTHER] = save_class(OTHER, crops_for(unique, detector, OTHER), writer)

    (ROOT / "models" / "species_dataset.json").write_text(json.dumps(summary, indent=2))
    print(json.dumps(summary, indent=2))
    if any(c["val"] < 20 for c in summary.values()):
        sys.exit("Too few images for at least one class")


if __name__ == "__main__":
    main()
