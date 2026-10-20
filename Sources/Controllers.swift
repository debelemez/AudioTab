import Cocoa
import SwiftUI

// MARK: - Cihaz paneli

/// Panel uygulama açılırken bir kez kurulur ve hazır bekler;
/// ⌘⇪ basılınca sadece konumlanıp gösterilir → anında açılır.
/// Kenarsız panel normalde klavye almaz; bunu açıyoruz.
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class DevicePanelController {
    private let store: DeviceStore
    private let model = PanelModel()
    private let panel: KeyPanel
    private var host: NSHostingView<DevicePanelView>!
    private var keyMonitor: Any?
    private var clickMonitor: Any?
    private var resignObserver: NSObjectProtocol?

    init(store: DeviceStore) {
        self.store = store
        panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                         styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.sharingType = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]

        host = GlassHostingView(rootView: DevicePanelView(store: store, model: model) { [weak self] uid in
            self?.commit(uid)
        })
        panel.contentView = host

        // Ön ısıtma: pencere sunucusu tamponunu ve blur katmanını şimdiden oluştur
        panel.alphaValue = 0
        panel.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        panel.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        panel.orderOut(nil)
        panel.alphaValue = 1
    }

    var isVisible: Bool { panel.isVisible }

    /// Kapalıysa aç, açıksa vurguyu bir alta kaydır.
    func showOrAdvance() {
        if isVisible { move(1) } else { show() }
    }

    func show() {
        model.highlighted = initialHighlight()

        let size = host.fittingSize
        if let screen = screenUnderMouse() {
            let f = screen.visibleFrame
            panel.setFrame(NSRect(x: (f.midX - size.width / 2).rounded(),
                                  y: (f.midY - size.height / 2 + f.height * 0.08).rounded(),
                                  width: size.width, height: size.height), display: false)
        }
        panel.alphaValue = 1
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
        installMonitors()
    }

    /// ⌘ bırakıldı: panel açıksa vurgulu cihazı seç ve kapat.
    func commitHighlighted() {
        guard panel.isVisible else { return }
        commit(model.highlighted)
    }

    func hide() {
        guard panel.isVisible else { return }
        removeMonitors()
        panel.orderOut(nil)
    }

    private var connectedRows: [DeviceRow] { store.panelRows.filter(\.isConnected) }

    /// Açılışta vurgu: listedeki bir sonraki cihaz.
    private func initialHighlight() -> String? {
        let rows = connectedRows
        guard !rows.isEmpty else { return nil }
        guard let i = rows.firstIndex(where: { $0.isCurrent }) else { return rows.first?.id }
        return rows[(i + 1) % rows.count].id
    }

    private func move(_ delta: Int) {
        let rows = connectedRows
        guard !rows.isEmpty else { return }
        let i = rows.firstIndex { $0.id == model.highlighted } ?? -1
        let n = ((i + delta) % rows.count + rows.count) % rows.count
        model.highlighted = rows[n].id
    }

    private func commit(_ uid: String?) {
        hide()
        if let uid { store.switchTo(uid: uid) }
    }

    private func installMonitors() {
        removeMonitors()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            switch event.keyCode {
            case 125, 48: self.move(1)                            // ↓, tab
            case 126: self.move(-1)                               // ↑
            case 36, 76, 49: self.commit(self.model.highlighted)  // return, enter, space
            case 53: self.hide()                                  // esc
            default:
                if let c = event.charactersIgnoringModifiers, let n = Int(c), n >= 1, n <= 9 {
                    let rows = self.connectedRows
                    if n <= rows.count { self.commit(rows[n - 1].id) }
                } else {
                    return event
                }
            }
            return nil
        }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.hide()
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in self?.hide() }
    }

    private func removeMonitors() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        keyMonitor = nil
        clickMonitor = nil
        resignObserver = nil
    }
}

// MARK: - Geçiş bildirimi (HUD)

final class HUDController {
    private let window: NSPanel
    private let host: NSHostingView<HUDView>
    private var hideWork: DispatchWorkItem?

    init() {
        window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 50),
                         styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .statusBar
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.appearance = NSAppearance(named: .darkAqua)
        window.sharingType = .none
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        host = GlassHostingView(rootView: HUDView(name: "", symbol: "speaker.wave.2"))
        window.contentView = host
    }

    func show(name: String, symbol: String) {
        host.rootView = HUDView(name: name, symbol: symbol)
        let size = host.fittingSize
        if let screen = screenUnderMouse() {
            let f = screen.visibleFrame
            window.setFrame(NSRect(x: (f.midX - size.width / 2).rounded(), y: f.minY + 110,
                                   width: size.width, height: size.height), display: true)
        }
        NSAnimationContext.runAnimationGroup { ctx in   // süren bir kaybolma animasyonunu ezer
            ctx.duration = 0
            window.animator().alphaValue = 1
        }
        window.orderFrontRegardless()
        window.invalidateShadow()

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                self.window.animator().alphaValue = 0
            }, completionHandler: {
                if self.window.alphaValue == 0 { self.window.orderOut(nil) }
            })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }
}
