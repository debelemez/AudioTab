import Cocoa
import SwiftUI
import ServiceManagement
import ApplicationServices

// MARK: - Ayar taşıma (GlassTab + AudioHop → AudioTab)

enum Migration {
    /// Eski iki uygulamanın ayarlarını bir kereye mahsus bu uygulamaya kopyalar.
    /// Uygulama sandbox'sız olduğu için diğer uygulamaların tercih dosyaları okunabilir.
    static func run() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "migratedFromGlassTabAudioHop") else { return }
        for domain in ["com.firewallstudio.glasstab", "com.audiohop.app"] {
            guard let old = d.persistentDomain(forName: domain) else { continue }
            for (key, value) in old where !key.hasPrefix("NS") && !key.hasPrefix("Apple") && d.object(forKey: key) == nil {
                d.set(value, forKey: key)
            }
        }
        d.set(true, forKey: "migratedFromGlassTabAudioHop")
    }
}

// MARK: - Ayarlar modeli

final class SettingsModel: ObservableObject {
    let store: DeviceStore
    var onNativeTabChanged: () -> Void = {}
    var onHotkeyChanged: () -> Void = {}
    var onPreviewsChanged: () -> Void = {}
    var onDeepScanChanged: () -> Void = {}
    /// ⌘⇧3/4/5/6 veya ⌘< açılıp kapandı → macOS kısayollarını güncelle
    var onShortcutsChanged: () -> Void = {}
    /// Dock'a sürükle-bırak hızlandırma açılıp kapandı
    var onDockDragChanged: () -> Void = {}
    /// Güncellemeyi yükle (kayıt sürüyorsa önce bitirilir)
    var onInstallUpdate: (ReleaseInfo?) -> Void = { _ in }

    init(store: DeviceStore) { self.store = store }

    /// UserDefaults'a yazan ayarlar için Binding; değişince ekranı yeniler.
    func bind<T>(_ get: @escaping () -> T, _ set: @escaping (T) -> Void) -> Binding<T> {
        Binding(get: get, set: { [weak self] value in
            self?.objectWillChange.send()
            set(value)
        })
    }

    func refresh() { objectWillChange.send() }

    var axTrusted: Bool { AXIsProcessTrusted() }
    var screenTrusted: Bool { CGPreflightScreenCaptureAccess() }
    var anyPreviews: Bool { Profile.allCases.contains { $0.enabled && $0.previews } }

    func profileBinding(_ p: Profile, _ key: String) -> Binding<Bool> {
        bind({ p.get(key) }, { [weak self] value in
            guard p.get(key) != value else { return }
            p.toggle(key)
            if key == "enabled" && p == .cmd { self?.onNativeTabChanged() }
            if key == "previews" || key == "enabled" { self?.onPreviewsChanged() }
        })
    }

