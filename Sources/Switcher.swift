// AudioTab — pencere değiştirici kısmı (eski GlassTab). Ses kısmı ayrı dosyalarda.
// Önizleme görüntüleri SADECE Cmd+Tab basılıyken, SADECE pencere başına tek kare olarak alınır.
// Hiçbir şey kaydedilmez, diske yazılmaz, internete gönderilmez (tek ağ erişimi: GitHub'dan güncelleme kontrolü).
// Boştayken hiçbir timer/polling çalışmaz.

import AppKit
import ApplicationServices
import ServiceManagement
import ScreenCaptureKit

// MARK: - Sistem fonksiyonları (çalışma anında yüklenir; derleme sırasında bağlanmaz)

private let RTLD_DEFAULT_ = UnsafeMutableRawPointer(bitPattern: -2)
private let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

private func sym<T>(_ name: String, _: T.Type) -> T? {
    guard let p = dlsym(skyLight, name) ?? dlsym(RTLD_DEFAULT_, name) else { return nil }
    return unsafeBitCast(p, to: T.self)
}

private typealias FnHotKey = @convention(c) (Int32, Bool) -> Int32
private typealias FnGetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> Int32
private typealias FnPSN = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
private typealias FnFront = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> Int32
private typealias FnPost = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> Int32

private let fHotKey = sym("CGSSetSymbolicHotKeyEnabled", FnHotKey.self)
private let fGetWindow = sym("_AXUIElementGetWindow", FnGetWindow.self)
private let fPSN = sym("GetProcessForPID", FnPSN.self)
private let fFront = sym("_SLPSSetFrontProcessWithOptions", FnFront.self)
private let fPost = sym("SLPSPostEventRecordTo", FnPost.self)

private typealias FnRemoteToken = @convention(c) (CFData) -> Unmanaged<AXUIElement>?
/// Uygulamanın bir AX öğesine kimlik numarasıyla doğrudan ulaşır (diğer masaüstlerindeki pencereler için).
private let fRemoteToken = sym("_AXUIElementCreateWithRemoteToken", FnRemoteToken.self)

/// Sistemin kendi Cmd+Tab ve Cmd+Shift+Tab kısayollarını aç/kapat.
/// Kapattığımız macOS kısayolları; çıkışta (ve SIGTERM/SIGINT'te) geri açılır.
var gDisabledNativeHotkeys = Set<Int32>()

/// macOS'un kendi kısayollarını aç/kapat. Kimlikler: 1-2 ⌘Tab, 27 sonraki pencere (⌘< / ⌘`),
/// 28 ⌘⇧3, 30 ⌘⇧4, 184 ⌘⇧5, 181 ⌘⇧6.
func setNativeHotkeys(_ ids: [Int32], enabled: Bool) {
    for id in ids {
        _ = fHotKey?(id, enabled)
        if enabled { gDisabledNativeHotkeys.remove(id) } else { gDisabledNativeHotkeys.insert(id) }
    }
}

func restoreNativeHotkeys() {
    for id in gDisabledNativeHotkeys { _ = fHotKey?(id, true) }
    gDisabledNativeHotkeys.removeAll()
}

func setNativeCommandTab(_ enabled: Bool) {
    setNativeHotkeys([1, 2], enabled: enabled)
}

// MARK: - Ayarlar

/// Her kısayolun kendi ayarları var: Cmd+Tab ve Option+Tab.
enum Profile: String, CaseIterable {
    case cmd, opt

    var flag: CGEventFlags { self == .cmd ? .maskCommand : .maskAlternate }
    var other: CGEventFlags { self == .cmd ? .maskAlternate : .maskCommand }
    var title: String { self == .cmd ? "⌘  Cmd + Tab" : "⌥  Option + Tab" }

    private func read(_ k: String, _ def: Bool) -> Bool {
        UserDefaults.standard.object(forKey: "\(rawValue).\(k)") as? Bool ?? def
    }
    private func write(_ k: String, _ v: Bool) { UserDefaults.standard.set(v, forKey: "\(rawValue).\(k)") }

    /// Kısayol açık mı (varsayılan: ikisi de açık)
    var enabled: Bool {
        get { read("enabled", true) }
        nonmutating set { write("enabled", newValue) }
    }
    /// Pencere önizlemeleri (varsayılan: sadece Option+Tab'da)
    var previews: Bool {
        get { read("previews", self == .opt) }
        nonmutating set { write("previews", newValue) }
    }
    /// Küçültülmüş pencereler + penceresiz uygulamalar (varsayılan: sadece Cmd+Tab'da)
    var showMinimized: Bool {
        get { read("showMinimized", self == .cmd) }
        nonmutating set { write("showMinimized", newValue) }
    }

    /// Liste görünümü (ses listesi gibi alt alta satırlar). Varsayılan: kapalı (ızgara)
    var list: Bool {
        get { read("list", false) }
        nonmutating set { write("list", newValue) }
    }

    /// Gruplu görünüm: Klasörler · Tarayıcılar · Projeler · Geliştirme · Uygulamalar bölümleri (isteğe bağlı)
    var grouped: Bool {
        get { read("grouped", false) }
        nonmutating set { write("grouped", newValue) }
    }

    /// Sadece bu uygulamanın pencereleri (paket kimliği). Boş = tüm uygulamalar.
    /// Panel açıkken A ile değiştirilebilir.
    var appFilter: String {
        get { UserDefaults.standard.string(forKey: "\(rawValue).appFilter") ?? "" }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: "\(rawValue).appFilter") }
    }

    func get(_ key: String) -> Bool {
        switch key {
        case "enabled": return enabled
        case "previews": return previews
        case "list": return list
        case "grouped": return grouped
        default: return showMinimized
        }
    }
    func toggle(_ key: String) {
        switch key {
        case "enabled": enabled.toggle()
        case "previews": previews.toggle()
        case "list": list.toggle()
        case "grouped": grouped.toggle()
        default: showMinimized.toggle()
        }
    }
}

// MARK: - Model

struct Item {
    let app: NSRunningApplication
    let window: AXUIElement?
    let wid: CGWindowID
    let title: String
    var minimized: Bool
    var aspect: CGFloat = 1.6   // genişlik / yükseklik
    var system = false          // sistem sorusu / uyarısı
    var pid: pid_t { app.processIdentifier }
}

// MARK: - Pencere listesi (sadece Cmd+Tab basıldığı an çalışır)

/// Uygulama başına toplanan, ana iş parçacığında hazırlanmış bilgi.
struct AppScanInfo {
    let app: NSRunningApplication
    let pid: pid_t
    let isRegular: Bool
    let rank: Int
    let name: String
    let systemWin: (CGWindowID, CGFloat)?
    /// Kalıcı pencere kaydı bu uygulama için kullanılsın mı (tarayıcılar vb.)
    let deep: Bool
    /// Pencere sunucusuna göre bu uygulamanın var olan normal pencereleri (diğer masaüstleri dahil).
    /// AX ile henüz bulunamamış olanlar da listede gösterilsin diye (ör. Chrome'da yeni açılan profil penceresi).
    var expected: [CGWindowID: (title: String, aspect: CGFloat)] = [:]
}

/// Bir uygulamanın pencere sunucusundaki gerçek pencereleri (katman 0, makul boyutta).
/// Diğer masaüstlerindekiler ve küçültülmüşler de gelir. Başlık sadece Ekran Kaydı izni varsa dolu.
func realWindows(_ all: [[String: Any]], pid: pid_t? = nil) -> [pid_t: [CGWindowID: (title: String, aspect: CGFloat)]] {
    var out: [pid_t: [CGWindowID: (title: String, aspect: CGFloat)]] = [:]
    for w in all where (w[kCGWindowLayer as String] as? Int) == 0 {
        guard let n = w[kCGWindowNumber as String] as? Int,
              let p = (w[kCGWindowOwnerPID as String] as? Int).map({ pid_t($0) }), pid == nil || p == pid,
              let b = w[kCGWindowBounds as String] as? [String: CGFloat],
              let wd = b["Width"], let ht = b["Height"], wd >= 200, ht >= 120,
              (w[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { continue }
        out[p, default: [:]][CGWindowID(n)] = (w[kCGWindowName as String] as? String ?? "", wd / ht)
    }
    return out
}

// MARK: - Pencereleri her zaman bul (diğer masaüstleri + geç cevap veren uygulamalar)

/// Hangi uygulamaların pencereleri kalıcı kayıtta tutulsun.
enum DeepScanScope: String, CaseIterable {
    case off, browsers, all

    static var current: DeepScanScope {
        get { DeepScanScope(rawValue: UserDefaults.standard.string(forKey: "deepScan") ?? "") ?? .browsers }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "deepScan") }
    }

    static let browserPrefixes = [
        "com.google.Chrome", "org.chromium.", "com.brave.Browser", "com.microsoft.edgemac",
        "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "company.thebrowser.", "com.apple.Safari",
        "org.mozilla.firefox", "app.zen-browser", "com.kagi.kagimacOS", "ai.perplexity.comet",
    ]

    /// Kullanıcının eklediği uygulamalar (paket kimliği): "Tarayıcılar" kapsamında onlar da hep bulunur
    static var extraApps: [String] {
        get { UserDefaults.standard.stringArray(forKey: "deepScan.extra") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "deepScan.extra") }
    }

    func covers(_ app: NSRunningApplication) -> Bool {
        guard app.activationPolicy == .regular else { return false }
        switch self {
        case .off: return false
        case .all: return true
        case .browsers:
            guard let b = app.bundleIdentifier else { return false }
            return Self.browserPrefixes.contains { b.hasPrefix($0) } || Self.extraApps.contains(b)
        }
    }
}

/// Uygulamaların bilinen pencereleri. Arka planda doldurulur, ⌘Tab anında sadece okunur.
///
/// macOS'un pencere listesi (kAXWindows) sadece o anki masaüstündeki pencereleri verir ve
/// Chrome yoğunken geç cevap verir. Bu kayıt sayesinde Chrome'un tüm profil pencereleri,
/// diğer masaüstlerindekiler ve tam ekrandakiler dahil, her zaman listede olur.
final class WindowRegistry: @unchecked Sendable {
    static let shared = WindowRegistry()

    private let lock = NSLock()
    private var map: [pid_t: [CGWindowID: AXUIElement]] = [:]
    /// Pencere sunucusunda görünen ama gerçek pencere olmayanlar (araç ipucu, gizli yardımcı pencere…)
    private var ignored: [pid_t: Set<CGWindowID>] = [:]
    private var pending = Set<pid_t>()
    private var lastRun: [pid_t: Date] = [:]
    private let queue = DispatchQueue(label: "audiotab.windowregistry", qos: .utility)

    func windows(_ pid: pid_t) -> [CGWindowID: AXUIElement] {
        lock.lock(); defer { lock.unlock() }
        return map[pid] ?? [:]
    }

    func ignoredWindows(_ pid: pid_t) -> Set<CGWindowID> {
        lock.lock(); defer { lock.unlock() }
        return ignored[pid] ?? []
    }

    var isEmpty: Bool {
        lock.lock(); defer { lock.unlock() }
        return map.isEmpty
    }

    func remember(_ pid: pid_t, _ wins: [CGWindowID: AXUIElement]) {
        guard !wins.isEmpty else { return }
        lock.lock()
        map[pid, default: [:]].merge(wins) { _, new in new }
        lock.unlock()
    }

    func forget(_ pid: pid_t) {
        lock.lock()
        map[pid] = nil
        ignored[pid] = nil
        lastRun[pid] = nil
        lock.unlock()
    }

