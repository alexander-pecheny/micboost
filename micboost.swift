// micboost — headless Core Audio bridge: RODE -> denoise + gain + compressor -> BlackHole.
// Runs in the audio render thread. No GUI. Tunable via environment variables.
//
// Build:  swiftc -O -framework AudioToolbox -framework CoreAudio -framework Accelerate \
//                 -framework Foundation micboost.swift -o micboost
//
// SIGUSR1 starts a noise-profile capture: the next NR_CAPTURE_SEC seconds of input are
// averaged into a magnitude spectrum, written to ~/.config/micboost/noise.profile, and
// subtracted from the signal from then on. Current state is mirrored to /tmp/micboost.status.
//
// Env (all optional):
//   RODE_NAME   substring of input device name   (default "Wireless MICRO")
//   OUT_NAME    substring of output device name   (default "BlackHole")
//   GAIN_DB     fixed pre-boost in dB             (default 12)
//   COMP        compressor on/off 1/0             (default 1)
//   THRESH_DB   compressor threshold in dB        (default -18)
//   RATIO       compressor ratio (x:1)            (default 4)
//   MAKEUP_DB   post-compressor makeup gain dB    (default 6)
//   ATTACK_MS   envelope attack in ms             (default 5)
//   RELEASE_MS  envelope release in ms            (default 150)
//   NR          noise suppression on/off 1/0      (default 0)
//   NR_ALPHA    over-subtraction factor           (default 2)
//   NR_FLOOR    residual noise floor, linear gain (default 0.06)
//   NR_SMOOTH   per-bin gain smoothing 0..1       (default 0.5)
//   NR_CAPTURE_SEC  noise capture length in sec   (default 6)
//   HPF_HZ      high-pass cutoff, 0 = off         (default 80)
//   LIMIT_MS    limiter look-ahead, 0 = hard clip (default 1.5)
//   LIMIT_RELEASE_MS  limiter release             (default 80)
//   CEIL_DB     output ceiling in dBFS            (default -0.5)

import Foundation
import AudioToolbox
import CoreAudio
import Accelerate
import Synchronization

// ---------- config ----------
// Precedence: environment variable  >  ~/.config/micboost/config  >  built-in default.
let CONFIG_PATH = (ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
                   ?? NSHomeDirectory() + "/.config") + "/micboost/config"

let fileCfg: [String: String] = {
    guard let text = try? String(contentsOfFile: CONFIG_PATH, encoding: .utf8) else { return [:] }
    var m = [String: String]()
    for raw in text.split(separator: "\n") {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") { continue }
        guard let eq = line.firstIndex(of: "=") else { continue }
        let k = line[..<eq].trimmingCharacters(in: .whitespaces)
        var v = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        if let hash = v.firstIndex(of: "#") { v = v[..<hash].trimmingCharacters(in: .whitespaces) } // trailing comment
        m[k] = v
    }
    return m
}()

func cfg(_ k: String) -> String? { ProcessInfo.processInfo.environment[k] ?? fileCfg[k] }
func envF(_ k: String, _ d: Float) -> Float { cfg(k).flatMap { Float($0) } ?? d }
func envS(_ k: String, _ d: String) -> String { cfg(k) ?? d }

let RODE_NAME  = envS("RODE_NAME", "Wireless MICRO")
let OUT_NAME   = envS("OUT_NAME",  "BlackHole")
let SR: Double = 48000
let CH: UInt32 = 2

let boost   = pow(10, envF("GAIN_DB", 12) / 20)
let compOn  = envF("COMP", 1) != 0
let thr     = pow(10, envF("THRESH_DB", -18) / 20)
let ratio   = max(1, envF("RATIO", 4))
let makeup  = pow(10, envF("MAKEUP_DB", 6) / 20)
let atkCoef = exp(-1.0 / Float(envF("ATTACK_MS", 5)  / 1000 * Float(SR)))
let relCoef = exp(-1.0 / Float(envF("RELEASE_MS", 150) / 1000 * Float(SR)))

