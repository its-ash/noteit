import AppKit
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSMenuDelegate {
  let store = NoteStore.shared
  let prefs = Prefs.shared
  let texts = NoteTexts.shared
  /// One sticky window per pinned note.
  private var controllers: [NoteWindowController] = []
  private let aiMenu = NSMenu(title: "AI")
  /// NoteIt's icon in the menu bar, always shown.
  private var statusItem: NSStatusItem?

  // MARK: lifecycle

  func applicationDidFinishLaunching(_ n: Notification) {
    NSApp.mainMenu = buildMenu()
    setUpStatusItem()
    NSApp.servicesProvider = self
    NSUpdateDynamicServices()
    store.purgeTrash()
    store.clearPastReminders()
    if prefs.dailyBackups { Backups.daily(store) }
    if store.notes.isEmpty {
      newNote(text: NSAttributedString(string: WELCOME, attributes: noteAttributes(prefs.font)))
    }
    else {
      syncStickies()
      if controllers.isEmpty { NotebookWindow.show() }
    }
    NotificationCenter.default.addObserver(self, selector: #selector(prefsChanged), name: .prefsChanged, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(syncStickies), name: .notesChanged, object: store)
    Reminders.shared.reveal = { [weak self] id in self?.reveal(id) }
    Reminders.shared.start()
    Hotkey.set(prefs.quickCapture) { [weak self] in self?.quickNote() }
    Sync.shared.start()
  }

  @objc private func prefsChanged() {
    rebuildAIMenu()
    Hotkey.set(prefs.quickCapture) { [weak self] in self?.quickNote() }
  }

  /// ⌃⌥N from any app: a new sticky, ready for typing.
  func quickNote() {
    newNote(text: nil)
  }

  /// Brings a note forward: its sticky when it is on the desktop, otherwise All Notes.
  func reveal(_ id: UUID) {
    NSApp.activate()
    if let c = controller(for: id) {
      c.showWindow(nil)
      c.window?.makeKeyAndOrderFront(nil)
    }
    else {
      NotebookWindow.show(select: id)
    }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
    if store.notes.isEmpty { newNote(nil) }
    else if controllers.isEmpty { NotebookWindow.show() }
    else if !hasVisibleWindows { controllers.forEach { $0.showWindow(nil) } }
    return true
  }

  func applicationWillTerminate(_ n: Notification) {
    texts.commitAll()
    store.saveNow()
  }

  @objc func searchAllNotes(_ sender: Any?) { NotebookWindow.search() }

  @objc func backUpNow(_ sender: Any?) {
    if let url = Backups.backUp(store) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
  }

  @objc func restoreBackup(_ sender: Any?) {
    texts.commitAll()
    Backups.chooseAndRestore(store: store, texts: texts)
  }

  func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

  // MARK: menu bar

  /// NoteIt's only app icon: it has no Dock icon.
  private func setUpStatusItem() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let image = NSImage(systemSymbolName: "note.text", accessibilityDescription: "NoteIt")
    image?.isTemplate = true
    item.button?.image = image
    item.button?.toolTip = "NoteIt"
    let m = NSMenu()
    m.addItem(withTitle: "New Note", action: #selector(newNote(_:)), keyEquivalent: "").target = self
    m.addItem(withTitle: "New Note from Clipboard", action: #selector(newNoteFromClipboard(_:)), keyEquivalent: "").target = self
    m.addItem(withTitle: "All Notes", action: #selector(showNotebook(_:)), keyEquivalent: "").target = self
    m.addItem(withTitle: "Search All Notes", action: #selector(searchAllNotes(_:)), keyEquivalent: "").target = self
    m.addItem(.separator())
    m.addItem(withTitle: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: "").target = self
    m.addItem(.separator())
    m.addItem(withTitle: "Quit NoteIt", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
    item.menu = m
    statusItem = item
  }

  // MARK: notes

  /// Opens a sticky for every pinned note and closes stickies whose note was unpinned or deleted.
  @objc private func syncStickies() {
    let pinned = Set(store.notes.filter(\.onDesktop).map(\.id))
    let gone = controllers.filter { !pinned.contains($0.note.id) }
    controllers.removeAll { !pinned.contains($0.note.id) }
    gone.forEach { $0.teardown() }
    for n in store.notes where n.onDesktop && controller(for: n.id) == nil { open(n) }
  }

  private func controller(for id: UUID) -> NoteWindowController? {
    controllers.first { $0.note.id == id }
  }

  @discardableResult
  private func open(_ saved: Note) -> NoteWindowController {
    if let c = controller(for: saved.id) { return c }
    var note = saved
    note.frame = Self.onScreen(note.frame)
    let c = NoteWindowController(note: note, store: store, prefs: prefs, texts: texts)
    c.peers = { [weak self, weak c] in
      self?.controllers.compactMap { $0 === c ? nil : $0.window?.frame } ?? []
    }
    controllers.append(c)
    c.showWindow(nil)
    return c
  }

  /// Moves a saved frame back onto a screen when its display is gone (for example, an unplugged monitor).
  static func onScreen(_ f: CGRect, screens: [CGRect] = NSScreen.screens.map(\.visibleFrame)) -> CGRect {
    let header = CGRect(x: f.minX, y: f.maxY - HEADER, width: f.width, height: HEADER)
    guard !screens.contains(where: { $0.intersection(header).width >= 40 }), let v = screens.first else { return f }
    let w = min(f.width, v.width - 40), h = min(f.height, v.height - 40)
    return CGRect(x: v.minX + 40, y: v.maxY - 40 - h, width: w, height: h)
  }

  private var current: NoteWindowController? {
    (NSApp.keyWindow?.windowController ?? NSApp.mainWindow?.windowController) as? NoteWindowController
  }

  /// A frame for a new note: cascaded from the front note, or near the top left of the screen.
  private func nextFrame() -> CGRect {
    let size = CGSize(width: 260, height: 220)
    if let f = current?.window?.frame {
      return CGRect(x: f.minX + 24, y: f.maxY - 24 - size.height, width: size.width, height: size.height)
    }
    let v = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    let i = CGFloat(controllers.count % 8)
    return CGRect(x: v.minX + 40 + i * 24, y: v.maxY - 40 - i * 24 - size.height, width: size.width, height: size.height)
  }

  @discardableResult
  func newNote(text: NSAttributedString? = nil, title: String = "") -> NoteWindowController {
    var n = Note()
    n.name = title
    n.color = prefs.defaultColor
    n.floating = prefs.newNotesFloat
    n.frame = nextFrame()
    if let text { n.attributed = text }
    store.add(n)
    let c = open(n)  // usually already opened by syncStickies
    NSApp.activate()
    c.window?.makeKeyAndOrderFront(nil)
    c.window?.makeFirstResponder(c.textView)
    if text == nil { c.textView.typingAttributes = c.baseAttributes }
    return c
  }

  @objc func newNote(_ sender: Any?) { newNote(text: nil) }

  @objc func newNoteFromClipboard(_ sender: Any?) {
    let pb = NSPasteboard.general
    let text = (pb.readObjects(forClasses: [NSAttributedString.self]) as? [NSAttributedString])?.first
      ?? pb.string(forType: .string).map { NSAttributedString(string: $0, attributes: noteAttributes(prefs.font)) }
    guard let text, text.length > 0 else { return NSSound.beep() }
    newNote(text: text)
  }

  /// Services menu: "Make New NoteIt Note" from text selected in any app.
  @objc func makeNoteFromSelection(_ pb: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
    let text = (pb.readObjects(forClasses: [NSAttributedString.self]) as? [NSAttributedString])?.first
      ?? pb.string(forType: .string).map { NSAttributedString(string: $0, attributes: noteAttributes(prefs.font)) }
    guard let text, text.length > 0 else {
      error.pointee = "No text was selected." as NSString
      return
    }
    newNote(text: text)
  }

  @objc func importText(_ sender: Any?) {
    let p = NSOpenPanel()
    p.allowedContentTypes = [.plainText, .markdownText, .rtf, .rtfd, .text]
    p.allowsMultipleSelection = true
    p.prompt = "Import"
    guard p.runModal() == .OK else { return }
    for url in p.urls {
      do {
        let (title, text) = try Exporter.read(url, font: prefs.font)
        newNote(text: text, title: title)
      }
      catch { NSAlert(error: error).runModal() }
    }
  }

  @objc func exportAll(_ sender: Any?) { exportAll(as: .rtfd) }
  @objc func exportAllMarkdown(_ sender: Any?) { exportAll(as: .markdownText) }

  /// Saves each note that isn't in the Trash as its own file in a folder.
  private func exportAll(as type: UTType) {
    texts.commitAll()
    let p = NSOpenPanel()
    p.canChooseDirectories = true
    p.canChooseFiles = false
    p.canCreateDirectories = true
    p.prompt = "Export"
    p.message = type == .markdownText ? "Choose a folder. Each note is saved as a Markdown file." : "Choose a folder. Each note is saved as a rich text file."
    guard p.runModal() == .OK, let dir = p.url else { return }
    var used = Set<String>()
    let ext = type == .markdownText ? "md" : "rtfd"
    for n in store.notes where n.trashed == nil {
      var name = n.title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
      name = String(name.prefix(60))
      var unique = name
      var i = 2
      while used.contains(unique) {
        unique = "\(name) \(i)"
        i += 1
      }
      used.insert(unique)
      do { try Exporter.write(n.attributed, title: n.name.trimmingCharacters(in: .whitespaces), to: dir.appending(path: "\(unique).\(ext)"), as: type) }
      catch { NSAlert(error: error).runModal() }
    }
    NSWorkspace.shared.activateFileViewerSelecting([dir])
  }

  // MARK: arrange

  private enum Order: Int { case color, created, modified, title }

  @objc func arrangeBy(_ sender: NSMenuItem) {
    guard let order = Order(rawValue: sender.tag) else { return }
    let colors = NoteColor.allCases
    let sorted = controllers.sorted { a, b in
      switch order {
      case .color: colors.firstIndex(of: a.note.color)! < colors.firstIndex(of: b.note.color)!
      case .created: a.note.created < b.note.created
      case .modified: a.note.modified > b.note.modified
      case .title: a.note.title.localizedStandardCompare(b.note.title) == .orderedAscending
      }
    }
    guard let v = NSScreen.main?.visibleFrame else { return }
    for (i, c) in sorted.enumerated() {
      guard let w = c.window else { continue }
      let step = CGFloat(i) * HEADER
      let top = v.maxY - 20 - step
      var f = w.frame
      f.origin = CGPoint(x: v.minX + 20 + step / 2, y: top - f.height)
      w.setFrame(f, display: true, animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
      w.orderFront(nil)
    }
  }

  @objc func showAllNotes(_ sender: Any?) {
    NSApp.activate()
    controllers.forEach { $0.window?.orderFront(nil) }
  }

  /// The All Notes window, opened on the front sticky's note when there is one.
  @objc func showNotebook(_ sender: Any?) {
    current?.commitText()
    NotebookWindow.show(select: current?.note.id)
  }

  @objc func showSettings(_ sender: Any?) { SettingsWindow.show() }
  @objc func showAISettings(_ sender: Any?) { SettingsWindow.show(tab: .ai) }

  func validateMenuItem(_ item: NSMenuItem) -> Bool {
    switch item.action {
    case #selector(arrangeBy(_:)), #selector(showAllNotes(_:)): !controllers.isEmpty
    case #selector(exportAll(_:)), #selector(exportAllMarkdown(_:)): !store.notes.isEmpty
    default: true
    }
  }

  // MARK: menu

  private func buildMenu() -> NSMenu {
    let main = NSMenu()

    let app = submenu(main, "NoteIt")
    app.addItem(withTitle: "About NoteIt", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
    app.addItem(.separator())
    app.addItem(withTitle: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",")
    app.addItem(.separator())
    let services = NSMenu()
    app.addItem(withTitle: "Services", action: nil, keyEquivalent: "").submenu = services
    NSApp.servicesMenu = services
    app.addItem(.separator())
    app.addItem(withTitle: "Hide NoteIt", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h").keyEquivalentModifierMask = [.command, .option]
    app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
    app.addItem(.separator())
    app.addItem(withTitle: "Quit NoteIt", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

    let file = submenu(main, "File")
    file.addItem(withTitle: "New Note", action: #selector(newNote(_:)), keyEquivalent: "n")
    file.addItem(withTitle: "New Note from Clipboard", action: #selector(newNoteFromClipboard(_:)), keyEquivalent: "N")
    file.addItem(.separator())
    file.addItem(withTitle: "Close", action: #selector(NoteWindowController.performCloseNote(_:)), keyEquivalent: "w")
    file.addItem(withTitle: "Move to Trash", action: #selector(NoteWindowController.moveToTrash(_:)), keyEquivalent: "")
    file.addItem(.separator())
    file.addItem(withTitle: "Set Title…", action: #selector(NoteWindowController.renameNote(_:)), keyEquivalent: "r").keyEquivalentModifierMask = [.command, .option]
    file.addItem(withTitle: "Suggest Title with AI", action: #selector(NoteWindowController.suggestTitle(_:)), keyEquivalent: "")
    file.addItem(withTitle: "Remind Me…", action: #selector(NoteWindowController.showReminder(_:)), keyEquivalent: "")
    file.addItem(withTitle: "Add to Favorites", action: #selector(NoteWindowController.toggleFavorite(_:)), keyEquivalent: "")
    file.addItem(withTitle: "Show in All Notes", action: #selector(NoteWindowController.showNoteInAllNotes(_:)), keyEquivalent: "")
    file.addItem(.separator())
    file.addItem(withTitle: "Import Text…", action: #selector(importText(_:)), keyEquivalent: "")
    file.addItem(withTitle: "Export Text…", action: #selector(NoteWindowController.exportNote(_:)), keyEquivalent: "e").keyEquivalentModifierMask = [.command, .shift]
    file.addItem(withTitle: "Export All Notes…", action: #selector(exportAll(_:)), keyEquivalent: "")
    file.addItem(withTitle: "Export All as Markdown…", action: #selector(exportAllMarkdown(_:)), keyEquivalent: "")
    file.addItem(.separator())
    file.addItem(withTitle: "Back Up Now", action: #selector(backUpNow(_:)), keyEquivalent: "")
    file.addItem(withTitle: "Restore from Backup…", action: #selector(restoreBackup(_:)), keyEquivalent: "")
    file.addItem(.separator())
    file.addItem(withTitle: "Page Setup…", action: #selector(NSApplication.runPageLayout(_:)), keyEquivalent: "P")
    file.addItem(withTitle: "Print…", action: #selector(NSView.printView(_:)), keyEquivalent: "p")

    let edit = submenu(main, "Edit")
    edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
    edit.addItem(.separator())
    edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    edit.addItem(withTitle: "Paste and Match Style", action: #selector(NSTextView.pasteAsPlainText(_:)), keyEquivalent: "V").keyEquivalentModifierMask = [.command, .option, .shift]
    edit.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
    edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    edit.addItem(.separator())
    let find = submenu(edit, "Find")
    findItem(find, "Find…", .showFindInterface, "f", [.command])
    findItem(find, "Find and Replace…", .showReplaceInterface, "", [.command])
    findItem(find, "Find Next", .nextMatch, "g", [.command])
    findItem(find, "Find Previous", .previousMatch, "G", [.command])
    findItem(find, "Use Selection for Find", .setSearchString, "e", [.command])
    find.addItem(withTitle: "Jump to Selection", action: #selector(NSResponder.centerSelectionInVisibleArea(_:)), keyEquivalent: "j")
    let spelling = submenu(edit, "Spelling and Grammar")
    spelling.addItem(withTitle: "Show Spelling and Grammar", action: #selector(NSText.showGuessPanel(_:)), keyEquivalent: ":")
    spelling.addItem(withTitle: "Check Document Now", action: #selector(NSText.checkSpelling(_:)), keyEquivalent: ";")
    spelling.addItem(.separator())
    spelling.addItem(withTitle: "Check Spelling While Typing", action: #selector(NSTextView.toggleContinuousSpellChecking(_:)), keyEquivalent: "")
    spelling.addItem(withTitle: "Check Grammar With Spelling", action: #selector(NSTextView.toggleGrammarChecking(_:)), keyEquivalent: "")
    spelling.addItem(withTitle: "Correct Spelling Automatically", action: #selector(NSTextView.toggleAutomaticSpellingCorrection(_:)), keyEquivalent: "")
    let subs = submenu(edit, "Substitutions")
    subs.addItem(withTitle: "Show Substitutions", action: #selector(NSTextView.orderFrontSubstitutionsPanel(_:)), keyEquivalent: "")
    subs.addItem(.separator())
    subs.addItem(withTitle: "Smart Copy/Paste", action: #selector(NSTextView.toggleSmartInsertDelete(_:)), keyEquivalent: "")
    subs.addItem(withTitle: "Smart Quotes", action: #selector(NSTextView.toggleAutomaticQuoteSubstitution(_:)), keyEquivalent: "")
    subs.addItem(withTitle: "Smart Dashes", action: #selector(NSTextView.toggleAutomaticDashSubstitution(_:)), keyEquivalent: "")
    subs.addItem(withTitle: "Smart Links", action: #selector(NSTextView.toggleAutomaticLinkDetection(_:)), keyEquivalent: "")
    subs.addItem(withTitle: "Data Detectors", action: #selector(NSTextView.toggleAutomaticDataDetection(_:)), keyEquivalent: "")
    subs.addItem(withTitle: "Text Replacement", action: #selector(NSTextView.toggleAutomaticTextReplacement(_:)), keyEquivalent: "")
    let transform = submenu(edit, "Transformations")
    transform.addItem(withTitle: "Make Upper Case", action: #selector(NSResponder.uppercaseWord(_:)), keyEquivalent: "")
    transform.addItem(withTitle: "Make Lower Case", action: #selector(NSResponder.lowercaseWord(_:)), keyEquivalent: "")
    transform.addItem(withTitle: "Capitalize", action: #selector(NSResponder.capitalizeWord(_:)), keyEquivalent: "")
    let speech = submenu(edit, "Speech")
    speech.addItem(withTitle: "Start Speaking", action: #selector(NSTextView.startSpeaking(_:)), keyEquivalent: "")
    speech.addItem(withTitle: "Stop Speaking", action: #selector(NSTextView.stopSpeaking(_:)), keyEquivalent: "")

    let format = submenu(main, "Format")
    let font = submenu(format, "Font")
    font.addItem(withTitle: "Show Fonts", action: #selector(NSFontManager.orderFrontFontPanel(_:)), keyEquivalent: "t").target = NSFontManager.shared
    fontItem(font, "Bold", #selector(NSFontManager.addFontTrait(_:)), "b", tag: Int(NSFontTraitMask.boldFontMask.rawValue))
    fontItem(font, "Italic", #selector(NSFontManager.addFontTrait(_:)), "i", tag: Int(NSFontTraitMask.italicFontMask.rawValue))
    font.addItem(withTitle: "Underline", action: #selector(NSText.underline(_:)), keyEquivalent: "u")
    font.addItem(.separator())
    fontItem(font, "Bigger", #selector(NSFontManager.modifyFont(_:)), "+", tag: Int(NSFontAction.sizeUpFontAction.rawValue))
    fontItem(font, "Smaller", #selector(NSFontManager.modifyFont(_:)), "-", tag: Int(NSFontAction.sizeDownFontAction.rawValue))
    font.addItem(.separator())
    font.addItem(withTitle: "Show Colors", action: #selector(NSApplication.orderFrontColorPanel(_:)), keyEquivalent: "C")
    font.addItem(.separator())
    font.addItem(withTitle: "Copy Style", action: #selector(NSText.copyFont(_:)), keyEquivalent: "c").keyEquivalentModifierMask = [.command, .option]
    font.addItem(withTitle: "Paste Style", action: #selector(NSText.pasteFont(_:)), keyEquivalent: "v").keyEquivalentModifierMask = [.command, .option]
    let text = submenu(format, "Text")
    text.addItem(withTitle: "Align Left", action: #selector(NSText.alignLeft(_:)), keyEquivalent: "{")
    text.addItem(withTitle: "Center", action: #selector(NSText.alignCenter(_:)), keyEquivalent: "|")
    text.addItem(withTitle: "Justify", action: #selector(NSTextView.alignJustified(_:)), keyEquivalent: "")
    text.addItem(withTitle: "Align Right", action: #selector(NSText.alignRight(_:)), keyEquivalent: "}")
    text.addItem(.separator())
    text.addItem(withTitle: "Show Ruler", action: #selector(NSText.toggleRuler(_:)), keyEquivalent: "")
    text.addItem(withTitle: "Lists…", action: #selector(NSTextView.orderFrontListPanel(_:)), keyEquivalent: "")
    text.addItem(withTitle: "Checklist", action: #selector(NoteTextView.toggleChecklist(_:)), keyEquivalent: "L")
    format.addItem(.separator())
    format.addItem(withTitle: "Use as Default", action: #selector(NoteWindowController.useAsDefault(_:)), keyEquivalent: "")

    let color = submenu(main, "Color")
    for (i, c) in NoteColor.allCases.enumerated() {
      let item = color.addItem(withTitle: c.title, action: #selector(NoteWindowController.setNoteColor(_:)), keyEquivalent: "\(i + 1)")
      item.tag = i
      item.image = c.swatch()
    }

    aiMenu.delegate = self
    main.addItem(withTitle: "AI", action: nil, keyEquivalent: "").submenu = aiMenu
    rebuildAIMenu()

    let window = submenu(main, "Window")
    window.addItem(withTitle: "Float on Top", action: #selector(NoteWindowController.toggleFloating(_:)), keyEquivalent: "f").keyEquivalentModifierMask = [.command, .option]
    window.addItem(withTitle: "Translucent", action: #selector(NoteWindowController.toggleTranslucent(_:)), keyEquivalent: "t").keyEquivalentModifierMask = [.command, .option]
    window.addItem(withTitle: "Collapse", action: #selector(NoteWindowController.toggleCollapsed(_:)), keyEquivalent: "m")
    window.addItem(withTitle: "Unpin from Desktop", action: #selector(NoteWindowController.togglePinned(_:)), keyEquivalent: "p").keyEquivalentModifierMask = [.command, .option]
    window.addItem(.separator())
    window.addItem(withTitle: "All Notes", action: #selector(showNotebook(_:)), keyEquivalent: "0")
    window.addItem(withTitle: "Search All Notes", action: #selector(searchAllNotes(_:)), keyEquivalent: "F")
    window.addItem(.separator())
    let arrange = submenu(window, "Arrange By")
    for (i, t) in ["Color", "Date Created", "Date Modified", "Title"].enumerated() {
      arrange.addItem(withTitle: t, action: #selector(arrangeBy(_:)), keyEquivalent: "").tag = i
    }
    window.addItem(.separator())
    window.addItem(withTitle: "Bring All to Front", action: #selector(showAllNotes(_:)), keyEquivalent: "")
    NSApp.windowsMenu = window

    let help = submenu(main, "Help")
    NSApp.helpMenu = help
    return main
  }

  @objc private func rebuildAIMenu() {
    aiMenu.removeAllItems()
    let actions = prefs.ai.enabledActions
    if let p = prefs.ai.primary {
      let i = AIEditor.item(p, target: nil)
      i.action = #selector(NoteTextView.runDefaultAI(_:))
      i.keyEquivalent = "r"
      aiMenu.addItem(i)
      aiMenu.addItem(.separator())
    }
    for (n, a) in actions.enumerated() {
      let i = AIEditor.item(a, target: nil)
      if n < 9 {
        i.keyEquivalent = "\(n + 1)"
        i.keyEquivalentModifierMask = [.command, .control]
      }
      aiMenu.addItem(i)
    }
    aiMenu.addItem(.separator())
    aiMenu.addItem(withTitle: "Stop", action: #selector(NoteTextView.stopAI(_:)), keyEquivalent: ".")
    aiMenu.addItem(.separator())
    let provider = NSMenuItem(title: "Using \(ProviderPreset.find(prefs.ai.provider).name) · \(prefs.ai.model.isEmpty ? "no model" : prefs.ai.model)", action: nil, keyEquivalent: "")
    provider.isEnabled = false
    aiMenu.addItem(provider)
    aiMenu.addItem(withTitle: "AI Settings…", action: #selector(showAISettings(_:)), keyEquivalent: "")
  }

  // MARK: menu helpers

  @discardableResult
  private func submenu(_ parent: NSMenu, _ title: String) -> NSMenu {
    let m = NSMenu(title: title)
    parent.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = m
    return m
  }

  private func findItem(_ m: NSMenu, _ title: String, _ action: NSTextFinder.Action, _ key: String, _ mods: NSEvent.ModifierFlags) {
    let i = m.addItem(withTitle: title, action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: key)
    i.tag = action.rawValue
    i.keyEquivalentModifierMask = mods
  }

  private func fontItem(_ m: NSMenu, _ title: String, _ action: Selector, _ key: String, tag: Int) {
    let i = m.addItem(withTitle: title, action: action, keyEquivalent: key)
    i.target = NSFontManager.shared
    i.tag = tag
  }
}

private let WELCOME = """
Welcome to NoteIt

Notes stay on your desktop, just like Stickies. Write here, then click ✨ (or press ⌘R) and AI refines the note. Select some text first to change only that part.

Click the chevron next to ✨ for more actions: fix grammar, shorten, summarize, make a checklist, change the tone, or translate. ⌘Z undoes any AI edit.

Every note is also listed in All Notes (⌘0). Give a note a title with ⌥⌘R. Click the pin to take a note off the desktop; it stays in All Notes until you pin it again.

Pick your AI provider and model in NoteIt → Settings → AI. Router, Anthropic, OpenAI, OpenRouter, Gemini, Groq, Ollama, LM Studio, or any OpenAI-compatible server.
"""