    func removeAll() {
        lock.lock()
        map.removeAll()
        ignored.removeAll()
        lastRun.removeAll()
        lock.unlock()
    }

    /// Kapanmış pencereleri kayıttan at.
    func prune(alive: Set<CGWindowID>) {
        lock.lock()
        for (pid, wins) in map {
            let kept = wins.filter { alive.contains($0.key) }
            map[pid] = kept.isEmpty ? nil : kept
        }
        for (pid, set) in ignored {
            let kept = set.filter { alive.contains($0) }
            ignored[pid] = kept.isEmpty ? nil : kept
        }
        lock.unlock()
    }

    /// Arka planda uygulamaların TÜM pencerelerini bul.
    /// force=false ise aynı uygulama 5 sn içinde tekrar taranmaz (pil için).
    func refresh(_ pids: [pid_t], force: Bool = false) {
        let now = Date()
        lock.lock()
        let todo = pids.filter { pid in
            if pending.contains(pid) { return false }
            if !force, let last = lastRun[pid], now.timeIntervalSince(last) < 5 { return false }
            return true
        }
        for pid in todo { pending.insert(pid); lastRun[pid] = now }
        lock.unlock()

        for pid in todo {
            queue.async { [self] in
                let (found, skip) = Self.findAllWindows(pid)
                lock.lock()
                pending.remove(pid)
                if !found.isEmpty { map[pid, default: [:]].merge(found) { _, new in new } }
                if !skip.isEmpty { ignored[pid, default: []].formUnion(skip) }
                lock.unlock()
            }
        }
    }

    /// Uygulamanın AX öğelerini kimlik numarasıyla tek tek dener; pencere olanları toplar.
    /// Diğer masaüstlerindeki pencereler de bu yolla bulunur. Sadece arka planda çalışır.
    /// Dönüş: bulunan pencereler + gerçek pencere olmadığı anlaşılanlar (bir daha aranmaz, listede gösterilmez).
    private static func findAllWindows(_ pid: pid_t) -> ([CGWindowID: AXUIElement], Set<CGWindowID>) {
        guard let fRemoteToken else { return ([:], []) }
        let standard = kAXStandardWindowSubrole as String
        let dialog = kAXDialogSubrole as String

        var token = Data(count: 20)
        token.replaceSubrange(0..<4, with: withUnsafeBytes(of: pid) { Data($0) })
        token.replaceSubrange(4..<8, with: withUnsafeBytes(of: Int32(0)) { Data($0) })
        token.replaceSubrange(8..<12, with: withUnsafeBytes(of: Int32(0x636f636f)) { Data($0) })

        // Bulunması gereken pencereler: pencere sunucusunda bu uygulamaya ait olanlar.
        // Hepsi bulununca durulur. Chrome gibi çok öğesi olan uygulamalarda yeni pencerelerin
        // kimlik numarası büyük olabildiği için aralık geniş, süre sınırı da daha uzun (arka planda).
        let all = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        var targets = Set((realWindows(all, pid: pid)[pid] ?? [:]).keys)
        var out: [CGWindowID: AXUIElement] = [:]
        var skip = Set<CGWindowID>()
        var timedOut = false
        let deadline = Date().addingTimeInterval(targets.isEmpty ? 0.8 : 3.0)
        let limit: UInt64 = targets.isEmpty ? 1500 : 60_000
        for id in UInt64(0)..<limit {
            if id % 100 == 0 && Date() > deadline { timedOut = true; break }
            if id >= 1500 && targets.isEmpty { break }
            token.replaceSubrange(12..<20, with: withUnsafeBytes(of: id) { Data($0) })
            guard let el = fRemoteToken(token as CFData)?.takeRetainedValue() else { continue }
            AXUIElementSetMessagingTimeout(el, 0.05)
            guard let sub: String = AX.attr(el, kAXSubroleAttribute) else { continue }
            var wid: CGWindowID = 0
            guard fGetWindow?(el, &wid) == 0, wid != 0 else { continue }
            if sub == standard || sub == dialog { out[wid] = el } else { skip.insert(wid) }
            targets.remove(wid)
            if limit > 1500 && targets.isEmpty { break }   // aranan hepsi bulundu
        }
        // Tüm aralık tarandı ve hâlâ bulunamadıysa bunlar kullanıcı penceresi değil
        if !timedOut { skip.formUnion(targets) }
        return (out, skip)
    }
}

/// Erişilebilirlik sorguları. Ana iş parçacığına bağlı değil: uygulamalar paralel taranır.
enum AX {
    static func attr<T>(_ el: AXUIElement, _ name: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success, let v else { return nil }
        return v as? T
    }

    /// Tüm uygulamaları aynı anda tarar (eskiden tek tek, sırayla taranıyordu).
    /// Yavaş cevap veren bir uygulama artık diğerlerini bekletmez.
    static func scanAll(_ infos: [AppScanInfo], z: [CGWindowID: Int], alive: Set<CGWindowID>, showMin: Bool) -> [(Int, Item)] {
        let n = infos.count
        guard n > 0 else { return [] }
        let out = UnsafeMutableBufferPointer<[(Int, Item)]>.allocate(capacity: n)
        out.initialize(repeating: [])
        defer { out.deinitialize(); out.deallocate() }
        DispatchQueue.concurrentPerform(iterations: n) { i in
            out[i] = scan(infos[i], z: z, alive: alive, showMin: showMin)   // her iş parçacığı kendi hücresine yazar
        }
        return out.flatMap { $0 }
    }

    static func scan(_ info: AppScanInfo, z: [CGWindowID: Int], alive: Set<CGWindowID>, showMin: Bool) -> [(Int, Item)] {
        let standard = kAXStandardWindowSubrole as String
        let dialog = kAXDialogSubrole as String
        let sysDialog = kAXSystemDialogSubrole as String
        let app = info.app
        let axApp = AXUIElementCreateApplication(info.pid)
        // Takılan uygulama switcher'ı yavaşlatmasın. Kayıtlı uygulamalara biraz daha süre tanınır;
        // yine de cevap gelmezse pencereler kayıttan gelir.
        AXUIElementSetMessagingTimeout(axApp, info.deep ? 0.15 : 0.08)
        let wins: [AXUIElement] = attr(axApp, kAXWindowsAttribute) ?? []
        var result: [(Int, Item)] = []

        // Canlı liste + (kayıtlı uygulamalarda) kayıttaki, hâlâ var olan diğer pencereler
        var cands: [(AXUIElement, CGWindowID)] = []
        var seen = Set<CGWindowID>()
        for w in wins {
            var wid: CGWindowID = 0
            _ = fGetWindow?(w, &wid)
            cands.append((w, wid))
            if wid != 0 { seen.insert(wid) }
        }
        if info.deep {
            for (wid, el) in WindowRegistry.shared.windows(info.pid) where !seen.contains(wid) && alive.contains(wid) {
                cands.append((el, wid))
            }
        }
        var good: [CGWindowID: AXUIElement] = [:]

        for (j, (w, wid)) in cands.enumerated() {
            AXUIElementSetMessagingTimeout(w, 0.08)
            let sub: String? = attr(w, kAXSubroleAttribute)
            guard sub == standard || sub == dialog || sub == sysDialog else { continue }
            if info.deep && wid != 0 { good[wid] = w }
            // Sistem süreçlerinden sadece şu an ekranda duran soru pencerelerini al
            if !info.isRegular && z[wid] == nil { continue }
            let minimized: Bool = attr(w, kAXMinimizedAttribute) ?? false
            // Tarayıcılar (kalıcı kayıttakiler) Dock'a gönderilmiş olsa da her zaman listede
            if minimized && !showMin && !info.deep { continue }
            let t: String = attr(w, kAXTitleAttribute) ?? ""
            var aspect: CGFloat = 1.6
            if let v: AXValue = attr(w, kAXSizeAttribute) {
                var sz = CGSize.zero
                if AXValueGetValue(v, .cgSize, &sz), sz.width > 10, sz.height > 10 { aspect = sz.width / sz.height }
            }
            let score = z[wid] ?? (100_000 + info.rank * 100 + j + (minimized ? 50 : 0))
            result.append((score, Item(app: app, window: w, wid: wid,
                                       title: t.isEmpty ? info.name : t, minimized: minimized, aspect: aspect,
                                       system: !info.isRegular)))
        }
        if info.deep { WindowRegistry.shared.remember(info.pid, good) }
        // Pencere sunucusunda olup AX ile henüz bulunamayan pencereler (ör. az önce başka masaüstünde
        // açılan Chrome profil penceresi) varsa arka planda aramaya başla. Listeye sadece gerçekten
        // bulunan pencereler girer (kimliği belli olmayanları göstermek gizli yardımcı pencereleri de getiriyordu).
        if info.deep && info.isRegular {
            let known = Set(cands.map { $0.1 }).union(WindowRegistry.shared.ignoredWindows(info.pid))
            if info.expected.keys.contains(where: { !known.contains($0) }) {
                WindowRegistry.shared.refresh([info.pid], force: true)
            }
        }
        if result.isEmpty && !info.isRegular, let sw = info.systemWin {
            // AX ile pencere vermeyen sistem soruları (ör. şifre kutusu)
            result.append((z[sw.0] ?? 0, Item(app: app, window: nil, wid: sw.0, title: info.name,
                                             minimized: false, aspect: sw.1, system: true)))
        } else if result.isEmpty && showMin && info.isRegular {
            result.append((1_000_000 + info.rank, Item(app: app, window: nil, wid: 0, title: info.name, minimized: false)))
        }
        return result
    }
}

@MainActor enum WindowList {
    static func attr<T>(_ el: AXUIElement, _ name: String) -> T? { AX.attr(el, name) }

    static func build(mru: [pid_t], showMin: Bool) -> [Item] {
        let me = getpid()

        // Ekrandaki pencerelerin önden arkaya sırası.
        // Katman 0 = normal pencereler, 1…19 = sistem uyarıları / izin soruları / modal paneller.
        // (Dock, menü çubuğu vb. 20+ katmanlar hariç.)
        var z: [CGWindowID: Int] = [:]
        var systemPids = Set<pid_t>()
        var systemWin: [pid_t: (CGWindowID, CGFloat)] = [:]
        if let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            for (i, w) in info.enumerated() {
                guard let layer = w[kCGWindowLayer as String] as? Int, (0...19).contains(layer),
                      let n = w[kCGWindowNumber as String] as? Int else { continue }
                z[CGWindowID(n)] = i
                if layer > 0, let pid = w[kCGWindowOwnerPID as String] as? Int,
                   let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                   (b["Width"] ?? 0) >= 120, (b["Height"] ?? 0) >= 60 {
                    systemPids.insert(pid_t(pid))
                    if systemWin[pid_t(pid)] == nil {
                        systemWin[pid_t(pid)] = (CGWindowID(n), (b["Width"] ?? 1) / max(1, b["Height"] ?? 1))
                    }
                }
            }
        }

        // Normal uygulamalar + ekranda soru/uyarı penceresi açık olan sistem süreçleri
        var apps: [NSRunningApplication] = []
        var seen = Set<pid_t>()
        for a in NSWorkspace.shared.runningApplications where a.processIdentifier != me {
            if a.activationPolicy == .regular || systemPids.contains(a.processIdentifier) {
                apps.append(a); seen.insert(a.processIdentifier)
            }
        }
        for pid in systemPids where pid != me && !seen.contains(pid) {
            if let a = NSRunningApplication(processIdentifier: pid) { apps.append(a) }
        }

