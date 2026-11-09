import AppKit
import AVFoundation

/// How a mic open ended. `.timedOut` means CoreAudio never returned; the
/// caller has to drop this instance, because that call cannot be cancelled.
enum MicOpen { case ok, failed, timedOut }

/// One mic tap: 16 kHz mono float into RAM, plus RMS for the waveform card.
final class Capture {
    static let sampleRate: Double = 16_000
    /// `AVAudioEngine.inputNode` asks CoreAudio for the hardware format, and
    /// that call blocks forever when coreaudiod is wedged (DisplayLink USB
    /// audio does this). Longer than a slow USB mic, short of a frozen app.
    static let openTimeout: TimeInterval = 2

    var onLevel: ((CGFloat) -> Void)?
    /// New 16 kHz samples, called off the audio thread's tap. Copy is already ours.
    var onChunk: (([Float]) -> Void)?

    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private let lock = NSLock()
    private var live = false
    /// Set when the open is taking too long or the take was cancelled.
    /// The engine queue is the only thread that touches `engine`.
    private var abandoned = false
    private let engineQ = DispatchQueue(label: "whisper.capture.engine")

    /// Opens the mic off the caller's thread. `done` runs on the main queue
    /// exactly once. On `.timedOut` this instance is dead: CoreAudio is still
    /// inside it, and calling in again would queue behind that call.
    func open(deviceName: String, timeout: TimeInterval = Capture.openTimeout,
              done: @escaping (MicOpen) -> Void) {
        lock.lock()
        abandoned = false
        lock.unlock()
        let gate = OpenGate()
        engineQ.async { [weak self] in
            guard let self else { return }
            let ok = self.start(deviceName: deviceName)
            if self.isAbandoned || !gate.claim() {
                self.teardownNow()
                return
            }
            let result: MicOpen = ok ? .ok : .failed
            DispatchQueue.main.async { done(result) }
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, gate.claim() else { return }
            self.abandon()
            DispatchQueue.main.async { done(.timedOut) }
        }
    }

    /// The in-flight open should tear the engine down and report nothing.
    func abandon() {
        lock.lock()
        abandoned = true
        lock.unlock()
    }

    private var isAbandoned: Bool {
        lock.lock()
        defer { lock.unlock() }
        return abandoned
    }

    /// `deviceName` is the mic's localizedName from config.json; empty, "0", or
    /// an unknown name means the system default input. Runs on `engineQ`.
    /// The `inputNode` line is the one that blocks inside CoreAudio.
    private func start(deviceName: String = "") -> Bool {
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        samples.reserveCapacity(Int(Capture.sampleRate * 30))
        live = true
        lock.unlock()
        if isAbandoned { return false }

        let e = AVAudioEngine()
        let input = e.inputNode
        if isAbandoned { return false }
        if let id = Capture.deviceID(named: deviceName), let unit = input.audioUnit {
            var dev = id
            let st = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                          &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
            if st != noErr { NSLog("Whisper capture: could not select \"\(deviceName)\" (\(st)); using default") }
        }
        // inputFormat, not outputFormat: after a device switch outputFormat
        // keeps the old device's rate (44.1k while music plays), the tap
        // fails, and the take records silence.
        let hw = input.inputFormat(forBus: 0)
        guard hw.channelCount > 0, hw.sampleRate > 0,
              let dst = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Capture.sampleRate,
                                      channels: 1, interleaved: false),
              let conv = AVAudioConverter(from: hw, to: dst) else { return false }
        if isAbandoned { return false }
        converter = conv
        let ratio = Capture.sampleRate / hw.sampleRate
        input.installTap(onBus: 0, bufferSize: 2048, format: hw) { [weak self] buf, _ in
            guard let self else { return }
            if let ch = buf.floatChannelData?[0] {
                let n = Int(buf.frameLength)
                var sum: Float = 0
                for i in 0..<n { sum += ch[i] * ch[i] }
                let rms = sqrt(sum / Float(max(n, 1)))
                let db = 20 * log10(max(rms, 1e-6))
                let level = min(1, max(0, (db + 50) / 40))   // -50 dB..-10 dB -> 0..1
                DispatchQueue.main.async { self.onLevel?(CGFloat(level)) }
            }
            guard let conv = self.converter else { return }
            let cap = AVAudioFrameCount(Double(buf.frameLength) * ratio + 32)
            guard let out = AVAudioPCMBuffer(pcmFormat: dst, frameCapacity: cap) else { return }
            var err: NSError?
            var got = false
            conv.convert(to: out, error: &err) { _, status in
                if got { status.pointee = .noDataNow; return nil }
                got = true
                status.pointee = .haveData
                return buf
            }
            if err != nil { return }
            guard let dstCh = out.floatChannelData?[0], out.frameLength > 0 else { return }
            let n = Int(out.frameLength)
            let chunk = Array(UnsafeBufferPointer(start: dstCh, count: n))
            self.lock.lock()
            self.samples.append(contentsOf: chunk)
            let running = self.live
            self.lock.unlock()
            if running { self.onChunk?(chunk) }
        }
        if isAbandoned {
            input.removeTap(onBus: 0)
            converter = nil
            return false
        }
        do { try e.start(); engine = e; return true } catch {
            NSLog("Whisper capture: \(error)")
            input.removeTap(onBus: 0)
            converter = nil
            return false
        }
    }

    /// Stops the tap and returns the samples taken so far. Does not wait on
    /// CoreAudio: tearing the engine down is queued, and a wedged HAL must
    /// not freeze whoever called this.
    @discardableResult
    func stop() -> [Float] {
        lock.lock()
        live = false
        let s = samples
        samples.removeAll(keepingCapacity: true)
        lock.unlock()
        onChunk = nil
        engineQ.async { [weak self] in self?.teardownNow() }
        return s
    }

    private func teardownNow() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        converter = nil
    }

    /// Every audio input macOS knows about, in system order.
    static func inputDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external],
                                         mediaType: .audio, position: .unspecified).devices
    }

    /// The input config.json names, or nil for "use the system default".
    /// Owns the one matching rule: trimmed, exact localizedName; "" and the
    /// legacy "0" mean default.
    static func device(named name: String) -> AVCaptureDevice? {
        let wanted = name.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty, wanted != "0" else { return nil }
        let dev = inputDevices().first { $0.localizedName == wanted }
        if dev == nil { NSLog("Whisper capture: no input named \"\(wanted)\"; using the system default") }
        return dev
    }

    /// CoreAudio id for the input whose name matches, or nil for "use the default".
    static func deviceID(named name: String) -> AudioDeviceID? {
        guard let dev = device(named: name) else { return nil }
        var uid = dev.uniqueID as CFString
        var id = AudioDeviceID(0)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let st = withUnsafeMutablePointer(to: &uid) { uidPtr in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                       UInt32(MemoryLayout<CFString>.size), uidPtr, &size, &id)
        }
        return st == noErr && id != 0 ? id : nil
    }

}

/// First caller wins. The mic open and its timeout both try.
private final class OpenGate {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