let nrOn     = envF("NR", 0) != 0
let nrAlpha  = max(0, envF("NR_ALPHA", 2))
let nrFloor  = min(1, max(0, envF("NR_FLOOR", 0.06)))
let nrSmooth = min(0.99, max(0, envF("NR_SMOOTH", 0.5)))
let nrSecs   = max(1, envF("NR_CAPTURE_SEC", 6))

let hpfHz    = max(0, envF("HPF_HZ", 80))
let limMs    = max(0, envF("LIMIT_MS", 1.5))
let limRelMs = max(1, envF("LIMIT_RELEASE_MS", 80))
let ceiling  = pow(10, envF("CEIL_DB", -0.5) / 20)

let CONFIG_DIR   = (CONFIG_PATH as NSString).deletingLastPathComponent
let PROFILE_PATH = CONFIG_DIR + "/noise.profile"
let STATUS_PATH  = "/tmp/micboost.status"

func die(_ m: String) -> Never { FileHandle.standardError.write(("micboost: " + m + "\n").data(using: .utf8)!); exit(1) }
func check(_ s: OSStatus, _ what: String) { if s != noErr { die("\(what) failed (\(s))") } }

// ---------- lock-free SPSC ring (interleaved stereo frames) ----------
final class Ring {
    let cap: Int, mask: Int
    let buf: UnsafeMutablePointer<Float>
    let w = Atomic<Int>(0)   // frames written (monotonic)
    let r = Atomic<Int>(0)   // frames read    (monotonic)
    init(frames: Int) { cap = frames; mask = frames - 1; buf = .allocate(capacity: frames * 2); buf.initialize(repeating: 0, count: frames * 2) }

    // producer: copy `n` interleaved-stereo frames in, dropping on overflow
    func write(_ src: UnsafePointer<Float>, _ n: Int) {
        let wv = w.load(ordering: .relaxed), rv = r.load(ordering: .acquiring)
        let free = cap - (wv - rv)
        let m = min(n, free)
        for i in 0..<m {
            let d = ((wv + i) & mask) * 2
            buf[d]     = src[i * 2]
            buf[d + 1] = src[i * 2 + 1]
        }
        w.store(wv + m, ordering: .releasing)
    }

    // consumer: fill `n` frames, zero-padding on underflow
    func read(_ dst: UnsafeMutablePointer<Float>, _ n: Int) {
        let rv = r.load(ordering: .relaxed), wv = w.load(ordering: .acquiring)
        let avail = wv - rv
        let m = min(n, avail)
        for i in 0..<m {
            let s = ((rv + i) & mask) * 2
            dst[i * 2]     = buf[s]
            dst[i * 2 + 1] = buf[s + 1]
        }
        if m < n { for i in (m * 2)..<(n * 2) { dst[i] = 0 } }
        r.store(rv + m, ordering: .releasing)
    }
}

// ---------- device discovery ----------
func deviceIDs() -> [AudioDeviceID] {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
    return ids
}

