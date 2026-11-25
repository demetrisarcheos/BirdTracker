import Combine
import CoreBluetooth
import Foundation
import QuartzCore
import simd

/// WitMotion WT901BLECL (Bluetooth 9-axis motion sensor) strapped to the gun.
///
/// It replaces the phone's own motion sensors when the phone is in a pocket:
///  • orientation history, so every (delayed) GoPro frame gets the gun's orientation at the moment
///    it was taken, and the lead uses where the barrel points right now;
///  • recoil detection, so a real trigger pull counts as a shot.
///
/// Data format (WitMotion BLE 5.0): 20-byte packets 0x55 0x61, then 9 little-endian Int16:
/// acceleration (±16 g), angular rate (±2000 °/s), roll / pitch / yaw (±180°).
final class GunSensor: NSObject, ObservableObject {
    enum Status: Equatable { case off, bluetoothOff, unauthorized, notChosen, searching, connecting, connected }

    struct Found: Identifiable, Equatable {
        let id: UUID
        let name: String
    }

    @Published private(set) var status: Status = .off
    @Published private(set) var found: [Found] = []
    @Published private(set) var connectedName: String?
    @Published private(set) var rateHz: Double = 0
    @Published private(set) var conventionLearned = false
    /// Latest sensor → world rotation, about 10 times a second (for the setup screen).
    @Published private(set) var latest: simd_double3x3?

    /// Called on the Bluetooth queue with the host time just before the recoil.
    var onRecoil: ((Double) -> Void)?

    var statusText: String {
        switch status {
        case .off:          return "Off"
        case .bluetoothOff: return "Bluetooth is off"
        case .unauthorized: return "Bluetooth permission is off (iPhone Settings › Bird Tracker)"
        case .notChosen:    return "No sensor chosen yet"
        case .searching:    return "Searching…"
        case .connecting:   return "Connecting…"
        case .connected:    return "Connected"
        }
    }

    private static let writeChar = CBUUID(string: "FFE9")
    private static let conventionKey = "gunSensorConvention"

    private let queue = DispatchQueue(label: "gun.sensor.ble", qos: .userInteractive)
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var wantRunning = false
    private var wantScan = false
    private var rx: [UInt8] = []

    private let historyLock = NSLock()
    private var history: [(t: Double, r: simd_double3x3)] = []
    private var lastRecoil = -Double.infinity
    private var packetCount = 0
    private var rateStart = 0.0
    private var lastPublish = 0.0

    // Axis-convention self-check (bits: 1 = pitch reversed, 2 = roll reversed, 4 = accel reversed, 8 = yaw reversed)
    private var convention = 0
    private var learned = false
    private var gravityError = [Double](repeating: 0, count: 8)
    private var pitchTilted = 0
    private var rollTilted = 0
    private var yawEvidence = 0.0
    private var yawSamples = 0
    private var lastYaw: (t: Double, deg: Double)?

    override init() {
        super.init()
        if let stored = UserDefaults.standard.object(forKey: Self.conventionKey) as? Int {
            convention = stored
            learned = true
            conventionLearned = true
        }
    }

    // MARK: - Public control

    func start() {
        queue.async {
            self.wantRunning = true
            if self.central == nil {
                self.central = CBCentralManager(delegate: self, queue: self.queue)
            } else {
                self.connectSaved()
            }
        }
    }

    func stop() {
        queue.async {
            self.wantRunning = false
            self.wantScan = false
            self.central?.stopScan()
            if let p = self.peripheral { self.central?.cancelPeripheralConnection(p) }
            self.peripheral = nil
            self.publish(.off)
        }
    }

    func scan() {
        queue.async {
            self.wantScan = true
            DispatchQueue.main.async { self.found = [] }
            if self.central == nil {
                self.central = CBCentralManager(delegate: self, queue: self.queue)
            } else {
                self.startScan()
            }
        }
    }

    func connect(_ id: UUID) {
        queue.async {
            UserDefaults.standard.set(id.uuidString, forKey: AppSettings.sensorIDKey)
            self.wantScan = false
            self.central?.stopScan()
            if let p = self.peripheral { self.central?.cancelPeripheralConnection(p) }
            self.peripheral = nil
            self.resetLearning()
            self.wantRunning = true
            self.connectSaved()
        }
    }

    func forget() {
        queue.async {
            UserDefaults.standard.removeObject(forKey: AppSettings.sensorIDKey)
            if let p = self.peripheral { self.central?.cancelPeripheralConnection(p) }
            self.peripheral = nil
            self.resetLearning()
            DispatchQueue.main.async { self.connectedName = nil }
            self.publish(.notChosen)
        }
    }

    /// Restart the automatic axis check (e.g. after re-mounting the sensor).
    func relearn() { queue.async { self.resetLearning() } }

