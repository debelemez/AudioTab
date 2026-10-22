import Cocoa

// MARK: - ⌘Tab gruplu görünüm: pencereleri türüne göre bölümlere ayır
//
// Yan yana sütunlar: Tarayıcılar · Projeler (DaVinci, Adobe, Final Cut…) · Geliştirme · Uygulamalar · Klasörler
// Klasör kartlarında önizleme yerine klasörün adı büyük yazılır; proje uygulamalarında
// pencere başlığından okunan proje adı önizlemenin üstüne yazılır.

/// Soldan sağa sıra. Klasörler her zaman en sağda.
enum WindowGroup: Int, CaseIterable {
    case browsers, projects, code, apps, folders

    var title: String {
        switch self {
        case .folders: return L("Klasörler")
        case .browsers: return L("Tarayıcılar")
        case .projects: return L("Projeler")
        case .code: return L("Geliştirme")
        case .apps: return L("Uygulamalar")
        }
    }

    var symbol: String {
        switch self {
        case .folders: return "folder.fill"
        case .browsers: return "globe"
        case .projects: return "film.stack"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .apps: return "square.grid.2x2.fill"
        }
    }
}

enum GroupSettings {
    private static let d = UserDefaults.standard

    /// Finder pencerelerinde önizleme yerine klasör adı (büyük)
    static var bigFolderNames: Bool {
        get { d.object(forKey: "groups.bigFolders") as? Bool ?? true }
        set { d.set(newValue, forKey: "groups.bigFolders") }
    }
    /// Proje uygulamalarında proje adını önizlemenin üstüne yaz
    static var showProjectNames: Bool {
        get { d.object(forKey: "groups.projectNames") as? Bool ?? true }
        set { d.set(newValue, forKey: "groups.projectNames") }
    }

    static let folderApps = ["com.apple.finder", "com.cocoatech.PathFinder", "com.binarynights.ForkLift"]

    /// Otomatik algılanan proje uygulamaları (paket kimliği başlangıcı)
    static let defaultProjectApps = [
        "com.blackmagic-design.DaVinciResolve", "com.adobe.", "com.apple.FinalCut", "com.apple.logic",
        "com.apple.motionapp", "com.apple.GarageBand", "com.ableton.live", "org.blenderfoundation.blender",
        "com.maxon.cinema4d", "com.figma.Desktop", "com.seriflabs.", "com.bohemiancoding.sketch3",
        "com.pixelmatorteam.", "com.image-line.flstudio", "com.steinberg.", "com.avid.", "com.cockos.reaper",
        "com.autodesk.", "com.sidefx.", "com.toonboom.", "com.affinity.", "com.lwks.", "com.blackmagic-design.Fusion",
    ]

    static let codeApps = [
        "com.apple.dt.Xcode", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed",
        "com.jetbrains.", "com.sublimetext.", "com.panic.Nova", "com.apple.Terminal", "com.googlecode.iterm2",
        "dev.warp.", "com.mitchellh.ghostty", "net.kovidgoyal.kitty", "com.github.wez.wezterm", "com.google.android.studio",
    ]

    /// Kullanıcının eklediği proje uygulamaları (tam paket kimliği)
    static var addedProjectApps: [String] {
        get { d.stringArray(forKey: "groups.projectApps.added") ?? [] }
        set { d.set(newValue, forKey: "groups.projectApps.added") }
    }
    /// Otomatik algılanıp kullanıcının çıkardıkları (tam paket kimliği)
    static var removedProjectApps: [String] {
        get { d.stringArray(forKey: "groups.projectApps.removed") ?? [] }
        set { d.set(newValue, forKey: "groups.projectApps.removed") }
    }

    static func isDefaultProjectApp(_ bid: String) -> Bool { defaultProjectApps.contains { bid.hasPrefix($0) } }

    static func isProjectApp(_ bid: String) -> Bool {
        if addedProjectApps.contains(bid) { return true }
        if removedProjectApps.contains(bid) { return false }
        return isDefaultProjectApp(bid)
    }

    static func addProjectApp(_ bid: String) {
        removedProjectApps.removeAll { $0 == bid }
        if !isDefaultProjectApp(bid), !addedProjectApps.contains(bid) { addedProjectApps.append(bid) }
    }

    static func removeProjectApp(_ bid: String) {
        addedProjectApps.removeAll { $0 == bid }
        if isDefaultProjectApp(bid), !removedProjectApps.contains(bid) { removedProjectApps.append(bid) }
    }

    static func group(for app: NSRunningApplication) -> WindowGroup {
        guard let b = app.bundleIdentifier else { return .apps }
        if isProjectApp(b) { return .projects }
        if folderApps.contains(where: { b.hasPrefix($0) }) { return .folders }
        if DeepScanScope.browserPrefixes.contains(where: { b.hasPrefix($0) }) { return .browsers }
        if codeApps.contains(where: { b.hasPrefix($0) }) { return .code }
        return .apps
    }

