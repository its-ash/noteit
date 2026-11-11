import AppKit

/// Paper colors for notes. Each is a light, low-saturation tint, so dark text stays easy to read (contrast above 7:1).
enum NoteColor: String, Codable, CaseIterable, Sendable {
  case yellow, orange, pink, purple, blue, teal, green, gray

  var title: String { rawValue.capitalized }

  /// sRGB components of the paper, 0...1.
  var rgb: (r: Double, g: Double, b: Double) {
    switch self {
    case .yellow: (1.000, 0.965, 0.690)
    case .orange: (1.000, 0.882, 0.737)
    case .pink: (0.992, 0.855, 0.898)
    case .purple: (0.910, 0.871, 0.984)
    case .blue: (0.839, 0.922, 0.992)
    case .teal: (0.816, 0.949, 0.929)
    case .green: (0.863, 0.961, 0.808)
    case .gray: (0.937, 0.937, 0.929)
    }
  }

  var paper: NSColor { NSColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1) }

  /// The slightly darker strip at the top of a note.
  var header: NSColor { paper.blended(withFraction: 0.07, of: .black) ?? paper }

  /// Text color on every paper: near-black, softer on the eyes than pure black.
  static let ink = NSColor(srgbRed: 0.114, green: 0.114, blue: 0.122, alpha: 1)
  static let inkRGB = (r: 0.114, g: 0.114, b: 0.122)

  /// WCAG contrast ratio between the paper and `ink`.
  var contrast: Double {
    func lum(_ c: (r: Double, g: Double, b: Double)) -> Double {
      func ch(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
      return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b)
    }
    let a = lum(rgb), b = lum(Self.inkRGB)
    return (max(a, b) + 0.05) / (min(a, b) + 0.05)
  }

  /// A small rounded swatch for menus and pickers.
  @MainActor
  func swatch(_ side: CGFloat = 12) -> NSImage {
    let c = self
    let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { r in
      c.paper.setFill()
      let p = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: side / 5, yRadius: side / 5)
      p.fill()
      NSColor.black.withAlphaComponent(0.25).setStroke()
      p.stroke()
      return true
    }
    img.accessibilityDescription = title
    return img
  }
}

/// Default text style for note text: the chosen font in ink, with a little extra line spacing.
@MainActor
func noteAttributes(_ font: NSFont) -> [NSAttributedString.Key: Any] {
  let p = NSMutableParagraphStyle()
  p.lineHeightMultiple = 1.12
  p.paragraphSpacing = 2
  return [.font: font, .foregroundColor: NoteColor.ink, .paragraphStyle: p]
}

struct Note: Codable, Identifiable, Equatable, Sendable {
  var id = UUID()
  /// The title the user typed. When empty, the first line of the note stands in.
  var name = ""
  /// Pinned notes show on the desktop as stickies; unpinned notes live only in All Notes.
  var pinned = true
  /// Flattened RTFD, so fonts, colors, lists, and images survive.
  var rtfd = Data()
  var color: NoteColor = .yellow
  var frame = CGRect(x: 0, y: 0, width: 260, height: 220)
  var floating = false
  var translucent = false
  var collapsed = false
  var created = Date()
  var modified = Date()
  /// Notebook (section) name; empty means none.
  var notebook = ""
  var favorite = false
  /// Archived notes leave All Notes and the desktop but are kept.
  var archived = false
  /// When the note went to the Trash. Trashed notes are deleted for good after 30 days.
  var trashed: Date?
  /// When to show a reminder notification.
  var remind: Date?

  /// Shown in All Notes and allowed on the desktop.
  var isLive: Bool { trashed == nil && !archived }
  /// Shown on the desktop as a sticky.
  var onDesktop: Bool { pinned && isLive }

  var attributed: NSAttributedString {
    get {
      guard !rtfd.isEmpty else { return NSAttributedString() }
      return NSAttributedString(rtfd: rtfd, documentAttributes: nil) ?? NSAttributedString()
    }
    set {
      rtfd = newValue.rtfd(from: NSRange(location: 0, length: newValue.length), documentAttributes: [:]) ?? Data()
    }
  }

  var plain: String { attributed.string }

  var firstLine: String { Self.firstLine(of: plain) }

  /// The typed title, or else the first non-empty line.
  var title: String { Self.title(name: name, plain: plain) }

  static func firstLine(of text: String) -> String {
    text.split(whereSeparator: \.isNewline).lazy
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .first { !$0.isEmpty } ?? ""
  }

  static func title(name: String, plain: String) -> String {
    let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
    if !n.isEmpty { return n }
    let line = firstLine(of: plain)
    return line.isEmpty ? "Empty note" : line
  }

  /// `#tags` in the text, lowercased and sorted. A `#` inside a word or URL is not a tag.
  static func tags(in text: String) -> [String] {
    guard let re = try? NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_#/&])#(\p{L}[\p{L}\p{N}_\-]*)"#) else { return [] }
    let ns = text as NSString
    let found = re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)).lowercased() }
    return Array(Set(found)).sorted()
  }

  var isBlank: Bool {
    plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !attributed.containsAttachments
  }
}