        let scope = DeepScanScope.current
        var infos: [AppScanInfo] = apps.map { app -> AppScanInfo in
            let pid = app.processIdentifier
            return AppScanInfo(app: app, pid: pid, isRegular: app.activationPolicy == .regular,
                               rank: mru.firstIndex(of: pid) ?? 500, name: app.localizedName ?? "",
                               systemWin: systemWin[pid], deep: scope.covers(app))
        }

        // Var olan tüm pencereler (diğer masaüstleri ve küçültülmüşler dahil):
        // kayıttaki kapanmış pencereleri ayıklamak için
        var alive = Set<CGWindowID>()
        if infos.contains(where: \.deep),
           let all = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] {
            for w in all where (w[kCGWindowLayer as String] as? Int) == 0 {
                if let n = w[kCGWindowNumber as String] as? Int { alive.insert(CGWindowID(n)) }
            }
            WindowRegistry.shared.prune(alive: alive)
            BrowserProfiles.shared.prune(alive: alive)
            let real = realWindows(all)
            for i in infos.indices where infos[i].deep { infos[i].expected = real[infos[i].pid] ?? [:] }
        }

        let scored = AX.scanAll(infos, z: z, alive: alive, showMin: showMin)
        return scored.sorted { $0.0 < $1.0 }.map(\.1)
    }

    static func focus(_ item: Item) {
        let app = item.app
        if app.isHidden { app.unhide() }
        var psn = ProcessSerialNumber()
        let hasPSN = fPSN.map { $0(item.pid, &psn) == 0 } ?? false

        guard let w = item.window else {
            if hasPSN {
                _ = fFront?(&psn, item.wid, item.wid == 0 ? 0x400 : 0x200)
                if item.wid != 0 { makeKey(&psn, item.wid) }
            }
            app.activate()
            return
        }
        if item.minimized {
            AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        if hasPSN, let fFront {
            _ = fFront(&psn, item.wid, 0x200)
            makeKey(&psn, item.wid)
        } else {
            app.activate()
        }
        AXUIElementPerformAction(w, kAXRaiseAction as CFString)
    }

    /// Seçilen pencerenin gerçekten klavye odağını almasını sağlar.
    static func makeKey(_ psn: UnsafeMutablePointer<ProcessSerialNumber>, _ wid: CGWindowID) {
        guard let fPost else { return }
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x3a] = 0x10
        for i in 0..<4 { bytes[0x3c + i] = UInt8((wid >> (UInt32(i) * 8)) & 0xff) }
        for i in 0x20..<0x30 { bytes[i] = 0xff }
        bytes.withUnsafeMutableBufferPointer { buf in
            buf[0x08] = 0x01; _ = fPost(psn, buf.baseAddress!)
            buf[0x08] = 0x02; _ = fPost(psn, buf.baseAddress!)
        }
    }

    static func close(_ item: Item) {
        guard let w = item.window, let btn: AXUIElement = attr(w, kAXCloseButtonAttribute) else { return }
        AXUIElementPerformAction(btn, kAXPressAction as CFString)
    }

    static func minimize(_ item: Item) {
        guard let w = item.window else { return }
        AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
    }
}

// MARK: - Önizlemeler (ScreenCaptureKit, pencere başına tek kare)

@available(macOS 14.0, *)
enum Thumbs {
    static func capture(_ wids: [CGWindowID], box: CGSize, scale: CGFloat,
                        each: @escaping @MainActor (CGWindowID, CGImage) -> Void) async {
        guard !wids.isEmpty,
              let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        else { return }
        var map: [CGWindowID: SCWindow] = [:]
        for w in content.windows { map[w.windowID] = w }

        await withTaskGroup(of: Void.self) { group in
            for wid in wids {
                guard let w = map[wid] else { continue }
                let f = w.frame
                guard f.width > 2, f.height > 2 else { continue }
                group.addTask {
                    if Task.isCancelled { return }
                    let k = min(box.width / f.width, box.height / f.height, 1) * scale
                    let cfg = SCStreamConfiguration()
                    cfg.width = max(1, Int(f.width * k))
                    cfg.height = max(1, Int(f.height * k))
                    cfg.showsCursor = false
                    cfg.ignoreShadowsSingleWindow = true
                    cfg.capturesAudio = false
                    cfg.captureResolution = .best   // retina kaynaktan küçült → keskin görüntü
                    cfg.scalesToFit = true
                    let filter = SCContentFilter(desktopIndependentWindow: w)
                    if let img = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg),
                       !Task.isCancelled {
                        await each(wid, img)
                    }
                }
            }
        }
    }
}

// MARK: - Klavye yakalama

@MainActor var gSwitcher: Switcher?
@MainActor var gAudioKeys: AudioKeys?
@MainActor var gExtraKeys: ExtraKeys?

let tapCallback: CGEventTapCallBack = { _, type, event, _ in
    let code = event.getIntegerValueField(.keyboardEventKeycode)
    let flags = event.flags
    let swallow = MainActor.assumeIsolated { () -> Bool in
        gAudioKeys?.handle(type, code, flags)              // ses kısayolu (hiçbir tuşu yutmaz)
        if gExtraKeys?.handle(type, code, flags, event) == true { return true }   // ⌘⇧3/4/5/6, ⌘<, ⌘⇧<
        // Harici ekranlar karartılmışken tuşlar arkadaki pencerelere gitmesin (⌘⇧< yukarıda zaten işlendi)
        if (type == .keyDown || type == .keyUp), Monitors.shared.isBlackedOut, MonitorSettings.lockKeysWhenDark { return true }
        if gSwitcher?.isActive != true, FinderMouseNav.handle(type, event) { return true }   // fare 4/5: Finder'da geri/ileri
        return gSwitcher?.handle(type, code, flags) ?? false
    }
    return swallow ? nil : Unmanaged.passUnretained(event)
}

@MainActor final class Switcher {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var items: [Item] = []
    /// Filtre uygulanmadan önceki tüm pencereler (panel açıkken uygulama değiştirmek için)
    private var allItems: [Item] = []
    private var selected = 0
    private var active = false
    private var profile: Profile = .cmd
    private var showWork: DispatchWorkItem?
    private var captureTask: Task<Void, Never>?
    private var mru: [pid_t] = []
    private var thumbCache: [CGWindowID: CGImage] = [:]

    /// Uygulamaya atanmış ses cihazı (kartlarda rozet)
    var audioFor: ((NSRunningApplication) -> (symbol: String, name: String)?)?
    /// Panel açıkken S: seçili uygulamanın ses cihazını sıradakiyle değiştir
    var onCycleAudio: ((NSRunningApplication) -> Void)?

    private lazy var ui: SwitcherUI = {
        let u = SwitcherUI(
            onHover: { [weak self] i in self?.select(i) },
            onExit: { _ in },   // fare karttan çıkınca seçim kaybolmasın
            onClick: { [weak self] i in self?.select(i); self?.commit() }
        )
        u.onCloseItem = { [weak self] i in self?.closeItem(at: i) }
        u.onTileItem = { [weak self] i in self?.tileItem(at: i) }
        u.onPickFilter = { [weak self] i in self?.setFilter(index: i) }
        u.onOpenFavorite = { [weak self] url in
            self?.end()
            NSWorkspace.shared.open(url)
        }
        return u
    }()

    /// Karttaki bölme düğmesi: panel kapanır, bu pencere için bölme seçici açılır
    var onTileItem: ((Item) -> Void)?

