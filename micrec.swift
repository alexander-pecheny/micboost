// micrec — records the selected mic plus any app or the whole system as sample-locked stems.
//
// Every source lives in one private aggregate device, so a single IOProc delivers all of them
// in the same callback and the stems can never drift apart. Capture writes float32 CAF files
// whose data chunk is left open-ended, which makes a half-written recording a valid file:
// kill -9, a panic or a flat battery costs at most one 50 ms writer tick. Encoding to
// FLAC/ALAC/AAC and the downmix happen afterwards, never on the audio thread.
//
// Build:  swiftc -O -framework AVFoundation -framework CoreAudio -framework AudioToolbox \
//                 -framework AppKit -framework Foundation micrec.swift -o micrec
//
//   micrec sources [--json]        list recordable sources
//   micrec start --source …        record until SIGINT/SIGTERM, then finalise
//   micrec stop                    stop the running recorder
//   micrec status                  what it is doing
//   micrec finalize <dir>          encode one session directory
//   micrec recover                 finalise every session left unfinished

import Foundation
import CoreAudio
import AudioToolbox
import AVFoundation
import AppKit
import Synchronization

let REC_DIR   = NSHomeDirectory() + "/Documents/MicboostRecordings"
let PID_PATH  = "/tmp/micrec.pid"
let STAT_PATH = "/tmp/micrec.status"
let MICBOOST_DOMAIN = "gui/\(getuid())/me.pecheny.micboost"

func note(_ s: String) {
    let t = ISO8601DateFormatter().string(from: Date())
    print("[\(t)] \(s)")
    fflush(stdout)
}
func fail(_ s: String) -> Never {
    FileHandle.standardError.write(("micrec: " + s + "\n").data(using: .utf8)!)
    exit(1)
}

// ============================ Core Audio property helpers ============================
let SYS = AudioObjectID(kAudioObjectSystemObject)

func addr(_ s: AudioObjectPropertySelector,
          _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    .init(mSelector: s, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func get<T>(_ obj: AudioObjectID, _ a: AudioObjectPropertyAddress, _ fallback: T) -> T {
    var x = a, v = fallback, sz = UInt32(MemoryLayout<T>.size)
    guard AudioObjectGetPropertyData(obj, &x, 0, nil, &sz, &v) == noErr else { return fallback }
    return v
}

func getString(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
    var x = addr(sel), cf: Unmanaged<CFString>? = nil
    var sz = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(obj, &x, 0, nil, &sz, &cf) == noErr, let v = cf else { return nil }
    return v.takeRetainedValue() as String
}

func getIDs(_ obj: AudioObjectID, _ a: AudioObjectPropertyAddress) -> [AudioObjectID] {
    var x = a, sz: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(obj, &x, 0, nil, &sz) == noErr, sz > 0 else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(sz) / 4)
    guard AudioObjectGetPropertyData(obj, &x, 0, nil, &sz, &ids) == noErr else { return [] }
    return ids
}

/// Channel count of each buffer, in stream order.
func bufferChannels(_ dev: AudioObjectID, input: Bool = true) -> [Int] {
    var x = addr(kAudioDevicePropertyStreamConfiguration,
                 input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput)
    var sz: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(dev, &x, 0, nil, &sz) == noErr, sz > 0 else { return [] }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(sz), alignment: 16)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(dev, &x, 0, nil, &sz, raw) == noErr else { return [] }
    let abl = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    return abl.map { Int($0.mNumberChannels) }
}

// ============================ processes and apps ============================
func parentPID(_ pid: pid_t) -> pid_t? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    let ppid = info.kp_eproc.e_ppid
    return ppid > 1 ? ppid : nil
}

/// Electron and WebKit render audio from helper processes, and those helpers register as
/// applications in their own right. Walk up to the nearest ancestor that is a real, user-facing
/// app, so "Slack" means Slack and all six of its helpers.
func owningApp(_ pid: pid_t) -> NSRunningApplication? {
    var p: pid_t? = pid, firstSeen: NSRunningApplication? = nil
    for _ in 0..<8 {
        guard let cur = p else { break }
        if let app = NSRunningApplication(processIdentifier: cur), app.bundleIdentifier != nil {
            if app.activationPolicy == .regular { return app }
            firstSeen = firstSeen ?? app
        }
        p = parentPID(cur)
    }
    return firstSeen
}

struct AudioApp {
    var id: String              // bundle identifier
    var name: String
    var objects: [AudioObjectID]
    var playing: Bool
    var tappable: Bool { !objects.isEmpty }
}

