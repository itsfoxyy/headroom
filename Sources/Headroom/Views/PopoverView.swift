import AppKit
import SwiftUI

struct PopoverActions {
    var openUsagePage: (ServiceID) -> Void
    var openSettings: () -> Void
    var signIn: (ServiceID) -> Void
    var quit: () -> Void
}

/// The dropdown under the menu bar icon: Compact or Standard.
struct PopoverView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var settings: AppSettings
    let actions: PopoverActions

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 0) {
                header
                if store.connected.isEmpty {
                    EmptyServicesView(actions: actions)
                } else if settings.layout == .compact {
                    CompactList(store: store, actions: actions, now: context.date)
                } else {
                    StandardList(store: store, actions: actions, now: context.date)
                }
                footer(now: context.date)
            }
            .padding(.top, 10)
            .padding(.bottom, 6)
        }
        .frame(width: 340)
        .background(PanelBackground(material: .menu))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }

    private var header: some View {
        HStack {
            Text("Headroom").font(.system(size: 13, weight: .semibold))
            Spacer()
            if settings.layout == .standard, store.connected.count > 1 {
                Text("\(store.connected.count) services")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 4)
            }
            Button {
                Task { await store.refreshAll() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(store.isRefreshing)
            .help("Refresh now")
            .accessibilityLabel("Refresh all services")
            .keyboardShortcut("r")
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.bottom, 4)
    }

    private func footer(now: Date) -> some View {
        VStack(spacing: 0) {
            Divider().padding(.horizontal, 6)
            HStack(spacing: 2) {
                Text(store.isRefreshing ? "Refreshing…" : Format.updatedText(store.lastRefresh, now: now))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 8)
                Spacer()
                TextButton("Settings…", action: actions.openSettings).keyboardShortcut(",")
                TextButton("Quit", action: actions.quit).keyboardShortcut("q")
            }
            .padding(.horizontal, 6)
            .padding(.top, 4)
        }
    }
}

// MARK: - Compact

struct CompactList: View {
    @ObservedObject var store: UsageStore
    let actions: PopoverActions
    let now: Date

    var body: some View {
        VStack(spacing: 2) {
            ForEach(rowOrder, id: \.self) { service in
                switch store.states[service] ?? .notConnected {
                case .ok(let snapshot), .failed(_, let snapshot?):
                    CompactRow(snapshot: snapshot,
                               error: store.states[service]?.errorMessage,
                               expanded: store.expandedService == service,
                               now: now) {
                        guard !snapshot.extras.isEmpty else { return }
                        store.expandedService = store.expandedService == service ? nil : service
                    }
                default:
                    ServiceStatusRow(service: service, state: store.states[service] ?? .notConnected, actions: actions)
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 6)
    }

    /// Services with numbers, closest to a limit first; the rest after.
    private var rowOrder: [ServiceID] {
        let ranked = store.ranked.map(\.service)
        return ranked + store.connected.filter { !ranked.contains($0) }
    }
}

struct CompactRow: View {
    let snapshot: ServiceSnapshot
    let error: String?
    let expanded: Bool
    let now: Date
    let toggle: () -> Void

    var body: some View {
        let service = snapshot.service
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                VStack(alignment: .leading, spacing: 7) {
                    if let primary = snapshot.primary {
                        HStack(spacing: 9) {
                            Ring(percent: primary.percent ?? 0, color: Color(nsColor: Palette.fill(service, primary.level)))
                                .frame(width: 26, height: 26)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(service.name).font(.system(size: 13, weight: .semibold))
                                Text(primary.shortTitle + (snapshot.extras.isEmpty ? "" : "  ›"))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            VStack(alignment: .trailing, spacing: 1) {
                                Text(primary.displayValue)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(Color(nsColor: Palette.text(for: primary.level)))
                                Text(Format.shortReset(primary.resetsAt, now: now))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        UsageBar(percent: primary.percent ?? 0, color: Color(nsColor: Palette.fill(service, primary.level)), height: 4)
                    }
                    if let secondary = snapshot.secondary {
                        SecondaryLine(service: service, limit: secondary, now: now)
                    }
                    if let error = error {
                        Text("\(error) · showing last numbers")
                            .font(.system(size: 11))
                            .foregroundStyle(Color(nsColor: Palette.warningText))
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 9)
                .padding(.bottom, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(snapshot.extras) { limit in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(limit.title).foregroundStyle(.secondary)
                                Spacer()
                                Text(Format.shortReset(limit.resetsAt, now: now)).foregroundStyle(.secondary)
                                Text(limit.displayValue).fontWeight(.semibold)
                            }
                            if let note = limit.note {
                                Text(note).foregroundStyle(.tertiary)
                            }
                        }
                        .font(.system(size: 11))
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
            }
        }
        .monospacedDigit()
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(expanded ? Color.primary.opacity(0.05) : Color.clear)
        )
        .accessibilityElement(children: .combine)
    }
}

struct SecondaryLine: View {
    let service: ServiceID
    let limit: UsageLimit
    let now: Date

    var body: some View {
        HStack(spacing: 8) {
            Text(limit.shortTitle).frame(width: 52, alignment: .leading)
            if let percent = limit.percent {
                UsageBar(percent: percent, color: Color(nsColor: Palette.fill(service, limit.level)).opacity(0.6), height: 3)
            } else {
                Spacer()
            }
            Text(Format.shortReset(limit.resetsAt, now: now)).foregroundStyle(.secondary)
            Text(limit.displayValue)
                .fontWeight(.semibold)
                .foregroundStyle(Color(nsColor: Palette.text(for: limit.level)))
                .frame(minWidth: 36, alignment: .trailing)
        }
        .font(.system(size: 11))
    }
}

// MARK: - Standard

struct StandardList: View {
    @ObservedObject var store: UsageStore
    let actions: PopoverActions
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(store.connected.enumerated()), id: \.element) { index, service in
                if index > 0 { Divider().padding(.horizontal, 16) }
                switch store.states[service] ?? .notConnected {
                case .ok(let snapshot), .failed(_, let snapshot?):
                    StandardSection(snapshot: snapshot, error: store.states[service]?.errorMessage, now: now)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                default:
                    ServiceStatusRow(service: service, state: store.states[service] ?? .notConnected, actions: actions)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 6)
                }
            }
        }
        .padding(.bottom, 2)
    }
}

