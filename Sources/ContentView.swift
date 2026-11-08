import SwiftUI
import CoreBluetooth

// MARK: - ECUTuner theme
private extension Color {
    init(hex: UInt) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}
private enum T {
    static let bg = Color(hex: 0x1D1E20)
    static let card = Color(hex: 0x252629)
    static let cardBorder = Color(hex: 0x3C3D41)
    static let line = Color(hex: 0x46474B)
    static let amber = Color(hex: 0xFFA51F)
    static let grey = Color(hex: 0x9B9DA3)
    static let greyLt = Color(hex: 0xC8CACF)
    static let green = Color(hex: 0x3DDC73)
    static let red = Color(hex: 0xFF6B5E)
}
private let targetDongle = "V2502615C3"

// MARK: - ECUTuner "ET" logo
struct ECULogo: View {
    var size: CGFloat = 32
    var body: some View {
        let s = size / 160
        ZStack(alignment: .topLeading) {
            Path { p in
                p.move(to: CGPoint(x: 24*s, y: 0))
                p.addLine(to: CGPoint(x: 160*s, y: 0))
                p.addLine(to: CGPoint(x: 136*s, y: 160*s))
                p.addLine(to: CGPoint(x: 0, y: 160*s))
                p.closeSubpath()
            }.fill(T.amber)
            Path { p in
                for (i, pt) in [(26,38),(72,38),(72,54),(44,54),(44,72),(68,72),(68,88),(44,88),(44,106),(72,106),(72,122),(26,122)].enumerated() {
                    let c = CGPoint(x: CGFloat(pt.0)*s, y: CGFloat(pt.1)*s)
                    if i == 0 { p.move(to: c) } else { p.addLine(to: c) }
                }
                p.closeSubpath()
                for (i, pt) in [(78,38),(132,38),(132,54),(114,54),(114,122),(96,122),(96,54),(78,54)].enumerated() {
                    let c = CGPoint(x: CGFloat(pt.0)*s, y: CGFloat(pt.1)*s)
                    if i == 0 { p.move(to: c) } else { p.addLine(to: c) }
                }
                p.closeSubpath()
            }
            .fill(.white)
            .transformEffect(CGAffineTransform(a: 1, b: 0, c: CGFloat(tan(-8 * Double.pi / 180)), d: 1, tx: 12*s, ty: 0))
        }
        .frame(width: size, height: size)
    }
}

struct AppHeader: View {
    var body: some View {
        HStack(spacing: 11) {
            ECULogo(size: 32)
            Text("ECU TUNER").font(.system(size: 23, weight: .heavy)).foregroundColor(T.amber)
            Spacer()
        }
        .padding(.top, 8).padding(.bottom, 4)
    }
}

// MARK: - Segmented picker
struct SegPicker: View {
    let options: [(tag: Int, label: String)]
    @Binding var selection: Int
    var body: some View {
        HStack(spacing: 6) {
            ForEach(options, id: \.tag) { opt in
                let on = selection == opt.tag
                Text(opt.label)
                    .font(.system(size: opt.label.count > 2 ? 13 : 15, weight: on ? .semibold : .regular))
                    .frame(maxWidth: .infinity).padding(.vertical, 9)
                    .background(on ? (opt.label.count > 2 ? Color(hex: 0x303134) : T.amber) : T.bg)
                    .foregroundColor(on ? (opt.label.count > 2 ? .white : T.bg) : T.greyLt)
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(on ? T.amber : T.line, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { selection = opt.tag } }
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: selection)
    }
}

// MARK: - Animation helpers
/// A connection dot with a soft expanding halo.
struct PulsingDot: View {
    var color: Color = T.green
    var size: CGFloat = 9
    @State private var on = false
    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
            .overlay(
                Circle().stroke(color, lineWidth: 2)
                    .scaleEffect(on ? 2.4 : 1).opacity(on ? 0 : 0.7)
            )
            .onAppear {
                withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { on = true }
            }
    }
}