extension Note {
  /// Missing keys fall back to defaults, so notes saved by older versions still load.
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.init()
    id = try c.decode(UUID.self, forKey: .id)
    name = try c.decodeIfPresent(String.self, forKey: .name) ?? name
    pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? pinned
    rtfd = try c.decodeIfPresent(Data.self, forKey: .rtfd) ?? rtfd
    color = try c.decodeIfPresent(NoteColor.self, forKey: .color) ?? color
    frame = try c.decodeIfPresent(CGRect.self, forKey: .frame) ?? frame
    floating = try c.decodeIfPresent(Bool.self, forKey: .floating) ?? floating
    translucent = try c.decodeIfPresent(Bool.self, forKey: .translucent) ?? translucent
    collapsed = try c.decodeIfPresent(Bool.self, forKey: .collapsed) ?? collapsed
    created = try c.decodeIfPresent(Date.self, forKey: .created) ?? created
    modified = try c.decodeIfPresent(Date.self, forKey: .modified) ?? modified
    notebook = try c.decodeIfPresent(String.self, forKey: .notebook) ?? notebook
    favorite = try c.decodeIfPresent(Bool.self, forKey: .favorite) ?? favorite
    archived = try c.decodeIfPresent(Bool.self, forKey: .archived) ?? archived
    trashed = try c.decodeIfPresent(Date.self, forKey: .trashed)
    remind = try c.decodeIfPresent(Date.self, forKey: .remind)
  }
}

extension Notification.Name {
  /// Posted by a `NoteStore` (the object) after any note is added, changed, or removed.
  static let notesChanged = Notification.Name("NoteIt.notesChanged")
  /// Posted by a `NoteStore` when a note is deleted for good. `userInfo["id"]` is its UUID.
  static let noteDeleted = Notification.Name("NoteIt.noteDeleted")
}

/// How long a note stays in the Trash.
let TRASH_DAYS = 30

/// Keeps every note in one JSON file and saves shortly after each change.
@MainActor
final class NoteStore {
  static let shared = NoteStore()

  private(set) var notes: [Note] = []
  let url: URL
  private var pending: Task<Void, Never>?

  init(file: URL = AppPaths.support.appending(path: "notes.json")) {
    url = file
    if let data = try? Data(contentsOf: file) {
      let d = JSONDecoder()
      d.dateDecodingStrategy = .iso8601
      notes = (try? d.decode([Note].self, from: data)) ?? []
    }
  }

  func note(_ id: UUID) -> Note? { notes.first { $0.id == id } }

  func add(_ n: Note) {
    notes.append(n)
    changed()
  }

  func update(_ n: Note) {
    guard let i = notes.firstIndex(where: { $0.id == n.id }) else { return add(n) }
    guard notes[i] != n else { return }
    notes[i] = n
    changed()
  }

  /// Deletes a note for good.
  func remove(_ id: UUID) {
    guard notes.contains(where: { $0.id == id }) else { return }
    notes.removeAll { $0.id == id }
    NotificationCenter.default.post(name: .noteDeleted, object: self, userInfo: ["id": id])
    changed()
  }

  /// Replaces every note, for example when restoring a backup.
  func replaceAll(_ new: [Note]) {
    let keep = Set(new.map(\.id))
    for n in notes where !keep.contains(n.id) {
      NotificationCenter.default.post(name: .noteDeleted, object: self, userInfo: ["id": n.id])
    }
    notes = new
    changed()
  }

  /// Deletes notes that have been in the Trash longer than `TRASH_DAYS`. Returns how many.
  @discardableResult
  func purgeTrash(now: Date = Date()) -> Int {
    let old = notes.filter { $0.trashed.map { now.timeIntervalSince($0) > Double(TRASH_DAYS) * 86_400 } ?? false }
    old.forEach { remove($0.id) }
    return old.count
  }

  /// Clears reminders whose time has passed.
  func clearPastReminders(now: Date = Date()) {
    for var n in notes where (n.remind.map { $0 <= now } ?? false) {
      n.remind = nil
      update(n)
    }
  }

  private func changed() {
    scheduleSave()
    NotificationCenter.default.post(name: .notesChanged, object: self)
  }

  func scheduleSave() {
    pending?.cancel()
    pending = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(600))
      guard !Task.isCancelled else { return }
      self?.saveNow()
    }
  }

  func saveNow() {
    pending?.cancel()
    pending = nil
    let e = JSONEncoder()
    e.dateEncodingStrategy = .iso8601
    e.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? e.encode(notes) else { return }
    try? data.write(to: url, options: .atomic)
  }
}

enum AppPaths {
  static let support: URL = {
    let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appending(path: "NoteIt", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }()
}