/// Every app you could plausibly record: the ones Core Audio knows about (which includes
/// menu-bar apps with no window) plus every app with a Dock icon. An app only becomes tappable
/// once it has touched audio, so the ones that never will are listed but marked.
func audioApps() -> [AudioApp] {
    var byBundle = [String: AudioApp]()
    for obj in getIDs(SYS, addr(kAudioHardwarePropertyProcessObjectList)) {
        let pid: pid_t = get(obj, addr(kAudioProcessPropertyPID), -1)
        guard pid > 0, let app = owningApp(pid), let bid = app.bundleIdentifier else { continue }
        if bid.hasPrefix("com.apple.") && app.activationPolicy != .regular { continue }
        let playing: UInt32 = get(obj, addr(kAudioProcessPropertyIsRunningOutput), 0)
        var e = byBundle[bid] ?? AudioApp(id: bid, name: app.localizedName ?? bid, objects: [], playing: false)
        e.objects.append(obj)
        e.playing = e.playing || playing != 0
        byBundle[bid] = e
    }
    for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
        guard let bid = app.bundleIdentifier, byBundle[bid] == nil else { continue }
        byBundle[bid] = AudioApp(id: bid, name: app.localizedName ?? bid, objects: [], playing: false)
    }
    return byBundle.values.sorted {
        ($0.playing ? 0 : 1, $0.tappable ? 0 : 1, $0.name.lowercased())
            < ($1.playing ? 0 : 1, $1.tappable ? 0 : 1, $1.name.lowercased())
    }
}

func processObjects(ofPID pid: pid_t) -> [AudioObjectID] {
    getIDs(SYS, addr(kAudioHardwarePropertyProcessObjectList)).filter {
        get($0, addr(kAudioProcessPropertyPID), pid_t(-1)) == pid
    }
}

func micboostPID() -> pid_t? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    p.arguments = ["print", MICBOOST_DOMAIN]
    let pipe = Pipe()
    p.standardOutput = pipe; p.standardError = Pipe()
    guard (try? p.run()) != nil else { return nil }
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    p.waitUntilExit()
    for line in out.split(separator: "\n") {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("pid = ") { return pid_t(t.dropFirst(6).trimmingCharacters(in: .whitespaces)) }
    }
    return nil
}

func defaultInputDevice() -> (id: AudioDeviceID, name: String, uid: String)? {
    let id: AudioDeviceID = get(SYS, addr(kAudioHardwarePropertyDefaultInputDevice), 0)
    guard id != 0, let uid = getString(id, kAudioDevicePropertyDeviceUID) else { return nil }
    return (id, getString(id, kAudioObjectPropertyName) ?? "Input", uid)
}

/// The format each input stream actually delivers. The device's nominal sample rate lies when a
/// tap runs at a different rate from the clock device, and a wrong rate in the header is a file
/// that plays back at the wrong speed — so we ask the streams, not the device.
func inputStreamFormats(_ dev: AudioObjectID) -> [AudioStreamBasicDescription] {
    getIDs(dev, addr(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput)).map {
        get($0, addr(kAudioStreamPropertyVirtualFormat), AudioStreamBasicDescription())
    }
}

func setSampleRate(_ dev: AudioObjectID, _ rate: Double) {
    var x = addr(kAudioDevicePropertyNominalSampleRate), v = rate
    AudioObjectSetPropertyData(dev, &x, 0, nil, UInt32(MemoryLayout<Double>.size), &v)
}

/// A tap-only aggregate never fires its IOProc — the taps carry audio but nothing drives the IO
/// cycle. An output device with no input streams supplies the clock without contributing a stem.
func clockDevice() -> (id: AudioDeviceID, name: String, uid: String)? {
    let preferred: AudioDeviceID = get(SYS, addr(kAudioHardwarePropertyDefaultOutputDevice), 0)
    for id in [preferred] + getIDs(SYS, addr(kAudioHardwarePropertyDevices)) where id != 0 {
        guard bufferChannels(id, input: true).isEmpty, !bufferChannels(id, input: false).isEmpty,
              let uid = getString(id, kAudioDevicePropertyDeviceUID) else { continue }
        return (id, getString(id, kAudioObjectPropertyName) ?? "output", uid)
    }
    return nil
}

func inputDevice(named needle: String) -> (id: AudioDeviceID, name: String, uid: String)? {
    for id in getIDs(SYS, addr(kAudioHardwarePropertyDevices)) {
        var x = addr(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput)
        var sz: UInt32 = 0
        AudioObjectGetPropertyDataSize(id, &x, 0, nil, &sz)
        guard sz > 0, let n = getString(id, kAudioObjectPropertyName),
              n.lowercased().contains(needle.lowercased()),
              let uid = getString(id, kAudioDevicePropertyDeviceUID) else { continue }
        return (id, n, uid)
    }
    return nil
}

// ============================ truncation-safe CAF writer ============================
extension Data {
    mutating func be<T: FixedWidthInteger>(_ v: T) { Swift.withUnsafeBytes(of: v.bigEndian) { append(contentsOf: $0) } }
    mutating func fourCC(_ s: String) { append(contentsOf: Array(s.utf8)) }
}

let CAF_HEADER_BYTES = 68

final class CAFWriter {
    private let fd: Int32
    let channels: Int
    let bytesPerFrame: Int
    private(set) var frames = 0

    init?(path: String, sampleRate: Double, channels: Int) {
        fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { return nil }
        self.channels = channels
        bytesPerFrame = 4 * channels

        var h = Data()
        h.fourCC("caff"); h.be(UInt16(1)); h.be(UInt16(0))
        h.fourCC("desc"); h.be(Int64(32))
        h.be(sampleRate.bitPattern)
        h.fourCC("lpcm")
        h.be(UInt32(3))                     // float | little-endian
        h.be(UInt32(bytesPerFrame)); h.be(UInt32(1)); h.be(UInt32(channels)); h.be(UInt32(32))
        h.fourCC("data"); h.be(Int64(-1))   // open-ended: a truncated file is still valid
        h.be(UInt32(0))                     // mEditCount
        h.withUnsafeBytes { _ = writeAll($0.baseAddress!, $0.count) }
    }

