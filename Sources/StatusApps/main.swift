import AppKit

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
// Menu bar only: no Dock icon, no main window.
application.setActivationPolicy(.accessory)
application.run()
