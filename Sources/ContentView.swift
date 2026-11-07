import SwiftUI
import CoreBluetooth

struct ContentView: View {
    @EnvironmentObject var ble: BLEManager

    @State private var enable = true
    @State private var cut = 1            // cylinders cut: 1..4
    @State private var modeA = false      // false = Mode B, true = Mode A
    @State private var showRaw = false
    @State private var rawCmd = ""

    private let orange = Color(red: 1.0, green: 0.42, blue: 0.0)

    var body: some View {
        NavigationView {
            Form {
                connectionSection
                if ble.isConnected {
                    configSection
                    actionSection
                }
                if showRaw { rawSection }
                logSection
            }
            .navigationTitle("SERYX TUNER")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(showRaw ? "Hide raw" : "Raw") { showRaw.toggle() }
                }
            }
        }
    }

    // MARK: Connection
    private var connectionSection: some View {
        Section(header: Text("Adapter")) {
            HStack {
                Circle().fill(ble.isConnected ? .green : .gray).frame(width: 10, height: 10)
                Text(ble.status).foregroundColor(.secondary)
                Spacer()
                if ble.isConnected {
                    Button("Disconnect", role: .destructive) { ble.disconnect() }
                } else {
                    Button(ble.isScanning ? "Scanning…" : "Scan") { ble.startScan() }
                        .disabled(ble.isScanning)
                }
            }
            if !ble.isConnected {
                ForEach(ble.discovered, id: \.identifier) { p in
                    Button {
                        ble.connect(p)
                    } label: {
                        HStack {
                            Image(systemName: "dot.radiowaves.left.and.right")
                            Text(p.name ?? "Unknown adapter")
                            Spacer()
                        }
                    }
                }
            }
        }
    }

    // MARK: Config
    private var configSection: some View {
        Section(header: Text("Upshift cut")) {
            Toggle("Enabled", isOn: $enable).tint(orange)

            Stepper(value: $cut, in: 1...4) {
                HStack {
                    Text("Cylinders cut")
                    Spacer()
                    Text("\(cut)").bold().foregroundColor(orange)
                }
            }

            Picker("Mode", selection: $modeA) {
                Text("B — only when ECU cuts").tag(false)
                Text("A — every Sport+ WOT upshift").tag(true)
            }
            .pickerStyle(.inline)
        }
    }

    // MARK: Actions
    private var actionSection: some View {
        Section(footer: ble.mbitoMode
                ? Text("mbito dongle: sends the V2 frame to 0xFF01 (01 A0 → 7E0). Tune request_type / timeout in the Raw box if no reply.")
                : Text("")) {
            Button {
                if ble.mbitoMode {
                    ble.sendMbitoFeature(1, enable ? 1 : 0)
                    ble.sendMbitoFeature(2, max(1, min(4, cut)))
                    ble.sendMbitoFeature(3, modeA ? 1 : 0)
                    ble.sendMbitoReadback()
                } else {
                    ble.applyUpshift(enable: enable, cut: cut, modeA: modeA)
                }
            } label: {
                HStack { Spacer(); Text(ble.mbitoMode ? "APPLY (mbito)" : "APPLY TO ECU").bold(); Spacer() }
            }
            .listRowBackground(orange)
            .foregroundColor(.black)

            Button("Read back from ECU") {
                if ble.mbitoMode { ble.sendMbitoReadback() } else { ble.readBack() }
            }
            if ble.mbitoMode, !ble.lastMbitoRx.isEmpty {
                Text("RX: \(ble.lastMbitoRx)")
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundColor(.secondary)
            } else if !ble.lastReadback.isEmpty {
                Text("ECU: \(ble.lastReadback)")
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: Raw debug
    private var rawSection: some View {
        Section(header: Text("Raw command")) {
            HStack {
                TextField("e.g. 01A00201", text: $rawCmd)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
                Button("Send") { ble.sendRaw(rawCmd); rawCmd = "" }
                    .disabled(!ble.isConnected)
            }
            if ble.mbitoMode {
                Text("mbito frame → 0xFF01 (verified), LE:\n40 01 19 00 | 00 00 FF | E0 07 00 00 | E8 07 00 00 | F4 01 | 00 00 | 20 00 | 04 00 | 04 00 | 01 A0 01 01\n[outer 40/seq/len] [rt/nr/respt] sender receiver tmo rtmo rlen reqln ares  payload")
                    .font(.caption2).foregroundColor(.secondary)
            } else {
                Text("SET = 01 A0 <feat> <val> · GET = 01 A1\nfeat1=enable  feat2=cut(1-4)  feat3=mode(A=1/B=0)")
                    .font(.caption2).foregroundColor(.secondary)
            }
        }
    }

    // MARK: Log
    private var logSection: some View {
        Section(header: HStack { Text("Log"); Spacer(); Button("Clear") { ble.clearLog() } }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(ble.log.suffix(60).enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(size: 11, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(height: 180)
        }
    }
}
