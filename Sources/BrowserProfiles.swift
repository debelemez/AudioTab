import Cocoa

// MARK: - Tarayıcı penceresinin profili (Chrome, Brave, Edge, Vivaldi, Chromium)
//
// Profil adları tarayıcının "Local State" dosyasından okunur. Bir pencerenin hangi profile ait
// olduğu, pencere başlığından ("Sayfa - Google Chrome - İş") ya da araç çubuğundaki profil
// düğmesinin adından anlaşılır. Sonuç pencere başına saklanır; ⌘Tab anında sadece okunur,
// bulunamayanlar arka planda aranır. Tarayıcıda tek profil varsa rozet gösterilmez.

final class BrowserProfiles: @unchecked Sendable {
    static let shared = BrowserProfiles()

    struct Profile { let name: String; let color: NSColor? }

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

        // 1) Pencere başlığı: "… - Google Chrome - İş" / "… - İş"
        if let title: String = AX.attr(w, kAXTitleAttribute) {
            for p in profiles.sorted(by: { $0.name.count > $1.name.count })
            where title.hasSuffix(" - \(p.name)") || title.hasSuffix(" – \(p.name)") {
                return p
            }
        }
        // 2) Araç çubuğundaki profil düğmesi (adı profil adı ya da "İş (…)" gibi)
        var queueEls: [(AXUIElement, Int)] = [(w, 0)]
        var visited = 0
        while !queueEls.isEmpty && visited < 500 {
            let (el, depth) = queueEls.removeFirst()
            visited += 1
            AXUIElementSetMessagingTimeout(el, 0.05)
            let role: String? = AX.attr(el, kAXRoleAttribute)
            if role == kAXButtonRole as String || role == kAXPopUpButtonRole as String || role == "AXMenuButton" {
                let texts = [AX.attr(el, kAXTitleAttribute) as String?, AX.attr(el, kAXDescriptionAttribute) as String?,
                             AX.attr(el, kAXHelpAttribute) as String?].compactMap { $0 }
                for t in texts {
                    for p in profiles.sorted(by: { $0.name.count > $1.name.count })
                    where t == p.name || t.hasPrefix(p.name + " ") || t.hasPrefix(p.name + "(") || t.hasSuffix(": " + p.name) {
                        return p
                    }
                }
            }
            // Web içeriğine inme (çok büyük); sadece pencere çerçevesi ve araç çubuğu
            if role == "AXWebArea" || depth >= 7 { continue }
            if let kids: [AXUIElement] = AX.attr(el, kAXChildrenAttribute) {
                for k in kids { queueEls.append((k, depth + 1)) }
            }
        }
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
                for (_, info) in cache {
                    guard let name = info["name"] as? String, !name.isEmpty else { continue }
                    var color: NSColor?
                    if let c = (info["profile_highlight_color"] as? NSNumber)?.int64Value ?? (info["default_avatar_fill_color"] as? NSNumber)?.int64Value {
                        let v = UInt32(truncatingIfNeeded: c)
                        color = NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                                        blue: CGFloat(v & 0xff) / 255, alpha: 1)
                    }
                    list.append(Profile(name: name, color: color))
                }
            }
        }
        lock.lock(); namesCache[bid] = (Date(), list); lock.unlock()
        return list
    }
}
