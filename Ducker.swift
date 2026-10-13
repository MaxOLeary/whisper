import CoreAudio
import AudioToolbox
import Foundation

/// Turns the Mac's output down while you dictate, so music from the speakers
/// doesn't land in the take. `musicDuringTake` in config.json: "lower" drops
/// the volume to 30%, "mute" mutes, anything else leaves it alone. Wired
/// headphones are skipped (the mic can't hear them). Only what we changed is
/// put back, on the same device we changed it on.
enum Ducker {
    static let lowerFactor: Float32 = 0.3

    /// What the output looked like before we touched it. Kept in UserDefaults
    /// too, so a crash mid-take gets fixed on the next launch.
    private struct Saved: Codable {
        var uid: String
        var volume: Float32?   // set when we lowered it
        var unmute: Bool       // true when we muted it
    }
    private static let key = "duckerSaved"
    private static var saved: Saved?

    static func duck(_ mode: String) {
        guard saved == nil, mode == "lower" || mode == "mute",
              let dev = defaultOutput(), !isWiredHeadphones(dev), let uid = uid(of: dev) else { return }
        if mute(of: dev) == true { return }   // already silent, nothing to do
        var s = Saved(uid: uid, volume: nil, unmute: false)
        if mode == "mute", setMute(dev, true) {
            s.unmute = true
        } else if let v = volume(of: dev), setVolume(dev, mode == "mute" ? 0 : v * lowerFactor) {
            s.volume = v   // "lower", or "mute" on a device with no mute switch
        } else {
            return         // no volume control (some HDMI / USB outputs)
        }
        saved = s
        if let data = try? JSONEncoder().encode(s) { UserDefaults.standard.set(data, forKey: key) }
    }

    static func restore() {
        let s = saved ?? UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
        saved = nil
        UserDefaults.standard.removeObject(forKey: key)
        guard let s, let dev = device(uid: s.uid) else { return }
        if let v = s.volume { _ = setVolume(dev, v) }
        if s.unmute { _ = setMute(dev, false) }
    }

    // MARK: Core Audio

    private static func addr(_ sel: AudioObjectPropertySelector,
                             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func get<T: BitwiseCopyable>(_ obj: AudioObjectID, _ a: AudioObjectPropertyAddress, _ initial: T) -> T? {
        var a = a, v = initial, size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &v) == noErr ? v : nil
    }

    private static func set<T: BitwiseCopyable>(_ obj: AudioObjectID, _ a: AudioObjectPropertyAddress, _ value: T) -> Bool {
        var a = a, v = value
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(obj, &a), AudioObjectIsPropertySettable(obj, &a, &settable) == noErr,
              settable.boolValue else { return false }
        return AudioObjectSetPropertyData(obj, &a, 0, nil, UInt32(MemoryLayout<T>.size), &v) == noErr
    }

    private static func defaultOutput() -> AudioDeviceID? {
        get(AudioObjectID(kAudioObjectSystemObject), addr(kAudioHardwarePropertyDefaultOutputDevice), AudioDeviceID(0))
            .flatMap { $0 == 0 ? nil : $0 }
    }

    /// The headphone jack: built-in transport, "hdpn" data source. Bluetooth
    /// and USB count as speakers on purpose; they could be either.
    private static func isWiredHeadphones(_ dev: AudioDeviceID) -> Bool {
        let hdpn: UInt32 = 0x6864_706E   // 'hdpn'
        return get(dev, addr(kAudioDevicePropertyTransportType), UInt32(0)) == kAudioDeviceTransportTypeBuiltIn
            && get(dev, addr(kAudioDevicePropertyDataSource, kAudioObjectPropertyScopeOutput), UInt32(0)) == hdpn
    }

    private static func uid(of dev: AudioDeviceID) -> String? {
        var a = addr(kAudioDevicePropertyDeviceUID)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var out: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &out) == noErr, let out else { return nil }
        return out.takeRetainedValue() as String
    }

    private static func device(uid: String) -> AudioDeviceID? {
        var a = addr(kAudioHardwarePropertyTranslateUIDToDevice)
        var cf = uid as CFString
        var dev = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let st = withUnsafeMutablePointer(to: &cf) { p in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a,
                                       UInt32(MemoryLayout<CFString>.size), p, &size, &dev)
        }
        return st == noErr && dev != 0 ? dev : nil
    }

    private static let volumeAddr = addr(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioObjectPropertyScopeOutput)
    private static let muteAddr = addr(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput)

    private static func volume(of dev: AudioDeviceID) -> Float32? { get(dev, volumeAddr, Float32(0)) }
    private static func setVolume(_ dev: AudioDeviceID, _ v: Float32) -> Bool { set(dev, volumeAddr, v) }
    private static func mute(of dev: AudioDeviceID) -> Bool? { get(dev, muteAddr, UInt32(0)).map { $0 != 0 } }
    private static func setMute(_ dev: AudioDeviceID, _ on: Bool) -> Bool { set(dev, muteAddr, UInt32(on ? 1 : 0)) }
}