/// Press-to-shrink feedback for buttons.
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

// MARK: - Root (2 tabs)
struct ContentView: View {
    var body: some View {
        TabView {
            DongleView().tabItem { Label("Dongle", systemImage: "dot.radiowaves.left.and.right") }
            TuneView().tabItem { Label("Tune", systemImage: "flame.fill") }
            FaultsView().tabItem { Label("Faults", systemImage: "exclamationmark.triangle.fill") }
        }
        .tint(T.amber)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Page 1: Dongle selection
struct DongleView: View {
    @EnvironmentObject var ble: BLEManager
    var body: some View {
        ZStack {
            T.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    AppHeader()
                    statusCard
                    if ble.isConnected {
                        vinCard.transition(.opacity.combined(with: .move(edge: .top)))
                    } else {
                        scanButton
                    }
                    if !ble.discovered.isEmpty {
                        deviceList.transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 24)
                .animation(.spring(response: 0.45, dampingFraction: 0.85), value: ble.isConnected)
                .animation(.easeInOut(duration: 0.3), value: ble.discovered.count)
            }
        }
    }

    private var statusCard: some View {
        HStack(spacing: 12) {
            Image(systemName: ble.isConnected ? "checkmark.seal.fill" : "antenna.radiowaves.left.and.right")
                .font(.system(size: 26)).foregroundColor(ble.isConnected ? T.green : T.amber)
                .scaleEffect(ble.isConnected ? 1 : 0.92)
            VStack(alignment: .leading, spacing: 2) {
                Text(ble.isConnected ? (ble.connectedName.isEmpty ? targetDongle : ble.connectedName) : (ble.isScanning ? "Scanning…" : "Not connected"))
                    .font(.system(size: 16, weight: .medium)).foregroundColor(.white)
                Text(ble.isConnected ? "ESP32 dongle · ready" : ble.status)
                    .font(.system(size: 12)).foregroundColor(T.grey)
            }
            Spacer()
            if ble.isConnected {
                PulsingDot()
                Button { ble.disconnect() } label: {
                    Text("Disconnect").font(.system(size: 13)).foregroundColor(T.red)
                }
                .buttonStyle(PressStyle())
            }
        }
        .cardStyle()
    }

    private var vinCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "car.fill").font(.system(size: 20)).foregroundColor(T.amber)
            VStack(alignment: .leading, spacing: 2) {
                Text("VIN").font(.system(size: 12)).foregroundColor(T.grey)
                Text(ble.vin.isEmpty ? "Reading…" : ble.vin)
                    .font(.system(size: 15, weight: .medium, design: .monospaced))
                    .foregroundColor(ble.vin.isEmpty ? T.grey : .white)
            }
            Spacer()
            Button { ble.readVIN() } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 15)).foregroundColor(T.amber)
            }
            .buttonStyle(PressStyle())
        }
        .cardStyle()
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: ble.vin)
    }

    private var scanButton: some View {
        Button { ble.startScan() } label: {
            HStack(spacing: 8) {
                Image(systemName: ble.isScanning ? "arrow.triangle.2.circlepath" : "magnifyingglass")
                    .rotationEffect(.degrees(ble.isScanning ? 360 : 0))
                    .animation(ble.isScanning ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: ble.isScanning)
                Text(ble.isScanning ? "Scanning…" : "Scan for dongles").font(.system(size: 15, weight: .medium))
            }
            .frame(maxWidth: .infinity).padding(.vertical, 13)
            .foregroundColor(T.bg).background(T.amber)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(PressStyle())
    }

    private var deviceList: some View {
        VStack(spacing: 0) {
            ForEach(sortedDevices, id: \.identifier) { p in
                let name = p.name ?? "Unknown adapter"
                let isTarget = (p.name == targetDongle)
                let isConn = ble.isConnected && ble.connectedName == name
                Button { ble.connect(p) } label: {
                    HStack(spacing: 11) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.system(size: 16)).foregroundColor(isTarget ? T.amber : T.grey)
                        Text(name).font(.system(size: 15)).foregroundColor(isTarget ? .white : T.greyLt)
                        if isTarget {
                            Text("Your dongle").font(.system(size: 11, weight: .medium))
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(T.amber.opacity(0.18)).foregroundColor(T.amber)
                                .clipShape(Capsule())
                        }
                        Spacer()
                        if isConn { Image(systemName: "checkmark").font(.system(size: 14)).foregroundColor(T.green) }
                    }
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                if p.identifier != sortedDevices.last?.identifier {
                    Rectangle().fill(T.line).frame(height: 0.5)
                }
            }
        }
        .padding(.horizontal, 15)
        .background(T.card)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(T.cardBorder, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var sortedDevices: [CBPeripheral] {
        ble.discovered.sorted { a, _ in a.name == targetDongle }
    }
}

// MARK: - Page 2: Tune
struct TuneView: View {
    @EnvironmentObject var ble: BLEManager
    @State private var enable = true
    @State private var cut = 1
    @State private var modeA = false
    @State private var showAdvanced = false
    @State private var rawCmd = ""

    var body: some View {
        ZStack {
            T.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    AppHeader()
                    if ble.isConnected {
                        Group {
                            exhaustCard
                            statusStrip
                            applyButton
                            readButton
                            advancedRow
                            if showAdvanced {
                                advancedBody.transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    } else {
                        notConnected.transition(.opacity)
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 24)
                .animation(.spring(response: 0.45, dampingFraction: 0.85), value: ble.isConnected)
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: showAdvanced)
            }
        }
        .onChange(of: cut) { _ in ble.markPending() }
        .onChange(of: modeA) { _ in ble.markPending() }
        .onChange(of: enable) { _ in ble.markPending() }
    }

    private var notConnected: some View {
        VStack(spacing: 10) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 34)).foregroundColor(T.grey)
            Text("Connect your dongle").font(.system(size: 16, weight: .medium)).foregroundColor(.white)
            Text("Open the Dongle tab to connect to \(targetDongle).")
                .font(.system(size: 13)).foregroundColor(T.grey).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 60)
    }

    private var exhaustCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "flame.fill").font(.system(size: 20)).foregroundColor(T.amber)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Exhaust").font(.system(size: 16, weight: .medium)).foregroundColor(.white)
                    Text("Burble on upshift").font(.system(size: 12)).foregroundColor(T.grey)
                }
                Spacer()
                Toggle("", isOn: $enable).labelsHidden().tint(T.amber)
            }
            .padding(.bottom, 14)
            Text("Cylinders cut").font(.system(size: 13)).foregroundColor(T.grey).padding(.bottom, 7)
            SegPicker(options: [(1,"1"),(2,"2"),(3,"3"),(4,"4")], selection: $cut).padding(.bottom, 15)
            Text("Mode").font(.system(size: 13)).foregroundColor(T.grey).padding(.bottom, 7)
            SegPicker(options: [(0,"B · ECU cuts"),(1,"A · every WOT")],
                      selection: Binding(get: { modeA ? 1 : 0 }, set: { modeA = $0 == 1 }))
        }
        .cardStyle()
    }

    private var statusStrip: some View {
        HStack(spacing: 7) {
            switch ble.applyState {
            case .idle: EmptyView()
            case .pending:
                Image(systemName: "circle.fill").font(.system(size: 9)).foregroundColor(T.amber)
                Text("Unsaved changes — tap Apply").font(.system(size: 13)).foregroundColor(T.amber)
            case .applying:
                ProgressView().scaleEffect(0.7).tint(T.amber)
                Text(ble.applyDetail).font(.system(size: 13)).foregroundColor(T.amber)
            case .verified:
                Image(systemName: "checkmark.circle.fill").font(.system(size: 15)).foregroundColor(T.green)
                Text("Applied & verified · \(cut) cyl · Mode \(modeA ? "A" : "B")").font(.system(size: 13)).foregroundColor(T.green)
            case .mismatch:
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 14)).foregroundColor(T.red)
                Text("Readback mismatch — retry").font(.system(size: 13)).foregroundColor(T.red)
            case .noReply:
                Image(systemName: "xmark.circle.fill").font(.system(size: 14)).foregroundColor(T.red)
                Text("No reply from ECU").font(.system(size: 13)).foregroundColor(T.red)
            }
            Spacer()
        }
        .frame(minHeight: 20).frame(maxWidth: .infinity).padding(.top, 2)
        .id(stateKey)
        .transition(.opacity.combined(with: .move(edge: .leading)))
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: stateKey)
    }

    private var stateKey: Int {
        switch ble.applyState {
        case .idle: return 0; case .pending: return 1; case .applying: return 2
        case .verified: return 3; case .mismatch: return 4; case .noReply: return 5
        }
    }

    private var applyButton: some View {
        Button { ble.applyConfig(enable: enable, cut: cut, modeA: modeA) } label: {
            HStack(spacing: 8) {
                Image(systemName: "bolt.fill").font(.system(size: 18))
                Text("Apply to ECU").font(.system(size: 16, weight: .bold))
            }
            .frame(maxWidth: .infinity).padding(.vertical, 15)
            .background(T.amber).foregroundColor(T.bg).clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(PressStyle())
    }

    private var readButton: some View {
        Button { ble.readConfig() } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.clockwise").font(.system(size: 16)).foregroundColor(T.amber)
                Text("Read back").font(.system(size: 14)).foregroundColor(T.greyLt)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 12)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(T.line, lineWidth: 1))
        }
        .buttonStyle(PressStyle())
    }

    private var advancedRow: some View {
        Button { withAnimation { showAdvanced.toggle() } } label: {
            HStack {
                Text("Advanced · raw frames, log").font(.system(size: 13)).foregroundColor(Color(hex: 0x85878C))
                Spacer()
                Image(systemName: showAdvanced ? "chevron.down" : "chevron.right").font(.system(size: 13)).foregroundColor(Color(hex: 0x85878C))
            }
            .padding(.vertical, 6).padding(.horizontal, 4)
        }
    }

    private var advancedBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("40 01 19 00 …", text: $rawCmd)
                    .font(.system(size: 13, design: .monospaced))
                    .textInputAutocapitalization(.characters).autocorrectionDisabled().foregroundColor(.white)
                Button("Send") { ble.sendRaw(rawCmd); rawCmd = "" }
                    .font(.system(size: 14)).foregroundColor(T.amber).disabled(!ble.isConnected)
            }
            .padding(10).overlay(RoundedRectangle(cornerRadius: 10).stroke(T.line, lineWidth: 1))
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(ble.log.suffix(80).enumerated()), id: \.offset) { _, l in
                        Text(l).font(.system(size: 10, design: .monospaced)).foregroundColor(T.greyLt)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(height: 200).padding(8).background(Color(hex: 0x151517)).clipShape(RoundedRectangle(cornerRadius: 10))
            Button("Clear log") { ble.clearLog() }.font(.system(size: 13)).foregroundColor(T.amber)
        }
        .cardStyle()
    }
}