    @discardableResult
    private func writeAll(_ p: UnsafeRawPointer, _ n: Int) -> Bool {
        var off = 0
        while off < n {
            let w = write(fd, p.advanced(by: off), n - off)
            if w <= 0 { if errno == EINTR { continue }; return false }
            off += w
        }
        return true
    }

    @discardableResult
    func append(_ p: UnsafeRawPointer, bytes: Int) -> Bool {
        guard writeAll(p, bytes) else { return false }
        frames += bytes / bytesPerFrame
        return true
    }

    func appendSilence(frames n: Int) {
        let chunk = 4096
        var zeros = [UInt8](repeating: 0, count: chunk * bytesPerFrame)
        var left = n
        while left > 0 {
            let take = min(left, chunk)
            zeros.withUnsafeBytes { _ = append($0.baseAddress!, bytes: take * bytesPerFrame) }
            left -= take
        }
    }

    func sync() { fsync(fd) }
    func close() { fsync(fd); Darwin.close(fd) }
}

// ============================ lock-free byte ring ============================
final class ByteRing {
    let cap: Int
    private let mask: Int
    private let buf: UnsafeMutablePointer<UInt8>
    private let wpos = Atomic<Int>(0)
    private let rpos = Atomic<Int>(0)

    init(bytes: Int) {
        var c = 1
        while c < bytes { c <<= 1 }
        cap = c; mask = c - 1
        buf = .allocate(capacity: c)
        buf.initialize(repeating: 0, count: c)
    }

    var free: Int { cap - (wpos.load(ordering: .relaxed) - rpos.load(ordering: .acquiring)) }

    /// Audio thread. Caller must have checked `free` first.
    func push(_ src: UnsafeRawPointer, _ n: Int) {
        let w = wpos.load(ordering: .relaxed)
        let start = w & mask
        let first = min(n, cap - start)
        memcpy(buf + start, src, first)
        if first < n { memcpy(buf, src.advanced(by: first), n - first) }
        wpos.store(w + n, ordering: .releasing)
    }

    /// Writer thread. Returns a pointer to a contiguous run of readable bytes.
    func peek() -> (UnsafeRawPointer, Int)? {
        let r = rpos.load(ordering: .relaxed), w = wpos.load(ordering: .acquiring)
        let avail = w - r
        guard avail > 0 else { return nil }
        let start = r & mask
        return (UnsafeRawPointer(buf + start), min(avail, cap - start))
    }

    func consume(_ n: Int) { rpos.store(rpos.load(ordering: .relaxed) + n, ordering: .releasing) }
}

// ============================ session ============================
struct Stem {
    var key: String            // "mic", "system", "app:org.mozilla.firefox"
    var name: String           // display / file name
    var channels: Int
    var file: String
}

func sanitize(_ s: String) -> String {
    s.map { "/:\\".contains($0) ? "-" : $0 }.reduce(into: "") { $0.append($1) }
       .trimmingCharacters(in: .whitespaces)
}

func writeStatus(_ fields: [String: String]) {
    let s = fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
    try? (s + "\n").write(toFile: STAT_PATH, atomically: true, encoding: .utf8)
}

func readStatus() -> [String: String] {
    guard let t = try? String(contentsOfFile: STAT_PATH, encoding: .utf8) else { return [:] }
    var m = [String: String]()
    for l in t.split(separator: "\n") {
        guard let eq = l.firstIndex(of: "=") else { continue }
        m[String(l[..<eq])] = String(l[l.index(after: eq)...])
    }
    return m
}

// ============================ recorder ============================
let stopFlag = Atomic<Int>(0)

final class Recorder {
    let dir: String
    let format: String
    private(set) var sampleRate: Double      // requested at init, replaced by what the streams report
    var stems: [Stem] = []
    var writers: [CAFWriter] = []
    var rings: [ByteRing] = []

    private var agg = AudioObjectID(0)
    private var taps: [AudioObjectID] = []
    private var procID: AudioDeviceIOProcID?
    private let gapFrames = Atomic<Int>(0)
    private let lastCallback = Atomic<UInt64>(0)
    private var started = Date()
    private var stalls = 0
    private var paddedSeconds = 0.0
    private var log: FileHandle?

    init(dir: String, format: String, sampleRate: Double) {
        self.dir = dir; self.format = format; self.sampleRate = sampleRate
    }

    func logLine(_ s: String) {
        note(s)
        let t = ISO8601DateFormatter().string(from: Date())
        log?.write(("[\(t)] " + s + "\n").data(using: .utf8)!)
    }

