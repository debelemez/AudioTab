import Cocoa

// MARK: - ⌘Tab kenar çubuğu: sık kullanılan klasörler + Finder favorileri
//
// İsteğe bağlı. Açıksa ⌘Tab panelinin en sağında Finder'ın kenar çubuğu gibi bir liste çıkar.
// Bir öğeye tıklayınca klasör Finder'da açılır ve panel kapanır.

enum Favorites {
    private static let d = UserDefaults.standard

    // ⌘Tab ve ⌥Tab için ayrı ayrı: "cmd.favorites.own", "opt.favorites.folders"…
    // İlk açılışta 2.3.9'daki ortak ayar (varsa) iki kısayola da başlangıç değeri olur.
    private static func key(_ p: Profile, _ k: String) -> String { "\(p.rawValue).favorites.\(k)" }

    /// Kendi sık kullanılan klasörlerimiz (Ayarlar'dan eklenir)
    static func showOwn(_ p: Profile) -> Bool {
        d.object(forKey: key(p, "own")) as? Bool ?? d.object(forKey: "favorites.own") as? Bool ?? false
    }
    static func setShowOwn(_ v: Bool, _ p: Profile) { d.set(v, forKey: key(p, "own")) }

    /// Finder kenar çubuğundaki Favoriler
    static func showFinder(_ p: Profile) -> Bool {
        d.object(forKey: key(p, "finder")) as? Bool ?? d.object(forKey: "favorites.finder") as? Bool ?? false
    }
    static func setShowFinder(_ v: Bool, _ p: Profile) { d.set(v, forKey: key(p, "finder")) }

    static func enabled(_ p: Profile) -> Bool { showOwn(p) || showFinder(p) }

    /// Sık kullanılan klasörlerin yolları (sırasıyla)
    static func folders(_ p: Profile) -> [String] {
        d.stringArray(forKey: key(p, "folders")) ?? d.stringArray(forKey: "favorites.folders") ?? []
    }
    static func setFolders(_ v: [String], _ p: Profile) { d.set(v, forKey: key(p, "folders")) }

    static func add(_ urls: [URL], to p: Profile) {
        var list = folders(p)
        for u in urls where !list.contains(u.path) { list.append(u.path) }
        setFolders(list, p)
    }
    static func remove(_ path: String, from p: Profile) { setFolders(folders(p).filter { $0 != path }, p) }

    struct Entry {
        let name: String
        let url: URL
    }

    /// Kenar çubuğu bölümleri (boş bölümler gösterilmez)
    static func sections(_ p: Profile) -> [(title: String, items: [Entry])] {
        var out: [(String, [Entry])] = []
        if showOwn(p) {
            let own = folders(p).compactMap { p -> Entry? in
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue else { return nil }
                let u = URL(fileURLWithPath: p)
                return Entry(name: FileManager.default.displayName(atPath: p), url: u)
            }
            if !own.isEmpty { out.append((L("Sık kullanılanlar"), own)) }
        }
        if showFinder(p) {
            let fav = finderFavorites()
            if !fav.isEmpty { out.append((L("Favoriler"), fav)) }
        }
        return out
    }

    // MARK: Finder favorileri

    private static var cache: (date: Date, items: [Entry])?

    /// Finder kenar çubuğundaki Favoriler, Finder'daki sırayla. Önce sistemin canlı listesi,
    /// olmazsa Finder'ın liste dosyası, o da olmazsa varsayılan klasörler.
    static func finderFavorites() -> [Entry] {
        if let c = cache, Date().timeIntervalSince(c.date) < 10 { return c.items }
        // 1) Finder'ın kullandığı sistem listesi (canlı, Finder'daki sırayla)
        var items = fromSharedFileList()
        // 2) Olmazsa Finder'ın liste dosyası
        if items.isEmpty { items = fromSFL() }
        // 3) O da olmazsa varsayılan klasörler
        if items.isEmpty { items = defaults() }
        cache = (Date(), items)
        return items
    }

