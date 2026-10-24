import Cocoa
import SwiftUI
import ScreenCaptureKit
import AVFoundation
import CoreImage
import CoreMedia
import ImageIO
import UniformTypeIdentifiers

// MARK: - Ayarlar

enum CaptureKind: String, CaseIterable {
    case screen, area, scroll, video
    var folderKey: String { "capture.folder.\(rawValue)" }
}

/// Ekran kaydı biçimi
enum VideoFormat: String, CaseIterable {
    /// H.264 (.mp4): her yerde açılır
    case h264
    /// H.265 / HEVC (.mp4): aynı kalitede yaklaşık yarı boyut, 4096 piksel sınırı yok
    case hevc
    /// ProRes 4444 (.mov): görsel olarak kayıpsız, renkler tam (4:4:4), kurgu programları için
    case prores

    var ext: String { self == .prores ? "mov" : "mp4" }
    var usesQuality: Bool { self == .h264 || self == .hevc }
}

enum CaptureSettings {
    private static var d: UserDefaults { .standard }
    private static func flag(_ key: String, _ def: Bool) -> Bool { d.object(forKey: key) as? Bool ?? def }

    /// Ekran görüntüsü ve kayıt özelliklerinin hepsi
    static var enabled: Bool {
        get { flag("capture.enabled", true) }
        set { d.set(newValue, forKey: "capture.enabled") }
    }
    static var screenKey: Bool {      // ⌘⇧3
        get { flag("capture.key.screen", true) }
        set { d.set(newValue, forKey: "capture.key.screen") }
    }
    static var areaKey: Bool {        // ⌘⇧4
        get { flag("capture.key.area", true) }
        set { d.set(newValue, forKey: "capture.key.area") }
    }
    static var videoKey: Bool {       // ⌘⇧5
        get { flag("capture.key.video", true) }
        set { d.set(newValue, forKey: "capture.key.video") }
    }
    static var scrollKey: Bool {      // ⌘⇧6
        get { flag("capture.key.scroll", true) }
        set { d.set(newValue, forKey: "capture.key.scroll") }
    }
    static var copyToClipboard: Bool {
        get { flag("capture.clipboard", false) }
        set { d.set(newValue, forKey: "capture.clipboard") }
    }
    static var playSound: Bool {
        get { flag("capture.sound", true) }
        set { d.set(newValue, forKey: "capture.sound") }
    }
    static var fps: Int {
        get { min(max(d.object(forKey: "capture.fps") as? Int ?? 60, 1), 120) }
        set { d.set(newValue, forKey: "capture.fps") }
    }
    /// Video kalitesi: 0 yüksek, 1 en yüksek, 2 ham (neredeyse sıkıştırmasız),
    /// 3 paylaşım (WhatsApp vb.: 1080p, 30 fps, küçük dosya; uygulamalar yeniden sıkıştırınca yazılar okunur kalır)
    static var quality: Int {
        get {
            if let q = d.object(forKey: "capture.quality") as? Int { return min(max(q, 0), 3) }
            return flag("capture.maxQuality", false) ? 1 : 0     // eski ayar
        }
        set { d.set(min(max(newValue, 0), 3), forKey: "capture.quality") }
    }
    /// Video biçimi
    static var format: VideoFormat {
        get { VideoFormat(rawValue: d.string(forKey: "capture.format") ?? "") ?? .h264 }
        set { d.set(newValue.rawValue, forKey: "capture.format") }
    }
    static var recordAudio: Bool {
        get { flag("capture.audio", true) }
        set { d.set(newValue, forKey: "capture.audio") }
    }
    static var showCursor: Bool {
        get { flag("capture.cursor", true) }
        set { d.set(newValue, forKey: "capture.cursor") }
    }

    static func folder(_ kind: CaptureKind) -> URL {
        if let p = d.string(forKey: kind.folderKey), !p.isEmpty { return URL(fileURLWithPath: p, isDirectory: true) }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    static func setFolder(_ url: URL, for kind: CaptureKind) {
        d.set(url.path, forKey: kind.folderKey)
    }
}

// MARK: - Yardımcılar

enum CaptureError: LocalizedError {
    case noDisplay, writer, tooSmall
    var errorDescription: String? {
        switch self {
        case .noDisplay: return L("Monitör bulunamadı")
        case .writer: return L("Video dosyası oluşturulamadı")
        case .tooSmall: return L("Seçilen alan çok küçük")
        }
    }
}

func displayID(of screen: NSScreen) -> CGDirectDisplayID {
    (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
}

enum CaptureFiles {
    static func newURL(_ kind: CaptureKind, prefix: String, ext: String) -> URL {
        let folder = CaptureSettings.folder(kind)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.locale = Locale(identifier: "tr_TR")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let base = "\(prefix) \(f.string(from: Date()))"
        var url = folder.appendingPathComponent("\(base).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) (\(n)).\(ext)")
            n += 1
        }
        return url
    }

    /// PNG olarak kaydet (retina ölçeği DPI bilgisine yazılır)
    static func savePNG(_ img: CGImage, to url: URL, scale: CGFloat) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
        let dpi = 72 * scale
        let props: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
        CGImageDestinationAddImage(dest, img, props as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }

    static func playShutter() {
        let path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif"
        if let s = NSSound(contentsOfFile: path, byReference: true) { s.play() } else { NSSound(named: "Tink")?.play() }
    }

    static func copyImage(at url: URL) {
        guard let img = NSImage(contentsOf: url) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([img])
    }

    /// screencapture'ın -D seçeneği için monitör sırası (1'den başlar)
    static func cliDisplayIndex(_ id: CGDirectDisplayID) -> Int {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return (ids.firstIndex(of: id) ?? 0) + 1
    }
}

/// ScreenCaptureKit yardımcıları. Kendi pencerelerimiz (kayıt noktası, paneller) her zaman hariç tutulur.
enum SCHelper {
    static func filter(displayID: CGDirectDisplayID) async throws -> (SCDisplay, SCContentFilter) {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let d = content.displays.first(where: { $0.displayID == displayID }) else { throw CaptureError.noDisplay }
        let me = content.applications.filter { $0.processID == getpid() }
        return (d, SCContentFilter(display: d, excludingApplications: me, exceptingWindows: []))
    }

