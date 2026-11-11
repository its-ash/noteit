import AppKit
import Carbon.HIToolbox

/// One system-wide shortcut, ⌃⌥N, for a new note from any app.
/// Uses the Carbon hot key API, which needs no Accessibility permission.
@MainActor
enum Hotkey {
  private static var ref: EventHotKeyRef?
  private static var handler: EventHandlerRef?
  private static var action: () -> Void = {}

  static let label = "⌃⌥N"

  static func set(_ on: Bool, action: @escaping () -> Void) {
    self.action = action
    if on { register() } else { unregister() }
  }

  private static func register() {
    guard ref == nil else { return }
    if handler == nil {
      var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
      InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
        Task { @MainActor in Hotkey.action() }
        return noErr
      }, 1, &spec, nil, &handler)
    }
    let id = EventHotKeyID(signature: OSType(0x4E_6F_49_74), id: 1)  // "NoIt"
    RegisterEventHotKey(UInt32(kVK_ANSI_N), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &ref)
  }

  private static func unregister() {
    if let ref { UnregisterEventHotKey(ref) }
    ref = nil
  }
}