    // ---- build the aggregate ----
    // Sub-devices come first in the input stream list, then taps in tap-list order. We assert the
    // channel layout matches what we asked for and refuse to record if it does not, because a
    // mislabelled stem is worse than no recording.
    func start(mic: (id: AudioDeviceID, name: String, uid: String)?,
               system: Bool, apps: [AudioApp]) throws {
        try FileManager.default.createDirectory(atPath: dir + "/raw", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir + "/micrec.log", contents: nil)
        log = FileHandle(forWritingAtPath: dir + "/micrec.log")

        var subDevices: [[String: Any]] = []
        var expected: [(String, String, Int)] = []      // key, display name, channels
        let main: String

        if let m = mic {
            subDevices.append([kAudioSubDeviceUIDKey: m.uid, kAudioSubDeviceDriftCompensationKey: 0])
            expected.append(("mic", m.name, max(1, bufferChannels(m.id).reduce(0, +))))
            main = m.uid
        } else {
            guard let c = clockDevice() else {
                throw NSError(domain: "micrec", code: 1, userInfo: [NSLocalizedDescriptionKey:
                    "no output device available to clock the recording"])
            }
            subDevices.append([kAudioSubDeviceUIDKey: c.uid, kAudioSubDeviceDriftCompensationKey: 0])
            main = c.uid
            logLine("no mic selected — clocking from \(c.name)")
        }

        var tapList: [[String: Any]] = []
        var excluded = [AudioObjectID]()
        if let pid = micboostPID() { excluded += processObjects(ofPID: pid) }   // never re-record our own mic feed
        excluded += processObjects(ofPID: getpid())

        for app in apps {
            let d = CATapDescription(stereoMixdownOfProcesses: app.objects)
            d.name = "micrec: \(app.name)"; d.isPrivate = true; d.muteBehavior = .unmuted
            var t = AudioObjectID(0)
            let s = AudioHardwareCreateProcessTap(d, &t)
            guard s == noErr, let uid = getString(t, kAudioTapPropertyUID) else {
                logLine("could not tap \(app.name) (\(s)) — skipped"); continue
            }
            taps.append(t)
            tapList.append([kAudioSubTapUIDKey: uid, kAudioSubTapDriftCompensationKey: 1])
            expected.append(("app:" + app.id, app.name, 2))
        }
        if system {
            let d = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
            d.name = "micrec: system"; d.isPrivate = true; d.muteBehavior = .unmuted
            var t = AudioObjectID(0)
            let s = AudioHardwareCreateProcessTap(d, &t)
            guard s == noErr, let uid = getString(t, kAudioTapPropertyUID) else {
                throw NSError(domain: "micrec", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "system audio tap failed (\(s))"])
            }
            taps.append(t)
            tapList.append([kAudioSubTapUIDKey: uid, kAudioSubTapDriftCompensationKey: 1])
            expected.append(("system", "System audio", 2))
        }