    /// rect: monitörün sol üst köşesine göre, nokta cinsinden. nil = tüm monitör.
    @available(macOS 14.0, *)
    static func configuration(display: SCDisplay, rect: CGRect?, scale: CGFloat) -> SCStreamConfiguration {
        let cfg = SCStreamConfiguration()
        let r = rect ?? CGRect(x: 0, y: 0, width: CGFloat(display.width), height: CGFloat(display.height))
        if rect != nil { cfg.sourceRect = r }
        cfg.width = max(1, Int((r.width * scale).rounded()))
        cfg.height = max(1, Int((r.height * scale).rounded()))
        cfg.showsCursor = false
        cfg.captureResolution = .best
        return cfg
    }

    @available(macOS 14.0, *)
    static func image(displayID: CGDirectDisplayID, rect: CGRect?, scale: CGFloat) async throws -> CGImage {
        let (d, f) = try await filter(displayID: displayID)
        return try await SCScreenshotManager.captureImage(contentFilter: f, configuration: configuration(display: d, rect: rect, scale: scale))
    }
}

// MARK: - Alan seçici

final class RegionView: NSView {
    var hint = ""
    var onDone: ((CGRect?) -> Void)?
    private var start: NSPoint?
    private var current: NSPoint?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    private var selection: CGRect? {
        guard let start, let current else { return nil }
        return CGRect(x: min(start.x, current.x), y: min(start.y, current.y),
                      width: abs(start.x - current.x), height: abs(start.y - current.y)).integral
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()
        if let r = selection {
            NSColor.clear.setFill()
            r.fill(using: .copy)
            let path = NSBezierPath(rect: r.insetBy(dx: -0.5, dy: -0.5))
            path.lineWidth = 1.5
            NSColor.white.setStroke()
            path.setLineDash([6, 4], count: 2, phase: 0)
            path.stroke()
            drawLabel("\(Int(r.width)) × \(Int(r.height))", at: NSPoint(x: r.maxX + 8, y: r.minY - 26))
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14, weight: .semibold)]
        let w = (hint as NSString).size(withAttributes: attrs).width
        drawLabel(hint, at: NSPoint(x: bounds.midX - w / 2 - 12, y: bounds.maxY - 90))
    }

    private func drawLabel(_ text: String, at p: NSPoint) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14, weight: .semibold),
                                                    .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attrs)
        var bg = NSRect(x: p.x, y: p.y, width: size.width + 24, height: size.height + 12)
        bg.origin.x = min(max(8, bg.origin.x), bounds.maxX - bg.width - 8)
        bg.origin.y = min(max(8, bg.origin.y), bounds.maxY - bg.height - 8)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: bg, xRadius: bg.height / 2, yRadius: bg.height / 2).fill()
        (text as NSString).draw(at: NSPoint(x: bg.minX + 12, y: bg.minY + 6), withAttributes: attrs)
    }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        current = start
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        let r = selection
        start = nil
        current = nil
        if let r, r.width >= 8, r.height >= 8 { onDone?(r) } else { needsDisplay = true }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onDone?(nil) } else { super.keyDown(with: event) }
    }
}

/// Farenin bulunduğu monitörde sürükleyerek alan seçtirir.
@MainActor final class RegionSelector {
    private var panel: KeyPanel?

    /// Sonuç: monitör ve AppKit (genel) koordinatlarında seçilen dikdörtgen
    func begin(hint: String, completion: @escaping (NSScreen, CGRect) -> Void) {
        guard let screen = screenUnderMouse() else { return }
        cancel()
        let p = KeyPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .screenSaver
        p.isReleasedWhenClosed = false
        p.animationBehavior = .none
        p.sharingType = .none
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        let v = RegionView(frame: NSRect(origin: .zero, size: screen.frame.size))
        v.hint = hint
        v.onDone = { [weak self] r in
            MainActor.assumeIsolated {
                self?.cancel()
                guard let r else { return }
                let global = r.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
                // Seçim katmanı ekrandan tamamen kalksın, sonra çek
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    MainActor.assumeIsolated { completion(screen, global) }
                }
            }
        }
        p.contentView = v
        p.setFrame(screen.frame, display: true)
        p.makeKeyAndOrderFront(nil)
        p.makeFirstResponder(v)
        panel = p
    }

    func cancel() {
        panel?.orderOut(nil)
        panel = nil
    }

    /// AppKit koordinatlarındaki alanı, monitörün sol üst köşesine göre koordinatlara çevir
    static func local(_ r: CGRect, in screen: NSScreen) -> CGRect {
        CGRect(x: r.minX - screen.frame.minX, y: screen.frame.maxY - r.maxY, width: r.width, height: r.height)
    }
}

// MARK: - Kaydırmalı görüntü birleştirici

