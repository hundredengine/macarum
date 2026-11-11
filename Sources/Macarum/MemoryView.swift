import AppKit
import MacarumCore
import SwiftUI

/// What the menu bar icon opens: memory at a glance, the apps holding the most of it, and
/// the app's own commands below.
struct MemoryView: View {
    let model: MemoryModel
    let converter: ConverterModel
    let preferences: Preferences
    let showHistory: () -> Void
    let showSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ConverterView(model: converter, preferences: preferences)
            Divider()
            summary
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 12)
            Divider()
            appList
                .padding(.vertical, 6)
            freeCacheButton
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            Divider()
            VStack(spacing: 0) {
                CommandRow(title: "Clipboard History",
                           hint: preferences.usesTripleCommand ? "⌘⌘⌘" : preferences.activeShortcut?.display,
                           action: showHistory)
                CommandRow(title: preferences.isPaused ? "Resume History" : "Pause History") {
                    preferences.isPaused.toggle()
                }
                CommandRow(title: "Settings…", hint: "⌘,", action: showSettings)
                CommandRow(title: "Quit Macarum") { NSApp.terminate(nil) }
            }
            .padding(.vertical, 5)
        }
        .frame(width: 340)
        // The whole panel takes a drop, not only the zone, so files are easy to land.
        .dropDestination(for: URL.self) { urls, _ in
            converter.noteDrop()
            converter.pick(urls)
            return !urls.isEmpty
        } isTargeted: { converter.isDropTargeted = $0 }
    }

    // MARK: Summary

    private var summary: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Memory").font(.system(size: 13, weight: .semibold))
                Spacer()
                PressureBadge(pressure: model.pressure)
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Swap used")
                    Spacer()
                    Text(swapText).monospacedDigit()
                }
                .font(.system(size: 12))
                SwapBar(used: model.swap.used, total: model.swap.total, pressure: model.pressure)
            }
            Text("Swap fills up with memory that apps hold but are not using. Quit or relaunch the ones at the top to get it back.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var swapText: String {
        guard model.swap.total > 0 else { return "None" }
        return memoryText(model.swap.used) + " of " + memoryText(model.swap.total)
    }

    // MARK: Apps

    @ViewBuilder
    private var appList: some View {
        if model.rows.isEmpty {
            HStack {
                Spacer()
                ProgressView().controlSize(.small)
                Spacer()
            }
            .frame(height: CGFloat(MemoryModel.rowCount) * 38 + 20)
        } else {
            VStack(spacing: 0) {
                HStack {
                    Text("Holding memory it isn't using")
                    Spacer()
                    Text("Out of RAM")
                        .help("Memory macOS moved out of RAM, compressed or into swap, because the app was not using it.")
                }
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
                ForEach(model.rows) { row in
                    AppRow(row: row,
                           isRelaunching: row.app.map { model.relaunching.contains($0.processIdentifier) } ?? false,
                           relaunch: { if let app = row.app { model.relaunch(app) } },
                           quit: {
                               if let app = row.app { model.quit(app) } else if let pid = row.usage.pid { model.stop(pid) }
                           })
                }
            }
        }
    }

    private var freeCacheButton: some View {
        Button {
            model.freeCachedMemory()
        } label: {
            HStack(spacing: 6) {
                if model.isFreeingCache { ProgressView().controlSize(.mini) }
                Text(model.isFreeingCache ? "Freeing Cached Memory…" : "Free Cached Memory…")
            }
            .frame(maxWidth: .infinity)
        }
        .controlSize(.regular)
        .disabled(model.isFreeingCache)
        .help("Drops cached files from memory (macOS's purge). Asks for your Mac's password.")
    }
}

/// "9.5 GB" or "430 MB": one decimal for gigabytes, none for megabytes, so columns line up.
func memoryText(_ bytes: UInt64) -> String {
    let gb = Double(bytes) / 1_073_741_824
    if gb >= 1 { return gb.formatted(.number.precision(.fractionLength(1))) + " GB" }
    return (Double(bytes) / 1_048_576).formatted(.number.precision(.fractionLength(0))) + " MB"
}

private struct PressureBadge: View {
    let pressure: MemoryPressure

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(.system(size: 11, weight: .medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.14), in: Capsule())
        .help("Memory pressure: how hard macOS is working to find free memory.")
    }

    private var label: String {
        switch pressure {
        case .normal: "Pressure normal"
        case .warning: "Pressure high"
        case .critical: "Pressure critical"
        }
    }

    private var color: Color { pressure.color }
}

extension MemoryPressure {
    var color: Color {
        switch self {
        case .normal: .green
        case .warning: .orange
        case .critical: .red
        }
    }
}