    init() {
        if let f = NSWorkspace.shared.frontmostApplication { mru = [f.processIdentifier] }
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let pid = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                self.mru.removeAll { $0 == pid }
                self.mru.insert(pid, at: 0)
            }
        }
        // Kalıcı pencere kaydını güncel tut: sadece olay olunca, timer yok
        nc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Switcher.refreshRegistry(force: true) }
        }
        nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if DeepScanScope.current.covers(app) { WindowRegistry.shared.refresh([app.processIdentifier], force: true) }
            }
        }
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  DeepScanScope.current.covers(app) else { return }
            WindowRegistry.shared.refresh([app.processIdentifier])
        }
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { n in
            guard let pid = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier else { return }
            WindowRegistry.shared.forget(pid)
        }
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let pid = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier else { return }
            MainActor.assumeIsolated { self?.mru.removeAll { $0 == pid } }
        }
    }

    func start() {
        guard tap == nil else { return }
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mask = types.reduce(0) { $0 | (1 << $1.rawValue) }
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: CGEventMask(mask), callback: tapCallback, userInfo: nil) else { return }
        tap = t
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        applyNative()
        ui.prewarm()   // ilk ⌘Tab'da gecikme olmasın
        Switcher.refreshRegistry(force: true)
    }

    /// Kapsamdaki tüm açık uygulamaların pencerelerini arka planda yeniden bul.
    static func refreshRegistry(force: Bool) {
        let scope = DeepScanScope.current
        guard scope != .off else { return }
        let pids = NSWorkspace.shared.runningApplications.filter { scope.covers($0) }.map(\.processIdentifier)
        WindowRegistry.shared.refresh(pids, force: force)
    }

    /// Ayarlardan kapsam değişti
    func deepScopeChanged() {
        WindowRegistry.shared.removeAll()
        Switcher.refreshRegistry(force: true)
    }

    /// Cmd+Tab bizdeyse sistemin kendi Cmd+Tab'ını kapat, değilse geri ver.
    func applyNative() {
        guard tap != nil else { return }
        setNativeCommandTab(!Profile.cmd.enabled)
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        setNativeCommandTab(true)
    }

    func clearThumbs() { thumbCache.removeAll() }

    var isRunning: Bool { tap != nil }
    var isActive: Bool { active }

    /// true dönerse tuş olayı yutulur.
    func handle(_ type: CGEventType, _ key: Int64, _ flags: CGEventFlags) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        case .flagsChanged:
            if active && !flags.contains(profile.flag) { commit() }
            return false
        case .keyDown:
            let shift = flags.contains(.maskShift)
            if key == 48 {                              // Tab
                if active {
                    step(shift ? -1 : 1)
                    return true
                }
                if let p = Profile.allCases.first(where: {
                    $0.enabled && flags.contains($0.flag) && !flags.contains($0.other) && !flags.contains(.maskControl)
                }) {
                    profile = p
                    begin(reverse: shift)
                    return true
                }
                return false
            }
            guard active else { return false }
            switch key {
            case 53: end()                              // Esc
            case 123: horizontal(-1)                    // ←
            case 124: horizontal(1)                     // →
            case 126: vertical(-1)                      // ↑
            case 125: vertical(1)                       // ↓
            case 36, 49: commit()                       // Enter / Space
            case 12: quitSelected()                     // Q
            case 13: closeSelected()                    // W
            case 46: minimizeSelected()                 // M
            case 4: hideSelected()                      // H
            case 1: cycleAudioSelected()                // S: ses cihazı ata
            case 0: cycleFilter(shift ? -1 : 1)          // A: filtreyi sonraki / önceki uygulamaya geçir
            case 10, 50, 3: toggleQuickFilter()          // Tab'ın üstündeki tuş (é / `) ya da F: sadece seçili kartın uygulaması
            default: break
            }
            return true
        case .keyUp:
            return active
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            // Ekran bölme panelleri açıkken dışına tıklanınca kapanır (Esc gibi)
            if !active, let outside = OutsideClick.handler { return outside(NSEvent.mouseLocation) }
            // Panel açıkken kartların dışına (boşluğa ya da panelin dışına) tıklanınca kapat
            guard active else { return false }
            if ui.hitsCard(NSEvent.mouseLocation) == true { return false }   // karta tıklama: kart kendisi işler
            end()
            return true
        default:
            return false
        }
    }

    private var previewsOn: Bool {
        guard profile.previews, !profile.list, #available(macOS 14.0, *) else { return false }
        return CGPreflightScreenCaptureAccess()
    }

    private func begin(reverse: Bool) {
        allItems = WindowList.build(mru: mru, showMin: profile.showMinimized)
        guard !allItems.isEmpty else { return }
        items = filtered()
        active = true
        selected = startIndex(reverse: reverse)
        applyGrouping()
        ui.filterBar = filterBarModel()
        ui.favorites = Favorites.enabled(profile) ? Favorites.sections(profile) : []
        ui.profileFor = { BrowserProfiles.shared.cached($0) }
        // Profili henüz bilinmeyen tarayıcı pencereleri: arka planda bul, bulununca kartları yenile
        BrowserProfiles.shared.resolve(allItems) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.active, self.ui.isVisible else { return }
                self.ui.show(self.items, selected: self.selected, thumbs: self.thumbCache)
            }
        }
        let previews = previewsOn
        ui.previews = previews
        ui.listMode = profile.list
        ui.groupedMode = profile.grouped && !profile.list
        ui.audioBadge = audioFor
        ui.prepare()

        // Artık olmayan pencerelerin önizlemelerini bellekten at.
        let live = Set(items.map(\.wid))
        thumbCache = thumbCache.filter { live.contains($0.key) }

        if previews, #available(macOS 14.0, *) {
            // Filtre panelde değişebilir: tüm pencerelerin önizlemeleri alınır (sıra: önce görünenler)
            let ordered = items + allItems.filter { a in !items.contains { $0.wid == a.wid && $0.pid == a.pid } }
            let wids = ordered.prefix(48).filter { $0.wid != 0 && !$0.minimized }.map(\.wid)
            let box = ui.thumbBox
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            captureTask = Task { [weak self] in
                await Thumbs.capture(wids, box: box, scale: scale) { wid, img in
                    guard let self, self.active else { return }
                    self.thumbCache[wid] = img
                    self.ui.updateThumb(wid, img)
                }
            }
        }

        // Çok hızlı Cmd+Tab'da (60 ms altı) panel hiç çizilmez, anında geçer.
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.active else { return }
                self.ui.show(self.items, selected: self.selected, thumbs: self.thumbCache)
            }
        }
        showWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
    }

    // MARK: Uygulama filtresi (ör. ⌥Tab sadece Chrome pencereleri)

    /// Filtrede seçilebilecek uygulamalar: listedeki sıraya göre, her uygulama bir kez
    private var filterApps: [NSRunningApplication] {
        var seen = Set<pid_t>(), out: [NSRunningApplication] = []
        for it in allItems where !it.system && it.app.bundleIdentifier != nil && !seen.contains(it.pid) {
            seen.insert(it.pid); out.append(it.app)
        }
        return out
    }

    /// F ile o an açılan geçici filtre (kaydedilmez, panel kapanınca biter). nil = ayardaki filtre, "" = hepsi
    private var sessionFilter: String?
    private var effectiveFilter: String { sessionFilter ?? profile.appFilter }

    /// Filtre uygulanmış liste. Seçili uygulamanın penceresi yoksa tüm pencereler gösterilir.
    private func filtered() -> [Item] {
        let f = effectiveFilter
        guard !f.isEmpty else { return allItems }
        let list = allItems.filter { $0.app.bundleIdentifier == f }
        return list.isEmpty ? allItems : list
    }

    private var filterActive: Bool {
        let f = effectiveFilter
        return !f.isEmpty && allItems.contains { $0.app.bundleIdentifier == f }
    }

    /// İlk seçim: listenin başı şu anki pencereyse bir sonrakinden başla (normal ⌘Tab gibi)
    private func startIndex(reverse: Bool) -> Int {
        guard items.count > 1 else { return 0 }
        if reverse { return items.count - 1 }
        if filterActive, items.first?.pid != NSWorkspace.shared.frontmostApplication?.processIdentifier { return 0 }
        return 1
    }

    private func filterBarModel() -> (names: [String], icons: [NSImage?], current: Int)? {
        guard filterActive else { return nil }
        let apps = filterApps
        let cur = apps.firstIndex { $0.bundleIdentifier == effectiveFilter }.map { $0 + 1 } ?? 0
        return ([L("Tümü")] + apps.map { $0.localizedName ?? "" }, [nil] + apps.map(\.icon), cur)
    }

    /// 0 = tüm uygulamalar, 1… = filterApps sırası
    private func setFilter(index: Int) {
        guard active else { return }
        let apps = filterApps
        let bid = index <= 0 || index > apps.count ? "" : (apps[index - 1].bundleIdentifier ?? "")
        // F ile geçici filtre açıksa geçici kalır; değilse seçim ayara kaydedilir (bir sonraki sefer de aynı)
        if sessionFilter != nil { sessionFilter = bid } else { profile.appFilter = bid }
        items = filtered()
        selected = startIndex(reverse: false)
        applyGrouping()
        ui.filterBar = filterBarModel()
        showWork?.cancel(); showWork = nil
        ui.show(items, selected: selected, thumbs: thumbCache)
    }

    /// Gruplu görünümde pencereleri bölüm sırasına diz (bölüm içinde en son kullanılan önce).
    /// Seçim aynı pencerede kalır: ⌘Tab'a hızlı basınca yine bir önceki pencereye geçilir.
    private func applyGrouping() {
        guard profile.grouped, !profile.list, items.count > 1 else { return }
        let keep = items.indices.contains(selected) ? items[selected] : nil
        items = items.enumerated()
            .sorted { a, b in
                let ga = GroupSettings.group(for: a.element.app).rawValue, gb = GroupSettings.group(for: b.element.app).rawValue
                return ga != gb ? ga < gb : a.offset < b.offset
            }
            .map { $0.element }
        if let keep, let i = items.firstIndex(where: { $0.pid == keep.pid && $0.wid == keep.wid && $0.title == keep.title }) {
            selected = i
        }
    }

    /// F: seçili kartın uygulamasının pencerelerine anında daralt; tekrar basınca hepsine dön.
    /// Geçicidir: ayara yazılmaz, panel kapanınca normale döner. Seçili pencere seçili kalır.
    private func toggleQuickFilter() {
        guard active, let it = current, let bid = it.app.bundleIdentifier else { return }
        sessionFilter = (filterActive && effectiveFilter == bid) ? "" : bid
        items = filtered()
        applyGrouping()
        selected = items.firstIndex { $0.pid == it.pid && $0.wid == it.wid && $0.title == it.title } ?? 0
        ui.filterBar = filterBarModel()
        showWork?.cancel(); showWork = nil
        ui.show(items, selected: selected, thumbs: thumbCache)
    }

    private func cycleFilter(_ d: Int) {
        let n = filterApps.count + 1
        guard n > 1 else { return }
        let cur = filterBarModel()?.current ?? 0
        setFilter(index: ((cur + d) % n + n) % n)
    }

    private func step(_ d: Int) {
        guard !items.isEmpty else { return }
        if selected < 0 { select(d > 0 ? 0 : items.count - 1); return }
        let n = selected + d
        select(((n % items.count) + items.count) % items.count)
    }

    /// Gruplu görünümde ←→ bölüm sütunları arasında, diğerlerinde sıradaki/önceki kart
    private func horizontal(_ d: Int) {
        if selected >= 0, ui.groupedMode, let n = ui.columnNeighbor(of: selected, delta: d) { select(n); return }
        step(d)
    }

    private func vertical(_ d: Int) {
        if selected < 0 || profile.list || ui.groupedMode { step(d); return }
        if let n = ui.neighbor(of: selected, rowDelta: d) { select(n) }
    }

    private func select(_ i: Int) {
        guard items.indices.contains(i) else { return }
        selected = i
        ui.setSelected(i)
    }

    private func commit() {
        guard active else { return }
        if selected < 0 { end(); return }   // seçim yoksa hiçbir yere geçme
        let item = items.indices.contains(selected) ? items[selected] : nil
        end()
        if let item { WindowList.focus(item) }
    }

    private func end() {
        active = false
        showWork?.cancel(); showWork = nil
        captureTask?.cancel(); captureTask = nil
        ui.hide()
        items = []
        allItems = []
        sessionFilter = nil
    }

    private var current: Item? { items.indices.contains(selected) ? items[selected] : nil }

    private func refresh() {
        if items.isEmpty { end(); return }
        selected = min(selected, items.count - 1)
        if ui.isVisible { ui.show(items, selected: selected, thumbs: thumbCache) }
    }

    private func quitSelected() {
        guard let it = current else { return }
        it.app.terminate()
        items.removeAll { $0.pid == it.pid }
        allItems.removeAll { $0.pid == it.pid }
        refresh()
    }

    private func closeSelected() {
        guard let it = current else { return }
        WindowList.close(it)
        items.remove(at: selected)
        allItems.removeAll { $0.pid == it.pid && $0.wid == it.wid }
        thumbCache[it.wid] = nil
        refresh()
    }

    private func minimizeSelected() {
        guard let it = current else { return }
        WindowList.minimize(it)
        if profile.showMinimized {
            items[selected].minimized = true
            if let k = allItems.firstIndex(where: { $0.pid == it.pid && $0.wid == it.wid }) { allItems[k].minimized = true }
        } else {
            items.remove(at: selected); thumbCache[it.wid] = nil
            allItems.removeAll { $0.pid == it.pid && $0.wid == it.wid }
        }
        refresh()
    }

    /// Karttaki kırmızı nokta: pencereyi kapat, panel açık kalsın
    private func closeItem(at i: Int) {
        guard active, items.indices.contains(i) else { return }
        selected = i
        closeSelected()
    }

    private func tileItem(at i: Int) {
        guard active, items.indices.contains(i) else { return }
        let it = items[i]
        end()
        onTileItem?(it)
    }

    /// Ekran bölme paneli için: taşınabilir pencereler, en son kullanılan önce
    func snapshotItems() -> [Item] {
        WindowList.build(mru: mru, showMin: true).filter { $0.window != nil && !$0.system }
    }

    private func cycleAudioSelected() {
        guard let it = current else { return }
        onCycleAudio?(it.app)
        if ui.isVisible { ui.show(items, selected: selected, thumbs: thumbCache) }
    }

    private func hideSelected() {
        guard let it = current else { return }
        it.app.hide()
        refresh()
    }
}

// MARK: - Arayüz (glassmorphism)

@MainActor final class SwitcherUI {
    static let radius: CGFloat = 26
    private let gap: CGFloat = 12, pad: CGFloat = 20
    private let titleH: CGFloat = 40, inset: CGFloat = 10
    private let listRowH: CGFloat = 58, listGap: CGFloat = 4

