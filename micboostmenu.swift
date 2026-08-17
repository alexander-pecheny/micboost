// micboostmenu — menu-bar control panel for the micboost bridge and the micrec recorder.
//
// Two collapsed sections: micboost (the live mic chain) and Recording (multi-source capture).
// micboost follows the input device: selecting BlackHole 2ch turns it on, selecting anything
// else turns it off, and the switch still works by hand in between.
//
// Build:
//   swiftc -O -framework Cocoa -framework SwiftUI -framework CoreAudio -framework Foundation \
//          micboostmenu.swift -o micboostmenu

import Cocoa
import SwiftUI
import CoreAudio

// ============================ paths / launchd ============================
let LABEL  = "me.pecheny.micboost"
let DOMAIN = "gui/\(getuid())/\(LABEL)"
let PLIST  = NSHomeDirectory() + "/Library/LaunchAgents/\(LABEL).plist"
let LOG    = "/tmp/micboost.log"
let REC_LOG = "/tmp/micrec.log"
let REC_PID = "/tmp/micrec.pid"
let REC_STATUS = "/tmp/micrec.status"
let REC_DIR = NSHomeDirectory() + "/Documents/MicboostRecordings"
let CONFIG_PATH = (ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
                   ?? NSHomeDirectory() + "/.config") + "/micboost/config"
let PROFILE_PATH = (CONFIG_PATH as NSString).deletingLastPathComponent + "/noise.profile"

@discardableResult
func run(_ path: String, _ args: [String], capture: Bool = false) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    if capture { p.standardOutput = pipe; p.standardError = Pipe() }
    do { try p.run() } catch { return "" }
    if capture {
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: d, encoding: .utf8) ?? ""
    }
    p.waitUntilExit()
    return ""
}

func launchctl(_ args: [String], capture: Bool = false) -> String {
    run("/bin/launchctl", args, capture: capture)
}

func micboostLoaded() -> Bool { !launchctl(["print", DOMAIN], capture: true).isEmpty }
func micboostRunning() -> Bool { launchctl(["print", DOMAIN], capture: true).contains("state = running") }

func setMicboost(_ on: Bool) {
    if on {
        if micboostLoaded() { launchctl(["kickstart", "-k", DOMAIN]) }
        else { launchctl(["bootstrap", "gui/\(getuid())", PLIST]) }
    } else {
        launchctl(["bootout", DOMAIN])
    }
}

func agentPID() -> pid_t? {
    for line in launchctl(["print", DOMAIN], capture: true).split(separator: "\n") {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("pid = ") { return pid_t(t.dropFirst(6).trimmingCharacters(in: .whitespaces)) }
    }
    return nil
}

func hasProfile() -> Bool { FileManager.default.fileExists(atPath: PROFILE_PATH) }
func profileMTime() -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: PROFILE_PATH))?[.modificationDate] as? Date
}

