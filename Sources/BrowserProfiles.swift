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
        /// Rozette yazan ad: Ayarlar'da verdiğin ad, yoksa Chrome'daki profil adı
        /// (o da yoksa hesap adı; aynıysa e-posta ile ayrılır)
        var name: String
        let color: NSColor?
        /// "paket kimliği|profil klasörü" (ör. "com.google.Chrome|Profile 1"): Ayarlar'daki özel ad bununla saklanır
        var id = ""
        /// Otomatik bulunan ad (özel ad verilmemişse rozette bu yazar)
        var autoName = ""
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

    /// ⌘Tab anında: bilinen profil (yoksa nil). Ayarlar'da özel ad verildiyse o yazar.
    func cached(_ item: Item) -> Profile? {
        lock.lock(); defer { lock.unlock() }
        guard var p = byWindow[item.wid] else { return nil }
        p.name = Self.label(for: p)
        return p
    }

    // MARK: Ayarlar'dan özel adlar

    private static let labelsKey = "browserProfiles.labels"
    static var labels: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: labelsKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: labelsKey) }
    }
    static func label(for p: Profile) -> String {
        let custom = labels[p.id]?.trimmingCharacters(in: .whitespaces) ?? ""
        return custom.isEmpty ? p.autoName : custom
    }
    static func setLabel(_ s: String, for p: Profile) {
        var l = labels
        let v = s.trimmingCharacters(in: .whitespaces)
        if v.isEmpty { l[p.id] = nil } else { l[p.id] = v }
        labels = l
    }

    /// Ayarlar için: açık desteklenen tarayıcılar ve profilleri
    struct BrowserEntry: Identifiable { let bundle: String; let app: String; let profiles: [Profile]; var id: String { bundle } }

    func browsersForSettings() -> [BrowserEntry] {
        var seen = Set<String>()
        var out: [BrowserEntry] = []
        for app in NSWorkspace.shared.runningApplications where Self.supports(app) {
            guard let b = app.bundleIdentifier, seen.insert(b).inserted else { continue }
            let list = names(b, force: true)
            if !list.isEmpty { out.append(BrowserEntry(bundle: b, app: app.localizedName ?? b, profiles: list)) }
        }
        return out
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

    private struct Btn { let texts: [String]; let x: CGFloat }

    /// Pencerenin araç çubuğu düğmeleri (web içeriğine inmeden): adlar/açıklamalar/ipuçları + yatay konum
    private func collectButtons(_ w: AXUIElement) -> [Btn] {
        var buttons: [Btn] = []
        var queueEls: [(AXUIElement, Int)] = [(w, 0)]
        var visited = 0
        while !queueEls.isEmpty && visited < 600 {
            let (el, depth) = queueEls.removeFirst()
            visited += 1
            AXUIElementSetMessagingTimeout(el, 0.05)
            let role: String? = AX.attr(el, kAXRoleAttribute)
            if role == kAXButtonRole as String || role == kAXPopUpButtonRole as String || role == "AXMenuButton" {
                var texts: [String] = []
                for k in [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute] {
                    if let s: String = AX.attr(el, k as String), !s.isEmpty {
                        texts.append(s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
                    }
                }
                var x: CGFloat = 0
                if let v: AXValue = AX.attr(el, kAXPositionAttribute) {
                    var pt = CGPoint.zero
                    if AXValueGetValue(v, .cgPoint, &pt) { x = pt.x }
                }
                if !texts.isEmpty { buttons.append(Btn(texts: texts, x: x)) }
            }
            if role == "AXWebArea" || depth >= 8 { continue }
            if let kids: [AXUIElement] = AX.attr(el, kAXChildrenAttribute) {
                for k in kids { queueEls.append((k, depth + 1)) }
            }
        }
        return buttons
    }

    /// Chrome'un profil düğmesi bazen profil adını ("Flow 2"), bazen oturum açılan hesabın adını
    /// ("Firewall") gösterir. İkisine de bakılır; bir düğme yazısı birden fazla profile uyuyorsa
    /// o yazı sayılmaz. Uyanlardan en sağdaki düğme seçilir (profil düğmesi sağda, yer imleri solda).
    private func match(_ buttons: [Btn], _ profiles: [Profile]) -> Profile? {
        func keys(_ p: Profile) -> [String] {
            ([p.localName] + p.accountNames).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
        }
        func fits(_ t: String, _ k: String) -> Bool {
            t == k || t.hasPrefix(k + " (") || t.hasPrefix(k + "\n") || t.hasSuffix(": " + k) || t.contains("\n" + k + "\n")
        }
        var best: (p: Profile, x: CGFloat)?
        for b in buttons {
            for t in b.texts {
                let hits = profiles.filter { p in keys(p).contains { fits(t, $0) } }
                guard hits.count == 1 else { continue }
                if best == nil || b.x > best!.x { best = (hits[0], b.x) }
            }
        }
        if let best { return best.p }
        // E-posta (sadece tek profile uyuyorsa)
        let byMail = profiles.filter { p in !p.email.isEmpty && buttons.contains { $0.texts.contains { $0.contains(p.email.lowercased()) } } }
        return byMail.count == 1 ? byMail[0] : nil
    }

    private func detect(_ it: Item) -> Profile? {
        guard let bid = it.app.bundleIdentifier, let w = it.window else { return nil }
        let profiles = names(bid)
        guard profiles.count > 1 else { return nil }     // tek profil: rozet gereksiz
        return match(collectButtons(w), profiles)        // emin değilsek nil: yanlış ad yazmaktansa rozet yok
    }

    /// Ayarlar'daki "Tanı bilgisini kopyala": açık tarayıcı pencerelerinin düğme yazıları ve sonuç
    func diagnostics() -> String {
        var out: [String] = []
        for app in NSWorkspace.shared.runningApplications where Self.supports(app) {
            guard let bid = app.bundleIdentifier else { continue }
            let profiles = names(bid, force: true)
            out.append("== \(app.localizedName ?? bid) (\(bid))")
            for p in profiles {
                out.append("profil: \(p.id) | ad: \(p.localName) | hesap: \(p.accountNames.joined(separator: " / "))")
            }
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(axApp, 0.3)
            let wins: [AXUIElement] = AX.attr(axApp, kAXWindowsAttribute) ?? []
            for w in wins {
                let title: String = AX.attr(w, kAXTitleAttribute) ?? ""
                let btns = collectButtons(w)
                let result = match(btns, profiles).map { $0.localName } ?? "—"
                out.append("-- pencere: \(title.prefix(60)) → \(result)")
                for b in btns.sorted(by: { $0.x > $1.x }).prefix(12) {
                    out.append("   x=\(Int(b.x))  \(b.texts.map { String($0.prefix(60)) }.joined(separator: " | "))")
                }
            }
        }
        // E-postaları gizle
        let text = out.joined(separator: "\n")
        return text.replacingOccurrences(of: #"[^\s@|]+@[^\s@|]+"#, with: "<e-posta>", options: .regularExpression)
    }

    /// Tarayıcının profil adları (ve varsa tema rengi), Local State'ten
    private func names(_ bid: String, force: Bool = false) -> [Profile] {
        lock.lock()
        if !force, let c = namesCache[bid], Date().timeIntervalSince(c.date) < 60 { lock.unlock(); return c.list }
        lock.unlock()
        var list: [Profile] = []
        if let rel = Self.roots.first(where: { bid.hasPrefix($0.0) })?.1 {
            let f = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/\(rel)/Local State")
            if let data = try? Data(contentsOf: f),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let cache = (json["profile"] as? [String: Any])?["info_cache"] as? [String: [String: Any]] {
                struct Raw { let dir: String; let local: String; let isDefault: Bool; let given: String; let full: String; let email: String; let color: NSColor? }
                var raws: [Raw] = []
                for (dir, info) in cache.sorted(by: { $0.key < $1.key }) {
                    let local = info["name"] as? String ?? ""
                    let email = info["user_name"] as? String ?? ""
                    var color: NSColor?
                    if let c = (info["profile_highlight_color"] as? NSNumber)?.int64Value ?? (info["default_avatar_fill_color"] as? NSNumber)?.int64Value {
                        let v = UInt32(truncatingIfNeeded: c)
                        color = NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                                        blue: CGFloat(v & 0xff) / 255, alpha: 1)
                    }
                    raws.append(Raw(dir: dir, local: local, isDefault: info["is_using_default_name"] as? Bool ?? false,
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
                    list.append(Profile(name: shown, color: r.color, id: "\(bid)|\(r.dir)", autoName: shown,
                                        email: r.email, localName: r.local,
                                        accountNames: [r.full, r.given].filter { !$0.isEmpty }))
                }
            }
        }
        lock.lock(); namesCache[bid] = (Date(), list); lock.unlock()
        return list
    }
}