        let desc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "micrec capture",
            kAudioAggregateDeviceUIDKey: "me.pecheny.micrec.\(getpid())",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceMainSubDeviceKey: main,
            kAudioAggregateDeviceSubDeviceListKey: subDevices,
            kAudioAggregateDeviceTapListKey: tapList,
            // Must be false. With auto-start on, a tap whose app is merely idle (Spotify paused,
            // say) stops the aggregate's IO cycle dead — the IOProc never fires and the mic is
            // lost along with it. Off, the mic keeps flowing and the tap still captures the app
            // the moment it makes a sound.
            kAudioAggregateDeviceTapAutoStartKey: false,
        ]
        let s = AudioHardwareCreateAggregateDevice(desc as CFDictionary, &agg)
        guard s == noErr else {
            throw NSError(domain: "micrec", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "aggregate device failed (\(s))"])
        }

        setSampleRate(agg, sampleRate)                  // pin it; otherwise the clock device decides
        let formats = inputStreamFormats(agg)
        guard formats.count == expected.count else {
            throw NSError(domain: "micrec", code: 4, userInfo: [NSLocalizedDescriptionKey:
                "expected \(expected.count) input streams, got \(formats.count) — refusing to guess the stem layout"])
        }
        let rates = Set(formats.map(\.mSampleRate))
        guard let rate = rates.first, rates.count == 1 else {
            throw NSError(domain: "micrec", code: 8, userInfo: [NSLocalizedDescriptionKey:
                "sources disagree on sample rate (\(rates.sorted())) — they would not stay in sync"])
        }

        for (i, e) in expected.enumerated() {
            let ch = max(1, Int(formats[i].mChannelsPerFrame))
            let file = "raw/" + sanitize(e.1) + ".caf"
            guard let w = CAFWriter(path: dir + "/" + file, sampleRate: rate, channels: ch) else {
                throw NSError(domain: "micrec", code: 5,
                              userInfo: [NSLocalizedDescriptionKey: "cannot create \(file)"])
            }
            stems.append(Stem(key: e.0, name: e.1, channels: ch, file: file))
            writers.append(w)
            rings.append(ByteRing(bytes: Int(rate) * 4 * ch * 8))   // 8 s of slack
            logLine("stem \(i): \(e.1) — \(ch) ch @ \(Int(rate)) Hz -> \(file)")
        }
        sampleRate = rate

        started = Date()
        writeManifest(rate: rate, finished: false)

        let ok = AudioDeviceCreateIOProcIDWithBlock(&procID, agg, nil) { [self] (_, inData, inTS, _, _) in
            captureBlock(inData, inTS)
        }
        guard ok == noErr, procID != nil else {
            throw NSError(domain: "micrec", code: 6,
                          userInfo: [NSLocalizedDescriptionKey: "IOProc failed (\(ok))"])
        }
        lastCallback.store(mach_absolute_time(), ordering: .releasing)
        let started = AudioDeviceStart(agg, procID)
        guard started == noErr else {
            throw NSError(domain: "micrec", code: 7,
                          userInfo: [NSLocalizedDescriptionKey: "AudioDeviceStart failed (\(started))"])
        }
        logLine("recording \(stems.count) stems at \(Int(rate)) Hz into \(dir)")
    }

    // Audio thread: all-or-nothing. If any ring is short of space we drop the whole callback and
    // count the frames, so every stem loses exactly the same samples and stays aligned.
    private func captureBlock(_ inData: UnsafePointer<AudioBufferList>, _ ts: UnsafePointer<AudioTimeStamp>) {
        lastCallback.store(mach_absolute_time(), ordering: .releasing)
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
        guard abl.count == rings.count else { return }

        var frames = 0
        for (i, b) in abl.enumerated() {
            guard rings[i].free >= Int(b.mDataByteSize) else {
                gapFrames.wrappingAdd(frames, ordering: .releasing)
                return
            }
            frames = Int(b.mDataByteSize) / (4 * max(1, Int(b.mNumberChannels)))
        }
        for (i, b) in abl.enumerated() {
            if let p = b.mData { rings[i].push(p, Int(b.mDataByteSize)) }
        }
    }

    // ---- writer thread ----
    func drain(final: Bool) {
        let gap = gapFrames.exchange(0, ordering: .acquiringAndReleasing)
        if gap > 0 {
            logLine("ring overflow: padded \(gap) frames of silence in every stem")
            for w in writers { w.appendSilence(frames: gap) }
        }
        for (i, r) in rings.enumerated() {
            while let (p, n) = r.peek() {
                if !writers[i].append(p, bytes: n) {
                    logLine("WRITE FAILED on \(stems[i].name) — \(String(cString: strerror(errno)))")
                    stopFlag.store(1, ordering: .releasing)
                    return
                }
                r.consume(n)
            }
        }
        if final { for w in writers { w.close() } } else { for w in writers { w.sync() } }
    }

    /// A device that vanishes stalls every stem together, so alignment survives on its own; we pad
    /// only to keep the recording true to wall-clock time.
    func checkStall() {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let last = lastCallback.load(ordering: .acquiring)
        let elapsedNs = (mach_absolute_time() - last) * UInt64(info.numer) / UInt64(info.denom)
        guard elapsedNs > 2_000_000_000 else { return }
        let secs = Double(elapsedNs) / 1e9
        stalls += 1
        paddedSeconds += secs
        logLine(String(format: "WARNING: no audio for %.1f s — that audio is gone; padding silence "
                              + "to keep the stems aligned (%.1f s lost so far)", secs, paddedSeconds))
        let pad = Int(secs * sampleRate)
        for w in writers { w.appendSilence(frames: pad) }
        lastCallback.store(mach_absolute_time(), ordering: .releasing)
    }

    var elapsed: Double { Date().timeIntervalSince(started) }
    var recordedFrames: Int { writers.first?.frames ?? 0 }

    func stop() {
        if let p = procID { AudioDeviceStop(agg, p); AudioDeviceDestroyIOProcID(agg, p) }
        drain(final: true)
        if agg != 0 { AudioHardwareDestroyAggregateDevice(agg) }
        for t in taps { AudioHardwareDestroyProcessTap(t) }
        writeManifest(rate: sampleRate, finished: true)
        logLine("stopped after \(Int(elapsed)) s, \(recordedFrames) frames per stem, \(stalls) stalls")
    }

    func writeManifest(rate: Double, finished: Bool) {
        var m: [String: Any] = [
            "version": 1,
            "sampleRate": rate,
            "format": format,
            "started": ISO8601DateFormatter().string(from: started),
            "aligned": true,
            "capture": finished ? "complete" : "in-progress",
            "stems": stems.enumerated().map { i, s in
                ["key": s.key, "name": s.name, "channels": s.channels,
                 "raw": s.file, "frames": writers.indices.contains(i) ? writers[i].frames : 0]
            },
        ]
        if finished { m["durationSeconds"] = Double(recordedFrames) / rate }
        if stalls > 0 {                       // audio the hardware never delivered, not a mixing error
            m["stalls"] = stalls
            m["silencePaddedSeconds"] = (paddedSeconds * 10).rounded() / 10
        }
        guard let d = try? JSONSerialization.data(withJSONObject: m, options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? d.write(to: URL(fileURLWithPath: dir + "/session.json"), options: .atomic)
    }
}

// ============================ encoding ============================
struct RawStem {
    var name: String
    var path: String
    var channels: Int
    var frames: Int
}

