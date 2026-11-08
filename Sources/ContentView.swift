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
                    .onTapGesture { selection = opt.tag }
            }
        }
    }
}

// MARK: - Root (2 tabs)
struct ContentView: View {
    var body: some View {
        TabView {
            DongleView().tabItem { Label("Dongle", systemImage: "dot.radiowaves.left.and.right") }
            TuneView().tabItem { Label("Tune", systemImage: "flame.fill") }
            LightsView().tabItem { Label("Lights", systemImage: "lightbulb.fill") }
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
                    scanButton
                    if !ble.discovered.isEmpty { deviceList }
                }
                .padding(.horizontal, 16).padding(.bottom, 24)
            }
        }
    }

    private var statusCard: some View {
        HStack(spacing: 12) {
            Image(systemName: ble.isConnected ? "checkmark.seal.fill" : "antenna.radiowaves.left.and.right")
                .font(.system(size: 26)).foregroundColor(ble.isConnected ? T.green : T.amber)
            VStack(alignment: .leading, spacing: 2) {
                Text(ble.isConnected ? (ble.connectedName.isEmpty ? targetDongle : ble.connectedName) : (ble.isScanning ? "Scanning…" : "Not connected"))
                    .font(.system(size: 16, weight: .medium)).foregroundColor(.white)
                Text(ble.isConnected ? "ESP32 dongle · ready" : ble.status)
                    .font(.system(size: 12)).foregroundColor(T.grey)
            }
            Spacer()
            if ble.isConnected {
                Button { ble.disconnect() } label: {
                    Text("Disconnect").font(.system(size: 13)).foregroundColor(T.red)
                }
            }
        }
        .cardStyle()
    }

    private var scanButton: some View {
        Button { ble.startScan() } label: {
            HStack(spacing: 8) {
                Image(systemName: ble.isScanning ? "arrow.triangle.2.circlepath" : "magnifyingglass")
                Text(ble.isScanning ? "Scanning…" : "Scan for dongles").font(.system(size: 15, weight: .medium))
            }
            .frame(maxWidth: .infinity).padding(.vertical, 13)
            .foregroundColor(T.bg).background(T.amber)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
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
                }
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
                        exhaustCard
                        statusStrip
                        applyButton
                        readButton
                        advancedRow
                        if showAdvanced { advancedBody }
                    } else {
                        notConnected
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 24)
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

// MARK: - Page 3: Lights
struct LightsView: View {
    @EnvironmentObject var ble: BLEManager
    private let cols = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        ZStack {
            T.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    AppHeader()
                    if ble.isConnected {
                        header
                        grid
                        if ble.activeLightStyle != nil { stopButton }
                        didRow
                        Text("Drives your front headlamps over UDS zone control. If nothing flashes, try another DID below. Running effects stop when you disconnect.")
                            .font(.system(size: 12)).foregroundColor(T.grey)
                    } else {
                        notConnected
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 24)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "lightbulb.fill").font(.system(size: 20)).foregroundColor(T.amber)
            VStack(alignment: .leading, spacing: 1) {
                Text("Headlight effects").font(.system(size: 16, weight: .medium)).foregroundColor(.white)
                Text(ble.activeLightStyle == nil ? "Tap a style to run it" : "Running — tap again or Stop")
                    .font(.system(size: 12)).foregroundColor(T.grey)
            }
            Spacer()
        }
    }

    private var grid: some View {
        LazyVGrid(columns: cols, spacing: 12) {
            ForEach(BLEManager.lightStyles) { style in
                let on = ble.activeLightStyle == style.id
                Button { ble.toggleLights(style) } label: {
                    VStack(spacing: 8) {
                        Image(systemName: style.icon).font(.system(size: 24)).foregroundColor(on ? T.bg : T.amber)
                        Text(style.name).font(.system(size: 14, weight: .medium)).foregroundColor(on ? T.bg : .white)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 20)
                    .background(on ? T.amber : T.card)
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(on ? T.amber : T.cardBorder, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
            }
        }
    }

    private var stopButton: some View {
        Button { ble.stopLights() } label: {
            HStack(spacing: 8) {
                Image(systemName: "stop.fill").font(.system(size: 16))
                Text("Stop").font(.system(size: 16, weight: .bold))
            }
            .frame(maxWidth: .infinity).padding(.vertical, 14)
            .background(T.red).foregroundColor(.white).clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private var didRow: some View {
        HStack {
            Text("Headlamp DID").font(.system(size: 13)).foregroundColor(T.grey)
            Spacer()
            ForEach([UInt16(0x0008), 0xD008, 0x0011], id: \.self) { did in
                let on = ble.lightDID == did
                Text(String(format: "%04X", did))
                    .font(.system(size: 13, design: .monospaced))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(on ? T.amber : T.bg).foregroundColor(on ? T.bg : T.greyLt)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(on ? T.amber : T.line, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .onTapGesture { ble.lightDID = did }
            }
        }
    }

    private var notConnected: some View {
        VStack(spacing: 10) {
            Image(systemName: "lightbulb.slash").font(.system(size: 34)).foregroundColor(T.grey)
            Text("Connect your dongle").font(.system(size: 16, weight: .medium)).foregroundColor(.white)
            Text("Open the Dongle tab to connect first.").font(.system(size: 13)).foregroundColor(T.grey)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 60)
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