    /// Sensor → world rotation at a host time (nearest earlier sample); nil if the sensor is silent.
    func sensorToWorld(at time: Double) -> simd_double3x3? {
        historyLock.lock(); defer { historyLock.unlock() }
        guard let newest = history.last, CACurrentMediaTime() - newest.t < 0.5 else { return nil }
        for entry in history.reversed() where entry.t <= time { return entry.r }
        return history.first?.r
    }

    // MARK: - Internals

    private func publish(_ status: Status) {
        DispatchQueue.main.async { if self.status != status { self.status = status } }
    }

    private func startScan() {
        guard let central, central.state == .poweredOn, wantScan else { return }
        central.scanForPeripherals(withServices: nil)
        publish(.searching)
        queue.asyncAfter(deadline: .now() + 15) {
            guard self.wantScan else { return }
            self.wantScan = false
            central.stopScan()
            if self.peripheral == nil { self.publish(.notChosen) }
        }
    }

    private func connectSaved() {
        guard let central, central.state == .poweredOn, wantRunning else { return }
        if let peripheral, peripheral.state == .connected || peripheral.state == .connecting { return }
        guard let text = UserDefaults.standard.string(forKey: AppSettings.sensorIDKey),
              let id = UUID(uuidString: text),
              let p = central.retrievePeripherals(withIdentifiers: [id]).first else {
            if !wantScan { publish(.notChosen) }
            return
        }
        peripheral = p
        p.delegate = self
        central.connect(p)
        publish(.connecting)
    }

    private func resetLearning() {
        UserDefaults.standard.removeObject(forKey: Self.conventionKey)
        convention = 0
        learned = false
        gravityError = [Double](repeating: 0, count: 8)
        pitchTilted = 0
        rollTilted = 0
        yawEvidence = 0
        yawSamples = 0
        lastYaw = nil
        DispatchQueue.main.async { self.conventionLearned = false }
    }

    private func configure(_ p: CBPeripheral, _ c: CBCharacteristic) {
        let type: CBCharacteristicWriteType = c.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        // Unlock, then 100 Hz output.
        let commands: [[UInt8]] = [[0xFF, 0xAA, 0x69, 0x88, 0xB5], [0xFF, 0xAA, 0x03, 0x09, 0x00]]
        for (i, command) in commands.enumerated() {
            queue.asyncAfter(deadline: .now() + 0.2 * Double(i + 1)) {
                p.writeValue(Data(command), for: c, type: type)
            }
        }
    }

    private func receive(_ data: Data) {
        rx.append(contentsOf: data)
        var packets: [[UInt8]] = []
        while rx.count >= 20 {
            if rx[0] == 0x55, rx[1] == 0x61 {
                packets.append(Array(rx[0..<20]))
                rx.removeFirst(20)
            } else if rx[0] == 0x55, rx[1] == 0x71 {
                rx.removeFirst(20)                 // register reply
            } else {
                rx.removeFirst()
            }
        }
        // Bluetooth may bundle several samples into one notification; space them at the 100 Hz rate.
        let now = CACurrentMediaTime() - 0.015
        for (i, packet) in packets.enumerated() {
            handle(packet, time: now - Double(packets.count - 1 - i) * 0.01)
        }
    }

    private static func int16(_ b: [UInt8], _ i: Int) -> Double {
        Double(Int16(bitPattern: UInt16(b[i]) | UInt16(b[i + 1]) << 8))
    }

    private func handle(_ b: [UInt8], time t: Double) {
        let a = SIMD3(Self.int16(b, 2), Self.int16(b, 4), Self.int16(b, 6)) * (16.0 / 32768)
        let w = SIMD3(Self.int16(b, 8), Self.int16(b, 10), Self.int16(b, 12)) * (2000.0 / 32768)
        let roll = Self.int16(b, 14) * 180 / 32768
        let pitch = Self.int16(b, 16) * 180 / 32768
        let yaw = Self.int16(b, 18) * 180 / 32768

        // Recoil: a real shot gives a spike of many g.
        let g = simd_length(a)
        let threshold = UserDefaults.standard.double(forKey: AppSettings.recoilThresholdKey)
        if g > max(3, threshold), t - lastRecoil > 1.0 {
            lastRecoil = t
            onRecoil?(t - 0.03)
        }

        learn(a: a, w: w, roll: roll, pitch: pitch, yaw: yaw, t: t)
        let r = Self.matrix(convention, roll: roll, pitch: pitch, yaw: yaw)

        historyLock.lock()
        history.append((t, r))
        if history.count > 400 { history.removeFirst(history.count - 400) }
        historyLock.unlock()

        packetCount += 1
        if t - rateStart >= 1 {
            let rate = Double(packetCount) / (t - rateStart)
            packetCount = 0
            rateStart = t
            DispatchQueue.main.async { self.rateHz = rate }
        }
        if t - lastPublish >= 0.1 {
            lastPublish = t
            DispatchQueue.main.async {
                self.latest = r
                if self.status != .connected { self.status = .connected }
            }
        }
    }

