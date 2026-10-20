import CoreAudio
import Foundation

/// Sistemde o an bağlı olan bir çıkış cihazı.
struct AudioDevice: Hashable {
    let id: AudioDeviceID
    let uid: String        // Kalıcı kimlik: cihaz çıkarılıp takılsa da aynı kalır
    let name: String
    let transport: UInt32
    var symbol: String { DeviceIcon.symbol(name: name, transport: transport) }
}

/// CoreAudio ile konuşan küçük yardımcılar.
enum CA {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    /// Çıkışı olan tüm cihazlar (hoparlör, kulaklık, HDMI, AirPlay...)
    static func outputDevices() -> [AudioDevice] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.compactMap { id in
            guard hasOutput(id),
                  let uid = string(id, kAudioDevicePropertyDeviceUID),
                  let name = string(id, kAudioObjectPropertyName) else { return nil }
            if uid.hasPrefix("CADefaultDeviceAggregate") { return nil } // sistemin gizli cihazı
            return AudioDevice(id: id, uid: uid, name: name,
                               transport: uint32(id, kAudioDevicePropertyTransportType) ?? 0)
        }
    }

    static func hasOutput(_ id: AudioDeviceID) -> Bool {
        var addr = address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr && size > 0
    }

    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func uint32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var value: UInt32 = 0
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    static func defaultOutput() -> AudioDeviceID? {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var id = AudioDeviceID(0)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return id
    }

    /// Varsayılan çıkışı değiştirir. Sistem sesleri (uyarı sesleri) de aynı cihaza taşınır.
    @discardableResult
    static func setDefaultOutput(_ id: AudioDeviceID) -> Bool {
        var device = id
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        let ok = AudioObjectSetPropertyData(system, &addr, 0, nil, size, &device) == noErr
        var sysAddr = address(kAudioHardwarePropertyDefaultSystemOutputDevice)
        _ = AudioObjectSetPropertyData(system, &sysAddr, 0, nil, size, &device)
        return ok
    }

    /// Sistem nesnesindeki bir özellik değişince haber ver (ana kuyrukta).
    static func listen(_ selector: AudioObjectPropertySelector, _ block: @escaping () -> Void) {
        var addr = address(selector)
        _ = AudioObjectAddPropertyListenerBlock(system, &addr, DispatchQueue.main) { _, _ in block() }
    }
}

/// Cihaz adına / bağlantı türüne göre SF Symbol seçer.
enum DeviceIcon {
    static func symbol(name: String, transport: UInt32) -> String {
        let n = name.lowercased()
        if n.contains("airpods max") { return "airpodsmax" }
        if n.contains("airpods pro") { return "airpodspro" }
        if n.contains("airpods") { return "airpods" }
        let headphoneWords = ["headphone", "kulaklık", "kulaklik", "headset", "buds", "beats", "wh-", "wf-"]
        if headphoneWords.contains(where: { n.contains($0) }) { return "headphones" }

        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return "headphones"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
            return "tv"
        case kAudioDeviceTransportTypeAirPlay:
            return "airplayaudio"
        case kAudioDeviceTransportTypeUSB:
            return "hifispeaker.fill"
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate:
            return "waveform"
        default:
            return "speaker.wave.2.fill"
        }
    }
}
