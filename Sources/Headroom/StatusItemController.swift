import AppKit
import Combine
import SwiftUI

// MARK: - What the menu bar shows

struct LabelContent {
    let image: NSImage
    let title: NSAttributedString
    let tooltip: String

    @MainActor
    static func make(store: UsageStore, settings: AppSettings, now: Date = Date()) -> LabelContent {
        let bold = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        let regular = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        func text(_ string: String, _ color: NSColor = .labelColor, _ font: NSFont? = nil) -> NSAttributedString {
            NSAttributedString(string: string, attributes: [.font: font ?? bold, .foregroundColor: color])
        }

        let snapshots = store.connected.compactMap { store.states[$0]?.snapshot }
        let tooltip = Self.tooltip(store: store, now: now)

        // Nothing to show yet.
        guard !snapshots.isEmpty else {
            let anyLoading = store.connected.contains { store.states[$0] == .loading }
            return LabelContent(
                image: Icons.dashedRing(color: .secondaryLabelColor),
                title: text(" —", .secondaryLabelColor),
                tooltip: store.connected.isEmpty
                    ? "Headroom: no services connected"
                    : (anyLoading ? "Headroom: loading…" : tooltip)
            )
        }

        switch settings.labelStyle {
        case .everyService:
            let image = Icons.dot(.clear)
            let title = NSMutableAttributedString()
            for (index, snapshot) in snapshots.enumerated() {
                let attachment = NSTextAttachment()
                attachment.image = Icons.dot(snapshot.service.color)
                attachment.bounds = CGRect(x: 0, y: 1, width: 7, height: 7)
                if index > 0 { title.append(text("  ")) }
                title.append(NSAttributedString(attachment: attachment))
                let percent = snapshot.tightest?.percent ?? 0
                title.append(text(" \(Int(percent.rounded()))", Palette.text(for: UsageLevel(percent: percent))))
            }
            return LabelContent(image: image, title: title, tooltip: tooltip)

        case .pinned:
            let snapshot = snapshots.first { $0.service == settings.pinnedService } ?? snapshots[0]
            guard let limit = snapshot.tightest ?? snapshot.primary else { break }
            if limit.isExhausted {
                return exhausted(snapshot, limit, text: text, now: now, tooltip: tooltip)
            }
            let percent = limit.percent ?? 0
            let title = NSMutableAttributedString()
            title.append(text(" " + snapshot.service.name, .labelColor, regular))
            title.append(text(" " + Format.percent(percent), Palette.text(for: limit.level)))
            return LabelContent(
                image: Icons.rings([(percent, Palette.fill(snapshot.service, limit.level))]),
                title: title, tooltip: tooltip)

        case .rings:
            break
        }

        // Rings + closest limit (default).
        guard let pair = store.closest else {
            return LabelContent(image: Icons.dashedRing(color: .secondaryLabelColor),
                                title: text(" —", .secondaryLabelColor), tooltip: tooltip)
        }
        let (closestSnapshot, closest) = pair
        if closest.isExhausted {
            return exhausted(closestSnapshot, closest, text: text, now: now, tooltip: tooltip)
        }
        let rings = snapshots.map { snapshot -> (Double, NSColor) in
            let limit = snapshot.tightest
            return (limit?.percent ?? 0, Palette.fill(snapshot.service, limit?.level ?? .normal))
        }
        let percent = closest.percent ?? 0
        let title = NSMutableAttributedString()
        if closest.level != .normal && snapshots.count > 1 {
            title.append(text(" " + closestSnapshot.service.name, Palette.text(for: closest.level), regular))
        }
        title.append(text(" " + Format.percent(percent), Palette.text(for: closest.level)))
        return LabelContent(image: Icons.rings(rings), title: title, tooltip: tooltip)
    }

    private static func exhausted(_ snapshot: ServiceSnapshot, _ limit: UsageLimit,
                                  text: (String, NSColor, NSFont?) -> NSAttributedString,
                                  now: Date, tooltip: String) -> LabelContent {
        let countdown = limit.resetsAt.map { Format.duration($0.timeIntervalSince(now)) } ?? "Limit"
        return LabelContent(
            image: Icons.clock(color: Palette.critical),
            title: text(" " + countdown, Palette.critical, nil),
            tooltip: tooltip)
    }

