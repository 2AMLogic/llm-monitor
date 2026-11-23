#if os(macOS)
import SwiftUI
import Charts

struct ProviderHistoryChart: View {
    let provider: AccountProvider
    let store: UsageStore
    @State private var history: ProviderUsageHistory?
    @State private var loadError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(provider.displayName) total").font(.title2.bold())
                Spacer()
                Text("Last 7 days").foregroundStyle(.secondary)
            }
            if let history {
                Text("Cumulative weekly quota used").font(.headline)
                if !history.quota.isEmpty {
                    Chart(history.quota) { sample in
                        LineMark(x: .value("Time", sample.timestamp),
                                 y: .value("Quota points", sample.points))
                    }
                    .chartXScale(domain: history.range)
                    .chartYAxisLabel("Quota points")
                    .frame(minHeight: 110)
                } else {
                    emptyChart("No weekly quota readings in this period.")
                }
                Text("Recorded increases across accounts. 100 points equal one account’s full weekly quota.")
                    .font(.caption).foregroundStyle(.secondary)

                Divider().padding(.vertical, 3)
                Text("Hourly billable tokens").font(.headline)
                if history.tokens.isEmpty {
                    emptyChart("No token usage recorded for \(provider.displayName) in this period.")
                } else {
                    Chart(history.tokens) { point in
                        BarMark(x: .value("Hour", point.timestamp, unit: .hour),
                                y: .value("Tokens", point.count))
                    }
                    .chartXScale(domain: history.range)
                    .chartYAxis {
                        AxisMarks { _ in
                            AxisGridLine()
                            AxisValueLabel(format: FloatingPointFormatStyle<Double>.number.notation(.compactName))
                        }
                    }
                    .frame(minHeight: 100)
                }
                Text("Includes input, output and cache-write tokens. Unmapped records use the model family.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let loadError {
                Text(loadError).foregroundStyle(.secondary)
                Spacer()
            } else {
                ProgressView("Loading totals…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(24)
        .frame(minWidth: 510, minHeight: 410)
        .task {
            do {
                let value = try await store.loadProviderHistory(for: provider)
                try Task.checkCancellation()
                history = value
            } catch is CancellationError {
                return
            } catch {
                loadError = "Couldn’t load usage totals. \(error.localizedDescription)"
            }
        }
    }

    private func emptyChart(_ message: String) -> some View {
        Text(message).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
#endif
