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
        ChangelogEntry(version: "2.3.22", items: [
            ("Paylaşım kalitesi WhatsApp'a göre ayarlandı: 720p, 30 fps, H.264, ~2 Mbit/sn; yazılar hafifçe keskinleştiriliyor",
             "Sharing quality tuned for WhatsApp: 720p, 30 fps, H.264, ~2 Mbit/s, with text gently sharpened"),
            ("Sıkıştırmasız kayıt biçimi kaldırıldı (en net seçenek ProRes 4444)",
             "Removed the uncompressed recording format (ProRes 4444 is the sharpest option)"),
        ]),
        ChangelogEntry(version: "2.3.21", items: [
            ("Ekran kaydında biçim seçimi: H.264, H.265 (HEVC), ProRes 4444 ve tamamen sıkıştırmasız",
             "Choose the recording format: H.264, H.265 (HEVC), ProRes 4444 or fully uncompressed"),
            ("H.265, ProRes ve sıkıştırmasız kayıtlarda 5K/6K ekranlar küçültülmeden birebir kaydediliyor",
             "H.265, ProRes and uncompressed recordings capture 5K/6K screens at full size"),
        ]),
        ChangelogEntry(version: "2.3.20", items: [
            ("Ekran kaydına \"Paylaşım\" kalitesi: WhatsApp gibi uygulamalara gönderince yazılar okunur kalsın diye 1080p, 30 fps, küçük dosya",
             "New \"Sharing\" recording quality: 1080p, 30 fps and a small file, so text stays readable when sent through apps like WhatsApp"),
        ]),
        ChangelogEntry(version: "2.3.19", items: [
            ("Ekran kaydına \"Ham\" kalite: ekranın gerçek çözünürlüğünde, neredeyse sıkıştırmasız H.264, en net görüntü",
             "New \"Raw\" recording quality: your screen's true resolution, almost uncompressed H.264, the sharpest picture"),
        ]),
        ChangelogEntry(version: "2.3.18", items: [
            ("KeePassXC gibi bir uygulama klavyeyi kilitlediğinde (güvenli giriş) ⌘Tab artık ölmüyor: o sırada macOS'un kendi ⌘Tab'ı devreye giriyor",
             "When an app like KeePassXC locks the keyboard (secure input), ⌘Tab no longer dies: macOS's own ⌘Tab takes over meanwhile"),
            ("AudioTab çöker ya da zorla kapanırsa bir sonraki açılışta macOS kısayolları geri açılıyor; izin sonradan verilirse kısayollar kendiliğinden başlıyor",
             "If AudioTab crashes or is force-quit, macOS shortcuts are restored on the next launch; shortcuts start on their own when permission is granted later"),
        ]),
        ChangelogEntry(version: "2.3.17", items: [
            ("Profil rozeti, Chrome'un profil düğmesinde hesap adı yazan profilleri de tanıyor (rozette yine profil adı yazar)",
             "The profile badge also recognizes profiles whose Chrome profile button shows the account name (the badge still shows the profile name)"),
            ("Ayarlar › Tarayıcı profilleri › Tanı bilgisini kopyala: rozet yanlışsa sorunu bulmak için",
             "Settings › Browser profiles › Copy diagnostics: to track down a wrong badge"),
        ]),
        ChangelogEntry(version: "2.3.16", items: [
            ("Profil rozeti doğru profili gösteriyor: pencerenin araç çubuğundaki profil düğmesinin adına bakılıyor (yer imleri karıştırılmıyor)",
             "The profile badge shows the right profile: it reads the profile button in the window's toolbar (bookmarks no longer confuse it)"),
        ]),
        ChangelogEntry(version: "2.3.15", items: [
            ("Profil rozeti yeniden yapıldı: ad kesilmeden tam yazıyor",
             "Profile badge rebuilt: the name is shown in full, not cut off"),
            ("Ayarlar › Pencereler › Tarayıcı profilleri: her profilin rozetinde yazacak adı kendin belirleyebilirsin",
             "Settings › Windows › Browser profiles: choose the name shown on each profile's badge"),
        ]),
        ChangelogEntry(version: "2.3.14", items: [
            ("2.3.13'ün derleme hatası düzeltildi (sürüm serileri, güncelleme penceresi ve bildirim bu sürümle geliyor)",
             "Fixed the 2.3.13 build error (version series, the update window and notifications ship with this version)"),
        ]),
        ChangelogEntry(version: "2.3.13", items: [
            ("Sürümler sekmesi serilere ayrıldı (1.0, 2.0, 2.1, 2.2, 2.3); bir seriyi açınca alt sürümleri ve geçiş düğmeleri çıkıyor",
             "The Versions tab is grouped into series (1.0, 2.0, 2.1, 2.2, 2.3); open one to see its versions and switch to any of them"),
            ("Sürüm kutularında yazılar artık dışarı taşmıyor",
             "Text no longer spills out of the version boxes"),
            ("Menüde \"Güncellemeleri denetle…\": sonuç küçük bir pencerede, yeni sürüm varsa tek tıkla yükle",
             "\"Check for updates…\" in the menu shows the result in a small window; install a new version in one click"),
            ("Yeni sürüm çıkınca Bildirim Merkezi'ne bildirim düşüyor; tıklayınca güncelleme penceresi açılıyor",
             "A notification appears when a new version is out; click it to open the update window"),
        ]),
        ChangelogEntry(version: "2.3.12", items: [
            ("Profil rozeti tam okunuyor; Chrome'da profile verdiğin ad yazıyor (aynı ada sahip profiller e-postayla ayrılır)",
             "The profile badge is no longer cut off and shows the name you gave the Chrome profile (profiles with the same name are told apart by email)"),
            ("Farenin 4. ve 5. tuşlarıyla Finder'da geri / ileri (ayarlardan kapatılabilir)",
             "Mouse buttons 4 and 5 go back / forward in Finder (can be turned off)"),
            ("\"Pencereleri her zaman bul\" listesine tarayıcıların yanında istediğin uygulamaları ekleyebilirsin",
             "Add any apps you like to \"Always find windows\", alongside browsers"),
            ("Sürümler sekmesi yeni tasarım: eşit boyda kutular, uzun listeler düğmeyle büyüyor",
             "New Versions tab layout: equal-size boxes; long lists expand with a button"),
            ("Uzun proje adları artık kaybolmuyor, \"…\" ile kısalıyor",
             "Long project names no longer disappear; they're shortened with \"…\""),
        ]),
        ChangelogEntry(version: "2.3.11", items: [
            ("Tarayıcı kartlarında pencerenin hangi profile ait olduğu küçük bir rozetle yazıyor (Chrome, Brave, Edge, Vivaldi)",
             "Browser cards show which profile the window belongs to in a small badge (Chrome, Brave, Edge, Vivaldi)"),
        ]),
        ChangelogEntry(version: "2.3.10", items: [
            ("Finder favorileri artık doğrudan Finder'ın kenar çubuğundaki Favoriler listesinden, aynı sırayla geliyor",
             "Finder favorites now come straight from Finder's sidebar Favorites, in the same order"),
            ("Kenar çubuğu ⌘Tab ve ⌥Tab için ayrı ayrı: her birinde açma/kapama ve kendi klasör listesi",
             "The sidebar is set separately for ⌘Tab and ⌥Tab: each has its own toggles and folder list"),
        ]),
        ChangelogEntry(version: "2.3.9", items: [
            ("⌘Tab'da isteğe bağlı kenar çubuğu: sık kullanılan klasörlerin ve Finder favorileri en sağda, Finder'daki gibi",
             "Optional ⌘Tab sidebar: your favorite folders and Finder Favorites on the far right, just like in Finder"),
            ("Dock'a sürükle-bırak: dosyayı Dock'taki uygulamanın üstüne getirince uygulama hemen öne gelir (ayarlardan kapatılabilir)",
             "Drag to the Dock: hovering a dragged file over an app in the Dock brings it forward right away (can be turned off)"),
        ]),
        ChangelogEntry(version: "2.3.8", items: [
            ("⌘Tab'da bir kartın üstündeyken Tab'ın üstündeki tuş (é): sadece o uygulamanın pencereleri; tekrar basınca hepsi (geçici). F de aynı işi yapar",
             "In ⌘Tab, press the key above Tab (`) on a card to show only that app's windows; press again for all (temporary). F works too"),
            ("Ekran bölme panelleri de dışına tıklayınca kapanıyor (Esc gibi)",
             "Split-screen panels now close when you click outside them (like Esc)"),
        ]),
        ChangelogEntry(version: "2.3.7", items: [
            ("Gruplu görünümde her sütunda en fazla 2 kart; fazlası yana geçer, panel aşağı uzamaz",
             "Grouped view: at most 2 cards per column; extra windows go to a new column so the panel stays short"),
        ]),
        ChangelogEntry(version: "2.3.6", items: [
            ("Proje adı artık büyük ve net: önizlemenin altında uygulamaya özgü renkte şerit",
             "Project names are now large and clear: a band in the app's own color under the preview"),
            ("Kart başlığında da uzun pencere başlığı yerine proje adı",
             "The card title shows the project name instead of the long window title"),
            ("Gruplu görünüm yatay: bölümler yan yana, aralarında ince çizgi; Klasörler hep en sağda",
             "Grouped view is horizontal: sections side by side with thin dividers; Folders always on the far right"),
        ]),
        ChangelogEntry(version: "2.3.5", items: [
            ("İsteğe bağlı gruplu ⌘Tab görünümü: Klasörler · Tarayıcılar · Projeler · Geliştirme · Uygulamalar",
             "Optional grouped ⌘Tab view: Folders · Browsers · Projects · Development · Apps"),
            ("Klasör kartlarında önizleme yerine klasörün adı büyük yazılır",
             "Folder cards show the folder name in large type instead of a preview"),
            ("DaVinci, Adobe, Final Cut, Logic, Ableton, Blender… otomatik algılanır, proje adı önizlemenin üstünde",
             "DaVinci, Adobe, Final Cut, Logic, Ableton, Blender… are detected and the project name is shown on the preview"),
            ("Proje uygulamaları listesini Ayarlar › Pencereler'den düzenleyebilirsin",
             "Edit the list of project apps in Settings › Windows"),
        ]),
        ChangelogEntry(version: "2.3.4", items: [
            ("Açık olmayan (gizli) pencereler artık listeye gelmiyor",
             "Hidden helper windows no longer show up in the list"),
            ("Tarayıcı pencereleri (tüm Chrome profilleri) Dock'a küçültülmüş olsa da ⌘Tab ve ⌥Tab'da görünür",
             "Browser windows (every Chrome profile) show in ⌘Tab and ⌥Tab even when minimized to the Dock"),
        ]),
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
