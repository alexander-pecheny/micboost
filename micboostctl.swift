// micboostctl — control + tune the micboost bridge.
//
//   micboostctl            interactive TUI: pick input mic + output device, tune gain/comp
//   micboostctl <cmd> …    scriptable CLI (show, devices, gain, comp, input, output, …)
//
// Build:  swiftc -O -framework CoreAudio -framework Foundation micboostctl.swift -o micboostctl
//
// Every change is written to ~/.config/micboost/config and hot-applied by restarting the
// launchd agent (gui/<uid>/me.pecheny.micboost).

import Foundation
import CoreAudio

// ============================ paths / launchd ============================
let LABEL  = "me.pecheny.micboost"
let DOMAIN = "gui/\(getuid())/\(LABEL)"
let LOG    = "/tmp/micboost.log"
let CONFIG_PATH = (ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
                   ?? NSHomeDirectory() + "/.config") + "/micboost/config"
let PROFILE_PATH = (CONFIG_PATH as NSString).deletingLastPathComponent + "/noise.profile"
let STATUS_PATH  = "/tmp/micboost.status"

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

func apply() { run("/bin/launchctl", ["kickstart", "-k", DOMAIN]) }

// ============================ noise profile ============================
func agentPID() -> pid_t? {
    for line in run("/bin/launchctl", ["print", DOMAIN], capture: true).split(separator: "\n") {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("pid = ") { return pid_t(t.dropFirst(6).trimmingCharacters(in: .whitespaces)) }
    }
    return nil
}

func hasProfile() -> Bool { FileManager.default.fileExists(atPath: PROFILE_PATH) }

func profileMTime() -> Date? {
    let a = try? FileManager.default.attributesOfItem(atPath: PROFILE_PATH)
    return a?[.modificationDate] as? Date
}

func nrState() -> String {
    guard let s = try? String(contentsOfFile: STATUS_PATH, encoding: .utf8) else { return "unknown" }
    for line in s.split(separator: "\n") where line.hasPrefix("nr=") { return String(line.dropFirst(3)) }
    return "unknown"
}

func captureSeconds(_ cfg: Config) -> Double { Double(cfg.get("NR_CAPTURE_SEC") ?? "") ?? 6 }

// Ask the running daemon (SIGUSR1) to sample the room, then wait for the profile file to land.
// `tick` is called roughly every 0.2 s with the seconds remaining, for progress display.
func captureProfile(_ cfg: Config, tick: (Double) -> Void = { _ in }) -> String? {
    guard let pid = agentPID() else { return "micboost is not running" }
    let before = profileMTime()
    guard kill(pid, SIGUSR1) == 0 else { return "could not signal micboost (pid \(pid))" }

    let secs = captureSeconds(cfg)
    let deadline = Date().addingTimeInterval(secs + 5)
    while Date() < deadline {
        tick(max(0, deadline.timeIntervalSinceNow - 5))
        Thread.sleep(forTimeInterval: 0.2)
        if let m = profileMTime(), m != before { return nil }
    }
    return "timed out waiting for the noise profile"
}

// ============================ config file ============================
// Order-preserving KEY=VALUE store that keeps blank lines, comments, and inline comments.
final class Config {
    var lines: [String]
    init() {
        let text = (try? String(contentsOfFile: CONFIG_PATH, encoding: .utf8)) ?? ""
        lines = text.isEmpty ? [] : text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }        // drop trailing newline artifact
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

// ============================ TUI ============================
struct TermColors {
    let bold = "\u{1b}[1m", dim = "\u{1b}[2m", rev = "\u{1b}[7m", off = "\u{1b}[0m"
    let cyan = "\u{1b}[36m", green = "\u{1b}[32m", yellow = "\u{1b}[33m"
}

enum Key { case up, down, left, right, enter, space, esc, char(Character) }

final class TUI {
    let cfg: Config
    let c = TermColors()
    var savedTermios = termios()

    // staged vs. saved snapshots
    var inDev: String, outDev: String, gain: Double, comp: Bool, nr: Bool
    var oInDev: String, oOutDev: String, oGain: Double, oComp: Bool, oNr: Bool   // last-saved snapshot
    var status = ""

