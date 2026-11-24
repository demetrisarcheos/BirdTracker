# Bird Tracker (iOS)

A native iOS app (Swift, SwiftUI, AVFoundation, Vision, Core ML, Core Motion) that detects birds
in the live camera feed with **YOLO26** and shows each bird's **distance, speed and flight direction**
on screen.

## What you need

| | |
|---|---|
| Mac with **Xcode 16 or later** | iOS apps can only be built and signed on macOS (a cloud Mac or a CI service with macOS runners also works) |
| iPhone running **iOS 17+** | The simulator has no camera, so test on a real phone |
| Apple ID | A free account can install to your own phone; publishing to the App Store needs the paid developer programme |
| Python 3.10+ on macOS or Linux/WSL | Only to export the YOLO26 model once |

## Build steps

```bash
# 1. Export YOLO26 to Core ML (macOS or Linux/WSL)
pip install -U ultralytics coremltools "numpy<2.0"
python scripts/export_yolo26.py          # writes BirdTracker/Models/yolo26n.mlpackage

# 2. Generate the Xcode project (on the Mac)
brew install xcodegen
xcodegen generate
open BirdTracker.xcodeproj
```

3. In Xcode select the **BirdTracker** target › *Signing & Capabilities*, choose your team and
   change the bundle ID if needed.
4. Plug in the iPhone, select it as the run destination, press **Run**.

If `yolo26n.mlpackage` does not show up under *Models* in Xcode, drag it into the project and tick
the BirdTracker target.

## Project layout

```
BirdTracker/
  App/          BirdTrackerApp.swift, AppSettings.swift (bird-size presets, units)
  Camera/       CameraManager.swift (capture + focal length), CameraPreview.swift
  Sensors/      MotionProvider.swift (phone orientation + compass)
  Detection/    BirdDetector.swift (YOLO26 via Vision; handles all export layouts)
  Tracking/     CameraGeometry.swift, KalmanCV3D.swift, MultiBirdTracker.swift
  Engine/       BirdTrackingEngine.swift (camera → detector → tracker → UI)
  UI/           ContentView, HUDView, SettingsView, Formatting
  Models/       put yolo26n.mlpackage here
scripts/export_yolo26.py
project.yml     XcodeGen project definition
```

## How the measurements work

**1. Detection.** Each frame goes through YOLO26 (COCO weights, class 14 = *bird*). YOLO26 is
NMS-free, so its `[N, 6]` output is used directly; older-style outputs are also supported.

**2. Distance — from apparent size.** One camera cannot see depth, so the app uses the pinhole
camera model:

```
distance ≈ focal_length_px × real_wingspan_m / bird_size_px
```

The focal length comes from the per-frame camera intrinsics iOS provides (falling back to the lens
field of view). The bird's real size comes from the **size class you pick in Settings** (sparrow …
eagle). The box size is median-filtered over ~15 frames to cancel out wing beats.
*Accuracy is only as good as the chosen size: a 20 % size error gives a 20 % distance and speed error.*

**3. 3D position in the real world.** The bird's pixel position plus distance gives a 3D point in
camera coordinates. Core Motion's attitude (gyro + accelerometer + magnetometer) rotates it into a
world frame (north / west / up). Because of this, **panning the phone to follow a bird does not count
as bird movement.**

**4. Speed and direction — Kalman filter.** Each bird has a 3D constant-velocity Kalman filter. It
trusts sideways motion (precise) much more than motion along the line of sight (noisy, size-based).
From the filtered velocity the app shows:

- **Speed** — total 3D speed (km/h, m/s or mph)
- **Direction** — compass heading of flight, e.g. `NE 47°` (magnetic), with a north-up arrow
- **Climbing / descending** rate, **height** above you, and **toward / away** speed

Values appear after ~0.4 s of tracking; birds are identified with `#ID` labels and the nearest one
(yellow box) is shown in the bottom panel.

**5. Species recognition.** About twice a second, a square crop around each bird is classified by
a second model, [chriamue/bird-species-classifier](https://huggingface.co/chriamue/bird-species-classifier)
(EfficientNet-B2, 525 species, MIT licence), exported by `scripts/export_species.py` as
`BirdSpecies.mlpackage`. Guesses are averaged over the last ~8 classifications. The species name shows
from 30 % confidence. From 60 % the app replaces the preset with that species' typical wingspan
(`SpeciesWingspan.swift`) and restarts the bird's filter, so the change in scale isn't counted as
movement. The classifier was trained on close-up photos, so expect it to work best on birds that
fill a good part of the frame. Turn it off in Settings › Species.

## Tips and limits

- Keep zoom at 1× (the code locks it) — zoom changes the focal length.
- If directions look wrong, calibrate the compass (wave the phone in a figure-8). Away from
  metal/magnets heading is typically within a few degrees.
- Distant birds that are only a few pixels wide may not be detected; `yolo26s` detects small birds
  better at some frame-rate cost.
- Flocks: each bird is tracked separately, but overlapping birds can swap IDs.
- For better accuracy on a specific species, fine-tune YOLO26 on a bird dataset and pick the matching
  size preset.

## Status

Built by GitHub Actions (`.github/workflows/build-ios.yml`) on every push to `main`. The unsigned IPA
is installed with Sideloadly on Windows (no Mac needed). Detection, distance and speed have been tested
on an iPhone with a bird picture. Real birds and species recognition have not been tested yet.
