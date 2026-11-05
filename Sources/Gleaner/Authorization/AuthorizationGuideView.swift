import AppKit
import SwiftUI

/// Content of the floating guide: the app icon to drag, and where to drag it.
struct AuthorizationGuideView: View {
    @ObservedObject var guide: AuthorizationGuide
    @State private var nudge = false

    private let appIcon = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: appIcon)
                .resizable()
                .interpolation(.high)
                .frame(width: 44, height: 44)
                .shadow(color: .black.opacity(0.15), radius: 3, y: 1.5)
                .onDrag { NSItemProvider(object: Bundle.main.bundleURL as NSURL) }
                .hoverHint("拖动")

            VStack(alignment: .leading, spacing: 3) {
                if guide.granted {
                    Label("授权成功", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.positive)
                } else {
                    HStack(spacing: 5) {
                        Text(instruction)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        if let arrow {
                            Image(systemName: arrow)
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(Theme.textSecondary)
                                .offset(x: guide.placement == .beside ? (nudge ? -3 : 2) : 0,
                                        y: guide.placement == .below ? (nudge ? -3 : 2) : 0)
                                .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: nudge)
                        }
                    }
                    Button("重新打开系统设置") { NSWorkspace.shared.open(AuthorizationGuide.settingsURL) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 34)
        .padding(.vertical, 12)
        .hintLayer()
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.canvas))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.cardStroke, lineWidth: 0.5))
        .overlay(alignment: .topTrailing) {
            Button { guide.close() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Theme.subtleFill))
            }
            .buttonStyle(.plain)
            .padding(8)
            .hoverHint("关闭")
        }
        .fixedSize()
        .onAppear { nudge = true }
        .animation(.easeOut(duration: 0.25), value: guide.granted)
    }

    private var instruction: String {
        switch guide.placement {
        case .below: return "把图标拖到上方的列表中"
        case .beside: return "把图标拖到左侧的列表中"
        case .unknown: return "把图标拖到系统设置的列表中"
        }
    }

    private var arrow: String? {
        switch guide.placement {
        case .below: return "arrow.up"
        case .beside: return "arrow.left"
        case .unknown: return nil
        }
    }
}
