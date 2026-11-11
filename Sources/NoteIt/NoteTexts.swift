import AppKit

/// One live text storage per note. A sticky and the All Notes editor attach their own layout
/// managers to the same storage, so typing in one shows up in the other at once.
/// Edits are written back to the store shortly after typing stops.
@MainActor
final class NoteTexts: NSObject {
  static let shared = NoteTexts(store: .shared)

  let store: NoteStore
  private var storages: [UUID: NSTextStorage] = [:]
  private var ids: [ObjectIdentifier: UUID] = [:]
  private var pending: [UUID: Task<Void, Never>] = [:]
  /// Set while the storage is changed from the store, so that change is not saved back.
  private var reloading = false

  init(store: NoteStore) {
    self.store = store
    super.init()
    NotificationCenter.default.addObserver(self, selector: #selector(storeChanged), name: .notesChanged, object: store)
  }

  func storage(_ id: UUID) -> NSTextStorage {
    if let s = storages[id] { return s }
    let s = NSTextStorage(attributedString: store.note(id)?.attributed ?? NSAttributedString())
    storages[id] = s
    ids[ObjectIdentifier(s)] = id
    NotificationCenter.default.addObserver(self, selector: #selector(edited(_:)), name: NSTextStorage.didProcessEditingNotification, object: s)
    return s
  }

  /// A text view drawing the note's shared storage.
  func makeTextView(_ id: UUID, size: NSSize) -> NoteTextView {
    let s = storage(id)
    let lm = NSLayoutManager()
    s.addLayoutManager(lm)
    let tc = NSTextContainer(size: NSSize(width: size.width, height: .greatestFiniteMagnitude))
    tc.widthTracksTextView = true
    lm.addTextContainer(tc)
    let tv = NoteTextView(frame: NSRect(origin: .zero, size: size), textContainer: tc)
    tv.owner = s
    return tv
  }

  /// Unhooks a text view that is going away, so the shared storage stops laying text out for it.
  func detach(_ tv: NoteTextView) {
    guard let lm = tv.layoutManager, let s = lm.textStorage else { return }
    // Move only this view's layout manager; `replaceTextStorage` would move every view sharing the storage.
    let empty = NSTextStorage()
    s.removeLayoutManager(lm)
    empty.addLayoutManager(lm)
    tv.owner = empty
  }

  /// Puts the stored text back into the live storage, after sync or a restore changed it.
  func reload(_ id: UUID) {
    guard let s = storages[id], let n = store.note(id) else { return }
    pending.removeValue(forKey: id)?.cancel()
    let text = n.attributed
    guard text != NSAttributedString(attributedString: s) else { return }
    reloading = true
    defer { reloading = false }
    s.setAttributedString(text)
  }

  func reloadAll() {
    for id in Array(storages.keys) { reload(id) }
  }

  /// The live text, when a view has it open; otherwise nil.
  func liveString(_ id: UUID) -> String? { storages[id]?.string }

  @objc private func edited(_ n: Notification) {
    guard !reloading, let s = n.object as? NSTextStorage, let id = ids[ObjectIdentifier(s)] else { return }
    pending[id]?.cancel()
    pending[id] = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(400))
      guard !Task.isCancelled else { return }
      self?.commit(id)
    }
  }

  /// Writes the note's live text to the store now.
  func commit(_ id: UUID) {
    pending.removeValue(forKey: id)?.cancel()
    guard let s = storages[id], var n = store.note(id) else { return }
    let copy = NSAttributedString(attributedString: s)
    guard copy != n.attributed else { return }
    n.attributed = copy
    n.modified = Date()
    store.update(n)
  }

  func commitAll() {
    for id in Array(pending.keys) { commit(id) }
  }

  /// Drops storages of deleted notes.
  @objc private func storeChanged() {
    let live = Set(store.notes.map(\.id))
    for (id, s) in storages where !live.contains(id) {
      pending.removeValue(forKey: id)?.cancel()
      NotificationCenter.default.removeObserver(self, name: NSTextStorage.didProcessEditingNotification, object: s)
      ids.removeValue(forKey: ObjectIdentifier(s))
      storages.removeValue(forKey: id)
    }
  }

  /// Settings shared by every note text view.
  static func configure(_ tv: NSTextView, prefs: Prefs) {
    tv.minSize = NSSize(width: 0, height: 0)
    tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
    tv.isVerticallyResizable = true
    tv.isHorizontallyResizable = false
    tv.autoresizingMask = [.width]
    tv.textContainer?.widthTracksTextView = true
    tv.drawsBackground = false
    tv.isRichText = true
    tv.importsGraphics = true
    tv.allowsImageEditing = true
    tv.allowsUndo = true
    tv.usesFindBar = true
    tv.isIncrementalSearchingEnabled = true
    tv.usesFontPanel = true
    tv.usesRuler = true
    tv.isAutomaticLinkDetectionEnabled = true
    tv.isAutomaticDataDetectionEnabled = true
    tv.isAutomaticTextCompletionEnabled = true
    tv.insertionPointColor = NoteColor.ink
    tv.isContinuousSpellCheckingEnabled = prefs.spellCheck
    tv.defaultParagraphStyle = noteAttributes(prefs.font)[.paragraphStyle] as? NSParagraphStyle
    if tv.string.isEmpty { tv.typingAttributes = noteAttributes(prefs.font) }
  }
}