/// Ardışık kareleri üst üste örtüşen satırlardan bulup tek uzun görüntüde birleştirir.
/// Yapışkan üst bilgi / alt bilgi (sabit menü, alt çubuk) tekrar edilmez.
final class Stitcher {
    let width: Int
    let frameH: Int
    private let bpr: Int
    private(set) var height: Int
    private var buffer: [UInt8]
    private var prevSig: [UInt64]

    init?(first: CGImage) {
        width = first.width
        frameH = first.height
        bpr = width * 4
        guard width > 0, frameH > 16 else { return nil }
        let px = Stitcher.pixels(first, width, frameH)
        buffer = px
        height = frameH
        prevSig = Stitcher.signatures(px, width, frameH)
    }

    static func pixels(_ img: CGImage, _ w: Int, _ h: Int) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: w * h * 4)
        data.withUnsafeMutableBytes { ptr in
            if let ctx = CGContext(data: ptr.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                   space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
        }
        return data
    }

    /// Satır başına özet; düz renkli satırlar 0 olarak işaretlenir (eşleştirmede bilgi taşımazlar).
    static func signatures(_ px: [UInt8], _ w: Int, _ h: Int) -> [UInt64] {
        var out = [UInt64](repeating: 0, count: h)
        let bpr = w * 4
        px.withUnsafeBufferPointer { p in
            for y in 0..<h {
                var hash: UInt64 = 0xcbf29ce484222325
                let row = y * bpr
                let first = UInt32(p[row]) | UInt32(p[row + 1]) << 8 | UInt32(p[row + 2]) << 16
                var flat = true
                var x = 0
                while x < w {
                    let i = row + x * 4
                    let v = UInt32(p[i]) | UInt32(p[i + 1]) << 8 | UInt32(p[i + 2]) << 16
                    if v != first { flat = false }
                    hash = (hash ^ UInt64(v)) &* 0x100000001b3
                    x += 2
                }
                out[y] = flat ? 0 : (hash | 1)
            }
        }
        return out
    }

    /// Yeni kareyi ekle. false: sayfa artık kaymıyor (son) ya da eşleşme bulunamadı.
    func add(_ img: CGImage) -> Bool {
        guard img.width == width, img.height == frameH else { return false }
        let h = frameH
        let px = Self.pixels(img, width, h)
        let sig = Self.signatures(px, width, h)

        var header = 0
        while header < h / 3 && sig[header] == prevSig[header] { header += 1 }
        var footer = 0
        while footer < h / 3 && sig[h - 1 - footer] == prevSig[h - 1 - footer] { footer += 1 }
        let lo = header, hi = h - footer
        guard hi - lo > 24 else { return false }   // hiç değişmedi: sayfanın sonu

        // En çok bilgi taşıyan satırı eşleştiren kayma miktarı
        var bestShift = 0, bestScore = 0
        for s in 1..<(hi - lo - 8) {
            var match = 0, total = 0, informative = 0
            var i = lo
            while i < hi - s {
                total += 1
                if sig[i] == prevSig[i + s] {
                    match += 1
                    if sig[i] != 0 { informative += 1 }
                }
                i += 1
            }
            if total >= 8, match * 10 >= total * 9, informative > bestScore {
                bestScore = informative
                bestShift = s
            }
        }
        guard bestShift > 0, bestScore >= 3 else { return false }

        // Önceki karenin alt bilgisi birleşik görüntünün sonunda: kaldır, yeni içerik + alt bilgiyi ekle
        if footer > 0 {
            buffer.removeLast(min(footer, height) * bpr)
            height -= min(footer, height)
        }
        let from = (hi - bestShift) * bpr
        buffer.append(contentsOf: px[from..<(h * bpr)])
        height += bestShift + footer
        prevSig = sig
        return true
    }

    func makeImage() -> CGImage? {
        guard height > 0, let provider = CGDataProvider(data: Data(buffer) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bpr,
                       space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

// MARK: - Ekran kaydı (MP4 · H.264)

final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    /// Paylaşım modunda kareler keskinleştirilip bu adaptörle yazılır
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var sharpen: CIFilter?
    private lazy var ciContext = CIContext(options: [.cacheIntermediates: false])
    private var sessionStarted = false
    private var startTime = CMTime.zero
    private let queue = DispatchQueue(label: "audiotab.recorder", qos: .userInitiated)
    private(set) var url: URL?
    /// Kayıt beklenmedik şekilde durursa (ör. monitör çıkarıldı)
    var onUnexpectedStop: (() -> Void)?

    /// rect: monitörün sol üst köşesine göre, nokta cinsinden. nil = tüm monitör.
    func start(displayID: CGDirectDisplayID, rect: CGRect?, scale: CGFloat, url: URL,
               fps requestedFPS: Int, quality: Int, format: VideoFormat = .h264, audio: Bool, cursor: Bool) async throws {
        let (display, filter) = try await SCHelper.filter(displayID: displayID)
        let r = rect ?? CGRect(x: 0, y: 0, width: CGFloat(display.width), height: CGFloat(display.height))
        guard r.width >= 16, r.height >= 16 else { throw CaptureError.tooSmall }

        let share = quality == 3 && format.usesQuality
        let fps = share ? min(requestedFPS, 30) : requestedFPS
        // H.264 sınırı: en fazla 4096 piksel genişlik ve 4096×2304 alan → gerekirse oranı koruyarak küçült.
        // H.265 / ProRes / sıkıştırmasız: 8192'ye kadar (5K/6K ekranlar birebir).
        // Paylaşım modunda WhatsApp'ın hedefi: uzun kenar 1280 (720p), 30 fps.
        var pw = r.width * scale, ph = r.height * scale
        let longest: CGFloat = share ? 1280 : (format == .h264 ? 4096 : 8192)
        let areaCap: CGFloat = (format == .h264 || share) ? (4096 * 2304 / (pw * ph)).squareRoot() : 1
        let k = min(1, longest / max(pw, ph), areaCap)
        pw *= k; ph *= k
        let W = max(16, Int(pw) / 2 * 2), H = max(16, Int(ph) / 2 * 2)

        let cfg = SCStreamConfiguration()
        if rect != nil { cfg.sourceRect = r }
        cfg.width = W
        cfg.height = H
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.queueDepth = 8
        cfg.showsCursor = cursor
        if audio {
            cfg.capturesAudio = true
            cfg.sampleRate = 48_000
            cfg.channelCount = 2
            cfg.excludesCurrentProcessAudio = true
        }

        let w = try AVAssetWriter(outputURL: url, fileType: format.ext == "mov" ? .mov : .mp4)
        // Bit hızı: piksel × kare hızı × katsayı
        // (1440p60: yüksek ≈ 31, en yüksek ≈ 55, ham ≈ 200 Mbit/sn — ham modda kodlayıcının sınırına kadar)
        let factor: Double = quality >= 2 ? 0.9 : (quality == 1 ? 0.25 : 0.14)
        // Paylaşım: ~2,2 Mbit/sn sabit hedef (720p30): 16 MB'a ~1 dakika sığar, WhatsApp'ın ikinci sıkıştırması hafif kalır
        let bitrate = share ? Int(2_200_000 * Double(W * H) / (1280 * 720)) : Int(Double(W * H * fps) * factor)
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitrate,
            AVVideoProfileLevelKey: share ? AVVideoProfileLevelH264MainAutoLevel : AVVideoProfileLevelH264HighAutoLevel,
            AVVideoExpectedSourceFrameRateKey: fps,
            AVVideoMaxKeyFrameIntervalKey: quality == 2 ? fps : fps * 2,
            AVVideoH264EntropyModeKey: AVVideoH264EntropyModeCABAC,
        ]
        if quality == 2 {
            compression[AVVideoQualityKey] = 1.0          // en yüksek kalite: yazılar ve ince çizgiler net
            compression[AVVideoAllowFrameReorderingKey] = true
        }
        let color: [String: Any] = [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
        ]
        var videoSettings: [String: Any]?
        switch share ? .h264 : format {   // paylaşımda her telefonun açtığı H.264
        case .h264:
            videoSettings = [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: W, AVVideoHeightKey: H,
                             AVVideoCompressionPropertiesKey: compression, AVVideoColorPropertiesKey: color]
        case .hevc:
            // HEVC aynı kaliteyi yaklaşık %60 bit hızıyla verir
            var c = compression
            c[AVVideoAverageBitRateKey] = Int(Double(bitrate) * 0.6)
            c[AVVideoProfileLevelKey] = nil
            c[AVVideoH264EntropyModeKey] = nil
            videoSettings = [AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: W, AVVideoHeightKey: H,
                             AVVideoCompressionPropertiesKey: c, AVVideoColorPropertiesKey: color]
        case .prores:
            videoSettings = [AVVideoCodecKey: AVVideoCodecType.proRes4444, AVVideoWidthKey: W, AVVideoHeightKey: H,
                             AVVideoColorPropertiesKey: color]
        }
        let vi = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        vi.expectsMediaDataInRealTime = true
        guard w.canAdd(vi) else { throw CaptureError.writer }
        w.add(vi)
        if share {
            // Küçültülmüş yazılar mesajlaşma uygulamasının sıkıştırmasından sonra da okunsun: hafif keskinleştirme
            adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vi, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: W,
                kCVPixelBufferHeightKey as String: H,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ])
            sharpen = CIFilter(name: "CIUnsharpMask", parameters: [kCIInputRadiusKey: 1.2, kCIInputIntensityKey: 0.7])
        } else {
            adaptor = nil
            sharpen = nil
        }

        var ai: AVAssetWriterInput?
        if audio {
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: share ? 128_000 : 256_000,
            ])
            a.expectsMediaDataInRealTime = true
            if w.canAdd(a) { w.add(a); ai = a }
        }
        guard w.startWriting() else { throw w.error ?? CaptureError.writer }

        writer = w
        videoInput = vi
        audioInput = ai
        sessionStarted = false
        self.url = url

        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if ai != nil { try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
        try await s.startCapture()
        stream = s
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sb.isValid, let writer, writer.status == .writing else { return }
        if type == .screen {
            // Sadece gerçek (tam) kareler; boşta kalma bildirimleri atlanır
            guard let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = atts.first?[.status] as? Int,
                  SCFrameStatus(rawValue: raw) == .complete else { return }
            let pts = CMSampleBufferGetPresentationTimeStamp(sb)
            if !sessionStarted {
                writer.startSession(atSourceTime: pts)
                startTime = pts
                sessionStarted = true
            }
            guard videoInput?.isReadyForMoreMediaData == true else { return }
            if let adaptor, let sharpen, let src = CMSampleBufferGetImageBuffer(sb), let pool = adaptor.pixelBufferPool {
                var out: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
                if let out {
                    sharpen.setValue(CIImage(cvPixelBuffer: src), forKey: kCIInputImageKey)
                    if let img = sharpen.outputImage {
                        ciContext.render(img, to: out, bounds: CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(out),
                                                                     height: CVPixelBufferGetHeight(out)),
                                         colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
                        adaptor.append(out, withPresentationTime: pts)
                        return
                    }
                }
            }
            videoInput?.append(sb)
        } else if type == .audio {
            guard sessionStarted, CMSampleBufferGetPresentationTimeStamp(sb) >= startTime,
                  audioInput?.isReadyForMoreMediaData == true else { return }
            audioInput?.append(sb)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in self?.onUnexpectedStop?() }
    }

    var isRecording: Bool { stream != nil }

    /// Kaydı bitir; başarılıysa dosya adresini döndürür.
    func stop() async -> URL? {
        guard let s = stream else { return nil }
        stream = nil
        try? await s.stopCapture()
        return await withCheckedContinuation { (cont: CheckedContinuation<URL?, Never>) in
            queue.async {
                guard let w = self.writer else { cont.resume(returning: nil); return }
                self.videoInput?.markAsFinished()
                self.audioInput?.markAsFinished()
                let out = self.url
                guard self.sessionStarted else {
                    w.cancelWriting()
                    if let out { try? FileManager.default.removeItem(at: out) }
                    cont.resume(returning: nil)
                    return
                }
                w.finishWriting {
                    cont.resume(returning: w.status == .completed ? out : nil)
                }
                self.writer = nil
            }
        }
    }
}