    var loginBinding: Binding<Bool> {
        bind({ SMAppService.mainApp.status == .enabled }, { on in
            do {
                if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch { NSSound.beep() }
        })
    }

    static func open(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Ayarlar penceresi

final class SettingsWindowController: NSObject, NSWindowDelegate {
    let model: SettingsModel
    private var window: NSWindow?

    init(model: SettingsModel) { self.model = model }

    func show() {
        let w = window ?? makeWindow()
        window = w
        model.refresh()
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 700),
                         styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.title = L("AudioTab Ayarları")
        w.isMovableByWindowBackground = true
        w.isOpaque = false
        w.backgroundColor = .clear
        w.appearance = NSAppearance(named: .darkAqua)
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.contentView = NSHostingView(rootView: SettingsView(model: model, store: model.store, updater: Updater.shared))
        w.center()
        return w
    }

    // İzin durumları pencereye her dönüşte tazelensin
    func windowDidBecomeKey(_ notification: Notification) { model.refresh() }
}

// MARK: - Görünüm

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var store: DeviceStore
    @ObservedObject var updater: Updater
    @State private var tab = 0
    @State private var confirmRelease: ReleaseInfo?

    private let tabs = [(L("Ses"), "speaker.wave.2.fill"),
                        (L("Pencereler"), "rectangle.on.rectangle"),
                        (L("Ekran"), "camera.viewfinder"),
                        (L("İzinler"), "lock.shield.fill"),
                        (L("Genel"), "gearshape.fill"),
                        (L("Sürümler"), "clock.arrow.circlepath")]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(tabs.indices, id: \.self) { i in
                    Button { tab = i } label: {
                        Label(tabs[i].0, systemImage: tabs[i].1)
                            .font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(.white.opacity(tab == i ? 0.20 : 0)))
                            .overlay(Capsule().strokeBorder(.white.opacity(tab == i ? 0.30 : 0), lineWidth: 1))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(tab == i ? 1 : 0.6))
                }
            }
            .padding(5)
            .background(Capsule().fill(.white.opacity(0.06)))
            .padding(.top, 38)
            .padding(.bottom, 14)

            ScrollView {
                VStack(spacing: 14) {
                    switch tab {
                    case 0: audioTab
                    case 1: windowsTab
                    case 2: screenTab
                    case 3: permissionsTab
                    case 4: generalTab
                    default: versionsTab
                    }
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 22)
            }
        }
        .frame(width: 680, height: 700)
        .background(
            ZStack {
                GlassBlur(material: .hudWindow)
                Color.black.opacity(0.30)
                LinearGradient(colors: [.white.opacity(0.10), .clear], startPoint: .top, endPoint: .center)
            }
            .ignoresSafeArea()
        )
        .foregroundStyle(Color.white)
        .environment(\.colorScheme, .dark)
        .alert(L("AudioTab %@ yüklensin mi?", confirmRelease?.version ?? ""),
               isPresented: Binding(get: { confirmRelease != nil }, set: { if !$0 { confirmRelease = nil } })) {
            Button(L("Yükle ve yeniden aç")) {
                if let r = confirmRelease { model.onInstallUpdate(r) }
                confirmRelease = nil
            }
            Button(L("Vazgeç"), role: .cancel) { confirmRelease = nil }
        } message: {
            Text(confirmMessage)
        }
    }

    // MARK: Ses

    @ViewBuilder private var audioTab: some View {
        let key = store.hotkeyChoice
        Card(title: L("Kısayol"), icon: "keyboard") {
            Row(L("Tuş kombinasyonu"),
                key == .cmdShift ? L("⌘ basılıyken ⇧'ye dokun. ⌘⇧4 gibi kısayolları bozmaz.") : "⌘ + Caps Lock") {
                Picker("", selection: model.bind({ store.hotkeyChoice }, { v in
                    store.hotkeyChoice = v
                    model.onHotkeyChanged()
                })) {
                    Text("⌘⇧").tag(HotkeyChoice.cmdShift)
                    Text("⌘⇪").tag(HotkeyChoice.cmdCaps)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 120)
            }
            Divider().opacity(0.4)
            Row(L("%@ basınca", key.symbol), nil) {
                Picker("", selection: model.bind({ store.mode }, { store.mode = $0 })) {
                    Text(L("Sıradakine geç")).tag(HotkeyMode.cycle)
                    Text(L("Listeyi göster")).tag(HotkeyMode.panel)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240)
            }
            if store.mode == .panel {
                ToggleRow(L("⌘ bırakınca seç"), L("⌘+Tab gibi: ⌘'yi bırakınca vurgulu cihaz seçilir"),
                          isOn: model.bind({ store.selectOnRelease }, { store.selectOnRelease = $0 }))
            } else {
                ToggleRow(L("Geçişte bildirim göster"), L("Ekranın altında küçük cam bildirim"),
                          isOn: model.bind({ store.showHUD }, { store.showHUD = $0 }))
            }
            if key == .cmdCaps {
                ToggleRow(L("Caps Lock'u açık bırakma"), L("⌘⇪ sonrası Caps Lock eski haline döner"),
                          isOn: model.bind({ store.keepCapsLock }, { v in
                              store.keepCapsLock = v
                              model.onHotkeyChanged()
                          }))
            }
        }

        Card(title: L("Ses cihazları"), icon: "hifispeaker.2.fill") {
            Row(L("Listede görünenler"), nil) {
                Picker("", selection: model.bind({ store.panelShowAll }, { store.panelShowAll = $0 })) {
                    Text(L("Tümü")).tag(true)
                    Text(L("Seçtiklerim")).tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
            }
            Divider().opacity(0.4)

            HStack {
                Text(L("Cihaz")).frame(maxWidth: .infinity, alignment: .leading)
                Text(L("%@ döngüsü", key.symbol)).frame(width: 82)
                Text(L("Listede")).frame(width: 60)
                Color.clear.frame(width: 26)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(0.55))

            if store.rows.isEmpty {
                Text(L("Henüz cihaz yok")).foregroundStyle(.white.opacity(0.5))
            }
            ForEach(store.rows) { row in
                HStack(spacing: 10) {
                    Image(systemName: row.symbol)
                        .frame(width: 22)
                        .foregroundStyle(row.isCurrent ? Color.accentColor : .white.opacity(0.85))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Text(row.isCurrent ? L("Şu an çalıyor") : (row.isConnected ? L("Bağlı") : L("Bağlı değil · hatırlanıyor")))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Toggle("", isOn: Binding(get: { row.inCycle }, set: { _ in store.toggleCycle(row.id) }))
                        .toggleStyle(.checkbox).labelsHidden()
                        .frame(width: 82)
                    Toggle("", isOn: Binding(get: { store.panelShowAll || row.inPanel },
                                             set: { _ in togglePanel(row.id) }))
                        .toggleStyle(.checkbox).labelsHidden()
                        .frame(width: 60)

                    Group {
                        if !row.isConnected {
                            Button { store.forget(row.id) } label: { Image(systemName: "trash") }
                                .buttonStyle(.plain)
                                .foregroundStyle(.white.opacity(0.6))
                                .help(L("Bu cihazı unut"))
                        } else {
                            Color.clear
                        }
                    }
                    .frame(width: 26)
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(row.isCurrent ? 0.10 : 0.03)))
                .opacity(row.isConnected ? 1 : 0.6)
            }

            if store.usingFallback {
                Text(L("Döngüde 2'den az takılı cihaz var → kısayol tüm takılı cihazlar arasında geçer."))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
            }
            if store.passthroughActive {
                Label(L("eqMac algılandı: ses eqMac üzerinden seçtiğin cihaza gidiyor."), systemImage: "slider.vertical.3")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }

        appAudioCard
    }

    // MARK: Uygulamaya göre ses

    private func appInfo(_ bid: String) -> (name: String, icon: NSImage?) {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
            let name = FileManager.default.displayName(atPath: url.path)
            return (name.hasSuffix(".app") ? String(name.dropLast(4)) : name, NSWorkspace.shared.icon(forFile: url.path))
        }
        return (bid, nil)
    }

    @ViewBuilder private var appAudioCard: some View {
        Card(title: L("Uygulamaya göre ses cihazı"), icon: "app.badge") {
            ToggleRow(L("Uygulamaya geçince ses cihazını değiştir"),
                      L("Atadığın uygulama öne gelince ses o cihaza geçer. ⌘Tab açıkken S ile de atayabilirsin."),
                      isOn: model.bind({ store.autoSwitchByApp }, { store.autoSwitchByApp = $0 }))
            Divider().opacity(0.4)

            let mapped = store.appAudio.keys.sorted { appInfo($0).name.localizedCaseInsensitiveCompare(appInfo($1).name) == .orderedAscending }
            if mapped.isEmpty {
                Text(L("Henüz atama yok."))
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
            }
            ForEach(mapped, id: \.self) { bid in
                let info = appInfo(bid)
                HStack(spacing: 10) {
                    if let icon = info.icon {
                        Image(nsImage: icon).resizable().frame(width: 24, height: 24)
                    } else {
                        Image(systemName: "app").frame(width: 24, height: 24)
                    }
                    Text(info.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Spacer()
                    Picker("", selection: Binding(
                        get: { store.appAudio[bid] ?? "" },
                        set: { store.setAppDevice($0.isEmpty ? nil : $0, bundleID: bid) })) {
                        Text(L("Atama yok")).tag("")
                        ForEach(store.rows) { row in
                            Text(row.isConnected ? row.name : L("%@ (bağlı değil)", row.name)).tag(row.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 220)
                    Button { store.setAppDevice(nil, bundleID: bid) } label: { Image(systemName: "trash") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white.opacity(0.6))
                        .help(L("Atamayı kaldır"))
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.03)))
            }

            let candidates = NSWorkspace.shared.runningApplications
                .filter { app -> Bool in
                    guard app.activationPolicy == .regular, let bid = app.bundleIdentifier else { return false }
                    if bid == Bundle.main.bundleIdentifier { return false }
                    return store.appAudio[bid] == nil
                }
                .sorted { ($0.localizedName ?? "").localizedCaseInsensitiveCompare($1.localizedName ?? "") == .orderedAscending }
            Menu {
                ForEach(candidates, id: \.processIdentifier) { app in
                    Button(app.localizedName ?? (app.bundleIdentifier ?? "?")) {
                        if let bid = app.bundleIdentifier, let uid = store.current?.uid ?? store.rows.first(where: \.isConnected)?.id {
                            store.setAppDevice(uid, bundleID: bid)
                        }
                    }
                }
            } label: {
                Label(L("Açık bir uygulama ekle"), systemImage: "plus.circle.fill")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(candidates.isEmpty)
        }
    }

    /// "Tümü" modundayken bir cihazın işaretini kaldırmak: o cihaz hariç hepsini seçili yap.
    private func togglePanel(_ uid: String) {
        if store.panelShowAll {
            for k in store.knownDevices where k.uid != uid && !store.isInPanel(k.uid) { store.togglePanel(k.uid) }
            if store.isInPanel(uid) { store.togglePanel(uid) }
            store.panelShowAll = false
        } else {
            store.togglePanel(uid)
        }
        model.refresh()
    }

    // MARK: Pencereler

    @ViewBuilder private var windowsTab: some View {
        ForEach(Profile.allCases, id: \.self) { p in
            Card(title: p.title, icon: p == .cmd ? "command" : "option") {
                ToggleRow(L("Kısayolu kullan"),
                          p == .cmd ? L("Kapatınca macOS'un kendi ⌘Tab'ı geri gelir") : nil,
                          isOn: model.profileBinding(p, "enabled"))
                Divider().opacity(0.4)
                Row(L("Görünüm"), p.list ? L("Alt alta satırlar, ses listesi gibi")
                                    : p.grouped ? L("Yan yana bölümler: Tarayıcılar · Projeler · Geliştirme · Uygulamalar · Klasörler")
                                    : L("Kartlar yan yana")) {
                    Picker("", selection: model.bind({ p.list ? 1 : (p.grouped ? 2 : 0) }, { v in
                        p.list = v == 1
                        p.grouped = v == 2
                        if v == 2 { p.previews = true }   // gruplu görünüm önizlemelerle tasarlandı
                    })) {
                        Text(L("Izgara")).tag(0)
                        Text(L("Liste")).tag(1)
                        Text(L("Gruplu")).tag(2)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 230)
                }
                .disabled(!p.enabled)
                ToggleRow(L("Pencere önizlemeleri"), p.list ? L("Liste görünümünde kullanılmaz") : L("Ekran Kaydı izni gerekir (macOS 14+)"),
                          isOn: model.profileBinding(p, "previews"))
                    .disabled(!p.enabled || p.list)
                ToggleRow(L("Küçültülmüş pencereler"), L("Küçültülmüş ve penceresiz uygulamaları da göster"),
                          isOn: model.profileBinding(p, "showMinimized"))
                    .disabled(!p.enabled)
                Divider().opacity(0.4)
                Row(L("Hangi uygulamalar"), L("Sadece seçilen uygulamanın pencereleri arasında geçer (ör. tüm Chrome pencereleri). Panel açıkken A ile değiştirebilirsin.")) {
                    Picker("", selection: model.bind({ p.appFilter }, { p.appFilter = $0 })) {
                        Text(L("Tüm uygulamalar")).tag("")
                        ForEach(filterChoices(p)) { c in Text(c.name).tag(c.id) }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                }
                .disabled(!p.enabled)
                Divider().opacity(0.4)
                sidebarRows(p)
                    .disabled(!p.enabled)
            }
        }
        if Profile.allCases.contains(where: { $0.grouped && !$0.list }) { groupedCard }
        Card(title: L("Dock'a sürükle-bırak"), icon: "dock.arrow.up.rectangle") {
            ToggleRow(L("Üstüne gelince uygulamayı hemen aç"),
                      L("Bir dosyayı sürüklerken Dock'taki uygulamanın üstüne gelince beklemeden öne gelir (kapalıysa açılır); dosyayı doğrudan penceresine bırakırsın"),
                      isOn: model.bind({ DockDragSettings.enabled }, { v in
                          DockDragSettings.enabled = v
                          model.onDockDragChanged()
                      }))
        }
        Card(title: L("Pencereleri her zaman bul"), icon: "scope") {
            Row(L("Kapsam"), L("Diğer masaüstlerindeki, tam ekrandaki ve arkada kalan pencereleri de kesin gösterir (Chrome profilleri dahil). Arka planda, sadece masaüstü değişince ve uygulama açılınca güncellenir.")) {
                Picker("", selection: model.bind({ DeepScanScope.current }, { v in
                    DeepScanScope.current = v
                    model.onDeepScanChanged()
                })) {
                    Text(L("Kapalı")).tag(DeepScanScope.off)
                    Text(L("Tarayıcılar")).tag(DeepScanScope.browsers)
                    Text(L("Tümü")).tag(DeepScanScope.all)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 250)
            }
        }
        Card(title: L("Panelde kısayollar"), icon: "keyboard") {
            VStack(alignment: .leading, spacing: 5) {
                shortcut("Tab / ⇧Tab", L("İleri / geri"))
                shortcut("← → ↑ ↓", L("Gezin"))
                shortcut(L("⌘'yi bırak, ↩, Space, tıkla"), L("Seçili pencereye geç"))
                shortcut("Esc", L("İptal"))
                shortcut("W · M · H · Q", L("Kapat · Küçült · Gizle · Çık"))
                shortcut("S", L("Uygulamanın ses cihazını değiştir"))
                shortcut(L("é (Tab'ın üstündeki tuş) · F"), L("Sadece seçili kartın uygulaması / hepsine dön (geçici)"))
                shortcut("A / ⇧A", L("Sadece bir uygulamanın pencereleri: sonraki / önceki uygulama"))
            }
        }
    }

    /// Kenar çubuğu: bu kısayola özel (⌘Tab ve ⌥Tab ayrı ayrı)
    @ViewBuilder private func sidebarRows(_ p: Profile) -> some View {
        ToggleRow(L("Kenar çubuğu: sık kullanılan klasörlerim"), L("Panelin en sağında, aşağıda eklediğin klasörler"),
                  isOn: model.bind({ Favorites.showOwn(p) }, { Favorites.setShowOwn($0, p) }))
        ToggleRow(L("Kenar çubuğu: Finder favorileri"), L("Finder'ın kenar çubuğundaki Favoriler, Finder'daki gibi listelenir"),
                  isOn: model.bind({ Favorites.showFinder(p) }, { Favorites.setShowFinder($0, p) }))
        if Favorites.showOwn(p) {
            Row(L("Klasörler"), L("Tıklayınca Finder'da açılır")) {
                Button(L("Klasör ekle…")) { addFavoriteFolders(p) }
            }
            let paths = Favorites.folders(p)
            if paths.isEmpty {
                Text(L("Henüz klasör eklemedin.")).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
            } else {
                FlowChips(items: paths.map { ChipItem(id: $0, name: FileManager.default.displayName(atPath: $0)) }) { path in
                    Favorites.remove(path, from: p); model.refresh()
                }
            }
        }
    }

    private func addFavoriteFolders(_ profile: Profile) {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = true
        p.prompt = L("Ekle")
        NSApp.activate(ignoringOtherApps: true)
        if p.runModal() == .OK {
            Favorites.add(p.urls, to: profile)
            model.refresh()
        }
    }

    // MARK: Gruplu görünüm ayarları

    @ViewBuilder private var groupedCard: some View {
        Card(title: L("Gruplu görünüm"), icon: "square.grid.3x1.below.line.grid.1x2") {
            ToggleRow(L("Klasör adlarını büyük göster"), L("Finder pencerelerinde önizleme yerine klasörün adı"),
                      isOn: model.bind({ GroupSettings.bigFolderNames }, { GroupSettings.bigFolderNames = $0 }))
            ToggleRow(L("Proje adlarını göster"), L("DaVinci, Adobe, Final Cut, Logic, Ableton, Blender… pencere başlığından proje adı okunur ve önizlemenin üstüne yazılır"),
                      isOn: model.bind({ GroupSettings.showProjectNames }, { GroupSettings.showProjectNames = $0 }))
            Divider().opacity(0.4)
            Row(L("Proje uygulamaları"), L("Otomatik algılananlar ve eklediklerin. Bunlar Projeler bölümünde görünür.")) {
                Menu(L("Ekle")) {
                    ForEach(runningApps().filter { !GroupSettings.isProjectApp($0.id) }) { a in
                        Button(a.name) { GroupSettings.addProjectApp(a.id); model.objectWillChange.send() }
                    }
                }
                .frame(width: 110)
            }
            let current = projectAppList()
            if current.isEmpty {
                Text(L("Şu an açık proje uygulaması yok. DaVinci, Adobe gibi uygulamalar açılınca otomatik algılanır."))
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
            } else {
                FlowChips(items: current.map { ChipItem(id: $0.id, name: $0.name) }) { bid in
                    GroupSettings.removeProjectApp(bid); model.objectWillChange.send()
                }
            }
        }
    }

    /// Açık uygulamalar (paket kimliği + ad), ada göre sıralı
    private func runningApps() -> [AppChoice] {
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .compactMap { a in a.bundleIdentifier.map { AppChoice(id: $0, name: a.localizedName ?? $0) } }
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Şu an Projeler bölümüne giren uygulamalar: açık olanlar + kullanıcının eklediği (kapalı olsa da)
    private func projectAppList() -> [AppChoice] {
        var list = runningApps().filter { GroupSettings.isProjectApp($0.id) }
        let ids = Set(list.map(\.id))
        for bid in GroupSettings.addedProjectApps where !ids.contains(bid) {
            let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid)
                .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? bid
            list.append(AppChoice(id: bid, name: name))
        }
        return list
    }

    /// Açık uygulamalar (+ kayıtlı seçim kapalı bir uygulamaysa o da), ada göre sıralı
    private struct AppChoice: Identifiable { let id: String; let name: String }

    private func filterChoices(_ p: Profile) -> [AppChoice] {
        var list: [AppChoice] = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .compactMap { a in a.bundleIdentifier.map { AppChoice(id: $0, name: a.localizedName ?? $0) } }
        var seen = Set<String>()
        list = list.filter { seen.insert($0.id).inserted }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let cur = p.appFilter
        if !cur.isEmpty, !seen.contains(cur) {
            let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: cur)
                .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? cur
            list.insert(AppChoice(id: cur, name: name), at: 0)
        }
        return list
    }

    private func shortcut(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.system(size: 12, weight: .semibold, design: .rounded)).frame(width: 190, alignment: .leading)
            Text(v).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
            Spacer()
        }
    }

    // MARK: Ekran (bölme + çekim)

    @ViewBuilder private var screenTab: some View {
        Card(title: L("Ekranı böl  ⌘<"), icon: "rectangle.split.3x1") {
            ToggleRow(L("Kısayolu kullan"),
                      L("⌘< → kaça bölüneceğini seç → hangi pencere hangi bölmeye. ⌘Tab kartlarındaki bölme düğmesi aynı işi tek pencere için yapar. Açıkken macOS'un ⌘< (aynı uygulamanın pencereleri arasında geçiş) kısayolu kapanır."),
                      isOn: model.bind({ TileSettings.enabled }, { v in
                          TileSettings.enabled = v
                          model.onShortcutsChanged()
                      }))
            if TileSettings.enabled {
                Divider().opacity(0.4)
                Row(L("Hedef monitör"), L("Birden fazla monitör varken. Panelde Tab ile her zaman değiştirebilirsin.")) {
                    Picker("", selection: model.bind({ TileSettings.askMonitor }, { TileSettings.askMonitor = $0 })) {
                        Text(L("Farenin olduğu")).tag(false)
                        Text(L("Her seferinde sor")).tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 250)
                }
                Row(L("Pencere arası boşluk"), "\(Int(TileSettings.gap)) pt") {
                    Slider(value: model.bind({ TileSettings.gap }, { TileSettings.gap = $0 }), in: 0...24, step: 2)
                        .frame(width: 200)
                }
            }
        }

        Card(title: L("Ekran görüntüsü ve kayıt"), icon: "camera.viewfinder") {
            ToggleRow(L("Kullan"),
                      L("Kapatınca hepsi devre dışı kalır ve macOS'un kendi ⌘⇧3 / ⌘⇧4 / ⌘⇧5 kısayolları geri gelir."),
                      isOn: model.bind({ CaptureSettings.enabled }, { v in
                          CaptureSettings.enabled = v
                          model.onShortcutsChanged()
                      }))
            if CaptureSettings.enabled {
                Divider().opacity(0.4)
                captureRow(.screen, key: "⌘⇧3", title: L("Bu monitörün görüntüsü"), detail: L("Sadece farenin olduğu monitör"),
                           isOn: model.bind({ CaptureSettings.screenKey }, { v in CaptureSettings.screenKey = v; model.onShortcutsChanged() }))
                captureRow(.area, key: "⌘⇧4", title: L("Ekran alıntısı"), detail: L("Alan seç; Space ile pencere seçimi"),
                           isOn: model.bind({ CaptureSettings.areaKey }, { v in CaptureSettings.areaKey = v; model.onShortcutsChanged() }))
                captureRow(.scroll, key: "⌘⇧6", title: L("Kaydırmalı görüntü"), detail: L("Alanı seç, sayfa kendiliğinden kayar · Esc bitirir"),
                           isOn: model.bind({ CaptureSettings.scrollKey }, { v in CaptureSettings.scrollKey = v; model.onShortcutsChanged() }))
                captureRow(.video, key: "⌘⇧5", title: L("Ekran kaydı (MP4 · H.264)"), detail: L("Çekim paleti; kayıt sırasında ⌘⇧5 durdurur"),
                           isOn: model.bind({ CaptureSettings.videoKey }, { v in CaptureSettings.videoKey = v; model.onShortcutsChanged() }))
                HStack {
                    Spacer()
                    Button(L("Hepsini tek klasöre kaydet…")) { pickFolderForAll() }
                }
                Divider().opacity(0.4)
                ToggleRow(L("Panoya da kopyala"), L("Görüntüler kaydedilirken panoya da alınır"),
                          isOn: model.bind({ CaptureSettings.copyToClipboard }, { CaptureSettings.copyToClipboard = $0 }))
                ToggleRow(L("Deklanşör sesi"), nil,
                          isOn: model.bind({ CaptureSettings.playSound }, { CaptureSettings.playSound = $0 }))
            }
        }

        if CaptureSettings.enabled {
            Card(title: L("Video kaydı"), icon: "record.circle") {
                Row(L("Kare hızı"), nil) {
                    Picker("", selection: model.bind({ CaptureSettings.fps }, { CaptureSettings.fps = $0 })) {
                        Text("30 fps").tag(30)
                        Text("60 fps").tag(60)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 160)
                }
                Row(L("Kalite"), CaptureSettings.maxQuality ? L("Kayıpsıza yakın, dosya büyük") : L("Görüntü bozulmaz, dosya makul boyutta")) {
                    Picker("", selection: model.bind({ CaptureSettings.maxQuality }, { CaptureSettings.maxQuality = $0 })) {
                        Text(L("Yüksek")).tag(false)
                        Text(L("En yüksek")).tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 180)
                }
                ToggleRow(L("Sistem sesini kaydet"), L("Bilgisayardan çıkan ses videoya eklenir"),
                          isOn: model.bind({ CaptureSettings.recordAudio }, { CaptureSettings.recordAudio = $0 }))
                ToggleRow(L("İmleci göster"), nil,
                          isOn: model.bind({ CaptureSettings.showCursor }, { CaptureSettings.showCursor = $0 }))
                Label(L("Kayıt sırasında sağ üstte kırmızı nokta ve süre görünür. Sadece sen görürsün, kayda girmez. Tıklayınca kayıt durur."),
                      systemImage: "record.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
    }

    private func captureRow(_ kind: CaptureKind, key: String, title: String, detail: String, isOn: Binding<Bool>) -> some View {
        let folder = CaptureSettings.folder(kind)
        return HStack(spacing: 10) {
            Text(key)
                .font(.system(size: 11.5, weight: .bold, design: .rounded))
                .frame(width: 46, height: 22)
                .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.12)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.5))
                Button {
                    NSWorkspace.shared.open(folder)
                } label: {
                    Label((folder.path as NSString).abbreviatingWithTildeInPath, systemImage: "folder")
                        .font(.system(size: 10.5))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .help(L("Klasörü Finder'da aç"))
            }
            Spacer(minLength: 8)
            Button(L("Klasör…")) { pickFolder(kind) }
            Toggle("", isOn: isOn).toggleStyle(.switch).labelsHidden()
        }
        .padding(.vertical, 4)
    }

    private func pickFolder(_ kind: CaptureKind) {
        if let url = choose(start: CaptureSettings.folder(kind)) {
            CaptureSettings.setFolder(url, for: kind)
            model.refresh()
        }
    }

    private func pickFolderForAll() {
        if let url = choose(start: CaptureSettings.folder(.screen)) {
            for k in CaptureKind.allCases { CaptureSettings.setFolder(url, for: k) }
            model.refresh()
        }
    }

    private func choose(start: URL) -> URL? {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.allowsMultipleSelection = false
        p.prompt = L("Seç")
        p.directoryURL = start
        NSApp.activate(ignoringOtherApps: true)
        return p.runModal() == .OK ? p.url : nil
    }

    // MARK: İzinler

    @ViewBuilder private var permissionsTab: some View {
        let ax = model.axTrusted
        let sc = model.screenTrusted
        Card(title: L("Durum"), icon: "checkmark.shield") {
            HStack(spacing: 10) {
                Image(systemName: ax ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(ax ? Color.green : Color.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ax ? L("Kısayollar çalışıyor") : L("Kısayollar için izin gerekli"))
                        .font(.system(size: 14, weight: .semibold))
                    Text(ax ? L("⌘Tab, ⌥Tab ve ses kısayolu aktif.") : L("Erişilebilirlik izni verilene kadar hiçbir kısayol çalışmaz."))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.6))
                }
                Spacer()
                Button { model.refresh() } label: { Label(L("Yenile"), systemImage: "arrow.clockwise") }
            }
        }
        Card(title: L("Gerekli izinler"), icon: "lock.shield") {
            PermissionRow(title: L("Erişilebilirlik"),
                          detail: L("⌘Tab, ⌥Tab ve ses kısayolu (⌘⇧ / ⌘⇪) için. Pencerelere geçmek, kapatmak, küçültmek için de kullanılır."),
                          granted: ax) { SettingsModel.open("Privacy_Accessibility") }
            Divider().opacity(0.4)
            PermissionRow(title: L("Ekran Kaydı"),
                          detail: (model.anyPreviews || CaptureSettings.enabled)
                            ? L("Pencere önizlemeleri, ekran görüntüsü ve ekran kaydı için. İzni verdikten sonra uygulamayı bir kez kapatıp aç.")
                            : L("Şu an gerekmiyor: önizlemeler ve ekran çekimi kapalı."),
                          granted: sc) { SettingsModel.open("Privacy_ScreenCapture") }
        }
        Card(title: L("Bilgi"), icon: "info.circle") {
            VStack(alignment: .leading, spacing: 6) {
                Label(L("Giriş İzleme izni gerekmez (eski AudioHop'tan kalmışsa kapatabilirsin)."), systemImage: "keyboard")
                Label(L("Yeniden derledikten sonra izin açık görünüp çalışmıyorsa: listeden AudioTab'ı – ile kaldırıp + ile tekrar ekle."), systemImage: "arrow.triangle.2.circlepath")
                Label(L("Hiçbir şey kaydedilmez, diske yazılmaz, internete gönderilmez."), systemImage: "hand.raised.fill")
            }
            .font(.system(size: 11.5))
            .foregroundStyle(.white.opacity(0.65))
        }
    }

    // MARK: Güncelleme

    private var updateStatus: (String, String, Color) {
        switch updater.state {
        case .idle: return (L("Henüz denetlenmedi"), "clock", .white.opacity(0.6))
        case .checking: return (L("Denetleniyor…"), "arrow.triangle.2.circlepath", .white.opacity(0.8))
        case .upToDate: return (L("Güncel"), "checkmark.circle.fill", .green)
        case .available(let v): return (L("Yeni sürüm var: %@", v), "arrow.down.circle.fill", .accentColor)
        case .downloading: return (L("İndiriliyor…"), "arrow.down.circle", .white.opacity(0.8))
        case .installing: return (L("Yükleniyor, uygulama yeniden açılacak…"), "gearshape.2", .white.opacity(0.8))
        case .failed(let m): return (m, "exclamationmark.triangle.fill", .orange)
        }
    }

    @ViewBuilder private var updateCard: some View {
        let status = updateStatus
        Card(title: L("Güncellemeler"), icon: "arrow.down.app") {
            Row(L("Sürüm %@", updater.currentVersion), nil) {
                HStack(spacing: 10) {
                    Label(status.0, systemImage: status.1)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(status.2)
                        .lineLimit(2)
                    if updater.updateAvailable {
                        Button(L("Yükle ve yeniden aç")) { model.onInstallUpdate(nil) }
                            .keyboardShortcut(.defaultAction)
                    } else {
                        Button(L("Şimdi denetle")) { updater.check(userInitiated: true) }
                            .disabled(updater.state == .checking || updater.state == .downloading || updater.state == .installing)
                    }
                }
            }
            if let notes = updater.latest?.notes, updater.updateAvailable, !notes.isEmpty {
                ScrollView {
                    Text(notes).font(.system(size: 11)).foregroundStyle(.white.opacity(0.75))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.05)))
            }
            Divider().opacity(0.4)
            ToggleRow(L("Otomatik denetle"), L("Açılışta ve 6 saatte bir GitHub'a bakar; yeni sürüm olunca haber verir"),
                      isOn: model.bind({ updater.autoCheck }, { updater.autoCheck = $0 }))
            HStack {
                if let last = updater.lastCheck {
                    Text(L("Son denetim: %@", last.formatted(date: .omitted, time: .shortened)))
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                }
                Spacer()
                Button(L("GitHub'da aç")) { NSWorkspace.shared.open(UpdateConfig.releasesPage) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .font(.system(size: 11.5, weight: .medium))
            }
        }
    }

    // MARK: Sürümler

    private struct VersionRow: Identifiable {
        let version: String
        let lines: [String]
        let release: ReleaseInfo?
        let preGitHub: Bool
        var id: String { version }
    }

    /// Uygulamadaki sürüm geçmişi + GitHub'daki sürümler (geçmişte olmayan daha yeni sürümler notlarıyla)
    private var versionRows: [VersionRow] {
        let byVersion = Dictionary(updater.releases.map { ($0.version, $0) }, uniquingKeysWith: { a, _ in a })
        var rows = Changelog.entries.map {
            VersionRow(version: $0.version, lines: $0.lines, release: byVersion[$0.version], preGitHub: $0.preGitHub)
        }
        let known = Set(rows.map(\.version))
        for r in updater.releases where !known.contains(r.version) {
            let lines = r.notes.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "*-# ")) }
                .filter { !$0.isEmpty }
                .prefix(8)
            rows.append(VersionRow(version: r.version, lines: Array(lines), release: r, preGitHub: false))
        }
        return rows.sorted { Updater.isNewer($0.version, than: $1.version) }
    }

    private var confirmMessage: String {
        guard let r = confirmRelease else { return "" }
        if Updater.isNewer(r.version, than: updater.currentVersion) {
            return L("Ayarların ve izinlerin korunur.")
        }
        var msg = L("Eski bir sürüme dönüyorsun. Ayarların ve izinlerin korunur. Otomatik denetim açıksa AudioTab yeni sürüm olduğunu yine haber verir; istersen Genel'den kapatabilirsin.")
        if Updater.isNewer("2.3.0", than: r.version) { msg += "\n\n" + L("Bu sürümün arayüzü sadece Türkçe.") }
        if Updater.isNewer("2.3.1", than: r.version) { msg += "\n\n" + L("Bu sürüm 2.3.1 güvenlik iyileştirmelerini içermez.") }
        return msg
    }

    private var installBusy: Bool { updater.state == .downloading || updater.state == .installing }

    @ViewBuilder private var versionsTab: some View {
        Card(title: L("Sürümler"), icon: "clock.arrow.circlepath") {
            HStack(spacing: 10) {
                Text(L("Şu an %@ kullanıyorsun. Bir sürümü seçip ona geçebilirsin; ayarların ve izinlerin korunur.", updater.currentVersion))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.65))
                    .frame(maxWidth: .infinity, alignment: .leading)
                if updater.releasesLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Button { updater.fetchReleases() } label: { Label(L("Yenile"), systemImage: "arrow.clockwise") }
                }
            }
            if let err = updater.releasesError {
                Label(L("Sürüm listesi alınamadı: %@", err), systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11.5)).foregroundStyle(.orange)
            }
            switch updater.state {
            case .downloading, .installing, .failed:
                let s = updateStatus
                Label(s.0, systemImage: s.1).font(.system(size: 12, weight: .semibold)).foregroundStyle(s.2)
            default: EmptyView()
            }
        }
        .onAppear { if updater.releases.isEmpty { updater.fetchReleases() } }

        ForEach(versionRows) { row in
            versionCard(row)
        }
    }

    @ViewBuilder private func versionCard(_ row: VersionRow) -> some View {
        let isCurrent = row.version == updater.currentVersion
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("AudioTab \(row.version)").font(.system(size: 14, weight: .bold))
                if let d = row.release?.date {
                    Text(d.formatted(date: .abbreviated, time: .omitted))
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                }
                if isCurrent {
                    Text(L("Kullanılan"))
                        .font(.system(size: 10.5, weight: .bold))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(Color.green.opacity(0.3)))
                }
                Spacer()
                if row.preGitHub {
                    Text(L("GitHub öncesi")).font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                } else if let r = row.release, !isCurrent {
                    let newer = Updater.isNewer(r.version, than: updater.currentVersion)
                    Button(newer ? L("Yükle") : L("Bu sürüme dön")) { confirmRelease = r }
                        .disabled(installBusy)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(row.lines.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").foregroundStyle(.white.opacity(0.45))
                        Text(line).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(.white.opacity(0.78))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(.white.opacity(isCurrent ? 0.10 : 0.06)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(isCurrent ? Color.green.opacity(0.45) : .white.opacity(0.12), lineWidth: 1))
    }

    // MARK: Genel

    @ViewBuilder private var generalTab: some View {
        Card(title: "Language · Dil", icon: "globe") {
            Row(L("Uygulamanın dili"), AppLanguage.selected != AppLanguage.active ? L("Dil değişikliği için AudioTab yeniden başlatılır") : nil) {
                HStack(spacing: 10) {
                    Picker("", selection: model.bind({ AppLanguage.selected }, { AppLanguage.selected = $0 })) {
                        ForEach(AppLanguage.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 180)
                    if AppLanguage.selected != AppLanguage.active {
                        Button(L("Yeniden başlat")) { Updater.relaunchApp() }
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
        Card(title: L("Başlangıç"), icon: "power") {
            ToggleRow(L("Girişte başlat"), L("Uygulama /Applications klasöründe olmalı"), isOn: model.loginBinding)
        }
        updateCard
        Card(title: L("Hakkında"), icon: "info.circle") {
            Text("AudioTab \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")  ·  GlassTab + AudioHop + ScreenHub")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.7))
        }
    }
}

// MARK: - Parçalar

struct Card<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white.opacity(0.9))
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1))
    }
}

