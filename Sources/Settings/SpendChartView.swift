import Charts
import SwiftUI

/// Renders a native 14-day token spend and dollar cost bar chart.
struct SpendChartView: View {
    let points: [TokenCostStore.DailyHistoryPoint]

    @State private var hoveredPoint: TokenCostStore.DailyHistoryPoint?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("14-Day Token Spend")
                        .font(.callout.weight(.medium))
                    Text("Aggregated daily from local session logs")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if let current = hoveredPoint ?? points.last {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(CostFormat.tokensWithCost(current.tokens, cost: current.costUSD > 0 ? current.costUSD : nil))
                            .font(.subheadline.monospacedDigit().weight(.semibold))
                        Text(current.dayLabel)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if points.allSatisfy({ $0.tokens == 0 }) {
                HStack {
                    Spacer()
                    Text("No local logs detected in the last 14 days")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 20)
                    Spacer()
                }
            } else {
                Chart(points) { point in
                    BarMark(
                        x: .value("Date", point.dayLabel),
                        y: .value("Tokens", point.tokens)
                    )
                    .foregroundStyle(Palette.ample.opacity(hoveredPoint?.id == point.id ? 1.0 : 0.75))
                    .cornerRadius(3)
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 7)) { _ in
                        AxisValueLabel()
                            .font(.system(size: 9))
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 2]))
                        AxisValueLabel {
                            if let doubleVal = value.as(Double.self) {
                                Text(CostFormat.tokens(doubleVal))
                                    .font(.system(size: 9))
                            }
                        }
                    }
                }
                .frame(height: 110)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }
}