    @MainActor
    private static func tooltip(store: UsageStore, now: Date) -> String {
        var lines: [String] = []
        for service in store.connected {
            switch store.states[service] {
            case .ok(let snapshot), .failed(_, let snapshot?):
                if let limit = snapshot.primary {
                    let reset = Format.resetText(limit.resetsAt, now: now)
                    lines.append("\(service.name) · \(limit.shortTitle) \(limit.displayValue)" + (reset.isEmpty ? "" : " · \(reset)"))
                }
            case .signedOut:
                lines.append("\(service.name) · signed out")
            case .failed(let message, .none):
                lines.append("\(service.name) · \(message)")
            default:
                lines.append("\(service.name) · loading…")
            }
        }
        return lines.isEmpty ? "Headroom" : lines.joined(separator: "\n")
    }
}

// MARK: - Panels

/// A borderless floating panel that can take keyboard focus without
/// activating the app (so Esc and Return work).
class FloatingPanel: NSPanel {
    var onDismiss: (() -> Void)?
    var onReturn: (() -> Void)?

    init(width: CGFloat) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 300),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onDismiss?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76, let onReturn = onReturn { // Return, Enter
            onReturn()
        } else {
            super.keyDown(with: event)
        }
    }

    override func resignKey() {
        super.resignKey()
        onDismiss?()
    }
}

// MARK: - Controller