/// micrec sits next to this binary; the installer also links it into PATH.
func micrecPath() -> String {
    let sibling = (Bundle.main.executablePath.map { ($0 as NSString).deletingLastPathComponent } ?? ".") + "/micrec"
    if FileManager.default.isExecutableFile(atPath: sibling) { return sibling }
    return "/opt/homebrew/bin/micrec"
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
let SYS = AudioObjectID(kAudioObjectSystemObject)

func caAddr(_ s: AudioObjectPropertySelector,
            _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    .init(mSelector: s, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func deviceIDs() -> [AudioDeviceID] {
    var a = caAddr(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(SYS, &a, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(SYS, &a, 0, nil, &size, &ids)
    return ids
}

func deviceName(_ id: AudioDeviceID) -> String {
    var a = caAddr(kAudioObjectPropertyName)
    var cf: CFString = "" as CFString
    var size = UInt32(MemoryLayout<CFString>.size)
    _ = withUnsafeMutablePointer(to: &cf) { AudioObjectGetPropertyData(id, &a, 0, nil, &size, $0) }
    return cf as String
}

func hasStreams(_ id: AudioDeviceID, input: Bool) -> Bool {
    var a = caAddr(kAudioDevicePropertyStreams,
                   input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput)
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size)
    return size > 0
}

func devices(input: Bool) -> [String] {
    var seen = Set<String>(), out = [String]()
    for id in deviceIDs() where hasStreams(id, input: input) {
        let n = deviceName(id)
        if !n.isEmpty && seen.insert(n).inserted { out.append(n) }
    }
    return out
}

func resolve(_ needle: String, input: Bool) -> String? {
    let n = needle.lowercased()
    return devices(input: input).first { $0.lowercased().contains(n) }
}

func defaultInputName() -> String {
    var a = caAddr(kAudioHardwarePropertyDefaultInputDevice)
    var id = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(SYS, &a, 0, nil, &size, &id) == noErr, id != 0 else { return "" }
    return deviceName(id)
}

func fmtNum(_ d: Double) -> String {
    d == d.rounded() ? String(Int(d)) : String(format: "%g", d)
}

// ============================ recording model ============================
struct Source: Identifiable, Hashable {
    let id: String          // "mic", "system", "app:<bundle id>"
    let name: String
    let kind: String
    let playing: Bool
    let tappable: Bool      // false = the app has never opened an audio stream, so it cannot be tapped
}

final class RecModel: ObservableObject {
    @Published var sources: [Source] = []
    @Published var selected: Set<String> = []
    @Published var search = ""
    @Published var format = "flac"
    @Published var recording = false
    @Published var finalizing = false
    @Published var elapsed = 0
    @Published var session = ""
    @Published var lastError = ""
    @Published var popoverOpen = false

    private let cfg: Config
    init(cfg: Config) {
        self.cfg = cfg
        format = cfg.get("REC_FORMAT") ?? "flac"
        selected = Set((cfg.get("REC_SOURCES") ?? "mic").split(separator: ",").map(String.init))
        refreshState()
    }

    var visible: [Source] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return sources }
        return sources.filter { $0.name.lowercased().contains(q) || $0.id.lowercased().contains(q) }
    }

    var selectedNames: String {
        let names = sources.filter { selected.contains($0.id) }.map(\.name)
        return names.isEmpty ? "nothing selected" : names.joined(separator: ", ")
    }

    func persist() {
        cfg.set("REC_FORMAT", format)
        cfg.set("REC_SOURCES", selected.sorted().joined(separator: ","))
        cfg.save()
    }

    /// Spawns micrec off the main thread — the list refreshes on a timer and must not hitch the UI.
    func refreshSources() {
        DispatchQueue.global().async { [weak self] in
            let out = run(micrecPath(), ["sources", "--json"], capture: true)
            guard let d = out.data(using: .utf8),
                  let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { return }
            let parsed: [Source] = arr.compactMap {
                guard let id = $0["id"] as? String, let name = $0["name"] as? String,
                      let kind = $0["kind"] as? String else { return nil }
                return Source(id: id, name: name, kind: kind,
                              playing: ($0["playing"] as? Bool) ?? false,
                              tappable: ($0["tappable"] as? Bool) ?? true)
            }
            DispatchQueue.main.async { if self?.sources != parsed { self?.sources = parsed } }
        }
    }

    /// Runs every second, so it publishes only genuine changes — assigning an unchanged value to
    /// an @Published still redraws the whole panel, which is visible as flicker mid-animation.
    func refreshState() {
        let pid = (try? String(contentsOfFile: REC_PID, encoding: .utf8))
            .flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let live = pid.map { kill($0, 0) == 0 } ?? false
        if recording != live { recording = live }
        guard let t = try? String(contentsOfFile: REC_STATUS, encoding: .utf8) else { return }
        var m = [String: String]()
        for l in t.split(separator: "\n") {
            guard let eq = l.firstIndex(of: "=") else { continue }
            m[String(l[..<eq])] = String(l[l.index(after: eq)...])
        }
        if live {
            let secs = Int(m["seconds"] ?? "0") ?? 0
            if elapsed != secs { elapsed = secs }
            if session != m["session"] ?? "" { session = m["session"] ?? "" }
        }
        let fin = !live && m["state"] == "finalizing"
        if finalizing != fin { finalizing = fin }
    }

    func start() {
        guard !selected.isEmpty else { lastError = "pick at least one source"; return }
        persist()
        lastError = ""
        var args = ["start", "--format", format]
        for s in selected.sorted() { args += ["--source", s] }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: micrecPath())
        p.arguments = args
        FileManager.default.createFile(atPath: REC_LOG, contents: nil)
        if let fh = FileHandle(forWritingAtPath: REC_LOG) { p.standardOutput = fh; p.standardError = fh }
        do { try p.run() } catch { lastError = error.localizedDescription; return }
        // micrec is not waited on: it outlives this app so quitting the menu never kills a take
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.refreshState()
            if self?.recording == false {
                self?.lastError = (try? String(contentsOfFile: REC_LOG, encoding: .utf8))?
                    .split(separator: "\n").last.map(String.init) ?? "recorder did not start"
            }
        }
    }

    func stop() {
        finalizing = true
        DispatchQueue.global().async { [weak self] in
            run(micrecPath(), ["stop"])
            DispatchQueue.main.async { self?.finalizing = false; self?.refreshState() }
        }
    }

    func openFolder() {
        try? FileManager.default.createDirectory(atPath: REC_DIR, withIntermediateDirectories: true)
        NSWorkspace.shared.open(URL(fileURLWithPath: session.isEmpty ? REC_DIR : session))
    }
}

