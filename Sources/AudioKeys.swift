import Cocoa
import IOKit.hidsystem

/// Ses kısayolu: ⌘⇧ (⌘ basılıyken ⇧'ye tek dokunuş) veya ⌘⇪.
///
/// Kendi event tap'i yok; pencere değiştiricinin tek tap'i olayları buraya da iletir.
/// Bu sayede tek izin (Erişilebilirlik) yeterli. Hiçbir tuşu yutmaz.
final class AudioKeys {
    var choice: HotkeyChoice = .cmdShift
    /// true ise ⌘⇪ sonrası Caps Lock eski durumuna geri alınır.
    var restoreCapsLock = true
    var onTrigger: (() -> Void)?
    /// ⌘ tuşu bırakıldığında (liste modunda "bırakınca seç")
    var onCommandReleased: (() -> Void)?
    /// true dönerse tetiklenmez (ör. ⌘Tab paneli açıkken)
    var isBlocked: (() -> Bool)?

    private var commandDown = false
    private var shiftDown = false

    // ⌘⇧ dokunuş takibi
    private var chordArmed = false
    private var chordDirty = false
    private var chordStart = Date.distantPast

    // ⌘⇪: kendi Caps Lock geri alma işlemimizin yankısını yok saymak için
    private var ignoreCapsState: Bool?
    private var ignoreDeadline = Date.distantPast
    private var lastTrigger = Date.distantPast

    private static let capsLockKeyCode: Int64 = 57 // kVK_CapsLock

    func handle(_ type: CGEventType, _ code: Int64, _ flags: CGEventFlags) {
        switch type {
        case .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown:
            // ⌘⇧ basılıyken başka bir şeye basıldı (⌘⇧4, ⌘⇧Z, ⌘⇧Tab...): bizim kısayolumuz değil
            chordDirty = true
            return
        case .flagsChanged:
            break
        default:
            return
        }

        let cmd = flags.contains(.maskCommand)
        let shift = flags.contains(.maskShift)
        let others = flags.contains(.maskAlternate) || flags.contains(.maskControl)

        if commandDown && !cmd { onCommandReleased?() }
        defer { commandDown = cmd; shiftDown = shift }

        switch choice {
        case .cmdShift: handleCmdShift(cmd: cmd, shift: shift, others: others)
        case .cmdCaps:  handleCmdCaps(code: code, flags: flags)
        }
    }

    // MARK: ⌘⇧

    private func handleCmdShift(cmd: Bool, shift: Bool, others: Bool) {
        if others { chordArmed = false; return }
        // ⌘ bırakıldıysa yarım kalan kombinasyon iptal (⇧ sonra bırakılsa da tetiklenmez)
        if !cmd { chordArmed = false }

        // ⌘ ve ⇧ ikisi birden basılı hale geldi → kurul
        if cmd && shift && !(commandDown && shiftDown) {
            chordArmed = true
            chordDirty = false
            chordStart = Date()
            return
        }

        // ⇧ bırakıldı → araya başka tuş girmediyse ve kısa bir dokunuşsa tetikle
        if shiftDown && !shift {
            defer { chordArmed = false }
            guard chordArmed, !chordDirty, cmd,
                  Date().timeIntervalSince(chordStart) < 1.0 else { return }
            fire()
        }
    }

    // MARK: ⌘⇪

    private func handleCmdCaps(code: Int64, flags: CGEventFlags) {
        guard code == Self.capsLockKeyCode else { return }
        let capsOn = flags.contains(.maskAlphaShift)

        if let expected = ignoreCapsState {
            if Date() < ignoreDeadline && capsOn == expected {
                ignoreCapsState = nil
                return
            }
            if Date() >= ignoreDeadline { ignoreCapsState = nil }
        }

        guard flags.contains(.maskCommand),
              !flags.contains(.maskAlternate),
              !flags.contains(.maskControl),
              !flags.contains(.maskShift) else { return }

        guard fire() else { return }

        if restoreCapsLock {
            let previous = !capsOn
            ignoreCapsState = previous
            ignoreDeadline = Date().addingTimeInterval(0.6)
            DispatchQueue.main.async { Self.setCapsLock(previous) }
        }
    }

    @discardableResult
    private func fire() -> Bool {
        if isBlocked?() == true { return false }
        let now = Date()
        guard now.timeIntervalSince(lastTrigger) > 0.12 else { return false }
        lastTrigger = now
        onTrigger?()
        return true
    }

    // MARK: Caps Lock

    /// HID bağlantısı bir kere açılıp saklanır.
    private static var hidConnect: io_connect_t = 0

    static func setCapsLock(_ on: Bool) {
        if hidConnect == 0 {
            let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass))
            guard service != 0 else { return }
            defer { IOObjectRelease(service) }
            var connect: io_connect_t = 0
            guard IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connect) == KERN_SUCCESS else { return }
            hidConnect = connect
        }
        if IOHIDSetModifierLockState(hidConnect, Int32(kIOHIDCapsLockState), on) != KERN_SUCCESS {
            IOServiceClose(hidConnect)
            hidConnect = 0
        }
    }
}
