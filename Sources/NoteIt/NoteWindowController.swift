import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Height of the strip at the top of a note; also the height of a collapsed note.
let HEADER: CGFloat = 24
/// Corner radius of a note. Small, like a sheet of paper.
let CORNER: CGFloat = 5
let MIN_NOTE = NSSize(width: 180, height: 90)

/// A frameless note window, so the corners can be less rounded than system title-bar windows.
final class NoteWindow: NSWindow {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }

  /// Frameless windows have no close button, so `performClose` would only beep.
  override func performClose(_ sender: Any?) {
    if delegate?.windowShouldClose?(self) ?? true { close() }
  }
}

/// The bottom-right corner grip, as in Stickies.
final class ResizeGrip: NSView {
  var minSize: () -> NSSize = { MIN_NOTE }
  var onEnd: (() -> Void)?
  private var start: (frame: NSRect, mouse: NSPoint)?

  override func draw(_ dirtyRect: NSRect) {
    NSColor.black.withAlphaComponent(0.28).setStroke()
    for i in 0..<3 {
      let o = CGFloat(i) * 4 + 3
      let p = NSBezierPath()
      p.move(to: NSPoint(x: bounds.maxX - o, y: 2))
      p.line(to: NSPoint(x: bounds.maxX - 2, y: o))
      p.lineWidth = 1
      p.stroke()
    }
  }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .frameResize(position: .bottomRight, directions: .all))
  }

  override func mouseDown(with e: NSEvent) {
    guard let w = window else { return }
    start = (w.frame, NSEvent.mouseLocation)
  }

  override func mouseDragged(with e: NSEvent) {
    guard let w = window, let s = start else { return }
    let now = NSEvent.mouseLocation
    let min = minSize()
    let width = max(min.width, s.frame.width + now.x - s.mouse.x)
    let height = max(min.height, s.frame.height - (now.y - s.mouse.y))
    w.setFrame(NSRect(x: s.frame.minX, y: s.frame.maxY - height, width: width, height: height), display: true)
  }

  override func mouseUp(with e: NSEvent) {
    start = nil
    onEnd?()
  }
}

/// The top strip: drag to move, double-click to collapse, like Stickies.
/// Dragging snaps to screen edges and other notes; hold Option to move freely.
final class HeaderView: NSView {
  var onDoubleClick: (() -> Void)?
  /// Where a frame should land; nil turns snapping off.
  var snap: ((NSRect) -> NSPoint)?
  var onDragEnd: (() -> Void)?
  var fill: NSColor = .clear { didSet { needsDisplay = true } }
  private(set) var dragging = false
  private var start: (origin: NSPoint, mouse: NSPoint)?

  override var mouseDownCanMoveWindow: Bool { false }

  override func draw(_ dirtyRect: NSRect) {
    fill.setFill()
    bounds.fill()
  }

  override func mouseDown(with e: NSEvent) {
    if e.clickCount == 2 {
      onDoubleClick?()
      return
    }
    guard let w = window else { return }
    start = (w.frame.origin, NSEvent.mouseLocation)
  }

  override func mouseDragged(with e: NSEvent) {
    guard let w = window, let s = start else { return }
    dragging = true
    let now = NSEvent.mouseLocation
    var f = w.frame
    f.origin = NSPoint(x: s.origin.x + now.x - s.mouse.x, y: s.origin.y + now.y - s.mouse.y)
    if !e.modifierFlags.contains(.option), let snap { f.origin = snap(f) }
    w.setFrameOrigin(f.origin)
  }

  override func mouseUp(with e: NSEvent) {
    let moved = dragging
    start = nil
    dragging = false
    if moved { onDragEnd?() }
  }
}

/// Paper background; shows the header buttons while the pointer is over the note.
final class PaperView: NSView {
  var fill: NSColor = .clear { didSet { needsDisplay = true } }
  var onHover: ((Bool) -> Void)?

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.cornerRadius = CORNER
    layer?.cornerCurve = .continuous
    layer?.masksToBounds = true
    layer?.borderWidth = 0.5
    layer?.borderColor = NSColor.black.withAlphaComponent(0.12).cgColor
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override func draw(_ dirtyRect: NSRect) {
    fill.setFill()
    bounds.fill()
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
  }

