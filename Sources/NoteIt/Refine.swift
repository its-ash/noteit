import AppKit
import SwiftUI

/// What the preview popover shows while an edit streams in.
@MainActor
@Observable
final class ReviewModel {
  var action: String
  var text = ""
  var done = false
  var error: String?

  init(action: String) { self.action = action }
}

@MainActor
final class ReviewPopover: NSObject, NSPopoverDelegate {
  let model: ReviewModel
  let popover = NSPopover()
  var onReplace: (() -> Void)?
  var onInsert: (() -> Void)?
  var onRetry: (() -> Void)?
  var onClose: (() -> Void)?

  init(model: ReviewModel) {
    self.model = model
    super.init()
    popover.behavior = .semitransient
    popover.delegate = self
    popover.contentViewController = NSHostingController(rootView: ReviewView(model: model, owner: self))
  }

  func show(from view: NSView) {
    popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
  }

  func popoverDidClose(_ n: Notification) { onClose?() }
}

private struct ReviewView: View {
  @Bindable var model: ReviewModel
  let owner: ReviewPopover

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label(model.action, systemImage: "sparkles")
        .font(.headline)
      if let e = model.error {
        Text(e)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
        HStack {
          Button("Open Settings…") {
            owner.popover.close()
            SettingsWindow.show(tab: .ai)
          }
          Spacer()
          Button("Try Again") { owner.onRetry?() }
          Button("Close") { owner.popover.close() }
            .keyboardShortcut(.cancelAction)
        }
      }
      else {
        ScrollView {
          Text(model.text.isEmpty ? "Writing…" : model.text)
            .foregroundStyle(model.text.isEmpty ? .secondary : .primary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 80, maxHeight: 280)
        HStack {
          Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(model.text, forType: .string)
          } label: {
            Label("Copy", systemImage: "doc.on.doc")
          }
          .disabled(!model.done)
          Spacer()
          Button("Discard") { owner.popover.close() }
            .keyboardShortcut(.cancelAction)
          Button("Insert Below") { owner.onInsert?() }
            .disabled(!model.done)
          Button("Replace") { owner.onReplace?() }
            .keyboardShortcut(.defaultAction)
            .disabled(!model.done)
        }
      }
    }
    .padding(14)
    .frame(width: 360)
  }
}

/// Text that streams into a note during an inline edit.
@MainActor
final class LiveEdit {
  let storage: NSTextStorage
  let original: NSAttributedString
  let style: [NSAttributedString.Key: Any]
  let prefix: String
  var live: NSRange
  var streamed = ""

  init(storage: NSTextStorage, original: NSAttributedString, style: [NSAttributedString.Key: Any], prefix: String, live: NSRange) {
    self.storage = storage
    self.original = original
    self.style = style
    self.prefix = prefix
    self.live = live
  }

  func show() {
    let piece = NSAttributedString(string: prefix + streamed, attributes: style)
    storage.replaceCharacters(in: live, with: piece)
    live.length = piece.length
  }

  func restore(below: Bool) {
    storage.replaceCharacters(in: live, with: below ? NSAttributedString() : original)
    live.length = below ? 0 : original.length
  }
}

/// Runs AI actions on one note text view. Used by stickies and by the All Notes editor.
@MainActor
final class AIEditor {
  let prefs: Prefs
  weak var textView: NoteTextView?
  /// The view the preview and error popovers point at.
  var anchor: () -> NSView? = { nil }
  /// Called before an action starts, for example to expand a collapsed sticky.
  var willRun: () -> Void = {}
  /// Called when an action starts or ends.
  var onBusyChange: () -> Void = {}
  private(set) var job: Task<Void, Never>? { didSet { onBusyChange() } }
  private var review: ReviewPopover?

  var busy: Bool { job != nil }

  init(prefs: Prefs = .shared) { self.prefs = prefs }

  private var baseAttributes: [NSAttributedString.Key: Any] { noteAttributes(prefs.font) }

  // MARK: menus

