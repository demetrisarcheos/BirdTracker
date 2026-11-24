"""
Export Ultralytics YOLO26 to Core ML for the BirdTracker iOS app.

Run on macOS or Linux/WSL (coremltools does not support native Windows):

    pip install -U ultralytics coremltools
    python scripts/export_yolo26.py            # yolo26n (fastest, recommended)
    python scripts/export_yolo26.py yolo26s    # more accurate on small/distant birds

The resulting .mlpackage is copied to BirdTracker/Models/. The app detects the COCO
"bird" class (index 14), so the stock COCO weights work out of the box. To use your own
bird-only fine-tuned weights, pass the path to your .pt file instead and make sure
"bird" stays class 14, or change BirdDetector.cocoBirdClass.
"""
import shutil
import sys
from pathlib import Path

from ultralytics import YOLO

weights = sys.argv[1] if len(sys.argv) > 1 else "yolo26n"
if not weights.endswith(".pt"):
    weights += ".pt"

model = YOLO(weights)  # downloads official weights on first use

try:
    # Adds a Vision-friendly NMS pipeline where supported. YOLO26 is NMS-free
    # (end-to-end) so Ultralytics may ignore or reject this flag.
    exported = model.export(format="coreml", imgsz=640, half=True, nms=True)
except Exception as exc:  # noqa: BLE001
    print(f"nms=True export failed ({exc}); exporting the end-to-end model instead.")
    exported = model.export(format="coreml", imgsz=640, half=True)

src = Path(exported)
dest_dir = Path(__file__).resolve().parents[1] / "BirdTracker" / "Models"
dest_dir.mkdir(parents=True, exist_ok=True)
dest = dest_dir / src.name
if dest.exists():
    shutil.rmtree(dest)
shutil.copytree(src, dest)
print(f"Copied {src} -> {dest}")
