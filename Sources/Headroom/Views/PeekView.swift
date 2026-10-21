import SwiftUI

/// The quick peek card the shortcut shows at the top of the screen.
struct PeekView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Headroom").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text(Format.updatedText(store.lastRefresh, now: context.date))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                if store.connected.isEmpty {
                    Text("No services connected. Open Settings to sign in.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                        ForEach(order, id: \.self) { service in
                            row(service, now: context.date)
                        }
                    }
                    .font(.system(size: 12))
                    .monospacedDigit()
                }

                Divider()
                HStack {
                    Text("Release to close")
                    Spacer()
                    Text("↩").fontWeight(.semibold) + Text(" full view · ") + Text("esc").fontWeight(.semibold) + Text(" close")
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 12)
        }
        .frame(width: 440)
        .background(PanelBackground(material: .hudWindow))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .environment(\.colorScheme, .dark)
    }

    private var order: [ServiceID] {
        let ranked = store.ranked.map(\.service)
        return ranked + store.connected.filter { !ranked.contains($0) }
    }

    @ViewBuilder
    private func row(_ service: ServiceID, now: Date) -> some View {
        GridRow {
            HStack(spacing: 6) {
                Circle().fill(Color(nsColor: service.color)).frame(width: 7, height: 7)
                Text(service.name)
            }
            .frame(width: 76, alignment: .leading)

            if let snapshot = store.states[service]?.snapshot, let limit = snapshot.tightest ?? snapshot.primary {
                UsageBar(percent: limit.percent ?? 0,
                         color: Color(nsColor: Palette.fill(service, limit.level)), height: 6)
                    .frame(maxWidth: .infinity)
                Text(limit.displayValue)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color(nsColor: Palette.text(for: limit.level)))
                    .frame(width: 44, alignment: .trailing)
                Text(resetPhrase(limit.resetsAt, now: now))
                    .foregroundStyle(.secondary)
                    .frame(width: 92, alignment: .leading)
            } else {
                Text(statusText(store.states[service]))
                    .foregroundStyle(.secondary)
                    .gridCellColumns(3)
            }
        }
    }

    private func resetPhrase(_ date: Date?, now: Date) -> String {
        guard let date = date else { return "" }
        let seconds = date.timeIntervalSince(now)
        if seconds < 12 * 3600 { return "in " + Format.duration(seconds) }
        return "on " + Format.dayTime(date)
    }

    private func statusText(_ state: ServiceState?) -> String {
        switch state {
        case .signedOut: return "Signed out"
        case .loading: return "Loading…"
        case .failed(let message, _): return message
        default: return "Not connected"
        }
    }
}
