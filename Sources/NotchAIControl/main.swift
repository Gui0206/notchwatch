import SwiftUI
import AppKit
import Combine
import ServiceManagement

// MARK: - Passthrough hosting view
//
// The window spans a large area at the top-center of the screen, but only the
// pill (collapsed) or the panel (expanded) should be interactive. Everywhere
// else, clicks must fall through to whatever is behind (menu bar, desktop, apps).

final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    /// Interactive rect in this view's coordinate space (origin bottom-left).
    var interactiveRect: CGRect = .zero

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard interactiveRect.contains(point) else { return nil }
        return super.hitTest(point)
    }
}

// MARK: - Controller

@MainActor
final class NotchController: NSObject, NSApplicationDelegate {
    private var panel: NSPanel!
    private var hostingView: PassthroughHostingView<AnyView>!
    private let store = SessionStore()

    private let ui = NotchUIState()
    private var expanded: Bool { ui.expanded }
    private var metrics = NotchMetrics(notchWidth: 200, notchHeight: 32)
    private var screen: NSScreen = .main ?? NSScreen.screens.first!
    private var measuredPanelHeight: CGFloat = 240

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var statusItem: NSStatusItem?

    private let windowExtraWidth: CGFloat = 48      // shadow breathing room
    private let expandedWindowHeight: CGFloat = 480 // generous; panel anchors at top
    private var collapseToken = 0                    // guards the delayed shrink

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        chooseScreen()
        metrics = NotchMetrics.detect(screen)
        buildPanel()
        buildStatusItem()
        installMouseMonitors()
        observeScreenChanges()
        render()
    }

    // MARK: Screen

    private func chooseScreen() {
        // Prefer a screen that actually has a notch.
        screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
            ?? NSScreen.main ?? NSScreen.screens.first!
    }

    // Collapsed: the window covers ONLY the hardware notch (no clickable menu-bar
    // items live there), so the menu bar on both sides stays fully usable.
    private func collapsedWindowFrame() -> NSRect {
        let f = screen.frame
        let w = metrics.notchWidth
        let h = metrics.notchHeight
        let x = f.minX + (f.width - w) / 2
        let y = f.maxY - h
        return NSRect(x: x, y: y, width: w, height: h)
    }

    // Expanded: a large window holding the panel, shown only while hovering.
    private func expandedWindowFrame() -> NSRect {
        let f = screen.frame
        let w = metrics.expandedWidth + windowExtraWidth
        let h = expandedWindowHeight
        let x = f.minX + (f.width - w) / 2
        let y = f.maxY - h
        return NSRect(x: x, y: y, width: w, height: h)
    }

    private func currentWindowFrame() -> NSRect {
        expanded ? expandedWindowFrame() : collapsedWindowFrame()
    }

    // MARK: Panel

    private func buildPanel() {
        let frame = collapsedWindowFrame()
        panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .init(rawValue: Int(CGWindowLevelForKey(.maximumWindow)) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.ignoresMouseEvents = false

        hostingView = PassthroughHostingView(rootView: makeRoot())
        hostingView.frame = NSRect(origin: .zero, size: frame.size)
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView
        updateInteractiveRect()
        panel.orderFrontRegardless()

        // Re-render whenever sessions change.
        storeObservation = store.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.afterStoreChange() }
        }
    }

    private var storeObservation: AnyCancellable?

    private func afterStoreChange() {
        // If everything finished and the user isn't looking, keep the pill calm.
        updateInteractiveRect()
    }

    // MARK: Rendering

    private func render() {
        // SwiftUI re-renders via @ObservedObject/@Binding automatically;
        // this just keeps the interactive rect in sync.
        updateInteractiveRect()
    }

    private func setExpanded(_ value: Bool) {
        guard ui.expanded != value else { return }
        collapseToken &+= 1

        if value {
            // Grow the window first so there's room, then let SwiftUI animate the
            // panel unfurling into it. The view tree is never rebuilt, so the
            // transition always plays — even on rapid edge hovers.
            let f = expandedWindowFrame()
            panel.setFrame(f, display: true)
            hostingView.frame = NSRect(origin: .zero, size: f.size)
            ui.expanded = true
            updateInteractiveRect()
        } else {
            // Animate the panel closing, then shrink the window back (after the
            // animation) so it stops covering the menu bar.
            ui.expanded = false
            updateInteractiveRect()
            let token = collapseToken
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, self.collapseToken == token, !self.ui.expanded else { return }
                let f = self.collapsedWindowFrame()
                self.panel.setFrame(f, display: true)
                self.hostingView.frame = NSRect(origin: .zero, size: f.size)
                self.updateInteractiveRect()
            }
        }
    }

    private func makeRoot() -> AnyView {
        AnyView(
            NotchView(
                store: store,
                ui: ui,
                metrics: metrics,
                onClose: { [weak self] in self?.setExpanded(false) },
                onActivate: { [weak self] session in
                    Focuser.focus(session)
                    self?.setExpanded(false)
                },
                onPanelHeight: { [weak self] h in
                    guard let self else { return }
                    if abs(self.measuredPanelHeight - h) > 0.5 {
                        self.measuredPanelHeight = h
                        self.updateInteractiveRect()
                    }
                }
            )
            .environmentObject(store)
        )
    }

    /// Keep the interactive (and hover) rect aligned with what's visible.
    private func updateInteractiveRect() {
        let w = hostingView.bounds.width
        let h = hostingView.bounds.height
        if expanded {
            let rectW = metrics.expandedWidth + 16
            let rectH = max(measuredPanelHeight, 120)
            interactiveRect = CGRect(x: (w - rectW) / 2, y: h - rectH, width: rectW, height: rectH)
        } else {
            // Only the notch is interactive; everything else passes through.
            let rectW = metrics.notchWidth
            let rectH = metrics.notchHeight
            interactiveRect = CGRect(x: (w - rectW) / 2, y: h - rectH, width: rectW, height: rectH)
        }
        hostingView.interactiveRect = interactiveRect
    }

    private var interactiveRect: CGRect = .zero

    // MARK: Hover monitors

    private func installMouseMonitors() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            Task { @MainActor in self?.evaluateHover() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] e in
            Task { @MainActor in self?.evaluateHover() }
            return e
        }
    }

    /// Screen-space rect (bottom-left origin) used to decide expand/collapse.
    private func hoverRect() -> CGRect {
        let f = screen.frame
        if expanded {
            let rectW = metrics.expandedWidth + 16
            let rectH = max(measuredPanelHeight, 120)
            let x = f.minX + (f.width - rectW) / 2
            let y = f.maxY - rectH
            // Pad so the pointer can travel to buttons without collapsing.
            return CGRect(x: x - 8, y: y - 10, width: rectW + 16, height: rectH + 10)
        } else {
            // The notch, padded slightly below so it's easy to "drop onto".
            let rectW = metrics.notchWidth + 8
            let rectH = metrics.notchHeight + 6
            let x = f.minX + (f.width - rectW) / 2
            let y = f.maxY - rectH
            return CGRect(x: x, y: y, width: rectW, height: rectH)
        }
    }

    private func evaluateHover() {
        let loc = NSEvent.mouseLocation
        let inside = hoverRect().contains(loc)
        if inside && !expanded {
            setExpanded(true)
        } else if !inside && expanded {
            setExpanded(false)
        }
    }

    // MARK: Status bar item

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "AI Control")
        let menu = NSMenu()
        menu.addItem(withTitle: "Notch AI Control", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        let toggle = NSMenuItem(title: "Show Panel", action: #selector(toggleFromMenu), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        let clear = NSMenuItem(title: "Clear Finished", action: #selector(clearFinished), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
        menu.addItem(.separator())
        let sound = NSMenuItem(title: "Play Sounds", action: #selector(toggleSound), keyEquivalent: "")
        sound.target = self
        sound.state = NotchSound.enabled ? .on : .off
        menu.addItem(sound)
        let login = NSMenuItem(title: "Start at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
    }

    @objc private func toggleFromMenu() { setExpanded(!expanded) }
    @objc private func clearFinished() { store.clearFinished() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func toggleSound(_ sender: NSMenuItem) {
        NotchSound.enabled.toggle()
        sender.state = NotchSound.enabled ? .on : .off
        if NotchSound.enabled { NotchSound.finished() }   // preview the chime
    }

    @objc private func toggleLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                sender.state = .off
            } else {
                try SMAppService.mainApp.register()
                sender.state = .on
            }
        } catch {
            NSSound.beep()
        }
    }

    // MARK: Screen change handling

    private func observeScreenChanges() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.relayout() }
        }
    }

    private func relayout() {
        chooseScreen()
        metrics = NotchMetrics.detect(screen)
        let f = currentWindowFrame()
        panel.setFrame(f, display: true)
        hostingView.frame = NSRect(origin: .zero, size: f.size)
        hostingView.rootView = makeRoot()
        updateInteractiveRect()
    }
}

// MARK: - Entry point

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let controller = NotchController()
    app.delegate = controller
    app.run()
}