// MARK: - Kayıt göstergesi (sadece sen görürsün; kayda girmez)

final class RecordingModel: ObservableObject {
    @Published var start = Date()
}

struct RecordingBadge: View {
    @ObservedObject var model: RecordingModel
    let onStop: () -> Void
    @State private var pulse = false

    var body: some View {
        Button(action: onStop) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 11, height: 11)
                    .shadow(color: .red.opacity(0.8), radius: pulse ? 6 : 2)
                    .opacity(pulse ? 0.45 : 1)
                    .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
                TimelineView(.periodic(from: model.start, by: 1)) { ctx in
                    Text(Self.format(ctx.date.timeIntervalSince(model.start)))
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                }
                Image(systemName: "stop.fill").font(.system(size: 10, weight: .bold)).opacity(0.8)
            }
            .foregroundStyle(Color.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .glass(radius: 16, tint: 0.45)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("Kaydı durdur"))
        .onAppear { pulse = true }
        .environment(\.colorScheme, .dark)
    }

    static func format(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}

@MainActor final class RecordingIndicator {
    private let model = RecordingModel()
    private var panel: NSPanel?
    var onStop: (() -> Void)?

    func show(on screen: NSScreen) {
        hide()
        model.start = Date()
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 120, height: 34),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
        p.isReleasedWhenClosed = false
        p.animationBehavior = .none
        p.sharingType = .none          // ekran görüntüsü / kayıtlara girmez
        p.appearance = NSAppearance(named: .darkAqua)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        let host = GlassHostingView(rootView: RecordingBadge(model: model) { [weak self] in
            MainActor.assumeIsolated { self?.onStop?() }
        })
        p.contentView = host
        let size = host.fittingSize
        let f = screen.visibleFrame
        p.setFrame(NSRect(x: f.maxX - size.width - 14, y: f.maxY - size.height - 10,
                          width: size.width, height: size.height), display: true)
        p.orderFrontRegardless()
        panel = p
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

// MARK: - Kalıcı küçük not (kaydırmalı çekim sırasında)

@MainActor final class NoteController {
    private var panel: NSPanel?