// ============================ micboost model ============================
final class Model: ObservableObject {
    let cfg = Config()
    lazy var rec = RecModel(cfg: cfg)

    @Published var enabled = false
    @Published var inDev  = ""
    @Published var outDev = ""
    @Published var gain   = 12.0
    @Published var comp   = true
    @Published var thresh = -18.0
    @Published var ratio  = 4.0
    @Published var makeup = 6.0
    @Published var attack = 5.0
    @Published var release = 150.0
    @Published var nr     = false

    @Published var inputs:  [String] = []
    @Published var outputs: [String] = []
    @Published var statusLine = ""
    @Published var appliedNote = ""
    @Published var systemInput = ""

    @Published var profileExists = false
    @Published var capturing = false
    @Published var captureLeft = 0.0

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
        nr     = (cfg.get("NR") ?? "0") != "0"
        profileExists = hasProfile()
        enabled = micboostRunning()
        systemInput = defaultInputName()
        snapshot()
        statusLine = enabled ? "on" : "off"
    }

    func refreshDevices() {
        inputs  = devices(input: true)
        outputs = devices(input: false)
        if !inDev.isEmpty  && !inputs.contains(inDev)   { inputs.insert(inDev, at: 0) }
        if !outDev.isEmpty && !outputs.contains(outDev) { outputs.insert(outDev, at: 0) }
    }

    private var staged: [String: String] {
        ["RODE_NAME": inDev, "OUT_NAME": outDev,
         "GAIN_DB": fmtNum(gain), "COMP": comp ? "1" : "0",
         "THRESH_DB": fmtNum(thresh), "RATIO": fmtNum(ratio),
         "MAKEUP_DB": fmtNum(makeup), "ATTACK_MS": fmtNum(attack),
         "RELEASE_MS": fmtNum(release), "NR": nr ? "1" : "0"]
    }
    private func snapshot() { base = staged }
    var dirty: Bool { staged != base }
    var captureSecs: Double { Double(cfg.get("NR_CAPTURE_SEC") ?? "") ?? 6 }

    private func flash(_ msg: String) {
        appliedNote = msg
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.appliedNote = "" }
    }

    func setEnabled(_ on: Bool) {
        setMicboost(on)
        enabled = on
        statusLine = on ? "on" : "off"
    }

    /// Selecting BlackHole as the system input means "route me through micboost", so the bridge
    /// follows it. A manual flick of the switch stands until the input changes again.
    func systemInputChanged() {
        systemInput = defaultInputName()
        let want = systemInput.lowercased().contains("blackhole")
        if want != micboostRunning() { setEnabled(want) } else { enabled = want }
    }

    func apply() {
        for (k, v) in staged { cfg.set(k, v) }
        cfg.save()
        if enabled { launchctl(["kickstart", "-k", DOMAIN]) }
        snapshot()
        objectWillChange.send()
        flash("Applied")
    }

    func captureNoise() {
        let before = profileMTime()
        guard let pid = agentPID(), kill(pid, SIGUSR1) == 0 else {
            flash("micboost is not running")
            return
        }
        capturing = true
        captureLeft = captureSecs
        let deadline = Date().addingTimeInterval(captureSecs + 5)
        let t = Timer(timeInterval: 0.2, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.captureLeft = max(0, deadline.timeIntervalSinceNow - 5)
            if let m = profileMTime(), m != before {
                timer.invalidate()
                self.capturing = false
                self.profileExists = true
                self.nr = true
                self.cfg.set("NR", "1"); self.cfg.save()
                self.base["NR"] = "1"
                launchctl(["kickstart", "-k", DOMAIN])
                self.flash("Noise profile captured — suppression on")
            } else if Date() >= deadline {
                timer.invalidate()
                self.capturing = false
                self.flash("Capture timed out")
            }
        }
        RunLoop.main.add(t, forMode: .common)
    }

    func openLog() { NSWorkspace.shared.open(URL(fileURLWithPath: LOG)) }
}

