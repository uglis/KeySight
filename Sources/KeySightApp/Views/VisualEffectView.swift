import AppKit
import SwiftUI
import KeySightCore

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var cornerRadius: CGFloat = 18

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = cornerRadius
        view.layer?.masksToBounds = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.layer?.cornerRadius = cornerRadius
    }
}

/// Renders the selected HUD backdrop style.
/// On macOS 26+, `.liquidGlass` and `.liquidGlassClear` are backed directly by AppKit's native `NSGlassEffectView`
/// hosted by `FloatingPanelController`, so this view stays optically clear to avoid double-blurring.
struct HUDSurfaceBackground: View {
    let style: HUDAppearanceStyle
    let cornerRadius: CGFloat

    private var usesNativeLiquidGlass: Bool {
        if #available(macOS 26.0, *) {
            return style.isLiquidGlass
        }
        return false
    }

    var body: some View {
        Group {
            if usesNativeLiquidGlass {
                // Native NSGlassEffectView provides real refraction & specular rim underneath
                Color.clear
            } else {
                switch style {
                case .liquidGlass:
                    ZStack {
                        VisualEffectView(material: .hudWindow, blendingMode: .behindWindow, cornerRadius: cornerRadius)
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.18),
                                Color.white.opacity(0.03),
                                Color.accentColor.opacity(0.05)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    }
                case .liquidGlassClear:
                    ZStack {
                        VisualEffectView(material: .popover, blendingMode: .behindWindow, cornerRadius: cornerRadius)
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.24),
                                Color.clear,
                                Color.white.opacity(0.08)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    }
                case .frostedHUD:
                    VisualEffectView(material: .hudWindow, blendingMode: .behindWindow, cornerRadius: cornerRadius)
                case .solidGraphite:
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color(red: 0.11, green: 0.12, blue: 0.15).opacity(0.94))
                }
            }
        }
    }
}

/// Renders a KeyCombo as crisp tactile macOS keycap badges, e.g. [⌃] [⇧] [T]
struct KeycapClusterView: View {
    let combo: KeyCombo
    var isSelected: Bool = false
    var isDimmed: Bool = false
    var compact: Bool = false
    var glassStyle: Bool = false

    var body: some View {
        HStack(spacing: compact ? 3 : 4) {
            ForEach(Array(combo.keycaps.enumerated()), id: \.offset) { _, cap in
                Text(cap)
                    .font(.system(size: compact ? 11 : 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(
                        isSelected
                            ? Color.white
                            : (isDimmed ? Color.secondary.opacity(0.6) : Color.primary.opacity(0.94))
                    )
                    .padding(.horizontal, cap.count > 1 ? (compact ? 5 : 6) : 0)
                    .frame(minWidth: compact ? 20 : 23, minHeight: compact ? 20 : 22)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(
                                isSelected
                                    ? Color.white.opacity(0.24)
                                    : (glassStyle ? Color.primary.opacity(0.10) : Color.primary.opacity(0.085))
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: isSelected
                                        ? [Color.white.opacity(0.45), Color.white.opacity(0.20)]
                                        : (glassStyle
                                            ? [Color.white.opacity(0.32), Color.primary.opacity(0.12)]
                                            : [Color.primary.opacity(0.15), Color.primary.opacity(0.12)]),
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 0.8
                            )
                    )
            }
        }
    }
}

struct MiniToggleChip: View {
    let label: String
    let icon: String
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(label)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(isOn ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.07))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(isOn ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.10), lineWidth: 0.75)
            )
        }
        .buttonStyle(.plain)
    }
}
