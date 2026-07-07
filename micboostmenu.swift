// micboostmenu — menu-bar control panel for the micboost bridge.
//
// Same job as `micboostctl`, in the menu bar: pick the input mic + output device,
// tune gain / compressor, and hot-apply by restarting the launchd agent.
//
// Build:
//   swiftc -O -framework Cocoa -framework SwiftUI -framework CoreAudio -framework Foundation \
//          micboostmenu.swift -o micboostmenu
//
// Every "Apply" writes ~/.config/micboost/config and kickstarts gui/<uid>/me.pecheny.micboost.

import Cocoa
import SwiftUI
import CoreAudio

// ============================ paths / launchd ============================
let LABEL  = "me.pecheny.micboost"
let DOMAIN = "gui/\(getuid())/\(LABEL)"
let LOG    = "/tmp/micboost.log"
let CONFIG_PATH = (ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
                   ?? NSHomeDirectory() + "/.config") + "/micboost/config"

@discardableResult
func run(_ path: String, _ args: [String], capture: Bool = false) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    if capture { p.standardOutput = pipe; p.standardError = pipe }
    do { try p.run() } catch { return "" }
    if capture {
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: d, encoding: .utf8) ?? ""
    }
    p.waitUntilExit()
    return ""
}

func kickstart() { run("/bin/launchctl", ["kickstart", "-k", DOMAIN]) }

func agentStatus() -> String {
    let out = run("/bin/launchctl", ["print", DOMAIN], capture: true)
    if out.isEmpty { return "not loaded" }
    var state = "", pid = ""
    for line in out.split(separator: "\n") {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("state = ") { state = String(t.dropFirst("state = ".count)) }
        if t.hasPrefix("pid = ")   { pid   = String(t.dropFirst("pid = ".count)) }
    }
    if state.isEmpty { return "not loaded" }
    return pid.isEmpty ? state : "\(state) · pid \(pid)"
}

// ============================ config file ============================
// Order-preserving KEY=VALUE store that keeps blank lines, comments, and inline comments.
final class Config {
    var lines: [String]
    init() {
        let text = (try? String(contentsOfFile: CONFIG_PATH, encoding: .utf8)) ?? ""
        lines = text.isEmpty ? [] : text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
    }

    private func keyOf(_ line: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.isEmpty || t.hasPrefix("#") { return nil }
        guard let eq = t.firstIndex(of: "=") else { return nil }
        return String(t[..<eq]).trimmingCharacters(in: .whitespaces)
    }

    func get(_ k: String) -> String? {
        for line in lines where keyOf(line) == k {
            let after = line[line.index(after: line.firstIndex(of: "=")!)...]
            var v = String(after)
            if let h = v.firstIndex(of: "#") { v = String(v[..<h]) }
            return v.trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    func set(_ k: String, _ v: String) {
        for i in lines.indices where keyOf(lines[i]) == k {
            let after = lines[i][lines[i].index(after: lines[i].firstIndex(of: "=")!)...]
            let comment = after.firstIndex(of: "#").map { "   " + after[$0...] } ?? ""
            lines[i] = "\(k)=\(v)\(comment)"
            return
        }
        lines.append("\(k)=\(v)")
    }

    func save() { try? (lines.joined(separator: "\n") + "\n").write(toFile: CONFIG_PATH, atomically: true, encoding: .utf8) }
}

// ============================ Core Audio device discovery ============================
func deviceIDs() -> [AudioDeviceID] {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
    return ids
}

func deviceName(_ id: AudioDeviceID) -> String {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var cf: CFString = "" as CFString
    var size = UInt32(MemoryLayout<CFString>.size)
    _ = withUnsafeMutablePointer(to: &cf) { AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0) }
    return cf as String
}

func hasStreams(_ id: AudioDeviceID, input: Bool) -> Bool {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
        mScope: input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size)
    return size > 0
}

// Live device names for a direction, de-duplicated in discovery order.
func devices(input: Bool) -> [String] {
    var seen = Set<String>(), out = [String]()
    for id in deviceIDs() where hasStreams(id, input: input) {
        let n = deviceName(id)
        if !n.isEmpty && seen.insert(n).inserted { out.append(n) }
    }
    return out
}

// Resolve a config substring to the actual connected device name (nil if none matches).
func resolve(_ needle: String, input: Bool) -> String? {
    let n = needle.lowercased()
    return devices(input: input).first { $0.lowercased().contains(n) }
}

// ============================ number formatting ============================
func fmtNum(_ d: Double) -> String {
    if d == d.rounded() { return String(Int(d)) }
    return String(format: "%g", d)
}

// ============================ view model ============================
// Staged (edited) values vs. the last-applied baseline, mirroring the micboostctl TUI.
final class Model: ObservableObject {
    let cfg = Config()

    // staged
    @Published var inDev  = ""
    @Published var outDev = ""
    @Published var gain   = 12.0
    @Published var comp   = true
    @Published var thresh = -18.0
    @Published var ratio  = 4.0
    @Published var makeup = 6.0
    @Published var attack = 5.0
    @Published var release = 150.0

    // live device lists (refreshed when the popover opens)
    @Published var inputs:  [String] = []
    @Published var outputs: [String] = []

    @Published var statusLine = ""
    @Published var appliedNote = ""

    // last-applied baseline for the dirty check
    private var base: [String: String] = [:]

    init() { reload() }

    private func d(_ k: String, _ dflt: Double) -> Double { Double(cfg.get(k) ?? "") ?? dflt }

