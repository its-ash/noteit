import AppKit

/// Daily copies of notes.json in Application Support/NoteIt/Backups, keeping the newest 14.
@MainActor
enum Backups {
  static let keep = 14
  static var dir: URL {
    let u = AppPaths.support.appending(path: "Backups", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
  }

  static func name(for date: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd-HHmmss"
    return "notes-\(f.string(from: date)).json"
  }

  /// Backups, newest first.
  static func list() -> [URL] {
    let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    return files.filter { $0.lastPathComponent.hasPrefix("notes-") && $0.pathExtension == "json" }
      .sorted { $0.lastPathComponent > $1.lastPathComponent }
  }

  /// File names to delete so only the newest `keep` remain. Names sort by date.
  nonisolated static func toPrune(_ names: [String], keep: Int) -> [String] {
    Array(names.sorted(by: >).dropFirst(keep))
  }

  /// Makes today's backup if there is none yet.
  static func daily(_ store: NoteStore, now: Date = Date()) {
    let today = String(name(for: now).prefix("notes-yyyy-MM-dd".count))
    guard !list().contains(where: { $0.lastPathComponent.hasPrefix(today) }) else { return }
    backUp(store, now: now)
  }

  @discardableResult
  static func backUp(_ store: NoteStore, now: Date = Date()) -> URL? {
    store.saveNow()
    let to = dir.appending(path: name(for: now))
    guard FileManager.default.fileExists(atPath: store.url.path) else { return nil }
    do { try FileManager.default.copyItem(at: store.url, to: to) }
    catch { return nil }
    for n in toPrune(list().map(\.lastPathComponent), keep: keep) {
      try? FileManager.default.removeItem(at: dir.appending(path: n))
    }
    return to
  }

  /// Replaces all notes with a backup, after backing up the current notes.
  static func restore(_ url: URL, store: NoteStore, texts: NoteTexts) throws {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    var notes = try d.decode([Note].self, from: Data(contentsOf: url))
    backUp(store)
    // Restored notes count as new edits, so sync sends them to your other devices.
    let now = Date()
    for i in notes.indices { notes[i].modified = now }
    store.replaceAll(notes)
    store.saveNow()
    texts.reloadAll()
  }

  /// Asks for a backup to restore and restores it.
  static func chooseAndRestore(store: NoteStore, texts: NoteTexts) {
    let p = NSOpenPanel()
    p.directoryURL = dir
    p.allowedContentTypes = [.json]
    p.prompt = "Restore"
    p.message = "Choose a backup. Your current notes are backed up first."
    guard p.runModal() == .OK, let url = p.url else { return }
    let a = NSAlert()
    a.messageText = "Replace all notes with this backup?"
    a.informativeText = "\(url.lastPathComponent)\n\nYour current notes are saved as a new backup first, so you can switch back."
    a.addButton(withTitle: "Restore").hasDestructiveAction = true
    a.addButton(withTitle: "Cancel")
    guard a.runModal() == .alertFirstButtonReturn else { return }
    do { try restore(url, store: store, texts: texts) }
    catch { NSAlert(error: error).runModal() }
  }
}