func name(_ id: AudioDeviceID) -> String {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
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

func find(_ needle: String, input: Bool) -> AudioDeviceID? {
    deviceIDs().first { hasStreams($0, input: input) && name($0).lowercased().contains(needle.lowercased()) }
}

// ---------- high-pass filter (rumble, HVAC, desk thumps, plosives) ----------
// RBJ-cookbook 2nd-order Butterworth, transposed direct form II. First in the chain, so the
// noise profile and the compressor envelope both see a signal already free of low-end energy.
final class HPF {
    private var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0
    private var s1 = [Float](repeating: 0, count: 2), s2 = [Float](repeating: 0, count: 2)
    let enabled: Bool

    init(_ hz: Float) {
        enabled = hz > 0 && hz < Float(SR) / 2
        guard enabled else { return }
        let w0 = 2 * Float.pi * hz / Float(SR)
        let alpha = sin(w0) / (2 * 0.7071)          // Q = 1/sqrt(2)
        let a0 = 1 + alpha
        b0 = (1 + cos(w0)) / 2 / a0
        b1 = -(1 + cos(w0)) / a0
        b2 = b0
        a1 = -2 * cos(w0) / a0
        a2 = (1 - alpha) / a0
    }

    func process(_ il: UnsafeMutablePointer<Float>, _ n: Int) {
        guard enabled else { return }
        for c in 0..<2 {
            var z1 = s1[c], z2 = s2[c]
            for i in 0..<n {
                let x = il[i * 2 + c]
                let y = b0 * x + z1
                z1 = b1 * x - a1 * y + z2
                z2 = b2 * x - a2 * y
                il[i * 2 + c] = y
            }
            s1[c] = z1; s2[c] = z2
        }
    }
}

// ---------- compressor state (touched only by input render thread) ----------
final class Comp {
    var env: Float = 0
    func process(_ l: inout Float, _ r: inout Float) {
        l *= boost; r *= boost
        if compOn {
            let peak = max(abs(l), abs(r))
            let c = peak > env ? atkCoef : relCoef
            env = c * env + (1 - c) * peak
            var g: Float = 1
            if env > thr {
                let overDb = 20 * log10(env / thr)
                g = pow(10, (overDb / ratio - overDb) / 20)   // gain reduction
            }
            l *= g * makeup; r *= g * makeup
        }
    }
}

// ---------- look-ahead brickwall limiter ----------
// The signal is delayed by the look-ahead window while the gain reacts to the *undelayed* peak,
// so gain reduction is already in place when a transient arrives — no clipping, no overshoot.
// Gain is stereo-linked so the image doesn't wander. LIMIT_MS=0 falls back to a hard clip.
final class Limiter {
    let lookahead: Int
    private let dl: UnsafeMutablePointer<Float>
    private var idx = 0
    private var env: Float = 0, g: Float = 1
    private let atk: Float, rel: Float

    init() {
        lookahead = Int(limMs / 1000 * Float(SR))
        dl = .allocate(capacity: max(lookahead, 1) * 2)
        dl.initialize(repeating: 0, count: max(lookahead, 1) * 2)
        // reach the target gain in roughly the look-ahead window (~4 time constants)
        atk = lookahead > 0 ? exp(-4.0 / Float(lookahead)) : 0
        rel = exp(-1.0 / (limRelMs / 1000 * Float(SR)))
    }

    func process(_ il: UnsafeMutablePointer<Float>, _ n: Int) {
        guard lookahead > 0 else {
            for i in 0..<(n * 2) { il[i] = min(ceiling, max(-ceiling, il[i])) }
            return
        }
        for i in 0..<n {
            let l = il[i * 2], r = il[i * 2 + 1]
            env = max(max(abs(l), abs(r)), env * rel)          // instant attack, slow decay
            let target: Float = env > ceiling ? ceiling / env : 1
            let c = target < g ? atk : rel
            g = c * g + (1 - c) * target

            let dl0 = dl[idx * 2], dl1 = dl[idx * 2 + 1]
            dl[idx * 2] = l; dl[idx * 2 + 1] = r
            idx = (idx + 1) % lookahead
            il[i * 2]     = min(ceiling, max(-ceiling, dl0 * g))   // backstop; should never bite
            il[i * 2 + 1] = min(ceiling, max(-ceiling, dl1 * g))
        }
    }
}

// ---------- noise suppression ----------
// Spectral subtraction over a weighted overlap-add STFT (Hann, 75% overlap).
// A capture pass averages |X(f)| over a few seconds of silence; afterwards every frame is
// scaled per-bin by max(floor, sqrt(1 - (alpha*noise)^2 / |X|^2)).
//
// Mode transitions are driven by the audio thread alone: it polls `captureReq` (bumped by the
// SIGUSR1 handler), and publishes to `nrMode` / `captureDone` for the main thread to mirror
// into the status + profile files.
let captureReq  = Atomic<Int>(0)
let captureDone = Atomic<Int>(0)
let nrMode      = Atomic<Int>(0)   // 0 bypass, 1 capturing, 2 active

final class Denoiser {
    static let n = 1024, hop = 256, bins = 512     // 21 ms window, ~16 ms added latency
    private let log2n = vDSP_Length(10)
    private let setup = vDSP_create_fftsetup(10, FFTRadix(kFFTRadix2))!
    private let capTarget = Int((Double(nrSecs) * SR / Double(Denoiser.hop)).rounded())

    // Hann analysis + Hann synthesis at hop = n/4 sums to a constant 1.5.
    private let scale = 1.0 / (2 * Float(Denoiser.n) * 1.5)   // vDSP zrip round-trip gain is 2n

    private let win, winFrame, realp, imagp, mag, raw, gain, outIL: UnsafeMutablePointer<Float>
    private let frame, acc, gSm, noise, noisePow: [UnsafeMutablePointer<Float>]

    private var mode = 0, fill = 0, capFrames = 0, lastReq = 0

    private static func buf(_ count: Int, _ v: Float = 0) -> UnsafeMutablePointer<Float> {
        let p = UnsafeMutablePointer<Float>.allocate(capacity: count)
        p.initialize(repeating: v, count: count)
        return p
    }

    init(maxFrames: Int) {
        let n = Denoiser.n, bins = Denoiser.bins
        win = Denoiser.buf(n); winFrame = Denoiser.buf(n)
        realp = Denoiser.buf(bins); imagp = Denoiser.buf(bins)
        mag = Denoiser.buf(bins); raw = Denoiser.buf(bins); gain = Denoiser.buf(bins, 1)
        outIL = Denoiser.buf((maxFrames + n) * 2)
        frame = (0..<2).map { _ in Denoiser.buf(n) }
        acc = (0..<2).map { _ in Denoiser.buf(n) }
        gSm = (0..<2).map { _ in Denoiser.buf(bins, 1) }
        noise = (0..<2).map { _ in Denoiser.buf(bins) }
        noisePow = (0..<2).map { _ in Denoiser.buf(bins) }
        for i in 0..<n { win[i] = 0.5 * (1 - cos(2 * .pi * Float(i) / Float(n))) }

        if nrOn, let p = loadProfile() {
            for c in 0..<2 { for k in 0..<bins { noise[c][k] = p[c][k] } }
            mode = 2
        }
        nrMode.store(mode, ordering: .releasing)
    }

    // main thread reads this once `captureDone` fires; the audio thread is done writing by then
    func profileSnapshot() -> [[Float]] {
        (0..<2).map { c in (0..<Denoiser.bins).map { noise[c][$0] } }
    }

    // Consume `frames` interleaved-stereo frames, emit whole hops. Returns the emitted buffer.
    func process(_ il: UnsafeMutablePointer<Float>, _ frames: Int) -> (UnsafeMutablePointer<Float>, Int) {
        let req = captureReq.load(ordering: .acquiring)
        if req != lastReq {
            lastReq = req
            for c in 0..<2 { noisePow[c].update(repeating: 0, count: Denoiser.bins) }
            capFrames = 0
            mode = 1
            nrMode.store(1, ordering: .releasing)
        }
        if mode == 0 { return (il, frames) }

        let n = Denoiser.n, hop = Denoiser.hop
        var produced = 0, i = 0
        while i < frames {
            let take = min(hop - fill, frames - i)
            for c in 0..<2 {
                let f = frame[c] + (n - hop + fill)
                for k in 0..<take { f[k] = il[(i + k) * 2 + c] }
            }
            fill += take; i += take
            guard fill == hop else { continue }
            fill = 0

            for c in 0..<2 { transform(c) }
            if mode == 1 {
                capFrames += 1
                if capFrames >= capTarget { finishCapture() }
            }
            for c in 0..<2 {
                let a = acc[c]
                for k in 0..<hop { outIL[(produced + k) * 2 + c] = a[k] }
                memmove(frame[c], frame[c] + hop, (n - hop) * MemoryLayout<Float>.size)
                memmove(a, a + hop, (n - hop) * MemoryLayout<Float>.size)
                (a + n - hop).update(repeating: 0, count: hop)
            }
            produced += hop
        }
        return (outIL, produced)
    }

    private func transform(_ c: Int) {
        let n = Denoiser.n, bins = Denoiser.bins
        var split = DSPSplitComplex(realp: realp, imagp: imagp)
        vDSP_vmul(frame[c], 1, win, 1, winFrame, 1, vDSP_Length(n))
        winFrame.withMemoryRebound(to: DSPComplex.self, capacity: bins) {
            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(bins))
        }
        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
        imagp[0] = 0                       // imagp[0] packs Nyquist; drop it, keep DC in realp[0]
        vDSP_zvabs(&split, 1, mag, 1, vDSP_Length(bins))

        computeGain(c)

        vDSP_vmul(realp, 1, gain, 1, realp, 1, vDSP_Length(bins))
        vDSP_vmul(imagp, 1, gain, 1, imagp, 1, vDSP_Length(bins))
        imagp[0] = 0
        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Inverse))
        winFrame.withMemoryRebound(to: DSPComplex.self, capacity: bins) {
            vDSP_ztoc(&split, 1, $0, 2, vDSP_Length(bins))
        }
        vDSP_vmul(winFrame, 1, win, 1, winFrame, 1, vDSP_Length(n))
        var s = scale
        vDSP_vsmul(winFrame, 1, &s, winFrame, 1, vDSP_Length(n))
        vDSP_vadd(acc[c], 1, winFrame, 1, acc[c], 1, vDSP_Length(n))
    }

    private func computeGain(_ c: Int) {
        let bins = Denoiser.bins
        if mode == 1 {
            let p = noisePow[c]
            for k in 0..<bins { p[k] += mag[k] * mag[k] }
            for k in 0..<bins { gain[k] = 1 }
            return
        }
        let nz = noise[c], g = gSm[c]
        for k in 0..<bins {
            let power = mag[k] * mag[k]
            let np = (nrAlpha * nz[k]) * (nrAlpha * nz[k])
            raw[k] = power > np ? sqrt((power - np) / power) : 0
        }
        // 3-bin blur then temporal smoothing — both suppress the "musical noise" warble that
        // per-bin subtraction produces on its own.
        for k in 0..<bins {
            let blurred = (raw[max(k - 1, 0)] + raw[k] + raw[min(k + 1, bins - 1)]) / 3
            g[k] = nrSmooth * g[k] + (1 - nrSmooth) * max(blurred, nrFloor)
            gain[k] = g[k]
        }
    }

    private func finishCapture() {
        for c in 0..<2 {
            for k in 0..<Denoiser.bins { noise[c][k] = sqrt(noisePow[c][k] / Float(capFrames)) }
        }
        mode = 2
        nrMode.store(2, ordering: .releasing)
        captureDone.wrappingAdd(1, ordering: .releasing)
    }
}