    func show(_ text: String, symbol: String, on screen: NSScreen) {
        hide()
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 44),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        p.animationBehavior = .none
        p.sharingType = .none
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        let host = GlassHostingView(rootView: HUDView(name: text, symbol: symbol))
        p.contentView = host
        let size = host.fittingSize
        let f = screen.visibleFrame
        p.setFrame(NSRect(x: f.midX - size.width / 2, y: f.minY + 60, width: size.width, height: size.height), display: true)
        p.orderFrontRegardless()
        panel = p
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

// MARK: - ⌘⇧5 çekim paleti

enum CaptureAction: Int, CaseIterable {
    case screen = 1, area, scroll, recordScreen, recordArea

    var title: String {
        switch self {
        case .screen: return L("Bu monitör")
        case .area: return L("Alan")
        case .scroll: return L("Kaydırmalı")
        case .recordScreen: return L("Monitörü kaydet")
        case .recordArea: return L("Alanı kaydet")
        }
    }
    var symbol: String {
        switch self {
        case .screen: return "display"
        case .area: return "rectangle.dashed"
        case .scroll: return "scroll"
        case .recordScreen: return "record.circle"
        case .recordArea: return "rectangle.dashed.badge.record"
        }
    }
}

struct CapturePaletteView: View {
    let onAction: (CaptureAction) -> Void
    let onClose: () -> Void
    @State private var hover: CaptureAction?