    var previews = true
    /// Liste görünümü: alt alta satırlar (ses listesi gibi)
    var listMode = false
    /// Gruplu görünüm: bölüm başlıkları altında kartlar
    var groupedMode = false
    private var headerViews: [NSView] = []
    private var preparedThumbH: CGFloat = 170
    private let groupHeaderH: CGFloat = 24, groupGap: CGFloat = 14
    /// Uygulamaya atanmış ses cihazı (simge, ad) — kartta rozet olarak gösterilir
    var audioBadge: ((NSRunningApplication) -> (symbol: String, name: String)?)?
    var onCloseItem: ((Int) -> Void)?
    var onTileItem: ((Int) -> Void)?
    /// Üstte uygulama filtresi çubuğu (nil = gösterme)
    var filterBar: (names: [String], icons: [NSImage?], current: Int)?
    var onPickFilter: ((Int) -> Void)?
    /// En sağda kenar çubuğu: sık kullanılan klasörler / Finder favorileri (boşsa gösterilmez)
    var favorites: [(title: String, items: [Favorites.Entry])] = []
    var onOpenFavorite: ((URL) -> Void)?
    /// Tarayıcı penceresinin profili (küçük rozet olarak gösterilir)
    var profileFor: ((Item) -> BrowserProfiles.Profile?)?
    private let sidebar = FavoritesSidebarView()
    private var sideExtra: CGFloat { favorites.isEmpty ? 0 : FavoritesSidebarView.width + 6 }
    private func sideMinH(_ screen: NSScreen) -> CGFloat {
        guard !favorites.isEmpty else { return 0 }
        return min(FavoritesSidebarView.neededHeight(favorites) + pad * 2 + headerH, screen.visibleFrame.height * 0.88)
    }
    /// cw: kartların kapladığı genişlik (sağ boşluk dahil); kenar çubuğu onun sağına
    private func placeSidebar(cw: CGFloat, h: CGFloat) {
        guard !favorites.isEmpty else { sidebar.removeFromSuperview(); return }
        sidebar.configure(favorites)
        sidebar.frame = NSRect(x: cw - pad / 2, y: pad, width: FavoritesSidebarView.width, height: h - pad * 2 - headerH)
        if sidebar.superview == nil { glass.addSubview(sidebar) }
    }
    private let barView = FilterBarView()
    private let barH: CGFloat = 30, barGap: CGFloat = 12
    private var headerH: CGFloat { filterBar == nil ? 0 : barH + barGap }
    /// Önizleme yüksekliği (ekrana göre ayarlanır); genişlik pencerenin oranına göre değişir.
    private(set) var thumbH: CGFloat = 170
    private var screen: NSScreen?
    /// Yakalanacak görüntünün sığacağı alan (nokta cinsinden).
    var thumbBox: CGSize { CGSize(width: thumbH * 2.0, height: thumbH) }

    private let panel: NSPanel
    private let glass = NSVisualEffectView()
    private let sheen = GlassSheen()
    private let tint = NSView()
    private var cells: [ItemCell] = []
    private var rows: [[Int]] = []
    private let onHover: (Int) -> Void
    private let onExit: (Int) -> Void
    private let onClick: (Int) -> Void
    var isVisible: Bool { panel.isVisible }

    // Liste görünümünde ekrana sığmayan uzun listeler için kayan pencere
    private var lastItems: [Item] = []
    private var lastThumbs: [CGWindowID: CGImage] = [:]
    private var visibleRange: Range<Int> = 0..<0

    init(onHover: @escaping (Int) -> Void, onExit: @escaping (Int) -> Void, onClick: @escaping (Int) -> Void) {
        self.onHover = onHover
        self.onExit = onExit
        self.onClick = onClick
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.acceptsMouseMovedEvents = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.sharingType = .none   // switcher'ın kendisi hiçbir ekran görüntüsüne girmez

        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.maskImage = Self.roundedMask(Self.radius)
        // Koyu ton: arkadaki masaüstü ne olursa olsun kartlar net okunsun
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.30).cgColor
        tint.autoresizingMask = [.width, .height]
        glass.addSubview(tint)
        sheen.autoresizingMask = [.width, .height]
        glass.addSubview(sheen)
        panel.contentView = glass
        barView.onPick = { [weak self] i in self?.onPickFilter?(i) }
        sidebar.onOpen = { [weak self] u in self?.onOpenFavorite?(u) }
    }

    /// Filtre çubuğunu panelin üstüne yerleştir; panel genişliği en az çubuk kadar olsun.
    private var minWidthForBar: CGFloat {
        guard let fb = filterBar else { return 0 }
        return FilterBarView.width(names: fb.names) + pad * 2
    }
    private func placeBar(w: CGFloat, h: CGFloat) {
        guard let fb = filterBar else { barView.removeFromSuperview(); return }
        barView.configure(names: fb.names, icons: fb.icons, current: fb.current)
        barView.frame = NSRect(x: pad, y: h - pad - barH, width: w - pad * 2, height: barH)
        if barView.superview == nil { glass.addSubview(barView) }
    }

    /// Pencere sunucusu tamponunu ve blur katmanını şimdiden oluştur:
    /// ilk ⌘Tab'da panel kurulumu beklenmesin.
    func prewarm() {
        panel.setFrame(NSRect(x: -10000, y: -10000, width: 400, height: 200), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.displayIfNeeded()
        panel.orderOut(nil)
        panel.alphaValue = 1
    }

    private static func roundedMask(_ r: CGFloat) -> NSImage {
        let s = r * 2 + 1
        let img = NSImage(size: NSSize(width: s, height: s), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        img.resizingMode = .stretch
        return img
    }

    /// Cmd+Tab basılınca: hangi ekranda açılacağını ve önizleme boyutunu belirle.
    func prepare() {
        let mouse = NSEvent.mouseLocation
        screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        let h = screen?.visibleFrame.height ?? 900
        if groupedMode {
            thumbH = previews ? (h * 0.17).clamped(110, 200).rounded() : 76
            preparedThumbH = thumbH
        } else {
            thumbH = (previews && !listMode) ? (h * 0.22).clamped(150, 260).rounded() : 76
        }
    }

    private func cellWidth(_ item: Item) -> CGFloat {
        guard previews else { return 156 }
        let w = (item.aspect * thumbH).clamped(thumbH * 0.75, thumbH * 2.0)
        return (w + inset * 2).rounded()
    }
    private var cellH: CGFloat { previews ? thumbH + titleH + inset : 168 }

    func show(_ items: [Item], selected: Int, thumbs: [CGWindowID: CGImage]) {
        lastItems = items
        lastThumbs = thumbs
        cells.forEach { $0.removeFromSuperview() }
        cells.removeAll(keepingCapacity: true)
        headerViews.forEach { $0.removeFromSuperview() }
        headerViews.removeAll()
        guard let screen else { return }

        ItemCell.armedAt = NSEvent.mouseLocation
        if listMode {
            layoutList(items, selected: selected, screen: screen)
        } else if groupedMode {
            layoutGrouped(items, thumbs: thumbs, screen: screen)
        } else {
            layoutGrid(items, thumbs: thumbs, screen: screen)
        }
        sheen.frame = glass.bounds
        tint.frame = glass.bounds
        setSelected(selected)

        if !panel.isVisible {
            panel.alphaValue = 1
            panel.orderFrontRegardless()   // animasyon yok: anında görünür
        }
        panel.invalidateShadow()
    }

    private func place(_ w: CGFloat, _ h: CGFloat, in screen: NSScreen) {
        let vf = screen.visibleFrame
        let scale = screen.backingScaleFactor
        // Tam piksele hizala → bulanıklık yok
        let x = ((vf.midX - w / 2) * scale).rounded() / scale
        let y = ((vf.midY - h / 2) * scale).rounded() / scale
        panel.setFrame(NSRect(x: x, y: y, width: w, height: h), display: false)
    }

    private func layoutGrid(_ items: [Item], thumbs: [CGWindowID: CGImage], screen: NSScreen) {
        let vf = screen.visibleFrame
        let scale = screen.backingScaleFactor

        // Satırlara yerleştir (pencere oranına göre değişken genişlik, AltTab gibi)
        let maxRowW = (vf.width * 0.92 - pad * 2 - sideExtra).rounded(.down)
        let maxRows = max(1, Int((vf.height * 0.88 - pad * 2 - headerH + gap) / (cellH + gap)))
        var rowList: [[Int]] = [[]]
        var widths: [CGFloat] = []
        var rowW: CGFloat = 0
        for i in items.indices {
            let w = min(cellWidth(items[i]), maxRowW)
            widths.append(w)
            if !rowList[rowList.count - 1].isEmpty && rowW + gap + w > maxRowW {
                if rowList.count == maxRows { break }
                rowList.append([]); rowW = 0
            }
            rowW += (rowList[rowList.count - 1].isEmpty ? 0 : gap) + w
            rowList[rowList.count - 1].append(i)
        }
        rows = rowList
        visibleRange = 0..<items.count
        func width(of row: [Int]) -> CGFloat { row.reduce(0) { $0 + widths[$1] } + CGFloat(max(0, row.count - 1)) * gap }

        let contentW = rows.map(width).max() ?? 0
        let cw = max(contentW + pad * 2, minWidthForBar - sideExtra).rounded()
        let w = cw + sideExtra
        let h = max(CGFloat(rows.count) * cellH + CGFloat(rows.count - 1) * gap + pad * 2 + headerH, sideMinH(screen)).rounded()
        place(w, h, in: screen)
        placeBar(w: w, h: h)
        placeSidebar(cw: cw, h: h)

        let mode: CellMode = previews ? .preview : .icon
        for (r, row) in rows.enumerated() {
            var cx = ((cw - width(of: row)) / 2).rounded()
            let cy = h - pad - headerH - CGFloat(r + 1) * cellH - CGFloat(r) * gap
            for i in row {
                let cell = ItemCell(frame: NSRect(x: cx, y: cy, width: widths[i], height: cellH),
                                    item: items[i], index: i, mode: mode,
                                    thumb: thumbs[items[i].wid], scale: scale,
                                    titleH: titleH, inset: inset,
                                    audio: audioBadge?(items[i].app),
                                    profile: profileFor?(items[i]))
                add(cell)
                cx += widths[i] + gap
            }
        }
    }

    /// Bölümlü görünüm: bölümler yan yana sütunlar (Tarayıcılar … Klasörler en sağda), aralarında ince çizgi.
    /// Her bölümde kartlar alt alta, sütun başına en fazla 2; fazlası bölüm içinde yan sütuna geçer.
    /// Toplam genişlik ekrana sığmazsa önizlemeler küçültülür.
    private var columns: [[Int]] = []
    static let cardsPerColumn = 2
    private func layoutGrouped(_ items: [Item], thumbs: [CGWindowID: CGImage], screen: NSScreen) {
        let vf = screen.visibleFrame
        let scale = screen.backingScaleFactor
        let maxW = (vf.width * 0.94 - pad * 2 - sideExtra).rounded(.down)
        let colGap: CGFloat = 12, secGap: CGFloat = 26   // sütun arası / bölüm arası (çizgi ortada)

        var sections: [(group: WindowGroup, idx: [Int])] = []
        for i in items.indices {
            let g = GroupSettings.group(for: items[i].app)
            if sections.last?.group == g { sections[sections.count - 1].idx.append(i) } else { sections.append((g, [i])) }
        }

        typealias Col = (idx: [Int], w: CGFloat, h: CGFloat)
        var laid: [(group: WindowGroup, count: Int, cols: [Col])] = []
        var widths: [Int: CGFloat] = [:]
        var totalW: CGFloat = 0, bodyH: CGFloat = 0
        thumbH = preparedThumbH   // her çizimde hazırlanan boydan başla (art arda küçülmesin)
        // Sığana kadar önizleme boyunu küçült
        for attempt in 0..<8 {
            if attempt > 0 { thumbH = max(80, (thumbH * 0.86).rounded()) }
            let maxColH = vf.height * 0.86 - pad * 2 - headerH - groupHeaderH
            laid.removeAll(); widths.removeAll()
            for s in sections {
                var cols: [Col] = [([], 0, 0)]
                for i in s.idx {
                    let w = min(cellWidth(items[i]), maxW)
                    widths[i] = w
                    var c = cols[cols.count - 1]
                    // Bir sütunda en fazla 2 kart (panel aşağı uzamasın); fazlası yan sütuna
                    if !c.idx.isEmpty && (c.idx.count >= Self.cardsPerColumn || c.h + gap + cellH > maxColH) {
                        cols.append(([], 0, 0)); c = cols[cols.count - 1]
                    }
                    c.h += (c.idx.isEmpty ? 0 : gap) + cellH
                    c.w = max(c.w, w)
                    c.idx.append(i)
                    cols[cols.count - 1] = c
                }
                laid.append((s.group, s.idx.count, cols))
            }
            let secW = laid.map { sec in sec.cols.reduce(0) { $0 + $1.w } + CGFloat(max(0, sec.cols.count - 1)) * colGap }
            totalW = secW.reduce(0, +) + CGFloat(max(0, laid.count - 1)) * secGap
            bodyH = laid.flatMap { $0.cols }.map { $0.h }.max() ?? cellH
            if totalW <= maxW || thumbH <= 80 || !previews { break }
        }

        // Sığmayan sütunlar kırpılır (çok nadir: çok fazla pencere)
        columns = laid.flatMap { $0.cols.map { $0.idx } }
        rows = columns                       // ↑↓ sütun içinde, ←→ sütunlar arası (bkz. neighbor)
        visibleRange = 0..<items.count

        let cw = max(min(totalW, maxW) + pad * 2, minWidthForBar - sideExtra, 300).rounded()
        let w = cw + sideExtra
        let h = max(bodyH + groupHeaderH + pad * 2 + headerH, sideMinH(screen)).rounded()
        place(w, h, in: screen)
        placeBar(w: w, h: h)
        placeSidebar(cw: cw, h: h)

        let mode: CellMode = previews ? .preview : .icon
        var x = pad + max(0, (cw - pad * 2 - totalW) / 2)
        let top = h - pad - headerH
        for (k, s) in laid.enumerated() {
            if k > 0 {
                // Bölüm ayırıcı: ince dikey çizgi
                let line = NSView(frame: NSRect(x: (x - secGap / 2).rounded(), y: pad, width: 1, height: top - pad))
                line.wantsLayer = true
                line.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.16).cgColor
                glass.addSubview(line)
                headerViews.append(line)
            }
            let secW = s.cols.reduce(0) { $0 + $1.w } + CGFloat(max(0, s.cols.count - 1)) * colGap
            let hv = Self.groupHeader(s.group, count: s.count)
            hv.frame = NSRect(x: x + 2, y: top - groupHeaderH + 3, width: max(secW, 120), height: groupHeaderH - 4)
            glass.addSubview(hv)
            headerViews.append(hv)
            var cx = x
            for col in s.cols {
                var y = top - groupHeaderH
                for i in col.idx {
                    y -= cellH
                    let cw = widths[i] ?? 156
                    let deco = GroupSettings.decoration(for: items[i])
                    let cell = ItemCell(frame: NSRect(x: cx + ((col.w - cw) / 2).rounded(), y: y, width: cw, height: cellH),
                                        item: items[i], index: i, mode: mode,
                                        thumb: thumbs[items[i].wid], scale: scale,
                                        titleH: titleH, inset: inset,
                                        audio: audioBadge?(items[i].app),
                                        folderName: deco.folder, project: deco.project,
                                        profile: profileFor?(items[i]))
                    add(cell)
                    y -= gap
                }
                cx += col.w + colGap
            }
            x += secW + secGap
        }
    }

    /// Gruplu görünümde ←→: komşu sütunda dikeyde en yakın kart
    func columnNeighbor(of i: Int, delta: Int) -> Int? {
        guard groupedMode, let c = columns.firstIndex(where: { $0.contains(i) }), columns.indices.contains(c + delta),
              let me = cells.first(where: { $0.index == i }) else { return nil }
        let my = me.frame.midY
        return columns[c + delta].min { a, b in
            let fa = cells.first { $0.index == a }?.frame.midY ?? 0
            let fb = cells.first { $0.index == b }?.frame.midY ?? 0
            return abs(fa - my) < abs(fb - my)
        }
    }

    /// Bölüm başlığı: simge + BÜYÜK HARF ad + sayı
    private static func groupHeader(_ g: WindowGroup, count: Int) -> NSView {
        let v = NSView()
        let img = NSImageView(frame: NSRect(x: 0, y: 2, width: 15, height: 15))
        img.image = NSImage(systemSymbolName: g.symbol, accessibilityDescription: g.title)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        img.contentTintColor = NSColor.white.withAlphaComponent(0.6)
        v.addSubview(img)
        let t = NSTextField(labelWithString: "\(g.title.uppercased(with: AppLanguage.active == .tr ? Locale(identifier: "tr_TR") : Locale(identifier: "en_US")))  \(count)")
        t.font = .systemFont(ofSize: 11.5, weight: .bold)
        t.textColor = NSColor.white.withAlphaComponent(0.6)
        t.frame = NSRect(x: 21, y: 1, width: 400, height: 16)
        v.addSubview(t)
        return v
    }

    private func layoutList(_ items: [Item], selected: Int, screen: NSScreen) {
        let vf = screen.visibleFrame
        let scale = screen.backingScaleFactor
        let maxRows = max(1, Int((vf.height * 0.8 - pad * 2 - headerH + listGap) / (listRowH + listGap)))
        let count = min(items.count, maxRows)
        var start = 0
        if items.count > count {
            start = min(max(0, selected - count / 2), items.count - count)
        }
        visibleRange = start..<(start + count)
        rows = visibleRange.map { [$0] }

        let cw = max(min(640, (vf.width * 0.9).rounded()), min(minWidthForBar - sideExtra, (vf.width * 0.9).rounded()))
        let w = cw + sideExtra
        let h = max(CGFloat(count) * listRowH + CGFloat(max(0, count - 1)) * listGap + pad * 2 + headerH, sideMinH(screen)).rounded()
        place(w, h, in: screen)
        placeBar(w: w, h: h)
        placeSidebar(cw: cw, h: h)

        for (k, i) in visibleRange.enumerated() {
            let y = h - pad - headerH - CGFloat(k + 1) * listRowH - CGFloat(k) * listGap
            let cell = ItemCell(frame: NSRect(x: pad, y: y, width: cw - pad * 2, height: listRowH),
                                item: items[i], index: i, mode: .list,
                                thumb: nil, scale: scale, titleH: titleH, inset: inset,
                                audio: audioBadge?(items[i].app),
                                profile: profileFor?(items[i]))
            add(cell)
        }
    }

    private func add(_ cell: ItemCell) {
        cell.onHover = onHover
        cell.onExit = onExit
        cell.onClick = onClick
        cell.onClose = onCloseItem
        cell.onTile = onTileItem
        glass.addSubview(cell)
        cells.append(cell)
    }

    /// Yukarı/aşağı ok: komşu satırda yatayda en yakın kart.
    func neighbor(of i: Int, rowDelta: Int) -> Int? {
        guard let r = rows.firstIndex(where: { $0.contains(i) }), rows.indices.contains(r + rowDelta),
              let me = cells.first(where: { $0.index == i }) else { return nil }
        let mx = me.frame.midX
        return rows[r + rowDelta].min { a, b in
            let fa = cells.first { $0.index == a }?.frame.midX ?? 0
            let fb = cells.first { $0.index == b }?.frame.midX ?? 0
            return abs(fa - mx) < abs(fb - mx)
        }
    }

    func updateThumb(_ wid: CGWindowID, _ img: CGImage) {
        lastThumbs[wid] = img
        for c in cells where c.wid == wid { c.setThumb(img) }
    }

    /// nil: nokta panelin dışında · true: bir kartın üstünde · false: paneldeki boşlukta
    func hitsCard(_ p: NSPoint) -> Bool? {
        guard panel.isVisible, panel.frame.contains(p) else { return nil }
        let local = NSPoint(x: p.x - panel.frame.minX, y: p.y - panel.frame.minY)
        if barView.superview != nil, barView.frame.contains(local) { return true }
        if sidebar.superview != nil, sidebar.frame.contains(local) { return true }
        return cells.contains { $0.frame.contains(local) }
    }

    func setSelected(_ i: Int) {
        // Liste görünümünde seçim görünen aralığın dışına çıktıysa listeyi kaydır
        if listMode, i >= 0, !visibleRange.contains(i), panel.isVisible, lastItems.indices.contains(i) {
            show(lastItems, selected: i, thumbs: lastThumbs)
            return
        }
        for c in cells { c.isSelected = (c.index == i) }
    }

    func hide() {
        panel.orderOut(nil)
        barView.removeFromSuperview()
        sidebar.removeFromSuperview()
        headerViews.forEach { $0.removeFromSuperview() }
        headerViews.removeAll()
        cells.forEach { $0.removeFromSuperview() }
        cells.removeAll()
        rows.removeAll()
        lastItems = []
        lastThumbs = [:]
        visibleRange = 0..<0
    }
}