private struct SwapBar: View {
    let used: UInt64
    let total: UInt64
    let pressure: MemoryPressure

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(pressure.color.opacity(0.85))
                    .frame(width: total > 0 ? max(4, geo.size.width * CGFloat(Double(used) / Double(total))) : 0)
            }
        }
        .frame(height: 6)
    }
}

private struct AppRow: View {
    let row: MemoryRow
    let isRelaunching: Bool
    let relaunch: () -> Void
    let quit: () -> Void
    @State private var hovering = false
    /// Quit, Stop and Relaunch ask first, in the row itself, so a stray click never closes anything.
    @State private var confirming: Action?

    private enum Action { case relaunch, quit }

    /// Apps can quit and relaunch; programs (dev servers, scripts) can only be stopped.
    private var canQuit: Bool { row.app != nil || row.usage.pid != nil }
    private var quitWord: String { row.app != nil ? "Quit" : "Stop" }
    private var title: String { row.usage.detail ?? row.usage.name }

    var body: some View {
        HStack(spacing: 10) {
            icon
            if let confirming {
                Text(confirming == .relaunch ? "Relaunch \(title)?" : "\(quitWord) \(title)?")
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 6)
                Button("Cancel") { self.confirming = nil }
                    .controlSize(.small)
                Button(confirming == .relaunch ? "Relaunch" : quitWord) {
                    self.confirming = nil
                    confirming == .relaunch ? relaunch() : quit()
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .tint(confirming == .quit ? .red : .accentColor)
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12.5))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 5) {
                        if let idle = row.idleSince { IdleBadge(since: idle, startedAt: row.usage.startedAt) }
                        Text(subtitle)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                if isRelaunching {
                    ProgressView().controlSize(.mini)
                } else if hovering, canQuit {
                    if row.app != nil {
                        Button { confirming = .relaunch } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.borderless)
                            .help("Relaunch \(title) to give back its memory")
                    }
                    Button { confirming = .quit } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .help("\(quitWord) \(title)")
                }
                Text(memoryText(row.usage.outOfRAM))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 56, alignment: .trailing)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 38)
        .background(confirming != nil ? Color.accentColor.opacity(0.10) : hovering ? Color.primary.opacity(0.06) : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    /// "8.7 GB total · running 8 days" (or after an idle badge, without the running part), plus what kind of process it is when that is not obvious.
    private var subtitle: String {
        var parts: [String] = []
        if row.app == nil { parts.append(row.usage.isAppBundle ? "Background app" : row.usage.name) }
        parts.append(memoryText(row.usage.bytes) + " total")
        // An idle row shows how long it has been idle instead; its start stays in the badge's tooltip.
        if let started = row.usage.startedAt, row.idleSince == nil { parts.append("running " + ageText(since: started)) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var icon: some View {
        if let image = row.app?.icon ?? (row.usage.isAppBundle ? NSWorkspace.shared.icon(forFile: row.usage.key) : nil) {
            Image(nsImage: image).resizable().frame(width: 20, height: 20)
        } else {
            Image(systemName: "terminal")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
        }
    }
}

/// "12 min", "3 h", "4 days": how long ago a moment was, as short as a row allows.
private func ageText(since date: Date) -> String {
    let seconds = Date().timeIntervalSince(date)
    if seconds < 3600 { return "\(max(1, Int(seconds / 60))) min" }
    if seconds < 86_400 { return "\(Int(seconds / 3600)) h" }
    let days = Int(seconds / 86_400)
    return days == 1 ? "1 day" : "\(days) days"
}

/// "Idle 3 h": a fact about the row, not a warning, so it stays grey and quiet.
private struct IdleBadge: View {
    let since: Date
    let startedAt: Date?

    var body: some View {
        Text("Idle " + ageText(since: since))
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.primary.opacity(0.08), in: Capsule())
            .fixedSize()
            .help(tooltip)
    }

    private var tooltip: String {
        var text = "No real CPU use since \(since.formatted(date: .abbreviated, time: .shortened))."
        if let startedAt { text += " Running \(ageText(since: startedAt))." }
        return text
    }
}

/// A menu-style row: full width, highlighted under the pointer like a real menu item.
private struct CommandRow: View {
    let title: String
    var hint: String? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                if let hint { Text(hint).foregroundStyle(hovering ? Color.white.opacity(0.8) : Color.secondary) }
            }
            .font(.system(size: 13))
            .foregroundStyle(hovering ? Color.white : Color.primary)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background {
                if hovering {
                    RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .onHover { hovering = $0 }
    }
}