    enum Row: Int, CaseIterable { case input, output, gain, comp, nr, capture }
    var cur: Row = .input

    init(_ cfg: Config) {
        self.cfg = cfg
        let rawIn  = cfg.get("RODE_NAME") ?? "Wireless MICRO"
        let rawOut = cfg.get("OUT_NAME")  ?? "BlackHole"
        inDev  = resolve(rawIn,  input: true)  ?? rawIn
        outDev = resolve(rawOut, input: false) ?? rawOut
        gain   = Double(cfg.get("GAIN_DB") ?? "") ?? 12
        comp   = (cfg.get("COMP") ?? "1") != "0"
        nr     = (cfg.get("NR") ?? "0") != "0"
        oInDev = inDev; oOutDev = outDev; oGain = gain; oComp = comp; oNr = nr
    }

    var dirty: Bool { inDev != oInDev || outDev != oOutDev || gain != oGain || comp != oComp || nr != oNr }

    // ---- raw terminal ----
    func enterRaw() {
        tcgetattr(0, &savedTermios)
        var raw = savedTermios
        raw.c_lflag &= ~UInt(ECHO | ICANON)
        raw.c_cc.16 = 1   // VMIN
        raw.c_cc.17 = 0   // VTIME
        tcsetattr(0, TCSANOW, &raw)
        write("\u{1b}[?1049h\u{1b}[?25l")   // alt screen + hide cursor
    }
    func exitRaw() {
        tcsetattr(0, TCSANOW, &savedTermios)
        write("\u{1b}[?25h\u{1b}[?1049l")   // show cursor + leave alt screen
    }
    func write(_ s: String) { FileHandle.standardOutput.write(s.data(using: .utf8)!) }
    func clear() { write("\u{1b}[H\u{1b}[2J") }

    func readKey() -> Key {
        var buf = [UInt8](repeating: 0, count: 8)
        let n = read(0, &buf, 8)
        if n <= 0 { return .esc }
        if buf[0] == 0x1b {
            if n >= 3 && buf[1] == 0x5b {
                switch buf[2] { case 0x41: return .up; case 0x42: return .down
                                case 0x43: return .right; case 0x44: return .left; default: break }
            }
            return .esc
        }
        switch buf[0] {
        case 0x0a, 0x0d: return .enter
        case 0x20:       return .space
        default:         return .char(Character(UnicodeScalar(buf[0])))
        }
    }

    // ---- full-screen device picker; returns chosen name or nil if cancelled ----
    func pick(title: String, items: [String], preselect: String) -> String? {
        let list = items.isEmpty ? ["(no devices found)"] : items
        var sel = list.firstIndex(of: preselect) ?? 0
        while true {
            clear()
            write("  \(c.bold)\(c.cyan)\(title)\(c.off)\n\n")
            for (i, name) in list.enumerated() {
                if i == sel { write("  \(c.rev) ▸ \(name) \(c.off)\n") }
                else        { write("     \(name)\n") }
            }
            write("\n  \(c.dim)↑/↓ move · enter select · esc cancel\(c.off)\n")
            switch readKey() {
            case .up:    sel = (sel - 1 + list.count) % list.count
            case .down:  sel = (sel + 1) % list.count
            case .char("k"): sel = (sel - 1 + list.count) % list.count
            case .char("j"): sel = (sel + 1) % list.count
            case .enter: return items.isEmpty ? nil : list[sel]
            case .esc, .char("q"): return nil
            default: break
            }
        }
    }

    // ---- main screen ----
    func rowValue(_ r: Row) -> String {
        switch r {
        case .input:  return inDev
        case .output: return outDev
        case .gain:   return "\(fmtNum(gain)) dB"
        case .comp:   return comp ? "on" : "off"
        case .nr:     return nr ? (hasProfile() ? "on" : "on — no profile yet") : "off"
        case .capture: return hasProfile() ? "profile recorded · enter to redo" : "enter to record"
        }
    }
    func rowLabel(_ r: Row) -> String {
        switch r {
        case .input:  return "Input  (mic to boost)"
        case .output: return "Output (virtual mic)"
        case .gain:   return "Gain"
        case .comp:   return "Compressor"
        case .nr:     return "Noise suppression"
        case .capture: return "Noise profile"
        }
    }

