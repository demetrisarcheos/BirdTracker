import SwiftUI

struct SettingsView: View {
    @AppStorage(AppSettings.birdSizeKey) private var birdSize = BirdSizePreset.pigeon.meters
    @AppStorage(AppSettings.confidenceKey) private var confidence = 0.30
    @AppStorage(AppSettings.speedUnitKey) private var speedUnitRaw = SpeedUnit.kmh.rawValue
    @AppStorage(AppSettings.identifySpeciesKey) private var identifySpecies = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
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

                Section("Detection") {
                    VStack(alignment: .leading) {
                        Text(String(format: "Confidence threshold: %.0f %%", confidence * 100))
                        Slider(value: $confidence, in: 0.1...0.9, step: 0.05)
                    }
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