  static func item(_ a: AIAction, target: AnyObject?) -> NSMenuItem {
    let i = NSMenuItem(title: a.name, action: #selector(NoteTextView.runAIAction(_:)), keyEquivalent: "")
    i.representedObject = a.id
    i.image = NSImage(systemSymbolName: a.icon, accessibilityDescription: nil)
    i.target = target
    return i
  }

  /// "NoteIt AI" with every enabled action, for context menus.
  func menuItems() -> [NSMenuItem] {
    let actions = prefs.ai.enabledActions
    guard !actions.isEmpty else { return [] }
    let root = NSMenuItem(title: "NoteIt AI", action: nil, keyEquivalent: "")
    root.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
    let sub = NSMenu()
    for a in actions { sub.addItem(Self.item(a, target: textView)) }
    root.submenu = sub
    return [root]
  }

  func showMenu(from sender: NSView) {
    let m = NSMenu()
    let selection = (textView?.selectedRange().length ?? 0) > 0
    let head = NSMenuItem(title: selection ? "Edit Selection" : "Edit Whole Note", action: nil, keyEquivalent: "")
    head.isEnabled = false
    m.addItem(head)
    for a in prefs.ai.enabledActions { m.addItem(Self.item(a, target: textView)) }
    m.addItem(.separator())
    m.addItem(NSMenuItem(title: "AI Settings…", action: #selector(AppDelegate.showAISettings(_:)), keyEquivalent: ""))
    m.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
  }

  // MARK: running

  func runDefault() {
    guard let a = prefs.ai.primary else { return SettingsWindow.show(tab: .actions) }
    run(a)
  }

  func run(id: UUID) {
    guard let a = prefs.ai.actions.first(where: { $0.id == id }) else { return }
    run(a)
  }

  func stop() { job?.cancel() }

  /// Stops any action and closes its popover.
  func cancel() {
    job?.cancel()
    review?.popover.close()
  }

  /// The range the action edits: the selection, or the whole note when nothing is selected.
  private func target(_ tv: NSTextView) -> NSRange {
    let sel = tv.selectedRange()
    if sel.length > 0 { return sel }
    return NSRange(location: 0, length: tv.string.utf16.count)
  }

  func run(_ action: AIAction) {
    guard job == nil, let tv = textView else { return }
    willRun()
    let range = target(tv)
    let source = (tv.string as NSString).substring(with: range)
    guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      NSSound.beep()
      return
    }
    let cfg = prefs.ai
    let key = Keychain.key(cfg.provider)
    if ProviderPreset.find(cfg.provider).needsKey, key.isEmpty {
      return fail(action, "Add your \(ProviderPreset.find(cfg.provider).name) API key in NoteIt Settings → AI.")
    }
    let user = AIClient.prompt(action, source)
    switch cfg.apply {
    case .review: runReview(action, cfg, key, user, range)
    case .replace, .below: runInline(action, cfg, key, user, range, below: cfg.apply == .below)
    }
  }

  private func attrs(at range: NSRange) -> [NSAttributedString.Key: Any] {
    guard let s = textView?.textStorage, s.length > 0 else { return baseAttributes }
    var a = s.attributes(at: min(range.location, s.length - 1), effectiveRange: nil)
    a.removeValue(forKey: .attachment)
    a.removeValue(forKey: .link)
    return a
  }

  /// Streams the answer straight into the note, then records the whole edit as one undo step.
  private func runInline(_ action: AIAction, _ cfg: AIConfig, _ key: String, _ user: String, _ range: NSRange, below: Bool) {
    guard let tv = textView, let storage = tv.textStorage else { return }
    let edit = LiveEdit(
      storage: storage,
      original: storage.attributedSubstring(from: range),
      style: attrs(at: range),
      prefix: below ? "\n\n" : "",
      live: NSRange(location: below ? NSMaxRange(range) : range.location, length: below ? 0 : range.length)
    )
    let undo = tv.undoManager
    tv.isEditable = false
    undo?.disableUndoRegistration()

    job = Task { [weak self] in
      var result: Result<String, Error>
      do {
        let text = try await AIClient.run(cfg, key: key, user: user) { [weak self] piece in
          edit.streamed += piece
          guard cfg.stream, let tv = self?.textView else { return }
          edit.show()
          tv.scrollRangeToVisible(NSRange(location: NSMaxRange(edit.live), length: 0))
        }
        result = .success(text)
      }
      catch { result = .failure(error) }
      // Put the original back without undo, then make the final change with undo on.
      edit.restore(below: below)
      undo?.enableUndoRegistration()
      guard let self else { return }
      self.textView?.isEditable = true
      self.job = nil
      switch result {
      case .success(let text) where !text.isEmpty:
        let at = below ? NSRange(location: NSMaxRange(range), length: 0) : range
        self.replace(at, with: NSAttributedString(string: edit.prefix + text, attributes: edit.style), name: action.name)
      case .success:
        self.fail(action, "The model returned no text.")
      case .failure(let e) where e is CancellationError:
        break
      case .failure(let e):
        self.fail(action, e.localizedDescription)
      }
    }
  }

  /// Replaces text through the text view so it joins the undo stack and keeps the note saved.
  func replace(_ range: NSRange, with text: NSAttributedString, name: String) {
    guard let tv = textView, tv.shouldChangeText(in: range, replacementString: text.string) else { return }
    tv.textStorage?.replaceCharacters(in: range, with: text)
    tv.didChangeText()
    tv.undoManager?.setActionName(name)
    tv.setSelectedRange(NSRange(location: range.location, length: text.length))
    tv.window?.makeFirstResponder(tv)
  }

  private func runReview(_ action: AIAction, _ cfg: AIConfig, _ key: String, _ user: String, _ range: NSRange) {
    let model = ReviewModel(action: action.name)
    let pop = ReviewPopover(model: model)
    let style = attrs(at: range)
    pop.onReplace = { [weak self, weak pop] in
      self?.replace(range, with: NSAttributedString(string: model.text, attributes: style), name: action.name)
      pop?.popover.close()
    }
    pop.onInsert = { [weak self, weak pop] in
      self?.replace(NSRange(location: NSMaxRange(range), length: 0), with: NSAttributedString(string: "\n\n" + model.text, attributes: style), name: action.name)
      pop?.popover.close()
    }
    pop.onRetry = { [weak self, weak pop] in
      pop?.popover.close()
      self?.run(action)
    }
    pop.onClose = { [weak self] in
      self?.job?.cancel()
      self?.review = nil
    }
    review = pop
    if let v = anchor() ?? textView { pop.show(from: v) }
    job = Task { [weak self] in
      do {
        let text = try await AIClient.run(cfg, key: key, user: user) { piece in model.text += piece }
        model.text = text
        if text.isEmpty { model.error = "The model returned no text." }
      }
      catch is CancellationError {}
      catch { model.error = error.localizedDescription }
      model.done = true
      self?.job = nil
    }
  }

  /// Shows an error next to the AI button.
  func fail(_ action: AIAction, _ message: String) {
    let model = ReviewModel(action: action.name)
    model.error = message
    model.done = true
    let pop = ReviewPopover(model: model)
    pop.onRetry = { [weak self, weak pop] in
      pop?.popover.close()
      self?.run(action)
    }
    pop.onClose = { [weak self] in self?.review = nil }
    review = pop
    willRun()
    if let v = anchor() ?? textView { pop.show(from: v) }
  }

  // MARK: one-off requests

  /// Sends one request with its own instructions, for titles and questions about notes.
  static func ask(_ prefs: Prefs, system: String, user: String, onText: @MainActor @Sendable (String) -> Void = { _ in }) async throws -> String {
    var cfg = prefs.ai
    cfg.system = system
    let key = Keychain.key(cfg.provider)
    if ProviderPreset.find(cfg.provider).needsKey, key.isEmpty {
      throw AIError(message: "Add your \(ProviderPreset.find(cfg.provider).name) API key in NoteIt Settings → AI.")
    }
    return try await AIClient.run(cfg, key: key, user: user, onText: onText)
  }

  /// A short title for a note's text.
  static func suggestTitle(_ prefs: Prefs, text: String) async throws -> String {
    let system = "You name sticky notes. Reply with only a short, specific title of at most six words, in the note's language. No quotes and no final period."
    let reply = try await ask(prefs, system: system, user: "<note>\n\(text.prefix(4000))\n</note>")
    return Note.firstLine(of: reply).trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’.#*"))
  }
}
