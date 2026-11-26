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

**5. Species recognition (Cyprus model).** About 5 times a second, a square crop around each bird
is classified by a small YOLO26n-cls model trained for this app on **Wood Pigeon, Song Thrush, Chukar
Partridge, Eurasian Skylark and Hooded Crow**, plus **Other Bird** for everything else.
Guesses are averaged over about the last 1.2 s. The name shows from the first guess at 50 %+. From
60 % (and at least 2 guesses) the app replaces the preset with that species' typical wingspan
(`SpeciesWingspan.swift`) and restarts the bird's filter, so the change in scale isn't counted as
movement. Turn it off in Settings › Species.

How the model is made (`.github/workflows/train-species.yml`, CPU only, on GitHub):
1. `training/build_dataset.py` downloads research-grade, Creative-Commons photos from iNaturalist
   for each species, plus look-alikes (Rock dove, Collared dove, Mistle thrush, Blackbird, Crested
   lark, Black francolin, Jackdaw, Carrion crow…) and random Cyprus birds for *Other Bird*.
2. The stock YOLO26 detector finds the bird in every photo, and the crop is made exactly as the app
   crops it. Wide boxes (wings spread, usually in flight) are preferred, and a third of the training
   crops get extra blurred/downscaled copies to mimic distant, moving birds.
3. `training/train_species.py` fine-tunes YOLO26n-cls, reports accuracy, exports Core ML and commits
   `models/BirdSpecies.mlpackage`. The iOS build then runs automatically and bundles it.

To add or change species, edit `TARGETS` in `build_dataset.py` and the wingspans in
`SpeciesWingspan.swift`, then push. Photo credits and licences are listed in
`models/species_photo_credits.csv`. Several photos are CC BY-NC (non-commercial), so check this
before selling the app.

**6. Hunting simulation — lead, ballistics and the Shoot button.** The reticle is the gun barrel.
For the bird in the sights (the one whose aiming point is nearest the reticle) the app works out
where a shot fired now would have to go, and what it would do (`Hunting/Ballistics.swift`,
`Tracking/LeadSolver.swift`):

- **Your gear** (Settings › Hunting simulation): shotgun brand/model (fills in typical barrel
  lengths and how its chokes are marked: stars/notches, letters or mm), barrel length, the choke
  fitted (both barrels on an over & under), and your cartridges: load (g), shot number / pellet
  diameter (Italian scale), material (lead, steel, bismuth, tungsten) and speed as printed on the
  box (V0, V1 or V2.5). Cartridges can be **scanned from the box** with the camera (on-device text
  recognition reads load, shot size, speed, material and brand; you check them before saving).
- **Pellet ballistics:** the flight of one pellet is integrated numerically with sphere drag
  (Cd 0.47 subsonic rising to 0.95 above the speed of sound), from the box speed corrected for
  barrel length (≈0.5 m/s per cm vs a 76 cm test barrel). This gives travel time, remaining speed
  and energy at any range (e.g. 32 g No.7½ at 400 m/s: ≈215 m/s and 1.8 J at 30 m).
- **Target on the bird:** the head, neck and chest, not the middle of the box, which is mostly
  wings and lower body. It is marked with a small yellow dot.
  - Flying: moved from the centre about a third of the way to the box's front edge, in the
    direction of flight (birds fly head first). The shift shrinks when the bird flies towards or
    away from you, because its head is then near the centre.
  - Perched: a quarter of the box height above the centre, whichever way the bird faces.
  - The kill zone is centred on this point.
- **Meeting point** = target point + velocity × travel time (iterated), raised by pellet drop.
- **Pattern:** a Gaussian pellet cloud sized from the choke's standard 40-yard pattern percentage
  (Cyl 40 % … Full 70 % in a 76 cm circle; steel patterns tighter).
- **Kill model:** expected pellets on the bird = pellet count × pattern density × the bird's
  presented area (from its wingspan). A clean kill needs ≥ 2 pellets in the vitals, each with
  enough energy for that bird size (≈0.35 J thrush … ≈1.25 J crow).

