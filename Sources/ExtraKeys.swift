import Cocoa

/// ⌘⇧3 / ⌘⇧4 / ⌘⇧5 / ⌘⇧6 (ekran çekimi) ve ⌘< (ekran bölme).
///
/// Ortak event tap'ten çağrılır. Bizim olan tuşu yutar; macOS'taki karşılığı
/// `applyNative()` ile kapatılır, uygulama kapanınca geri açılır.
@MainActor final class ExtraKeys {
    var onScreenshot: (() -> Void)?      // ⌘⇧3
    var onArea: (() -> Void)?            // ⌘⇧4
    var onCaptureMenu: (() -> Void)?     // ⌘⇧5
    var onScrolling: (() -> Void)?       // ⌘⇧6
    var onTile: (() -> Void)?            // ⌘<
    var onBlackout: (() -> Void)?        // ⌘⇧<: harici monitörleri karart / geri getir
    /// true dönerse hiçbir şey yapılmaz (ör. ⌘Tab paneli açıkken)
    var isBlocked: (() -> Bool)?

    /// keyDown'unu yuttuğumuz tuşların keyUp'ını da yut
    private var swallowedUp = Set<Int64>()

    private static let key3: Int64 = 20, key4: Int64 = 21, key6: Int64 = 22, key5: Int64 = 23

    func handle(_ type: CGEventType, _ code: Int64, _ flags: CGEventFlags, _ event: CGEvent) -> Bool {
        if type == .keyUp, swallowedUp.contains(code) {
            swallowedUp.remove(code)
            return true
        }
        guard type == .keyDown else { return false }
        if isBlocked?() == true { return false }

        let cmd = flags.contains(.maskCommand)
        let shift = flags.contains(.maskShift)
        guard cmd, !flags.contains(.maskControl), !flags.contains(.maskAlternate) else { return false }

        var action: (() -> Void)?
        if shift && MonitorSettings.blackoutKey && Self.isShiftLessThan(event) {
            action = onBlackout
        } else if shift {
            if CaptureSettings.enabled {
                switch code {
                case Self.key3 where CaptureSettings.screenKey: action = onScreenshot
                case Self.key4 where CaptureSettings.areaKey: action = onArea
                case Self.key5 where CaptureSettings.videoKey: action = onCaptureMenu
                case Self.key6 where CaptureSettings.scrollKey: action = onScrolling
                default: break
                }
            }
        } else if TileSettings.enabled && Self.isLessThan(event) {
            action = onTile
        }
        guard let action else { return false }

        swallowedUp.insert(code)
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        if !isRepeat {
            // Tap'i bekletmemek için eylemi bir sonraki turda çalıştır
            DispatchQueue.main.async { MainActor.assumeIsolated { action() } }
        }
        return true
    }

    /// ⌘⇧<: Türkçe Q'da "<" tuşu (⇧ ile ">" olur), ABD düzeninde ⇧+virgül ("<")
    private static func isShiftLessThan(_ event: CGEvent) -> Bool {
        guard let ns = NSEvent(cgEvent: event) else { return false }
        if ns.characters(byApplyingModifiers: []) == "<" { return true }
        return ns.charactersIgnoringModifiers == "<"
    }

    /// Klavye düzeninden bağımsız: basılan tuş "<" karakterini üretiyor mu (Türkçe Q'da sol ⇧ yanındaki tuş).
    private static func isLessThan(_ event: CGEvent) -> Bool {
        guard let ns = NSEvent(cgEvent: event), let ch = ns.charactersIgnoringModifiers else { return false }
        return ch == "<"
    }

    /// Ayarlara göre macOS'un kendi kısayollarını kapat / geri aç.
    func applyNative() {
        let c = CaptureSettings.self
        setNativeHotkeys([28], enabled: !(c.enabled && c.screenKey))
        setNativeHotkeys([30], enabled: !(c.enabled && c.areaKey))
        setNativeHotkeys([184], enabled: !(c.enabled && c.videoKey))
        setNativeHotkeys([181], enabled: !(c.enabled && c.scrollKey))
        setNativeHotkeys([27], enabled: !TileSettings.enabled)
    }
}
