import Cocoa
import IOKit

// MARK: - Harici monitörler: parlaklık ve ses (DDC/CI)
//
// Mac'in kendi ekranı hiç dahil değil; sadece harici monitörler. Monitöre DDC/CI ile
// (monitörün kendi menüsündeki parlaklık / ses ayarı) komut gönderilir. Apple Silicon
// Mac'lerde IOAVService üzerinden çalışır. Bazı monitörler (özellikle bazı HDMI
// bağlantılarında) DDC'yi desteklemez; o zaman kaydırıcı bir şey değiştirmez.

enum MonitorSettings {
    private static let d = UserDefaults.standard
    /// Menü çubuğu menüsünde monitör kaydırıcıları
    static var showInMenu: Bool {
        get { d.object(forKey: "monitors.menu") as? Bool ?? true }
        set { d.set(newValue, forKey: "monitors.menu") }
    }
    /// Karartılmışken klavye arkadaki pencerelere yazmasın; sadece ⌘⇧< (geri açmak için) çalışır
    static var lockKeysWhenDark: Bool {
        get { d.object(forKey: "monitors.lockKeys") as? Bool ?? true }
        set { d.set(newValue, forKey: "monitors.lockKeys") }
    }
    /// ⌘⇧< ile harici monitörlerin parlaklığını 0'a çek / geri getir
    static var blackoutKey: Bool {
        get { d.object(forKey: "monitors.blackoutKey") as? Bool ?? true }
        set { d.set(newValue, forKey: "monitors.blackoutKey") }
    }
}

/// DDC/CI düşük seviye: IOAVService (Apple Silicon), özel API'ler çalışma anında bulunur
private enum DDC {
    typealias CreateFn = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    typealias WriteFn = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
    typealias ReadFn = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

    static let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
    static let create: CreateFn? = handle.flatMap { dlsym($0, "IOAVServiceCreateWithService") }.map { unsafeBitCast($0, to: CreateFn.self) }
    static let write: WriteFn? = handle.flatMap { dlsym($0, "IOAVServiceWriteI2C") }.map { unsafeBitCast($0, to: WriteFn.self) }
    static let read: ReadFn? = handle.flatMap { dlsym($0, "IOAVServiceReadI2C") }.map { unsafeBitCast($0, to: ReadFn.self) }

    static var available: Bool { create != nil && write != nil && read != nil }

    static let chip: UInt32 = 0x37, dataAddr: UInt32 = 0x51

    private static func checksum(_ bytes: [UInt8]) -> UInt8 {
        bytes.reduce(UInt8(0x6E ^ 0x51)) { $0 ^ $1 }    // hedef 0x6E, kaynak 0x51 + paket
    }

    /// VCP değeri yaz (ör. 0x10 parlaklık, 0x62 ses)
    static func set(_ svc: CFTypeRef, vcp: UInt8, value: Int) -> Bool {
        guard let write else { return false }
        let v = UInt16(clamping: max(0, value))
        var packet: [UInt8] = [0x84, 0x03, vcp, UInt8(v >> 8), UInt8(v & 0xFF)]
        packet.append(checksum(packet))
        for _ in 0..<3 {
            usleep(10_000)
            let r = packet.withUnsafeMutableBytes { write(svc, chip, dataAddr, $0.baseAddress!, UInt32($0.count)) }
            if r == kIOReturnSuccess { return true }
        }
        return false
    }

    /// VCP değeri oku: (şu anki, en yüksek)
    static func get(_ svc: CFTypeRef, vcp: UInt8) -> (current: Int, max: Int)? {
        guard let write, let read else { return nil }
        var packet: [UInt8] = [0x82, 0x01, vcp]
        packet.append(checksum(packet))
        for _ in 0..<3 {
            usleep(10_000)
            let w = packet.withUnsafeMutableBytes { write(svc, chip, dataAddr, $0.baseAddress!, UInt32($0.count)) }
            guard w == kIOReturnSuccess else { continue }
            usleep(50_000)
            var reply = [UInt8](repeating: 0, count: 12)
            let r = reply.withUnsafeMutableBytes { read(svc, chip, 0, $0.baseAddress!, UInt32($0.count)) }
            guard r == kIOReturnSuccess else { continue }
            // Yanıt: … 0x02 (VCP yanıtı), sonuç, vcp, tür, enYüksekH, enYüksekL, şimdiH, şimdiL …
            for i in 0..<(reply.count - 7) where reply[i] == 0x02 && reply[i + 2] == vcp && reply[i + 1] == 0 {
                let mx = Int(reply[i + 4]) << 8 | Int(reply[i + 5])
                let cur = Int(reply[i + 6]) << 8 | Int(reply[i + 7])
                if mx > 0 { return (cur, mx) }
            }
        }
        return nil
    }

    struct Service { let svc: CFTypeRef; let vendor: Int; let product: Int; let serial: Int; let name: String }