  override func mouseEntered(with e: NSEvent) { onHover?(true) }
  override func mouseExited(with e: NSEvent) { onHover?(false) }
}

/// A note's text view: AI actions, clickable checklist boxes, and extra context-menu items.
final class NoteTextView: NSTextView {
  var extraMenu: (() -> [NSMenuItem])?
  /// Keeps the text system alive: a text view made with a container does not own its storage.
  var owner: NSTextStorage?
  /// Runs AI actions on this view. Owned by the sticky or the All Notes window.
  weak var ai: AIEditor?

  // MARK: AI (through the responder chain, so the menu bar and ⌘R work in any note view)

  @objc func runDefaultAI(_ sender: Any?) { ai?.runDefault() }

  @objc func runAIAction(_ sender: NSMenuItem) {
    guard let id = sender.representedObject as? UUID else { return }
    ai?.run(id: id)
  }

  @objc func stopAI(_ sender: Any?) { ai?.stop() }

  override func validateMenuItem(_ item: NSMenuItem) -> Bool {
    switch item.action {
    case #selector(runDefaultAI(_:)), #selector(runAIAction(_:)):
      return ai.map { !$0.busy && !$0.prefs.ai.enabledActions.isEmpty } ?? false
    case #selector(stopAI(_:)):
      return ai?.busy ?? false
    case #selector(toggleChecklist(_:)):
      return isEditable
    default:
      return super.validateMenuItem(item)
    }
  }

  // MARK: checklists

  /// Format → Checklist (⇧⌘L): adds or removes ☐ on the selected lines.
  @objc func toggleChecklist(_ sender: Any?) {
    guard isEditable, let s = textStorage else { return }
    let (range, text) = Checklist.toggleLines(s.string as NSString, range: selectedRange())
    guard shouldChangeText(in: range, replacementString: text) else { return }
    let attrs = s.length > 0 ? s.attributes(at: min(range.location, s.length - 1), effectiveRange: nil) : typingAttributes
    s.replaceCharacters(in: range, with: NSAttributedString(string: text, attributes: attrs))
    didChangeText()
    undoManager?.setActionName("Checklist")
    setSelectedRange(NSRange(location: range.location + (text as NSString).length - (text.hasSuffix("\n") ? 1 : 0), length: 0))
  }

  /// The character index of a checklist box under a point in this view, if any.
  func checkbox(at p: NSPoint) -> Int? {
    guard let lm = layoutManager, let tc = textContainer, let s = textStorage, s.length > 0 else { return nil }
    let pt = NSPoint(x: p.x - textContainerOrigin.x, y: p.y - textContainerOrigin.y)
    var frac: CGFloat = 0
    let g = lm.glyphIndex(for: pt, in: tc, fractionOfDistanceThroughGlyph: &frac)
    guard lm.boundingRect(forGlyphRange: NSRange(location: g, length: 1), in: tc).insetBy(dx: -2, dy: -2).contains(pt) else { return nil }
    let i = lm.characterIndexForGlyph(at: g)
    guard i < s.length, let c = (s.string as NSString).substring(with: NSRange(location: i, length: 1)).first, Checklist.isBox(c) else { return nil }
    return i
  }

  override func mouseDown(with e: NSEvent) {
    let p = convert(e.locationInWindow, from: nil)
    if isEditable, e.clickCount == 1, e.modifierFlags.intersection([.shift, .command, .option]).isEmpty, let i = checkbox(at: p) {
      toggleBox(at: i)
      return
    }
    super.mouseDown(with: e)
  }

