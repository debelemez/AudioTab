import AppKit
import Combine
import ServiceManagement

// MARK: - Uygulama

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
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
    private var permTimer: Timer?
    private var bag = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        gSwitcher = switcher
        gAudioKeys = audioKeys
        gExtraKeys = extraKeys
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
        model.onHotkeyChanged = { [weak self] in self?.applyAudioKeySettings() }
        model.onPreviewsChanged = { [weak self, weak model] in
            guard let self, let model else { return }
            if model.anyPreviews && !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
            if !model.anyPreviews { self.switcher.clearThumbs() }
        }
        model.onShortcutsChanged = { [weak self] in self?.applyExtraNative() }
        model.onInstallUpdate = { [weak self] in self?.installUpdate() }
        settings = SettingsWindowController(model: model)

        // Ekran çekimi ve ekran bölme
        capture = CaptureController(hud: hud)
        capture.onRecordingChanged = { [weak self] _ in self?.updateIcon() }
        extraKeys.onScreenshot = { [weak self] in self?.capture.screenshotCurrentScreen() }
        extraKeys.onArea = { [weak self] in self?.capture.screenshotArea() }
        extraKeys.onCaptureMenu = { [weak self] in self?.capture.paletteOrStop() }
        extraKeys.onScrolling = { [weak self] in self?.capture.scrollingScreenshot() }
        extraKeys.onTile = { [weak self] in self?.tiling.trigger() }
        extraKeys.isBlocked = { [weak self] in self?.switcher.isActive ?? false }
        tiling.itemsProvider = { [weak self] in self?.switcher.snapshotItems() ?? [] }
        switcher.onTileItem = { [weak self] item in self?.zonePicker.show(item) }

        // GitHub'dan güncelleme
        Updater.shared.onAvailable = { [weak self] info in
            self?.hud.show(name: L("AudioTab %@ hazır · menüden yükle", info.version), symbol: "arrow.down.circle.fill")
        }
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
        if AXIsProcessTrustedWithOptions(opts) {
            switcher.start()
            applyExtraNative()
        } else {
            // Sadece izin verilene kadar çalışır, sonra kendini kapatır.
            permTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, AXIsProcessTrusted() else { return }
                    self.permTimer?.invalidate(); self.permTimer = nil
                    self.switcher.start()
                    self.applyExtraNative()
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
        guard switcher.isRunning else { return }
        extraKeys.applyNative()
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

    /// Kayıt sürüyorsa önce dosyayı bitir, sonra güncelle ve yeniden aç
    private func installUpdate() {
        Updater.shared.install { [weak self] relaunch in
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
