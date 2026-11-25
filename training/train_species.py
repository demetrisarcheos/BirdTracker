"""
Train the Cyprus species classifier (YOLO26n-cls) on dataset/ and export it to Core ML.

Output:
    models/BirdSpecies.mlpackage   (Core ML classifier the app loads)
    models/species_report.json     (validation accuracy, overall and per class)

Usage:  python training/train_species.py [epochs]
"""
import json
import shutil
import sys
from pathlib import Path

from ultralytics import YOLO

ROOT = Path(__file__).resolve().parents[1]
DATA = ROOT / "dataset"
MODELS = ROOT / "models"
EPOCHS = int(sys.argv[1]) if len(sys.argv) > 1 else 30
IMGSZ = 224


def load_base():
    for name in ("yolo26n-cls.pt", "yolo11n-cls.pt"):
        try:
            return YOLO(name), name
        except Exception as exc:  # noqa: BLE001
            print(f"Could not load {name}: {exc}")
    sys.exit("No classification base model available")


model, base = load_base()
model.train(
    data=str(DATA), epochs=EPOCHS, imgsz=IMGSZ, batch=64, device="cpu", workers=4,
    patience=8, project=str(ROOT / "runs"), name="species", exist_ok=True, plots=False,
    fliplr=0.5, erasing=0.2,
)

best = YOLO(model.trainer.best)
metrics = best.val(data=str(DATA), imgsz=IMGSZ, split="val", device="cpu", plots=False)

names = best.names
per_class = {}
try:
    matrix = metrics.confusion_matrix.matrix      # rows = predicted, columns = true
    for i, name in names.items():
        total = matrix[:, i].sum()
        per_class[name] = round(float(matrix[i, i] / total) * 100, 1) if total else None
except Exception as exc:  # noqa: BLE001  (report only; never block the export)
    print(f"Per-class accuracy unavailable: {exc}")

report = {
    "base_model": base,
    "epochs_requested": EPOCHS,
    "top1_accuracy_pct": round(float(metrics.top1) * 100, 1),
    "per_class_accuracy_pct": per_class,
}
print(json.dumps(report, indent=2))

exported = Path(best.export(format="coreml", imgsz=IMGSZ, half=True))
MODELS.mkdir(exist_ok=True)
dest = MODELS / "BirdSpecies.mlpackage"
if dest.exists():
    shutil.rmtree(dest)
shutil.copytree(exported, dest)
(MODELS / "species_report.json").write_text(json.dumps(report, indent=2))
print(f"Saved {dest}")
