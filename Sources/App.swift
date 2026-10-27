import AppKit
import Combine
import ServiceManagement
import UserNotifications

// MARK: - Uygulama

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    private let store = DeviceStore.shared
    private let switcher = Switcher()
    private let audioKeys = AudioKeys()
    private let hud = HUDController()
    private var panel: DevicePanelController!
    private var settings: SettingsWindowController!
    private var statusItem: NSStatusItem!
    private let extraKeys = ExtraKeys()
    private var capture: CaptureController!
    private let tiling = TilingController()
    private let zonePicker = ZonePickerController()
    private let dockDrag = DockDragAccelerator()
    private let updatePopup = UpdatePopupController()
    private var permTimer: Timer?
    private var guardTimer: Timer?
    private var secureActive = false
    private var lastSecureNotice = Date.distantPast
    private var bag = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        gSwitcher = switcher
        gAudioKeys = audioKeys
        gExtraKeys = extraKeys
        // Önceki çalışma kısayolları kapalı bırakmış olabilir (çökme, zorla kapatma): önce hepsini aç,
        // AudioTab kısayolları dinlemeye başlayınca yalnızca gerekenler yeniden kapanır
        setNativeHotkeys(allManagedNativeHotkeys, enabled: true)
        // Kapattığımız macOS kısayollarını (⌘Tab, ⌘⇧3/4/5…) her durumda geri aç
        signal(SIGTERM) { _ in restoreNativeHotkeys(); exit(0) }
        signal(SIGINT) { _ in restoreNativeHotkeys(); exit(0) }

        // Menü çubuğu: tek ikon, o an çalan ses cihazının simgesi
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        store.$current
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateIcon() }
            .store(in: &bag)
        updateIcon()

        // Ses paneli önceden kurulur → kısayolda anında açılır
        panel = DevicePanelController(store: store)

        let model = SettingsModel(store: store)
        model.onNativeTabChanged = { [weak self] in self?.switcher.applyNative() }
        model.onDeepScanChanged = { [weak self] in self?.switcher.deepScopeChanged() }
        model.onDockDragChanged = { [weak self] in self?.dockDrag.start() }
        model.onHotkeyChanged = { [weak self] in self?.applyAudioKeySettings() }
        model.onPreviewsChanged = { [weak self, weak model] in
            guard let self, let model else { return }
            if model.anyPreviews && !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
            if !model.anyPreviews { self.switcher.clearThumbs() }
        }
        model.onShortcutsChanged = { [weak self] in self?.applyExtraNative() }
        model.onInstallUpdate = { [weak self] release in self?.installUpdate(release) }
        settings = SettingsWindowController(model: model)

        // Ekran çekimi ve ekran bölme
        capture = CaptureController(hud: hud)
        capture.onRecordingChanged = { [weak self] _ in self?.updateIcon() }
        extraKeys.onScreenshot = { [weak self] in self?.capture.screenshotCurrentScreen() }
        extraKeys.onArea = { [weak self] in self?.capture.screenshotArea() }
        extraKeys.onCaptureMenu = { [weak self] in self?.capture.paletteOrStop() }
        extraKeys.onScrolling = { [weak self] in self?.capture.scrollingScreenshot() }
        extraKeys.onTile = { [weak self] in self?.tiling.trigger() }
        extraKeys.onBlackout = { [weak self] in
            guard let self else { return }
            let mon = Monitors.shared
            if mon.displays.isEmpty { mon.refresh(readValues: false) }
            guard !mon.displays.isEmpty || mon.isBlackedOut else {
                self.hud.show(name: L("Bağlı harici monitör yok"), symbol: "display")
                return
            }
            let dark = mon.toggleBlackout()
            self.hud.show(name: dark ? L("Harici monitörler karartıldı · ⌘⇧< ile geri") : L("Harici monitörlerin parlaklığı geri geldi"),
                          symbol: dark ? "moon.fill" : "sun.max.fill")
        }
        // Harici monitör listesi (parlaklık / ses için)
        Monitors.shared.refresh(rescan: true)
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Monitors.shared.refresh(rescan: true) }
        }
        extraKeys.isBlocked = { [weak self] in self?.switcher.isActive ?? false }
        tiling.itemsProvider = { [weak self] in self?.switcher.snapshotItems() ?? [] }
        switcher.onTileItem = { [weak self] item in self?.zonePicker.show(item) }

        // GitHub'dan güncelleme
        Updater.shared.onAvailable = { [weak self] info in
            self?.hud.show(name: L("AudioTab %@ hazır · menüden yükle", info.version), symbol: "arrow.down.circle.fill")
            UpdateNotifier.post(version: info.version)   // Bildirim Merkezi'ne de düşsün
        }
        updatePopup.onInstall = { [weak self] in self?.installUpdate() }
        UNUserNotificationCenter.current().delegate = self
        Updater.shared.start()

        // Ses kısayolu (pencere değiştiricinin tap'ini paylaşır)
        applyAudioKeySettings()
        audioKeys.onTrigger = { [weak self] in self?.audioHotkey() }
        audioKeys.onCommandReleased = { [weak self] in
            guard let self, self.store.mode == .panel, self.store.selectOnRelease else { return }
            self.panel.commitHighlighted()
        }
        audioKeys.isBlocked = { [weak self] in self?.switcher.isActive ?? false }

        // ⌘Tab kartlarında uygulamanın ses cihazı rozeti + panelde S ile atama
        switcher.audioFor = { [weak self] app in
            guard let dev = self?.store.device(forApp: app.bundleIdentifier) else { return nil }
            return (dev.symbol, dev.name)
        }
        switcher.onCycleAudio = { [weak self] app in
            guard let bid = app.bundleIdentifier else { NSSound.beep(); return }
            self?.store.cycleAppDevice(bundleID: bid)
        }

        // Uygulama öne gelince atanmış ses cihazına geç
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bid = app?.bundleIdentifier
            MainActor.assumeIsolated {
                guard let self, let dev = self.store.applyAppDevice(bundleID: bid) else { return }
                if self.store.showHUD { self.hud.show(name: dev.name, symbol: dev.symbol) }
            }
        }

        // İzinler
        if Profile.allCases.contains(where: { $0.enabled && $0.previews }), !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
        }
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        startGuard()
        if AXIsProcessTrustedWithOptions(opts) {
            switcher.start()
            applyExtraNative()
            dockDrag.start()
        } else {
            // Sadece izin verilene kadar çalışır, sonra kendini kapatır.
            permTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, AXIsProcessTrusted() else { return }
                    self.permTimer?.invalidate(); self.permTimer = nil
                    self.switcher.start()
                    self.applyExtraNative()
                    self.dockDrag.start()
                }
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Kayıt sürüyorsa önce dosyayı düzgünce kapat
        guard capture?.isRecording == true else { return .terminateNow }
        capture.stopRecording { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        switcher.stop()
        restoreNativeHotkeys()
    }

    /// macOS'un ⌘⇧3/4/5/6 ve ⌘< kısayollarını ayarlara göre kapat/aç (sadece kısayol dinleyicisi çalışıyorsa)
    private func applyExtraNative() {
        guard switcher.isRunning, !secureActive else { return }
        extraKeys.applyNative()
    }

    /// Hafif bekçi (1,5 sn): güvenli giriş kilidi, kapanmış olay dinleyicisi, sonradan verilen izin
    private func startGuard() {
        guardTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.guardTick() }
        }
        guardTimer?.tolerance = 0.5
    }

    private func guardTick() {
        // İzin var ama dinleyici kurulamamışsa yeniden dene
        if !switcher.isRunning, permTimer == nil, AXIsProcessTrusted() {
            switcher.start()
            applyExtraNative()
        }
        guard switcher.isRunning else { return }
        let on = SecureInput.isOn
        guard on != secureActive else { return }
        secureActive = on
        if on {
            // Tuşlar bize ulaşamıyor: macOS'un kendi ⌘Tab'ı ve ekran görüntüsü kısayolları geçici olarak geri
            setNativeHotkeys(allManagedNativeHotkeys, enabled: true)
            guard Date().timeIntervalSince(lastSecureNotice) > 600 else { return }   // en fazla 10 dakikada bir haber ver
            lastSecureNotice = Date()
            let who = SecureInput.ownerName()
            hud.show(name: who.map { L("%@ klavyeyi kilitledi · ⌘Tab şimdilik macOS'unki", $0) }
                          ?? L("Güvenli giriş açık · ⌘Tab şimdilik macOS'unki"), symbol: "lock.fill")
        } else {
            switcher.applyNative()
            applyExtraNative()
        }
    }

    // MARK: Ses

    private func applyAudioKeySettings() {
        audioKeys.choice = store.hotkeyChoice
        audioKeys.restoreCapsLock = store.keepCapsLock
    }

    private func audioHotkey() {
        switch store.mode {
        case .cycle:
            guard let next = store.nextDevice() else { NSSound.beep(); return }
            store.switchTo(uid: next.uid)
            if store.showHUD { hud.show(name: next.name, symbol: next.symbol) }
        case .panel:
            panel.showOrAdvance()
        }
    }

    private func updateIcon() {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let symbol = store.current?.symbol ?? "speaker.wave.2"
        if capture?.isRecording == true {
            let rec = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: L("Kaydediliyor"))?
                .withSymbolConfiguration(config)
            rec?.isTemplate = true
            statusItem.button?.image = rec
            statusItem.button?.contentTintColor = .systemRed
            statusItem.button?.toolTip = L("AudioTab · Kaydediliyor")
            return
        }
        statusItem.button?.contentTintColor = nil
        let image = (NSImage(systemSymbolName: symbol, accessibilityDescription: "AudioTab")
                     ?? NSImage(systemSymbolName: "speaker.wave.2", accessibilityDescription: "AudioTab"))?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = store.current.map { "AudioTab · \($0.name)" } ?? "AudioTab"
    }

    // MARK: Menü (kısa tutuldu; her şey Ayarlar penceresinde)

    func menuNeedsUpdate(_ menu: NSMenu) {
        store.refresh()
        menu.removeAllItems()

        let up = Updater.shared
        if up.updateAvailable, let v = up.latest?.version {
            menu.addItem(action(L("Güncelleme var: %@ · Yükle", v), "arrow.down.circle.fill", #selector(installUpdateFromMenu)))
            menu.addItem(.separator())
        } else if up.state == .downloading || up.state == .installing {
            menu.addItem(header(L("Güncelleme yükleniyor…")))
            menu.addItem(.separator())
        }
        menu.addItem(header(L("Çıkış: %@", store.current?.name ?? "—")))
        if store.passthroughActive { menu.addItem(header(L("eqMac üzerinden yönlendiriliyor"))) }
        menu.addItem(.separator())

        for row in store.rows where row.isConnected {
            let item = NSMenuItem(title: row.name, action: #selector(selectDevice(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = row.id
            item.state = row.isCurrent ? .on : .off
            item.image = NSImage(systemSymbolName: row.symbol, accessibilityDescription: nil)
            menu.addItem(item)
        }
        menu.addItem(.separator())

        // Harici monitörler: parlaklık ve ses kaydırıcıları (Mac'in kendi ekranı yok)
        let mon = Monitors.shared
        if MonitorSettings.showInMenu {
            mon.refresh()
            if !mon.displays.isEmpty {
                menu.addItem(header(L("Harici monitörler")))
                for d in mon.displays {
                    let title = NSMenuItem(title: d.ddc ? d.name : L("%@ · desteklemiyor", d.name), action: nil, keyEquivalent: "")
                    title.isEnabled = false
                    title.image = NSImage(systemSymbolName: "display", accessibilityDescription: nil)
                    menu.addItem(title)
                    let id = d.id
                    let b = NSMenuItem()
                    b.view = MenuSliderView(symbol: "sun.max.fill", value: d.brightness, enabled: d.ddc) { v in
                        MainActor.assumeIsolated { Monitors.shared.setBrightness(v, for: id) }
                    }
                    menu.addItem(b)
                    if d.volumeSupported {
                        let v = NSMenuItem()
                        v.view = MenuSliderView(symbol: "speaker.wave.2.fill", value: d.volume, enabled: d.ddc) { val in
                            MainActor.assumeIsolated { Monitors.shared.setVolume(val, for: id) }
                        }
                        menu.addItem(v)
                    }
                }
                if MonitorSettings.blackoutKey {
                    let it = action(mon.isBlackedOut ? L("Parlaklığı geri getir  ⌘⇧<") : L("Monitörleri karart  ⌘⇧<"),
                                    mon.isBlackedOut ? "sun.max" : "moon", #selector(toggleBlackoutFromMenu))
                    menu.addItem(it)
                }
                menu.addItem(.separator())
            }
        }

        if capture.isRecording {
            let stop = NSMenuItem(title: L("Kaydı durdur"), action: #selector(stopRecording), keyEquivalent: "")
            stop.target = self
            stop.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: nil)
            menu.addItem(stop)
            menu.addItem(.separator())
        }
        if TileSettings.enabled {
            menu.addItem(action(L("Ekranı böl…  ⌘<"), "rectangle.split.3x1", #selector(openTiling)))
        }
        if CaptureSettings.enabled {
            let cap = NSMenuItem(title: L("Ekran görüntüsü ve kayıt"), action: nil, keyEquivalent: "")
            cap.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: nil)
            let sub = NSMenu()
            for a in CaptureAction.allCases {
                let key: String
                switch a {
                case .screen: key = "  ⌘⇧3"
                case .area: key = "  ⌘⇧4"
                case .scroll: key = "  ⌘⇧6"
                default: key = ""
                }
                let it = action(a.title + key, a.symbol, #selector(captureAction(_:)))
                it.tag = a.rawValue
                it.isEnabled = !capture.isRecording
                sub.addItem(it)
            }
            cap.submenu = sub
            menu.addItem(cap)
        }
        if TileSettings.enabled || CaptureSettings.enabled { menu.addItem(.separator()) }

        menu.addItem(action(L("Güncellemeleri denetle…"), "arrow.triangle.2.circlepath", #selector(checkUpdatesFromMenu)))
        let prefs = NSMenuItem(title: L("Ayarlar…"), action: #selector(openSettings), keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)

        if !AXIsProcessTrusted() {
            let warn = NSMenuItem(title: L("⚠︎ Erişilebilirlik izni ver…"), action: #selector(openAX), keyEquivalent: "")
            warn.target = self
            menu.addItem(warn)
        }

        menu.addItem(.separator())
        let quit = NSMenuItem(title: L("AudioTab'tan Çık"), action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func action(_ title: String, _ symbol: String, _ sel: Selector) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        it.target = self
        it.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return it
    }

    @objc private func openTiling() {
        // Menü kapansın, sonra panel açılsın
        DispatchQueue.main.async { MainActor.assumeIsolated { self.tiling.trigger() } }
    }

    @objc private func captureAction(_ sender: NSMenuItem) {
        guard let a = CaptureAction(rawValue: sender.tag) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            MainActor.assumeIsolated { self.capture.perform(a) }
        }
    }

    @objc private func stopRecording() { capture.stopRecording() }

    @objc private func installUpdateFromMenu() { installUpdate() }

    @objc private func toggleBlackoutFromMenu() { extraKeys.onBlackout?() }

    @objc private func checkUpdatesFromMenu() {
        // Menü kapansın, sonra simgenin altında açılsın
        DispatchQueue.main.async { MainActor.assumeIsolated { self.showUpdatePopup(check: true) } }
    }

    private func showUpdatePopup(check: Bool) {
        updatePopup.show(below: statusItem.button?.window?.frame, check: check)
    }

    // Bildirime tıklanınca güncelleme penceresi açılsın; uygulama öndeyken de bildirim görünsün
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.showUpdatePopup(check: false) } }
        completionHandler()
    }

    /// Kayıt sürüyorsa önce dosyayı bitir, sonra güncelle ve yeniden aç
    private func installUpdate(_ release: ReleaseInfo? = nil) {
        Updater.shared.install(release: release) { [weak self] relaunch in
            MainActor.assumeIsolated {
                guard let self, self.capture.isRecording else { relaunch(); return }
                self.capture.stopRecording { relaunch() }
            }
        }
    }

    private func header(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func selectDevice(_ sender: NSMenuItem) {
        guard let uid = sender.representedObject as? String else { return }
        store.switchTo(uid: uid)
    }

    @objc private func openSettings() { settings.show() }
    @objc private func openAX() { SettingsModel.open("Privacy_Accessibility") }
    @objc private func quit() { NSApp.terminate(nil) }
}

@main enum AudioTabMain {
    @MainActor static func main() {
        Migration.run()   // eski GlassTab/AudioHop ayarlarını taşı (DeviceStore'dan önce)
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