    func reload() {
        let rawIn  = cfg.get("RODE_NAME") ?? "Wireless MICRO"
        let rawOut = cfg.get("OUT_NAME")  ?? "BlackHole"
        refreshDevices()
        inDev  = resolve(rawIn,  input: true)  ?? rawIn
        outDev = resolve(rawOut, input: false) ?? rawOut
        gain   = d("GAIN_DB", 12)
        comp   = (cfg.get("COMP") ?? "1") != "0"
        thresh = d("THRESH_DB", -18)
        ratio  = d("RATIO", 4)
        makeup = d("MAKEUP_DB", 6)
        attack = d("ATTACK_MS", 5)
        release = d("RELEASE_MS", 150)
        snapshot()
        statusLine = agentStatus()
    }

    func refreshDevices() {
        inputs  = devices(input: true)
        outputs = devices(input: false)
        // keep whatever is staged visible even if it isn't currently connected
        if !inDev.isEmpty  && !inputs.contains(inDev)   { inputs.insert(inDev, at: 0) }
        if !outDev.isEmpty && !outputs.contains(outDev) { outputs.insert(outDev, at: 0) }
    }

    private var staged: [String: String] {
        ["RODE_NAME": inDev, "OUT_NAME": outDev,
         "GAIN_DB": fmtNum(gain), "COMP": comp ? "1" : "0",
         "THRESH_DB": fmtNum(thresh), "RATIO": fmtNum(ratio),
         "MAKEUP_DB": fmtNum(makeup), "ATTACK_MS": fmtNum(attack),
         "RELEASE_MS": fmtNum(release)]
    }
    private func snapshot() { base = staged }
    var dirty: Bool { staged != base }

    func apply() {
        for (k, v) in staged { cfg.set(k, v) }
        cfg.save()
        kickstart()
        snapshot()
        objectWillChange.send()
        statusLine = agentStatus()
        appliedNote = "Applied — micboost restarted"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.appliedNote = "" }
    }

    func restart() {
        kickstart()
        statusLine = agentStatus()
        appliedNote = "Restarted micboost"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.appliedNote = "" }
    }

    func openLog() {
        NSWorkspace.shared.open(URL(fileURLWithPath: LOG))   // opens in Console (default .log handler)
    }
}

// ============================ SwiftUI panel ============================
struct SliderRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    var unit: String = ""
    var body: some View {
        HStack(spacing: 8) {
            Text(label).frame(width: 78, alignment: .leading)
            Slider(value: $value, in: range, step: step)
            Text("\(fmtNum(value))\(unit.isEmpty ? "" : " " + unit)")
                .font(.system(.body, design: .monospaced))
                .frame(width: 62, alignment: .trailing)
        }
    }
}

struct Panel: View {
    @ObservedObject var m: Model
    @State private var showAdvanced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("micboost").font(.headline)
                Spacer()
                Text(m.statusLine).font(.caption).foregroundColor(.secondary)
            }

            Divider()

            // devices
            HStack(spacing: 8) {
                Text("Input").frame(width: 78, alignment: .leading)
                Picker("", selection: $m.inDev) {
                    ForEach(m.inputs, id: \.self) { Text($0).tag($0) }
                }.labelsHidden()
            }
            HStack(spacing: 8) {
                Text("Output").frame(width: 78, alignment: .leading)
                Picker("", selection: $m.outDev) {
                    ForEach(m.outputs, id: \.self) { Text($0).tag($0) }
                }.labelsHidden()
            }

            Divider()

            // core tuning
            SliderRow(label: "Gain", value: $m.gain, range: -6...30, step: 1, unit: "dB")
            Toggle(isOn: $m.comp) { Text("Compressor") }
                .toggleStyle(.switch)

            // advanced compressor params
            if m.comp {
                DisclosureGroup(isExpanded: $showAdvanced) {
                    VStack(alignment: .leading, spacing: 8) {
                        SliderRow(label: "Threshold", value: $m.thresh, range: -60...0, step: 1, unit: "dB")
                        SliderRow(label: "Ratio", value: $m.ratio, range: 1...20, step: 0.5, unit: ":1")
                        SliderRow(label: "Makeup", value: $m.makeup, range: 0...24, step: 1, unit: "dB")
                        SliderRow(label: "Attack", value: $m.attack, range: 1...100, step: 1, unit: "ms")
                        SliderRow(label: "Release", value: $m.release, range: 10...1000, step: 10, unit: "ms")
                    }.padding(.top, 4)
                } label: {
                    Text("Advanced").font(.subheadline)
                }
            }

            Divider()

            HStack {
                if !m.appliedNote.isEmpty {
                    Label(m.appliedNote, systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundColor(.green)
                } else if m.dirty {
                    Label("Unsaved changes", systemImage: "circle.fill")
                        .font(.caption).foregroundColor(.orange)
                } else {
                    Label("In sync", systemImage: "checkmark.circle")
                        .font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Button("Apply") { m.apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!m.dirty)
            }

            HStack {
                Button("Restart") { m.restart() }
                Button("Log…") { m.openLog() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }.font(.caption)
        }
        .padding(14)
        .frame(width: 340)
    }
}

// ============================ status-item app ============================
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = Model()
    var statusItem: NSStatusItem!
    let popover = NSPopover()
    var monitor: Any?

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button {
            b.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "micboost")
            b.image?.isTemplate = true
            b.action = #selector(toggle(_:))
            b.target = self
        }
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: Panel(m: model))
    }

    @objc func toggle(_ sender: Any?) {
        if popover.isShown { close() } else { open() }
    }

    func open() {
        guard let b = statusItem.button else { return }
        model.reload()                 // pick up live devices + agent status each time
        popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        // close when clicking away
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.close()
        }
    }

    func close() {
        popover.performClose(nil)
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu-bar only, no Dock icon
app.run()
