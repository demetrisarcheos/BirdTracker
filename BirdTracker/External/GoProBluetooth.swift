import Combine
import CoreBluetooth
import Foundation

/// Uses the GoPro's Bluetooth link (Open GoPro) to switch on its Wi-Fi access point and read the
/// network name and password, so the phone can join it.
final class GoProBluetooth: NSObject, ObservableObject {
    @Published private(set) var state = ""
    @Published private(set) var ssid: String?
    @Published private(set) var password: String?

    private static let advertised = CBUUID(string: "FEA6")
    private static let wifiService = CBUUID(string: "B5F90001-AA8D-11E3-9046-0002A5D5C51B")
    private static let ssidChar = CBUUID(string: "B5F90002-AA8D-11E3-9046-0002A5D5C51B")
    private static let passwordChar = CBUUID(string: "B5F90003-AA8D-11E3-9046-0002A5D5C51B")
    private static let commandChar = CBUUID(string: "B5F90072-AA8D-11E3-9046-0002A5D5C51B")
    private static let commandResponseChar = CBUUID(string: "B5F90073-AA8D-11E3-9046-0002A5D5C51B")

    private let queue = DispatchQueue(label: "gopro.ble")
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var wanted = false
    private var scanning = false

    func enableWiFi() {
        queue.async {
            self.wanted = true
            if self.central == nil {
                self.central = CBCentralManager(delegate: self, queue: self.queue)
            } else {
                self.begin()
            }
        }
    }

    private func set(_ text: String) {
        DispatchQueue.main.async { self.state = text }
    }

    private func begin() {
        guard let central, central.state == .poweredOn else { return }
        if let peripheral, peripheral.state == .connected {
            peripheral.discoverServices([Self.wifiService, Self.advertised])
            return
        }
        set("Looking for the GoPro…")
        scanning = true
        central.scanForPeripherals(withServices: [Self.advertised])
        queue.asyncAfter(deadline: .now() + 15) {
            guard self.scanning else { return }
            self.scanning = false
            central.stopScan()
            self.set("No GoPro found. Turn it on and switch on Wireless Connections. The first time, put it in " +
                     "pairing mode: Preferences › Connections › Connect Device › GoPro Quik app.")
        }
    }
}

extension GoProBluetooth: CBCentralManagerDelegate, CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:    if wanted { begin() }
        case .poweredOff:   set("Bluetooth is off.")
        case .unauthorized: set("Bluetooth permission is off (iPhone Settings › Bird Tracker).")
        default:            break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        scanning = false
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        central.connect(peripheral)
        set("Connecting to \(peripheral.name ?? "GoPro")…")
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        set("Connected – switching on the GoPro's Wi-Fi…")
        peripheral.discoverServices([Self.wifiService, Self.advertised])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        set("Could not connect to the GoPro: \(error?.localizedDescription ?? "unknown error").")
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for c in service.characteristics ?? [] {
            switch c.uuid {
            case Self.ssidChar, Self.passwordChar:
                peripheral.readValue(for: c)
            case Self.commandResponseChar:
                peripheral.setNotifyValue(true, for: c)
            case Self.commandChar:
                // Open GoPro "Set AP Control": enable the Wi-Fi access point.
                peripheral.writeValue(Data([0x03, 0x17, 0x01, 0x01]), for: c, type: .withResponse)
            default:
                break
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard error == nil, let data = c.value else { return }
        switch c.uuid {
        case Self.ssidChar:
            let text = String(data: data, encoding: .utf8)
            DispatchQueue.main.async { self.ssid = text }
        case Self.passwordChar:
            let text = String(data: data, encoding: .utf8)
            DispatchQueue.main.async { self.password = text }
        case Self.commandResponseChar:
            let bytes = [UInt8](data)
            if bytes.count >= 3, bytes[1] == 0x17 {
                set(bytes[2] == 0
                    ? "GoPro Wi-Fi is on. Join its network in iPhone Settings › Wi-Fi, then come back here."
                    : "The GoPro did not switch its Wi-Fi on (code \(bytes[2])).")
            }
        default:
            break
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor c: CBCharacteristic, error: Error?) {
        if let error {
            set("The GoPro refused (\(error.localizedDescription)). Put it in pairing mode – Preferences › " +
                "Connections › Connect Device › GoPro Quik app – and try again.")
        }
    }
}