// ============================ views ============================
struct SliderRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    var unit: String = ""
    var body: some View {
        HStack(spacing: 8) {
            Text(label).frame(width: 74, alignment: .leading)
            Slider(value: $value, in: range, step: step)
            Text("\(fmtNum(value))\(unit.isEmpty ? "" : " " + unit)")
                .font(.system(.caption, design: .monospaced))
                .frame(width: 58, alignment: .trailing)
        }.font(.callout)
    }
}

/// Collapsed by default, with a control that lives in the header and does not toggle it.
struct SectionBox<Content: View, Accessory: View>: View {
    let title: String
    let subtitle: String
    @Binding var expanded: Bool
    @ViewBuilder let accessory: () -> Accessory
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                // No animation: the popover window resizes on its own clock, and a content
                // animation racing it draws the expanded list ghosted over the collapsed one.
                Button {
                    expanded.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.bold))
                            .foregroundColor(.secondary)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(title).font(.headline)
                            if !subtitle.isEmpty {
                                Text(subtitle).font(.caption).foregroundColor(.secondary)
                                    .lineLimit(1).truncationMode(.tail)
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
                Spacer(minLength: 8)
                accessory()
            }
            if expanded { content() }
        }
    }
}

struct MicboostSection: View {
    @ObservedObject var m: Model
    @Binding var expanded: Bool
    @State private var showAdvanced = false

