import Cocoa

// MARK: - Tarayıcı penceresinin profili (Chrome, Brave, Edge, Vivaldi, Chromium)
//
// Profil adları tarayıcının "Local State" dosyasından okunur. Bir pencerenin hangi profile ait
// olduğu, pencere başlığından ("Sayfa - Google Chrome - İş") ya da araç çubuğundaki profil
// düğmesinin adından anlaşılır. Sonuç pencere başına saklanır; ⌘Tab anında sadece okunur,
// bulunamayanlar arka planda aranır. Tarayıcıda tek profil varsa rozet gösterilmez.

final class BrowserProfiles: @unchecked Sendable {
    static let shared = BrowserProfiles()

    struct Profile {
        /// Rozette yazan ad: Chrome'da profile verdiğin ad (yoksa hesap adı; aynıysa e-posta ile ayrılır)
        let name: String
        let color: NSColor?
        /// Pencereyle eşleştirmek için: e-posta (en ayırt edici), profil adı, hesap adı
        var email = ""
        var localName = ""
        var accountNames: [String] = []
    }

    /// Paket kimliği başlangıcı → ~/Library/Application Support altındaki klasör
    private static let roots: [(String, String)] = [
        ("com.google.Chrome.canary", "Google/Chrome Canary"), ("com.google.Chrome.beta", "Google/Chrome Beta"),
        ("com.google.Chrome.dev", "Google/Chrome Dev"), ("com.google.Chrome", "Google/Chrome"),
        ("com.brave.Browser", "BraveSoftware/Brave-Browser"), ("com.microsoft.edgemac", "Microsoft Edge"),
        ("com.vivaldi.Vivaldi", "Vivaldi"), ("org.chromium.Chromium", "Chromium"),
    ]

    private let lock = NSLock()
    private var byWindow: [CGWindowID: Profile] = [:]
    private var tried = Set<CGWindowID>()
    private var namesCache: [String: (date: Date, list: [Profile])] = [:]
    private let queue = DispatchQueue(label: "audiotab.browserprofiles", qos: .userInitiated)

    static func supports(_ app: NSRunningApplication) -> Bool {
        guard let b = app.bundleIdentifier else { return false }
        return roots.contains { b.hasPrefix($0.0) }
    }

    /// ⌘Tab anında: bilinen profil (yoksa nil)
    func cached(_ item: Item) -> Profile? {
        lock.lock(); defer { lock.unlock() }
        return byWindow[item.wid]
    }

    /// Bilinmeyen tarayıcı pencerelerinin profilini arka planda bul; bulununca done çağrılır (ana iş parçacığında)
    func resolve(_ items: [Item], done: @escaping () -> Void) {
        let todo: [Item] = {
            lock.lock(); defer { lock.unlock() }
            return items.filter { $0.wid != 0 && $0.window != nil && Self.supports($0.app) && byWindow[$0.wid] == nil && !tried.contains($0.wid) }
        }()
        guard !todo.isEmpty else { return }
        queue.async { [self] in
            var found = false
            for it in todo {
                let p = detect(it)
                lock.lock()
                tried.insert(it.wid)
                if let p { byWindow[it.wid] = p; found = true }
                lock.unlock()
            }
            if found { DispatchQueue.main.async(execute: done) }
        }
    }

    /// Kapanmış pencereleri unut (ve profili değişmiş olabilecekleri yeniden dene)
    func prune(alive: Set<CGWindowID>) {
        lock.lock()
        byWindow = byWindow.filter { alive.contains($0.key) }
        tried = tried.filter { alive.contains($0) }
        lock.unlock()
    }

    // MARK: Algılama