    /// Z-Y-X Euler angles → sensor-to-world rotation, with the learned sign conventions.
    private static func matrix(_ c: Int, roll: Double, pitch: Double, yaw: Double) -> simd_double3x3 {
        let rad = Double.pi / 180
        let sp = c & 1 != 0 ? -1.0 : 1.0
        let sr = c & 2 != 0 ? -1.0 : 1.0
        let sy = c & 8 != 0 ? -1.0 : 1.0
        return Rotation.z(sy * yaw * rad) * Rotation.y(sp * pitch * rad) * Rotation.x(sr * roll * rad)
    }

    /// Checks the sensor's angle conventions against physics, so a sign mix-up cannot silently turn
    /// panning into fake bird motion:
    ///  • pitch/roll signs (and accelerometer sign) must make gravity point where the accelerometer says;
    ///  • yaw sign must make the yaw angle change in the same direction the gyro turns.
    private func learn(a: SIMD3<Double>, w: SIMD3<Double>, roll: Double, pitch: Double, yaw: Double, t: Double) {
        guard !learned else { return }
        let rad = Double.pi / 180
        let g = simd_length(a)

        if abs(g - 1) < 0.1, simd_length(w) < 30 {
            let up = a / g
            for c in 0..<8 {
                let sp = c & 1 != 0 ? -1.0 : 1.0
                let sr = c & 2 != 0 ? -1.0 : 1.0
                let sa = c & 4 != 0 ? -1.0 : 1.0
                let r = Rotation.y(sp * pitch * rad) * Rotation.x(sr * roll * rad)
                gravityError[c] += simd_length_squared(sa * up - r.transpose * SIMD3(0, 0, 1))
            }
            if abs(pitch) > 12 { pitchTilted += 1 }
            if abs(roll) > 12, abs(roll) < 168 { rollTilted += 1 }
        }
        let best = gravityError.indices.min { gravityError[$0] < gravityError[$1] } ?? 0

        if let last = lastYaw, t - last.t > 0.004, t - last.t < 0.1, g > 0.6, g < 1.5 {
            var d = yaw - last.deg
            if d > 180 { d -= 360 } else if d < -180 { d += 360 }
            let rate = d / (t - last.t)
            let sp = best & 1 != 0 ? -1.0 : 1.0
            let sr = best & 2 != 0 ? -1.0 : 1.0
            let worldRate = (Rotation.y(sp * pitch * rad) * Rotation.x(sr * roll * rad) * w).z
            if abs(rate) > 25, abs(worldRate) > 25 {
                yawEvidence += rate * worldRate > 0 ? 1 : -1
                yawSamples += 1
            }
        }
        lastYaw = (t, yaw)

        // Use the best guess so far; lock it in once the evidence is clear.
        convention = (best & 3) | (best & 4) | (yawEvidence < 0 ? 8 : 0)
        let sorted = gravityError.sorted()
        let gravityDecided = pitchTilted >= 60 && rollTilted >= 60 && sorted[0] < 0.4 * sorted[1]
        let yawDecided = yawSamples >= 40 && abs(yawEvidence) >= 0.6 * Double(yawSamples)
        if gravityDecided && yawDecided {
            learned = true
            UserDefaults.standard.set(convention, forKey: Self.conventionKey)
            DispatchQueue.main.async { self.conventionLearned = true }
        }
    }
}

extension GunSensor: CBCentralManagerDelegate, CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            connectSaved()
            startScan()
        case .poweredOff:
            publish(.bluetoothOff)
        case .unauthorized:
            publish(.unauthorized)
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        guard name.uppercased().contains("WT") else { return }
        let item = Found(id: peripheral.identifier, name: name)
        DispatchQueue.main.async {
            if !self.found.contains(where: { $0.id == item.id }) { self.found.append(item) }
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let name = peripheral.name ?? "WitMotion sensor"
        DispatchQueue.main.async { self.connectedName = name }
        rx.removeAll()
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        if wantRunning, peripheral == self.peripheral { central.connect(peripheral) }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        guard wantRunning, peripheral == self.peripheral else { return }
        central.connect(peripheral)          // reconnects as soon as it is back in range
        publish(.connecting)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for c in service.characteristics ?? [] {
            if c.properties.contains(.notify) { peripheral.setNotifyValue(true, for: c) }
            if c.uuid == Self.writeChar { configure(peripheral, c) }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard error == nil, let data = c.value else { return }
        receive(data)
    }
}