// ---------- noise profile file ----------
func loadProfile() -> [[Float]]? {
    guard let text = try? String(contentsOfFile: PROFILE_PATH, encoding: .utf8) else { return nil }
    var out = [[Float]](repeating: [], count: 2)
    for line in text.split(separator: "\n") {
        for c in 0..<2 where line.hasPrefix("ch\(c)=") {
            out[c] = line.dropFirst(4).split(separator: ",").compactMap { Float($0) }
        }
    }
    guard out.allSatisfy({ $0.count == Denoiser.bins }) else { return nil }
    return out
}

func saveProfile(_ p: [[Float]]) {
    var s = "# micboost noise profile — mean magnitude spectrum, one line per channel\n"
    s += "sr=\(Int(SR))\nn=\(Denoiser.n)\n"
    for c in 0..<2 {
        s += "ch\(c)=" + p[c].map { String(format: "%.6g", $0) }.joined(separator: ",") + "\n"
    }
    try? FileManager.default.createDirectory(atPath: CONFIG_DIR, withIntermediateDirectories: true)
    try? s.write(toFile: PROFILE_PATH, atomically: true, encoding: .utf8)
}

func writeStatus() {
    let name = ["off", "capturing", "active"][nrMode.load(ordering: .acquiring)]
    try? "nr=\(name)\n".write(toFile: STATUS_PATH, atomically: true, encoding: .utf8)
}

