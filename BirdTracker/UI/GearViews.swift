import PhotosUI
import SwiftUI
import UIKit

// MARK: - Shotgun

struct GunSetupView: View {
    @AppStorage(GearStore.gunKey) private var gunJSON = ""
    @State private var gun = GunSetup()
    @State private var loaded = false

    private var currentModel: GunModel? {
        GunCatalog.models(of: gun.brand).first { $0.name == gun.model }
    }

    private var brandBinding: Binding<String> {
        Binding(get: { gun.brand }, set: { brand in
            if let first = GunCatalog.models(of: brand).first { apply(first) }
        })
    }

    private var modelBinding: Binding<String> {
        Binding(get: { gun.model }, set: { name in
            if let m = GunCatalog.models(of: gun.brand).first(where: { $0.name == name }) { apply(m) }
        })
    }

    var body: some View {
        Form {
            Section {
                Picker("Brand", selection: brandBinding) {
                    ForEach(GunCatalog.brands, id: \.self) { Text($0).tag($0) }
                }
                Picker("Model", selection: modelBinding) {
                    ForEach(GunCatalog.models(of: gun.brand)) { Text($0.name).tag($0.name) }
                }
                Picker("Action", selection: $gun.action) {
                    ForEach(GunAction.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Shotgun")
            } footer: {
                Text("The pattern is set by the choke, not the brand. The model fills in typical barrel lengths " +
                     "and how its chokes are marked; adjust both to match your gun.")
            }

            Section {
                Stepper(value: $gun.barrelCM, in: 50...90, step: 1) {
                    Text(String(format: "Barrel length %.0f cm", gun.barrelCM))
                }
                if let m = currentModel, m.barrels.count > 1 {
                    Picker("Common lengths", selection: $gun.barrelCM) {
                        ForEach(m.barrels, id: \.self) { Text(String(format: "%.0f", $0)).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
            } header: {
                Text("Barrel")
            } footer: {
                Text("Box speeds are measured in a 76 cm test barrel; each cm shorter is about 0.5 m/s slower.")
            }

            Section {
                Picker("Marking", selection: $gun.chokeSystem) {
                    ForEach(ChokeSystem.allCases) { Text($0.title).tag($0) }
                }
                chokeRow(gun.action.isDouble ? "Barrel 1 (fires first)" : "Choke", $gun.choke1MM)
                if gun.action.isDouble {
                    chokeRow("Barrel 2", $gun.choke2MM)
                }
            } header: {
                Text("Choke fitted")
            } footer: {
                Text("Stars / notches: ★ = Full, ★★ = Improved Modified, ★★★ = Modified, ★★★★ = Improved " +
                     "Cylinder, ★★★★★ = Cylinder (Beretta, Benelli, Browning, Franchi and Italian fixed chokes). " +
                     "On most over & unders the bottom barrel fires first.")
            }

            Section {
                ForEach([20.0, 30.0, 40.0], id: \.self) { range in
                    LabeledContent(String(format: "%.0f m", range), value: patternText(range))
                }
            } header: {
                Text("Pattern with your cartridge")
            } footer: {
                Text("Diameter holding 75 % of the pellets, pellet speed and energy on arrival.")
            }
        }
        .navigationTitle("Shotgun")
        .onAppear {
            if !loaded {
                gun = GearStore.gun(gunJSON)
                loaded = true
            }
        }
        .onChange(of: gun) { _, new in gunJSON = GearStore.json(new) }
    }

    private func apply(_ m: GunModel) {
        gun.brand = m.brand
        gun.model = m.name
        gun.action = m.action
        gun.chokeSystem = m.chokes
        if !m.barrels.contains(gun.barrelCM) { gun.barrelCM = m.barrels[m.barrels.count / 2] }
    }

    @ViewBuilder
    private func chokeRow(_ title: String, _ mm: Binding<Double>) -> some View {
        if gun.chokeSystem == .millimetres {
            Stepper(value: mm, in: 0...1.5, step: 0.05) {
                Text(String(format: "%@: %.2f mm (%@)", title, mm.wrappedValue, ChokeSystem.name(forMM: mm.wrappedValue)))
            }
        } else {
            Picker(title, selection: mm) {
                ForEach(gun.chokeSystem.options) { Text($0.label).tag($0.mm) }
            }
        }
    }

    private func patternText(_ range: Double) -> String {
        let cartridge = GearStore.loadout().cartridge
        let first = Loadout(gun: gun, cartridge: cartridge, barrel: 1)
        var text = String(format: "Ø %.2f m", first.patternDiameter(at: range))
        if gun.action.isDouble {
            text += String(format: " / %.2f m", Loadout(gun: gun, cartridge: cartridge, barrel: 2).patternDiameter(at: range))
        }
        let impact = first.impact(at: range)
        return text + String(format: " · %.0f m/s · %.1f J", impact.speed, impact.energy)
    }
}

// MARK: - Cartridges

struct CartridgeDraft: Identifiable {
    let id = UUID()
    var cartridge: Cartridge
    var found: [String]
    var isNew: Bool
}

struct CartridgeListView: View {
    @AppStorage(GearStore.cartridgesKey) private var cartridgesJSON = ""
    @AppStorage(GearStore.selectedCartridgeKey) private var selectedID = ""
    @State private var editing: CartridgeDraft?
    @State private var showCamera = false
    @State private var photoItem: PhotosPickerItem?
    @State private var scanning = false
    @State private var scanMessage: String?

    private var list: [Cartridge] { GearStore.cartridges(cartridgesJSON) }
    private var selected: Cartridge { GearStore.selected(list, id: selectedID) }

    var body: some View {
        List {
            Section {
                ForEach(list) { c in
                    Button {
                        selectedID = c.id.uuidString
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.title).foregroundStyle(.primary)
                                Text(c.summary).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if c.id == selected.id {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) { delete(c) } label: { Label("Delete", systemImage: "trash") }
                        Button {
                            editing = CartridgeDraft(cartridge: c, found: [], isNew: false)
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        .tint(.blue)
                    }
                }
            } footer: {
                Text("Tap to use, swipe to edit or delete. The generic loads are typical values; add your own " +
                     "cartridges from the box for accurate results.")
            }

            Section {
                Button { showCamera = true } label: { Label("Scan cartridge box", systemImage: "camera.viewfinder") }
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label("Scan from a photo", systemImage: "photo")
                }
                Button {
                    editing = CartridgeDraft(cartridge: Cartridge(), found: [], isNew: true)
                } label: {
                    Label("Enter manually", systemImage: "square.and.pencil")
                }
            } header: {
                Text("Add a cartridge")
            } footer: {
                if scanning {
                    Text("Reading the box…")
                } else if let scanMessage {
                    Text(scanMessage).foregroundStyle(.orange)
                } else {
                    Text("Photograph the side of the box where the load (g), shot size (No. / mm) and speed " +
                         "(m/s) are printed. The text is read on the phone; you check it before saving.")
                }
            }
        }
        .navigationTitle("Cartridges")
        .sheet(isPresented: $showCamera) {
            CameraPhotoPicker { image in process(image) }
                .ignoresSafeArea()
        }
        .sheet(item: $editing) { draft in
            NavigationStack {
                CartridgeEditorView(draft: draft) { save($0) }
            }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    process(image)
                }
                photoItem = nil
            }
        }
    }

    private func process(_ image: UIImage) {
        scanning = true
        scanMessage = nil
        Task {
            let result = await CartridgeScanner.scan(image)
            scanning = false
            if result.found.isEmpty {
                scanMessage = "No specs found in the photo. Try closer, sharper and straight on, or enter them manually."
            } else {
                editing = CartridgeDraft(cartridge: result.cartridge, found: result.found, isNew: true)
            }
        }
    }

    private func save(_ cartridge: Cartridge) {
        var l = list
        if let i = l.firstIndex(where: { $0.id == cartridge.id }) { l[i] = cartridge } else { l.append(cartridge) }
        cartridgesJSON = GearStore.json(l)
        selectedID = cartridge.id.uuidString
    }

    private func delete(_ cartridge: Cartridge) {
        var l = list
        l.removeAll { $0.id == cartridge.id }
        cartridgesJSON = GearStore.json(l)
    }
}

struct CartridgeEditorView: View {
    @State private var draft: CartridgeDraft
    let onSave: (Cartridge) -> Void
    @Environment(\.dismiss) private var dismiss

    init(draft: CartridgeDraft, onSave: @escaping (Cartridge) -> Void) {
        _draft = State(initialValue: draft)
        self.onSave = onSave
    }

    private var shotNumber: Binding<String> {
        Binding(get: { draft.cartridge.shotNumber }, set: { number in
            draft.cartridge.shotNumber = number
            if let mm = ShotScale.mm(for: number) { draft.cartridge.pelletMM = mm }
        })
    }

    var body: some View {
        Form {
            if !draft.found.isEmpty {
                Section("Read from the box – please check") {
                    ForEach(draft.found, id: \.self) { Label($0, systemImage: "text.viewfinder") }
                }
            }

            Section("Cartridge") {
                TextField("Brand", text: $draft.cartridge.brand)
                TextField("Model / name", text: $draft.cartridge.model)
                Picker("Gauge", selection: $draft.cartridge.gauge) {
                    ForEach([12, 16, 20, 28], id: \.self) { Text("\($0)").tag($0) }
                }
            }

            Section {
                numberField("Load (g)", value: $draft.cartridge.loadGrams)
                Picker("Shot number", selection: shotNumber) {
                    ForEach(ShotScale.numbers, id: \.self) { Text("No. \($0)").tag($0) }
                }
                numberField("Pellet Ø (mm)", value: $draft.cartridge.pelletMM)
                Picker("Material", selection: $draft.cartridge.material) {
                    ForEach(PelletMaterial.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Shot")
            } footer: {
                Text("Shot numbers use the Italian scale (No. 7 = 2.5 mm, No. 9 = 2.0 mm). If the box prints " +
                     "the diameter in mm, enter that.")
            }

            Section {
                numberField("Speed (m/s)", value: $draft.cartridge.velocity)
                Picker("Measured at", selection: $draft.cartridge.velocityDistance) {
                    Text("Muzzle V0").tag(0.0)
                    Text("1 m (V1)").tag(1.0)
                    Text("2.5 m (V2.5)").tag(2.5)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Speed, as printed on the box")
            }

            Section {
                let loadout = Loadout(gun: GearStore.loadout().gun, cartridge: valid(draft.cartridge))
                LabeledContent("Pellets", value: String(format: "≈ %.0f", loadout.pelletCount))
                ForEach([20.0, 30.0, 40.0], id: \.self) { range in
                    let impact = loadout.impact(at: range)
                    LabeledContent(String(format: "%.0f m", range),
                                   value: String(format: "%.0f m/s · %.1f J · %.3f s", impact.speed, impact.energy, impact.time))
                }
            } header: {
                Text("Performance with your shotgun")
            }
        }
        .navigationTitle(draft.isNew ? "New cartridge" : "Edit cartridge")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    onSave(valid(draft.cartridge))
                    dismiss()
                }
            }
        }
    }

    private func numberField(_ title: String, value: Binding<Double>) -> some View {
        LabeledContent(title) {
            TextField(title, value: value, format: .number)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
        }
    }

    /// Keeps values in a physically sensible range.
    private func valid(_ c: Cartridge) -> Cartridge {
        var c = c
        c.loadGrams = min(max(c.loadGrams, 10), 70)
        c.pelletMM = min(max(c.pelletMM, 1.0), 5.5)
        c.velocity = min(max(c.velocity, 200), 600)
        return c
    }
}

/// Takes a photo with the camera (or picks one if there is no camera).
struct CameraPhotoPicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPhotoPicker
        init(_ parent: CameraPhotoPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onImage(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}