    var body: some View {
        SectionBox(title: "micboost",
                   subtitle: m.enabled ? "\(m.inDev) → \(m.outDev)" : "off · input is \(m.systemInput)",
                   expanded: $expanded) {
            Toggle("", isOn: Binding(get: { m.enabled }, set: { m.setEnabled($0) }))
                .toggleStyle(.switch)
                .labelsHidden()
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("Input").frame(width: 74, alignment: .leading)
                    Picker("", selection: $m.inDev) {
                        ForEach(m.inputs, id: \.self) { Text($0).tag($0) }
                    }.labelsHidden()
                }.font(.callout)
                HStack(spacing: 8) {
                    Text("Output").frame(width: 74, alignment: .leading)
                    Picker("", selection: $m.outDev) {
                        ForEach(m.outputs, id: \.self) { Text($0).tag($0) }
                    }.labelsHidden()
                }.font(.callout)

                SliderRow(label: "Gain", value: $m.gain, range: -6...30, step: 1, unit: "dB")
                Toggle(isOn: $m.comp) { Text("Compressor").font(.callout) }.toggleStyle(.switch)

                if m.comp {
                    DisclosureGroup(isExpanded: $showAdvanced) {
                        VStack(alignment: .leading, spacing: 6) {
                            SliderRow(label: "Threshold", value: $m.thresh, range: -60...0, step: 1, unit: "dB")
                            SliderRow(label: "Ratio", value: $m.ratio, range: 1...20, step: 0.5, unit: ":1")
                            SliderRow(label: "Makeup", value: $m.makeup, range: 0...24, step: 1, unit: "dB")
                            SliderRow(label: "Attack", value: $m.attack, range: 1...100, step: 1, unit: "ms")
                            SliderRow(label: "Release", value: $m.release, range: 10...1000, step: 10, unit: "ms")
                        }.padding(.top, 4)
                    } label: { Text("Advanced").font(.caption) }
                }

                Toggle(isOn: $m.nr) { Text("Noise suppression").font(.callout) }
                    .toggleStyle(.switch)
                    .disabled(!m.profileExists)

                if m.capturing {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(String(format: "Recording noise… %.1fs — stay silent", m.captureLeft))
                            .font(.caption).foregroundColor(.secondary)
                    }
                } else {
                    Button(m.profileExists ? "Re-record noise profile" : "Capture noise profile") {
                        m.captureNoise()
                    }.font(.caption)
                }

                HStack {
                    if !m.appliedNote.isEmpty {
                        Label(m.appliedNote, systemImage: "checkmark.circle.fill")
                            .font(.caption).foregroundColor(.green)
                    } else if m.dirty {
                        Label("Unsaved changes", systemImage: "circle.fill")
                            .font(.caption).foregroundColor(.orange)
                    }
                    Spacer()
                    Button("Apply") { m.apply() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!m.dirty || m.capturing)
                }
            }
        }
    }
}

struct RecordingSection: View {
    @ObservedObject var m: Model
    @ObservedObject var r: RecModel
    @Binding var expanded: Bool

    var subtitle: String {
        if r.recording { return String(format: "recording — %d:%02d", r.elapsed / 60, r.elapsed % 60) }
        if r.finalizing { return "finishing up…" }
        return r.selectedNames
    }

    func icon(_ s: Source) -> String {
        switch s.kind {
        case "mic": return "mic"
        case "system": return "speaker.wave.2"
        default: return "app"
        }
    }

    var body: some View {
        SectionBox(title: "Recording", subtitle: subtitle, expanded: $expanded) {
            Button {
                r.recording ? r.stop() : r.start()
            } label: {
                Label(r.recording ? "Stop" : "Record",
                      systemImage: r.recording ? "stop.fill" : "record.circle")
                    .foregroundColor(r.recording ? .red : .primary)
            }
            .disabled(r.finalizing)
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.caption).foregroundColor(.secondary)
                    TextField("Filter apps", text: $r.search).textFieldStyle(.roundedBorder)
                    Button { r.refreshSources() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).help("Refresh the list")
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(r.visible) { s in
                            Toggle(isOn: Binding(
                                get: { r.selected.contains(s.id) },
                                set: { on in
                                    if on { r.selected.insert(s.id) } else { r.selected.remove(s.id) }
                                    r.persist()
                                })) {
                                HStack(spacing: 5) {
                                    Image(systemName: icon(s)).font(.caption).foregroundColor(.secondary)
                                    Text(s.name).font(.callout).lineLimit(1)
                                        .foregroundColor(s.tappable ? .primary : .secondary)
                                    if s.playing && s.kind == "app" {
                                        Image(systemName: "waveform").font(.caption2).foregroundColor(.accentColor)
                                    }
                                }
                            }
                            .toggleStyle(.checkbox)
                            .disabled(!s.tappable)
                            .help(s.tappable ? "" : "\(s.name) has not opened an audio stream yet")
                        }
                        if r.visible.isEmpty {
                            Text("nothing matches").font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
                .frame(maxHeight: 180)
                .disabled(r.recording)

                HStack(spacing: 8) {
                    Text("Format").frame(width: 74, alignment: .leading)
                    Picker("", selection: Binding(get: { r.format },
                                                  set: { r.format = $0; r.persist() })) {
                        Text("Lossless — FLAC").tag("flac")
                        Text("Lossy — AAC 256k").tag("aac")
                    }.labelsHidden().disabled(r.recording)
                }.font(.callout)

                if !r.lastError.isEmpty {
                    Label(r.lastError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundColor(.orange).lineLimit(2)
                }

                HStack {
                    Button("Recordings…") { r.openFolder() }
                    Spacer()
                    if r.recording {
                        Text("stems stay in sync by construction")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                }.font(.caption)
            }
            .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
                if expanded && r.popoverOpen { r.refreshSources() }
            }
        }
    }
}

