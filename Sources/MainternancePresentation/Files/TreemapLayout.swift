import CoreGraphics

struct TreemapItem: Equatable, Sendable {
    var id: String
    var size: Int64
}

struct TreemapTile: Equatable, Sendable {
    var id: String
    var rect: CGRect

    /// The rectangle to draw (and hit-test), or nil when the tile is too small to inset and show.
    func drawRect(inset: CGFloat = 1) -> CGRect? {
        let minimum = max(inset * 2, 2)
        guard rect.width.isFinite, rect.height.isFinite, rect.width >= minimum,
              rect.height >= minimum else { return nil }
        return rect.insetBy(dx: inset, dy: inset)
    }
}

/// Squarified treemap. Areas are proportional to sizes and tiles cover the container without overlap.
enum TreemapLayout {
    static func layout(_ items: [TreemapItem], in container: CGRect) -> [TreemapTile] {
        let valid = items.filter { $0.size > 0 }.sorted { $0.size != $1.size ? $0.size > $1.size : $0.id < $1.id }
        let total = valid.reduce(0.0) { $0 + Double($1.size) }
        guard !valid.isEmpty, total > 0, container.width > 0, container.height > 0 else { return [] }

        let scale = Double(container.width * container.height) / total
        var areas = valid.map { Double($0.size) * scale }
        var tiles: [TreemapTile] = []
        var free = container
        var start = 0

        while start < valid.count {
            let side = Double(min(free.width, free.height))
            var end = start + 1
            var best = worst(areas[start ..< end], side)
            while end < valid.count {
                let candidate = worst(areas[start ... end], side)
                if candidate > best {
                    break
                }
                best = candidate
                end += 1
            }
            let rowArea = areas[start ..< end].reduce(0, +)
            let horizontalStrip = free.width >= free.height // row laid along the left edge
            let thickness = side > 0 ? CGFloat(rowArea / side) : 0
            var offset: CGFloat = 0
            for index in start ..< end {
                let length = rowArea > 0 ? CGFloat(areas[index] / rowArea) * CGFloat(side) : 0
                let rect = horizontalStrip
                    ? CGRect(x: free.minX, y: free.minY + offset, width: thickness, height: length)
                    : CGRect(x: free.minX + offset, y: free.minY, width: length, height: thickness)
                tiles.append(TreemapTile(id: valid[index].id, rect: rect))
                offset += length
            }
            free = horizontalStrip
                ? CGRect(
                    x: free.minX + thickness,
                    y: free.minY,
                    width: max(free.width - thickness, 0),
                    height: free.height
                )
                : CGRect(
                    x: free.minX,
                    y: free.minY + thickness,
                    width: free.width,
                    height: max(free.height - thickness, 0)
                )
            start = end
            if free.width <= 0 || free.height <= 0 {
                break
            }
        }
        areas.removeAll()
        return tiles
    }

    private static func worst(_ row: ArraySlice<Double>, _ side: Double) -> Double {
        let sum = row.reduce(0, +)
        guard let low = row.min(), let high = row.max(), low > 0, side > 0 else { return .infinity }
        let s2 = sum * sum
        return max(side * side * high / s2, s2 / (side * side * low))
    }
}
