import Cocoa
import Security

// MARK: - GitHub'dan otomatik güncelleme
//
// GitHub Actions her "v*" etiketinde uygulamayı derleyip Releases'e AudioTab.zip olarak koyar.
// Uygulama en son sürümü denetler; yeniyse indirir, imzasını doğrular, kendini değiştirip yeniden açılır.
// Ayarlar ve izinler korunur (sürümler aynı sertifikayla imzalanır).

enum UpdateConfig {
    /// "kullanıcı/repo"
    static let repo = "debelemez/AudioTab"
    static var releasesPage: URL { URL(string: "https://github.com/\(repo)/releases")! }
}

struct ReleaseInfo {
    let version: String
    let notes: String
    let zipURL: URL
    let page: URL
}

final class Updater: ObservableObject {
    static let shared = Updater()

    enum State: Equatable {
        case idle, checking, upToDate, available(String), downloading, installing, failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var latest: ReleaseInfo?
    @Published private(set) var lastCheck: Date?

    /// Yeni sürüm bulununca (otomatik denetimde, her sürüm için bir kez)
    var onAvailable: ((ReleaseInfo) -> Void)?
    private var timer: Timer?

    var autoCheck: Bool {
        get { UserDefaults.standard.object(forKey: "update.auto") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "update.auto")
            objectWillChange.send()
            schedule()
        }
    }

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    var updateAvailable: Bool {
        if case .available = state { return true }
        return false
    }

