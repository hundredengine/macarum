import AppKit
import MacarumCore
import Observation
import SwiftUI

/// What the welcome window shows right now.
@MainActor @Observable
final class WelcomeModel {
    var flow: WelcomeFlow

    init(flow: WelcomeFlow) {
        self.flow = flow
    }
}

/// The first-run window: what Macarum is, where it lives, and why macOS is about to ask for
/// Accessibility. Laid out on one text edge: the app icon and the row symbols share the left
/// column, every line of text starts at the same x.
struct WelcomeView: View {
    let model: WelcomeModel
    let icon: NSImage
    let allow: () -> Void
    let openSystemSettings: () -> Void
    let close: () -> Void

    private static let symbolColumn: CGFloat = 56
    private static let columnGap: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            VStack(alignment: .leading, spacing: 14) {
                row(title: "Find it in the menu bar",
                    detail: "Click the macaron at the top right. There is no Dock icon.") {
                    Image(nsImage: MenuBarIcon.image)
                        .resizable()
                        .frame(width: 24, height: 24)
                }
                row(symbol: "clipboard",
                    title: "Clipboard history",
                    detail: "Press ⌘ three times to see what you copied and paste it again.")
                row(symbol: "memorychip",
                    title: "Memory check",
                    detail: "See what is holding memory, and quit or relaunch it.")
                row(symbol: "arrow.down.document",
                    title: "File converter",
                    detail: "Drop images, PDFs, video or sound on the macaron to convert.")
            }
            .padding(.top, 24)

            Divider()
                .padding(.leading, Self.symbolColumn + Self.columnGap)
                .padding(.vertical, 20)

            row(symbol: "accessibility", title: "One permission: Accessibility") {
                Text(model.flow.step == .granted
                    ? "Pressing ⌘ three times and pasting for you both use it. You can switch it off in System Settings at any time."
                    : "Pressing ⌘ three times and pasting for you both need it. macOS will ask in its own, rather stern words.")
                Text("Macarum watches keys like ⌘, notices that you typed or clicked (never what), and presses ⌘V for you. Nothing leaves this Mac.")
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
            }

            footer
                .padding(.top, 20)
        }
        .padding(.horizontal, 28)
        .padding(.top, 8)
        .padding(.bottom, 24)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var header: some View {
        HStack(spacing: Self.columnGap) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: Self.symbolColumn, height: Self.symbolColumn)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Welcome to Macarum")
                    .font(.system(size: 22, weight: .bold))
                Text("Three small tools that live in your menu bar.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func row(symbol: String, title: String, detail: String) -> some View {
        row(symbol: symbol, title: title) { Text(detail).foregroundStyle(.secondary) }
    }

    private func row(symbol: String, title: String, @ViewBuilder text: () -> some View) -> some View {
        row(title: title, text: text) {
            Image(systemName: symbol).font(.system(size: 22, weight: .medium))
        }
    }

    private func row(title: String, detail: String, @ViewBuilder mark: () -> some View) -> some View {
        row(title: title, text: { Text(detail).foregroundStyle(.secondary) }, mark: mark)
    }

    /// The mark sits in the icon's column, centred on the title and the first line under it.
    private func row(title: String, @ViewBuilder text: () -> some View, @ViewBuilder mark: () -> some View) -> some View {
        HStack(alignment: .top, spacing: Self.columnGap) {
            mark()
                .foregroundStyle(.tint)
                .frame(width: Self.symbolColumn, height: 34)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                text().fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The live state on one line, the buttons under it at the right. Same height in every
    /// state so the window never changes size.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 14) {
            state
                .font(.callout)
                .lineLimit(1)
                .frame(height: 16)
                .padding(.leading, Self.symbolColumn + Self.columnGap)
            HStack(spacing: 10) {
                Spacer()
                switch model.flow.step {
                case .explaining:
                    Button("Not Now", action: close).keyboardShortcut(.cancelAction)
                    Button("Allow Accessibility…", action: allow).keyboardShortcut(.defaultAction)
                case .waiting:
                    Button("Not Now", action: close).keyboardShortcut(.cancelAction)
                    Button("Open System Settings", action: openSystemSettings).keyboardShortcut(.defaultAction)
                case .granted:
                    Button("Done", action: close).keyboardShortcut(.defaultAction)
                }
            }
            .controlSize(.large)
        }
    }

    @ViewBuilder private var state: some View {
        switch model.flow.step {
        case .explaining:
            Text("Not now is fine: Macarum still works from its menu bar icon.")
                .foregroundStyle(.secondary)
        case .waiting:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Waiting for you to switch Macarum on in System Settings…")
                    .foregroundStyle(.secondary)
            }
        case .granted:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.green)
                Text("Accessibility is on. Press ⌘ three times to try it.")
            }
        }
    }
}

/// Owns the welcome window. While it is open, the permission is checked once a second so the
/// window can show it arriving; the check stops when the window closes.
@MainActor
final class WelcomeWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var timer: Timer?
    private let model = WelcomeModel(flow: WelcomeFlow(granted: false))
    private let icon: NSImage
    private let isGranted: () -> Bool
    private let requestAccess: () -> Void
    private let openSystemSettings: () -> Void
    private let permissionChanged: () -> Void

    /// `requestAccess` brings up the macOS prompt and the Accessibility pane,
    /// `openSystemSettings` only the pane (for someone who lost it while waiting);
    /// `permissionChanged` runs when the window sees the permission arrive or go.
    init(icon: NSImage, isGranted: @escaping () -> Bool, requestAccess: @escaping () -> Void,
         openSystemSettings: @escaping () -> Void, permissionChanged: @escaping () -> Void = {}) {
        self.openSystemSettings = openSystemSettings
        self.icon = icon
        self.isGranted = isGranted
        self.requestAccess = requestAccess
        self.permissionChanged = permissionChanged
    }

    var isVisible: Bool { window?.isVisible ?? false }
    /// For `screencapture -l` in preview runs.
    var windowNumber: Int? { window?.windowNumber }

    /// `waiting` starts in the state after the button was pressed (for screenshots).
    func show(waiting: Bool = false) {
        if !isVisible {
            model.flow = WelcomeFlow(granted: isGranted())
            if waiting { model.flow.askedForPermission() }
        }
        if window == nil { window = makeWindow() }
        startChecking()
        window?.center()
        // Macarum has no Dock icon, so nothing brings its windows forward unless it asks.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let view = WelcomeView(
            model: model, icon: icon,
            allow: { [weak self] in self?.allow() },
            openSystemSettings: { [weak self] in self?.openSystemSettings() },
            close: { [weak self] in self?.window?.close() })
        let controller = NSHostingController(rootView: view)
        controller.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: controller)
        window.title = "Welcome to Macarum"
        // Like the system's own welcome sheets: no title, content up to the top edge.
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(controller.view.fittingSize)
        return window
    }

    private func allow() {
        model.flow.askedForPermission()
        requestAccess()
    }

    private func startChecking() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        timer?.tolerance = 0.2
    }

    private func check() {
        let before = model.flow.step
        model.flow.permissionChecked(granted: isGranted())
        guard model.flow.step != before else { return }
        permissionChanged()
        // The person is in System Settings when the switch goes on; come back to the front
        // so the result is seen.
        if model.flow.step == .granted {
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
        }
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
    }
}
