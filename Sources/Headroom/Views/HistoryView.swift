import Charts
import SwiftUI

enum HistoryRange: String, CaseIterable, Identifiable {
    case day, week
    var id: String { rawValue }
    var title: String { self == .day ? "24 hours" : "7 days" }
    var seconds: TimeInterval { self == .day ? 86_400 : 7 * 86_400 }
}

/// The History window: one chart per service, every limit as its own line.
struct HistoryView: View {
    @ObservedObject var history: UsageHistory
    @State private var range: HistoryRange = .day

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Usage history").font(.title3.weight(.semibold))
                Spacer()
                Picker("Range", selection: $range) {
                    ForEach(HistoryRange.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
            }

            if history.services.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Nothing recorded yet").font(.headline)
                    Text("Headroom saves your usage every time it refreshes. Check back in a few hours to see how your limits fill up and reset.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 14) {
                        ForEach(history.services) { service in
                            ServiceHistoryCard(service: service, series: history.series(for: service), range: range)
                        }
                    }
                }
            }

            Text("Kept for 7 days, on this Mac only.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 600, height: 560)
    }
}

private struct ChartPoint: Identifiable {
    let id = UUID()
    let line: String
    let title: String
    let date: Date
    let percent: Double
}

private struct ServiceHistoryCard: View {
    let service: ServiceID
    let series: [UsageHistory.Series]
    let range: HistoryRange

    var body: some View {
        let now = Date()
        let start = now.addingTimeInterval(-range.seconds)
        let points = Self.points(series, from: start)
        let titles = series.map(\.title)
        let palette = Self.palette(for: service, count: titles.count)
        let peak = points.map(\.percent).max() ?? 0

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(Color(nsColor: service.color)).frame(width: 8, height: 8)
                Text(service.name).font(.headline)
                Spacer()
                Text("Peak \(Format.percent(peak))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            if points.isEmpty {
                Text("No data in this range yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(height: 150)
            } else {
                Chart(points) { point in
                    LineMark(
                        x: .value("Time", point.date),
                        y: .value("Used", point.percent),
                        series: .value("Line", point.line)
                    )
                    .foregroundStyle(by: .value("Limit", point.title))
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
                .chartForegroundStyleScale(domain: titles, range: palette)
                .chartXScale(domain: start...now)
                .chartYScale(domain: 0...100)
                .chartYAxis {
                    AxisMarks(position: .leading, values: [0, 50, 80, 100]) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let v = value.as(Double.self) { Text("\(Int(v))%") }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: range == .day ? .hour : .day, count: range == .day ? 6 : 1)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: range == .day
                                       ? Date.FormatStyle().hour()
                                       : Date.FormatStyle().weekday(.abbreviated))
                    }
                }
                .chartLegend(position: .bottom, alignment: .leading)
                .frame(height: 170)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(service.name) usage over the last \(range.title), peak \(Format.percent(peak))")
    }

    /// Splits each limit's line where the Mac was asleep (gaps over 20 minutes).
    static func points(_ series: [UsageHistory.Series], from start: Date) -> [ChartPoint] {
        var result: [ChartPoint] = []
        for s in series {
            var segment = 0
            var previous: Date?
            for point in s.points where point.t >= start {
                if let previous = previous, point.t.timeIntervalSince(previous) > 20 * 60 { segment += 1 }
                result.append(ChartPoint(line: "\(s.limitId)#\(segment)", title: s.title, date: point.t, percent: point.p))
                previous = point.t
            }
        }
        return result
    }

    static func palette(for service: ServiceID, count: Int) -> [Color] {
        let base = Color(nsColor: service.color)
        let options: [Color] = [base, base.opacity(0.5), .gray, .gray.opacity(0.5)]
        // One color per line, so the legend and the lines always match up.
        return (0..<max(count, 1)).map { options[$0 % options.count] }
    }
}
