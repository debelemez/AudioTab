import Cocoa

// MARK: - Dock'a sürükle-bırak hızlandırma
//
// Bir dosyayı sürüklerken Dock'taki bir uygulamanın üstüne gelince macOS'un beklemesini
// atlar: uygulama hemen öne gelir (açık değilse açılır). Böylece dosyayı doğrudan
// uygulamanın penceresine bırakabilirsin. Ayarlardan açılıp kapanır.

enum DockDragSettings {
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "dockDrag.enabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "dockDrag.enabled") }
    }
}

@MainActor final class DockDragAccelerator {
    private var downMonitor: Any?
    private var dragMonitor: Any?
    private var upMonitor: Any?
    private var dragChange = 0
    private var lastCheck = Date.distantPast
    private var hoverURL: URL?
    private var hoverSince = Date.distantPast
    private var triggered = Set<URL>()

    /// Üstünde bu kadar kalınca uygulama öne gelir (yanlışlıkla üzerinden geçerken açılmasın)
    private let dwell: TimeInterval = 0.15

    func start() {
        stop()
        guard DockDragSettings.enabled else { return }
        downMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            MainActor.assumeIsolated { self?.reset() }
        }
        dragMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] e in
            let p = e.cgEvent?.location
            MainActor.assumeIsolated { if let p { self?.dragged(at: p) } }
        }
        upMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            MainActor.assumeIsolated { self?.reset() }
        }
    }

    func stop() {
        for m in [downMonitor, dragMonitor, upMonitor] { if let m { NSEvent.removeMonitor(m) } }
        downMonitor = nil; dragMonitor = nil; upMonitor = nil
    }

    private func reset() {
        dragChange = NSPasteboard(name: .drag).changeCount
        hoverURL = nil
        triggered.removeAll()
    }

    /// p: ekranın sol üstünden koordinat (CGEvent)
    private func dragged(at p: CGPoint) {
        // Gerçek bir dosya sürükleme mi? (pencere taşıma / metin seçme değil)
        guard NSPasteboard(name: .drag).changeCount != dragChange else { return }
        let now = Date()
        guard now.timeIntervalSince(lastCheck) > 0.05 else { return }
        lastCheck = now

        guard let url = Self.dockAppURL(at: p) else { hoverURL = nil; return }
        if url != hoverURL { hoverURL = url; hoverSince = now; return }
        guard now.timeIntervalSince(hoverSince) >= dwell, !triggered.contains(url) else { return }
        triggered.insert(url)
        Self.bringForward(url)
    }

    /// İmlecin altındaki Dock öğesi bir uygulamaysa onun adresi
    private static func dockAppURL(at p: CGPoint) -> URL? {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.05)
        var el: AXUIElement?
        guard AXUIElementCopyElementAtPosition(sys, Float(p.x), Float(p.y), &el) == .success, let el else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(el, &pid) == .success, pid == dock.processIdentifier else { return nil }
        let sub: String? = AX.attr(el, kAXSubroleAttribute)
        guard sub == "AXApplicationDockItem" else { return nil }
        if let u: URL = AX.attr(el, kAXURLAttribute) { return u }
        if let u: NSURL = AX.attr(el, kAXURLAttribute) { return u as URL }
        return nil
    }

    private static func bringForward(_ appURL: URL) {
        let path = appURL.standardizedFileURL.path
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL?.standardizedFileURL.path == path }) {
            if app.isHidden { app.unhide() }
            app.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
        } else {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            NSWorkspace.shared.openApplication(at: appURL, configuration: cfg)
        }
    }
}
