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
    /// Güncellemeyi yükle (kayıt sürüyorsa önce bitirilir)
    var onInstallUpdate: () -> Void = {}

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
        w.title = "AudioTab Ayarları"
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

    private let tabs = [("Ses", "speaker.wave.2.fill"),
                        ("Pencereler", "rectangle.on.rectangle"),
                        ("Ekran", "camera.viewfinder"),
                        ("İzinler", "lock.shield.fill"),
                        ("Genel", "gearshape.fill")]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(tabs.indices, id: \.self) { i in
                    Button { tab = i } label: {
                        Label(tabs[i].0, systemImage: tabs[i].1)
                            .font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 14)
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
                    default: generalTab
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
    }

    // MARK: Ses

    @ViewBuilder private var audioTab: some View {
        let key = store.hotkeyChoice
        Card(title: "Kısayol", icon: "keyboard") {
            Row("Tuş kombinasyonu",
                key == .cmdShift ? "⌘ basılıyken ⇧'ye dokun. ⌘⇧4 gibi kısayolları bozmaz." : "⌘ + Caps Lock") {
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
            Row("\(key.symbol) basınca", nil) {
                Picker("", selection: model.bind({ store.mode }, { store.mode = $0 })) {
                    Text("Sıradakine geç").tag(HotkeyMode.cycle)
                    Text("Listeyi göster").tag(HotkeyMode.panel)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240)
            }
            if store.mode == .panel {
                ToggleRow("⌘ bırakınca seç", "⌘+Tab gibi: ⌘'yi bırakınca vurgulu cihaz seçilir",
                          isOn: model.bind({ store.selectOnRelease }, { store.selectOnRelease = $0 }))
            } else {
                ToggleRow("Geçişte bildirim göster", "Ekranın altında küçük cam bildirim",
                          isOn: model.bind({ store.showHUD }, { store.showHUD = $0 }))
            }
            if key == .cmdCaps {
                ToggleRow("Caps Lock'u açık bırakma", "⌘⇪ sonrası Caps Lock eski haline döner",
                          isOn: model.bind({ store.keepCapsLock }, { v in
                              store.keepCapsLock = v
                              model.onHotkeyChanged()
                          }))
            }
        }

        Card(title: "Ses cihazları", icon: "hifispeaker.2.fill") {
            Row("Listede görünenler", nil) {
                Picker("", selection: model.bind({ store.panelShowAll }, { store.panelShowAll = $0 })) {
                    Text("Tümü").tag(true)
                    Text("Seçtiklerim").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
            }
            Divider().opacity(0.4)

            HStack {
                Text("Cihaz").frame(maxWidth: .infinity, alignment: .leading)
                Text("\(key.symbol) döngüsü").frame(width: 82)
                Text("Listede").frame(width: 60)
                Color.clear.frame(width: 26)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(0.55))

            if store.rows.isEmpty {
                Text("Henüz cihaz yok").foregroundStyle(.white.opacity(0.5))
            }
            ForEach(store.rows) { row in
                HStack(spacing: 10) {
                    Image(systemName: row.symbol)
                        .frame(width: 22)
                        .foregroundStyle(row.isCurrent ? Color.accentColor : .white.opacity(0.85))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Text(row.isCurrent ? "Şu an çalıyor" : (row.isConnected ? "Bağlı" : "Bağlı değil · hatırlanıyor"))
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
                                .help("Bu cihazı unut")
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
                Text("Döngüde 2'den az takılı cihaz var → kısayol tüm takılı cihazlar arasında geçer.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
            }
            if store.passthroughActive {
                Label("eqMac algılandı: ses eqMac üzerinden seçtiğin cihaza gidiyor.", systemImage: "slider.vertical.3")
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
        Card(title: "Uygulamaya göre ses cihazı", icon: "app.badge") {
            ToggleRow("Uygulamaya geçince ses cihazını değiştir",
                      "Atadığın uygulama öne gelince ses o cihaza geçer. ⌘Tab açıkken S ile de atayabilirsin.",
                      isOn: model.bind({ store.autoSwitchByApp }, { store.autoSwitchByApp = $0 }))
            Divider().opacity(0.4)

            let mapped = store.appAudio.keys.sorted { appInfo($0).name.localizedCaseInsensitiveCompare(appInfo($1).name) == .orderedAscending }
            if mapped.isEmpty {
                Text("Henüz atama yok.")
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
                        Text("Atama yok").tag("")
                        ForEach(store.rows) { row in
                            Text(row.isConnected ? row.name : "\(row.name) (bağlı değil)").tag(row.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 220)
                    Button { store.setAppDevice(nil, bundleID: bid) } label: { Image(systemName: "trash") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white.opacity(0.6))
                        .help("Atamayı kaldır")
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
                Label("Açık bir uygulama ekle", systemImage: "plus.circle.fill")
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
                ToggleRow("Kısayolu kullan",
                          p == .cmd ? "Kapatınca macOS'un kendi ⌘Tab'ı geri gelir" : nil,
                          isOn: model.profileBinding(p, "enabled"))
                Divider().opacity(0.4)
                Row("Görünüm", p.list ? "Alt alta satırlar, ses listesi gibi" : "Kartlar yan yana") {
                    Picker("", selection: model.profileBinding(p, "list")) {
                        Text("Izgara").tag(false)
                        Text("Liste").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 160)
                }
                .disabled(!p.enabled)
                ToggleRow("Pencere önizlemeleri", p.list ? "Liste görünümünde kullanılmaz" : "Ekran Kaydı izni gerekir (macOS 14+)",
                          isOn: model.profileBinding(p, "previews"))
                    .disabled(!p.enabled || p.list)
                ToggleRow("Küçültülmüş pencereler", "Küçültülmüş ve penceresiz uygulamaları da göster",
                          isOn: model.profileBinding(p, "showMinimized"))
                    .disabled(!p.enabled)
            }
        }
        Card(title: "Pencereleri her zaman bul", icon: "scope") {
            Row("Kapsam", "Diğer masaüstlerindeki, tam ekrandaki ve arkada kalan pencereleri de kesin gösterir (Chrome profilleri dahil). Arka planda, sadece masaüstü değişince ve uygulama açılınca güncellenir.") {
                Picker("", selection: model.bind({ DeepScanScope.current }, { v in
                    DeepScanScope.current = v
                    model.onDeepScanChanged()
                })) {
                    Text("Kapalı").tag(DeepScanScope.off)
                    Text("Tarayıcılar").tag(DeepScanScope.browsers)
                    Text("Tümü").tag(DeepScanScope.all)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 250)
            }
        }
        Card(title: "Panelde kısayollar", icon: "keyboard") {
            VStack(alignment: .leading, spacing: 5) {
                shortcut("Tab / ⇧Tab", "İleri / geri")
                shortcut("← → ↑ ↓", "Gezin")
                shortcut("⌘'yi bırak, ↩, Space, tıkla", "Seçili pencereye geç")
                shortcut("Esc", "İptal")
                shortcut("W · M · H · Q", "Kapat · Küçült · Gizle · Çık")
                shortcut("S", "Uygulamanın ses cihazını değiştir")
            }
        }
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
        Card(title: "Ekranı böl  ⌘<", icon: "rectangle.split.3x1") {
            ToggleRow("Kısayolu kullan",
                      "⌘< → kaça bölüneceğini seç → hangi pencere hangi bölmeye. ⌘Tab kartlarındaki bölme düğmesi aynı işi tek pencere için yapar. Açıkken macOS'un ⌘< (aynı uygulamanın pencereleri arasında geçiş) kısayolu kapanır.",
                      isOn: model.bind({ TileSettings.enabled }, { v in
                          TileSettings.enabled = v
                          model.onShortcutsChanged()
                      }))
            if TileSettings.enabled {
                Divider().opacity(0.4)
                Row("Hedef monitör", "Birden fazla monitör varken. Panelde Tab ile her zaman değiştirebilirsin.") {
                    Picker("", selection: model.bind({ TileSettings.askMonitor }, { TileSettings.askMonitor = $0 })) {
                        Text("Farenin olduğu").tag(false)
                        Text("Her seferinde sor").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 250)
                }
                Row("Pencere arası boşluk", "\(Int(TileSettings.gap)) pt") {
                    Slider(value: model.bind({ TileSettings.gap }, { TileSettings.gap = $0 }), in: 0...24, step: 2)
                        .frame(width: 200)
                }
            }
        }

        Card(title: "Ekran görüntüsü ve kayıt", icon: "camera.viewfinder") {
            ToggleRow("Kullan",
                      "Kapatınca hepsi devre dışı kalır ve macOS'un kendi ⌘⇧3 / ⌘⇧4 / ⌘⇧5 kısayolları geri gelir.",
                      isOn: model.bind({ CaptureSettings.enabled }, { v in
                          CaptureSettings.enabled = v
                          model.onShortcutsChanged()
                      }))
            if CaptureSettings.enabled {
                Divider().opacity(0.4)
                captureRow(.screen, key: "⌘⇧3", title: "Bu monitörün görüntüsü", detail: "Sadece farenin olduğu monitör",
                           isOn: model.bind({ CaptureSettings.screenKey }, { v in CaptureSettings.screenKey = v; model.onShortcutsChanged() }))
                captureRow(.area, key: "⌘⇧4", title: "Ekran alıntısı", detail: "Alan seç; Space ile pencere seçimi",
                           isOn: model.bind({ CaptureSettings.areaKey }, { v in CaptureSettings.areaKey = v; model.onShortcutsChanged() }))
                captureRow(.scroll, key: "⌘⇧6", title: "Kaydırmalı görüntü", detail: "Alanı seç, sayfa kendiliğinden kayar · Esc bitirir",
                           isOn: model.bind({ CaptureSettings.scrollKey }, { v in CaptureSettings.scrollKey = v; model.onShortcutsChanged() }))
                captureRow(.video, key: "⌘⇧5", title: "Ekran kaydı (MP4 · H.264)", detail: "Çekim paleti; kayıt sırasında ⌘⇧5 durdurur",
                           isOn: model.bind({ CaptureSettings.videoKey }, { v in CaptureSettings.videoKey = v; model.onShortcutsChanged() }))
                HStack {
                    Spacer()
                    Button("Hepsini tek klasöre kaydet…") { pickFolderForAll() }
                }
                Divider().opacity(0.4)
                ToggleRow("Panoya da kopyala", "Görüntüler kaydedilirken panoya da alınır",
                          isOn: model.bind({ CaptureSettings.copyToClipboard }, { CaptureSettings.copyToClipboard = $0 }))
                ToggleRow("Deklanşör sesi", nil,
                          isOn: model.bind({ CaptureSettings.playSound }, { CaptureSettings.playSound = $0 }))
            }
        }

        if CaptureSettings.enabled {
            Card(title: "Video kaydı", icon: "record.circle") {
                Row("Kare hızı", nil) {
                    Picker("", selection: model.bind({ CaptureSettings.fps }, { CaptureSettings.fps = $0 })) {
                        Text("30 fps").tag(30)
                        Text("60 fps").tag(60)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 160)
                }
                Row("Kalite", CaptureSettings.maxQuality ? "Kayıpsıza yakın, dosya büyük" : "Görüntü bozulmaz, dosya makul boyutta") {
                    Picker("", selection: model.bind({ CaptureSettings.maxQuality }, { CaptureSettings.maxQuality = $0 })) {
                        Text("Yüksek").tag(false)
                        Text("En yüksek").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 180)
                }
                ToggleRow("Sistem sesini kaydet", "Bilgisayardan çıkan ses videoya eklenir",
                          isOn: model.bind({ CaptureSettings.recordAudio }, { CaptureSettings.recordAudio = $0 }))
                ToggleRow("İmleci göster", nil,
                          isOn: model.bind({ CaptureSettings.showCursor }, { CaptureSettings.showCursor = $0 }))
                Label("Kayıt sırasında sağ üstte kırmızı nokta ve süre görünür. Sadece sen görürsün, kayda girmez. Tıklayınca kayıt durur.",
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
                .help("Klasörü Finder'da aç")
            }
            Spacer(minLength: 8)
            Button("Klasör…") { pickFolder(kind) }
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
        p.prompt = "Seç"
        p.directoryURL = start
        NSApp.activate(ignoringOtherApps: true)
        return p.runModal() == .OK ? p.url : nil
    }

    // MARK: İzinler

    @ViewBuilder private var permissionsTab: some View {
        let ax = model.axTrusted
        let sc = model.screenTrusted
        Card(title: "Durum", icon: "checkmark.shield") {
            HStack(spacing: 10) {
                Image(systemName: ax ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(ax ? Color.green : Color.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ax ? "Kısayollar çalışıyor" : "Kısayollar için izin gerekli")
                        .font(.system(size: 14, weight: .semibold))
                    Text(ax ? "⌘Tab, ⌥Tab ve ses kısayolu aktif." : "Erişilebilirlik izni verilene kadar hiçbir kısayol çalışmaz.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.6))
                }
                Spacer()
                Button { model.refresh() } label: { Label("Yenile", systemImage: "arrow.clockwise") }
            }
        }
        Card(title: "Gerekli izinler", icon: "lock.shield") {
            PermissionRow(title: "Erişilebilirlik",
                          detail: "⌘Tab, ⌥Tab ve ses kısayolu (⌘⇧ / ⌘⇪) için. Pencerelere geçmek, kapatmak, küçültmek için de kullanılır.",
                          granted: ax) { SettingsModel.open("Privacy_Accessibility") }
            Divider().opacity(0.4)
            PermissionRow(title: "Ekran Kaydı",
                          detail: (model.anyPreviews || CaptureSettings.enabled)
                            ? "Pencere önizlemeleri, ekran görüntüsü ve ekran kaydı için. İzni verdikten sonra uygulamayı bir kez kapatıp aç."
                            : "Şu an gerekmiyor: önizlemeler ve ekran çekimi kapalı.",
                          granted: sc) { SettingsModel.open("Privacy_ScreenCapture") }
        }
        Card(title: "Bilgi", icon: "info.circle") {
            VStack(alignment: .leading, spacing: 6) {
                Label("Giriş İzleme izni gerekmez (eski AudioHop'tan kalmışsa kapatabilirsin).", systemImage: "keyboard")
                Label("Yeniden derledikten sonra izin açık görünüp çalışmıyorsa: listeden AudioTab'ı – ile kaldırıp + ile tekrar ekle.", systemImage: "arrow.triangle.2.circlepath")
                Label("Hiçbir şey kaydedilmez, diske yazılmaz, internete gönderilmez.", systemImage: "hand.raised.fill")
            }
            .font(.system(size: 11.5))
            .foregroundStyle(.white.opacity(0.65))
        }
    }

    // MARK: Güncelleme

    private var updateStatus: (String, String, Color) {
        switch updater.state {
        case .idle: return ("Henüz denetlenmedi", "clock", .white.opacity(0.6))
        case .checking: return ("Denetleniyor…", "arrow.triangle.2.circlepath", .white.opacity(0.8))
        case .upToDate: return ("Güncel", "checkmark.circle.fill", .green)
        case .available(let v): return ("Yeni sürüm var: \(v)", "arrow.down.circle.fill", .accentColor)
        case .downloading: return ("İndiriliyor…", "arrow.down.circle", .white.opacity(0.8))
        case .installing: return ("Yükleniyor, uygulama yeniden açılacak…", "gearshape.2", .white.opacity(0.8))
        case .failed(let m): return (m, "exclamationmark.triangle.fill", .orange)
        }
    }

    @ViewBuilder private var updateCard: some View {
        let status = updateStatus
        Card(title: "Güncellemeler", icon: "arrow.down.app") {
            Row("Sürüm \(updater.currentVersion)", nil) {
                HStack(spacing: 10) {
                    Label(status.0, systemImage: status.1)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(status.2)
                        .lineLimit(2)
                    if updater.updateAvailable {
                        Button("Yükle ve yeniden aç") { model.onInstallUpdate() }
                            .keyboardShortcut(.defaultAction)
                    } else {
                        Button("Şimdi denetle") { updater.check(userInitiated: true) }
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
            ToggleRow("Otomatik denetle", "Açılışta ve 6 saatte bir GitHub'a bakar; yeni sürüm olunca haber verir",
                      isOn: model.bind({ updater.autoCheck }, { updater.autoCheck = $0 }))
            HStack {
                if let last = updater.lastCheck {
                    Text("Son denetim: \(last.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                }
                Spacer()
                Button("GitHub'da aç") { NSWorkspace.shared.open(UpdateConfig.releasesPage) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .font(.system(size: 11.5, weight: .medium))
            }
        }
    }

    // MARK: Genel

    @ViewBuilder private var generalTab: some View {
        Card(title: "Başlangıç", icon: "power") {
            ToggleRow("Girişte başlat", "Uygulama /Applications klasöründe olmalı", isOn: model.loginBinding)
        }
        updateCard
        Card(title: "Hakkında", icon: "info.circle") {
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
                Label(granted ? "Verildi" : "Verilmedi",
                      systemImage: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(granted ? Color.green : Color.orange)
                Button("Ayarları aç", action: open)
            }
        }
    }
}
