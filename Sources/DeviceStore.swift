import Combine
import CoreAudio
import Foundation

/// Daha önce görülmüş bir cihaz. Cihaz çıkarılsa bile burada kalır.
struct KnownDevice: Codable, Hashable {
    var uid: String
    var name: String
    var symbol: String
}

/// Panelde / menüde gösterilen satır.
struct DeviceRow: Identifiable, Hashable {
    let id: String            // uid
    let name: String
    let symbol: String
    let isConnected: Bool
    let isCurrent: Bool
    let inCycle: Bool
    let inPanel: Bool
}

enum HotkeyChoice: String {
    case cmdShift   // ⌘ basılıyken ⇧'ye dokun
    case cmdCaps    // ⌘ + Caps Lock

    var symbol: String { self == .cmdShift ? "⌘⇧" : "⌘⇪" }
    var stepKey: String { self == .cmdShift ? "⇧" : "⇪" }
}

enum HotkeyMode: String {
    case cycle   // ⌘⇪ → doğrudan sıradaki cihaza geç
    case panel   // ⌘⇪ → cam paneli aç, cihazları alt alta göster
}

final class DeviceStore: ObservableObject {
    static let shared = DeviceStore()

    /// Tüm bilinen cihazlar (bağlılar önce)
    @Published private(set) var rows: [DeviceRow] = []
    /// Panelde gösterilecekler (ayara göre filtrelenmiş)
    @Published private(set) var panelRows: [DeviceRow] = []
    /// Sesin gerçekten gittiği cihaz (eqMac aradaysa onun arkasındaki cihaz)
    @Published private(set) var current: AudioDevice?
    /// eqMac gibi bir aracı sanal cihaz şu an varsayılan çıkış mı?
    @Published private(set) var passthroughActive = false
    /// Uygulamaya göre ses cihazı: bundle kimliği → cihaz UID
    @Published private(set) var appAudio: [String: String] = [:]

    private(set) var connected: [AudioDevice] = []

    private var known: [KnownDevice]
    private var cycle: Set<String>
    private var panelSet: Set<String>
    private let defaults = UserDefaults.standard

    // MARK: Ayarlar