  func toggleBox(at i: Int) {
    guard let s = textStorage else { return }
    let r = NSRange(location: i, length: 1)
    guard let c = (s.string as NSString).substring(with: r).first else { return }
    let new = String(Checklist.toggled(c))
    guard shouldChangeText(in: r, replacementString: new) else { return }
    s.replaceCharacters(in: r, with: new)
    didChangeText()
    undoManager?.setActionName(c == Checklist.open ? "Check Item" : "Uncheck Item")
  }

  override func menu(for event: NSEvent) -> NSMenu? {
    let m = super.menu(for: event) ?? NSMenu()
    if let items = extraMenu?(), !items.isEmpty {
      m.insertItem(.separator(), at: 0)
      for (i, item) in items.enumerated() { m.insertItem(item, at: i) }
    }
    return m
  }
}

/// Scrolls note text up and down only. The text always wraps to the visible width, and the
/// scroller stays on screen whenever the text is taller than the view.
final class NoteScrollView: NSScrollView {
  override init(frame: NSRect) {
    super.init(frame: frame)
    verticalScroller = KnobScroller()
    hasVerticalScroller = true
    hasHorizontalScroller = false
    autohidesScrollers = true
    super.scrollerStyle = .legacy
    drawsBackground = false
    borderType = .noBorder
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  /// Legacy scrollers stay visible; overlay ones fade out. AppKit resets the style when the
  /// system scroll bar setting changes, so pin it here.
  override var scrollerStyle: NSScroller.Style {
    get { .legacy }
    set { super.scrollerStyle = .legacy }
  }

  /// Keeps the text exactly as wide as the visible area, so lines wrap there and never scroll sideways.
  override func tile() {
    super.tile()
    guard let doc = documentView else { return }
    let w = contentSize.width
    if doc.frame.width != w { doc.setFrameSize(NSSize(width: w, height: doc.frame.height)) }
  }
}

/// A scroller that draws only its knob, so it sits cleanly on the note's paper.
private final class KnobScroller: NSScroller {
  override class var isCompatibleWithOverlayScrollers: Bool { false }
  override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}
}

@MainActor
final class NoteWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate, NSMenuItemValidation {
  private(set) var note: Note
  let store: NoteStore
  let prefs: Prefs
  let texts: NoteTexts

  let paper = PaperView()
  let header = HeaderView()
  let scroll: NSScrollView
  let textView: NoteTextView
  let titleLabel = NSTextField(labelWithString: "")
  let closeButton = NSButton()
  let newButton = NSButton()
  let colorButton = NSButton()
  let grip = ResizeGrip()
  let aiButton = NSButton()
  let aiMenuButton = NSButton()
  let collapseButton = NSButton()
  let pinButton = NSButton()
  let bellButton = NSButton()
  let progressLabel = NSTextField(labelWithString: "")
  let spinner = NSProgressIndicator()
  let ai: AIEditor

  private var hovering = false
  private var deleting = false
  /// Frames of the other stickies, for snapping.
  var peers: () -> [NSRect] = { [] }

