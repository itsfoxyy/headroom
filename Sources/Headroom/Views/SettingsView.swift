import ServiceManagement
import SwiftUI

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Headroom: launch at login change failed: \(error.localizedDescription)")
        }
    }
}

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var store: UsageStore
    @ObservedObject var shortcutStatus: ShortcutStatus
    let signIn: (ServiceID) -> Void

    var body: some View {
        TabView {
            GeneralTab(settings: settings)
                .tabItem { Label("General", systemImage: "gearshape") }
            ServicesTab(settings: settings, store: store, signIn: signIn)
                .tabItem { Label("Services", systemImage: "square.stack.3d.up") }
            ShortcutTab(settings: settings, status: shortcutStatus)
                .tabItem { Label("Shortcut", systemImage: "keyboard") }
        }
        .frame(width: 500, height: 470)
    }
}

// MARK: - General

private struct GeneralTab: View {
    @ObservedObject var settings: AppSettings
    @State private var launchAtLogin = LoginItem.isEnabled

    var body: some View {
        Form {
            Section("Dropdown") {
                Picker("Layout", selection: $settings.layout) {
                    ForEach(PopoverLayout.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section("Menu bar") {
                Picker("Label", selection: $settings.labelStyle) {
                    ForEach(LabelStyle.allCases) { Text($0.title).tag($0) }
                }
                if settings.labelStyle == .pinned {
                    Picker("Pinned service", selection: $settings.pinnedService) {
                        ForEach(ServiceID.allCases) { Text($0.name).tag($0) }
                    }
                }
                Picker("Refresh every", selection: $settings.refreshMinutes) {
                    Text("1 minute").tag(1)
                    Text("2 minutes").tag(2)
                    Text("5 minutes").tag(5)
                }
            }
            Section("Alerts") {
                Toggle("Notify when a limit reaches 80% and 95%", isOn: $settings.notificationsEnabled)
            }
            Section("General") {
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { newValue in
                        LoginItem.set(newValue)
                        launchAtLogin = LoginItem.isEnabled
                    }
                ))
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Services

private struct ServicesTab: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var store: UsageStore
    let signIn: (ServiceID) -> Void
    @State private var sessionKey = ""

    var body: some View {
        Form {
            Section {
                ForEach(ServiceID.allCases) { service in
                    HStack(spacing: 10) {
                        Circle().fill(Color(nsColor: service.color)).frame(width: 9, height: 9)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(service.name).fontWeight(.semibold)
                            Text(status(service)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if settings.connected.contains(service) {
                            Button("Sign in again") { signIn(service) }
                            Button("Sign out") { Task { await store.signOut(service) } }
                        } else {
                            Button("Sign in…") { signIn(service) }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding(.vertical, 2)
                }
            } footer: {
                Text("Each service signs in through its own website in a small window. Passkeys may not work there; use email sign-in instead.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Cursor") {
                Picker("Plan type", selection: $settings.cursorPlan) {
                    ForEach(CursorPlanSetting.allCases) { Text($0.title).tag($0) }
                }
            }

            Section("Claude session key (optional)") {
                SecureField("sessionKey cookie from claude.ai", text: $sessionKey)
                HStack {
                    Button("Use this key") {
                        store.setClaudeKey(sessionKey)
                        sessionKey = ""
                    }
                    .disabled(sessionKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if store.claude.usesManualKey {
                        Button("Remove saved key") { store.setClaudeKey(nil) }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func status(_ service: ServiceID) -> String {
        guard settings.connected.contains(service) else { return "Not connected" }
        switch store.states[service] {
        case .ok(let snapshot):
            let names = snapshot.limits.map(\.shortTitle).prefix(3).joined(separator: ", ")
            return ["Signed in", snapshot.plan, names].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        case .signedOut(let reason): return reason ?? "Signed out"
        case .failed(let message, _): return message
        case .loading: return "Checking…"
        default: return "Not connected"
        }
    }
}

// MARK: - Shortcut

final class ShortcutStatus: ObservableObject {
    @Published var problem: String?
}

private struct ShortcutTab: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var status: ShortcutStatus

    var body: some View {
        Form {
            Section {
                Toggle("Global shortcut", isOn: $settings.shortcutEnabled)
                LabeledContent("Open Headroom") {
                    ShortcutRecorder(shortcut: $settings.shortcut)
                        .frame(width: 140, height: 26)
                        .disabled(!settings.shortcutEnabled)
                }
                if let problem = status.problem {
                    Text(problem).font(.footnote).foregroundStyle(.red)
                } else {
                    Text("Works from any app, even when the menu bar icon is hidden.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("When pressed") {
                Picker("When pressed", selection: $settings.shortcutAction) {
                    Text("Open the dropdown under the menu bar icon").tag(ShortcutAction.dropdown)
                    Text("Show a quick peek at the top of the screen").tag(ShortcutAction.peek)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                Toggle("Hold to peek: keep the keys down to look, let go to close", isOn: $settings.holdToPeek)
                    .disabled(settings.shortcutAction != .peek)
            }
        }
        .formStyle(.grouped)
    }
}

/// Click, then press the new shortcut. Esc cancels, Delete clears back to the default.
struct ShortcutRecorder: NSViewRepresentable {
    @Binding var shortcut: Shortcut

    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton()
        button.onChange = { shortcut = $0 }
        button.shortcut = shortcut
        return button
    }

    func updateNSView(_ nsView: RecorderButton, context: Context) {
        nsView.onChange = { shortcut = $0 }
        if !nsView.isRecording { nsView.shortcut = shortcut }
    }
}

final class RecorderButton: NSButton {
    var onChange: ((Shortcut) -> Void)?
    var shortcut: Shortcut = .default { didSet { refresh() } }
    private(set) var isRecording = false
    private var monitor: Any?

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(toggleRecording)
        refresh()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    @objc private func toggleRecording() {
        isRecording ? stop() : start()
    }

    private func start() {
        isRecording = true
        refresh()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            let code = event.keyCode
            if code == 53 { // Esc
                self.stop()
                return nil
            }
            if code == 51 || code == 117 { // Delete: back to the default
                self.shortcut = .default
                self.onChange?(.default)
                self.stop()
                return nil
            }
            let modifiers = CarbonModifiers.from(event.modifierFlags)
            if event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
                NSSound.beep()
                return nil
            }
            let new = Shortcut(keyCode: UInt32(code), modifiers: modifiers)
            self.shortcut = new
            self.onChange?(new)
            self.stop()
            return nil
        }
    }

    private func stop() {
        isRecording = false
        if let monitor = monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        refresh()
    }

    private func refresh() {
        title = isRecording ? "Type a shortcut…" : shortcut.display
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil, isRecording { stop() }
        super.viewWillMove(toWindow: newWindow)
    }
}
