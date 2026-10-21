import AppKit
import SwiftUI

/// Shown on first launch: what Headroom does, and a sign-in button per service.
struct WelcomeView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var settings: AppSettings
    let signIn: (ServiceID) -> Void
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Welcome to Headroom").font(.title2.weight(.semibold))
                    Text("See how much room you have left on your AI subscriptions, right in the menu bar.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 0) {
                Text("Connect your services")
                    .font(.subheadline.weight(.semibold))
                    .padding(.bottom, 8)
                ForEach(Array(ServiceID.allCases.enumerated()), id: \.element) { index, service in
                    if index > 0 { Divider() }
                    ServiceRow(service: service,
                               detail: Self.detail(service),
                               connected: isConnected(service),
                               signIn: { signIn(service) })
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))

            VStack(alignment: .leading, spacing: 6) {
                Tip(symbol: "circle.circle", text: "Click the rings in the menu bar to see every limit.")
                Tip(symbol: "keyboard", text: "Press \(settings.shortcut.display) from any app for a quick peek.")
                Tip(symbol: "lock", text: "Sign-ins stay on this Mac. Passkeys don't work in the sign-in window, so use email sign-in.")
            }

            HStack {
                Spacer()
                Button(settings.connected.isEmpty ? "Later" : "Done", action: done)
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    private func isConnected(_ service: ServiceID) -> Bool {
        guard settings.connected.contains(service) else { return false }
        if case .signedOut = store.states[service] { return false }
        return true
    }

    private static func detail(_ service: ServiceID) -> String {
        switch service {
        case .claude: return "Session, weekly and per-model limits"
        case .chatgpt: return "Codex 5-hour and weekly limits"
        case .cursor: return "Weekly pool or monthly usage"
        }
    }

    private struct ServiceRow: View {
        let service: ServiceID
        let detail: String
        let connected: Bool
        let signIn: () -> Void

        var body: some View {
            HStack(spacing: 10) {
                Circle().fill(Color(nsColor: service.color)).frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 1) {
                    Text(service.name).fontWeight(.semibold)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if connected {
                    Label("Connected", systemImage: "checkmark.circle.fill")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.green)
                        .font(.callout)
                } else {
                    Button("Sign in…", action: signIn)
                }
            }
            .padding(.vertical, 8)
        }
    }

    private struct Tip: View {
        let symbol: String
        let text: String

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 16)
                Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
