import Foundation
import CoreBluetooth

enum ApplyState { case idle, pending, applying, verified, mismatch, noReply }

/// One stored fault read from a module (UDS 19 02).
struct DTCItem: Identifiable {
    let id = UUID()
    let ecu: String
    let code: String      // 6-hex raw DTC, e.g. "9C5400"
    let status: UInt8     // DTC status byte (bit0 = testFailed)
    var active: Bool { status & 0x01 != 0 }
}

/// A headlight animation = a looping sequence of per-lamp 6-zone bitmasks.
/// Each step sends a UDS 2F InputOutputControl frame to each front headlamp.
struct LightStyle: Identifiable {
    let id: String
    let name: String
    let icon: String
    let periodMs: Int
    let random: Bool
    let steps: [(UInt8, UInt8)]   // (left-lamp zone mask, right-lamp zone mask), 6 bits
}

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

    // MARK: Apply/verify feedback
    @Published var connectedName = ""
    @Published var vin = ""
    @Published var dtcScanning = false
    @Published var dtcResults: [DTCItem] = []
    @Published var dtcScanned: [String] = []      // module names that answered the scan
    @Published var applyState: ApplyState = .idle
    @Published var applyDetail = "Applying to ECU…"
    private var expected: (en: Bool, cut: Int, modeA: Bool)?
    private var awaitingVerify = false
    private var verifyToken = 0
    private let targetName = "V2502615C3"   // the mbito dongle always advertises this

    // MARK: ESP205 Dynamic Select "Last Mode" variant coding
    // Multi-step UDS session on ESP205 (tester 0x7E2 / ECU 0x7EA):
    // 10 03 → 27 0B (seed) → 27 0C (key) → 22 2201 (read 81B) → 2E 2201 (write) → 11 03.
    enum CodingStep { case idle, session, seed, key, read, write, reset }
    @Published var codingState: ApplyState = .idle
    @Published var codingDetail = ""
    @Published var lastModeOn: Bool? = nil        // current read-back state (nil = unknown)
    private let esp205 = (tx: UInt32(0x7E2), rx: UInt32(0x7EA))
    private var codingStep: CodingStep = .idle
    private var codingEnable = false
    private var codingReadOnly = false
    private var codingToken = 0

    // MARK: Headlight animations (UDS 2F zone control to front headlamps)
    @Published var activeLightStyle: String? = nil
    @Published var lightDID: UInt16 = 0x0008     // swap to 0xD008 / 0x0011 if lamps don't respond
    // Front headlamp request/response CAN id pairs, per module variant (pick on-car).
    @Published var lampVariantId: String = "212"
    static let lampVariants: [(id: String, name: String, fl: (UInt32, UInt32), fr: (UInt32, UInt32))] = [
        ("212", "212 / 176", (0x76A, 0x4AD), (0x772, 0x4AE)),
        ("247", "247",       (0x650, 0x5D0), (0x656, 0x5D6))
    ]
    private var lampVariant: (id: String, name: String, fl: (UInt32, UInt32), fr: (UInt32, UInt32)) {
        Self.lampVariants.first { $0.id == lampVariantId } ?? Self.lampVariants[0]
    }
    private var hlFL: (tx: UInt32, rx: UInt32) { (lampVariant.fl.0, lampVariant.fl.1) }
    private var hlFR: (tx: UInt32, rx: UInt32) { (lampVariant.fr.0, lampVariant.fr.1) }
    private var lightTimer: Timer?
    private var lightStep = 0
    private var currentStyle: LightStyle?

    static let lightStyles: [LightStyle] = [
        LightStyle(id: "strobe", name: "Strobe", icon: "bolt.fill", periodMs: 60, random: false,
                   steps: [(0x3F,0x3F),(0x00,0x00)]),
        LightStyle(id: "knight", name: "Knight Rider", icon: "arrow.left.and.right", periodMs: 70, random: false,
                   steps: [(0x01,0),(0x02,0),(0x04,0),(0x08,0),(0x10,0),(0x20,0),
                           (0,0x01),(0,0x02),(0,0x04),(0,0x08),(0,0x10),(0,0x20),
                           (0,0x10),(0,0x08),(0,0x04),(0,0x02),(0,0x01),
                           (0x20,0),(0x10,0),(0x08,0),(0x04,0),(0x02,0)]),
        LightStyle(id: "wave", name: "Wave", icon: "waveform", periodMs: 80, random: false,
                   steps: [(0x01,0x01),(0x03,0x03),(0x07,0x07),(0x0F,0x0F),(0x1F,0x1F),(0x3F,0x3F),
                           (0x1F,0x1F),(0x0F,0x0F),(0x07,0x07),(0x03,0x03),(0x01,0x01),(0,0)]),
        LightStyle(id: "police", name: "Police", icon: "car.fill", periodMs: 55, random: false,
                   steps: [(0x3F,0),(0,0x3F),(0x3F,0),(0,0x3F),(0,0),(0x3F,0x3F),(0,0),(0x3F,0x3F)]),
        LightStyle(id: "pulse", name: "Pulse", icon: "dot.radiowaves.left.and.right", periodMs: 320, random: false,
                   steps: [(0x3F,0x3F),(0x00,0x00)]),
        LightStyle(id: "sparkle", name: "Sparkle", icon: "sparkles", periodMs: 90, random: true, steps: [])
    ]

    // Known ELM327 BLE service/characteristic families (adapter-dependent).
    // We don't hard-filter on scan; on connect we pick any char that is writable+notifiable.
    // Advertised service UUIDs used by compatible adapters: 00FF = mbito/ESP32,
    // the rest are the common BLE ELM327 families (Vgate iCar Pro = FFE0, others FFF0/18F0/FFE5).
    private let knownServiceUUIDs: Set<CBUUID> = [
        CBUUID(string: "00FF"),
        CBUUID(string: "FFF0"), CBUUID(string: "FFE0"),
        CBUUID(string: "18F0"), CBUUID(string: "FFE5")
    ]
    // Name hints for adapters that don't put their service UUID in the advertising packet.
    private let adapterNameHints = ["icar", "vgate", "vlink", "obd", "elm", "v250", "viecar", "konnwei"]

    // MARK: Command queue (ELM327 is a serial, prompt-based device)
    private var queue: [String] = []
    private var sending = false
    private var rxBuffer = ""
    private var responseHandler: ((String) -> Void)?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
        #if targetEnvironment(simulator)
        // Demo state so the full UI renders for CI preview screenshots (no BLE in the sim).
        isConnected = true
        mbitoMode = true
        connectedName = "V2502615C3"
        vin = "WDD2050461A123456"
        applyState = .verified
        lastModeOn = false
        dtcScanned = ["Engine", "Transmission", "Front SAM", "Cluster"]
        dtcResults = [
            DTCItem(ecu: "Engine", code: "9C5400", status: 0x09),
            DTCItem(ecu: "Front SAM", code: "B10A01", status: 0x08),
        ]
        logLine("Preview mode — demo connection")
        #endif
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
        // Scan broadly, then filter in didDiscover to compatible adapters (mbito + ELM327)
        // by advertised service OR name. Filtering by service on scan would miss ELM
        // adapters like the iCar Pro that don't advertise their service in the adv packet.
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
            // Positive read response carries the service echo 0x41. Slice from it and verify.
            let b = Self.hexToBytes(resp)
            if let idx = b.firstIndex(of: 0x41) {
                self.resolveVerify(Array(b[idx...]))
            } else if self.awaitingVerify {
                self.applyState = .noReply; self.awaitingVerify = false
            }
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
        guard !bytes.isEmpty else { logLine("ESP32: empty/invalid hex"); return }
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

    /// Read the car VIN: UDS ReadDataByIdentifier DID F190 → 62 F1 90 + 17 ASCII chars.
    func readVIN() {
        if mbitoChar != nil {
            writeMbito(Self.buildMbitoV2(senderId: 0x7E0, receiverId: 0x7E8, payload: [0x22, 0xF1, 0x90]))
            return
        }
        // ELM327: ATCAF1 reassembles the ISO-TP multiframe, so the reply hex contains 62 F1 90 + VIN.
        guard notifyChar != nil else { return }
        enqueueWithResponse("22F190") { [weak self] resp in
            guard let self = self else { return }
            let b = Self.hexToBytes(resp)
            if let i = b.firstIndex(where: { idx in idx == 0x62 }),
               i + 2 < b.count, b[i+1] == 0xF1, b[i+2] == 0x90 {
                let ascii = b[(i+3)...].prefix(17).map { (32...126).contains($0) ? Character(UnicodeScalar($0)) : " " }
                let v = String(ascii).trimmingCharacters(in: .whitespaces)
                if v.count >= 11 { self.vin = v; self.logLine("VIN ← \(v)") }
            }
        }
    }

    // MARK: DTC scan ------------------------------------------------------------------
    // Request CAN ids (tx) + response (rx) for the modules mbito scanned on this car.
    static let dtcEcus: [(name: String, tx: UInt32, rx: UInt32)] = [
        ("Engine", 0x7E0, 0x7E8), ("Transmission", 0x7E1, 0x7E9),
        ("Module 7E2", 0x7E2, 0x7EA), ("Module 7E3", 0x7E3, 0x7EB), ("Module 7E5", 0x7E5, 0x7ED),
        ("EZS / EIS", 0x607, 0x587), ("Cluster", 0x609, 0x589),
        ("Front SAM", 0x640, 0x5C0), ("Rear SAM", 0x641, 0x5C1),
        ("Module 600", 0x600, 0x580), ("Module 602", 0x602, 0x582),
        ("Module 60D", 0x60D, 0x58D), ("Module 61D", 0x61D, 0x59D),
        ("Module 620", 0x620, 0x5A0), ("Module 650", 0x650, 0x5D0)
    ]

    func scanDTCs() {
        guard mbitoChar != nil, !dtcScanning else { return }
        dtcResults = []; dtcScanned = []; dtcScanning = true
        logLine("DTC scan: \(Self.dtcEcus.count) modules")
        for (i, e) in Self.dtcEcus.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.18) { [weak self] in
                guard let self = self, self.dtcScanning else { return }
                self.writeMbito(Self.buildMbitoV2(senderId: e.tx, receiverId: e.rx, payload: [0x19, 0x02, 0x0D]))
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(Self.dtcEcus.count) * 0.18 + 1.2) { [weak self] in
            self?.dtcScanning = false
        }
    }

    /// Clear fault codes on every scanned module (UDS 14 FF FF FF).
    func clearDTCs() {
        guard mbitoChar != nil else { return }
        logLine("DTC clear: all modules")
        for (i, e) in Self.dtcEcus.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.12) { [weak self] in
                self?.writeMbito(Self.buildMbitoV2(senderId: e.tx, receiverId: e.rx, payload: [0x14, 0xFF, 0xFF, 0xFF]))
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.dtcResults = []; self?.dtcScanned = []
        }
    }

    private func handleDTCResponse(sender: UInt32, _ cmd: [UInt8]) {
        let name = Self.dtcEcus.first { $0.tx == sender }?.name ?? String(format: "Module %03X", sender)
        if !dtcScanned.contains(name) { dtcScanned.append(name) }
        // 59 02 <mask> then groups of [DTC hi, mid, lo, status]
        var i = 3
        while i + 3 < cmd.count {
            let a = cmd[i], b = cmd[i+1], c = cmd[i+2], st = cmd[i+3]
            if a == 0 && b == 0 && c == 0 { break }
            let code = String(format: "%02X%02X%02X", a, b, c)
            dtcResults.append(DTCItem(ecu: name, code: code, status: st))
            i += 4
        }
    }

    // MARK: ESP205 Dynamic Select Last Mode coding -----------------------------------

    /// Read the current Last-Mode coding state (no write).
    func readDynamicSelectLastMode() { beginCoding(enable: false, readOnly: true) }

    /// Apply Last-Mode on/off. Full unlock + read-modify-write of bytes 77..80 only.
    func codeDynamicSelectLastMode(enable: Bool) { beginCoding(enable: enable, readOnly: false) }

    private func beginCoding(enable: Bool, readOnly: Bool) {
        guard mbitoChar != nil else { codingState = .noReply; return }
        guard codingStep == .idle else { return }   // one session at a time
        codingEnable = enable
        codingReadOnly = readOnly
        codingState = .applying
        codingDetail = readOnly ? "Reading coding…" : "Entering session…"
        codingStep = .session
        logLine("ESP205 coding: \(readOnly ? "read" : (enable ? "enable" : "disable")) Last-Mode")
        sendEsp([0x10, 0x03])                        // extended session
        armCodingTimeout()
    }

    private func sendEsp(_ uds: [UInt8], responseLen: UInt16 = 64, timeout: UInt16 = 500,
                         full: Bool = false) {
        // Default to the proven V2 0x40 path for every length — writeMbito now chunks the
        // BLE packet so a long command (the 84-byte coding write) is delivered intact.
        // `full` forces the FullScript 0x33 path only if we need it as a fallback.
        let frame = full
            ? Self.buildMbitoFull(senderId: esp205.tx, receiverId: esp205.rx,
                                  payload: uds, timeout: timeout, responseLen: responseLen)
            : Self.buildMbitoV2(senderId: esp205.tx, receiverId: esp205.rx,
                                payload: uds, timeout: timeout, responseLen: responseLen)
        writeMbito(frame)
    }

    private func armCodingTimeout() {
        codingToken += 1
        let tok = codingToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 9) { [weak self] in
            guard let self = self, tok == self.codingToken, self.codingStep != .idle else { return }
            self.logLine("ESP205 coding: timeout at \(self.codingStep)")
            self.codingStep = .idle
            self.codingState = .noReply
        }
    }

    private func failCoding(_ why: String) {
        logLine("ESP205 coding failed: \(why)")
        codingStep = .idle
        codingState = .mismatch
    }

    /// Drive the coding state machine from an ESP205 UDS reply (`cmd` = UDS bytes).
    private func handleCodingResponse(_ cmd: [UInt8]) {
        guard codingStep != .idle, let sid = cmd.first else { return }
        if sid == 0x7F {                              // negative response
            failCoding("NRC \(cmd.count > 2 ? String(format: "%02X", cmd[2]) : "?") at \(codingStep)")
            return
        }
        codingToken += 1                              // cancel the pending timeout; we re-arm per step
        switch codingStep {
        case .session:                                // expect 50 03
            codingStep = .seed
            codingDetail = "Unlocking…"
            sendEsp([0x27, ESP205.accessLevel])       // 27 0B request seed
            armCodingTimeout()

        case .seed:                                   // expect 67 0B <8 seed>
            guard cmd.count >= 10, cmd[0] == 0x67 else { failCoding("bad seed reply"); return }
            let seed = Array(cmd[2..<10])
            let key = ESP205.key(fromSeed: seed)
            logLine("ESP205 seed \(seed.map{String(format:"%02X",$0)}.joined()) → key \(key.map{String(format:"%02X",$0)}.joined())")
            codingStep = .key
            sendEsp([0x27, ESP205.accessLevel + 1] + key)   // 27 0C <key>
            armCodingTimeout()

        case .key:                                    // expect 67 0C
            guard cmd[0] == 0x67 else { failCoding("key rejected"); return }
            codingStep = .read
            codingDetail = "Reading coding…"
            sendEsp(DynamicSelectLastMode.readBlock, responseLen: 96)  // 22 2201
            armCodingTimeout()

        case .read:                                   // expect 62 22 01 <81 bytes>
            guard cmd.count >= 84, cmd[0] == 0x62, cmd[1] == 0x22, cmd[2] == 0x01 else {
                failCoding("bad read reply (\(cmd.count)B)"); return
            }
            let block = Array(cmd[3..<84])            // 81-byte coding block
            let cur = Array(block[DynamicSelectLastMode.fieldOffset..<DynamicSelectLastMode.fieldOffset+4])
            let isOn = (cur == DynamicSelectLastMode.valueOn)
            lastModeOn = isOn
            logLine("ESP205 bytes 77..80 = \(cur.map{String(format:"%02X",$0)}.joined()) (\(isOn ? "Last-Mode 4h" : "off"))")
            if codingReadOnly {                       // read-only: done
                codingStep = .idle
                codingState = .verified
                return
            }
            let newBlock = DynamicSelectLastMode.apply(block: block, enable: codingEnable)
            if newBlock == block {                    // already in desired state
                codingStep = .idle
                codingState = .verified
                lastModeOn = codingEnable
                return
            }
            codingStep = .write
            codingDetail = "Writing coding…"
            // V2 0x40 path (the dongle acknowledges it); the earlier failure was BLE-MTU
            // truncation of the 109-byte frame, now fixed by chunking in writeMbito. 3s EEPROM window.
            sendEsp(DynamicSelectLastMode.writeBlock + newBlock, responseLen: 32, timeout: 3000)  // 2E 2201 <81 bytes>
            armCodingTimeout()

        case .write:                                  // expect 6E 22 01
            guard cmd[0] == 0x6E else { failCoding("write rejected"); return }
            codingStep = .reset
            codingDetail = "Resetting ECU…"
            sendEsp([0x11, 0x03])                      // soft reset
            armCodingTimeout()

        case .reset:                                  // expect 51 03
            codingStep = .idle
            codingState = .verified
            lastModeOn = codingEnable
            logLine("ESP205 Last-Mode \(codingEnable ? "enabled" : "disabled") ✓")

        case .idle:
            break
        }
    }

    // MARK: Headlight animation engine ------------------------------------------------

    func toggleLights(_ style: LightStyle) {
        if activeLightStyle == style.id { stopLights() } else { startLights(style) }
    }

    func startLights(_ style: LightStyle) {
        stopLights()
        guard mbitoChar != nil else { logLine("lights: not connected"); return }
        currentStyle = style
        activeLightStyle = style.id
        lightStep = 0
        // Enter extended diagnostic session on both headlamps once.
        sendUDS(hlFL, [0x10, 0x03]); sendUDS(hlFR, [0x10, 0x03])
        logLine("lights: \(style.name) start (DID \(String(format: "%04X", lightDID)))")
        lightTimer = Timer.scheduledTimer(withTimeInterval: Double(style.periodMs) / 1000.0, repeats: true) { [weak self] _ in
            self?.lightTick()
        }
    }

    func stopLights() {
        lightTimer?.invalidate(); lightTimer = nil
        currentStyle = nil
        activeLightStyle = nil
        // All zones off on both lamps.
        if mbitoChar != nil { sendZone(hlFL, 0x00); sendZone(hlFR, 0x00) }
    }

    private func lightTick() {
        guard let s = currentStyle else { return }
        let l: UInt8, r: UInt8
        if s.random {
            l = UInt8.random(in: 0...0x3F); r = UInt8.random(in: 0...0x3F)
        } else {
            let step = s.steps[lightStep % s.steps.count]
            l = step.0; r = step.1
        }
        sendZone(hlFL, l); sendZone(hlFR, r)
        lightStep += 1
    }

    /// UDS InputOutputControlByIdentifier zone frame: 2F <DID> 03 <zoneMask> 3F 00
    private func sendZone(_ lamp: (tx: UInt32, rx: UInt32), _ mask: UInt8) {
        sendUDS(lamp, [0x2F, UInt8(lightDID >> 8), UInt8(lightDID & 0xFF), 0x03, mask, 0x3F, 0x00])
    }

    private func sendUDS(_ lamp: (tx: UInt32, rx: UInt32), _ uds: [UInt8]) {
        guard mbitoChar != nil else { return }
        writeMbito(Self.buildMbitoV2(senderId: lamp.tx, receiverId: lamp.rx, payload: uds))
    }

    // MARK: High-level apply/verify (drives the UI feedback) ------------------------

    func markPending() {
        if applyState != .applying { applyState = .pending }
    }

    /// Apply config, then auto-read-back and verify the ECU echoes what we set.
    func applyConfig(enable: Bool, cut: Int, modeA: Bool) {
        expected = (enable, cut, modeA)
        applyState = .applying
        applyDetail = "Applying to ECU…"
        awaitingVerify = false
        let c = max(1, min(4, cut))
        if mbitoMode {
            sendMbitoFeature(1, enable ? 1 : 0)
            sendMbitoFeature(2, c)
            sendMbitoFeature(3, modeA ? 1 : 0)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                guard let self = self else { return }
                self.applyDetail = "Reading back…"
                self.awaitingVerify = true
                self.sendMbitoReadback()
            }
        } else {
            setFeature(1, enable ? 1 : 0); setFeature(2, c); setFeature(3, modeA ? 1 : 0)
            applyDetail = "Reading back…"
            awaitingVerify = true
            readBack()
        }
        armVerifyTimeout()
    }

    /// Plain read-back (no expected comparison — just confirm comms).
    func readConfig() {
        expected = nil
        applyState = .applying
        applyDetail = "Reading back…"
        awaitingVerify = true
        if mbitoMode { sendMbitoReadback() } else { readBack() }
        armVerifyTimeout()
    }

    private func armVerifyTimeout() {
        verifyToken += 1
        let tok = verifyToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
            guard let self = self, tok == self.verifyToken else { return }
            if self.applyState == .applying { self.applyState = .noReply; self.awaitingVerify = false }
        }
    }

    /// Parse a `41 <enable> <depth> <mode> …` config reply and resolve the apply state.
    private func resolveVerify(_ cmd: [UInt8]) {
        guard awaitingVerify, let first = cmd.first, first == 0x41 else { return }
        awaitingVerify = false
        verifyToken += 1
        guard let e = expected, cmd.count >= 4 else { applyState = .verified; return }
        let en = cmd[1] != 0, ct = Int(cmd[2]), md = cmd[3] != 0
        applyState = (en == e.en && ct == e.cut && md == e.modeA) ? .verified : .mismatch
    }

    private func writeMbito(_ bytes: [UInt8]) {
        guard let p = peripheral, let c = mbitoChar else { logLine("ESP32: not connected to 0xFF01"); return }
        let type: CBCharacteristicWriteType =
            c.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        // The dongle negotiates a small ATT MTU; a frame larger than one BLE packet (e.g. the
        // 109-byte coding write) truncates on a single writeValue. mbito requests MTU 512 for
        // this reason. iOS won't let us force MTU, but the dongle reassembles multiple writes
        // via its 4-byte length header — so chunk any oversized frame into MTU-sized packets.
        let maxLen = max(20, p.maximumWriteValueLength(for: type))
        let shown = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        logLine("TX → \(shown)  [\(bytes.count)B, mtu \(maxLen)]")
        if bytes.count <= maxLen {
            p.writeValue(Data(bytes), for: c, type: type)
            return
        }
        var off = 0, idx = 0
        while off < bytes.count {
            let end = min(off + maxLen, bytes.count)
            let chunk = Data(bytes[off..<end])
            // small stagger so back-to-back writeWithoutResponse packets aren't dropped
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(idx) * 0.02) { [weak self] in
                guard let self = self, self.mbitoChar != nil else { return }
                p.writeValue(chunk, for: c, type: type)
            }
            off = end; idx += 1
        }
    }

    /// mbito request frame — VERIFIED against a live HCI capture of the mbito app.
    /// = 4-byte outer BLE header + 21-byte UDS struct + raw UDS payload. All LE.
    ///   outer:  [0]=0x40 "send request"  [1]=seq(0x01)  [2-3]=UDS-struct length (LE)
    ///   struct: [0]req_type=0x00 [1]req_nr=0x00 [2]resp_type=0xFF
    ///           [3-6]sender(LE) [7-10]receiver(LE) [11-12]timeout [13-14]resp_timeout
    ///           [15-16]resp_len [17-18]req_len [19-20]actual_res_len [21+]command
    static func buildMbitoV2(senderId: UInt32, receiverId: UInt32, payload: [UInt8],
                             timeout: UInt16 = 500, responseLen: UInt16 = 32, seq: UInt8 = 1) -> [UInt8] {
        var u = [UInt8](repeating: 0, count: 21 + payload.count)
        func le32(_ v: UInt32, _ at: Int) {
            u[at] = UInt8(v & 0xFF); u[at+1] = UInt8((v >> 8) & 0xFF)
            u[at+2] = UInt8((v >> 16) & 0xFF); u[at+3] = UInt8((v >> 24) & 0xFF)
        }
        func le16(_ v: UInt16, _ at: Int) { u[at] = UInt8(v & 0xFF); u[at+1] = UInt8((v >> 8) & 0xFF) }
        u[0] = 0x00                    // request_type
        u[1] = 0x00                    // request_nr
        u[2] = 0xFF                    // response_type
        le32(senderId, 3)              // sender CAN id (LE)
        le32(receiverId, 7)            // receiver CAN id (LE)
        le16(timeout, 11)              // timeout ms
        le16(0, 13)                    // response_timeout
        le16(responseLen, 15)          // response_len (expected)
        le16(UInt16(payload.count), 17)   // request_len
        le16(UInt16(payload.count), 19)   // actual_res_len
        for (i, b) in payload.enumerated() { u[21 + i] = b }
        // outer BLE header: 40 <seq> <len LE>
        var f: [UInt8] = [0x40, seq, UInt8(u.count & 0xFF), UInt8((u.count >> 8) & 0xFF)]
        f.append(contentsOf: u)
        return f
    }

    /// Build a FullScript (0x33) request — mbito's multi-frame path for long commands.
    /// The V2 single frame (0x40) is length-capped on the dongle, so an 81-byte coding
    /// write must go via FullScript: same 21-byte UDS struct + payload, but the outer
    /// header announces frameCount so the dongle buffers the whole command before TX.
    /// Outer header: [0x33, frameCount, structLen LE] — best reconstruction from the mbito
    /// bundle (makeRequest/getFramesCount=floor(len/16)); iterating on-car from the raw log.
    static func buildMbitoFull(senderId: UInt32, receiverId: UInt32, payload: [UInt8],
                               timeout: UInt16 = 3000, responseLen: UInt16 = 64) -> [UInt8] {
        var u = [UInt8](repeating: 0, count: 21 + payload.count)
        func le32(_ v: UInt32, _ at: Int) {
            u[at] = UInt8(v & 0xFF); u[at+1] = UInt8((v >> 8) & 0xFF)
            u[at+2] = UInt8((v >> 16) & 0xFF); u[at+3] = UInt8((v >> 24) & 0xFF)
        }
        func le16(_ v: UInt16, _ at: Int) { u[at] = UInt8(v & 0xFF); u[at+1] = UInt8((v >> 8) & 0xFF) }
        u[0] = 0x00; u[1] = 0x00; u[2] = 0xFF
        le32(senderId, 3); le32(receiverId, 7)
        le16(timeout, 11); le16(0, 13); le16(responseLen, 15)
        le16(UInt16(payload.count), 17); le16(0, 19)
        for (i, b) in payload.enumerated() { u[21 + i] = b }
        let frameCount = (u.count + 15) / 16                         // ceil(len/16)
        var f: [UInt8] = [0x33, UInt8(frameCount & 0xFF),
                          UInt8(u.count & 0xFF), UInt8((u.count >> 8) & 0xFF)]
        f.append(contentsOf: u)
        return f
    }

    /// Init handshake the mbito app runs on connect (observed in the capture):
    /// 04 00 00 00 (session?) then 01 00 00 00 (get firmware version → "v1.xx").
    func mbitoInit() {
        writeMbito([0x04, 0x00, 0x00, 0x00])
        writeMbito([0x01, 0x00, 0x00, 0x00])
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
        case .poweredOn:  status = "Ready"; startScan()
        case .poweredOff: status = "Bluetooth off"; isConnected = false
        case .unauthorized: status = "Bluetooth not allowed"
        default: status = "Bluetooth unavailable"
        }
    }
    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        // Only surface compatible adapters: those advertising a known service, or whose
        // name looks like an OBD adapter. Keeps phones/watches/etc. out of the list.
        let advServices = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let name = (p.name ?? "").lowercased()
        let looksCompatible = advServices.contains(where: { knownServiceUUIDs.contains($0) })
            || adapterNameHints.contains(where: { name.contains($0) })
        guard looksCompatible else { return }
        if !discovered.contains(where: { $0.identifier == p.identifier }) {
            discovered.append(p)
            logLine("Found: \(p.name ?? "Unknown") (\(RSSI))")
        }
        // Auto-connect to the known mbito dongle name.
        if !isConnected, p.name == targetName {
            logLine("Auto-connecting to \(targetName)")
            connect(p)
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
        lightTimer?.invalidate(); lightTimer = nil; currentStyle = nil; activeLightStyle = nil
        mbitoChar = nil; mbitoMode = false
        connectedName = ""; vin = ""; applyState = .idle; awaitingVerify = false
        status = "Disconnected"
        // Keep trying to reconnect to the dongle.
        startScan()
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
                    connectedName = p.name ?? "V2502615C3"
                    applyState = .idle
                    status = "Connected (ESP32 0xFF01)"
                    logLine("ESP32 dongle detected — subscribing to 0xFF01")
                    // Replay the app's connect handshake once the CCCD write settles.
                    vin = ""
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                        self?.logLine("ESP32 init handshake (04/01)")
                        self?.mbitoInit()
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                        self?.readVIN()
                    }
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
            connectedName = p.name ?? ""
            applyState = .idle
            status = "Connected"
            logLine("Connected – initialising adapter")
            vin = ""
            initAdapter()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.readVIN() }
        }
    }
    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard let d = c.value else { return }
        if mbitoMode {
            let bytes = [UInt8](d)
            let hex = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
            lastMbitoRx = hex
            if let a = String(data: d, encoding: .ascii), a.contains("enabled") {
                logLine("RX ← \(hex)   (dongle ready: \"enabled\")")
            } else {
                logLine("RX ← \(hex)")
            }
            // Verify: a C0 response carries the UDS reply command starting at offset 25.
            if bytes.count >= 26, bytes[0] == 0xC0 {
                let cmd = Array(bytes[25...])
                let replySender = UInt32(bytes[7]) | UInt32(bytes[8]) << 8
                    | UInt32(bytes[9]) << 16 | UInt32(bytes[10]) << 24
                // ESP205 variant-coding session takes priority while active.
                if codingStep != .idle, replySender == esp205.tx {
                    handleCodingResponse(cmd); return
                }
                resolveVerify(cmd)
                // VIN reply: 62 F1 90 <17 ASCII chars>
                if cmd.count >= 4, cmd[0] == 0x62, cmd[1] == 0xF1, cmd[2] == 0x90 {
                    let ascii = cmd[3...].prefix(17).map { (32...126).contains($0) ? Character(UnicodeScalar($0)) : " " }
                    let v = String(ascii).trimmingCharacters(in: .whitespaces)
                    if v.count >= 11 { vin = v; logLine("VIN ← \(v)") }
                }
                // DTC reply: 59 02 <mask> [dtc3 status]...  (sender id echoed at bytes[7..10] LE)
                if cmd.count >= 3, cmd[0] == 0x59, cmd[1] == 0x02 {
                    let sender = UInt32(bytes[7]) | UInt32(bytes[8]) << 8
                        | UInt32(bytes[9]) << 16 | UInt32(bytes[10]) << 24
                    handleDTCResponse(sender: sender, cmd)
                }
            }
            return
        }
        guard let s = String(data: d, encoding: .ascii) else { return }
        rxBuffer += s
        if rxBuffer.contains(">") { finishCommand() }
    }
}
