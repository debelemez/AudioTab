import Cocoa
import SwiftUI

// MARK: - Ortak cam görünümü (⌘Tab paneliyle aynı tarif)
//
// blur (.hudWindow) + %30 siyah ton + üstten beyaz parlama + ince beyaz kenar

struct GlassBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

struct GlassStyle: ViewModifier {
    var radius: CGFloat
    var tint: Double = 0.30

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return content
            .background(
                LinearGradient(stops: [.init(color: .white.opacity(0.14), location: 0),
                                       .init(color: .white.opacity(0.03), location: 0.35),
                                       .init(color: .clear, location: 1)],
                               startPoint: .top, endPoint: .bottom)
            )
            .background(Color.black.opacity(tint))
            .background(GlassBlur())
            .clipShape(shape)
            .overlay(shape.strokeBorder(.white.opacity(0.30), lineWidth: 1))
    }
}

extension View {
    func glass(radius: CGFloat, tint: Double = 0.30) -> some View {
        modifier(GlassStyle(radius: radius, tint: tint))
    }
}

/// Uygulama arka plandayken de ilk tıklamayı düğmelere ileten SwiftUI barındırıcı.
/// (Normal NSHostingView ilk tıklamayı sadece "pencereyi öne al" sayar; bizim uygulama hiç öne
/// gelmediği için her tıklama ilk tıklama olur ve fareyle hiçbir şey seçilemez.)
final class GlassHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Fare imlecinin bulunduğu ekran.
func screenUnderMouse() -> NSScreen? {
    let p = NSEvent.mouseLocation
    return NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main
}

/// Seçili öğe görünümü: ⌘Tab kartlarıyla aynı (parlak zemin + vurgu çerçevesi + ışıma).
struct SelectionLook: ViewModifier {
    var selected: Bool
    var radius: CGFloat = 14

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return content
            .background(shape.fill(.white.opacity(selected ? 0.22 : 0.06))
                .shadow(color: selected ? Color.accentColor.opacity(0.7) : .clear, radius: 10))
            .overlay(shape.strokeBorder(selected ? Color.accentColor : .white.opacity(0.10),
                                        lineWidth: selected ? 2.5 : 1))
    }
}

// MARK: - Ses cihazı paneli

final class PanelModel: ObservableObject {
    @Published var highlighted: String?
}

struct DevicePanelView: View {
    @ObservedObject var store: DeviceStore
    @ObservedObject var model: PanelModel
    var onPick: (String) -> Void

    var body: some View {
        let connected = store.panelRows.filter(\.isConnected)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Label(L("Ses Çıkışı"), systemImage: "speaker.wave.2.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                Spacer()
                Text(L("%@ sonraki · ⌘ bırak / ↩ seç · esc", store.hotkeyChoice.stepKey))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 4)

            ForEach(store.panelRows) { row in
                DeviceRowView(row: row,
                              number: connected.firstIndex(of: row).map { $0 + 1 },
                              highlighted: model.highlighted == row.id)
                    .contentShape(Rectangle())
                    .onTapGesture { if row.isConnected { onPick(row.id) } }
                    .onHover { inside in if inside && row.isConnected { model.highlighted = row.id } }
            }
        }
        .padding(16)
        .frame(width: 420)
        .glass(radius: 26)
        .environment(\.colorScheme, .dark)
    }
}

struct DeviceRowView: View {
    let row: DeviceRow
    let number: Int?
    let highlighted: Bool

    private var subtitle: String {
        if row.isCurrent { return L("Şu an çalıyor") }
        if !row.isConnected { return L("Bağlı değil · hatırlanıyor") }
        return row.inCycle ? L("Kısayol döngüsünde") : L("Bağlı")
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(row.isCurrent ? AnyShapeStyle(Color.accentColor)
                                        : AnyShapeStyle(Color.white.opacity(0.14)))
                Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5)
                Image(systemName: row.symbol)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.white)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    if row.inCycle {
                        Circle().fill(Color.accentColor).frame(width: 5, height: 5)
                    }
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.65))
                }
            }

            Spacer(minLength: 8)

            if row.isCurrent {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(Color.accentColor)
            } else if let number, number <= 9 {
                Text("\(number)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 20, height: 20)
                    .background(RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.10)))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .modifier(SelectionLook(selected: highlighted))
        .opacity(row.isConnected ? 1 : 0.5)
    }
}

// MARK: - Geçiş bildirimi (HUD)

struct HUDView: View {
    let name: String
    let symbol: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .medium))
            Text(name)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(Color.white)
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .glass(radius: 22)
        .environment(\.colorScheme, .dark)
    }
}
