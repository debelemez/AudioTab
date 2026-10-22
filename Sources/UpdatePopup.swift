import Cocoa
import SwiftUI
import UserNotifications

// MARK: - Menüden "Güncellemeleri denetle…": küçük cam pencere
//
// Menü çubuğu simgesinin hemen altında açılır, denetimi başlatır ve sonucu gösterir:
// yeni sürüm varsa notlarıyla "Yükle ve yeniden aç", yoksa "AudioTab güncel".

@MainActor final class UpdatePopupController {
    private let panel: KeyPanel
    private var clickMonitor: Any?
    private var keyMonitor: Any?
    var onInstall: () -> Void = {}

    static let size = NSSize(width: 360, height: 300)

    init() {
        panel = KeyPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        let host = GlassHostingView(rootView: UpdatePopupView(updater: Updater.shared,
                                                              install: { [weak self] in self?.hide(); self?.onInstall() },
                                                              close: { [weak self] in self?.hide() }))
        host.sizingOptions = []
        panel.contentView = host
    }

    /// anchor: menü çubuğu simgesinin ekrandaki yeri (yoksa ana ekranın sağ üstü)
    func show(below anchor: NSRect?, check: Bool = true) {
        let screen = NSScreen.screens.first { s in
            guard let r = anchor else { return false }
            return s.frame.contains(NSPoint(x: r.midX, y: r.midY))
        } ?? NSScreen.main
        guard let screen else { return }
        let vf = screen.visibleFrame
        var x = (anchor?.midX ?? vf.maxX - 200) - Self.size.width / 2
        x = min(max(vf.minX + 8, x), vf.maxX - Self.size.width - 8)
        let y = vf.maxY - Self.size.height - 6
        panel.setFrame(NSRect(x: x.rounded(), y: y.rounded(), width: Self.size.width, height: Self.size.height), display: true)
        panel.makeKeyAndOrderFront(nil)
        if check { Updater.shared.check(userInitiated: true) }
        installMonitors()
    }

    func hide() {
        removeMonitors()
        panel.orderOut(nil)
    }

    private func installMonitors() {
        removeMonitors()
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard e.keyCode == 53 else { return e }   // Esc
            MainActor.assumeIsolated { self?.hide() }
            return nil
        }
    }

    private func removeMonitors() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        clickMonitor = nil; keyMonitor = nil
    }
}

struct UpdatePopupView: View {
    @ObservedObject var updater: Updater
    let install: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 56, height: 56)
            content
        }
        .padding(20)
        .frame(width: UpdatePopupController.size.width, height: UpdatePopupController.size.height)
        .glass(radius: 22)
        .foregroundStyle(Color.white)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private var content: some View {
        switch updater.state {
        case .idle, .checking:
            ProgressView().controlSize(.small)
            Text(L("Güncellemeler denetleniyor…")).font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 0)
        case .available(let v):
            Text(L("AudioTab %@ hazır", v)).font(.system(size: 16, weight: .bold))
            Text(L("Şu an %@ kullanıyorsun.", updater.currentVersion)).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.6))
            if let notes = updater.latest?.notes, !notes.isEmpty {
                ScrollView {
                    Text(notes).font(.system(size: 11)).foregroundStyle(.white.opacity(0.75))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.06)))
            } else {
                Spacer(minLength: 0)
            }
            HStack {
                Button(L("Sonra"), action: close)
                Spacer()
                Button(L("Yükle ve yeniden aç"), action: install).keyboardShortcut(.defaultAction)
            }
        case .upToDate:
            Label(L("AudioTab güncel"), systemImage: "checkmark.seal.fill")
                .font(.system(size: 16, weight: .bold)).foregroundStyle(Color.green)
            Text(L("Sürüm %@ en son sürüm.", updater.currentVersion)).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
            Spacer(minLength: 0)
            Button(L("Tamam"), action: close).keyboardShortcut(.defaultAction)
        case .downloading, .installing:
            ProgressView().controlSize(.small)
            Text(updater.state == .downloading ? L("İndiriliyor…") : L("Yükleniyor, uygulama yeniden açılacak…"))
                .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 0)
        case .failed(let msg):
            Label(msg, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Color.orange)
                .multilineTextAlignment(.center)
            Spacer(minLength: 0)
            HStack {
                Button(L("Kapat"), action: close)
                Spacer()
                Button(L("Tekrar dene")) { updater.check(userInitiated: true) }.keyboardShortcut(.defaultAction)
            }
        }
    }
}

// MARK: - Yeni sürüm bildirimi (Bildirim Merkezi)

enum UpdateNotifier {
    static let category = "audiotab.update"

    static func post(version: String) {
        let c = UNUserNotificationCenter.current()
        c.requestAuthorization(options: [.alert, .sound]) { ok, _ in
            guard ok else { return }
            let content = UNMutableNotificationContent()
            content.title = L("AudioTab güncellemesi hazır")
            content.body = L("Sürüm %@ yüklenmeye hazır. Yüklemek için tıkla.", version)
            content.sound = .default
            content.categoryIdentifier = category
            let req = UNNotificationRequest(identifier: "update-\(version)", content: content, trigger: nil)
            c.add(req)
        }
    }
}
