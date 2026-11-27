"""Fine-tunes YOLO26n (COCO weights) into a one-class clay-target detector on CPU, exports it
to Core ML and writes models/ClayDetector.mlpackage plus models/clay_report.json.

Usage: python training/clays/train_clay.py [epochs] [max_hours]
"""

import json
import shutil
import sys
from pathlib import Path

from ultralytics import YOLO

epochs = int(sys.argv[1]) if len(sys.argv) > 1 else 30
hours = float(sys.argv[2]) if len(sys.argv) > 2 else 4.0

model = YOLO("yolo26n.pt")      # COCO weights; the clay detector is retrained from these each time
model.train(
    data="/tmp/clays/data.yaml",
    epochs=epochs,
    time=hours,            # hard stop so the job fits GitHub's 6-hour limit
    imgsz=640,             # small, distant clays need the full input size
    batch=16,
    device="cpu",
    workers=4,
    patience=100,
    project="/tmp/clay_runs",
    name="clay",
    exist_ok=True,
    plots=False,
    fliplr=0.5,
    scale=0.4,             # keep tiny clays from vanishing
    mosaic=1.0,
    close_mosaic=3,
)

best = YOLO("/tmp/clay_runs/clay/weights/best.pt")
metrics = best.val(data="/tmp/clays/data.yaml", imgsz=640, device="cpu", plots=False)

try:
    exported = best.export(format="coreml", imgsz=640, half=True, nms=True)
except Exception as exc:  # some versions cannot add NMS to end-to-end models
    print(f"nms=True export failed ({exc}); exporting the end-to-end model instead.")
    exported = best.export(format="coreml", imgsz=640, half=True)

dest = Path("models/ClayDetector.mlpackage")
if dest.exists():
    shutil.rmtree(dest)
shutil.copytree(exported, dest)

report = {
    "base_model": "yolo26n.pt",
    "negatives": "household/clutter photos and drawn decoys (balls, rings, plates, cups, lights)",
    "epochs_requested": epochs,
    "mAP50_pct": round(float(metrics.box.map50) * 100, 1),
    "mAP50_95_pct": round(float(metrics.box.map) * 100, 1),
    "precision_pct": round(float(metrics.box.mp) * 100, 1),
    "recall_pct": round(float(metrics.box.mr) * 100, 1),
    "note": "Validation images are synthetic (clays drawn onto unseen photos); real-world accuracy will be lower.",
}
Path("models/clay_report.json").write_text(json.dumps(report, indent=2))
print(report)
