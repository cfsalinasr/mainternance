import SwiftUI

/// Collapsed by default; the system disclosure group keeps its own expansion state.
struct DetailsDisclosure: View {
    let series: HistorySeries
    let temperatureText: String?

    var body: some View {
        DisclosureGroup("Details") {
            VStack(spacing: 10) {
                if let cpu = series.cpu {
                    SparklineRow(title: "CPU", values: cpu)
                }
                if let gpu = series.gpu {
                    SparklineRow(title: "GPU", values: gpu)
                }
                if let memory = series.memory {
                    SparklineRow(title: "RAM pressure", values: memory)
                }
                if let temperatureText {
                    HStack {
                        Text("Temperature").foregroundStyle(.secondary)
                        Spacer()
                        Text(temperatureText)
                    }
                    .font(.system(size: 12))
                }
            }
            .padding(.top, 8)
        }
        .font(.system(size: 13))
        .frame(maxWidth: .infinity, alignment: .leading)
        .solidCard()
    }
}

private struct SparklineRow: View {
    let title: String
    let values: [Double]

    var body: some View {
        HStack(spacing: 12) {
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
            Sparkline(values: values)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                .frame(height: 28)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Plain `Path` line through values in 0...1; draws nothing until there are two points.
struct Sparkline: Shape {
    let values: [Double]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count >= 2 else { return path }
        let step = rect.width / CGFloat(values.count - 1)
        for (index, value) in values.enumerated() {
            let point = CGPoint(x: rect.minX + step * CGFloat(index), y: rect.maxY - rect.height * CGFloat(value))
            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        return path
    }
}