struct Panel: View {
    @ObservedObject var m: Model
    @State private var micboostOpen = false
    @State private var recordingOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MicboostSection(m: m, expanded: $micboostOpen)
            Divider()
            RecordingSection(m: m, r: m.rec, expanded: $recordingOpen)
            Divider()
            HStack {
                Button("Log…") { m.openLog() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }.font(.caption)
        }
        .padding(14)
        .frame(width: 340)
        .onChange(of: recordingOpen) { open in if open { m.rec.refreshSources() } }
    }
}

// ============================ status-item app ============================
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = Model()
    var statusItem: NSStatusItem!
    let popover = NSPopover()
    var monitor: Any?
    var tick: Timer?

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.action = #selector(toggle(_:))
        statusItem.button?.target = self
        popover.behavior = .transient
        popover.animates = false
        let hosting = NSHostingController(rootView: Panel(m: model))
        hosting.sizingOptions = [.preferredContentSize]   // keeps the popover in step as sections expand
        popover.contentViewController = hosting

        var a = caAddr(kAudioHardwarePropertyDefaultInputDevice)
        AudioObjectAddPropertyListenerBlock(SYS, &a, DispatchQueue.main) { [weak self] _, _ in
            self?.model.systemInputChanged()
        }
        model.systemInputChanged()

        // finish anything a crash or a reboot left half-written
        DispatchQueue.global().async { run(micrecPath(), ["recover"]) }

        tick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.model.rec.refreshState()
            self.render()
        }
        render()
    }

    var shownSymbol = ""

    func render() {
        guard let b = statusItem.button else { return }
        let r = model.rec
        let symbol = r.recording ? "record.circle.fill" : (model.enabled ? "mic.fill" : "mic.slash")
        if symbol != shownSymbol {
            shownSymbol = symbol
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "micboost")
            b.image?.isTemplate = !r.recording
            b.contentTintColor = r.recording ? .systemRed : nil
        }
        let title = r.recording ? String(format: " %d:%02d", r.elapsed / 60, r.elapsed % 60) : ""
        if b.title != title { b.title = title }
    }

    @objc func toggle(_ sender: Any?) { popover.isShown ? close() : open() }

    func open() {
        guard let b = statusItem.button else { return }
        model.reload()
        model.rec.refreshState()
        model.rec.popoverOpen = true
        model.rec.refreshSources()
        // A SwiftUI hosting view still measures 0x0 here; without a real size AppKit anchors the
        // popover using its 320x320 default and leaves it floating below the icon.
        if let v = popover.contentViewController?.view {
            v.layoutSubtreeIfNeeded()
            if v.fittingSize.height > 0 { popover.contentSize = v.fittingSize }
        }
        popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.close()
        }
    }

    func close() {
        popover.performClose(nil)
        model.rec.popoverOpen = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
