import AppKit
import Observation
import ServiceManagement

extension Notification.Name {
  static let prefsChanged = Notification.Name("NoteIt.prefsChanged")
}

/// App-wide settings. Each change saves to UserDefaults and tells open notes to refresh.
@MainActor
@Observable
final class Prefs {
  static let shared = Prefs()

  @ObservationIgnored private let defaults: UserDefaults

  var defaultColor: NoteColor { didSet { save() } }
  var fontName: String { didSet { save() } }
  var fontSize: Double { didSet { save() } }
  var newNotesFloat: Bool { didSet { save() } }
  var translucency: Double { didSet { save() } }
  var confirmDelete: Bool { didSet { save() } }
  var spellCheck: Bool { didSet { save() } }
  var showAIButton: Bool { didSet { save() } }
  /// Stickies snap to screen edges and to each other while dragged.
  var snapNotes: Bool { didSet { save() } }
  /// ⌃⌥N makes a new note from any app.
  var quickCapture: Bool { didSet { save() } }
  /// Keep a copy of all notes each day.
  var dailyBackups: Bool { didSet { save() } }
  var ai: AIConfig { didSet { save() } }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    defaultColor = NoteColor(rawValue: defaults.string(forKey: "defaultColor") ?? "") ?? .yellow
    fontName = defaults.string(forKey: "fontName") ?? ""
    fontSize = defaults.object(forKey: "fontSize") as? Double ?? 14
    newNotesFloat = defaults.bool(forKey: "newNotesFloat")
    translucency = defaults.object(forKey: "translucency") as? Double ?? 0.72
    confirmDelete = defaults.object(forKey: "confirmDelete") as? Bool ?? true
    spellCheck = defaults.object(forKey: "spellCheck") as? Bool ?? true
    showAIButton = defaults.object(forKey: "showAIButton") as? Bool ?? true
    snapNotes = defaults.object(forKey: "snapNotes") as? Bool ?? true
    quickCapture = defaults.object(forKey: "quickCapture") as? Bool ?? true
    dailyBackups = defaults.object(forKey: "dailyBackups") as? Bool ?? true
    ai = defaults.data(forKey: "ai").flatMap { try? JSONDecoder().decode(AIConfig.self, from: $0) } ?? AIConfig()
  }

  /// The font new notes start with: the chosen face, or the system font.
  var font: NSFont {
    let size = CGFloat(fontSize)
    return (fontName.isEmpty ? nil : NSFont(name: fontName, size: size)) ?? .systemFont(ofSize: size)
  }

  /// On once registered, even while macOS still waits for the user to allow it in Login Items.
  var launchAtLogin: Bool {
    get { [.enabled, .requiresApproval].contains(SMAppService.mainApp.status) }
    set {
      guard newValue != launchAtLogin else { return }
      do { newValue ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
      catch { NSSound.beep() }
    }
  }

  /// macOS blocked opening at login until the user allows NoteIt in System Settings → Login Items.
  var launchAtLoginNeedsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

  private func save() {
    defaults.set(defaultColor.rawValue, forKey: "defaultColor")
    defaults.set(fontName, forKey: "fontName")
    defaults.set(fontSize, forKey: "fontSize")
    defaults.set(newNotesFloat, forKey: "newNotesFloat")
    defaults.set(translucency, forKey: "translucency")
    defaults.set(confirmDelete, forKey: "confirmDelete")
    defaults.set(spellCheck, forKey: "spellCheck")
    defaults.set(showAIButton, forKey: "showAIButton")
    defaults.set(snapNotes, forKey: "snapNotes")
    defaults.set(quickCapture, forKey: "quickCapture")
    defaults.set(dailyBackups, forKey: "dailyBackups")
    if let d = try? JSONEncoder().encode(ai) { defaults.set(d, forKey: "ai") }
    NotificationCenter.default.post(name: .prefsChanged, object: nil)
  }
}
