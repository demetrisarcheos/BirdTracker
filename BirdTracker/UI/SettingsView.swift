import SwiftUI

struct SettingsView: View {
    @AppStorage(AppSettings.birdSizeKey) private var birdSize = BirdSizePreset.pigeon.meters
    @AppStorage(AppSettings.confidenceKey) private var confidence = 0.30
    @AppStorage(AppSettings.speedUnitKey) private var speedUnitRaw = SpeedUnit.kmh.rawValue
    @AppStorage(AppSettings.identifySpeciesKey) private var identifySpecies = true
    @AppStorage(AppSettings.showLeadPointKey) private var showLeadPoint = true
    @AppStorage(AppSettings.shotSoundKey) private var shotSound = true
    @AppStorage(AppSettings.aimBeepsKey) private var aimBeeps = true
    @AppStorage(AppSettings.shootVibrationKey) private var shootVibration = true
    @AppStorage(GearStore.gunKey) private var gunJSON = ""
    @AppStorage(GearStore.cartridgesKey) private var cartridgesJSON = ""
    @AppStorage(GearStore.selectedCartridgeKey) private var selectedCartridgeID = ""
    @AppStorage(AppSettings.cameraSourceKey) private var cameraSourceRaw = CameraSource.phone.rawValue
    @AppStorage(AppSettings.highFrameRateKey) private var highFrameRate = true
    @Environment(\.dismiss) private var dismiss

    private var gearSummary: (gun: String, cartridge: String) {
        let gun = GearStore.gun(gunJSON)
        let cartridge = GearStore.selected(GearStore.cartridges(cartridgesJSON), id: selectedCartridgeID)
        return (gun.title, cartridge.shortTitle)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Camera", selection: $cameraSourceRaw) {
                        ForEach(CameraSource.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    NavigationLink("GoPro & gun sensor setup") { GunCameraSetupView() }
                } header: {
                    Text("Camera")
                } footer: {
                    Text("GoPro on the gun: the phone can stay in your pocket. Video comes from a GoPro over " +
                         "Wi-Fi and the gun's movement from a WitMotion Bluetooth sensor on the gun, because the " +
                         "phone's own sensors no longer move with the camera. Takes effect when you close Settings.")
                }

                Section {
                    ForEach(BirdSizePreset.allCases) { preset in
                        Button {
                            birdSize = preset.meters
                        } label: {
                            HStack {
                                Text(preset.title).foregroundStyle(.primary)
                                Spacer()
                                Text(String(format: "%.2f m", preset.meters)).foregroundStyle(.secondary)
                                if abs(birdSize - preset.meters) < 0.001 {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                    VStack(alignment: .leading) {
                        Text(String(format: "Custom wingspan: %.2f m", birdSize))
                        Slider(value: $birdSize, in: 0.1...3.0, step: 0.05)
                    }
                } header: {
                    Text("Assumed bird size (wingspan)")
                } footer: {
                    Text("A single camera cannot measure depth directly. Distance is computed from the bird's " +
                         "apparent size, so distance and speed are only as accurate as this value — " +
                         "a 20 % size error gives a 20 % distance and speed error.")
                }

                Section {
                    Toggle("Identify species", isOn: $identifySpecies)
                } header: {
                    Text("Species")
                } footer: {
                    Text("Recognises Wood Pigeon, Song Thrush, Chukar Partridge, Eurasian Skylark and Hooded Crow " +
                         "(anything else shows as Other Bird). Once confident (60 %+) it uses that species' typical " +
                         "wingspan instead of the preset above. Works best on birds that fill a good " +
                         "part of the screen.")
                }

                Section {
                    NavigationLink {
                        GunSetupView()
                    } label: {
                        LabeledContent("Shotgun", value: gearSummary.gun)
                    }
                    NavigationLink {
                        CartridgeListView()
                    } label: {
                        LabeledContent("Cartridge", value: gearSummary.cartridge)
                    }
                    Toggle("Show aiming point", isOn: $showLeadPoint)
                    Toggle("Shot sound", isOn: $shotSound)
                    Toggle("Aiming beeps", isOn: $aimBeeps)
                    Toggle("Vibrate on shot (1 s)", isOn: $shootVibration)
                } header: {
                    Text("Hunting simulation")
                } footer: {
                    Text("The Shoot button fills in as the reticle nears the point where the shot would meet " +
                         "the bird, using its speed, direction and distance with your cartridge's pellet " +
                         "ballistics (drag, drop, energy) and your choke's pattern. SHOOT means a shot fired now " +
                         "would kill cleanly at least 80 % of the time. Aiming beeps work like a parking sensor: " +
                         "faster as you close in, a steady tone at the shooting point. Sounds are muted when the " +
                         "phone is on silent. Long-press the score to reset it.")
                }

                Section {
                    VStack(alignment: .leading) {
                        Text(String(format: "Confidence threshold: %.0f %%", confidence * 100))
                        Slider(value: $confidence, in: 0.1...0.9, step: 0.05)
                    }
                    Toggle("High frame rate (up to 60 fps)", isOn: $highFrameRate)
                } header: {
                    Text("Detection")
                } footer: {
                    Text("The phone camera runs at up to 60 fps and the app analyses as many frames as the " +
                         "phone can (the top bar shows fps and the time per frame). Speed and direction settle " +
                         "faster, at the cost of battery and heat. It falls back to 30 fps when the phone gets " +
                         "hot or the light is poor.")
                }

                Section("Units") {
                    Picker("Speed", selection: $speedUnitRaw) {
                        ForEach(SpeedUnit.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