extension CGFloat {
    func clamped(_ lo: CGFloat, _ hi: CGFloat) -> CGFloat { Swift.min(Swift.max(self, lo), hi) }
}

/// Camın üstündeki ışık yansıması + ince kenar.
final class GlassSheen: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        let g = CAGradientLayer()
        g.colors = [NSColor.white.withAlphaComponent(0.14).cgColor,
                    NSColor.white.withAlphaComponent(0.03).cgColor,
                    NSColor.clear.cgColor]
        g.locations = [0, 0.35, 1]
        g.startPoint = CGPoint(x: 0.5, y: 1)
        g.endPoint = CGPoint(x: 0.5, y: 0)
        g.cornerRadius = SwitcherUI.radius
        g.cornerCurve = .continuous
        g.borderWidth = 1
        g.borderColor = NSColor.white.withAlphaComponent(0.30).cgColor
        layer = g
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Pencere önizlemesi: görüntüyü oranını koruyarak sığdırır, köşelerini yuvarlar.
final class ThumbView: NSView {
    private let img = CALayer()
    private let scale: CGFloat

    init(frame: NSRect, scale: CGFloat) {
        self.scale = scale
        super.init(frame: frame)
        layer = CALayer()
        wantsLayer = true
        img.contentsGravity = .resize
        img.cornerCurve = .continuous
        img.contentsScale = scale
        img.minificationFilter = .trilinear
        img.magnificationFilter = .linear
        img.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(img)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func px(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale }

    func set(_ cg: CGImage, dimmed: Bool) {
        let b = bounds.size
        let iw = CGFloat(cg.width), ih = CGFloat(cg.height)
        guard iw > 0, ih > 0 else { return }
        let k = min(b.width / iw, b.height / ih)
        let sw = px(iw * k), sh = px(ih * k)
        img.frame = CGRect(x: px((b.width - sw) / 2), y: px((b.height - sh) / 2), width: sw, height: sh)
        img.contents = cg
        img.cornerRadius = 8
        img.masksToBounds = true
        img.borderWidth = 0.5
        img.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor
        img.opacity = dimmed ? 0.78 : 1
    }

    func placeholder(_ icon: NSImage?, dimmed: Bool) {
        let b = bounds.size
        let s: CGFloat = min(72, b.height * 0.6).rounded()
        img.frame = CGRect(x: px((b.width - s) / 2), y: px((b.height - s) / 2), width: s, height: s)
        img.contents = icon?.layerContents(forContentsScale: scale)
        img.cornerRadius = 0
        img.masksToBounds = false
        img.borderWidth = 0
        img.opacity = dimmed ? 0.7 : 1
    }
}

enum CellMode { case preview, icon, list }

final class ItemCell: NSView {
    static var armedAt: NSPoint = .zero   // panel açıldığında fare hareket etmeden seçim değişmesin
    let index: Int
    let wid: CGWindowID
    private let dimmed: Bool
    private var thumbView: ThumbView?
    var onHover: ((Int) -> Void)?
    var onExit: ((Int) -> Void)?
    var onClick: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onTile: ((Int) -> Void)?
    private var closeDot: DotView?
    private var tileDot: DotView?
    var isSelected = false { didSet { if oldValue != isSelected { updateLook() } } }