    /// Harici DCPAVServiceProxy'ler, önündeki ekran kartı girdisinin ürün bilgisiyle eşlenmiş
    static func externalServices() -> [Service] {
        guard let create else { return [] }
        var iter = io_iterator_t()
        guard IORegistryCreateIterator(kIOMainPortDefault, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iter) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iter) }
        var out: [Service] = []
        var last: (vendor: Int, product: Int, serial: Int, name: String) = (0, 0, 0, "")
        while case let e = IOIteratorNext(iter), e != 0 {
            defer { IOObjectRelease(e) }
            var buf = [CChar](repeating: 0, count: 128)
            IORegistryEntryGetName(e, &buf)
            let name = String(cString: buf)
            if name == "AppleCLCD2" || name == "IOMobileFramebufferShim" {
                if let attrs = IORegistryEntryCreateCFProperty(e, "DisplayAttributes" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any],
                   let p = attrs["ProductAttributes"] as? [String: Any] {
                    last = ((p["LegacyManufacturerID"] as? NSNumber)?.intValue ?? 0,
                            (p["ProductID"] as? NSNumber)?.intValue ?? 0,
                            (p["SerialNumber"] as? NSNumber)?.intValue ?? 0,
                            p["ProductName"] as? String ?? "")
                }
            } else if name == "DCPAVServiceProxy" {
                let loc = IORegistryEntryCreateCFProperty(e, "Location" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? String
                if loc == "External", let s = create(kCFAllocatorDefault, e)?.takeRetainedValue() {
                    out.append(Service(svc: s, vendor: last.vendor, product: last.product, serial: last.serial, name: last.name))
                }
            }
        }
        return out
    }
}

/// Harici monitörler ve parlaklık / ses durumları (Ayarlar ve menü bunu gösterir)
@MainActor final class Monitors: ObservableObject {
    static let shared = Monitors()

    struct Display: Identifiable {
        let id: CGDirectDisplayID
        let name: String
        fileprivate let service: CFTypeRef?
        var brightness: Double = 50      // 0…100
        var volume: Double = 50          // 0…100
        var brightnessMax = 100
        var volumeMax = 100
        var volumeSupported = true
        /// Ses bir kez okunabildiyse sonraki geçici okuma hatalarında kaydırıcı gizlenmez
        var volumeSeen = false
        var ddc: Bool { service != nil }
    }

    @Published private(set) var displays: [Display] = []
    /// ⌘⇧< ile karartıldıysa önceki parlaklıklar
    private var savedBrightness: [CGDirectDisplayID: Double] = [:]
    /// Tam karartma: her harici ekranın üstünde tamamen siyah bir pencere (+ DDC ile parlaklık 0)
    private var blackWindows: [NSWindow] = []
    @Published private(set) var isBlackedOut = false

    private let io = DispatchQueue(label: "audiotab.ddc", qos: .userInitiated)
    private var pending: [String: (CFTypeRef, UInt8, Int)] = [:]
    private var flushing = false

    var ddcAvailable: Bool { DDC.available }

    /// Monitör listesini yenile; değerleri arka planda oku.
    /// rescan: donanım listesi baştan taranır (açılışta, ekran değişince). Menü açılırken monitörler
    /// aynıysa tarama atlanır, sadece güncel parlaklık / ses okunur.
    func refresh(readValues: Bool = true, rescan: Bool = false) {
        let externals = NSScreen.screens.compactMap { s -> (CGDirectDisplayID, String)? in
            guard let id = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                  CGDisplayIsBuiltin(id) == 0 else { return nil }
            return (id, s.localizedName)
        }
        if !rescan, !displays.isEmpty, Set(externals.map { $0.0 }) == Set(displays.map(\.id)) {
            if readValues { readAll(displays) }
            return
        }
        if isBlackedOut { showBlackWindows() }   // ekranlar değiştiyse siyah pencereleri yeniden yerleştir
        var services = DDC.externalServices()
        var list: [Display] = []
        for (id, name) in externals {
            let v = Int(CGDisplayVendorNumber(id)), p = Int(CGDisplayModelNumber(id)), sn = Int(CGDisplaySerialNumber(id))
            var idx = services.firstIndex { $0.vendor == v && $0.product == p && (sn == 0 || $0.serial == 0 || $0.serial == sn) }
            if idx == nil, services.count == 1 { idx = 0 }     // tek harici monitör: eşleştirmeye gerek yok
            let svc = idx.map { services.remove(at: $0).svc }
            var disp = Display(id: id, name: name, service: svc)
            if let old = displays.first(where: { $0.id == id }) {
                disp.brightness = old.brightness; disp.volume = old.volume
                disp.brightnessMax = old.brightnessMax; disp.volumeMax = old.volumeMax
                disp.volumeSupported = old.volumeSupported
                disp.volumeSeen = old.volumeSeen
            }
            list.append(disp)
        }
        displays = list
        if readValues { readAll(list) }
    }

