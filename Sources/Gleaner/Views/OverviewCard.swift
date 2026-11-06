import GleanerCore
import SwiftUI

/// Opens the overview: a white capsule, plainer than 提问 but easy to find.
struct OverviewButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "text.justify.leading").font(.system(size: 10.5, weight: .semibold))
                Text("总览")
            }
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Theme.card).shadow(color: .black.opacity(0.06), radius: 1.5, y: 1))
            .overlay(Capsule().strokeBorder(hovering ? Theme.cardStrokeHover : Theme.cardStroke, lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Everything open at a glance, at the top of the list. Lines lead to their cards.
struct OverviewCard: View {
    @EnvironmentObject private var model: AppModel
    let state: AppModel.OverviewState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("总览").font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.textTertiary)
                Spacer()
                if model.overviewIsStale {
                    Button("有更新") { model.showOverview(refresh: true) }
                        .buttonStyle(PillButtonStyle())
                        .padding(.vertical, -4)
                }
                IconButton(symbol: "xmark", help: "收起") { model.hideOverview() }
                    .padding(.vertical, -6)
            }
            switch state {
            case .loading:
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, alignment: .leading)
            case .failed:
                HStack(spacing: 8) {
                    Text("没整理出来").font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
                    Button("重试") { model.showOverview(refresh: true) }.buttonStyle(PillButtonStyle())
                }
            case .ready(let overview):
                content(overview)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .fill(Theme.card)
                .shadow(color: .black.opacity(0.04), radius: 1.5, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(Theme.cardStroke, lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private func content(_ overview: Overview) -> some View {
        Text(overview.headline)
            .font(.system(size: 13.5, weight: .semibold))
            .foregroundStyle(Theme.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
        if !overview.first.isEmpty { group("先处理", overview.first) }
        if !overview.quick.isEmpty { group("回复一下就好", overview.quick) }
        if !overview.later.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                heading("可以晚点看")
                Text(overview.later)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        if !overview.advice.isEmpty {
            Text(overview.advice)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textPrimary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.insetRadius, style: .continuous).fill(Theme.inset))
        }
    }

    private func group(_ title: String, _ lines: [Overview.Line]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            heading(title)
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in OverviewLineRow(line: line) }
        }
    }

    private func heading(_ title: String) -> some View {
        Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textTertiary)
    }
}

/// One thing to do; clicking scrolls to its card.
private struct OverviewLineRow: View {
    @EnvironmentObject private var model: AppModel
    let line: Overview.Line
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle().fill(Theme.textTertiary.opacity(0.6)).frame(width: 4, height: 4)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 0.5 }
            Text(line.text)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Image(systemName: "arrow.down.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
                .opacity(hovering ? 1 : 0)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering ? Theme.subtleFill : .clear))
        .padding(.horizontal, -4)
        .onHover { hovering = $0 }
        .clickable { model.reveal(line.itemIDs) }
    }
}