struct StandardSection: View {
    let snapshot: ServiceSnapshot
    let error: String?
    let now: Date

    var body: some View {
        let service = snapshot.service
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(Color(nsColor: service.color)).frame(width: 8, height: 8)
                Text(service.name).font(.system(size: 13, weight: .semibold))
                if let plan = snapshot.plan {
                    Text(plan)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.07)))
                }
            }
            ForEach(snapshot.limits) { limit in
                if let percent = limit.percent {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(limit.title)
                            Spacer()
                            Text(limit.displayValue)
                                .fontWeight(.semibold)
                                .foregroundStyle(Color(nsColor: Palette.text(for: limit.level)))
                        }
                        .font(.system(size: 12))
                        UsageBar(percent: percent, color: Color(nsColor: Palette.fill(service, limit.level)), height: 5)
                        let detail = [limit.note, Format.resetText(limit.resetsAt, now: now)]
                            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                        if !detail.isEmpty {
                            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    HStack {
                        Text(limit.title)
                        Spacer()
                        Text(limit.displayValue).fontWeight(.semibold)
                    }
                    .font(.system(size: 12))
                }
            }
            if let error = error {
                Text("\(error) · showing last numbers")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: Palette.warningText))
            }
        }
        .monospacedDigit()
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Shared pieces

/// A connected service without numbers: loading, signed out or failing.
struct ServiceStatusRow: View {
    let service: ServiceID
    let state: ServiceState
    let actions: PopoverActions

    var body: some View {
        HStack(spacing: 9) {
            Circle()
                .strokeBorder(Color(nsColor: service.color), lineWidth: 1.5)
                .frame(width: 8, height: 8)
                .padding(.horizontal, 9)
            VStack(alignment: .leading, spacing: 1) {
                Text(service.name).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            switch state {
            case .signedOut:
                Button("Sign in…") { actions.signIn(service) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            case .loading:
                ProgressView().controlSize(.small)
            default:
                EmptyView()
            }
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 8)
    }

    private var detail: String {
        switch state {
        case .loading: return "Loading…"
        case .signedOut(let reason): return reason ?? "Signed out"
        case .failed(let message, _): return message
        case .notConnected: return "Not connected"
        case .ok: return ""
        }
    }
}

struct EmptyServicesView: View {
    let actions: PopoverActions

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Connect a service").font(.system(size: 13, weight: .semibold))
            Text("Sign in to see your usage limits. Everything stays on this Mac.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                ForEach(ServiceID.allCases) { service in
                    Button(service.name) { actions.signIn(service) }
                        .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }
}

struct Ring: View {
    let percent: Double
    let color: Color

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.1), lineWidth: 3)
            Circle()
                .trim(from: 0, to: CGFloat(min(max(percent, 0), 100) / 100))
                .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(1.5)
    }
}

struct UsageBar: View {
    let percent: Double
    let color: Color
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                if percent > 0 {
                    Capsule()
                        .fill(color)
                        .frame(width: max(height, geo.size.width * CGFloat(min(percent, 100)) / 100))
                }
            }
        }
        .frame(height: height)
    }
}

struct TextButton: View {
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12))
                .padding(.horizontal, 9)
                .frame(height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(HoverButtonStyle())
    }
}

struct HoverButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverBody(configuration: configuration)
    }

    private struct HoverBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(hovering || configuration.isPressed ? Color.primary.opacity(0.08) : Color.clear)
                )
                .onHover { hovering = $0 }
        }
    }
}

/// The blurred background with rounded corners.
struct PanelBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .menu

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        view.maskImage = Icons.roundedMask(radius: 12)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