    static let dotSize: CGFloat = 15, dotGap: CGFloat = 6
    static var dotsWidth: CGFloat { dotSize * 2 + dotGap }

    init(frame: NSRect, item: Item, index: Int, mode: CellMode, thumb: CGImage?, scale: CGFloat,
         titleH: CGFloat, inset: CGFloat, audio: (symbol: String, name: String)?,
         folderName: String? = nil, project: String? = nil, profile: BrowserProfiles.Profile? = nil) {
        self.index = index
        self.wid = item.wid
        self.dimmed = item.minimized || item.app.isHidden || (item.window == nil && !item.system)
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = mode == .list ? 14 : 16
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = false

        let appName = item.app.localizedName ?? ""
        let hasDots = item.window != nil && !item.system
        let dotsW: CGFloat = hasDots ? Self.dotsWidth : 0
        let state: String
        if item.system { state = L("Sistem") }
        else if item.window == nil { state = L("Pencere yok") }
        else if item.minimized { state = L("Küçültülmüş") }
        else if item.app.isHidden { state = L("Gizli") }
        else { state = "" }

        switch mode {
        case .preview:
            // Üstte ikon + başlık (+ ses rozeti), altında büyük önizleme
            let top = frame.height - titleH
            let iconS: CGFloat = 28
            let icon = NSImageView(frame: NSRect(x: inset, y: top + (titleH - iconS) / 2, width: iconS, height: iconS))
            icon.image = item.app.icon
            icon.imageScaling = .scaleProportionallyUpOrDown
            addSubview(icon)

            var right = frame.width - inset
            if hasDots {
                addDots(x: right - dotsW, y: top + (titleH - Self.dotSize) / 2)
                right -= dotsW + 10
            }
            if let audio {
                let b = Self.badge(symbol: audio.symbol, name: audio.name, compact: frame.width < 320)
                b.frame.origin = NSPoint(x: right - b.frame.width, y: top + (titleH - b.frame.height) / 2)
                addSubview(b)
                right -= b.frame.width + 6
            }

            let shown = project ?? folderName ?? item.title
            let text = state.isEmpty ? shown : "\(shown) · \(state)"
            let title = label(text, size: 14, weight: .semibold, alpha: dimmed ? 0.75 : 1, align: .left)
            let tx = inset + iconS + 8
            title.frame = NSRect(x: tx, y: top + (titleH - 18) / 2, width: max(10, right - tx), height: 18)
            addSubview(title)

            let area = NSRect(x: inset, y: inset, width: frame.width - inset * 2, height: top - inset)
            if let folderName {
                // Klasör: önizleme yerine klasör simgesi + büyük ad
                addSubview(Self.folderCard(folderName, frame: area))
            } else {
                let tv = ThumbView(frame: area, scale: scale)
                addSubview(tv)
                thumbView = tv
                if let thumb { tv.set(thumb, dimmed: dimmed) } else { tv.placeholder(item.app.icon, dimmed: dimmed) }
                if let project { addSubview(Self.projectBand(project, app: item.app, in: area)) }
                else if let profile {
                    let b = Self.profileBadge(profile, maxWidth: area.width - 12)
                    b.frame.origin = NSPoint(x: area.minX + 6, y: area.minY + 6)
                    addSubview(b)
                }
            }

        case .icon:
            // Önizlemesiz: büyük ikon + başlık
            let iconS: CGFloat = 96
            let icon = NSImageView(frame: NSRect(x: (frame.width - iconS) / 2, y: frame.height - 14 - iconS, width: iconS, height: iconS))
            icon.image = item.app.icon
            icon.imageScaling = .scaleProportionallyUpOrDown
            if dimmed { icon.alphaValue = 0.7 }
            addSubview(icon)

            if let project {
                let b = Self.projectBand(project, app: item.app,
                                         in: NSRect(x: 6, y: 8, width: frame.width - 12, height: 60), compact: true)
                addSubview(b)
            }
            if project == nil {   // proje varsa adı renkli şeritte, ayrıca başlık yazılmaz
                let main = folderName ?? item.title
                let title = label(main, size: folderName != nil ? 15 : 14, weight: folderName != nil ? .bold : .semibold, alpha: 1, align: .center)
                title.frame = NSRect(x: 8, y: 30, width: frame.width - 16, height: 19)
                addSubview(title)

                if let profile, state.isEmpty {
                    let b = Self.profileBadge(profile, maxWidth: frame.width - 12)
                    b.frame.origin = NSPoint(x: ((frame.width - b.frame.width) / 2).rounded(), y: 9)
                    addSubview(b)
                } else {
                    let detail = state.isEmpty ? (main == appName ? "" : appName) : state
                    let sub = label(detail, size: 11.5, weight: .regular, alpha: 0.7, align: .center)
                    sub.frame = NSRect(x: 8, y: 12, width: frame.width - 16, height: 15)
                    addSubview(sub)
                }
            }

            if hasDots {
                addDots(x: frame.width - dotsW - 8, y: frame.height - Self.dotSize - 8)
            }
            if let audio {
                let b = Self.badge(symbol: audio.symbol, name: audio.name, compact: true)
                b.frame.origin = NSPoint(x: 6, y: frame.height - b.frame.height - 6)
                addSubview(b)
            }

        case .list:
            // Satır: ikon | başlık + uygulama adı | ses rozeti
            let iconS: CGFloat = 38
            let icon = NSImageView(frame: NSRect(x: 12, y: (frame.height - iconS) / 2, width: iconS, height: iconS))
            icon.image = item.app.icon
            icon.imageScaling = .scaleProportionallyUpOrDown
            if dimmed { icon.alphaValue = 0.7 }
            addSubview(icon)

            var right = frame.width - 12
            if hasDots {
                addDots(x: right - dotsW, y: (frame.height - Self.dotSize) / 2)
                right -= dotsW + 12
            }
            if let audio {
                let b = Self.badge(symbol: audio.symbol, name: audio.name, compact: false)
                b.frame.origin = NSPoint(x: right - b.frame.width, y: (frame.height - b.frame.height) / 2)
                addSubview(b)
                right -= b.frame.width + 10
            }

            let tx: CGFloat = 12 + iconS + 12
            let title = label(item.title, size: 14.5, weight: .semibold, alpha: dimmed ? 0.75 : 1, align: .left)
            title.frame = NSRect(x: tx, y: frame.height / 2 + 1, width: max(10, right - tx), height: 19)
            addSubview(title)

            var detail = item.title == appName ? "" : appName
            if let profile { detail = detail.isEmpty ? profile.name : "\(detail) · \(profile.name)" }
            if !state.isEmpty { detail = detail.isEmpty ? state : "\(detail) · \(state)" }
            let sub = label(detail, size: 11.5, weight: .regular, alpha: 0.65, align: .left)
            sub.frame = NSRect(x: tx, y: frame.height / 2 - 17, width: max(10, right - tx), height: 15)
            addSubview(sub)
        }
        updateLook()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Tarayıcı profili rozeti: küçük koyu kapsül, solda profil renginde nokta.
    /// Yazı doğrudan çizilir (etiket kutusunun iç boşluğu yüzünden kısalmasın).
    static func profileBadge(_ p: BrowserProfiles.Profile, maxWidth: CGFloat = 200) -> NSView {
        ProfileBadgeView(name: p.name, color: p.color ?? .controlAccentColor, maxWidth: maxWidth)
    }

    /// Klasör kartı: önizleme alanında klasör simgesi ve büyük klasör adı
    static func folderCard(_ name: String, frame: NSRect) -> NSView {
        let v = NSView(frame: frame)
        v.wantsLayer = true
        v.layer?.cornerRadius = 10
        v.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.07).cgColor
        let iconS = min(64, frame.height * 0.42)
        let icon = NSImageView(frame: NSRect(x: (frame.width - iconS) / 2, y: frame.height * 0.52, width: iconS, height: iconS))
        icon.image = NSImage(named: NSImage.folderName)
        icon.imageScaling = .scaleProportionallyUpOrDown
        v.addSubview(icon)
        let t = NSTextField(labelWithString: name)
        t.font = .systemFont(ofSize: min(30, max(18, frame.height * 0.16)), weight: .bold)
        t.textColor = .white
        t.alignment = .center
        t.lineBreakMode = .byTruncatingMiddle
        t.maximumNumberOfLines = 2
        t.frame = NSRect(x: 10, y: frame.height * 0.10, width: frame.width - 20, height: frame.height * 0.38)
        v.addSubview(t)
        return v
    }

    /// Proje adı şeridi: önizlemenin altında uygulamaya özgü renkte, büyük ve net yazı.
    /// Üstte küçük uygulama adı, altında proje adı (sığmazsa iki satır, sonra küçülür).
    static func projectBand(_ name: String, app: NSRunningApplication, in area: NSRect, compact: Bool = false) -> NSView {
        let color = GroupSettings.color(for: app)
        let w = area.width - (compact ? 0 : 12)
        let textW = w - 24
        // Yazı boyutu: önce 20 pt tek satır, sığmazsa iki satır, yine sığmazsa küçült
        var size: CGFloat = compact ? 15 : min(22, max(16, area.height * 0.14))
        func lines(_ s: CGFloat) -> CGFloat {
            let r = (name as NSString).boundingRect(with: NSSize(width: textW, height: 1000),
                                                    options: [.usesLineFragmentOrigin],
                                                    attributes: [.font: NSFont.systemFont(ofSize: s, weight: .heavy)])
            return ceil(r.height / (s * 1.2))
        }
        while size > 12 && lines(size) > 2 { size -= 1 }
        let lineCount = min(2, lines(size))
        let nameH = ceil(size * 1.22) * lineCount
        let capH: CGFloat = compact ? 0 : 14
        let h = nameH + capH + (compact ? 10 : 14)

        let v = NSView(frame: NSRect(x: area.minX + (compact ? 0 : 6), y: area.minY + (compact ? 0 : 6), width: w, height: h))
        v.wantsLayer = true
        v.layer?.cornerRadius = compact ? 9 : 11
        v.layer?.cornerCurve = .continuous
        v.layer?.backgroundColor = color.withAlphaComponent(0.92).cgColor
        v.layer?.borderWidth = 1
        v.layer?.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor
        v.layer?.shadowColor = NSColor.black.cgColor
        v.layer?.shadowOpacity = 0.45
        v.layer?.shadowRadius = 6
        v.layer?.shadowOffset = CGSize(width: 0, height: -2)
        v.toolTip = name

        if !compact {
            let cap = NSTextField(labelWithString: (app.localizedName ?? "").uppercased())
            cap.font = .systemFont(ofSize: 9.5, weight: .bold)
            cap.textColor = NSColor.white.withAlphaComponent(0.85)
            cap.lineBreakMode = .byTruncatingTail
            cap.frame = NSRect(x: 12, y: h - 7 - 12, width: textW, height: 12)
            v.addSubview(cap)
        }
        let t = NSTextField(wrappingLabelWithString: name)
        t.font = .systemFont(ofSize: size, weight: .heavy)
        t.textColor = .white
        t.alignment = compact ? .center : .left
        t.maximumNumberOfLines = 2
        t.lineBreakMode = .byWordWrapping
        t.cell?.truncatesLastVisibleLine = true
        t.frame = NSRect(x: 12, y: (compact ? 5 : 6), width: textW, height: nameH)
        v.addSubview(t)
        return v
    }