struct Row<Trailing: View>: View {
    let title: String
    let detail: String?
    @ViewBuilder let trailing: Trailing

    init(_ title: String, _ detail: String?, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.detail = detail
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                if let detail {
                    Text(detail).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                }
            }
            Spacer()
            trailing
        }
    }
}

struct ToggleRow: View {
    let title: String
    let detail: String?
    @Binding var isOn: Bool

    init(_ title: String, _ detail: String?, isOn: Binding<Bool>) {
        self.title = title
        self.detail = detail
        self._isOn = isOn
    }

    var body: some View {
        Row(title, detail) {
            Toggle("", isOn: $isOn).toggleStyle(.switch).labelsHidden()
        }
    }
}

struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let open: () -> Void

    var body: some View {
        Row(title, detail) {
            HStack(spacing: 10) {
                Label(granted ? L("Verildi") : L("Verilmedi"),
                      systemImage: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(granted ? Color.green : Color.orange)
                Button(L("Ayarları aç"), action: open)
            }
        }
    }
}


/// Kaldırılabilir küçük çipler (satıra sığmayan alta geçer)
struct ChipItem: Identifiable { let id: String; let name: String }

struct FlowChips: View {
    let items: [ChipItem]
    let onRemove: (String) -> Void

    var body: some View {
        let columns = [GridItem(.adaptive(minimum: 150), spacing: 6, alignment: .leading)]
        LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(items) { it in
                HStack(spacing: 6) {
                    Text(it.name).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 0)
                    Button { onRemove(it.id) } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(.white.opacity(0.10)))
            }
        }
    }
}
