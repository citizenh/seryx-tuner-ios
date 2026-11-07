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

    // MARK: mbito dongle (custom BLE transport, reverse-engineered from lt.pixinn.mbito)
    // Service 0x00FF, single characteristic 0xFF01 used for both TX (writeWithoutResponse)
    // and RX (notify). Not ELM327 — we send the binary V2 request frame, not AT text.
    @Published var mbitoMode = false
    @Published var lastMbitoRx = ""
    private let mbitoCharUUID = CBUUID(string: "FF01")
    private var mbitoChar: CBCharacteristic?

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

    /// Initialise the ELM327 for 11-bit CAN @500k to header 7E0.
    /// ATCAF1 keeps ISO-TP (ISO15765) auto-formatting ON so the adapter adds the
    /// PCI length byte on TX and strips/reassembles it on RX — exactly what the
    /// J2534 transport in ECUTuner does. With CAF0 the ECU sees a malformed
    /// single-frame (PCI=0x01) and silently drops the 01 A0 … config request.
    /// NOTE: no "ATZ". On ESP32-based dongles that emulate ELM327, ATZ is often a
    /// real MCU reboot, which drops the BLE link the instant we connect. "ATE0"
    /// (echo off) is a safe, non-disruptive first command.
    func initAdapter() {
        enqueue(["ATE0", "ATL0", "ATS0", "ATH1", "ATSP6", "ATCAF1", "ATSH7E0"])
    }

    /// Send one config byte: 01 A0 <feat> <val>
    func setFeature(_ feat: Int, _ val: Int) {
        let cmd = String(format: "01A0%02X%02X", feat & 0xFF, val & 0xFF)
        enqueue([cmd])
    }

    /// Apply the whole upshift config in one shot, then read back to confirm.
    /// feat1=enable, feat2=cut cylinders (1..4), feat3=mode (A=1 / B=0).
    /// Mirrors ECUTuner's CfgApply, which ends the batch with a 01 A1 read.
    /// The adapter is initialised once on connect, so we don't re-run ATZ here
    /// (that reset would drop the header and slow every apply).
    func applyUpshift(enable: Bool, cut: Int, modeA: Bool) {
        setFeature(1, enable ? 1 : 0)
        setFeature(2, max(1, min(4, cut)))
        setFeature(3, modeA ? 1 : 0)
        status = "Config sent — verifying…"
        readBack()
    }

    /// Read back current config: 01 A1  → response parsed into lastReadback.
    /// Positive reply is 41 <enable> <depth> <mode> …
    func readBack() {
        enqueueWithResponse("01A1") { [weak self] resp in
            guard let self = self else { return }
            self.lastReadback = resp
            self.logLine("READBACK ← \(resp)")
            // Positive read response starts with service echo 0x41 (0x01 + 0x40).
            let clean = resp.replacingOccurrences(of: " ", with: "").uppercased()
            self.status = clean.contains("41A1") || clean.hasPrefix("41") || clean.contains("7E8") && clean.contains("41")
                ? "Applied ✓" : "No valid reply"
        }
    }

    /// Send an arbitrary raw command (debug box).
    /// In mbito mode the box carries raw hex bytes (written to 0xFF01); otherwise ELM AT text.
    func sendRaw(_ cmd: String) {
        if mbitoMode { sendMbitoHex(cmd); return }
        let c = cmd.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !c.isEmpty else { return }
        enqueue([c])
    }

    // MARK: mbito send ---------------------------------------------------------------

    /// Write raw bytes (given as a hex string) straight to the mbito 0xFF01 characteristic.
    func sendMbitoHex(_ hex: String) {
        let bytes = Self.hexToBytes(hex)
        guard !bytes.isEmpty else { logLine("mbito: empty/invalid hex"); return }
        writeMbito(bytes)
    }

    /// Build + send the reverse-engineered V2 request frame.
    /// feat/val go in as the UDS payload 01 A0 <feat> <val>; set=0xA0, get would be 0xA1.
    func sendMbitoFeature(_ feat: Int, _ val: Int) {
        let payload: [UInt8] = [0x01, 0xA0, UInt8(feat & 0xFF), UInt8(val & 0xFF)]
        let frame = Self.buildMbitoV2(senderId: 0x7E0, receiverId: 0x7E8, payload: payload)
        writeMbito(frame)
    }

    /// Read back current config via the mbito dongle: UDS payload 01 A1.
    func sendMbitoReadback() {
        let frame = Self.buildMbitoV2(senderId: 0x7E0, receiverId: 0x7E8, payload: [0x01, 0xA1])
        writeMbito(frame)
    }

    private func writeMbito(_ bytes: [UInt8]) {
        guard let p = peripheral, let c = mbitoChar else { logLine("mbito: not connected to 0xFF01"); return }
        let data = Data(bytes)
        let type: CBCharacteristicWriteType =
            c.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        let shown = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        logLine("TX → \(shown)")
        p.writeValue(data, for: c, type: type)
    }

    /// mbito V2 request frame (21-byte header + raw UDS payload), all multi-byte fields LE.
    /// Layout (from decompiled app): [0]request_type [1]request_nr [2]response_type
    /// [3-6]sender(LE) [7-10]receiver(LE) [11-12]timeout [13-14]response_timeout
    /// [15-16]response_len [17-18]request_len [19-20]actual_res_len [21+]command.
    static func buildMbitoV2(senderId: UInt32, receiverId: UInt32, payload: [UInt8],
                             requestType: UInt8 = 0x40, requestNr: UInt8 = 0, responseType: UInt8 = 0,
                             timeout: UInt16 = 500, responseTimeout: UInt16 = 0, responseLen: UInt16 = 0) -> [UInt8] {
        var f = [UInt8](repeating: 0, count: 21 + payload.count)
        f[0] = requestType
        f[1] = requestNr
        f[2] = responseType
        func le32(_ v: UInt32, _ at: Int) {
            f[at] = UInt8(v & 0xFF); f[at+1] = UInt8((v >> 8) & 0xFF)
            f[at+2] = UInt8((v >> 16) & 0xFF); f[at+3] = UInt8((v >> 24) & 0xFF)
        }
        func le16(_ v: UInt16, _ at: Int) { f[at] = UInt8(v & 0xFF); f[at+1] = UInt8((v >> 8) & 0xFF) }
        le32(senderId, 3)
        le32(receiverId, 7)
        le16(timeout, 11)
        le16(responseTimeout, 13)
        le16(responseLen, 15)
        let plen = UInt16(payload.count)
        le16(plen, 17)
        le16(plen, 19)
        for (i, b) in payload.enumerated() { f[21 + i] = b }
        return f
    }

    static func hexToBytes(_ s: String) -> [UInt8] {
        let clean = s.filter { $0.isHexDigit }
        var out: [UInt8] = []
        var i = clean.startIndex
        while i < clean.endIndex {
            let j = clean.index(i, offsetBy: 2, limitedBy: clean.endIndex) ?? clean.endIndex
            if j == i { break }
            if let b = UInt8(clean[i..<j], radix: 16) { out.append(b) }
            i = j
        }
        return out
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
        mbitoChar = nil; mbitoMode = false
        status = "Disconnected"
    }

    // MARK: CBPeripheralDelegate
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        for s in p.services ?? [] { p.discoverCharacteristics(nil, for: s) }
    }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for c in s.characteristics ?? [] {
            // mbito dongle: bind directly to 0xFF01 (TX + RX), subscribe, skip AT init.
            if c.uuid == mbitoCharUUID {
                mbitoChar = c
                writeChar = c
                notifyChar = c
                mbitoMode = true
                p.setNotifyValue(true, for: c)
                if !isConnected {
                    isConnected = true
                    status = "Connected (mbito 0xFF01)"
                    logLine("mbito dongle detected — subscribed to 0xFF01, no AT init")
                }
                continue
            }
            if c.properties.contains(.notify) || c.properties.contains(.indicate) {
                notifyChar = c
                p.setNotifyValue(true, for: c)
            }
            if c.properties.contains(.write) || c.properties.contains(.writeWithoutResponse) {
                writeChar = c
            }
        }
        if !mbitoMode && writeChar != nil && notifyChar != nil && !isConnected {
            isConnected = true
            status = "Connected"
            logLine("Connected – initialising adapter")
            initAdapter()
        }
    }
    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard let d = c.value else { return }
        if mbitoMode {
            let hex = d.map { String(format: "%02X", $0) }.joined(separator: " ")
            lastMbitoRx = hex
            if let a = String(data: d, encoding: .ascii), a.contains("enabled") {
                logLine("RX ← \(hex)   (dongle ready: \"enabled\")")
            } else {
                logLine("RX ← \(hex)")
            }
            return
        }
        guard let s = String(data: d, encoding: .ascii) else { return }
        rxBuffer += s
        if rxBuffer.contains(">") { finishCommand() }
    }
}