func rawStems(in dir: String) -> (rate: Double, format: String, stems: [RawStem])? {
    guard let d = FileManager.default.contents(atPath: dir + "/session.json"),
          let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
          let rate = j["sampleRate"] as? Double,
          let arr = j["stems"] as? [[String: Any]] else { return nil }
    let format = (j["format"] as? String) ?? "flac"
    var out = [RawStem]()
    for s in arr {
        guard let name = s["name"] as? String, let raw = s["raw"] as? String,
              let ch = s["channels"] as? Int else { continue }
        let path = dir + "/" + raw
        let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int ?? 0
        out.append(RawStem(name: name, path: path, channels: ch,
                           frames: max(0, (size - CAF_HEADER_BYTES) / (4 * ch))))
    }
    return out.isEmpty ? nil : (rate, format, out)
}

func encoderSettings(_ format: String, rate: Double, channels: Int) -> ([String: Any], String)? {
    switch format {
    case "flac": return ([AVFormatIDKey: kAudioFormatFLAC, AVSampleRateKey: rate,
                          AVNumberOfChannelsKey: channels, AVLinearPCMBitDepthKey: 24], "flac")
    case "aac":  return ([AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate,
                          AVNumberOfChannelsKey: channels, AVEncoderBitRateKey: 256_000], "m4a")
    default: return nil
    }
}

/// Streams a raw CAF through a block, `chunk` frames at a time.
func readRaw(_ s: RawStem, chunk: Int, _ body: (UnsafePointer<Float>, Int) -> Void) throws {
    let fh = try FileHandle(forReadingFrom: URL(fileURLWithPath: s.path))
    defer { try? fh.close() }
    try fh.seek(toOffset: UInt64(CAF_HEADER_BYTES))
    let bytes = chunk * 4 * s.channels
    while true {
        guard let d = try fh.read(upToCount: bytes), !d.isEmpty else { return }
        let n = d.count / (4 * s.channels)
        guard n > 0 else { return }
        d.withUnsafeBytes { body($0.bindMemory(to: Float.self).baseAddress!, n) }
    }
}

func encode(_ s: RawStem, to path: String, rate: Double, format: String) throws {
    guard let (settings, _) = encoderSettings(format, rate: rate, channels: s.channels) else {
        throw NSError(domain: "micrec", code: 10,
                      userInfo: [NSLocalizedDescriptionKey: "unknown format \(format)"])
    }
    let url = URL(fileURLWithPath: path)
    try? FileManager.default.removeItem(at: url)
    let file = try AVAudioFile(forWriting: url, settings: settings,
                               commonFormat: .pcmFormatFloat32, interleaved: false)
    let fmt = file.processingFormat
    let chunk = 32768
    guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(chunk)) else { return }
    var err: Error?
    try readRaw(s, chunk: chunk) { p, n in
        guard err == nil, let dst = buf.floatChannelData else { return }
        for c in 0..<s.channels { for i in 0..<n { dst[c][i] = p[i * s.channels + c] } }
        buf.frameLength = AVAudioFrameCount(n)
        do { try file.write(from: buf) } catch { err = error }
    }
    if let e = err { throw e }
}

/// Sums every stem to stereo. Two passes: find the peak, then write with exactly the gain needed
/// to sit at -0.5 dBFS, so the mix never clips and is never needlessly quiet.
func downmix(_ stems: [RawStem], to path: String, rate: Double, format: String) throws {
    let frames = stems.map(\.frames).max() ?? 0
    guard frames > 0 else { return }
    let chunk = 32768
    var acc = [Float](repeating: 0, count: chunk * 2)

    func sweep(_ body: (UnsafePointer<Float>, Int) -> Void) throws {
        var handles = [FileHandle]()
        for s in stems {
            let fh = try FileHandle(forReadingFrom: URL(fileURLWithPath: s.path))
            try fh.seek(toOffset: UInt64(CAF_HEADER_BYTES))
            handles.append(fh)
        }
        defer { for h in handles { try? h.close() } }
        var done = 0
        while done < frames {
            let want = min(chunk, frames - done)
            for i in 0..<(want * 2) { acc[i] = 0 }
            for (i, s) in stems.enumerated() {
                guard let d = try handles[i].read(upToCount: want * 4 * s.channels), !d.isEmpty else { continue }
                let n = min(want, d.count / (4 * s.channels))
                d.withUnsafeBytes { rb in
                    let p = rb.bindMemory(to: Float.self).baseAddress!
                    for f in 0..<n {
                        if s.channels == 1 {
                            acc[f * 2] += p[f]; acc[f * 2 + 1] += p[f]
                        } else {
                            acc[f * 2] += p[f * s.channels]; acc[f * 2 + 1] += p[f * s.channels + 1]
                        }
                    }
                }
            }
            acc.withUnsafeBufferPointer { body($0.baseAddress!, want) }
            done += want
        }
    }

    var peak: Float = 0
    try sweep { p, n in for i in 0..<(n * 2) { peak = max(peak, abs(p[i])) } }
    let ceiling: Float = 0.9441                      // -0.5 dBFS
    let gain = peak > ceiling ? ceiling / peak : 1

    guard let (settings, _) = encoderSettings(format, rate: rate, channels: 2) else { return }
    let url = URL(fileURLWithPath: path)
    try? FileManager.default.removeItem(at: url)
    let file = try AVAudioFile(forWriting: url, settings: settings,
                               commonFormat: .pcmFormatFloat32, interleaved: false)
    guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                     frameCapacity: AVAudioFrameCount(chunk)) else { return }
    var err: Error?
    try sweep { p, n in
        guard err == nil, let dst = buf.floatChannelData else { return }
        for i in 0..<n { dst[0][i] = p[i * 2] * gain; dst[1][i] = p[i * 2 + 1] * gain }
        buf.frameLength = AVAudioFrameCount(n)
        do { try file.write(from: buf) } catch { err = error }
    }
    if let e = err { throw e }
    if gain < 1 { note(String(format: "mix: peak was %.1f dBFS, pulled down %.1f dB",
                              20 * log10(peak), 20 * log10(gain))) }
}

