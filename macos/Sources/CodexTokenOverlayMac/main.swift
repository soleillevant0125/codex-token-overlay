import AppKit

let application = NSApplication.shared
let applicationDelegate = AppDelegate()

application.setActivationPolicy(.accessory)
application.delegate = applicationDelegate
application.run()