// MARK: - Page 3: Fault codes (DTC)
struct FaultsView: View {
    @EnvironmentObject var ble: BLEManager
    @State private var confirmClear = false

    var body: some View {
        ZStack {
            T.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    AppHeader()
                    if !ble.isConnected {
                        notConnectedCard
                    } else {
                        scanButton
                        if !ble.dtcResults.isEmpty || !ble.dtcScanned.isEmpty {
                            summaryStrip
                            ForEach(ble.dtcScanned, id: \.self) { module in
                                moduleCard(module)
                            }
                            clearButton
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 24)
                .animation(.spring(response: 0.45, dampingFraction: 0.85), value: ble.dtcResults.count)
                .animation(.easeInOut(duration: 0.3), value: ble.dtcScanned.count)
            }
        }
        .alert("Clear all fault codes?", isPresented: $confirmClear) {
            Button("Cancel", role: .cancel) {}
            Button("Clear codes", role: .destructive) { ble.clearDTCs() }
        } message: {
            Text("This erases stored DTCs on every scanned module. Codes for faults that are still present will return on the next drive cycle.")
        }
    }

    private var notConnectedCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 20)).foregroundColor(T.grey)
            Text("Connect your dongle on the Dongle tab to read fault codes.")
                .font(.system(size: 14)).foregroundColor(T.greyLt)
            Spacer(minLength: 0)
        }
        .cardStyle()
    }

    private var scanButton: some View {
        Button { ble.scanDTCs() } label: {
            HStack(spacing: 8) {
                Image(systemName: ble.dtcScanning ? "arrow.triangle.2.circlepath" : "magnifyingglass")
                    .rotationEffect(.degrees(ble.dtcScanning ? 360 : 0))
                    .animation(ble.dtcScanning ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: ble.dtcScanning)
                Text(ble.dtcScanning ? "Scanning modules…" : "Scan for faults").font(.system(size: 15, weight: .medium))
            }
            .frame(maxWidth: .infinity).padding(.vertical, 13)
            .foregroundColor(T.bg).background(T.amber)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(PressStyle())
        .disabled(ble.dtcScanning)
    }

    private var summaryStrip: some View {
        let faults = ble.dtcResults.count
        return HStack(spacing: 10) {
            Image(systemName: faults == 0 ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 18)).foregroundColor(faults == 0 ? T.green : T.amber)
            Text(faults == 0
                 ? "No faults · \(ble.dtcScanned.count) modules"
                 : "\(faults) fault\(faults == 1 ? "" : "s") · \(ble.dtcScanned.count) modules")
                .font(.system(size: 14, weight: .semibold)).foregroundColor(.white)
            Spacer()
        }
        .cardStyle()
    }

    private func moduleCard(_ module: String) -> some View {
        let faults = ble.dtcResults.filter { $0.ecu == module }
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(module).font(.system(size: 14, weight: .semibold)).foregroundColor(T.greyLt)
                Spacer()
                if faults.isEmpty {
                    Text("OK").font(.system(size: 11, weight: .bold))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(T.green.opacity(0.16)).foregroundColor(T.green).clipShape(Capsule())
                }
            }
            .padding(.bottom, faults.isEmpty ? 0 : 10)
            ForEach(Array(faults.enumerated()), id: \.element.id) { i, f in
                HStack(spacing: 10) {
                    Circle().fill(f.active ? T.red : T.grey).frame(width: 7, height: 7)
                    Text(f.code).font(.system(size: 15, weight: .medium, design: .monospaced)).foregroundColor(.white)
                    Spacer()
                    Text(f.active ? "Active" : "Stored")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background((f.active ? T.red : T.grey).opacity(0.16))
                        .foregroundColor(f.active ? T.red : T.grey).clipShape(Capsule())
                }
                .padding(.vertical, 8)
                if i != faults.count - 1 { Rectangle().fill(T.line).frame(height: 0.5) }
            }
        }
        .cardStyle()
    }

    private var clearButton: some View {
        Button { confirmClear = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "trash")
                Text("Clear all codes").font(.system(size: 15, weight: .medium))
            }
            .frame(maxWidth: .infinity).padding(.vertical, 13)
            .foregroundColor(T.red)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(T.red.opacity(0.5), lineWidth: 1))
        }
        .buttonStyle(PressStyle())
        .disabled(ble.dtcResults.isEmpty)
        .opacity(ble.dtcResults.isEmpty ? 0.4 : 1)
    }
}

private extension View {
    func cardStyle() -> some View {
        self.padding(15)
            .background(T.card)
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(T.cardBorder, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}
