import Cocoa

// MARK: - Finder'da farenin yan tuşlarıyla geri / ileri
//
// Farenin 4. (geri) ve 5. (ileri) tuşları Finder öndeyken Finder'ın "Git › Geri / İleri"
// komutunu çalıştırır. Komut, klavye düzeninden ve dilden bağımsız olsun diye menüdeki
// kısayoluna (⌘[ / ⌘]) bakılarak bulunur ve doğrudan tetiklenir. Ayarlardan kapatılabilir.

enum FinderMouseNav {
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "finderMouseNav.enabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "finderMouseNav.enabled") }
    }

    private static let finderID = "com.apple.finder"
    private static var cache: (pid: pid_t, back: AXUIElement?, forward: AXUIElement?)?

    /// Ortak olay dinleyicisinden çağrılır. true dönerse tıklama yutulur.
    @MainActor static func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        guard type == .otherMouseDown, enabled else { return false }
        let button = event.getIntegerValueField(.mouseEventButtonNumber)
        guard button == 3 || button == 4 else { return false }
        guard let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier == finderID else { return false }
        let back = button == 3
        if !pressMenu(back: back, pid: front.processIdentifier) {
            postShortcut(back: back)
        }
        return true
    }

    /// Finder menüsünde ⌘[ (geri) / ⌘] (ileri) kısayollu öğeyi bulup bas
    private static func pressMenu(back: Bool, pid: pid_t) -> Bool {
        if cache?.pid != pid { cache = (pid, nil, nil) }
        var item = back ? cache?.back : cache?.forward
        if item == nil {
            item = findItem(pid: pid, char: back ? "[" : "]")
            if back { cache?.back = item } else { cache?.forward = item }
        }
        guard let item else { return false }
        if AXUIElementPerformAction(item, kAXPressAction as CFString) == .success { return true }
        // Öğe geçersizleşmiş olabilir (Finder yeniden açıldı vb.): bir kez yeniden ara
        cache = (pid, nil, nil)
        guard let fresh = findItem(pid: pid, char: back ? "[" : "]") else { return false }
        if back { cache?.back = fresh } else { cache?.forward = fresh }
        return AXUIElementPerformAction(fresh, kAXPressAction as CFString) == .success
    }

    private static func findItem(pid: pid_t, char: String) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        guard let bar: AXUIElement = AX.attr(app, kAXMenuBarAttribute),
              let menus: [AXUIElement] = AX.attr(bar, kAXChildrenAttribute) else { return nil }
        for m in menus {
            guard let subs: [AXUIElement] = AX.attr(m, kAXChildrenAttribute) else { continue }
            for menu in subs {
                guard let items: [AXUIElement] = AX.attr(menu, kAXChildrenAttribute) else { continue }
                for it in items {
                    guard let c: String = AX.attr(it, kAXMenuItemCmdCharAttribute), c == char else { continue }
                    let mods = (AX.attr(it, kAXMenuItemCmdModifiersAttribute) as NSNumber?)?.intValue ?? 0
                    if mods == 0 { return it }      // 0 = sadece ⌘
                }
            }
        }
        return nil
    }

    /// Yedek: ⌘[ / ⌘] kısayolunu gönder (ABD klavye konumları)
    private static func postShortcut(back: Bool) {
        let key: CGKeyCode = back ? 33 : 30
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down)
            e?.flags = .maskCommand
            e?.post(tap: .cghidEventTap)
        }
    }
}