    /// Açılıştan biraz sonra ve 6 saatte bir denetle (sadece otomatik denetim açıksa)
    func start() {
        schedule()
        guard autoCheck else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.check(userInitiated: false) }
    }

    private func schedule() {
        timer?.invalidate()
        timer = nil
        guard autoCheck else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            self?.check(userInitiated: false)
        }
        timer?.tolerance = 600
    }

    private func set(_ s: State) {
        DispatchQueue.main.async { self.state = s }
    }

    // MARK: Denetle

    func check(userInitiated: Bool) {
        if state == .checking || state == .downloading || state == .installing { return }
        set(.checking)
        Task {
            do {
                let info = try await Self.fetchLatest()
                let newer = Self.isNewer(info.version, than: currentVersion)
                DispatchQueue.main.async {
                    self.lastCheck = Date()
                    self.latest = info
                    self.state = newer ? .available(info.version) : .upToDate
                    if newer && !userInitiated {
                        let key = "update.notified"
                        if UserDefaults.standard.string(forKey: key) != info.version {
                            UserDefaults.standard.set(info.version, forKey: key)
                            self.onAvailable?(info)
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.lastCheck = Date()
                    // Otomatik denetimde ağ hatası sessizce geçilir
                    self.state = userInitiated ? .failed(error.localizedDescription) : .idle
                }
            }
        }
    }

    /// Önce GitHub API (sürüm notlarıyla), olmazsa github.com/…/releases/latest yönlendirmesi
    /// (API sınırı ya da ağ engeli olsa bile çalışır).
    static func fetchLatest() async throws -> ReleaseInfo {
        do {
            return try await fetchFromAPI()
        } catch let apiError {
            do {
                return try await fetchFromRedirect()
            } catch {
                throw apiError
            }
        }
    }

    private static func fetchFromAPI() async throws -> ReleaseInfo {
        guard let url = URL(string: "https://api.github.com/repos/\(UpdateConfig.repo)/releases/latest") else {
            throw UpdateError.message(L("Repo adresi geçersiz"))
        }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("AudioTab-Updater", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard status == 200 else {
            if status == 404 { throw UpdateError.message(L("Henüz yayınlanmış sürüm yok")) }
            let msg = json?["message"] as? String ?? "HTTP \(status)"
            throw UpdateError.message("GitHub: \(msg)")
        }
        guard let json, let tag = json["tag_name"] as? String else {
            throw UpdateError.message(L("GitHub cevabı okunamadı"))
        }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let assets = json["assets"] as? [[String: Any]] ?? []
        let dl = assets.first(where: { ($0["name"] as? String) == "AudioTab.zip" })
            .flatMap { ($0["browser_download_url"] as? String).flatMap(URL.init(string:)) }
            ?? downloadURL(tag: tag)
        let page = (json["html_url"] as? String).flatMap(URL.init(string:)) ?? UpdateConfig.releasesPage
        return ReleaseInfo(version: version, notes: json["body"] as? String ?? "", zipURL: dl, page: page)
    }

    /// github.com/…/releases/latest → …/releases/tag/v2.3.0 yönlendirmesinden sürümü al
    private static func fetchFromRedirect() async throws -> ReleaseInfo {
        guard let url = URL(string: "https://github.com/\(UpdateConfig.repo)/releases/latest") else {
            throw UpdateError.message(L("Repo adresi geçersiz"))
        }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        req.httpMethod = "HEAD"
        req.setValue("AudioTab-Updater", forHTTPHeaderField: "User-Agent")
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let final = resp.url, final.path.contains("/releases/tag/") else {
            throw UpdateError.message(L("Henüz yayınlanmış sürüm yok"))
        }
        let tag = final.lastPathComponent
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return ReleaseInfo(version: version, notes: "", zipURL: downloadURL(tag: tag), page: final)
    }

    private static func downloadURL(tag: String) -> URL {
        URL(string: "https://github.com/\(UpdateConfig.repo)/releases/download/\(tag)/AudioTab.zip")!
    }

    /// "2.10.0" > "2.9.3"
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: Yükle

    /// İndir → aç → imzayı doğrula → mevcut uygulamanın yerine koy → yeniden aç.
    /// beforeRelaunch: uygulama kapanmadan önce (ör. kayıt sürüyorsa bitir) çağrılır.
    func install(beforeRelaunch: @escaping (@escaping () -> Void) -> Void = { $0() }) {
        guard let info = latest, state != .downloading, state != .installing else { return }
        set(.downloading)
        Task {
            do {
                let fm = FileManager.default
                let work = fm.temporaryDirectory.appendingPathComponent("AudioTabUpdate-\(UUID().uuidString)", isDirectory: true)
                try fm.createDirectory(at: work, withIntermediateDirectories: true)
                let (tmp, resp) = try await URLSession.shared.download(from: info.zipURL)
                if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw UpdateError.message(L("İndirme başarısız (%@)", "\(http.statusCode)"))
                }
                let zip = work.appendingPathComponent("AudioTab.zip")
                try fm.moveItem(at: tmp, to: zip)

                set(.installing)
                try Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])
                let newApp = work.appendingPathComponent("AudioTab.app")
                guard fm.fileExists(atPath: newApp.path) else { throw UpdateError.message(L("Paket içinde AudioTab.app yok")) }
                try Self.verify(newApp)
                _ = try? Self.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])

                let dest = Bundle.main.bundleURL
                try Self.replace(dest, with: newApp)
                try? fm.removeItem(at: work)

                DispatchQueue.main.async {
                    beforeRelaunch {
                        DispatchQueue.main.async { MainActor.assumeIsolated { Self.relaunch(dest) } }
                    }
                }
            } catch {
                self.set(.failed(error.localizedDescription))
            }
        }
    }

    private static func replace(_ dest: URL, with newApp: URL) throws {
        let fm = FileManager.default
        guard fm.isWritableFile(atPath: dest.deletingLastPathComponent().path) else {
            throw UpdateError.message(L("%@ klasörüne yazılamıyor", dest.deletingLastPathComponent().path))
        }
        // Eski sürümü çöpe at (geri dönmek istersen Çöp'te durur), yenisini yerine kopyala
        var trashed: NSURL?
        try fm.trashItem(at: dest, resultingItemURL: &trashed)
        do {
            try fm.copyItem(at: newApp, to: dest)
        } catch {
            if let back = trashed as URL? { try? fm.moveItem(at: back, to: dest) }
            throw error
        }
    }

    /// Uygulamayı kapatıp yeniden aç (dil değişikliği vb.)
    @MainActor static func relaunchApp() { relaunch(Bundle.main.bundleURL) }

    @MainActor private static func relaunch(_ app: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", app.path]
        try? p.run()
        NSApp.terminate(nil)
    }

    @discardableResult
    private static func run(_ tool: String, _ args: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 { throw UpdateError.message(L("%@ hata verdi (%@)", (tool as NSString).lastPathComponent, "\(p.terminationStatus)")) }
        return p.terminationStatus
    }

    /// Yeni sürümün imzası geçerli mi ve bizimle aynı sertifikayla mı imzalanmış?
    /// (Biz yerelde ad-hoc derlendiysek sertifika karşılaştırılamaz; o zaman paket kimliği kontrol edilir.)
    static func verify(_ newApp: URL) throws {
        var newCodeRef: SecStaticCode?
        guard SecStaticCodeCreateWithPath(newApp as CFURL, [], &newCodeRef) == errSecSuccess, let newCode = newCodeRef else {
            throw UpdateError.message(L("Yeni sürümün imzası okunamadı"))
        }
        guard SecStaticCodeCheckValidity(newCode, [], nil) == errSecSuccess else {
            throw UpdateError.message(L("Yeni sürümün imzası geçersiz"))
        }

        var selfRef: SecCode?
        var selfStaticRef: SecStaticCode?
        guard SecCodeCopySelf([], &selfRef) == errSecSuccess, let me = selfRef,
              SecCodeCopyStaticCode(me, [], &selfStaticRef) == errSecSuccess, let meStatic = selfStaticRef else {
            throw UpdateError.message(L("Mevcut uygulamanın imzası okunamadı"))
        }
        var infoRef: CFDictionary?
        _ = SecCodeCopySigningInformation(meStatic, SecCSFlags(rawValue: 1 << 1), &infoRef)   // kSecCSSigningInformation
        let info = infoRef as? [String: Any] ?? [:]
        let flags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let adhoc = flags & SecCodeSignatureFlags.adhoc.rawValue != 0

        if adhoc {
            let newID = Bundle(url: newApp)?.bundleIdentifier
            guard newID != nil, newID == Bundle.main.bundleIdentifier else {
                throw UpdateError.message(L("Paket kimliği uyuşmuyor"))
            }
        } else {
            var reqRef: SecRequirement?
            guard SecCodeCopyDesignatedRequirement(meStatic, [], &reqRef) == errSecSuccess, let req = reqRef,
                  SecStaticCodeCheckValidity(newCode, [], req) == errSecSuccess else {
                throw UpdateError.message(L("Yeni sürüm farklı bir sertifikayla imzalanmış, yüklenmedi"))
            }
        }
    }
}

enum UpdateError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let m): return m }
    }
}