/// Encode stems + mix, verify every output before the raw capture is removed.
@discardableResult
func finalize(dir: String, keepRaw: Bool) -> Bool {
    guard let (rate, format, stems) = rawStems(in: dir) else {
        note("\(dir): no session.json — skipped"); return false
    }
    guard let (_, ext) = encoderSettings(format, rate: rate, channels: 2) else {
        note("\(dir): unknown format \(format)"); return false
    }
    writeStatus(["state": "finalizing", "session": dir])
    try? FileManager.default.createDirectory(atPath: dir + "/stems", withIntermediateDirectories: true)

    var ok = true
    for s in stems where s.frames > 0 {
        let out = dir + "/stems/" + sanitize(s.name) + "." + ext
        do {
            try encode(s, to: out, rate: rate, format: format)
            let written = (try? AVAudioFile(forReading: URL(fileURLWithPath: out)).length) ?? 0
            // lossy codecs pad to a packet boundary; a short file means a real failure
            if Double(written) < Double(s.frames) * 0.999 {
                note("\(s.name): encoded \(written) of \(s.frames) frames — keeping raw"); ok = false
            } else {
                note("\(s.name): \(written) frames -> \(out)")
            }
        } catch { note("\(s.name): encode failed — \(error.localizedDescription)"); ok = false }
    }
    if stems.count > 1 {
        do { try downmix(stems, to: dir + "/mix." + ext, rate: rate, format: format) }
        catch { note("mix failed — \(error.localizedDescription)"); ok = false }
    }

    if ok && !keepRaw {
        try? FileManager.default.removeItem(atPath: dir + "/raw")
    } else if !ok {
        note("\(dir): raw capture kept because something did not verify")
    }
    if var j = (FileManager.default.contents(atPath: dir + "/session.json")
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) {
        j["encoded"] = ok ? "complete" : "partial"
        j["rawKept"] = keepRaw || !ok
        if let d = try? JSONSerialization.data(withJSONObject: j, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: URL(fileURLWithPath: dir + "/session.json"), options: .atomic)
        }
    }
    writeStatus(["state": "idle"])
    return ok
}

// ============================ commands ============================
func argValue(_ name: String) -> String? {
    let a = CommandLine.arguments
    guard let i = a.firstIndex(of: name), i + 1 < a.count else { return nil }
    return a[i + 1]
}
func argValues(_ name: String) -> [String] {
    let a = CommandLine.arguments
    return a.indices.filter { a[$0] == name && $0 + 1 < a.count }.map { a[$0 + 1] }
}
func hasFlag(_ name: String) -> Bool { CommandLine.arguments.contains(name) }

func cmdSources() {
    let mic = defaultInputDevice()
    let apps = audioApps()
    if hasFlag("--json") {
        var list: [[String: Any]] = []
        if let m = mic { list.append(["id": "mic", "name": m.name, "kind": "mic", "playing": true]) }
        list.append(["id": "system", "name": "All system audio", "kind": "system", "playing": true])
        for a in apps {
            list.append(["id": "app:" + a.id, "name": a.name, "kind": "app",
                         "playing": a.playing, "tappable": a.tappable])
        }
        let d = try! JSONSerialization.data(withJSONObject: list, options: [.prettyPrinted])
        FileHandle.standardOutput.write(d)
        print("")
    } else {
        print("mic     \(mic?.name ?? "— none selected —")")
        print("system  All system audio")
        for a in apps {
            let mark = a.playing ? "  ♪" : (a.tappable ? "" : "  (no audio yet)")
            print("app:\(a.id.padding(toLength: max(a.id.count, 34), withPad: " ", startingAt: 0)) \(a.name)\(mark)")
        }
    }
}