    /// Proje şeridinin rengi: bilinen uygulamalara sabit, diğerlerine paket kimliğinden türetilmiş renk
    static func color(for app: NSRunningApplication) -> NSColor {
        let b = (app.bundleIdentifier ?? app.localizedName ?? "").lowercased()
        let known: [(String, (CGFloat, CGFloat, CGFloat))] = [
            ("davinciresolve", (0.93, 0.36, 0.18)), ("fusion", (0.80, 0.25, 0.45)),
            ("premierepro", (0.48, 0.30, 0.92)), ("aftereffects", (0.40, 0.33, 0.95)),
            ("photoshop", (0.10, 0.52, 0.95)), ("illustrator", (0.93, 0.55, 0.05)),
            ("indesign", (0.90, 0.20, 0.45)), ("audition", (0.10, 0.65, 0.55)),
            ("lightroom", (0.20, 0.55, 0.85)), ("finalcut", (0.30, 0.30, 0.38)),
            ("logic", (0.18, 0.62, 0.58)), ("garageband", (0.95, 0.50, 0.10)),
            ("ableton", (0.55, 0.55, 0.12)), ("blender", (0.92, 0.47, 0.10)),
            ("cinema4d", (0.15, 0.45, 0.90)), ("figma", (0.62, 0.30, 0.95)),
            ("sketch", (0.92, 0.62, 0.05)), ("pixelmator", (0.10, 0.60, 0.90)),
        ]
        if let k = known.first(where: { b.contains($0.0) }) {
            return NSColor(srgbRed: k.1.0, green: k.1.1, blue: k.1.2, alpha: 1)
        }
        // Kararlı karma: aynı uygulama hep aynı renk
        var h: UInt64 = 1469598103934665603
        for c in b.utf8 { h = (h ^ UInt64(c)) &* 1099511628211 }
        return NSColor(hue: CGFloat(h % 360) / 360, saturation: 0.62, brightness: 0.78, alpha: 1)
    }

    /// Kartta gösterilecek ek bilgi: klasör adı (büyük) ya da proje adı
    static func decoration(for item: Item) -> (folder: String?, project: String?) {
        guard item.window != nil, !item.system else { return (nil, nil) }
        switch group(for: item.app) {
        case .folders where bigFolderNames:
            return (item.title, nil)
        case .projects where showProjectNames:
            return (nil, ProjectName.parse(item.title, appName: item.app.localizedName ?? ""))
        default:
            return (nil, nil)
        }
    }
}

/// Pencere başlığından proje adını çıkar.
/// Örnekler:
///   "DaVinci Resolve Studio - Düğün Klibi"                 → Düğün Klibi
///   "Adobe Premiere Pro 2025 - /Users/a/Reklam.prproj *"   → Reklam
///   "Afiş.psd @ 66,7% (Katman 1, RGB/8)"                    → Afiş
///   "Şarkı [Şarkı] - Ableton Live 12 Suite"                 → Şarkı
///   "Demo - Tracks" (Logic)                                 → Demo
enum ProjectName {
    private static let fileExt = #"\.(prproj|aep|aet|psd|psb|ai|indd|idml|drp|blend|als|logicx|band|fcpbundle|fcpxml|c4d|fig|afphoto|afdesign|afpub|sketch|pxd|pxm|ptx|cpr|flp|rpp|aup3|kra|xd|motn|hip|hiplc|ma|mb|max|prel|aepx|sesx|lrcat)\b"#
    private static let viewWords: Set<String> = [
        "tracks", "mixer", "edit", "cut", "color", "fusion", "fairlight", "deliver", "media",
        "arrangement", "session", "untitled", "adsız", "project manager", "proje yöneticisi",
    ]

    static func parse(_ rawTitle: String, appName: String) -> String? {
        var t = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        t = t.replacingOccurrences(of: " — ", with: " - ").replacingOccurrences(of: " – ", with: " - ")
        let appLower = appName.lowercased()
        let appFirst = appLower.split(separator: " ").first.map(String.init) ?? appLower

        var parts = t.components(separatedBy: " - ").map(clean).filter { !$0.isEmpty }

        // Dosya yolu / proje dosyası içeren parça varsa onun adı
        for p in parts where p.range(of: fileExt, options: [.regularExpression, .caseInsensitive]) != nil {
            var name = p
            if let at = name.range(of: " @ ") { name = String(name[..<at.lowerBound]) }
            name = (name as NSString).lastPathComponent
            name = (name as NSString).deletingPathExtension
            name = clean(name)
            if !name.isEmpty { return name.count > 60 ? String(name.prefix(59)) + "…" : name }
        }

        // Uygulamanın kendi adını ve görünüm adlarını (Tracks, Edit, Color…) at
        parts = parts.compactMap { p in
            var s = p
            if let at = s.range(of: " @ ") { s = String(s[..<at.lowerBound]) }     // Photoshop/Illustrator: "dosya @ %50"
            if let br = s.range(of: " [") { s = String(s[..<br.lowerBound]) }       // Ableton: "Şarkı [Şarkı]"
            s = clean(s)
            let l = s.lowercased()
            if s.isEmpty || viewWords.contains(l) { return nil }
            if !appLower.isEmpty && (l.contains(appLower) || appLower.contains(l)) { return nil }
            if appFirst.count > 2 && l.hasPrefix(appFirst) { return nil }            // "DaVinci Resolve Studio", "Adobe …"
            if l.hasPrefix("adobe ") || l.hasPrefix("davinci") || l.hasPrefix("ableton") || l.hasPrefix("blender") { return nil }
            return s
        }
        guard let first = parts.first else { return nil }
        // Çok uzun adlar silinmesin: kısaltılıp "…" ile devam etsin
        return first.count > 60 ? String(first.prefix(59)).trimmingCharacters(in: .whitespaces) + "…" : first
    }

    /// Kaydedilmemiş işaretleri (*, •) ve boşlukları temizle
    private static func clean(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet(charactersIn: "*•●◆ ").union(.whitespacesAndNewlines))
    }
}