    /// ~/Library/Application Support/com.apple.sharedfilelist/…FavoriteItems.sfl3 (ya da .sfl2)
    private static func fromSFL() -> [Entry] {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.sharedfilelist", isDirectory: true)
        for ext in ["sfl3", "sfl2"] {
            let f = dir.appendingPathComponent("com.apple.LSSharedFileList.FavoriteItems.\(ext)")
            guard let data = try? Data(contentsOf: f) else { continue }
            guard let un = try? NSKeyedUnarchiver(forReadingFrom: data) else { continue }
            un.requiresSecureCoding = false
            un.decodingFailurePolicy = .setErrorAndReturn   // bilinmeyen sınıf varsa çökme, boş dön
            let root = (try? un.decodeTopLevelObject(forKey: NSKeyedArchiveRootObjectKey)) as? NSDictionary
            un.finishDecoding()
            guard let arr = root?["items"] as? [NSDictionary] else { continue }
            var out: [Entry] = []
            for it in arr {
                guard let bm = it["Bookmark"] as? Data else { continue }
                var stale = false
                guard let url = try? URL(resolvingBookmarkData: bm, options: [.withoutUI, .withoutMounting],
                                         relativeTo: nil, bookmarkDataIsStale: &stale),
                      url.isFileURL else { continue }
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { continue }
                out.append(Entry(name: FileManager.default.displayName(atPath: url.path), url: url))
            }
            if !out.isEmpty { return out }
        }
        return []
    }

    /// Finder kenar çubuğu Favorileri, sistemin paylaşılan liste servisi üzerinden.
    /// Bu arayüz eski (derleme uyarısı vermesin diye çalışma anında bulunur) ama Finder hâlâ bunu kullanıyor.
    private static func fromSharedFileList() -> [Entry] {
        typealias CreateFn = @convention(c) (CFAllocator?, CFString, CFTypeRef?) -> Unmanaged<AnyObject>?
        typealias SnapshotFn = @convention(c) (AnyObject, UnsafeMutablePointer<UInt32>?) -> Unmanaged<CFArray>?
        typealias ResolveFn = @convention(c) (AnyObject, UInt32, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        typealias NameFn = @convention(c) (AnyObject) -> Unmanaged<CFString>?

        guard let h = dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_LAZY),
              let pCreate = dlsym(h, "LSSharedFileListCreate"),
              let pSnap = dlsym(h, "LSSharedFileListCopySnapshot"),
              let pResolve = dlsym(h, "LSSharedFileListItemCopyResolvedURL"),
              let pName = dlsym(h, "LSSharedFileListItemCopyDisplayName"),
              let pKind = dlsym(h, "kLSSharedFileListFavoriteItems") else { return [] }
        let create = unsafeBitCast(pCreate, to: CreateFn.self)
        let snapshot = unsafeBitCast(pSnap, to: SnapshotFn.self)
        let resolve = unsafeBitCast(pResolve, to: ResolveFn.self)
        let displayName = unsafeBitCast(pName, to: NameFn.self)
        let kind = pKind.assumingMemoryBound(to: CFString.self).pointee

        guard let list = create(nil, kind, nil)?.takeRetainedValue() else { return [] }
        var seed: UInt32 = 0
        guard let snap = snapshot(list, &seed)?.takeRetainedValue() as? [AnyObject] else { return [] }
        let flags: UInt32 = 1 | 2    // kullanıcıya sorma | disk bağlama
        var out: [Entry] = []
        for item in snap {
            guard let cf = resolve(item, flags, nil)?.takeRetainedValue() else { continue }
            let url = cf as URL
            guard url.isFileURL else { continue }        // AirDrop, Son Kullanılanlar gibi özel öğeler hariç
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let name = (displayName(item)?.takeRetainedValue() as String?) ?? FileManager.default.displayName(atPath: url.path)
            out.append(Entry(name: name, url: url))
        }
        return out
    }