    // Records the room with the daemon while the user stays quiet; NR is switched on afterwards.
    func doCapture() {
        clear()
        write("\n  \(c.bold)\(c.cyan)Recording noise profile\(c.off)\n\n")
        write("  \(c.dim)Stay silent. Leave the room exactly as it is during calls\n")
        write("  (fans, laptop, street) — that is what gets subtracted.\(c.off)\n\n")
        let err = captureProfile(cfg) { left in
            self.write(String(format: "\r  \(self.c.yellow)● recording… %.1fs\(self.c.off)   ", left))
        }
        if let err {
            status = "capture failed: \(err)"
        } else {
            cfg.set("NR", "1"); cfg.save()
            apply()                          // restart to apply, like every other change
            nr = true; oNr = true
            status = "noise profile captured — suppression is on"
        }
    }

    func draw() {
        clear()
        write("  \(c.bold)\(c.cyan)micboost\(c.off)  \(c.dim)· device routing & tuning\(c.off)\n\n")
        for r in Row.allCases {
            let label = rowLabel(r).padding(toLength: 22, withPad: " ", startingAt: 0)
            if r == cur { write("  \(c.rev) ▸ \(label) \(rowValue(r)) \(c.off)\n") }
            else        { write("     \(label) \(c.bold)\(rowValue(r))\(c.off)\n") }
        }
        write("\n")
        if dirty { write("  \(c.yellow)● unsaved\(c.off) — press \(c.bold)a\(c.off) to apply\n") }
        else     { write("  \(c.green)✓ in sync with running micboost\(c.off)\n") }
        write("\n  \(c.dim)↑/↓ move · enter change · ←/→ gain · space toggle · a apply · q quit\(c.off)\n")
        if !status.isEmpty { write("\n  \(c.green)\(status)\(c.off)\n") }
    }

    func choose(input: Bool) {
        clear(); write("  \(c.dim)scanning audio devices…\(c.off)\n")
        let cur = input ? inDev : outDev
        if let picked = pick(title: "Select \(input ? "input" : "output") device",
                             items: devices(input: input), preselect: cur) {
            if input { inDev = picked } else { outDev = picked }
        }
    }

    func applyChanges() {
        guard dirty else { status = "nothing to apply"; return }
        cfg.set("RODE_NAME", inDev); cfg.set("OUT_NAME", outDev)
        cfg.set("GAIN_DB", fmtNum(gain)); cfg.set("COMP", comp ? "1" : "0")
        cfg.set("NR", nr ? "1" : "0")
        cfg.save(); apply()
        oInDev = inDev; oOutDev = outDev; oGain = gain; oComp = comp; oNr = nr   // saved baseline
        status = "applied → micboost restarted"
    }