    var body: some View {
        HStack(spacing: 6) {
            ForEach(CaptureAction.allCases, id: \.rawValue) { a in
                if a == .recordScreen {
                    Divider().frame(height: 44).opacity(0.5).padding(.horizontal, 4)
                }
                Button { onAction(a) } label: {
                    VStack(spacing: 5) {
                        Image(systemName: a.symbol)
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(a.rawValue >= 4 ? Color.red : Color.white)
                        Text(a.title).font(.system(size: 11, weight: .semibold))
                        Text("\(a.rawValue)").font(.system(size: 9.5, weight: .bold, design: .rounded)).opacity(0.5)
                    }
                    .frame(width: 92, height: 72)
                    .modifier(SelectionLook(selected: hover == a, radius: 12))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hover = $0 ? a : (hover == a ? nil : hover) }
            }
            Divider().frame(height: 44).opacity(0.5).padding(.horizontal, 4)
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 13, weight: .bold)).frame(width: 30, height: 30)
                    .background(Circle().fill(.white.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .help(L("Kapat (Esc)"))
        }
        .foregroundStyle(Color.white)
        .padding(12)
        .glass(radius: 22)
        .environment(\.colorScheme, .dark)
    }
}

@MainActor final class CapturePalette {
    private var panel: KeyPanel?
    private var keyMonitor: Any?
    private var clickMonitor: Any?
    var onAction: ((CaptureAction) -> Void)?

    var isVisible: Bool { panel?.isVisible == true }

    func show() {
        guard let screen = screenUnderMouse() else { return }
        hide()
        let p = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 100),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .popUpMenu
        p.isReleasedWhenClosed = false
        p.animationBehavior = .none
        p.sharingType = .none
        p.appearance = NSAppearance(named: .darkAqua)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        let host = GlassHostingView(rootView: CapturePaletteView(
            onAction: { [weak self] a in MainActor.assumeIsolated { self?.fire(a) } },
            onClose: { [weak self] in MainActor.assumeIsolated { self?.hide() } }))
        p.contentView = host
        let size = host.fittingSize
        let f = screen.visibleFrame
        p.setFrame(NSRect(x: (f.midX - size.width / 2).rounded(), y: f.minY + 80, width: size.width, height: size.height), display: true)
        p.makeKeyAndOrderFront(nil)
        panel = p

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self else { return false }
                if e.keyCode == 53 { self.hide(); return true }
                if let n = e.charactersIgnoringModifiers.flatMap({ Int($0) }), let a = CaptureAction(rawValue: n) {
                    self.fire(a)
                    return true
                }
                return false
            }
            return handled ? nil : e
        }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
    }

    private func fire(_ a: CaptureAction) {
        hide()
        // Palet ekrandan kalksın, sonra çek
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            MainActor.assumeIsolated { self?.onAction?(a) }
        }
    }

    func hide() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        keyMonitor = nil
        clickMonitor = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

// MARK: - Çekim denetleyicisi

@MainActor final class CaptureController {
    private let hud: HUDController
    private let selector = RegionSelector()
    private let recorder = ScreenRecorder()
    private let indicator = RecordingIndicator()
    private let palette = CapturePalette()
    private let note = NoteController()
    private let toast = CaptureToast()
    private var scrollCancelled = false
    private var scrolling = false
    private var escMonitors: [Any] = []
    private(set) var isRecording = false
    var onRecordingChanged: ((Bool) -> Void)?

    init(hud: HUDController) {
        self.hud = hud
        palette.onAction = { [weak self] a in self?.perform(a) }
        indicator.onStop = { [weak self] in self?.stopRecording() }
        recorder.onUnexpectedStop = { [weak self] in
            MainActor.assumeIsolated { self?.stopRecording() }
        }
    }

    func perform(_ a: CaptureAction) {
        switch a {
        case .screen: screenshotCurrentScreen()
        case .area: screenshotArea()
        case .scroll: scrollingScreenshot()
        case .recordScreen: startRecording(area: false)
        case .recordArea: startRecording(area: true)
        }
    }

    /// ⌘⇧5: kayıt sürüyorsa durdur, değilse paleti aç
    func paletteOrStop() {
        if isRecording { stopRecording() } else if palette.isVisible { palette.hide() } else { palette.show() }
    }