    private func detect(_ it: Item) -> Profile? {
        guard let bid = it.app.bundleIdentifier, let w = it.window else { return nil }
        let profiles = names(bid)
        guard profiles.count > 1 else { return nil }     // tek profil: rozet gereksiz

        // Pencere başlığı + araç çubuğundaki düğmelerin adları / açıklamaları / ipuçları
        var texts: [String] = []
        if let title: String = AX.attr(w, kAXTitleAttribute) { texts.append(title) }
        var queueEls: [(AXUIElement, Int)] = [(w, 0)]
        var visited = 0
        while !queueEls.isEmpty && visited < 500 {
            let (el, depth) = queueEls.removeFirst()
            visited += 1
            AXUIElementSetMessagingTimeout(el, 0.05)
            let role: String? = AX.attr(el, kAXRoleAttribute)
            if role == kAXButtonRole as String || role == kAXPopUpButtonRole as String || role == "AXMenuButton" {
                for k in [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute] {
                    if let s: String = AX.attr(el, k as String), !s.isEmpty { texts.append(s) }
                }
            }
            if role == "AXWebArea" || depth >= 7 { continue }   // web içeriğine inme
            if let kids: [AXUIElement] = AX.attr(el, kAXChildrenAttribute) {
                for k in kids { queueEls.append((k, depth + 1)) }
            }
        }
        let all = texts.map { $0.lowercased() }

        // Sadece TEK profile uyan ipucuyla karar ver (iki profilde de aynı hesap adı varsa o ipucu sayılmaz)
        func unique(_ key: (Profile) -> [String], _ match: (String, String) -> Bool) -> Profile? {
            let hits = profiles.filter { p in
                key(p).contains { k in !k.isEmpty && all.contains { match($0, k.lowercased()) } }
            }
            return hits.count == 1 ? hits[0] : nil
        }
        // 1) e-posta  2) profile verilen ad  3) hesap adı
        if let p = unique({ [$0.email] }, { $0.contains($1) }) { return p }
        if let p = unique({ [$0.localName] }, { t, k in t == k || t.hasPrefix(k + " ") || t.hasPrefix(k + "(") || t.hasSuffix(" - " + k) || t.hasSuffix(" – " + k) || t.contains("\n" + k) || t.hasPrefix(k + "\n") }) { return p }
        if let p = unique({ $0.accountNames }, { t, k in t == k || t.hasPrefix(k + " ") || t.hasPrefix(k + "\n") || t.hasSuffix(" - " + k) }) { return p }
        return nil
    }

    /// Tarayıcının profil adları (ve varsa tema rengi), Local State'ten
    private func names(_ bid: String) -> [Profile] {
        lock.lock()
        if let c = namesCache[bid], Date().timeIntervalSince(c.date) < 60 { lock.unlock(); return c.list }
        lock.unlock()
        var list: [Profile] = []
        if let rel = Self.roots.first(where: { bid.hasPrefix($0.0) })?.1 {
            let f = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/\(rel)/Local State")
            if let data = try? Data(contentsOf: f),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let cache = (json["profile"] as? [String: Any])?["info_cache"] as? [String: [String: Any]] {
                struct Raw { let local: String; let isDefault: Bool; let given: String; let full: String; let email: String; let color: NSColor? }
                var raws: [Raw] = []
                for (_, info) in cache {
                    let local = info["name"] as? String ?? ""
                    let email = info["user_name"] as? String ?? ""
                    var color: NSColor?
                    if let c = (info["profile_highlight_color"] as? NSNumber)?.int64Value ?? (info["default_avatar_fill_color"] as? NSNumber)?.int64Value {
                        let v = UInt32(truncatingIfNeeded: c)
                        color = NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                                        blue: CGFloat(v & 0xff) / 255, alpha: 1)
                    }
                    raws.append(Raw(local: local, isDefault: info["is_using_default_name"] as? Bool ?? false,
                                    given: info["gaia_given_name"] as? String ?? "", full: info["gaia_name"] as? String ?? "",
                                    email: email, color: color))
                }
                // Rozet adı: profile verdiğin ad. Varsayılan addaysa (Kişi 1 gibi) hesap adı.
                func base(_ r: Raw) -> String {
                    if !r.isDefault, !r.local.isEmpty { return r.local }
                    return !r.given.isEmpty ? r.given : (!r.full.isEmpty ? r.full : r.local)
                }
                let counts = Dictionary(raws.map { (base($0).lowercased(), 1) }, uniquingKeysWith: +)
                for r in raws {
                    var shown = base(r)
                    // İki profil aynı adı gösteriyorsa e-postayla ayır
                    if (counts[shown.lowercased()] ?? 0) > 1, !r.email.isEmpty { shown = r.email }
                    guard !shown.isEmpty else { continue }
                    list.append(Profile(name: shown, color: r.color, email: r.email,
                                        localName: r.isDefault ? "" : r.local,
                                        accountNames: [r.full, r.given].filter { !$0.isEmpty }))
                }
            }
        }
        lock.lock(); namesCache[bid] = (Date(), list); lock.unlock()
        return list
    }
}