    /// Sağ üst: kırmızı kapat noktası + sağında bölme düğmesi
    private func addDots(x: CGFloat, y: CGFloat) {
        let c = DotView(kind: .close, frame: NSRect(x: x, y: y, width: Self.dotSize, height: Self.dotSize))
        let t = DotView(kind: .tile, frame: NSRect(x: x + Self.dotSize + Self.dotGap, y: y, width: Self.dotSize, height: Self.dotSize))
        c.toolTip = L("Pencereyi kapat")
        t.toolTip = L("Ekranın bir bölmesine taşı")
        addSubview(c)
        addSubview(t)
        closeDot = c
        tileDot = t
    }

    private func dot(at event: NSEvent) -> DotView.Kind? {
        let p = convert(event.locationInWindow, from: nil)
        if let d = closeDot, d.frame.insetBy(dx: -4, dy: -4).contains(p) { return .close }
        if let d = tileDot, d.frame.insetBy(dx: -4, dy: -4).contains(p) { return .tile }
        return nil
    }

    private func updateDotHover(_ event: NSEvent?) {
        let k = event.flatMap { dot(at: $0) }
        closeDot?.hovered = (k == .close)
        tileDot?.hovered = (k == .tile)
    }

    /// Uygulamaya atanmış ses cihazı rozeti (cam kapsül).
    static func badge(symbol: String, name: String, compact: Bool) -> NSView {
        let h: CGFloat = 22
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.16).cgColor
        v.layer?.cornerRadius = h / 2
        v.layer?.borderWidth = 0.5
        v.layer?.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor
        v.toolTip = L("Ses: %@", name)

        let img = NSImageView(frame: NSRect(x: 7, y: 4, width: 14, height: 14))
        img.image = NSImage(systemSymbolName: symbol, accessibilityDescription: name)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        img.contentTintColor = .white
        img.imageScaling = .scaleProportionallyUpOrDown
        v.addSubview(img)

        var w: CGFloat = 28
        if !compact {
            let t = NSTextField(labelWithString: name)
            t.font = .systemFont(ofSize: 11, weight: .medium)
            t.textColor = NSColor.white.withAlphaComponent(0.92)
            t.lineBreakMode = .byTruncatingTail
            t.maximumNumberOfLines = 1
            let tw = min(ceil(t.intrinsicContentSize.width), 130)
            t.frame = NSRect(x: 25, y: 3, width: tw, height: 15)
            v.addSubview(t)
            w = 25 + tw + 9
        }
        v.frame = NSRect(x: 0, y: 0, width: w, height: h)
        return v
    }

    private func label(_ s: String, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat, align: NSTextAlignment) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = .systemFont(ofSize: size, weight: weight)
        t.textColor = NSColor.white.withAlphaComponent(alpha)
        t.alignment = align
        t.lineBreakMode = .byTruncatingTail
        t.maximumNumberOfLines = 1
        return t
    }

    func setThumb(_ img: CGImage) { thumbView?.set(img, dimmed: dimmed) }

    /// Seçili kart: parlak zemin + vurgu renginde kalın çerçeve + hafif ışıma.
    /// Diğer kartlar: ince cam zemin, böylece her kart ayrı bir hedef olarak görünür.
    private func updateLook() {
        guard let layer else { return }
        let accent = NSColor.controlAccentColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if isSelected {
            layer.backgroundColor = NSColor.white.withAlphaComponent(0.22).cgColor
            layer.borderWidth = 2.5
            layer.borderColor = accent.cgColor
            layer.shadowColor = accent.cgColor
            layer.shadowOpacity = 0.75
            layer.shadowRadius = 14
            layer.shadowOffset = .zero
        } else {
            layer.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
            layer.borderWidth = 1
            layer.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor
            layer.shadowOpacity = 0
        }
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
    private var moved: Bool { NSEvent.mouseLocation != ItemCell.armedAt }
    override func mouseEntered(with event: NSEvent) {
        updateDotHover(event)
        if moved { onHover?(index) }
    }
    override func mouseMoved(with event: NSEvent) {
        updateDotHover(event)
        if !isSelected && moved { onHover?(index) }
    }
    override func mouseExited(with event: NSEvent) {
        updateDotHover(nil)
        if moved { onExit?(index) }
    }
    override func mouseUp(with event: NSEvent) {
        switch dot(at: event) {
        case .close?: onClose?(index)
        case .tile?: onTile?(index)
        case nil: onClick?(index)
        }
    }
    override func mouseDown(with event: NSEvent) {}
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
}


/// Profil rozeti: koyu kapsül + renkli nokta + ad (gerekirse "…" ile kısalır, ama ad sığıyorsa tam yazar)
final class ProfileBadgeView: NSView {
    private let name: String
    private let color: NSColor
    private static let font = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
    private static let h: CGFloat = 18

    init(name: String, color: NSColor, maxWidth: CGFloat) {
        self.name = name
        self.color = color
        let tw = ceil((name as NSString).size(withAttributes: [.font: Self.font]).width)
        let w = min(max(40, maxWidth), tw + 27)
        super.init(frame: NSRect(x: 0, y: 0, width: w, height: Self.h))
        toolTip = name
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // tıklamayı kart yönetir

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.25, dy: 0.25)
        let pill = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        NSColor.black.withAlphaComponent(0.58).setFill(); pill.fill()
        NSColor.white.withAlphaComponent(0.28).setStroke(); pill.lineWidth = 0.5; pill.stroke()
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: 7, y: (bounds.height - 7) / 2, width: 7, height: 7)).fill()
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: NSColor.white.withAlphaComponent(0.95)]
        let sz = (name as NSString).size(withAttributes: attrs)
        (name as NSString).draw(with: NSRect(x: 18, y: (bounds.height - sz.height) / 2, width: bounds.width - 24, height: sz.height),
                                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
    }
}

/// Panelin üstündeki uygulama filtresi: "Tümü · Chrome · Kod Düzenleyici …" çipleri.
final class FilterBarView: NSView {
    var onPick: ((Int) -> Void)?
    private var names: [String] = []
    private var icons: [NSImage?] = []
    private var current = 0
    private var rects: [NSRect] = []

    static let font = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
    static let hint = "é · A ⇄"
    private static let chipH: CGFloat = 28, iconS: CGFloat = 18, padX: CGFloat = 11, spacing: CGFloat = 6

    static func chipWidth(_ name: String, icon: Bool) -> CGFloat {
        let tw = min(150, (name as NSString).size(withAttributes: [.font: font]).width)
        return ceil(tw + padX * 2 + (icon ? iconS + 6 : 0))
    }
    static func width(names: [String]) -> CGFloat {
        let chips = names.enumerated().reduce(CGFloat(0)) { $0 + chipWidth($1.element, icon: $1.offset > 0) }
        let hintW = (hint as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium)]).width + 14
        return chips + CGFloat(max(0, names.count - 1)) * spacing + hintW
    }

    func configure(names: [String], icons: [NSImage?], current: Int) {
        self.names = names; self.icons = icons; self.current = current
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        rects.removeAll()
        let hintAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .medium),
                                                        .foregroundColor: NSColor.white.withAlphaComponent(0.45)]
        let hintW = (Self.hint as NSString).size(withAttributes: hintAttrs).width
        let total = Self.width(names: names)
        var x = max(0, (bounds.width - total) / 2)
        let y = (bounds.height - Self.chipH) / 2
        for (i, n) in names.enumerated() {
            let hasIcon = i > 0
            let w = Self.chipWidth(n, icon: hasIcon)
            let r = NSRect(x: x, y: y, width: w, height: Self.chipH)
            rects.append(r)
            let path = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: Self.chipH / 2, yRadius: Self.chipH / 2)
            if i == current {
                NSColor.white.withAlphaComponent(0.22).setFill(); path.fill()
                NSColor.controlAccentColor.setStroke(); path.lineWidth = 1.5; path.stroke()
            } else {
                NSColor.white.withAlphaComponent(0.08).setFill(); path.fill()
            }
            var tx = r.minX + Self.padX
            if hasIcon, let img = icons[safe: i] ?? nil {
                img.draw(in: NSRect(x: tx, y: r.midY - Self.iconS / 2, width: Self.iconS, height: Self.iconS))
                tx += Self.iconS + 6
            }
            let attrs: [NSAttributedString.Key: Any] = [.font: Self.font,
                .foregroundColor: NSColor.white.withAlphaComponent(i == current ? 1 : 0.7)]
            let s = n as NSString
            let sz = s.size(withAttributes: attrs)
            s.draw(with: NSRect(x: tx, y: r.midY - sz.height / 2, width: min(150, sz.width), height: sz.height),
                   options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
            x += w + Self.spacing
        }
        (Self.hint as NSString).draw(at: NSPoint(x: x + 8, y: (bounds.height - 13) / 2), withAttributes: hintAttrs)
        _ = hintW
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let i = rects.firstIndex(where: { $0.contains(p) }) { onPick?(i) }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// macOS pencere düğmesi gibi küçük yuvarlak düğme (kırmızı kapat / bölme).
final class DotView: NSView {
    enum Kind { case close, tile }
    let kind: Kind
    var hovered = false { didSet { if oldValue != hovered { needsDisplay = true } } }

    init(kind: Kind, frame: NSRect) {
        self.kind = kind
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // tıklamayı kart yönetir

    override func draw(_ dirtyRect: NSRect) {
        let b = bounds.insetBy(dx: 0.5, dy: 0.5)
        let circle = NSBezierPath(ovalIn: b)
        switch kind {
        case .close:
            NSColor(srgbRed: 1.0, green: 0.37, blue: 0.34, alpha: 1).setFill()
            circle.fill()
            NSColor(srgbRed: 0.85, green: 0.23, blue: 0.2, alpha: 1).setStroke()
            circle.lineWidth = 0.75
            circle.stroke()
            if hovered {
                let x = NSBezierPath()
                let i = b.width * 0.3
                x.move(to: NSPoint(x: b.minX + i, y: b.minY + i))
                x.line(to: NSPoint(x: b.maxX - i, y: b.maxY - i))
                x.move(to: NSPoint(x: b.minX + i, y: b.maxY - i))
                x.line(to: NSPoint(x: b.maxX - i, y: b.minY + i))
                x.lineWidth = 1.5
                x.lineCapStyle = .round
                NSColor(srgbRed: 0.45, green: 0.05, blue: 0.03, alpha: 0.9).setStroke()
                x.stroke()
            }
        case .tile:
            NSColor.white.withAlphaComponent(hovered ? 0.6 : 0.3).setFill()
            circle.fill()
            NSColor.white.withAlphaComponent(0.35).setStroke()
            circle.lineWidth = 0.75
            circle.stroke()
            // iki bölmeli ekran simgesi
            let gw = b.width * 0.26, gh = b.height * 0.42, gap = b.width * 0.06
            let y0 = b.midY - gh / 2
            let left = NSRect(x: b.midX - gap / 2 - gw, y: y0, width: gw, height: gh)
            let right = NSRect(x: b.midX + gap / 2, y: y0, width: gw, height: gh)
            NSColor.black.withAlphaComponent(hovered ? 0.8 : 0.6).setFill()
            NSBezierPath(roundedRect: left, xRadius: 1, yRadius: 1).fill()
            NSBezierPath(roundedRect: right, xRadius: 1, yRadius: 1).fill()
        }
    }
}