@MainActor
final class StatusItemController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let store: UsageStore
    private let settings: AppSettings
    private let dropdown = FloatingPanel(width: 340)
    private let peek = FloatingPanel(width: 440)
    private var dropdownHost: NSHostingView<PopoverView>!
    private var peekHost: NSHostingView<PeekView>!
    private var cancellables = Set<AnyCancellable>()
    private var appearanceObservation: NSKeyValueObservation?
    private var tickTimer: Timer?
    private var outsideClickMonitor: Any?
    private var lastHidden = Date.distantPast
    private var shortcutPressedAt: Date?
    private var peekWasOpenOnPress = false

    init(store: UsageStore, settings: AppSettings, actions: PopoverActions) {
        self.store = store
        self.settings = settings
        super.init()

        let wrapped = PopoverActions(
            openUsagePage: { [weak self] service in self?.hideAll(); actions.openUsagePage(service) },
            openSettings: { [weak self] in self?.hideAll(); actions.openSettings() },
            openHistory: { [weak self] in self?.hideAll(); actions.openHistory() },
            signIn: { [weak self] service in self?.hideAll(); actions.signIn(service) },
            quit: actions.quit
        )
        dropdownHost = NSHostingView(rootView: PopoverView(store: store, settings: settings, actions: wrapped))
        dropdownHost.sizingOptions = []
        dropdown.contentView = dropdownHost
        dropdown.onDismiss = { [weak self] in self?.hideDropdown() }

        peekHost = NSHostingView(rootView: PeekView(store: store))
        peekHost.sizingOptions = []
        peek.contentView = peekHost
        peek.onDismiss = { [weak self] in self?.hidePeek() }
        peek.onReturn = { [weak self] in
            self?.hidePeek()
            self?.showDropdown()
        }

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(toggleDropdown(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
            appearanceObservation = button.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.render() }
            }
        }

        store.objectWillChange
            .merge(with: settings.objectWillChange)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.render()
                    self?.resizeVisiblePanels()
                }
            }
            .store(in: &cancellables)

        tickTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.render() }
        }
        render()
    }

    func render() {
        guard let button = statusItem.button else { return }
        let content = LabelContent.make(store: store, settings: settings)
        button.image = content.image
        button.attributedTitle = content.title
        let hasImage = settings.labelStyle != .everyService || store.connected.allSatisfy { store.states[$0]?.snapshot == nil }
        button.imagePosition = content.title.length == 0 ? .imageOnly : (hasImage ? .imageLeading : .noImage)
        button.toolTip = content.tooltip
        button.setAccessibilityLabel(content.tooltip)
    }

    // MARK: Shortcut

    func shortcutPressed() {
        shortcutPressedAt = Date()
        switch settings.shortcutAction {
        case .dropdown:
            if dropdown.isVisible {
                hideDropdown()
            } else if isStatusItemOnScreen {
                showDropdown()
            } else {
                // Hidden by Hidden Bar or the notch: open it under the menu bar instead.
                showDropdown(fallback: true)
            }
        case .peek:
            peekWasOpenOnPress = peek.isVisible
            if peek.isVisible {
                hidePeek()
            } else {
                showPeek()
            }
        }
    }

    func shortcutReleased() {
        defer { shortcutPressedAt = nil }
        guard settings.shortcutAction == .peek, settings.holdToPeek,
              !peekWasOpenOnPress, peek.isVisible,
              let pressed = shortcutPressedAt else { return }
        // A quick tap keeps the peek open; holding it shows it only while held.
        if Date().timeIntervalSince(pressed) > 0.35 {
            hidePeek()
        }
    }

    // MARK: Dropdown

    @objc private func toggleDropdown(_ sender: Any?) {
        if dropdown.isVisible {
            hideDropdown()
            return
        }
        if Date().timeIntervalSince(lastHidden) < 0.3 { return }
        showDropdown()
    }

    private var isStatusItemOnScreen: Bool {
        guard let window = statusItem.button?.window, window.isVisible else { return false }
        return NSScreen.screens.contains { $0.frame.intersects(window.frame) }
            && window.occlusionState.contains(.visible)
    }

    private func showDropdown(fallback: Bool = false) {
        hidePeek()
        store.refreshIfStale()
        let size = measure(dropdownHost, width: 340)
        let anchor: NSRect
        if !fallback, let frame = statusItem.button?.window?.frame {
            anchor = frame
        } else {
            let screen = screenWithMouse
            let top = screen.frame.maxY - (screen.frame.maxY - screen.visibleFrame.maxY)
            anchor = NSRect(x: screen.visibleFrame.maxX - 200, y: top, width: 40, height: 0)
        }
        var x = anchor.midX - size.width / 2
        let visible = (statusItem.button?.window?.screen ?? screenWithMouse).visibleFrame
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        dropdown.setFrame(NSRect(x: x, y: anchor.minY - size.height - 4, width: size.width, height: size.height),
                          display: true)
        dropdown.invalidateShadow()
        dropdown.makeKeyAndOrderFront(nil)
        statusItem.button?.highlight(true)
        installOutsideClickMonitor()
    }

    private func hideDropdown() {
        guard dropdown.isVisible else { return }
        dropdown.orderOut(nil)
        lastHidden = Date()
        statusItem.button?.highlight(false)
        removeOutsideClickMonitorIfIdle()
    }

    // MARK: Peek

    private func showPeek() {
        hideDropdown()
        store.refreshIfStale()
        let size = measure(peekHost, width: 440)
        let screen = screenWithMouse
        let x = screen.frame.midX - size.width / 2
        let y = screen.visibleFrame.maxY - size.height - 28
        peek.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        peek.invalidateShadow()
        peek.makeKeyAndOrderFront(nil)
        installOutsideClickMonitor()
    }

    private func hidePeek() {
        guard peek.isVisible else { return }
        peek.orderOut(nil)
        removeOutsideClickMonitorIfIdle()
    }

    func hideAll() {
        hideDropdown()
        hidePeek()
    }

    // MARK: Helpers

    private var screenWithMouse: NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func measure<V: View>(_ host: NSHostingView<V>, width: CGFloat) -> NSSize {
        let fitted = NSHostingController(rootView: host.rootView)
            .sizeThatFits(in: NSSize(width: width, height: 10_000))
        return NSSize(width: width, height: ceil(fitted.height))
    }

    private func resizeVisiblePanels() {
        if dropdown.isVisible {
            let size = measure(dropdownHost, width: 340)
            var frame = dropdown.frame
            frame.origin.y += frame.height - size.height
            frame.size.height = size.height
            dropdown.setFrame(frame, display: true)
        }
        if peek.isVisible {
            let size = measure(peekHost, width: 440)
            var frame = peek.frame
            frame.origin.y += frame.height - size.height
            frame.size.height = size.height
            peek.setFrame(frame, display: true)
        }
    }

    private func installOutsideClickMonitor() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.hideAll() }
        }
    }

    private func removeOutsideClickMonitorIfIdle() {
        guard !dropdown.isVisible, !peek.isVisible, let monitor = outsideClickMonitor else { return }
        NSEvent.removeMonitor(monitor)
        outsideClickMonitor = nil
    }
}
