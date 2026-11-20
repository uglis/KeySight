import SwiftUI

struct PermissionView: View {
    let onOpenSettings: () -> Void
    let onRecheck: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.14))
                    .frame(width: 56, height: 56)
                Image(systemName: "hand.raised.fingers.spread.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(Color.accentColor)
            }

            VStack(spacing: 6) {
                Text("需要「辅助功能」权限")
                    .font(.system(size: 16, weight: .semibold))
                Text("KeySight 需要读取当前应用菜单栏和焦点状态，才能实时显示“当前界面真正可用”的快捷键，并支持长按 ⌘ 呼出和回车直达执行。")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                stepRow(number: "1", text: "点击下方按钮打开「系统设置 → 隐私与安全性 → 辅助功能」")
                stepRow(number: "2", text: "勾选开启 KeySight（开启后本悬浮窗会自动刷新生效）")
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )

            HStack(spacing: 10) {
                Button(action: onOpenSettings) {
                    Label("打开辅助功能设置", systemImage: "gearshape.fill")
                        .font(.system(size: 12.5, weight: .semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)

                Button("立即检测", action: onRecheck)
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
            }

            Text("注：在授权前，下方仍可查看系统与常用软件的免触控板快捷键。")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(20)
    }

    private func stepRow(number: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(number)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.accentColor))
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.primary.opacity(0.88))
        }
    }
}