    func loop() {
        enterRaw()
        defer { exitRaw() }
        var pendingQuit = false
        while true {
            draw()
            let key = readKey()
            // any key other than a repeated quit cancels a pending discard
            if case .char("q") = key {} else if case .esc = key {} else { pendingQuit = false }
            switch key {
            case .up, .char("k"):
                cur = Row(rawValue: (cur.rawValue - 1 + Row.allCases.count) % Row.allCases.count)!; status = ""
            case .down, .char("j"):
                cur = Row(rawValue: (cur.rawValue + 1) % Row.allCases.count)!; status = ""
            case .enter:
                status = ""
                switch cur {
                case .input:  choose(input: true)
                case .output: choose(input: false)
                case .comp:   comp.toggle()
                case .nr:     nr.toggle()
                case .gain:   gain += 1
                case .capture: doCapture()
                }
            case .space:
                if cur == .comp { comp.toggle() }
                if cur == .nr   { nr.toggle() }
            case .right, .char("+"), .char("="):
                if cur == .gain { gain += 1 }
            case .left, .char("-"):
                if cur == .gain { gain -= 1 }
            case .char("a"):
                applyChanges()
            case .char("q"), .esc:
                if !dirty || pendingQuit { return }
                pendingQuit = true
                status = "unsaved changes — a to apply, q again to discard"
            default: break
            }
        }
    }
}

// ============================ CLI ============================
func cliShow(_ cfg: Config) {
    print("config: \(CONFIG_PATH)")
    for k in ["GAIN_DB","HPF_HZ","COMP","THRESH_DB","RATIO","MAKEUP_DB","ATTACK_MS","RELEASE_MS",
              "LIMIT_MS","LIMIT_RELEASE_MS","CEIL_DB",
              "NR","NR_ALPHA","NR_FLOOR","NR_SMOOTH","NR_CAPTURE_SEC","RODE_NAME","OUT_NAME"] {
        print(String(format: "  %-15s %@", (k as NSString).utf8String!, (cfg.get(k) ?? "<default>") as NSString))
    }
    print("  noise profile   \(hasProfile() ? PROFILE_PATH : "<none — run `micboostctl nr capture`>")")
    print("  live state      nr=\(nrState())")
}

func cliNR(_ cfg: Config, _ argv: [String]) {
    switch argv.count >= 2 ? argv[1] : "show" {
    case "show":
        print("NR = \(cfg.get("NR") ?? "0")   live: nr=\(nrState())")
        print("profile: \(hasProfile() ? PROFILE_PATH : "none — run `micboostctl nr capture`")")
    case "on", "1":
        if !hasProfile() { print("warning: no noise profile yet — record one with `micboostctl nr capture`") }
        put(cfg, "NR", "1", "NR = 1")
    case "off", "0":
        put(cfg, "NR", "0", "NR = 0")
    case "clear":
        try? FileManager.default.removeItem(atPath: PROFILE_PATH)
        put(cfg, "NR", "0", "noise profile cleared, NR = 0")
    case "capture":
        let secs = captureSeconds(cfg)
        print("Recording \(fmtNum(secs))s of room noise — stay silent…")
        var lastShown = -1.0
        let err = captureProfile(cfg) { left in
            let s = (left * 10).rounded() / 10
            if s != lastShown { lastShown = s; print(String(format: "\r  %.1fs remaining ", left), terminator: ""); fflush(stdout) }
        }
        print("\r                          \r", terminator: "")
        if let err {
            FileHandle.standardError.write("capture failed: \(err)\n".data(using: .utf8)!); exit(1)
        }
        cfg.set("NR", "1"); cfg.save()
        apply()
        print("noise profile captured → \(PROFILE_PATH)\nnoise suppression is on")
    default:
        FileHandle.standardError.write("usage: micboostctl nr [show|on|off|capture|clear]\n".data(using: .utf8)!); exit(1)
    }
}

func usage() {
    print("""
    micboostctl — control the RODE→BlackHole mic processor (auto-restarts on change)

      micboostctl                      launch the interactive TUI (pick devices, tune)
      micboostctl tui                  same as above, explicitly

      micboostctl show                 show current settings
      micboostctl devices              list live input/output devices
      micboostctl status               launchd status
      micboostctl log                  tail the log

      micboostctl input <name>         set input (mic) device   (substring match)
      micboostctl output <name>        set output device        (substring match)
      micboostctl gain <dB>            set absolute pre-boost    (e.g. gain 15)
      micboostctl gain +3 | -2         nudge boost relative
      micboostctl comp on | off        compressor on/off

      micboostctl nr                   show noise-suppression state
      micboostctl nr capture           record a noise profile (stay silent for ~6s)
      micboostctl nr on | off          noise suppression on/off
      micboostctl nr clear             forget the profile and switch NR off

      micboostctl threshold <dB>       compressor threshold      (e.g. -18)
      micboostctl ratio <x>            compressor ratio          (e.g. 4)
      micboostctl makeup <dB>          post-compressor makeup gain
      micboostctl attack <ms>          envelope attack
      micboostctl release <ms>         envelope release
      micboostctl set KEY VALUE        set any raw key

      micboostctl restart              re-apply without changes
    """)
}

func need(_ args: [String], _ n: Int, _ msg: String) {
    if args.count < n { FileHandle.standardError.write((msg + "\n").data(using: .utf8)!); exit(1) }
}

func put(_ cfg: Config, _ k: String, _ v: String, _ echo: String) {
    cfg.set(k, v); cfg.save(); print(echo); apply()
}

let argv = Array(CommandLine.arguments.dropFirst())
let cfg = Config()
let cmd = argv.first ?? "tui"

switch cmd {
case "tui", "ui":
    guard isatty(0) != 0 && isatty(1) != 0 else {
        FileHandle.standardError.write("micboostctl: TUI needs an interactive terminal\n".data(using: .utf8)!); exit(1)
    }
    TUI(cfg).loop()

case "show": cliShow(cfg)

case "devices":
    print("inputs:");  for d in devices(input: true)  { print("  \(d)") }
    print("outputs:"); for d in devices(input: false) { print("  \(d)") }

case "status":
    let out = run("/bin/launchctl", ["print", DOMAIN], capture: true)
    let hits = out.split(separator: "\n").filter { $0.contains("state =") || $0.contains("pid =") }.prefix(3)
    print(hits.isEmpty ? "not loaded" : hits.joined(separator: "\n"))

case "log":
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
    p.arguments = ["-n", "40", "-f", LOG]
    try? p.run(); p.waitUntilExit()

case "input":  need(argv, 2, "usage: micboostctl input <name>");  put(cfg, "RODE_NAME", argv[1], "RODE_NAME = \(argv[1])")
case "output": need(argv, 2, "usage: micboostctl output <name>"); put(cfg, "OUT_NAME", argv[1], "OUT_NAME = \(argv[1])")

case "gain":
    need(argv, 2, "usage: micboostctl gain <dB|+N|-N>")
    let a = argv[1]
    let newVal: Double
    if a.hasPrefix("+") || (a.hasPrefix("-") && Double(a) != nil && a.count > 1 && !a.dropFirst().contains(where: { !$0.isNumber && $0 != "." })) {
        let cur = Double(cfg.get("GAIN_DB") ?? "") ?? 12
        newVal = cur + (Double(a) ?? 0)
    } else {
        newVal = Double(a) ?? 0
    }
    put(cfg, "GAIN_DB", fmtNum(newVal), "GAIN_DB = \(fmtNum(newVal)) dB")

case "comp":
    switch argv.count >= 2 ? argv[1] : "" {
    case "on", "1":  put(cfg, "COMP", "1", "COMP = 1")
    case "off", "0": put(cfg, "COMP", "0", "COMP = 0")
    default: FileHandle.standardError.write("usage: micboostctl comp on|off\n".data(using: .utf8)!); exit(1)
    }

case "nr": cliNR(cfg, argv)

case "threshold": need(argv, 2, "usage: micboostctl threshold <dB>"); put(cfg, "THRESH_DB", argv[1], "THRESH_DB = \(argv[1]) dB")
case "ratio":     need(argv, 2, "usage: micboostctl ratio <x>");      put(cfg, "RATIO", argv[1], "RATIO = \(argv[1])")
case "makeup":    need(argv, 2, "usage: micboostctl makeup <dB>");    put(cfg, "MAKEUP_DB", argv[1], "MAKEUP_DB = \(argv[1]) dB")
case "attack":    need(argv, 2, "usage: micboostctl attack <ms>");    put(cfg, "ATTACK_MS", argv[1], "ATTACK_MS = \(argv[1]) ms")
case "release":   need(argv, 2, "usage: micboostctl release <ms>");   put(cfg, "RELEASE_MS", argv[1], "RELEASE_MS = \(argv[1]) ms")

case "set":
    need(argv, 3, "usage: micboostctl set KEY VALUE")
    put(cfg, argv[1], argv[2], "\(argv[1]) = \(argv[2])")

case "restart": apply(); print("applied → restarted micboost")
case "help", "-h", "--help": usage()
default:
    FileHandle.standardError.write("unknown command: \(cmd)\n\n".data(using: .utf8)!); usage(); exit(1)
}