    private static func defaults() -> [Entry] {
        let fm = FileManager.default
        let dirs: [FileManager.SearchPathDirectory] = [.applicationDirectory, .desktopDirectory, .documentDirectory, .downloadsDirectory]
        var out = dirs.compactMap { d -> Entry? in
            guard let u = fm.urls(for: d, in: d == .applicationDirectory ? .localDomainMask : .userDomainMask).first else { return nil }
            return Entry(name: fm.displayName(atPath: u.path), url: u)
        }
        let home = fm.homeDirectoryForCurrentUser
        out.append(Entry(name: fm.displayName(atPath: home.path), url: home))
        return out
    }
}

// MARK: - Kenar çubuğu görünümü (Finder'ın kenar çubuğu gibi)

final class FavoritesSidebarView: NSView {
    var onOpen: ((URL) -> Void)?
    private var rows: [(rect: NSRect, url: URL)] = []
    private var sections: [(title: String, items: [Favorites.Entry])] = []
    private var hovered: Int? { didSet { if oldValue != hovered { needsDisplay = true } } }
    private var tracking: NSTrackingArea?

    static let width: CGFloat = 210
    static let rowH: CGFloat = 26, headerH: CGFloat = 24, sectionGap: CGFloat = 10

    static func neededHeight(_ sections: [(title: String, items: [Favorites.Entry])]) -> CGFloat {
        guard !sections.isEmpty else { return 0 }
        return sections.reduce(0) { $0 + headerH + CGFloat($1.items.count) * rowH } + CGFloat(sections.count - 1) * sectionGap + 8
    }

    func configure(_ s: [(title: String, items: [Favorites.Entry])]) {
        sections = s
        hovered = nil
        needsDisplay = true
    }

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func draw(_ dirtyRect: NSRect) {
        rows.removeAll()
        // Sol kenarda ince ayırıcı çizgi
        NSColor.white.withAlphaComponent(0.16).setFill()
        NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()

        let x0: CGFloat = 14
        var y: CGFloat = 4
        let headAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .bold),
                                                        .foregroundColor: NSColor.white.withAlphaComponent(0.5)]
        let nameAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .medium),
                                                        .foregroundColor: NSColor.white.withAlphaComponent(0.92)]
        for (k, s) in sections.enumerated() {
            if k > 0 { y += Self.sectionGap }
            let loc = Locale(identifier: AppLanguage.active == .tr ? "tr_TR" : "en_US")
            (s.title.uppercased(with: loc) as NSString).draw(at: NSPoint(x: x0, y: y + 5), withAttributes: headAttrs)
            y += Self.headerH
            for it in s.items {
                guard y + Self.rowH <= bounds.height else { return }
                let r = NSRect(x: 6, y: y, width: bounds.width - 10, height: Self.rowH)
                let i = rows.count
                rows.append((r, it.url))
                if hovered == i {
                    NSColor.white.withAlphaComponent(0.16).setFill()
                    NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7).fill()
                }
                let icon = NSWorkspace.shared.icon(forFile: it.url.path)
                icon.draw(in: NSRect(x: r.minX + 8, y: r.midY - 9, width: 18, height: 18), from: .zero, operation: .sourceOver,
                          fraction: 1, respectFlipped: true, hints: nil)
                let s = it.name as NSString
                let sz = s.size(withAttributes: nameAttrs)
                s.draw(with: NSRect(x: r.minX + 34, y: r.midY - sz.height / 2, width: r.width - 40, height: sz.height),
                       options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: nameAttrs)
                y += Self.rowH
            }
        }
    }

    private func row(at e: NSEvent) -> Int? {
        let p = convert(e.locationInWindow, from: nil)
        return rows.firstIndex { $0.rect.contains(p) }
    }

    override func mouseMoved(with event: NSEvent) { hovered = row(at: event) }
    override func mouseExited(with event: NSEvent) { hovered = nil }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if let i = row(at: event) { onOpen?(rows[i].url) }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