// ---------- bridge ----------
final class Bridge {
    let ring = Ring(frames: 16384)
    let hpf = HPF(hpfHz)
    let comp = Comp()
    let lim = Limiter()
    let nr = Denoiser(maxFrames: 8192)
    var inUnit: AudioUnit!
    var outUnit: AudioUnit!
    let maxFrames = 8192
    let scratch: UnsafeMutablePointer<Float>          // interleaved stereo
    let abl: UnsafeMutableAudioBufferListPointer

    init() {
        scratch = .allocate(capacity: maxFrames * 2)
        abl = AudioBufferList.allocate(maximumBuffers: 1)
        abl[0] = AudioBuffer(mNumberChannels: CH, mDataByteSize: 0, mData: UnsafeMutableRawPointer(scratch))
    }

    func asbd() -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(mSampleRate: SR, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4 * CH, mFramesPerPacket: 1, mBytesPerFrame: 4 * CH,
            mChannelsPerFrame: CH, mBitsPerChannel: 32, mReserved: 0)
    }

    func makeUnit(device: AudioDeviceID, isInput: Bool) -> AudioUnit {
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput, componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        let comp = AudioComponentFindNext(nil, &desc)!
        var unit: AudioUnit?
        check(AudioComponentInstanceNew(comp, &unit), "AudioComponentInstanceNew")
        let u = unit!
        var one: UInt32 = 1, zero: UInt32 = 0
        if isInput {
            check(AudioUnitSetProperty(u, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input,  1, &one,  4), "enable in")
            check(AudioUnitSetProperty(u, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &zero, 4), "disable out")
        } else {
            check(AudioUnitSetProperty(u, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &one,  4), "enable out")
            check(AudioUnitSetProperty(u, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input,  1, &zero, 4), "disable in")
        }
        var dev = device
        check(AudioUnitSetProperty(u, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, 4), "set device")
        var fmt = asbd()
        let sz = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        if isInput {
            check(AudioUnitSetProperty(u, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &fmt, sz), "in fmt")
        } else {
            check(AudioUnitSetProperty(u, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &fmt, sz), "out fmt")
        }
        return u
    }

    func start(rode: AudioDeviceID, out: AudioDeviceID) {
        inUnit  = makeUnit(device: rode, isInput: true)
        outUnit = makeUnit(device: out,  isInput: false)
        let ref = Unmanaged.passUnretained(self).toOpaque()

        var icb = AURenderCallbackStruct(inputProc: { rc, flags, ts, bus, n, _ in
            Unmanaged<Bridge>.fromOpaque(rc).takeUnretainedValue().pullInput(flags, ts, bus, n)
        }, inputProcRefCon: ref)
        check(AudioUnitSetProperty(inUnit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &icb, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "set input cb")

        var ocb = AURenderCallbackStruct(inputProc: { rc, _, _, _, n, io in
            Unmanaged<Bridge>.fromOpaque(rc).takeUnretainedValue().pushOutput(n, io)
        }, inputProcRefCon: ref)
        check(AudioUnitSetProperty(outUnit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &ocb, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "set output cb")

        check(AudioUnitInitialize(inUnit),  "init in")
        check(AudioUnitInitialize(outUnit), "init out")
        check(AudioOutputUnitStart(inUnit),  "start in")
        check(AudioOutputUnitStart(outUnit), "start out")
    }

    func pullInput(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                   _ ts: UnsafePointer<AudioTimeStamp>, _ bus: UInt32, _ n: UInt32) -> OSStatus {
        let frames = Int(min(n, UInt32(maxFrames)))
        abl[0].mDataByteSize = UInt32(frames) * 4 * CH
        let s = AudioUnitRender(inUnit, flags, ts, bus, n, abl.unsafeMutablePointer)
        if s != noErr { return s }
        hpf.process(scratch, frames)                     // rumble out before anything else sees it
        let (buf, count) = nr.process(scratch, frames)   // denoise, then boost the clean signal
        for i in 0..<count { comp.process(&buf[i * 2], &buf[i * 2 + 1]) }
        lim.process(buf, count)
        ring.write(buf, count)
        return noErr
    }

    func pushOutput(_ n: UInt32, _ io: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
        guard let io = io else { return noErr }
        let list = UnsafeMutableAudioBufferListPointer(io)
        guard let data = list[0].mData else { return noErr }
        ring.read(data.assumingMemoryBound(to: Float.self), Int(n))
        return noErr
    }
}

// ---------- main ----------
setbuf(stdout, nil)
var rode: AudioDeviceID?, out: AudioDeviceID?
for _ in 0..<40 {                       // wait up to ~2min for both devices to appear
    rode = find(RODE_NAME, input: true)
    out  = find(OUT_NAME,  input: false)
    if rode != nil && out != nil { break }
    Thread.sleep(forTimeInterval: 3)
}
guard let r = rode else { die("input device matching \"\(RODE_NAME)\" not found") }
guard let o = out  else { die("output device matching \"\(OUT_NAME)\" not found") }
let bridge = Bridge()
let nrState = ["off", "capturing", "active"][nrMode.load(ordering: .acquiring)]
print("micboost: \(name(r)) -> \(name(o))  gain=\(envF("GAIN_DB",12))dB comp=\(compOn) nr=\(nrState)")
if nrOn && nrState == "off" { print("micboost: NR=1 but no noise profile — run `micboostctl nr capture`") }
bridge.start(rode: r, out: o)
writeStatus()

// A USB mic can drop off the bus and come back milliseconds later as a different AudioObjectID.
// The units go on rendering from the dead one — silence, or worse, a buzz that the far end hears
// instead of you. There is nothing to salvage in place, so leave and let launchd start us again on
// whatever the devices are now; the wait loop above picks them up as they reappear.
let rName = name(r), oName = name(o)
var devices = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                         mScope: kAudioObjectPropertyScopeGlobal,
                                         mElement: kAudioObjectPropertyElementMain)
AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &devices, .main) { _, _ in
    let live = Set(deviceIDs())
    guard !live.contains(r) || !live.contains(o) else { return }
    print("micboost: \(live.contains(r) ? oName : rName) went away — restarting")
    exit(0)
}

signal(SIGUSR1, SIG_IGN)
let sigSrc = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
sigSrc.setEventHandler { captureReq.wrappingAdd(1, ordering: .releasing) }
sigSrc.resume()

// Poll for audio-thread state changes and mirror them to disk (no file I/O on the render thread).
var lastMode = nrMode.load(ordering: .acquiring), lastDone = 0
let poll = DispatchSource.makeTimerSource(queue: .main)
poll.schedule(deadline: .now() + 0.2, repeating: 0.2)
poll.setEventHandler {
    let done = captureDone.load(ordering: .acquiring)
    if done != lastDone {
        lastDone = done
        saveProfile(bridge.nr.profileSnapshot())
        print("micboost: noise profile captured -> \(PROFILE_PATH)")
    }
    let mode = nrMode.load(ordering: .acquiring)
    if mode != lastMode { lastMode = mode; writeStatus() }
}
poll.resume()

dispatchMain()
