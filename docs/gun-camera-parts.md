# Bird Tracker gun camera: parts list

A small camera box for the shotgun barrel. It holds a camera and a motion sensor on one clock,
streams video plus orientation over its own Wi-Fi to the iPhone (in your pocket), and detects
recoil. No soldering is needed.

Prices are approximate (November 2026, including VAT) and change often. Check the shop page
before ordering. EU shops are listed first, because buying from the UK into Cyprus can add import
VAT and handling fees.

## Board choice

| | Raspberry Pi Zero 2 W (**chosen**) | Radxa Zero 3W |
|---|---|---|
| Size | 65 × 30 mm | 65 × 30 mm |
| Video encoder | H.264, 1080p at about 30 fps or 720p at 60 fps | H.264/H.265 up to 1080p at 60 fps (spec sheet) |
| Camera support | Official Camera Module 3, mature software | Only older modules (IMX219/OV5647) officially; low-delay H.264 not documented |
| Battery board | PiSugar 3 fits directly | No confirmed battery board |

The Pi Zero 2 W is the safe first build. Everything is documented and fits together without
soldering. The Radxa stays a possible later upgrade for 1080p at 60 fps, once someone has proven
its camera pipeline.

## Shopping list

| # | Part | Why | Shop (EU first) | Approx. |
|---|---|---|---|---|
| 1 | **Raspberry Pi Zero 2 WH** (the "H" means header pins already soldered) | The computer | [BerryBase](https://www.berrybase.de/en/raspberry-pi-zero-2-wh) (€20.90) · Botland · Kubii | €21 |
| 2 | **Raspberry Pi Camera Module 3, standard lens** (not Wide, not NoIR) | 12 MP, 66° view, good in low light. The narrower view gives more pixels per bird | [BerryBase](https://www.berrybase.de/en/raspberry-pi-camera-module-3-12mp) (€28.90) · [The Pi Hut](https://thepihut.com/products/raspberry-pi-camera-module-3) (£24, includes the Zero cable) | €29 |
| 3 | **Pi Zero camera cable, 22-pin to 15-pin**, about 38–100 mm | Pi Zero uses a smaller camera socket. Skip this if your camera came with the 200 mm Zero cable (The Pi Hut's does) | [The Pi Hut, 38 mm stub](https://thepihut.com/collections/raspberry-pi-camera-cables/products/raspberry-pi-zero-stub-camera-cable-38mm) (£2.50) or similar at BerryBase/Botland | €3 |
| 4 | **Adafruit BNO085 9-DOF orientation sensor, STEMMA QT** (Adafruit 4754) | Gyro, accelerometer and compass with built-in orientation fusion, hundreds of readings a second | [BerryBase](https://www.berrybase.de/en/adafruit-9-dof-orientation-imu-fusion-breakout-bno085-bno080) (€37.50) · [The Pi Hut](https://thepihut.com/products/adafruit-9-dof-orientation-imu-fusion-breakout-bno085-bno080-stemma-qt-qwiic) (£26.40) | €30–38 |
| 5 | **STEMMA QT / Qwiic cable to female sockets, 150 mm** (Adafruit 4397) | Plugs the sensor onto the Pi's pins without soldering | [Botland](https://botland.store/1426-female-to-female-connecting-cables) (€1.90) | €2 |
| 6 | **PiSugar 3** battery for Pi Zero (1200 mAh, USB-C charging, power button) | Clips under the Pi with spring pins and leaves the header free. Vendor says 8–10 h at light load; expect about 2–4 h while streaming | [Tindie, PiSugar Kitchen](https://www.tindie.com/products/pisugar/pisugar-3-battery-for-raspberry-pi-zero/) ($39.99) | €37 |
| 7 | **microSD card, 32 GB "High Endurance"** (e.g. SanDisk High Endurance) | System disk. High-endurance cards cope better with heat and constant writing | Any shop | €10 |
| 8 | **Small adhesive copper heatsink** for the Pi Zero (about 14 × 14 mm) | Constant video encoding and Wi-Fi warm the chip | Any shop | €2 |
| 9 | **GoPro-compatible barrel mount** | The case will have GoPro mounting fingers, so any GoPro shotgun or barrel mount works | Any shop | €15–30 |
| 10 | **3D-printed case** | Holds everything firmly against recoil, with foam padding and GoPro mounting fingers. I'll design the file once the parts are confirmed | Online print service (e.g. JLCPCB/Craftcloud) or a local maker space | €10–20 |

**Total: about €150–170**, including the case and mount.

**Cheaper battery option:** PiSugar S (same 1200 mAh, no clock or button) at about $28 on Tindie
saves about €10.

## Also needed (you may have these)

- A microSD card reader for your PC, to put the system on the card once.
- A USB-C cable and charger, to charge the PiSugar.
- Earphones for the aiming beeps while the phone is in your pocket.

## Wiring (no soldering)

1. Stick the heatsink on the Pi's main chip.
2. Connect the camera ribbon. The contacts face the board on the Pi Zero side; lift the latch, insert, close.
3. Sensor cable from the BNO085's STEMMA QT socket to the Pi header:
   - red → pin 1 (3.3 V)
   - blue → pin 3 (SDA)
   - yellow → pin 5 (SCL)
   - black → pin 6 (GND)
4. Screw the PiSugar 3 under the Pi with the supplied screws (its spring pins touch the Pi's underside).

The PiSugar also talks on the same I²C pins at a different address, so it doesn't clash with
the sensor.

## Notes for the build

- **Sensor and Pi I²C:** the BNO085 is known to be fussy on the Raspberry Pi's I²C bus. The Pi
  software will use the settings that work reliably, a lower bus speed with clock-stretching
  tolerance. If that still fails, the Adafruit board can also be read over UART instead.
- **Recoil:** the camera ribbon, SD card and battery must be held firmly. The case clamps the
  board on foam, glues the ribbon in place and closes the SD slot. Expect one or two case versions.
- **Accelerometer range:** the BNO085 measures up to ±8 g. Recoil goes beyond that, but the
  detector only needs to see a spike above about 6 g, so clipping does not matter.
- **Waterproofing:** none. Keep it out of heavy rain.
- **Start-up:** about 20–30 s after switching on before video appears.

## What happens next

1. **Pi software (I write it):** starts at power-on and creates its own Wi-Fi network.
   - Streams H.264 video: 1080p at 30 fps with centre zoom by default, or 720p at 60 fps.
   - Sends the sensor's orientation with the same timestamps as the video frames.
   - Detects recoil.
2. **iPhone app:** a new camera source, "Bird Tracker gun camera".
   - Exact frame timing replaces the delay measurement, and the known lens replaces the field-of-view measurement.
   - It keeps the barrel alignment, kill model and pocket lock from the GoPro source.
3. **Case design:** a 3D-print file made to fit these exact parts.
4. **Step-by-step guide:** putting the system on the SD card, assembly and first test.
