import SwiftUI
import KeySightCore

/// Per-row isolated hover state so moving the mouse across rows re-renders ONLY the hovered row
/// instead of re-evaluating the entire HUD view tree.
private final class RowHoverState: ObservableObject {
    @Published var isHovered: Bool = false
}

struct ShortcutRowView: View {
    let item: ShortcutItem
    let isPinned: Bool
    let isMastered: Bool
    let isSelected: Bool
    var compact: Bool = false
    var glassStyle: Bool = false

    let onExecute: () -> Void
    let onTogglePin: () -> Void
    let onToggleMastered: () -> Void

    @StateObject private var hoverState = RowHoverState()

    var body: some View {
        let isHovered = hoverState.isHovered
        HStack(spacing: 8) {
            if isPinned {
                Image(systemName: "star.fill")
                    .font(.system(size: 9.5))
                    .foregroundStyle(isSelected ? Color.yellow : Color.orange)
                    .frame(width: 12)
            } else if item.source == .contextTip {
                Image(systemName: "sparkles")
                    .font(.system(size: 9.5))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.9) : Color.accentColor)
                    .frame(width: 12)
            }

            VStack(alignment: .leading, spacing: 1.5) {
                Text(item.title)
                    .font(.system(size: compact ? 12 : 12.5, weight: .medium))
                    .foregroundStyle(
                        isSelected
                            ? Color.white
                            : (item.isEnabled ? Color.primary : Color.secondary.opacity(0.6))
                    )
                    .lineLimit(1)
                    .truncationMode(.tail)

                if let subtitle = item.subtitle, !subtitle.isEmpty, !compact {
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.75) : Color.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 6)

            if isHovered || isSelected {
                HStack(spacing: 4) {
                    actionButton(
                        icon: isPinned ? "star.fill" : "star",
                        tint: isPinned ? .orange : (isSelected ? .white.opacity(0.85) : .secondary),
                        help: isPinned ? "取消置顶练习 (⌘P)" : "置顶到重点练习 (⌘P)",
                        action: onTogglePin
                    )
                    actionButton(
                        icon: isMastered ? "arrow.uturn.backward.circle" : "checkmark.circle",
                        tint: isSelected ? .white.opacity(0.85) : .green,
                        help: isMastered ? "恢复显示 (⌘M)" : "标为已记住并收起 (⌘M)",
                        action: onToggleMastered
                    )
                    if !compact {
                        actionButton(
                            icon: "play.fill",
                            tint: isSelected ? .white : .accentColor,
                            help: "立即执行 (↩)",
                            action: onExecute
                        )
                    }
                }
            }

            KeycapClusterView(
                combo: item.keyCombo,
                isSelected: isSelected,
                isDimmed: !item.isEnabled,
                compact: compact,
                glassStyle: glassStyle
            )
        }
        .padding(.horizontal, compact ? 6 : 10)
        .padding(.vertical, compact ? 3.5 : 6.5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(backgroundColor(isHovered: isHovered))
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            if hoverState.isHovered != hovering {
                hoverState.isHovered = hovering
            }
        }
        .onTapGesture {
            onExecute()
        }
    }

    private func backgroundColor(isHovered: Bool) -> Color {
        if isSelected {
            return Color.accentColor
        }
        if isHovered {
            return Color.primary.opacity(0.075)
        }
        return Color.clear
    }

    private func actionButton(icon: String, tint: Color, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 20, height: 20)
                .background(
                    Circle().fill(isSelected ? Color.white.opacity(0.16) : Color.primary.opacity(0.06))
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