The round button gets more opaque as the reticle nears the aiming point and turns solid red with
**SHOOT** when a shot fired now would kill cleanly ≥ 80 % of the time; it shows **TOO FAR** when
even a centred shot could not. Tapping it fires a simulated shot: pellet counts are drawn at
random around the expected values, so the result is a clean kill, a wounded bird, or a miss
(with "behind / ahead / high / low"), with a shotgun sound. Aiming beeps work like a car parking
sensor: silent when far off, faster beeps as the reticle closes in, a steady tone at the shooting
point. Both sounds are synthesised in code and muted when the phone is on silent (ambient audio).
Double guns fire barrel 1, then barrel 2. A red ring shows
the aiming point (can be turned off for a harder game). The gun list and generic cartridges are
typical values, and the whole model is a simplified simulation for practice, not a real
ballistics tool.

### 6b. Frame rate and centre zoom

- **Frame rate:** the phone camera runs at up to 60 fps (30 fps when the phone is hot or the light is
  poor). The detector skips frames it cannot keep up with. The top bar shows frames analysed per
  second and the phone's time per frame.
- **Centre zoom:** the full frame is shrunk to the model's 640-px input, so a far bird becomes a few
  pixels. A second pass runs the model on a 640-px square around the reticle at native resolution,
  which gives about 3× the detection range there and a sharper box, so a better distance.
  - Zoomed detections replace full-frame ones of the same bird.
  - Boxes cut by the square's edge are ignored, and the full frame covers those birds.
  - The square is drawn faintly on screen.

### 6c. Perched birds and zoom

- **Perched test:** the velocity is split into two parts. Movement across the view is measured
  precisely from the image position. Movement towards or away is measured poorly, from the bird's
  size. Each part counts only when it is clearly above its noise:
  - across the view: above 0.8 m/s and 3σ;
  - towards or away: above 3 m/s and 3σ, and confirmed by a 1-second straight-line fit of the
    measured distance.

  If neither part counts, the bird shows **perched**, with no lead. Each phone frame uses the motion
  reading from the moment it was taken (100 Hz history), so moving the phone does not move the bird.
- **Zoom (1× / 2× / 5×):** real camera zoom.
  - 2× is a crop of the main camera's sensor.
  - 5× switches to the telephoto lens.
  - The focal length follows the lens and zoom, checked against the per-frame camera intrinsics,
    so distance and speed stay correct.
  - Tracks restart when the zoom changes.

### 7. GoPro on the gun (phone in the pocket)

Settings › Camera › **GoPro on the gun**. The video comes from a GoPro (HERO9 or newer; recommended:
HERO13 Black, Linear lens) on a barrel mount, and the gun's movement comes from a **WitMotion
WT901BLECL** Bluetooth motion sensor strapped to the gun with its X arrow towards the muzzle. The
phone's own sensors cannot be used because the phone no longer moves with the camera.

- **Video:** the phone joins the GoPro's Wi-Fi. The app finds out which control API the camera speaks
  and starts its preview stream:
  - HERO9 and newer: Open GoPro, HTTP on 10.5.5.9:8080.
  - HERO5–HERO8 (e.g. HERO7 Black): the older gpControl API, HTTP on 10.5.5.9:80, kept alive with a
    UDP message to the camera's port 8554 every 2 s. The preview is lower resolution (about 480p),
    so birds are detected at shorter range.

  Both send H.264 in MPEG-TS over UDP port 8554, decoded with VideoToolbox.
  The button "Switch on GoPro Wi-Fi" uses the GoPro's Bluetooth link and shows the network name and
  password.
- **Delay:** Wi-Fi video arrives about 200–300 ms late. Each frame is given the gun's orientation
  at the moment it was taken (from the sensor's 100 Hz history), and birds are moved forward by the
  delay for the lead, using where the barrel points now. "Measure delay" flashes the phone screen in
  front of the GoPro and times how long the flash takes to show up in the video.
- **Calibration:**
  - Field of view: tap the two edges of an object of known width at a known distance.
  - Barrel alignment: mark where the barrel points in the picture; the reticle moves there.
  - Sensor axes: checked automatically against gravity and the gyro while you tilt and swing the gun.
  - North: point the gun north and tap the button.
- **Real shots:** a recoil spike above the threshold (default 6 g) counts as a shot. It is judged
  with the barrel's orientation just before the recoil. No fake bang or vibration is played.
- **Pocket lock** (lock icon): a black screen that ignores touches. Hold for 2 s to unlock. Use
  earphones for the aiming beeps, and keep the app open with silent mode off.

None of this has been tested with real hardware yet.

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
