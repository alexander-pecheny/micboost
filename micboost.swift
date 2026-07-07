// micboost — headless Core Audio bridge: RODE -> gain + compressor -> BlackHole.
// Runs in the audio render thread. No GUI. Tunable via environment variables.
//
// Build:  swiftc -O -framework AudioToolbox -framework CoreAudio -framework Foundation \
//                 micboost.swift -o micboost
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

import Foundation
import AudioToolbox
import CoreAudio
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
        l = min(0.999, max(-0.999, l)); r = min(0.999, max(-0.999, r)) // safety limiter
    }
}

// ---------- bridge ----------
final class Bridge {
    let ring = Ring(frames: 16384)
    let comp = Comp()
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
        for i in 0..<frames { comp.process(&scratch[i * 2], &scratch[i * 2 + 1]) }
        ring.write(scratch, frames)
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
print("micboost: \(name(r)) -> \(name(o))  gain=\(envF("GAIN_DB",12))dB comp=\(compOn)")
let bridge = Bridge()
bridge.start(rode: r, out: o)
dispatchMain()
