import Carbon.HIToolbox
import Foundation
import MacarumCore
import Observation

/// A global keyboard shortcut in Carbon terms (what RegisterEventHotKey takes).
struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    /// The key as shown to the person, for example "V" or "Space".
    var key: String

    var combo: KeyCombo {
        var m: KeyModifiers = []
        if modifiers & UInt32(cmdKey) != 0 { m.insert(.command) }
        if modifiers & UInt32(optionKey) != 0 { m.insert(.option) }
        if modifiers & UInt32(controlKey) != 0 { m.insert(.control) }
        if modifiers & UInt32(shiftKey) != 0 { m.insert(.shift) }
        return KeyCombo(Int(keyCode), m)
    }

    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + key
    }
}

/// How the history panel opens. One at a time, so there is never a second, forgotten trigger.
enum OpenMethod: String, CaseIterable {
    case tripleCommand
    case shortcut
}

/// Where converted files are saved.
enum ConverterSaveLocation: String, CaseIterable {
    case nextToOriginal
    case folder
}

struct IgnoredApp: Codable, Hashable, Identifiable {
    var bundleID: String
    var name: String
    var id: String { bundleID }
}

/// Settings the person can change, saved in UserDefaults.
@MainActor @Observable
final class Preferences {
    static let shared = Preferences()

    /// A week by default: anything worth keeping longer can be pinned.
    static let defaultRetentionDays = 7
    static let maxRetentionDays = 30
    static let retentionChoices = [1, 7, 14, 30]
    /// Hard ceiling for the history on disk; oldest items go first.
    static let maxStoreBytes = 2 * 1024 * 1024 * 1024

    private let defaults = UserDefaults.standard
    private enum Key {
        static let shortcut = "keyboardShortcut"
        static let openMethod = "openMethod"
        static let askedAccessibility = "askedAccessibility"
        static let retentionDays = "retentionDays"
        static let pasteDirectly = "pasteDirectly"
        static let isPaused = "isPaused"
        static let ignoredApps = "ignoredApps"
        static let converterSaveLocation = "converterSaveLocation"
        static let converterFolder = "converterFolder"
        static let copyConversionResult = "copyConversionResult"
        static let converterQuality = "converterQuality"
        static let svgScale = "svgScale"
    }

    var openMethod: OpenMethod { didSet { defaults.set(openMethod.rawValue, forKey: Key.openMethod) } }
    /// The recorded shortcut, used only when `openMethod` is `.shortcut`.
    var shortcut: Shortcut? { didSet { save(shortcut, Key.shortcut) } }
    var askedAccessibility: Bool { didSet { defaults.set(askedAccessibility, forKey: Key.askedAccessibility) } }
    var retentionDays: Int { didSet { defaults.set(retentionDays, forKey: Key.retentionDays) } }
    var pasteDirectly: Bool { didSet { defaults.set(pasteDirectly, forKey: Key.pasteDirectly) } }
    var isPaused: Bool { didSet { defaults.set(isPaused, forKey: Key.isPaused) } }
    var ignoredApps: [IgnoredApp] { didSet { save(ignoredApps, Key.ignoredApps) } }
    var converterSaveLocation: ConverterSaveLocation { didSet { defaults.set(converterSaveLocation.rawValue, forKey: Key.converterSaveLocation) } }
    /// The chosen folder; Downloads until the person picks another.
    var converterFolder: URL { didSet { defaults.set(converterFolder.path, forKey: Key.converterFolder) } }
    var copyConversionResult: Bool { didSet { defaults.set(copyConversionResult, forKey: Key.copyConversionResult) } }
    var converterQuality: JPEGQuality { didSet { defaults.set(converterQuality.rawValue, forKey: Key.converterQuality) } }
    var svgScale: SVGScale { didSet { defaults.set(svgScale.rawValue, forKey: Key.svgScale) } }

    private init() {
        shortcut = Self.load(Shortcut.self, Key.shortcut, from: defaults)
        openMethod = defaults.string(forKey: Key.openMethod).flatMap(OpenMethod.init(rawValue:)) ?? .tripleCommand
        askedAccessibility = defaults.bool(forKey: Key.askedAccessibility)
        let days = defaults.integer(forKey: Key.retentionDays)
        retentionDays = days == 0 ? Self.defaultRetentionDays : min(days, Self.maxRetentionDays)
        pasteDirectly = defaults.object(forKey: Key.pasteDirectly) as? Bool ?? true
        isPaused = defaults.bool(forKey: Key.isPaused)
        ignoredApps = Self.load([IgnoredApp].self, Key.ignoredApps, from: defaults) ?? []
        converterSaveLocation = defaults.string(forKey: Key.converterSaveLocation).flatMap(ConverterSaveLocation.init(rawValue:)) ?? .nextToOriginal
        converterFolder = defaults.string(forKey: Key.converterFolder).map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        copyConversionResult = defaults.bool(forKey: Key.copyConversionResult)
        converterQuality = defaults.string(forKey: Key.converterQuality).flatMap(JPEGQuality.init(rawValue:)) ?? .default
        svgScale = SVGScale(rawValue: defaults.integer(forKey: Key.svgScale)) ?? .default
    }

    var conversionSettings: ConversionSettings {
        ConversionSettings(quality: converterQuality, svgScale: svgScale,
                           destination: converterSaveLocation == .folder ? .folder(converterFolder) : .nextToOriginal)
    }

    var usesTripleCommand: Bool { openMethod == .tripleCommand }

    /// The shortcut to register right now, if any.
    var activeShortcut: Shortcut? { openMethod == .shortcut ? shortcut : nil }

    /// How to open the history, in words, for hints in the panel and menu.
    var openHint: String {
        if usesTripleCommand { return "pressing ⌘ three times" }
        if let shortcut { return "pressing \(shortcut.display)" }
        return "clicking the menu bar icon"
    }

    private func save<T: Encodable>(_ value: T?, _ key: String) {
        guard let value else { return defaults.removeObject(forKey: key) }
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }

    private static func load<T: Decodable>(_ type: T.Type, _ key: String, from defaults: UserDefaults) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }
}
