import AppKit

MainActor.assumeIsolated {
  let app = NSApplication.shared
  let delegate = AppDelegate()
  app.delegate = delegate
  // Menu bar only: no Dock icon. Info.plist sets LSUIElement for the app bundle; this covers `swift run`.
  app.setActivationPolicy(.accessory)
  withExtendedLifetime(delegate) { app.run() }
}
