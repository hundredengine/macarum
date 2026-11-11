import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
// For screenshots in both looks: launch with `-MacarumAppearance light` or `dark`.
switch UserDefaults.standard.string(forKey: "MacarumAppearance") {
case "light": app.appearance = NSAppearance(named: .aqua)
case "dark": app.appearance = NSAppearance(named: .darkAqua)
default: break
}
app.run()
