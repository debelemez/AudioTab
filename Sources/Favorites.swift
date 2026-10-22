import Cocoa

// MARK: - ⌘Tab kenar çubuğu: sık kullanılan klasörler + Finder favorileri
//
// İsteğe bağlı. Açıksa ⌘Tab panelinin en sağında Finder'ın kenar çubuğu gibi bir liste çıkar.
// Bir öğeye tıklayınca klasör Finder'da açılır ve panel kapanır.

enum Favorites {
    private static let d = UserDefaults.standard

    /// Kendi sık kullanılan klasörlerimiz (Ayarlar'dan eklenir)
    static var showOwn: Bool {
        get { d.object(forKey: "favorites.own") as? Bool ?? false }
        set { d.set(newValue, forKey: "favorites.own") }
    }
    /// Finder kenar çubuğundaki Favoriler
    static var showFinder: Bool {
        get { d.object(forKey: "favorites.finder") as? Bool ?? false }
        set { d.set(newValue, forKey: "favorites.finder") }
    }
    static var enabled: Bool { showOwn || showFinder }

    /// Sık kullanılan klasörlerin yolları (sırasıyla)
    static var folders: [String] {
        get { d.stringArray(forKey: "favorites.folders") ?? [] }
        set { d.set(newValue, forKey: "favorites.folders") }
    }

    static func add(_ urls: [URL]) {
        var list = folders
        for u in urls where !list.contains(u.path) { list.append(u.path) }
        folders = list
    }
    static func remove(_ path: String) { folders.removeAll { $0 == path } }

    struct Entry {
        let name: String
        let url: URL
    }

    /// Kenar çubuğu bölümleri (boş bölümler gösterilmez)
    static func sections() -> [(title: String, items: [Entry])] {
        var out: [(String, [Entry])] = []
        if showOwn {
            let own = folders.compactMap { p -> Entry? in
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue else { return nil }
                let u = URL(fileURLWithPath: p)
                return Entry(name: FileManager.default.displayName(atPath: p), url: u)
            }
            if !own.isEmpty { out.append((L("Sık kullanılanlar"), own)) }
        }
        if showFinder {
            let fav = finderFavorites()
            if !fav.isEmpty { out.append((L("Favoriler"), fav)) }
        }
        return out
    }

    // MARK: Finder favorileri

    private static var cache: (date: Date, items: [Entry])?

    /// Finder kenar çubuğundaki Favoriler: Finder'ın kendi liste dosyasından okunur;
    /// okunamazsa varsayılan klasörler (Uygulamalar, Masaüstü, Belgeler, İndirilenler, Ana klasör).
    static func finderFavorites() -> [Entry] {
        if let c = cache, Date().timeIntervalSince(c.date) < 30 { return c.items }
        var items = fromSFL()
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
                if let vis = it["visibility"] as? Int, vis != 0 { continue }     // gizlenmiş öğe
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