    var mode: HotkeyMode {
        get { HotkeyMode(rawValue: defaults.string(forKey: "mode") ?? "") ?? .cycle }
        set { defaults.set(newValue.rawValue, forKey: "mode") }
    }
    var showHUD: Bool {
        get { defaults.object(forKey: "showHUD") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "showHUD") }
    }
    var hotkeyChoice: HotkeyChoice {
        get { HotkeyChoice(rawValue: defaults.string(forKey: "hotkeyChoice") ?? "") ?? .cmdShift }
        set { defaults.set(newValue.rawValue, forKey: "hotkeyChoice") }
    }
    /// Liste modunda ⌘ bırakılınca vurgulu cihazı seç (⌘+Tab gibi).
    var selectOnRelease: Bool {
        get { defaults.object(forKey: "selectOnRelease") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "selectOnRelease") }
    }
    /// ⌘⇪ basınca Caps Lock'un açık kalmasını engelle.
    var keepCapsLock: Bool {
        get { defaults.object(forKey: "keepCapsLock") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "keepCapsLock") }
    }
    /// Bir uygulamaya geçince ona atanmış ses cihazına otomatik geç
    var autoSwitchByApp: Bool {
        get { defaults.object(forKey: "autoSwitchByApp") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "autoSwitchByApp") }
    }
    /// Panel: true → tüm cihazlar, false → sadece seçilenler
    var panelShowAll: Bool {
        get { defaults.object(forKey: "panelShowAll") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "panelShowAll"); rebuildRows() }
    }
    /// En son seçtiğimiz gerçek cihaz (eqMac varken "şu an nerede" sorusunun cevabı)
    private var lastSelectedUID: String? {
        get { defaults.string(forKey: "lastSelectedUID") }
        set { defaults.set(newValue, forKey: "lastSelectedUID") }
    }

    /// eqMac vb. ses yönlendiren sanal cihazlar: listelerde gösterilmez.
    static func isPassthrough(uid: String, name: String) -> Bool {
        let s = (uid + " " + name).lowercased()
        return s.contains("eqmac")
    }

    // MARK: Yaşam döngüsü

    private init() {
        if let data = defaults.data(forKey: "knownDevices"),
           let list = try? JSONDecoder().decode([KnownDevice].self, from: data) {
            known = list.filter { !DeviceStore.isPassthrough(uid: $0.uid, name: $0.name) }
        } else {
            known = []
        }
        cycle = Set(defaults.stringArray(forKey: "cycleUIDs") ?? [])
        panelSet = Set(defaults.stringArray(forKey: "panelUIDs") ?? [])
        appAudio = defaults.dictionary(forKey: "appAudio") as? [String: String] ?? [:]
        refresh()
        CA.listen(kAudioHardwarePropertyDevices) { [weak self] in self?.refresh() }
        CA.listen(kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in self?.refresh() }
    }

    /// Bağlı cihazları okur, yenileri öğrenir, listeyi günceller.
    func refresh() {
        let all = CA.outputDevices()
        connected = all.filter { !Self.isPassthrough(uid: $0.uid, name: $0.name) }
        let connectedUIDs = Set(connected.map(\.uid))
        var changed = false

        for dev in connected {
            if let i = known.firstIndex(where: { $0.uid == dev.uid }) {
                if known[i].name != dev.name || known[i].symbol != dev.symbol {
                    known[i].name = dev.name
                    known[i].symbol = dev.symbol
                    changed = true
                }
            } else if known.filter({ $0.name == dev.name }).count == 1,
                      let i = known.firstIndex(where: { k in k.name == dev.name && !connectedUIDs.contains(k.uid) }) {
                // Yalnızca bu isimde tek bir kayıtlı cihaz varsa taşı (aynı isimli başka cihaza sessizce geçmesin)
                // Aynı cihaz farklı porta takılmış (USB'de UID değişebilir): seçimleri taşı
                let old = known[i].uid
                known[i].uid = dev.uid
                if cycle.remove(old) != nil { cycle.insert(dev.uid) }
                if panelSet.remove(old) != nil { panelSet.insert(dev.uid) }
                if lastSelectedUID == old { lastSelectedUID = dev.uid }
                for (bid, uid) in appAudio where uid == old { appAudio[bid] = dev.uid }
                changed = true
            } else {
                known.append(KnownDevice(uid: dev.uid, name: dev.name, symbol: dev.symbol))
                changed = true
            }
        }
        if changed { save() }

        // Şu anki cihaz
        let defaultID = CA.defaultOutput()
        let defaultDev = all.first { $0.id == defaultID }
        if let d = defaultDev, !Self.isPassthrough(uid: d.uid, name: d.name) {
            passthroughActive = false
            current = d
            if lastSelectedUID != d.uid { lastSelectedUID = d.uid }
        } else {
            // eqMac varsayılan çıkışı kendine alıyor: sesin gittiği yer en son seçtiğimiz cihaz
            passthroughActive = defaultDev != nil
            current = connected.first { $0.uid == lastSelectedUID }
        }
        rebuildRows()
    }

    private func rebuildRows() {
        let all = known.map { k -> DeviceRow in
            DeviceRow(id: k.uid, name: k.name, symbol: k.symbol,
                      isConnected: connected.contains { $0.uid == k.uid },
                      isCurrent: current?.uid == k.uid,
                      inCycle: cycle.contains(k.uid),
                      inPanel: panelSet.contains(k.uid))
        }
        rows = all.filter(\.isConnected) + all.filter { !$0.isConnected }
        if panelShowAll || panelSet.isEmpty {
            panelRows = rows
        } else {
            panelRows = rows.filter { panelSet.contains($0.id) }
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(known) { defaults.set(data, forKey: "knownDevices") }
        defaults.set(Array(cycle), forKey: "cycleUIDs")
        defaults.set(Array(panelSet), forKey: "panelUIDs")
        defaults.set(appAudio, forKey: "appAudio")
    }

    // MARK: Döngü

    /// Bağlı cihazlar, bilinen sıraya göre.
    private var connectedOrdered: [AudioDevice] {
        let order = known.map(\.uid)
        return connected.sorted {
            (order.firstIndex(of: $0.uid) ?? .max) < (order.firstIndex(of: $1.uid) ?? .max)
        }
    }

    /// ⌘⇪'nin dolaştığı cihazlar. 2'den az seçili cihaz takılıysa tüm bağlı cihazlar.
    var cycleTargets: [AudioDevice] {
        let all = connectedOrdered
        let chosen = all.filter { cycle.contains($0.uid) }
        return chosen.count >= 2 ? chosen : all
    }

    var usingFallback: Bool {
        connected.filter { cycle.contains($0.uid) }.count < 2
    }

    func nextDevice() -> AudioDevice? {
        let targets = cycleTargets
        guard !targets.isEmpty else { return nil }
        let curUID = current?.uid ?? lastSelectedUID
        guard let curUID, let i = targets.firstIndex(where: { $0.uid == curUID }) else {
            return targets.first
        }
        let next = targets[(i + 1) % targets.count]
        return next.uid == curUID ? nil : next
    }

    func switchTo(uid: String) {
        guard let dev = connected.first(where: { $0.uid == uid }) else { return }
        lastSelectedUID = uid          // eqMac geri alsa bile nerede olduğumuzu biliyoruz
        CA.setDefaultOutput(dev.id)
        refresh()
    }

    // MARK: Düzenleme

    var knownDevices: [KnownDevice] { known }
    func isConnected(_ uid: String) -> Bool { connected.contains { $0.uid == uid } }
    func isInCycle(_ uid: String) -> Bool { cycle.contains(uid) }
    func isInPanel(_ uid: String) -> Bool { panelSet.contains(uid) }

    func toggleCycle(_ uid: String) {
        if cycle.contains(uid) { cycle.remove(uid) } else { cycle.insert(uid) }
        save()
        rebuildRows()
    }

    /// Panel listesine ekle/çıkar. İşaretlemek "sadece seçtiklerim" moduna geçirir.
    func togglePanel(_ uid: String) {
        if panelSet.contains(uid) { panelSet.remove(uid) } else { panelSet.insert(uid) }
        save()
        if panelShowAll && !panelSet.isEmpty { panelShowAll = false } else { rebuildRows() }
    }

    func forget(_ uid: String) {
        guard !isConnected(uid) else { return }
        known.removeAll { $0.uid == uid }
        cycle.remove(uid)
        panelSet.remove(uid)
        appAudio = appAudio.filter { $0.value != uid }
        save()
        rebuildRows()
    }

    // MARK: Uygulamaya göre ses cihazı

    func knownDevice(_ uid: String) -> KnownDevice? { known.first { $0.uid == uid } }

    /// Uygulamaya atanmış cihaz (bilinen cihazlar arasından)
    func device(forApp bundleID: String?) -> KnownDevice? {
        guard let bundleID, let uid = appAudio[bundleID] else { return nil }
        return knownDevice(uid)
    }

    func setAppDevice(_ uid: String?, bundleID: String) {
        appAudio[bundleID] = uid
        save()
    }

    /// Yok → 1. cihaz → 2. cihaz → … → yok (sadece takılı cihazlar arasında)
    func cycleAppDevice(bundleID: String) {
        let devices = connectedOrdered
        guard !devices.isEmpty else { return }
        if let uid = appAudio[bundleID], let i = devices.firstIndex(where: { $0.uid == uid }) {
            setAppDevice(i + 1 < devices.count ? devices[i + 1].uid : nil, bundleID: bundleID)
        } else {
            setAppDevice(devices[0].uid, bundleID: bundleID)
        }
    }

    /// Uygulama öne geldi: atanmış cihaz takılıysa ona geç. Geçildiyse cihazı döndürür.
    @discardableResult
    func applyAppDevice(bundleID: String?) -> AudioDevice? {
        guard autoSwitchByApp, let bundleID, let uid = appAudio[bundleID],
              current?.uid != uid,
              let dev = connected.first(where: { $0.uid == uid }) else { return nil }
        switchTo(uid: uid)
        return dev
    }
}