    private func ensurePermission() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        _ = CGRequestScreenCaptureAccess()
        hud.show(name: L("Ekran Kaydı izni gerekli (Ayarlar › İzinler)"), symbol: "lock.fill")
        return false
    }

    /// preview: sağ altta önizleme kartı (tıklayınca dosya klasörde seçili açılır). false: küçük bildirim.
    private func done(_ url: URL?, _ label: String, symbol: String, image: Bool = true, preview: Bool = true) {
        guard let url else {
            hud.show(name: L("%@ kaydedilemedi", label), symbol: "exclamationmark.triangle.fill")
            return
        }
        if image && CaptureSettings.copyToClipboard { CaptureFiles.copyImage(at: url) }
        if preview {
            toast.show(url: url, title: L("%@ kaydedildi", label), isVideo: !image)
        } else {
            hud.show(name: "\(label) · \(url.deletingLastPathComponent().lastPathComponent)", symbol: symbol)
        }
    }

    private func save(_ img: CGImage, to url: URL, scale: CGFloat, label: String) {
        if CaptureSettings.playSound { CaptureFiles.playShutter() }
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = CaptureFiles.savePNG(img, to: url, scale: scale)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.done(ok ? url : nil, label, symbol: "camera.fill") }
            }
        }
    }

    /// macOS'un screencapture aracıyla çek (eski sistemler ve alan seçimi için)
    private func runScreencapture(_ args: [String], url: URL, label: String, preview: Bool = true) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = args + [url.path]
        p.terminationHandler = { _ in
            let exists = FileManager.default.fileExists(atPath: url.path)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    // Alan seçimi Esc ile iptal edildiyse dosya yoktur: sessizce geç
                    if exists { self?.done(url, label, symbol: "camera.fill", preview: preview) }
                }
            }
        }
        do { try p.run() } catch { done(nil, label, symbol: "camera.fill", preview: preview) }
    }

    // MARK: ⌘⇧3 — sadece bulunduğun monitör

    func screenshotCurrentScreen() {
        guard ensurePermission(), let screen = screenUnderMouse() else { return }
        let url = CaptureFiles.newURL(.screen, prefix: L("Ekran Görüntüsü"), ext: "png")
        let id = displayID(of: screen)
        let scale = screen.backingScaleFactor
        let cliArgs = ["-x", "-D", "\(CaptureFiles.cliDisplayIndex(id))"]
        if #available(macOS 14.0, *) {
            Task { @MainActor in
                do {
                    let img = try await SCHelper.image(displayID: id, rect: nil, scale: scale)
                    self.save(img, to: url, scale: scale, label: L("Ekran görüntüsü"))
                } catch {
                    if CaptureSettings.playSound { CaptureFiles.playShutter() }
                    self.runScreencapture(cliArgs, url: url, label: L("Ekran görüntüsü"))
                }
            }
        } else {
            if CaptureSettings.playSound { CaptureFiles.playShutter() }
            runScreencapture(cliArgs, url: url, label: L("Ekran görüntüsü"))
        }
    }

    // MARK: ⌘⇧4 — alan (macOS'un kendi seçicisi: Space ile pencere seçimi de çalışır)

    func screenshotArea() {
        guard ensurePermission() else { return }
        let url = CaptureFiles.newURL(.area, prefix: L("Ekran Alıntısı"), ext: "png")
        runScreencapture(CaptureSettings.playSound ? ["-i"] : ["-i", "-x"], url: url, label: L("Ekran alıntısı"), preview: false)
    }

    // MARK: ⌘⇧6 — kaydırmalı görüntü

    func scrollingScreenshot() {
        guard #available(macOS 14.0, *) else {
            hud.show(name: L("Kaydırmalı görüntü macOS 14 veya üstü ister"), symbol: "exclamationmark.triangle.fill")
            return
        }
        guard ensurePermission(), !scrolling else { return }
        selector.begin(hint: L("Kaydırılacak alanı seç (sayfanın içi) · Esc iptal")) { [weak self] screen, rect in
            self?.runScrolling(screen: screen, rect: rect)
        }
    }

    @available(macOS 14.0, *)
    private func runScrolling(screen: NSScreen, rect: CGRect) {
        let local = RegionSelector.local(rect, in: screen)
        let scale = screen.backingScaleFactor
        let id = displayID(of: screen)
        let primaryH = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let center = CGPoint(x: rect.midX, y: primaryH - rect.midY)   // genel CG koordinatı (sol üst)
        let step = max(40, rect.height * 0.6)
        let url = CaptureFiles.newURL(.scroll, prefix: L("Kaydırmalı Görüntü"), ext: "png")

        scrolling = true
        scrollCancelled = false
        note.show(L("Kaydırmalı çekim… Esc ile bitir"), symbol: "scroll", on: screen)
        installEsc()

        Task { @MainActor in
            defer {
                self.scrolling = false
                self.note.hide()
                self.removeEsc()
            }
            do {
                let (display, filter) = try await SCHelper.filter(displayID: id)
                let cfg = SCHelper.configuration(display: display, rect: local, scale: scale)
                // İmleci alanın ortasına al: kaydırma olayları imlecin altındaki pencereye gider
                CGWarpMouseCursorPosition(center)
                CGAssociateMouseAndMouseCursorPosition(1)
                try await Task.sleep(nanoseconds: 150_000_000)

                var stitcher: Stitcher?
                for _ in 0..<120 {
                    if self.scrollCancelled { break }
                    let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
                    if let st = stitcher {
                        if !st.add(img) || st.height >= 32_000 { break }
                    } else {
                        stitcher = Stitcher(first: img)
                        if stitcher == nil { break }
                    }
                    Self.postScroll(at: center, pixels: step)
                    try await Task.sleep(nanoseconds: 380_000_000)
                }
                guard let out = stitcher?.makeImage() else { throw CaptureError.tooSmall }
                self.save(out, to: url, scale: scale, label: L("Kaydırmalı görüntü"))
            } catch {
                self.hud.show(name: L("Kaydırmalı görüntü alınamadı"), symbol: "exclamationmark.triangle.fill")
            }
        }
    }

    private static func postScroll(at p: CGPoint, pixels: CGFloat) {
        guard let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                              wheel1: Int32(-pixels.rounded()), wheel2: 0, wheel3: 0) else { return }
        e.location = p
        e.post(tap: .cghidEventTap)
    }

    private func installEsc() {
        removeEsc()
        let handler: (NSEvent) -> Void = { [weak self] e in
            if e.keyCode == 53 { MainActor.assumeIsolated { self?.scrollCancelled = true } }
        }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handler) { escMonitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { e in handler(e); return e }) { escMonitors.append(l) }
    }

    private func removeEsc() {
        escMonitors.forEach { NSEvent.removeMonitor($0) }
        escMonitors.removeAll()
    }

    // MARK: ⌘⇧5 — ekran kaydı

    func startRecording(area: Bool) {
        guard !isRecording, ensurePermission() else { return }
        if area {
            selector.begin(hint: L("Kaydedilecek alanı seç · Esc iptal")) { [weak self] screen, rect in
                self?.record(screen: screen, rect: RegionSelector.local(rect, in: screen))
            }
        } else if let screen = screenUnderMouse() {
            record(screen: screen, rect: nil)
        }
    }

    private func record(screen: NSScreen, rect: CGRect?) {
        let url = CaptureFiles.newURL(.video, prefix: L("Ekran Kaydı"), ext: CaptureSettings.format.ext)
        let id = displayID(of: screen)
        let scale = screen.backingScaleFactor
        isRecording = true
        onRecordingChanged?(true)
        Task { @MainActor in
            do {
                try await self.recorder.start(displayID: id, rect: rect, scale: scale, url: url,
                                              fps: CaptureSettings.fps, quality: CaptureSettings.quality,
                                              format: CaptureSettings.format,
                                              audio: CaptureSettings.recordAudio, cursor: CaptureSettings.showCursor)
                // Başlarken durdurulduysa
                guard self.isRecording else { _ = await self.recorder.stop(); return }
                self.indicator.show(on: screen)
            } catch {
                self.isRecording = false
                self.onRecordingChanged?(false)
                self.hud.show(name: L("Kayıt başlatılamadı: %@", error.localizedDescription), symbol: "exclamationmark.triangle.fill")
            }
        }
    }

    func stopRecording(completion: (() -> Void)? = nil) {
        guard isRecording else { completion?(); return }
        // Kayıt henüz başlamadıysa: başlayınca kendini durduracak
        guard recorder.isRecording else {
            isRecording = false
            onRecordingChanged?(false)
            completion?()
            return
        }
        indicator.hide()
        Task { @MainActor in
            let url = await self.recorder.stop()
            self.isRecording = false
            self.onRecordingChanged?(false)
            self.done(url, L("Ekran kaydı"), symbol: "film.fill", image: false)
            completion?()
        }
    }
}


