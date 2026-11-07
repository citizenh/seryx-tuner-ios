import Foundation
import CoreBluetooth

/// Talks to a Bluetooth-LE ELM327 OBD adapter and sends the Seryx custom
/// config frames (CAN id 0x7E0, payload `01 A0 <feat> <val>` for SET, `01 A1` for GET).
/// The ECU firmware handler writes the arming magic + checksum itself, so the app
/// only sends the 4-byte command frames.
final class BLEManager: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {

    // MARK: Published state (drives the UI)
    @Published var status: String = "Idle"
    @Published var isConnected = false
    @Published var isScanning = false
    @Published var discovered: [CBPeripheral] = []
    @Published var log: [String] = []
    @Published var lastReadback: String = ""   // raw response to GET (01 A1)

    // MARK: BLE internals
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var notifyChar: CBCharacteristic?

    // Known ELM327 BLE service/characteristic families (adapter-dependent).
    // We don't hard-filter on scan; on connect we pick any char that is writable+notifiable.
    private let knownServiceUUIDs: [CBUUID] = [
        CBUUID(string: "FFF0"), CBUUID(string: "FFE0"),
        CBUUID(string: "18F0"), CBUUID(string: "FFE5")
    ]

    // MARK: Command queue (ELM327 is a serial, prompt-based device)
    private var queue: [String] = []
    private var sending = false
    private var rxBuffer = ""
    private var responseHandler: ((String) -> Void)?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: Logging
    private func logLine(_ s: String) {
        let t = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        log.append("[\(t)] \(s)")
        if log.count > 400 { log.removeFirst(log.count - 400) }
    }
    func clearLog() { log.removeAll() }

    // MARK: Scanning / connecting
    func startScan() {
        guard central.state == .poweredOn else { status = "Bluetooth off"; return }
        discovered.removeAll()
        isScanning = true
        status = "Scanning…"
        // nil = all peripherals; many ELM327 clones don't advertise their service UUID
        central.scanForPeripherals(withServices: nil, options: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in self?.stopScan() }
    }
    func stopScan() {
        central.stopScan()
        isScanning = false
        if !isConnected { status = discovered.isEmpty ? "No adapter found" : "Select adapter" }
    }
    func connect(_ p: CBPeripheral) {
        stopScan()
        peripheral = p
        p.delegate = self
        status = "Connecting…"
        central.connect(p, options: nil)
    }
    func disconnect() {
        if let p = peripheral { central.cancelPeripheralConnection(p) }
    }

    // MARK: Public high-level actions ------------------------------------------------

    /// Initialise the ELM327 for raw 11-bit CAN @500k to header 7E0.
    func initAdapter() {
        enqueue(["ATZ", "ATE0", "ATL0", "ATS0", "ATH1", "ATSP6", "ATCAF0", "ATSH7E0"])
    }

    /// Send one config byte: 01 A0 <feat> <val>
    func setFeature(_ feat: Int, _ val: Int) {
        let cmd = String(format: "01A0%02X%02X", feat & 0xFF, val & 0xFF)
        enqueue([cmd])
    }

    /// Apply the whole upshift config in one shot.
    /// feat1=enable, feat2=cut cylinders (1..4), feat3=mode (A=1 / B=0)
    func applyUpshift(enable: Bool, cut: Int, modeA: Bool) {
        initAdapter()
        setFeature(1, enable ? 1 : 0)
        setFeature(2, max(1, min(4, cut)))
        setFeature(3, modeA ? 1 : 0)
        status = "Config sent"
    }

    /// Read back current config: 01 A1  → response parsed into lastReadback.
    func readBack() {
        initAdapter()
        enqueueWithResponse("01A1") { [weak self] resp in
            guard let self = self else { return }
            self.lastReadback = resp
            self.logLine("READBACK ← \(resp)")
        }
    }

    /// Send an arbitrary raw command (debug box).
    func sendRaw(_ cmd: String) {
        let c = cmd.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !c.isEmpty else { return }
        enqueue([c])
    }

    // MARK: Command queue plumbing ---------------------------------------------------

    private func enqueue(_ cmds: [String]) {
        queue.append(contentsOf: cmds)
        pump()
    }
    private func enqueueWithResponse(_ cmd: String, _ handler: @escaping (String) -> Void) {
        responseHandler = handler
        queue.append(cmd)
        pump()
    }
    private func pump() {
        guard !sending, !queue.isEmpty, let wc = writeChar, let p = peripheral else { return }
        let cmd = queue.removeFirst()
        sending = true
        rxBuffer = ""
        let payload = (cmd + "\r").data(using: .ascii)!
        let type: CBCharacteristicWriteType = wc.properties.contains(.write) ? .withResponse : .withoutResponse
        logLine("TX → \(cmd)")
        p.writeValue(payload, for: wc, type: type)
        // Safety timeout in case no '>' prompt arrives
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self = self, self.sending else { return }
            self.finishCommand()
        }
    }
    private func finishCommand() {
        let resp = rxBuffer
            .replacingOccurrences(of: ">", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !resp.isEmpty { logLine("RX ← \(resp)") }
        if let h = responseHandler { responseHandler = nil; h(resp) }
        sending = false
        pump()
    }

    // MARK: CBCentralManagerDelegate
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:  status = "Ready"
        case .poweredOff: status = "Bluetooth off"; isConnected = false
        case .unauthorized: status = "Bluetooth not allowed"
        default: status = "Bluetooth unavailable"
        }
    }
    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        if !discovered.contains(where: { $0.identifier == p.identifier }) {
            discovered.append(p)
            logLine("Found: \(p.name ?? "Unknown") (\(RSSI))")
        }
    }
    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        status = "Discovering…"
        p.discoverServices(nil)
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        status = "Connect failed"
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        isConnected = false
        writeChar = nil; notifyChar = nil
        status = "Disconnected"
    }

    // MARK: CBPeripheralDelegate
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        for s in p.services ?? [] { p.discoverCharacteristics(nil, for: s) }
    }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for c in s.characteristics ?? [] {
            if c.properties.contains(.notify) || c.properties.contains(.indicate) {
                notifyChar = c
                p.setNotifyValue(true, for: c)
            }
            if c.properties.contains(.write) || c.properties.contains(.writeWithoutResponse) {
                writeChar = c
            }
        }
        if writeChar != nil && notifyChar != nil && !isConnected {
            isConnected = true
            status = "Connected"
            logLine("Connected – initialising adapter")
            initAdapter()
        }
    }
    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard let d = c.value, let s = String(data: d, encoding: .ascii) else { return }
        rxBuffer += s
        if rxBuffer.contains(">") { finishCommand() }
    }
}