func cmdStart() {
    if let t = try? String(contentsOfFile: PID_PATH, encoding: .utf8), let pid = pid_t(t.trimmingCharacters(in: .whitespacesAndNewlines)),
       kill(pid, 0) == 0 { fail("already recording (pid \(pid))") }

    let format = argValue("--format") ?? "flac"
    guard encoderSettings(format, rate: 48000, channels: 2) != nil else {
        fail("unknown format \(format) — use flac or aac")
    }
    let wanted = argValues("--source")
    guard !wanted.isEmpty else { fail("nothing to record — pass --source mic / system / app:<bundle id>") }

    let mic = wanted.contains("mic") ? defaultInputDevice() : nil
    if wanted.contains("mic") && mic == nil { fail("no input device is selected") }
    let apps = audioApps().filter { wanted.contains("app:" + $0.id) && $0.tappable }
    for w in wanted where w.hasPrefix("app:") {
        if !apps.contains(where: { "app:" + $0.id == w }) {
            note("\(w) has not opened an audio stream yet — cannot be tapped, skipped")
        }
    }
    let system = wanted.contains("system")
    guard mic != nil || system || !apps.isEmpty else { fail("no source is available to record") }

    let stamp = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH-mm-ss"; return f.string(from: Date()) }()
    let dir = (argValue("--dir") ?? REC_DIR) + "/" + stamp
    let rec = Recorder(dir: dir, format: format, sampleRate: 48000)
    do { try rec.start(mic: mic, system: system, apps: apps) }
    catch { fail(error.localizedDescription) }

    try? "\(getpid())\n".write(toFile: PID_PATH, atomically: true, encoding: .utf8)
    print(dir)

    for s in [SIGINT, SIGTERM] {
        signal(s, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: s, queue: .global())
        src.setEventHandler { stopFlag.store(1, ordering: .releasing) }
        src.resume()
        signalSources.append(src)
    }

    var ticks = 0
    while stopFlag.load(ordering: .acquiring) == 0 {
        Thread.sleep(forTimeInterval: 0.05)
        rec.drain(final: false)
        ticks += 1
        if ticks % 20 == 0 {                                   // once a second
            rec.checkStall()
            writeStatus(["state": "recording", "session": dir, "format": format,
                         "seconds": String(Int(rec.elapsed)),
                         "stems": rec.stems.map(\.name).joined(separator: "|")])
            if ticks % 100 == 0, freeBytes(dir) < 300_000_000 {
                rec.logLine("less than 300 MB free — stopping while the recording is still good")
                break
            }
        }
    }
    rec.stop()
    try? FileManager.default.removeItem(atPath: PID_PATH)
    finalize(dir: dir, keepRaw: hasFlag("--keep-raw"))
    print("done: \(dir)")
}

var signalSources: [DispatchSourceSignal] = []

func freeBytes(_ path: String) -> Int64 {
    let v = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    return v?.volumeAvailableCapacityForImportantUsage ?? Int64.max
}

func cmdStop() {
    guard let t = try? String(contentsOfFile: PID_PATH, encoding: .utf8),
          let pid = pid_t(t.trimmingCharacters(in: .whitespacesAndNewlines)), kill(pid, 0) == 0 else {
        fail("not recording")
    }
    kill(pid, SIGTERM)
    for _ in 0..<600 {                                          // finalising can take a while
        Thread.sleep(forTimeInterval: 0.1)
        if kill(pid, 0) != 0 { print("stopped"); return }
    }
    fail("recorder did not exit")
}

func cmdStatus() {
    let s = readStatus()
    let running = (try? String(contentsOfFile: PID_PATH, encoding: .utf8))
        .flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        .map { kill($0, 0) == 0 } ?? false
    print("state    \(running ? (s["state"] ?? "recording") : (s["state"] ?? "idle"))")
    if let d = s["session"] { print("session  \(d)") }
    if let n = s["seconds"], running { print("elapsed  \(n) s") }
    if let n = s["stems"] { print("stems    \(n.replacingOccurrences(of: "|", with: ", "))") }
}

func cmdRecover() {
    let fm = FileManager.default
    guard let dirs = try? fm.contentsOfDirectory(atPath: REC_DIR) else { print("nothing to recover"); return }
    // Never touch the session a live recorder is still writing into.
    let live: String? = (try? String(contentsOfFile: PID_PATH, encoding: .utf8))
        .flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        .flatMap { kill($0, 0) == 0 ? readStatus()["session"] : nil }
    var n = 0
    for d in dirs.sorted() {
        let full = REC_DIR + "/" + d
        if full == live { note("\(d) is still recording — left alone"); continue }
        guard fm.fileExists(atPath: full + "/raw"),
              let j = fm.contents(atPath: full + "/session.json")
                  .flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }),
              (j["encoded"] as? String) != "complete" else { continue }
        note("recovering \(d)")
        finalize(dir: full, keepRaw: false)
        n += 1
    }
    print(n == 0 ? "nothing to recover" : "recovered \(n) session(s)")
}

// ============================ main ============================
setbuf(stdout, nil)
switch CommandLine.arguments.dropFirst().first ?? "" {
case "sources":  cmdSources()
case "start":    cmdStart()
case "stop":     cmdStop()
case "status":   cmdStatus()
case "finalize": finalize(dir: argValue("finalize") ?? "", keepRaw: hasFlag("--keep-raw"))
case "recover":  cmdRecover()
default:
    print("""
    micrec — sample-locked multi-source recorder

      micrec sources [--json]
      micrec start --source mic [--source system] [--source app:<bundle id>]
                   [--format flac|aac] [--dir <path>] [--keep-raw]
      micrec stop
      micrec status
      micrec finalize <session dir> [--keep-raw]
      micrec recover

    Recordings go to \(REC_DIR).
    """)
}