// MARK: - Çekim sonrası önizleme kartı (sağ alt)

struct CaptureToastView: View {
    let image: NSImage?
    let title: String
    let fileName: String
    let isVideo: Bool
    let onOpen: () -> Void
    let onClose: () -> Void
    @State private var hover = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.black.opacity(0.35))
                        if let image {
                            Image(nsImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 128, height: 80)
                                .clipped()
                        } else {
                            Image(systemName: isVideo ? "film" : "photo").font(.system(size: 26)).opacity(0.6)
                        }
                        if isVideo {
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 26))
                                .foregroundStyle(Color.white)
                                .shadow(radius: 4)
                        }
                    }
                    .frame(width: 128, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.25), lineWidth: 0.5))

                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(.system(size: 13, weight: .semibold))
                        Text(fileName).font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
                            .lineLimit(2).truncationMode(.middle)
                        Label(L("Klasörde göster"), systemImage: "folder")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                    }
                    .frame(width: 180, alignment: .leading)
                }
                .padding(12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if hover {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(.black.opacity(0.55)))
                        .overlay(Circle().strokeBorder(.white.opacity(0.3), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .padding(6)
                .help(L("Kapat"))
            }
        }
        .foregroundStyle(Color.white)
        .glass(radius: 18)
        .onHover { hover = $0 }
        .padding(10)
        .environment(\.colorScheme, .dark)
    }
}

@MainActor final class CaptureToast {
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?
    private var hovering = false

    func show(url: URL, title: String, isVideo: Bool) {
        let screen = screenUnderMouse() ?? NSScreen.main
        if isVideo {
            // Videonun ilk karesi
            present(url: url, title: title, isVideo: true, image: nil, on: screen)
            Task { @MainActor in
                let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                gen.appliesPreferredTrackTransform = true
                gen.maximumSize = CGSize(width: 512, height: 512)
                if let frame = try? await gen.image(at: CMTime(seconds: 0.1, preferredTimescale: 600)) {
                    let cg = frame.image
                    let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                    self.present(url: url, title: title, isVideo: true, image: img, on: screen, keepTimer: true)
                }
            }
        } else {
            present(url: url, title: title, isVideo: false, image: NSImage(contentsOf: url), on: screen)
        }
    }

    private func present(url: URL, title: String, isVideo: Bool, image: NSImage?, on screen: NSScreen?, keepTimer: Bool = false) {
        guard let screen else { return }
        let p = panel ?? makePanel()
        panel = p
        let view = CaptureToastView(
            image: image, title: title, fileName: url.lastPathComponent, isVideo: isVideo,
            onOpen: { [weak self] in
                MainActor.assumeIsolated {
                    // Klasörü aç ve dosyayı seçili göster
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                    self?.hide()
                }
            },
            onClose: { [weak self] in MainActor.assumeIsolated { self?.hide() } })
        let host = GlassHostingView(rootView: view)
        p.contentView = host
        let size = host.fittingSize
        let f = screen.visibleFrame
        p.setFrame(NSRect(x: f.maxX - size.width - 6, y: f.minY + 6, width: size.width, height: size.height), display: true)
        p.alphaValue = 1
        p.orderFrontRegardless()

        if !keepTimer { scheduleHide(after: 6) }
    }

    private func scheduleHide(after seconds: Double) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let p = self.panel else { return }
                // Fare üstündeyse bekle
                if p.frame.contains(NSEvent.mouseLocation) { self.scheduleHide(after: 2); return }
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.3
                    p.animator().alphaValue = 0
                }, completionHandler: {
                    MainActor.assumeIsolated {
                        if p.alphaValue == 0 { p.orderOut(nil) }
                    }
                })
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func hide() {
        hideWork?.cancel()
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 120),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
        p.isReleasedWhenClosed = false
        p.animationBehavior = .none
        p.sharingType = .none          // sonraki çekimlere girmez
        p.appearance = NSAppearance(named: .darkAqua)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        return p
    }
}
