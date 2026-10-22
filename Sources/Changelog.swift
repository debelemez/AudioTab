import Foundation

// MARK: - Sürüm geçmişi (Ayarlar › Sürümler)
//
// Uygulamanın içinde gelir, internet olmadan da görünür. Her yeni sürümde en üste bir kayıt ekle.
// Her madde iki dilde yazılır: (Türkçe, English).

struct ChangelogEntry {
    let version: String
    /// GitHub'a gelmeden önceki sürümler (indirilemez, sadece geçmiş)
    var preGitHub = false
    let items: [(tr: String, en: String)]

    var lines: [String] { items.map { AppLanguage.active == .tr ? $0.tr : $0.en } }
}

enum Changelog {
    static let entries: [ChangelogEntry] = [
        ChangelogEntry(version: "2.3.3", items: [
            ("⌘Tab / ⌥Tab'ı tek uygulamaya sınırla (ör. sadece Chrome pencereleri); panel açıkken A ile uygulamayı değiştir",
             "Limit ⌘Tab / ⌥Tab to one app (e.g. only Chrome windows); press A in the panel to switch apps"),
            ("Chrome'da başka profilde ya da başka masaüstünde yeni açılan pencereler artık hemen listede",
             "New Chrome windows from another profile or desktop now show up right away"),
        ]),
        ChangelogEntry(version: "2.3.2", items: [
            ("Ayarlara Sürümler sekmesi: tüm sürümlerin değişiklik listesi",
             "New Versions tab in Settings: what changed in every release"),
            ("İstersen eski bir sürümü seçip ona dönebilirsin (imza yine kontrol edilir)",
             "You can pick an older version and go back to it (the signature is still checked)"),
        ]),
        ChangelogEntry(version: "2.3.1", items: [
            ("Güvenlik denetimi (Cloudflare security-audit) sonrası sıkılaştırmalar",
             "Hardening after a security audit (Cloudflare security-audit)"),
            ("Güncelleyici sadece AudioTab sertifikasıyla imzalı paketleri kurar",
             "The updater installs only packages signed with the AudioTab certificate"),
            ("Paketteki sürüm yayınla aynı olmalı; otomatik güncelleme eski sürüme düşmez",
             "The version inside the package must match the release; auto-update never downgrades"),
            ("install.sh kurmadan önce imzayı kontrol eder",
             "install.sh checks the signature before installing"),
            ("Aynı isimli başka bir ses cihazına ayarlar sessizce taşınmaz",
             "Audio assignments no longer move silently to a different device with the same name"),
        ]),
        ChangelogEntry(version: "2.3.0", items: [
            ("Arayüz İngilizce (varsayılan); Ayarlar › Genel'den Türkçe seçilebilir",
             "English interface (default); Turkish can be chosen in Settings › General"),
            ("README İngilizce ve Türkçe, ekran görüntüleriyle",
             "README in English and Turkish, with screenshots"),
        ]),
        ChangelogEntry(version: "2.2.4", items: [
            ("Derleme hatası düzeltildi (ekran bölme seçicisi)",
             "Fixed a build error (split-screen picker)"),
        ]),
        ChangelogEntry(version: "2.2.3", items: [
            ("Güncelleme denetimi daha sağlam: GitHub API'ye ulaşılamazsa yedek yol, gerçek hata mesajı",
             "More reliable update check: fallback when the GitHub API is unreachable, real error messages"),
        ]),
        ChangelogEntry(version: "2.2.2", items: [
            ("Ekran görüntüsü / kayıt sonrası sağ altta önizleme kartı; tıklayınca Finder'da dosya seçili açılır",
             "Preview card at the bottom right after a screenshot or recording; click to reveal the file in Finder"),
            ("Ekran bölme seçicisi artık kesik görünmüyor",
             "The split-screen picker is no longer cut off"),
        ]),
        ChangelogEntry(version: "2.2.1", items: [
            ("⌘Tab açıkken boşluğa tıklayınca panel kapanır",
             "Clicking empty space closes the ⌘Tab panel"),
        ]),
        ChangelogEntry(version: "2.2.0", items: [
            ("GitHub'dan otomatik güncelleme: tek tıkla indir, doğrula, yeniden aç",
             "Automatic updates from GitHub: download, verify and relaunch in one click"),
            ("Sürümler sertifikayla imzalı; izinler güncellemeden sonra korunur",
             "Releases are signed, so permissions survive updates"),
        ]),
        ChangelogEntry(version: "2.1", preGitHub: true, items: [
            ("⌘< ile ekran bölme; 2–3 monitörde çalışır, monitör seçilebilir",
             "Split screen with ⌘<; works across 2–3 monitors, with monitor choice"),
            ("⌘Tab kartlarında kırmızı kapat noktası ve bölme düğmesi",
             "Red close dot and tile button on ⌘Tab cards"),
            ("⌘⇧3 sadece bulunduğun monitör, ⌘⇧4 alan seçimi, kaydırmalı ekran görüntüsü",
             "⌘⇧3 captures the current monitor, ⌘⇧4 an area, plus scrolling screenshots"),
            ("⌘⇧5 MP4 (H.264) ekran kaydı; kırmızı nokta kayda girmez",
             "⌘⇧5 MP4 (H.264) screen recording; the red dot isn't recorded"),
            ("Kayıt klasörleri seçilebilir, ekran çekme özellikleri kapatılabilir",
             "Choose save folders; capture features can be turned off"),
        ]),
        ChangelogEntry(version: "2.0", preGitHub: true, items: [
            ("GlassTab ve AudioHop tek uygulamada birleşti: AudioTab",
             "GlassTab and AudioHop merged into one app: AudioTab"),
            ("Tek menü çubuğu simgesi, ayarlar penceresi; eski ayarlar otomatik taşındı",
             "One menu bar icon and a settings window; old settings migrated automatically"),
            ("Daha büyük simgeler, daha hızlı ⌘Tab, liste görünümü",
             "Bigger icons, faster ⌘Tab, list view"),
            ("Uygulamaya göre ses cihazı; İzinler sekmesi",
             "Audio device per app; Permissions tab"),
            ("Chrome profillerinin pencereleri her zaman bulunur",
             "Windows of every Chrome profile are always found"),
        ]),
        ChangelogEntry(version: "1.0", preGitHub: true, items: [
            ("AudioHop: kısayolla ses çıkışı değiştirme (⌘⇧ veya ⌘⇪)",
             "AudioHop: switch audio output with a shortcut (⌘⇧ or ⌘⇪)"),
            ("Çıkarılan cihazları hatırlar; cam görünümlü cihaz listesi, ⌘ bırakınca seç",
             "Remembers unplugged devices; glass device list, select on ⌘ release"),
        ]),
    ]
}