    private func readAll(_ list: [Display]) {
        for d in list where d.ddc {
            let svc = d.service!, id = d.id
            io.async {
                let b = DDC.get(svc, vcp: 0x10)
                let v = DDC.get(svc, vcp: 0x62)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let i = self.displays.firstIndex(where: { $0.id == id }) else { return }
                        if let b { self.displays[i].brightnessMax = b.max; self.displays[i].brightness = Double(b.current) * 100 / Double(b.max) }
                        if let v { self.displays[i].volumeMax = v.max; self.displays[i].volume = Double(v.current) * 100 / Double(v.max) }
                        if v != nil { self.displays[i].volumeSeen = true }
                        self.displays[i].volumeSupported = v != nil || self.displays[i].volumeSeen
                    }
                }
            }
        }
    }

    func setBrightness(_ value: Double, for id: CGDirectDisplayID) {
        guard let i = displays.firstIndex(where: { $0.id == id }) else { return }
        displays[i].brightness = value
        if value > 0, !isBlackedOut { savedBrightness[id] = nil }
        send(displays[i], vcp: 0x10, percent: value, max: displays[i].brightnessMax)
    }

    func setVolume(_ value: Double, for id: CGDirectDisplayID) {
        guard let i = displays.firstIndex(where: { $0.id == id }) else { return }
        displays[i].volume = value
        send(displays[i], vcp: 0x62, percent: value, max: displays[i].volumeMax)
    }

    /// ⌘⇧<: harici ekranlar tamamen kararır (görüntü kalmaz); tekrar basınca her şey eski haline döner.
    /// Siyah pencere her monitörde çalışır; DDC destekleyen monitörlerde arka ışık da 0'a iner.
    @discardableResult
    func toggleBlackout() -> Bool {
        if displays.isEmpty { refresh(readValues: false) }
        if isBlackedOut {
            isBlackedOut = false
            removeBlackWindows()
            for (id, b) in savedBrightness { setBrightness(b, for: id) }
            savedBrightness.removeAll()
            return false
        }
        isBlackedOut = true
        for d in displays where d.ddc {
            savedBrightness[d.id] = d.brightness > 0 ? d.brightness : 50
            setBrightness(0, for: d.id)
        }
        showBlackWindows()
        return true
    }

    private func showBlackWindows() {
        removeBlackWindows()
        for s in NSScreen.screens {
            guard let id = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                  CGDisplayIsBuiltin(id) == 0 else { continue }      // Mac'in kendi ekranı hariç
            let w = NSWindow(contentRect: s.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: s)
            w.setFrame(s.frame, display: false)
            w.backgroundColor = .black
            w.isOpaque = true
            w.hasShadow = false
            w.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            w.isReleasedWhenClosed = false
            w.animationBehavior = .none
            w.ignoresMouseEvents = false        // karanlık ekrana yanlışlıkla tıklanmasın
            w.orderFrontRegardless()
            blackWindows.append(w)
        }
    }

    private func removeBlackWindows() {
        blackWindows.forEach { $0.orderOut(nil) }
        blackWindows.removeAll()
    }

    /// Kaydırıcı sürüklenirken komutlar birikmesin: her monitör/ayar için sadece son değer gönderilir
    private func send(_ d: Display, vcp: UInt8, percent: Double, max: Int) {
        guard let svc = d.service else { return }
        let raw = Int((percent / 100 * Double(max)).rounded())
        pending["\(d.id)-\(vcp)"] = (svc, vcp, raw)
        guard !flushing else { return }
        flushing = true
        flush()
    }

    private func flush() {
        guard let (key, job) = pending.first else { flushing = false; return }
        pending[key] = nil
        io.async {
            _ = DDC.set(job.0, vcp: job.1, value: job.2)
            usleep(30_000)
            DispatchQueue.main.async { MainActor.assumeIsolated { self.flush() } }
        }
    }
}

// MARK: - Menü çubuğu menüsündeki kaydırıcı satırı

final class MenuSliderView: NSView {
    private let slider: NSSlider
    private let onChange: (Double) -> Void

    init(symbol: String, value: Double, enabled: Bool, onChange: @escaping (Double) -> Void) {
        self.onChange = onChange
        slider = NSSlider(value: value, minValue: 0, maxValue: 100, target: nil, action: nil)
        super.init(frame: NSRect(x: 0, y: 0, width: 250, height: 26))
        let img = NSImageView(frame: NSRect(x: 18, y: 5, width: 16, height: 16))
        img.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        img.contentTintColor = .secondaryLabelColor
        addSubview(img)
        slider.frame = NSRect(x: 42, y: 3, width: 190, height: 20)
        slider.isContinuous = true
        slider.isEnabled = enabled
        slider.target = self
        slider.action = #selector(changed)
        addSubview(slider)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func changed() { onChange(slider.doubleValue) }
}
