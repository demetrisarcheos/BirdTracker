"""
Export the bird-species classifier to Core ML for the BirdTracker iOS app.

Model: chriamue/bird-species-classifier (Hugging Face, MIT licence)
       EfficientNet-B2 fine-tuned on 525 bird species, 260x260 input.

Run on macOS or Linux/WSL:

    pip install -U transformers torch coremltools "numpy<2.0"
    python scripts/export_species.py

Writes BirdTracker/Models/BirdSpecies.mlpackage — a Core ML *classifier*, so Vision returns
VNClassificationObservation objects with the species names as labels.
"""
from pathlib import Path

import coremltools as ct
import torch
from transformers import AutoModelForImageClassification

REPO = "chriamue/bird-species-classifier"
SIZE = 260
# From the model's preprocessor_config.json (rescale 1/255, then normalise).
MEAN = [0.485, 0.456, 0.406]
STD = [0.47853944, 0.4732864, 0.47434163]

model = AutoModelForImageClassification.from_pretrained(REPO, torchscript=True).eval()
labels = [model.config.id2label[i] for i in range(model.config.num_labels)]


class Wrapper(torch.nn.Module):
    """Takes RGB in 0..1, normalises, returns softmax probabilities."""

    def __init__(self, net):
        super().__init__()
        self.net = net
        self.register_buffer("mean", torch.tensor(MEAN).view(1, 3, 1, 1))
        self.register_buffer("std", torch.tensor(STD).view(1, 3, 1, 1))

    def forward(self, x):
        logits = self.net((x - self.mean) / self.std)[0]
        return torch.softmax(logits, dim=-1)


wrapper = Wrapper(model).eval()
example = torch.rand(1, 3, SIZE, SIZE)
with torch.no_grad():
    traced = torch.jit.trace(wrapper, example, strict=False)

mlmodel = ct.convert(
    traced,
    inputs=[ct.ImageType(name="image", shape=example.shape, scale=1 / 255.0,
                         color_layout=ct.colorlayout.RGB)],
    classifier_config=ct.ClassifierConfig(labels),
    convert_to="mlprogram",
    minimum_deployment_target=ct.target.iOS17,
    compute_precision=ct.precision.FLOAT16,
)
mlmodel.short_description = "Bird species classifier (525 species) - chriamue/bird-species-classifier"

dest = Path(__file__).resolve().parents[1] / "BirdTracker" / "Models" / "BirdSpecies.mlpackage"
dest.parent.mkdir(parents=True, exist_ok=True)
mlmodel.save(str(dest))
print(f"Saved {dest} ({len(labels)} species)")