  init(note: Note, store: NoteStore = .shared, prefs: Prefs = .shared, texts: NoteTexts = .shared) {
    self.note = note
    self.store = store
    self.prefs = prefs
    self.texts = texts
    scroll = NoteScrollView()
    textView = texts.makeTextView(note.id, size: note.frame.size)
    ai = AIEditor(prefs: prefs)
    let w = NoteWindow(contentRect: note.frame, styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
    super.init(window: w)
    w.delegate = self
    ai.textView = textView
    textView.ai = ai
    ai.anchor = { [weak self] in
      guard let self else { return nil }
      return self.aiButton.isHidden ? self.header : self.aiButton
    }
    ai.willRun = { [weak self] in
      if self?.note.collapsed == true { self?.setCollapsed(false) }
    }
    ai.onBusyChange = { [weak self] in self?.updateChrome() }
    setUpWindow(w)
    setUpViews()
    apply()
    if note.collapsed { setCollapsed(true, animate: false) }
    NotificationCenter.default.addObserver(self, selector: #selector(prefsChanged), name: .prefsChanged, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(storeChanged), name: .notesChanged, object: store)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  var baseAttributes: [NSAttributedString.Key: Any] {
    noteAttributes(prefs.font)
  }

  // MARK: setup

  private func setUpWindow(_ w: NSWindow) {
    w.isOpaque = false
    w.backgroundColor = .clear
    w.hasShadow = true
    w.isMovableByWindowBackground = false
    w.isReleasedWhenClosed = false
    w.appearance = NSAppearance(named: .aqua)
    w.minSize = MIN_NOTE
    w.collectionBehavior = [.fullScreenNone, .managed]
    w.tabbingMode = .disallowed
    w.isExcludedFromWindowsMenu = false
    w.setFrame(note.frame, display: false)
  }

  private func symbol(_ b: NSButton, _ name: String, _ tip: String, _ action: Selector) {
    b.image = NSImage(systemSymbolName: name, accessibilityDescription: tip)?
      .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
    b.isBordered = false
    b.bezelStyle = .accessoryBarAction
    b.imagePosition = .imageOnly
    b.contentTintColor = NSColor.black.withAlphaComponent(0.55)
    b.toolTip = tip
    b.setAccessibilityLabel(tip)
    b.target = self
    b.action = action
    b.translatesAutoresizingMaskIntoConstraints = false
    b.widthAnchor.constraint(equalToConstant: 20).isActive = true
    b.heightAnchor.constraint(equalToConstant: 20).isActive = true
  }

  private func setUpViews() {
    symbol(closeButton, "xmark", "Close (keeps the note in All Notes)", #selector(performCloseNote(_:)))
    symbol(bellButton, "bell.fill", "Reminder", #selector(showReminder(_:)))
    symbol(newButton, "plus", "New Note (⌘N)", #selector(AppDelegate.newNote(_:)))
    newButton.target = nil
    symbol(colorButton, "paintpalette", "Note Color", #selector(showColorMenu(_:)))
    symbol(aiButton, "sparkles", "Refine with AI", #selector(runDefaultAI(_:)))
    symbol(aiMenuButton, "chevron.down", "AI Actions", #selector(showAIMenu(_:)))
    symbol(collapseButton, "rectangle.compress.vertical", "Collapse", #selector(toggleCollapsed(_:)))
    symbol(pinButton, "pin.slash", "Unpin from Desktop (keep in All Notes)", #selector(togglePinned(_:)))
    aiMenuButton.image = aiMenuButton.image?.withSymbolConfiguration(.init(pointSize: 8, weight: .bold))
    aiMenuButton.widthAnchor.constraint(equalToConstant: 12).isActive = true

    titleLabel.font = .systemFont(ofSize: 11, weight: .medium)
    titleLabel.textColor = NSColor.black.withAlphaComponent(0.65)
    titleLabel.lineBreakMode = .byTruncatingTail
    titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
    progressLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
    progressLabel.textColor = NSColor.black.withAlphaComponent(0.55)
    progressLabel.setContentHuggingPriority(.required, for: .horizontal)
    progressLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

    spinner.style = .spinning
    spinner.controlSize = .small
    spinner.isDisplayedWhenStopped = false
    spinner.appearance = NSAppearance(named: .aqua)

    let ai = NSStackView(views: [spinner, aiButton, aiMenuButton])
    ai.spacing = 0
    let row = NSStackView(views: [closeButton, titleLabel, progressLabel, bellButton, ai, colorButton, newButton, pinButton, collapseButton])
    row.orientation = .horizontal
    row.spacing = 4
    row.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
    row.translatesAutoresizingMaskIntoConstraints = false
    header.addSubview(row)
    header.onDoubleClick = { [weak self] in self?.toggleCollapsed(nil) }
    header.snap = { [weak self] f in
      guard let self, self.prefs.snapNotes else { return f.origin }
      return Snap.origin(for: f, screens: NSScreen.screens.map(\.visibleFrame), others: self.peers())
    }
    header.onDragEnd = { [weak self] in self?.trackFrame() }

    NoteTexts.configure(textView, prefs: prefs)
    textView.textContainerInset = NSSize(width: 8, height: 6)
    textView.delegate = self
    textView.extraMenu = { [weak self] in
      guard let self else { return [] }
      let color = NSMenuItem(title: "Note Color", action: nil, keyEquivalent: "")
      color.image = NSImage(systemSymbolName: "paintpalette", accessibilityDescription: nil)
      color.submenu = self.colorMenu()
      func item(_ title: String, _ icon: String, _ action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
        i.target = self
        return i
      }
      return self.ai.menuItems() + [
        item("Set Title…", "character.cursor.ibeam", #selector(self.renameNote(_:))),
        item("Suggest Title with AI", "wand.and.stars", #selector(self.suggestTitle(_:))),
        color,
        item(self.note.remind == nil ? "Remind Me…" : "Change Reminder…", "bell", #selector(self.showReminder(_:))),
        item(self.note.favorite ? "Remove from Favorites" : "Add to Favorites", self.note.favorite ? "star.slash" : "star", #selector(self.toggleFavorite(_:))),
        item("Unpin from Desktop", "pin.slash", #selector(self.togglePinned(_:))),
        item("Move to Trash", "trash", #selector(self.moveToTrash(_:))),
      ]
    }

    scroll.documentView = textView
    scroll.translatesAutoresizingMaskIntoConstraints = false
    header.translatesAutoresizingMaskIntoConstraints = false
    grip.translatesAutoresizingMaskIntoConstraints = false
    grip.toolTip = "Resize"
    grip.minSize = { [weak self] in self?.window?.minSize ?? MIN_NOTE }
    grip.onEnd = { [weak self] in self?.trackFrame() }

    paper.addSubview(scroll)
    paper.addSubview(header)
    paper.addSubview(grip)
    paper.onHover = { [weak self] in
      self?.hovering = $0
      self?.updateChrome()
    }
    window?.contentView = paper

    NSLayoutConstraint.activate([
      header.topAnchor.constraint(equalTo: paper.topAnchor),
      header.leadingAnchor.constraint(equalTo: paper.leadingAnchor),
      header.trailingAnchor.constraint(equalTo: paper.trailingAnchor),
      header.heightAnchor.constraint(equalToConstant: HEADER),
      row.leadingAnchor.constraint(equalTo: header.leadingAnchor),
      row.trailingAnchor.constraint(equalTo: header.trailingAnchor),
      row.centerYAnchor.constraint(equalTo: header.centerYAnchor),
      scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
      scroll.leadingAnchor.constraint(equalTo: paper.leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: paper.trailingAnchor),
      scroll.bottomAnchor.constraint(equalTo: paper.bottomAnchor),
      grip.trailingAnchor.constraint(equalTo: paper.trailingAnchor),
      grip.bottomAnchor.constraint(equalTo: paper.bottomAnchor),
      grip.widthAnchor.constraint(equalToConstant: 14),
      grip.heightAnchor.constraint(equalToConstant: 14),
    ])
  }

  // MARK: state

  /// Pushes the note's settings onto the window.
  func apply() {
    guard let w = window else { return }
    paper.fill = note.color.paper
    header.fill = note.color.header
    w.level = note.floating ? .floating : .normal
    w.alphaValue = note.translucent ? prefs.translucency : 1
    textView.isContinuousSpellCheckingEnabled = prefs.spellCheck
    collapseButton.image = NSImage(systemSymbolName: note.collapsed ? "rectangle.expand.vertical" : "rectangle.compress.vertical", accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
    collapseButton.toolTip = note.collapsed ? "Expand" : "Collapse"
    w.title = note.title
    grip.isHidden = note.collapsed
    updateChrome()
    w.invalidateShadow()
  }

  func updateChrome() {
    let busy = ai.busy
    let show = hovering || window?.isKeyWindow == true || busy
    for b in [closeButton, colorButton, newButton, pinButton, collapseButton] { b.isHidden = !show }
    bellButton.isHidden = note.remind == nil
    if let r = note.remind { bellButton.toolTip = "Reminder: \(r.formatted(date: .abbreviated, time: .shortened))" }
    let p = Checklist.progress(textView.string)
    progressLabel.stringValue = p.total > 0 ? "\(p.done)/\(p.total)" : ""
    progressLabel.isHidden = p.total == 0
    progressLabel.toolTip = p.total > 0 ? "\(p.done) of \(p.total) done" : nil
    let ai = prefs.showAIButton && !prefs.ai.enabledActions.isEmpty
    aiButton.isHidden = !(show && ai) || busy
    aiMenuButton.isHidden = !(show && ai) || busy
    // A typed title always shows; otherwise the first line shows only while collapsed.
    titleLabel.stringValue = note.collapsed ? note.title : note.name.trimmingCharacters(in: .whitespacesAndNewlines)
    busy ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
    if let p = prefs.ai.primary { aiButton.toolTip = "\(p.name) with AI (⌘R)" }
  }

  @objc private func prefsChanged() { apply() }

  /// Picks up changes made elsewhere, such as a new title or color set in All Notes, or typing there.
  @objc private func storeChanged() {
    guard !deleting, let n = store.note(note.id), n != note else { return }
    note = n
    apply()
  }

  func update(_ change: (inout Note) -> Void) {
    commitText()
    change(&note)
    note.modified = Date()
    store.update(note)
    apply()
  }

  /// Saves the live text now. Typing is otherwise saved shortly after it stops.
  func commitText() {
    texts.commit(note.id)
  }

  func textDidChange(_ notification: Notification) {
    let p = Checklist.progress(textView.string)
    let label = p.total > 0 ? "\(p.done)/\(p.total)" : ""
    if progressLabel.stringValue != label { updateChrome() }
  }

  // MARK: collapse

  func setCollapsed(_ c: Bool, animate: Bool = true) {
    guard let w = window else { return }
    note.collapsed = c
    let full = note.frame
    var f = w.frame
    if c {
      w.minSize = NSSize(width: MIN_NOTE.width, height: HEADER)
      w.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: HEADER)
      f.origin.y = f.maxY - HEADER
      f.size.height = HEADER
      scroll.isHidden = true
    }
    else {
      w.minSize = MIN_NOTE
      w.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
      f.size.height = max(full.height, MIN_NOTE.height)
      f.origin.y = w.frame.maxY - f.size.height
      scroll.isHidden = false
    }
    w.setFrame(f, display: true, animate: animate && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    store.update(note)
    apply()
  }

  private func trackFrame() {
    guard let w = window else { return }
    w.invalidateShadow()
    if note.collapsed {
      note.frame.origin.x = w.frame.origin.x
      note.frame.size.width = w.frame.width
      note.frame.origin.y = w.frame.maxY - note.frame.height
    }
    else {
      note.frame = w.frame
    }
    store.update(note)
  }

  func windowDidMove(_ n: Notification) { if !header.dragging { trackFrame() } }
  func windowDidEndLiveResize(_ n: Notification) { trackFrame() }
  func windowDidResize(_ n: Notification) { if window?.inLiveResize == false { trackFrame() } }
  func windowDidBecomeKey(_ n: Notification) { updateChrome() }
  func windowDidResignKey(_ n: Notification) {
    commitText()
    updateChrome()
  }

  // MARK: close

  /// ✕ takes the note off the desktop; it stays in All Notes. An empty note is simply deleted.
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    if deleting { return true }
    commitText()
    if note.isBlank { store.remove(note.id) } else { update { $0.pinned = false } }
    return false
  }

  /// Closes the window without deleting the note, for example when it is unpinned.
  /// The app delegate calls this; the note itself is unchanged.
  func teardown() {
    guard !deleting else { return }
    deleting = true
    ai.cancel()
    reminderPopover?.close()
    window?.close()
    texts.detach(textView)
  }

  // MARK: actions

  @objc func performCloseNote(_ sender: Any?) { window?.performClose(sender) }

  /// Takes the note off the desktop. It stays in All Notes, where it can be pinned again.
  @objc func togglePinned(_ sender: Any?) { update { $0.pinned.toggle() } }

  @objc func moveToTrash(_ sender: Any?) {
    commitText()
    if note.isBlank { return store.remove(note.id) }
    update {
      $0.trashed = Date()
      $0.pinned = false
    }
  }

  @objc func toggleFavorite(_ sender: Any?) { update { $0.favorite.toggle() } }

  @objc func runDefaultAI(_ sender: Any?) { ai.runDefault() }
  @objc func stopAI(_ sender: Any?) { ai.stop() }
  @objc func showAIMenu(_ sender: NSButton) { ai.showMenu(from: sender) }

  @objc func showNoteInAllNotes(_ sender: Any?) {
    commitText()
    NotebookWindow.show(select: note.id)
  }

  private var reminderPopover: NSPopover?

  @objc func showReminder(_ sender: Any?) {
    if note.collapsed { setCollapsed(false) }
    let pop = NSPopover()
    pop.behavior = .transient
    pop.contentViewController = NSHostingController(rootView: ReminderPicker(current: note.remind) { [weak self, weak pop] date in
      self?.update { $0.remind = date }
      pop?.close()
    })
    reminderPopover = pop
    let anchor: NSView = bellButton.isHidden ? (pinButton.isHidden ? header : pinButton) : bellButton
    pop.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
  }

  @objc func suggestTitle(_ sender: Any?) {
    commitText()
    let text = textView.string
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return NSSound.beep() }
    spinner.startAnimation(nil)
    Task { [weak self] in
      guard let self else { return }
      do {
        let title = try await AIEditor.suggestTitle(self.prefs, text: text)
        if !title.isEmpty { self.update { $0.name = title } }
      }
      catch {
        self.ai.fail(AIAction(name: "Suggest Title", icon: "wand.and.stars", prompt: ""), error.localizedDescription)
      }
      self.updateChrome()
    }
  }

  @objc func renameNote(_ sender: Any?) {
    guard let w = window else { return }
    if note.collapsed { setCollapsed(false) }
    let a = NSAlert()
    a.messageText = "Note Title"
    a.informativeText = "Leave it empty to use the first line of the note."
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
    field.stringValue = note.name
    field.placeholderString = note.firstLine.isEmpty ? "Untitled" : note.firstLine
    a.accessoryView = field
    a.addButton(withTitle: "Save")
    a.addButton(withTitle: "Cancel")
    a.window.initialFirstResponder = field
    a.beginSheetModal(for: w) { [weak self] r in
      guard let self, r == .alertFirstButtonReturn else { return }
      let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
      self.update { $0.name = name }
    }
  }

  @objc func toggleCollapsed(_ sender: Any?) { setCollapsed(!note.collapsed) }

  @objc func toggleFloating(_ sender: Any?) { update { $0.floating.toggle() } }

  @objc func toggleTranslucent(_ sender: Any?) { update { $0.translucent.toggle() } }

  /// The preset paper colors, with the current one checked.
  func colorMenu() -> NSMenu {
    let m = NSMenu()
    for (i, c) in NoteColor.allCases.enumerated() {
      let item = m.addItem(withTitle: c.title, action: #selector(setNoteColor(_:)), keyEquivalent: "")
      item.tag = i
      item.image = c.swatch()
      item.target = self
      item.state = c == note.color ? .on : .off
    }
    return m
  }

  @objc func showColorMenu(_ sender: NSButton) {
    colorMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
  }

  @objc func setNoteColor(_ sender: NSMenuItem) {
    guard NoteColor.allCases.indices.contains(sender.tag) else { return }
    update { $0.color = NoteColor.allCases[sender.tag] }
  }

  /// Stickies' "Use as Default": new notes copy this note's color and font.
  @objc func useAsDefault(_ sender: Any?) {
    prefs.defaultColor = note.color
    if let f = textView.font ?? textView.typingAttributes[.font] as? NSFont {
      prefs.fontName = f.fontName == NSFont.systemFont(ofSize: f.pointSize).fontName ? "" : f.fontName
      prefs.fontSize = Double(f.pointSize)
    }
  }

  @objc func exportNote(_ sender: Any?) {
    guard let w = window else { return }
    commitText()
    let panel = NSSavePanel()
    let formats: [(String, UTType)] = [("Plain Text", .plainText), ("Markdown", .markdownText), ("Rich Text (RTF)", .rtf), ("Rich Text with Attachments (RTFD)", .rtfd)]
    let pop = NSPopUpButton(frame: .zero, pullsDown: false)
    pop.addItems(withTitles: formats.map(\.0))
    let label = NSTextField(labelWithString: "Format:")
    let box = NSStackView(views: [label, pop])
    box.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
    panel.accessoryView = box
    panel.allowedContentTypes = [.plainText]
    panel.nameFieldStringValue = String(note.title.prefix(60))
    let handler = FormatHandler(panel: panel, types: formats.map(\.1))
    pop.target = handler
    pop.action = #selector(FormatHandler.changed(_:))
    let text = note.attributed
    let title = note.name.trimmingCharacters(in: .whitespacesAndNewlines)
    panel.beginSheetModal(for: w) { r in
      _ = handler
      guard r == .OK, let url = panel.url else { return }
      do { try Exporter.write(text, title: title, to: url, as: formats[pop.indexOfSelectedItem].1) }
      catch { NSAlert(error: error).runModal() }
    }
  }

  // MARK: menu validation

  func validateMenuItem(_ item: NSMenuItem) -> Bool {
    switch item.action {
    case #selector(setNoteColor(_:)):
      item.state = NoteColor.allCases.firstIndex(of: note.color) == item.tag ? .on : .off
    case #selector(toggleFloating(_:)):
      item.state = note.floating ? .on : .off
    case #selector(toggleTranslucent(_:)):
      item.state = note.translucent ? .on : .off
    case #selector(toggleCollapsed(_:)):
      item.title = note.collapsed ? "Expand" : "Collapse"
    case #selector(NoteTextView.runAIAction(_:)), #selector(runDefaultAI(_:)), #selector(showAIMenu(_:)):
      return !ai.busy && !prefs.ai.enabledActions.isEmpty
    case #selector(stopAI(_:)):
      return ai.busy
    case #selector(toggleFavorite(_:)):
      item.state = note.favorite ? .on : .off
    default:
      break
    }
    return true
  }
}

/// Keeps the save panel's file type in step with the format pop-up.
@MainActor
final class FormatHandler: NSObject {
  let panel: NSSavePanel
  let types: [UTType]

  init(panel: NSSavePanel, types: [UTType]) {
    self.panel = panel
    self.types = types
  }

  @objc func changed(_ sender: NSPopUpButton) {
    panel.allowedContentTypes = [types[sender.indexOfSelectedItem]]
  }
}

enum Exporter {
  /// `title` is used only by Markdown, as a heading.
  static func write(_ text: NSAttributedString, title: String = "", to url: URL, as type: UTType) throws {
    let range = NSRange(location: 0, length: text.length)
    switch type {
    case .markdownText:
      try MarkdownText.from(text, title: title).write(to: url, atomically: true, encoding: .utf8)
    case .rtfd:
      let wrapper = try text.fileWrapper(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
      try wrapper.write(to: url, options: .atomic, originalContentsURL: nil)
    case .rtf:
      try text.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]).write(to: url, options: .atomic)
    default:
      try text.string.write(to: url, atomically: true, encoding: .utf8)
    }
  }

  /// A note's title and text from a file. Markdown files keep their formatting and a `# Title`.
  @MainActor
  static func read(_ url: URL, font: NSFont) throws -> (title: String, text: NSAttributedString) {
    if ["md", "markdown"].contains(url.pathExtension.lowercased()) {
      return MarkdownText.toNote(try String(contentsOf: url, encoding: .utf8), font: font)
    }
    return ("", try NSAttributedString(url: url, options: [:], documentAttributes: nil))
  }
}
