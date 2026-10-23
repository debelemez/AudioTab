import Cocoa
import Carbon
import IOKit

// MARK: - Güvenli giriş (Secure Event Input) koruması
//
// KeePassXC, 1Password, Terminal'in "Güvenli Klavye Girişi" gibi uygulamalar şifre alanı açıkken
// klavyeyi kilitler; o sırada hiçbir uygulama (AudioTab da) tuşları göremez. AudioTab macOS'un
// kendi ⌘Tab'ını kapattığı için bu durumda ⌘Tab tamamen ölüyordu. Artık kilit açıldığında
// macOS'un kendi kısayolları geçici olarak geri açılır, kilit kalkınca AudioTab devralır.

enum SecureInput {
    static var isOn: Bool { IsSecureEventInputEnabled() }

    /// Kilidi açan uygulamanın adı (bulunabilirse)
    static func ownerName() -> String? {
        var pid: Int?
        if let d = CGSessionCopyCurrentDictionary() as? [String: Any] {
            pid = (d["kCGSSessionSecureInputPID"] as? NSNumber)?.intValue
        }
        if pid == nil {
            let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IOService:/IOResources/IOConsoleUsers")
            if entry != 0 {
                defer { IOObjectRelease(entry) }
                if let users = IORegistryEntryCreateCFProperty(entry, "IOConsoleUsers" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [[String: Any]] {
                    pid = users.compactMap { ($0["kCGSSessionSecureInputPID"] as? NSNumber)?.intValue }.first
                }
            }
        }
        guard let pid, pid > 0 else { return nil }
        return NSRunningApplication(processIdentifier: pid_t(pid))?.localizedName
    }
}

/// Tüm yönettiğimiz macOS kısayolları: ⌘Tab (1, 2), ⌘< (27), ⌘⇧3 (28), ⌘⇧4 (30), ⌘⇧5 (184), ⌘⇧6 (181)
let allManagedNativeHotkeys: [Int32] = [1, 2, 27, 28, 30, 184, 181]
