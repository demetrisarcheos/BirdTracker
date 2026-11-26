# Gun camera case (cylindrical, tight version)

**Size:** Ø 41 mm × 90.5 mm, plus two 7 mm saddles underneath.
**Weight:** about 100 g with all parts (about 40 g of plastic).

The source is [`case.scad`](case.scad), an OpenSCAD file where every size is a named
setting at the top. GitHub renders the print files automatically: Actions › **Gun camera case
(STL)** › Artifacts › `gun-camera-case`. You get `tube.stl`, `tray.stl`, `cap.stl`, `pin.stl`
and two preview pictures.

## How it fits together

| Part | What it does |
|---|---|
| **Tube** | The shell. The front wall has the lens window, with a recess for an optional 12 × 1 mm clear disc. A flat floor inside stops the tray from turning. Vent slots sit over the Pi's processor, and two saddles with strap slots go underneath. |
| **Tray** | One rigid frame that holds everything, so the camera and sensor can't move relative to each other. The camera screws to its front plate, the Pi and PiSugar stack screws to four posts, and the BNO085 sits on a rail above the Pi. Two legs at the front rest against the front wall. |
| **Cap** | Rear cover with openings for USB-C, the power button and the charge light. Two M2.5 screws go through the cap into the tray. |
| **Pin** | A small pin that presses the PiSugar's button through the cap. |

**Recoil:** the gun jumps back, so the parts inside are pushed forward. The tray's legs carry
that load straight into the front wall, not into the screws.

**Why it's this size:**
- **Diameter:** the Pi Zero is 30 mm wide. With the PiSugar under it and the GPIO pins on top, its
  cross-section needs a 37 mm circle. The tube adds 0.4 mm clearance and 2 mm walls.
- **Length:** the parts are laid end to end, as tight as they go:
  - 2.5 mm front wall and gap
  - 11.5 mm camera
  - 2 mm standoffs
  - 2 mm plate
  - 3 mm ribbon fold
  - 65 mm Pi
  - 2.5 mm for the microSD card
  - 2 mm cap
- **Sensor:** it lies over the Pi instead of behind it, so it adds no length.
- **Camera:** it is mounted upside down so its ribbon comes off the top edge. This lets the lens sit
  2 mm below the centre and the board fit the circle. The Pi software turns the picture the
  right way up.

## Measure before printing

The values marked `MEASURE` in `case.scad` come from datasheets or are estimates. Check these on
the real parts with calipers, then change the number at the top of the file and push. GitHub
makes new print files.

1. **PiSugar 3:** stack height (`sugar_drop`, `batt_t`, `batt_l`), and where the USB-C port,
   button and LED sit (`usb_*`, `btn_*`, `led_*`, measured from the tube's centre line).
2. **Camera Module 3:** thickness board-to-lens (`cam_depth`), lens position (`lens_from_edge`)
   and the mounting holes (`cam_hole_*`).
3. **BNO085 board:** hole positions (`imu_hole_*`).
4. **Your barrel:** outside diameter where the saddles go (`barrel_d`).

## Printing

- **Material:** PETG or ASA, black. Not PLA, which softens in a hot car and cracks more easily.
- **Settings:** 0.2 mm layers, 4 walls, 40 % gyroid infill.
- **Tube:** stand it on its front face, which is how the file is oriented. No supports are needed.
- **Tray:** stand it on its rear ring. Use supports for the front plate and the sensor rail.
- **Cap and pin:** print them flat.
- **Fit:** if the tray is too tight or loose in the tube, change `clr`; 0.4 is the default.

## Assembly

1. Stick the heatsink (at most 3 mm tall) on the Pi's processor.
2. Press the **Qwiic SHIM** onto the Pi's GPIO pins 1–6 (no soldering). Plug the 50 mm
   STEMMA QT cable into it.
3. Fit the PiSugar 3 under the Pi.
4. Screw the camera to the tray's front plate with 4 × M2 × 5 screws, ribbon connector at the
   top. Connect the ribbon to the Pi (contacts towards the board).
5. Screw the Pi + PiSugar stack to the tray posts with 4 × M2.5 × 12 screws.
6. Screw the BNO085 onto the rail with 2 × M2.5 × 6 screws, label side up, its long side along
   the tray. Plug in the cable.
7. Slide the tray into the tube from the back until the legs touch the front wall.
8. Put the pin in the cap's button hole and fit the cap with 2 × M2.5 × 8 screws.
9. Glue a 1 mm rubber strip into each saddle groove. Strap the case to the barrel with two
   12 mm hook-and-loop straps.

**Mounting position:** on top of the barrel, under it, or on the side all work. The app's
barrel alignment step finds where the barrel points in the picture. If it's mounted upside
down (under the barrel), switch on "Camera upside down" in the app.
