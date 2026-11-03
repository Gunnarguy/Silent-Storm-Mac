import SwiftUI

/// A row of category chips with counts that wraps onto as many lines as it needs. "All" is the empty selection.
struct ChipBar: View {
    let items: [(name: String, count: Int)]
    @Binding var selection: String
    var allTitle: String? = "All"

    var body: some View {
        FlowLayout(spacing: 4) {
            if let allTitle { chip(allTitle, items.reduce(0) { $0 + $1.count }, value: "") }
            ForEach(items, id: \.name) { item in chip(item.name, item.count, value: item.name) }
        }
    }

    private func chip(_ title: String, _ count: Int, value: String) -> some View {
        let on = selection == value
        return Button { selection = value } label: {
            HStack(spacing: 3) {
                Text(title).font(.system(size: 11, weight: on ? .semibold : .regular))
                Text("\(count)").font(.system(size: 9.5, design: .monospaced)).foregroundStyle(on ? Color.white.opacity(0.8) : Color.secondary)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(on ? Color.accentColor : Color.white.opacity(0.07))
            .foregroundStyle(on ? Color.white : Color.primary)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Counts of each name, largest first, then by name.
    static func counted<S: Sequence>(_ names: S) -> [(name: String, count: Int)] where S.Element == String {
        var counts: [String: Int] = [:]
        for n in names { counts[n, default: 0] += 1 }
        return counts.map { (name: $0.key, count: $0.value) }.sorted { $0.count == $1.count ? $0.name < $1.name : $0.count > $1.count }
    }
}

/// Lays children out left to right and wraps them, like words in a paragraph.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews) {
            var x = bounds.minX
            for i in row.indices {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row { var indices: [Int] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, _ subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty && rows[rows.count - 1].width + spacing + size.width > width {
                let last = rows[rows.count - 1]
                rows.append(Row(y: last.y + last.height + spacing))
            }
            var row = rows[rows.count - 1]
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(i)
            rows[rows.count - 1] = row
        }
        return rows
    }
}
