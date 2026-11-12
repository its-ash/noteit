import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// What the sidebar shows.
enum Scope: Hashable {
  case all, favorites, desktop, reminders, archive, trash
  case notebook(String)
  case tag(String)

  var title: String {
    switch self {
    case .all: "All Notes"
    case .favorites: "Favorites"
    case .desktop: "On Desktop"
    case .reminders: "Reminders"
    case .archive: "Archive"
    case .trash: "Trash"
    case .notebook(let n): n
    case .tag(let t): "#\(t)"
    }
  }
}

enum NoteSort: String, CaseIterable {
  case edited, newest, title, color

  var title: String {
    switch self {
    case .edited: "Date Edited"
    case .newest: "Date Created"
    case .title: "Title"
    case .color: "Color"
    }
  }
}

/// One line in the note list. Built once per change, so the list never decodes RTFD while drawing.
struct NoteRow: Identifiable, Equatable {
  let id: UUID
  let title: String
  let preview: String
  let plain: String
  let color: NoteColor
  let pinned: Bool
  let favorite: Bool
  let archived: Bool
  let trashed: Date?
  let remind: Date?
  let notebook: String
  let tags: [String]
  let done: Int
  let total: Int
  let created: Date
  let modified: Date

  var isLive: Bool { trashed == nil && !archived }
}

/// State behind the All Notes window.
@MainActor
@Observable
final class Notebook {
  static let shared = Notebook()

  @ObservationIgnored let store: NoteStore
  @ObservationIgnored let texts: NoteTexts
  @ObservationIgnored let prefs: Prefs
  @ObservationIgnored let defaults: UserDefaults
  @ObservationIgnored let ai: AIEditor
  @ObservationIgnored weak var editor: NoteTextView?
  @ObservationIgnored private let smartSearch = SmartSearch()
  @ObservationIgnored private var plainCache: [UUID: (Date, String)] = [:]

  private(set) var rows: [NoteRow] = []
  var scope: Scope = .all
  var selection: UUID?
  var query = ""
  var aiBusy = false
  /// Bumped to move keyboard focus to the search field.
  var searchFocus = 0
  var smart: Bool { didSet { defaults.set(smart, forKey: "Notebook.smart") } }
  var sort: NoteSort { didSet { defaults.set(sort.rawValue, forKey: "Notebook.sort") } }
  var favoritesFirst: Bool { didSet { defaults.set(favoritesFirst, forKey: "Notebook.favoritesFirst") } }
  /// Notebooks made here that have no notes yet.
  var emptyNotebooks: [String] { didSet { defaults.set(emptyNotebooks, forKey: "Notebook.notebooks") } }

  init(store: NoteStore = .shared, texts: NoteTexts = .shared, prefs: Prefs = .shared, defaults: UserDefaults = .standard) {
    self.store = store
    self.texts = texts
    self.prefs = prefs
    self.defaults = defaults
    ai = AIEditor(prefs: prefs)
    smart = defaults.object(forKey: "Notebook.smart") as? Bool ?? true
    sort = NoteSort(rawValue: defaults.string(forKey: "Notebook.sort") ?? "") ?? .edited
    favoritesFirst = defaults.object(forKey: "Notebook.favoritesFirst") as? Bool ?? true
    emptyNotebooks = defaults.stringArray(forKey: "Notebook.notebooks") ?? []
    ai.onBusyChange = { [weak self] in self?.aiBusy = self?.ai.busy ?? false }
    ai.anchor = { [weak self] in self?.editor?.enclosingScrollView }
    refresh()
    NotificationCenter.default.addObserver(forName: .notesChanged, object: store, queue: nil) { [weak self] _ in
      MainActor.assumeIsolated { self?.refresh() }
    }
  }

  // MARK: rows

  func refresh() {
    var cache: [UUID: (Date, String)] = [:]
    let new = store.notes.map { n in
      let plain = plainCache[n.id].flatMap { $0.0 == n.modified ? $0.1 : nil } ?? n.plain
      cache[n.id] = (n.modified, plain)
      let named = !n.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      let first = Note.firstLine(of: plain)
      let body = named ? plain : String(plain.drop { $0 == "\n" || $0 == " " }.dropFirst(first.count))
      let preview = Note.firstLine(of: body)
      let p = Checklist.progress(plain)
      return NoteRow(
        id: n.id, title: Note.title(name: n.name, plain: plain), preview: preview, plain: plain, color: n.color,
        pinned: n.pinned, favorite: n.favorite, archived: n.archived, trashed: n.trashed, remind: n.remind,
        notebook: n.notebook, tags: Note.tags(in: plain), done: p.done, total: p.total, created: n.created, modified: n.modified
      )
    }
    plainCache = cache
    if new != rows { rows = new }
    let used = Set(rows.map(\.notebook))
    if emptyNotebooks.contains(where: used.contains) { emptyNotebooks.removeAll(where: used.contains) }
    if let s = selection, !visible.contains(where: { $0.id == s }) { selection = visible.first?.id }
  }

  func inScope(_ r: NoteRow, _ s: Scope) -> Bool {
    switch s {
    case .all: r.isLive
    case .favorites: r.isLive && r.favorite
    case .desktop: r.isLive && r.pinned
    case .reminders: r.trashed == nil && r.remind != nil
    case .archive: r.trashed == nil && r.archived
    case .trash: r.trashed != nil
    case .notebook(let n): r.isLive && r.notebook == n
    case .tag(let t): r.isLive && r.tags.contains(t)
    }
  }

  func count(_ s: Scope) -> Int { rows.filter { inScope($0, s) }.count }

  var notebooks: [String] {
    Array(Set(rows.filter { $0.trashed == nil }.map(\.notebook)).subtracting([""]).union(emptyNotebooks))
      .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
  }

  var tags: [(name: String, count: Int)] {
    var c: [String: Int] = [:]
    for r in rows where r.isLive { for t in r.tags { c[t, default: 0] += 1 } }
    return c.map { ($0.key, $0.value) }.sorted { $0.name < $1.name }
  }

  private func ordered(_ a: NoteRow, _ b: NoteRow) -> Bool {
    if favoritesFirst, a.favorite != b.favorite { return a.favorite }
    switch sort {
    case .edited: return a.modified > b.modified
    case .newest: return a.created > b.created
    case .title: return a.title.localizedStandardCompare(b.title) == .orderedAscending
    case .color:
      let cs = NoteColor.allCases
      let (ia, ib) = (cs.firstIndex(of: a.color) ?? 0, cs.firstIndex(of: b.color) ?? 0)
      return ia == ib ? a.modified > b.modified : ia < ib
    }
  }

  /// The notes in the list: the scope, filtered by search, sorted. Word matches come first, then notes close in meaning.
  var visible: [NoteRow] {
    let inside = rows.filter { inScope($0, scope) }
    let q = query.trimmingCharacters(in: .whitespaces)
    guard !q.isEmpty else { return inside.sorted(by: ordered) }
    let words = inside.filter { $0.title.localizedStandardContains(q) || $0.plain.localizedStandardContains(q) }
    guard smart, q.count >= 3 else { return words.sorted(by: ordered) }
    let hit = Set(words.map(\.id))
    let rest = inside.filter { !hit.contains($0.id) }
    let scores = smartSearch.scores(q, notes: rest.map { ($0.id, $0.modified, $0.title + "\n" + $0.plain) })
    let close = rest.filter { (scores[$0.id] ?? 0) >= SmartSearch.minScore }.sorted { (scores[$0.id] ?? 0) > (scores[$1.id] ?? 0) }
    return words.sorted(by: ordered) + close
  }

  func note(_ id: UUID) -> Note? { store.note(id) }

  // MARK: changes

  func change(_ id: UUID, _ edit: (inout Note) -> Void) {
    texts.commit(id)
    guard var n = store.note(id) else { return }
    edit(&n)
    n.modified = Date()
    if !n.isLive { n.pinned = false }
    store.update(n)
  }

  /// A new note in the current notebook (or favorites), shown only here until it is pinned.
  func newNote() {
    var n = Note()
    n.pinned = scope == .desktop
    n.color = prefs.defaultColor
    let v = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    n.frame = CGRect(x: v.midX - 130, y: v.midY - 110, width: 260, height: 220)
    switch scope {
    case .notebook(let name): n.notebook = name
    case .favorites: n.favorite = true
    case .all, .desktop: break
    default: scope = .all
    }
    query = ""
    store.add(n)
    selection = n.id
    DispatchQueue.main.async { [weak self] in self?.focusEditor() }
  }

  func focusEditor() {
    guard let e = editor else { return }
    e.window?.makeFirstResponder(e)
  }

  func trash(_ id: UUID) {
    if let n = store.note(id), n.isBlank { return store.remove(id) }
    change(id) { $0.trashed = Date() }
  }

  func restore(_ id: UUID) { change(id) { $0.trashed = nil } }

  func deleteForever(_ id: UUID) { store.remove(id) }

  func emptyTrash() {
    for r in rows where r.trashed != nil { store.remove(r.id) }
  }

  func addNotebook(_ name: String) -> String? {
    let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !n.isEmpty else { return nil }
    if !notebooks.contains(n) { emptyNotebooks.append(n) }
    scope = .notebook(n)
    return n
  }

  func renameNotebook(_ old: String, to new: String) {
    let n = new.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !n.isEmpty, n != old else { return }
    for r in rows where r.notebook == old { change(r.id) { $0.notebook = n } }
    emptyNotebooks = emptyNotebooks.map { $0 == old ? n : $0 }
    if scope == .notebook(old) { scope = .notebook(n) }
  }

  /// Removes a notebook. Its notes stay, without a notebook.
  func deleteNotebook(_ name: String) {
    for r in rows where r.notebook == name { change(r.id) { $0.notebook = "" } }
    emptyNotebooks.removeAll { $0 == name }
    if scope == .notebook(name) { scope = .all }
  }

  /// Selects a note and a scope that shows it.
  func reveal(_ id: UUID) {
    guard let r = rows.first(where: { $0.id == id }) else { return }
    query = ""
    if !inScope(r, scope) { scope = r.trashed != nil ? .trash : (r.archived ? .archive : .all) }
    selection = id
  }

  // MARK: AI

  func suggestTitle(_ id: UUID) async throws {
    texts.commit(id)
    guard let n = store.note(id), !n.plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    let title = try await AIEditor.suggestTitle(prefs, text: n.plain)
    if !title.isEmpty { change(id) { $0.name = title } }
  }

  /// Notes as context for a question: newest first, trimmed to fit.
  func askContext(limit: Int = 60_000) -> String {
    var out = ""
    for r in rows.filter(\.isLive).sorted(by: { $0.modified > $1.modified }) {
      let block = "## \(r.title)\nEdited \(r.modified.formatted(date: .abbreviated, time: .omitted))\(r.notebook.isEmpty ? "" : " · Notebook: \(r.notebook)")\n\(r.plain.prefix(4000))\n\n"
      if out.count + block.count > limit { break }
      out += block
    }
    return out
  }
}

// MARK: window

/// The All Notes window.
@MainActor
final class NotebookWindow: NSWindowController, NSWindowDelegate {
  private static var shared: NotebookWindow?

  static func show(select id: UUID? = nil) {
    let c = shared ?? NotebookWindow()
    shared = c
    let m = Notebook.shared
    if let id { m.reveal(id) }
    else if m.selection == nil { m.selection = m.visible.first?.id }
    NSApp.activate()
    c.showWindow(nil)
    c.window?.makeKeyAndOrderFront(nil)
  }

  static func search() {
    show()
    Notebook.shared.searchFocus += 1
  }

  private init() {
    let host = NSHostingController(rootView: NotebookView(model: .shared))
    let w = NSWindow(contentViewController: host)
    w.title = "All Notes"
    w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
    w.isReleasedWhenClosed = false
    w.setContentSize(NSSize(width: 1080, height: 640))
    w.minSize = NSSize(width: 760, height: 420)
    w.tabbingMode = .disallowed
    w.center()
    w.setFrameAutosaveName("NoteIt.AllNotes")
    super.init(window: w)
    w.delegate = self
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  /// File → Close (⌘W) sends this to the key window's controller.
  @objc func performCloseNote(_ sender: Any?) { window?.performClose(sender) }

  /// File → Move to Trash (⌘⌫) when All Notes is in front.
  @objc func moveToTrash(_ sender: Any?) {
    guard let id = Notebook.shared.selection else { return NSSound.beep() }
    Notebook.shared.trash(id)
  }

  func windowWillClose(_ n: Notification) {
    Notebook.shared.texts.commitAll()
    Notebook.shared.ai.cancel()
  }
}

// MARK: views

private struct NotebookView: View {
  @Bindable var model: Notebook
  @State private var confirm: Confirm?
  @State private var asking = false

  enum Confirm: Identifiable {
    case delete(UUID), emptyTrash
    var id: String {
      switch self {
      case .delete(let u): u.uuidString
      case .emptyTrash: "empty"
      }
    }
  }

  var body: some View {
    NavigationSplitView {
      SidebarView(model: model, onEmptyTrash: { confirm = .emptyTrash })
        .navigationSplitViewColumnWidth(min: 170, ideal: 200, max: 280)
    } content: {
      NoteListView(model: model, asking: $asking, onDelete: ask)
        .navigationSplitViewColumnWidth(min: 240, ideal: 290, max: 440)
    } detail: {
      if let id = model.selection, let n = model.note(id) {
        NoteDetail(model: model, note: n, onDelete: { ask(id) })
          .id(id)
      }
      else {
        ContentUnavailableView {
          Label("No Note Selected", systemImage: "note.text")
        } description: {
          Text("Pick a note, or make a new one.")
        } actions: {
          Button("New Note") { model.newNote() }
        }
      }
    }
    .sheet(isPresented: $asking) { AskView(model: model) }
    .alert(item: $confirm) { c in
      switch c {
      case .delete(let id):
        Alert(title: Text("Delete this note forever?"), message: Text("You can't undo this action."),
              primaryButton: .destructive(Text("Delete")) { model.deleteForever(id) }, secondaryButton: .cancel())
      case .emptyTrash:
        Alert(title: Text("Empty the Trash?"), message: Text("\(model.count(.trash)) notes will be deleted forever. You can't undo this action."),
              primaryButton: .destructive(Text("Empty Trash")) { model.emptyTrash() }, secondaryButton: .cancel())
      }
    }
  }

  /// In the Trash, delete forever (after asking); elsewhere, move to the Trash.
  private func ask(_ id: UUID) {
    guard let n = model.note(id) else { return }
    if n.trashed != nil { confirm = .delete(id) } else { model.trash(id) }
  }
}

private struct SidebarView: View {
  @Bindable var model: Notebook
  let onEmptyTrash: () -> Void
  @State private var naming: String?
  @State private var renaming: String?
  @State private var draft = ""

  var body: some View {
    List(selection: Binding<Scope?>(get: { model.scope }, set: { if let s = $0 { model.scope = s } })) {
      Section("Library") {
        row(.all, "note.text")
        row(.favorites, "star")
        row(.desktop, "pin")
        row(.reminders, "bell")
        row(.archive, "archivebox")
        row(.trash, "trash")
          .contextMenu {
            Button("Empty Trash…", role: .destructive, action: onEmptyTrash).disabled(model.count(.trash) == 0)
          }
      }
      Section {
        ForEach(model.notebooks, id: \.self) { nb in
          row(.notebook(nb), "book.closed")
            .contextMenu {
              Button("Rename…") {
                draft = nb
                renaming = nb
              }
              Button("Delete Notebook", role: .destructive) { model.deleteNotebook(nb) }
            }
        }
      } header: {
        HStack {
          Text("Notebooks")
          Spacer()
          Button("New Notebook", systemImage: "plus") {
            draft = ""
            naming = ""
          }
          .labelStyle(.iconOnly)
          .buttonStyle(.borderless)
          .help("New notebook")
        }
      }
      if !model.tags.isEmpty {
        Section("Tags") {
          ForEach(model.tags, id: \.name) { t in
            Label(t.name, systemImage: "number")
              .badge(t.count)
              .tag(Scope.tag(t.name))
          }
        }
      }
    }
    .listStyle(.sidebar)
    .safeAreaInset(edge: .bottom) { SyncFooter() }
    .alert("New Notebook", isPresented: Binding { naming != nil } set: { if !$0 { naming = nil } }) {
      TextField("Name", text: $draft)
      Button("Create") { _ = model.addNotebook(draft) }
      Button("Cancel", role: .cancel) {}
    }
    .alert("Rename Notebook", isPresented: Binding { renaming != nil } set: { if !$0 { renaming = nil } }) {
      TextField("Name", text: $draft)
      Button("Rename") { if let old = renaming { model.renameNotebook(old, to: draft) } }
      Button("Cancel", role: .cancel) {}
    }
  }

  private func row(_ s: Scope, _ icon: String) -> some View {
    let n = model.count(s)
    return Label(s.title, systemImage: icon)
      .badge(n)
      .tag(s)
  }
}

/// Sync status at the bottom of the sidebar.
private struct SyncFooter: View {
  @State private var sync = Sync.shared

  var body: some View {
    HStack(spacing: 6) {
      switch sync.phase {
      case .signedOut:
        Image(systemName: "icloud.slash").foregroundStyle(.secondary)
        Button("Turn On Sync…") { SettingsWindow.show(tab: .sync) }
          .buttonStyle(.link)
      case .syncing:
        ProgressView().controlSize(.mini)
        Text("Syncing…").foregroundStyle(.secondary)
      case .idle:
        Image(systemName: "checkmark.icloud").foregroundStyle(.secondary)
        if let d = sync.lastSync {
          Text("Synced \(d, style: .relative) ago").foregroundStyle(.secondary)
        }
        else {
          Text("Sync on").foregroundStyle(.secondary)
        }
      case .failed(let m):
        Image(systemName: "exclamationmark.icloud").foregroundStyle(.orange)
        Button("Sync problem") { SettingsWindow.show(tab: .sync) }
          .buttonStyle(.link)
          .help(m)
      }
      Spacer()
    }
    .font(.caption)
    .lineLimit(1)
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }
}

private struct NoteListView: View {
  @Bindable var model: Notebook
  @Binding var asking: Bool
  let onDelete: (UUID) -> Void
  @FocusState private var searchFocused: Bool

  var body: some View {
    let list = model.visible
    VStack(spacing: 0) {
      HStack(spacing: 6) {
        HStack(spacing: 4) {
          Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
          TextField(model.smart ? "Search by words or meaning" : "Search", text: $model.query)
            .textFieldStyle(.plain)
            .focused($searchFocused)
            .onKeyPress(.downArrow) {
              model.selection = list.first?.id
              searchFocused = false
              return .handled
            }
          if !model.query.isEmpty {
            Button("Clear Search", systemImage: "xmark.circle.fill") { model.query = "" }
              .labelStyle(.iconOnly)
              .buttonStyle(.borderless)
              .foregroundStyle(.secondary)
          }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
        Menu {
          Picker("Sort By", selection: $model.sort) {
            ForEach(NoteSort.allCases, id: \.self) { Text($0.title).tag($0) }
          }
          .pickerStyle(.inline)
          Toggle("Favorites First", isOn: $model.favoritesFirst)
          Divider()
          Toggle("Search by Meaning", isOn: $model.smart)
        } label: {
          Image(systemName: "line.3.horizontal.decrease.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sort and search options")
        Button("Ask Your Notes", systemImage: "bubble.left.and.text.bubble.right") { asking = true }
          .labelStyle(.iconOnly)
          .buttonStyle(.borderless)
          .help("Ask a question about your notes")
        Button("New Note", systemImage: "square.and.pencil") { model.newNote() }
          .labelStyle(.iconOnly)
          .buttonStyle(.borderless)
          .help("New note here (pin it to put it on the desktop)")
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 8)

      List(selection: $model.selection) {
        ForEach(list) { r in
          RowView(row: r, showNotebook: { if case .notebook = model.scope { false } else { true } }())
            .tag(r.id)
            .contextMenu { RowMenu(model: model, row: r, onDelete: onDelete) }
        }
      }
      .listStyle(.inset)
      .onDeleteCommand { if let id = model.selection { onDelete(id) } }
      .onKeyPress(.return) {
        model.focusEditor()
        return .handled
      }
      .overlay {
        if list.isEmpty {
          if model.query.isEmpty {
            ContentUnavailableView(model.scope == .trash ? "Trash Is Empty" : "No Notes", systemImage: model.scope == .trash ? "trash" : "note.text")
          }
          else {
            ContentUnavailableView.search(text: model.query)
          }
        }
      }
    }
    .navigationTitle(model.scope.title)
    .onChange(of: model.searchFocus) { searchFocused = true }
  }
}

private struct RowMenu: View {
  let model: Notebook
  let row: NoteRow
  let onDelete: (UUID) -> Void

  var body: some View {
    if row.trashed != nil {
      Button("Restore", systemImage: "arrow.uturn.backward") { model.restore(row.id) }
      Button("Delete Forever…", systemImage: "trash", role: .destructive) { onDelete(row.id) }
    }
    else {
      Button(row.pinned ? "Unpin from Desktop" : "Pin to Desktop", systemImage: row.pinned ? "pin.slash" : "pin") {
        model.change(row.id) {
          $0.pinned.toggle()
          $0.archived = false
        }
      }
      Button(row.favorite ? "Remove from Favorites" : "Add to Favorites", systemImage: row.favorite ? "star.slash" : "star") {
        model.change(row.id) { $0.favorite.toggle() }
      }
      NotebookMenu(model: model, id: row.id, current: row.notebook)
      Menu("Color") {
        ForEach(NoteColor.allCases, id: \.self) { c in
          Button(c.title) { model.change(row.id) { $0.color = c } }
        }
      }
      Divider()
      Button(row.archived ? "Unarchive" : "Archive", systemImage: "archivebox") { model.change(row.id) { $0.archived.toggle() } }
      Button("Move to Trash", systemImage: "trash") { onDelete(row.id) }
    }
  }
}

private struct NotebookMenu: View {
  let model: Notebook
  let id: UUID
  let current: String

  var body: some View {
    Menu("Move to Notebook") {
      Button("None") { model.change(id) { $0.notebook = "" } }.disabled(current.isEmpty)
      if !model.notebooks.isEmpty { Divider() }
      ForEach(model.notebooks, id: \.self) { nb in
        Button(nb) { model.change(id) { $0.notebook = nb } }.disabled(nb == current)
      }
    }
  }
}

private struct RowView: View {
  let row: NoteRow
  let showNotebook: Bool

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      RoundedRectangle(cornerRadius: 2.5)
        .fill(Color(nsColor: row.color.paper))
        .overlay(RoundedRectangle(cornerRadius: 2.5).strokeBorder(.black.opacity(0.2), lineWidth: 0.5))
        .frame(width: 10, height: 10)
        .padding(.top, 4)
        .accessibilityLabel("\(row.color.title) note")
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 4) {
          Text(row.title)
            .fontWeight(.semibold)
            .lineLimit(1)
          Spacer(minLength: 0)
          if row.favorite { icon("star.fill", "Favorite") }
          if row.remind != nil { icon("bell.fill", "Has a reminder") }
          if row.pinned && row.isLive { icon("pin.fill", "On the desktop") }
        }
        HStack(spacing: 6) {
          Text(row.modified, format: .dateTime.month(.abbreviated).day())
            .foregroundStyle(.secondary)
          if row.total > 0 {
            Text("\(row.done)/\(row.total)")
              .monospacedDigit()
              .foregroundStyle(row.done == row.total ? .green : .secondary)
              .accessibilityLabel("\(row.done) of \(row.total) done")
          }
          Text(row.preview.isEmpty ? "No additional text" : row.preview)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        }
        .font(.caption)
        if showNotebook, !row.notebook.isEmpty {
          Label(row.notebook, systemImage: "book.closed")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
        }
      }
    }
    .padding(.vertical, 3)
  }

  private func icon(_ name: String, _ label: String) -> some View {
    Image(systemName: name)
      .font(.caption2)
      .foregroundStyle(.secondary)
      .help(label)
      .accessibilityLabel(label)
  }
}

private struct NoteDetail: View {
  let model: Notebook
  let note: Note
  let onDelete: () -> Void
  @State private var reminding = false
  @State private var naming = false
  @State private var titleError: String?

  private var trashed: Bool { note.trashed != nil }

  var body: some View {
    VStack(spacing: 0) {
      if let t = note.trashed {
        HStack {
          Label("In the Trash. Deleted forever \(Calendar.current.date(byAdding: .day, value: TRASH_DAYS, to: t)?.formatted(date: .abbreviated, time: .omitted) ?? "soon").", systemImage: "trash")
          Spacer()
          Button("Restore") { model.restore(note.id) }
          Button("Delete Forever…", role: .destructive, action: onDelete)
        }
        .padding(10)
        .background(.orange.opacity(0.12))
      }
      else if note.archived {
        HStack {
          Label("Archived. Hidden from All Notes and the desktop.", systemImage: "archivebox")
          Spacer()
          Button("Unarchive") { model.change(note.id) { $0.archived = false } }
        }
        .padding(10)
        .background(.blue.opacity(0.08))
      }
      header
      Divider()
      NoteEditor(id: note.id, model: model, editable: !trashed)
        .background(Color(nsColor: note.color.paper))
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 10) {
        TextField(
          "Title",
          text: Binding(get: { note.name }, set: { v in model.change(note.id) { $0.name = v } }),
          prompt: Text(note.firstLine.isEmpty ? "Untitled" : note.firstLine)
        )
        .textFieldStyle(.plain)
        .font(.title2.weight(.semibold))
        .disabled(trashed)
        .accessibilityLabel("Note title")

        Button {
          naming = true
          titleError = nil
          Task {
            do { try await model.suggestTitle(note.id) }
            catch { titleError = error.localizedDescription }
            naming = false
          }
        } label: {
          if naming { ProgressView().controlSize(.small) } else { Image(systemName: "wand.and.stars") }
        }
        .buttonStyle(.borderless)
        .disabled(trashed || naming)
        .help(titleError ?? "Suggest a title with AI")
        .accessibilityLabel("Suggest a title with AI")
      }
      HStack(spacing: 14) {
        Button {
          model.change(note.id) {
            $0.pinned.toggle()
            $0.archived = false
          }
        } label: {
          Label(note.onDesktop ? "On Desktop" : "Pin to Desktop", systemImage: note.onDesktop ? "pin.fill" : "pin")
        }
        .help(note.onDesktop ? "Shown on the desktop as a sticky. Click to unpin." : "Show this note on the desktop as a sticky")

        Button {
          model.change(note.id) { $0.favorite.toggle() }
        } label: {
          Label("Favorite", systemImage: note.favorite ? "star.fill" : "star")
        }
        .labelStyle(.iconOnly)
        .help(note.favorite ? "Remove from Favorites" : "Add to Favorites")

        Button {
          reminding = true
        } label: {
          Label(note.remind.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Remind Me", systemImage: note.remind == nil ? "bell" : "bell.fill")
        }
        .popover(isPresented: $reminding) {
          ReminderPicker(current: note.remind) { d in
            model.change(note.id) { $0.remind = d }
            reminding = false
          }
        }

        Menu {
          NotebookMenu(model: model, id: note.id, current: note.notebook)
          Menu("Color") {
            ForEach(NoteColor.allCases, id: \.self) { c in
              Toggle(c.title, isOn: Binding(get: { note.color == c }, set: { _ in model.change(note.id) { $0.color = c } }))
            }
          }
          Divider()
          Button("Export as Markdown…") { exportMarkdown() }
          Button(note.archived ? "Unarchive" : "Archive") { model.change(note.id) { $0.archived.toggle() } }
          Button("Move to Trash", role: .destructive, action: onDelete)
        } label: {
          Label(note.notebook.isEmpty ? "No Notebook" : note.notebook, systemImage: "book.closed")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Notebook, color, export, archive")

        Spacer()

        AIButton(model: model)
          .disabled(trashed)
      }
      .buttonStyle(.borderless)
      .disabled(trashed)
      HStack(spacing: 4) {
        Text("Created \(note.created.formatted(date: .abbreviated, time: .shortened))")
        Text("·")
        Text("Edited \(note.modified.formatted(date: .abbreviated, time: .shortened))")
        let tags = Note.tags(in: note.plain)
        if !tags.isEmpty {
          Text("·")
          Text(tags.map { "#\($0)" }.joined(separator: " "))
        }
      }
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 12)
  }

  private func exportMarkdown() {
    model.texts.commit(note.id)
    guard let n = model.note(note.id) else { return }
    let p = NSSavePanel()
    p.allowedContentTypes = [.markdownText]
    p.nameFieldStringValue = String(n.title.prefix(60)) + ".md"
    guard p.runModal() == .OK, let url = p.url else { return }
    do { try Exporter.write(n.attributed, title: n.name.trimmingCharacters(in: .whitespaces), to: url, as: .markdownText) }
    catch { NSAlert(error: error).runModal() }
  }
}

/// ✨ runs the default action; the menu lists every action.
private struct AIButton: View {
  let model: Notebook

  var body: some View {
    if model.aiBusy {
      HStack(spacing: 6) {
        ProgressView().controlSize(.small)
        Button("Stop") { model.ai.stop() }
      }
    }
    else if !model.prefs.ai.enabledActions.isEmpty {
      Menu {
        ForEach(model.prefs.ai.enabledActions) { a in
          Button(a.name, systemImage: a.icon) { model.ai.run(a) }
        }
        Divider()
        Button("AI Settings…") { SettingsWindow.show(tab: .ai) }
      } label: {
        Label(model.prefs.ai.primary?.name ?? "AI", systemImage: "sparkles")
      } primaryAction: {
        model.ai.runDefault()
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .help("Click to \(model.prefs.ai.primary?.name.lowercased() ?? "run AI") (⌘R). Select text first to change only that part.")
    }
  }
}

/// The note's rich text, sharing live storage with its sticky if one is on the desktop.
private struct NoteEditor: NSViewRepresentable {
  let id: UUID
  let model: Notebook
  let editable: Bool

  func makeNSView(context: Context) -> NSScrollView {
    let tv = model.texts.makeTextView(id, size: NSSize(width: 600, height: 400))
    NoteTexts.configure(tv, prefs: model.prefs)
    tv.textContainerInset = NSSize(width: 18, height: 14)
    tv.appearance = NSAppearance(named: .aqua)
    tv.isEditable = editable
    tv.ai = model.ai
    tv.extraMenu = { [weak model] in model?.ai.menuItems() ?? [] }
    model.ai.textView = tv
    model.editor = tv
    let scroll = NoteScrollView()
    scroll.documentView = tv
    scroll.appearance = NSAppearance(named: .aqua)
    return scroll
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {
    (scroll.documentView as? NSTextView)?.isEditable = editable
  }

  static func dismantleNSView(_ scroll: NSScrollView, coordinator: ()) {
    guard let tv = scroll.documentView as? NoteTextView else { return }
    MainActor.assumeIsolated {
      let m = Notebook.shared
      if m.ai.textView === tv {
        m.ai.cancel()
        m.ai.textView = nil
      }
      NoteTexts.shared.detach(tv)
    }
  }
}

// MARK: ask

/// Ask a question; the AI answers from your notes.
private struct AskView: View {
  let model: Notebook
  @Environment(\.dismiss) private var dismiss
  @State private var question = ""
  @State private var answer = ""
  @State private var error: String?
  @State private var busy = false
  @State private var history: [(q: String, a: String)] = []
  @State private var task: Task<Void, Never>?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label("Ask Your Notes", systemImage: "bubble.left.and.text.bubble.right").font(.headline)
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          ForEach(Array(history.enumerated()), id: \.offset) { _, h in
            Text(h.q).fontWeight(.semibold)
            Text(h.a).textSelection(.enabled)
          }
          if busy || !answer.isEmpty {
            Text(answer.isEmpty ? "Reading your notes…" : answer)
              .foregroundStyle(answer.isEmpty ? .secondary : .primary)
              .textSelection(.enabled)
          }
          if let error {
            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
          }
          if history.isEmpty && !busy && answer.isEmpty && error == nil {
            Text("For example: “What did I plan for the Router release?” or “List every open to-do.” The question and your notes go to the AI provider set in Settings.")
              .foregroundStyle(.secondary)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(minHeight: 240)
      HStack {
        TextField("Ask a question", text: $question)
          .textFieldStyle(.roundedBorder)
          .onSubmit(send)
          .disabled(busy)
        if busy {
          Button("Stop") { task?.cancel() }
        }
        else {
          Button("Ask", action: send)
            .keyboardShortcut(.defaultAction)
            .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        Button("Done") {
          task?.cancel()
          dismiss()
        }
        .keyboardShortcut(.cancelAction)
      }
    }
    .padding(18)
    .frame(width: 560, height: 460)
  }

  private func send() {
    let q = question.trimmingCharacters(in: .whitespaces)
    guard !q.isEmpty, !busy else { return }
    model.texts.commitAll()
    let system = """
    You answer questions about the user's own notes. Use only the notes given. Be brief and direct. \
    Name the notes you used by their titles. If the notes don't answer the question, say so. Today is \(Date().formatted(date: .complete, time: .omitted)).
    """
    let earlier = history.suffix(3).map { "Q: \($0.q)\nA: \($0.a)" }.joined(separator: "\n\n")
    let user = "<notes>\n\(model.askContext())</notes>\n\n" + (earlier.isEmpty ? "" : "Earlier in this conversation:\n\(earlier)\n\n") + "Question: \(q)"
    history.append((q, ""))
    answer = ""
    error = nil
    busy = true
    question = ""
    task = Task {
      do {
        let full = try await AIEditor.ask(model.prefs, system: system, user: user) { piece in answer += piece }
        answer = full
      }
      catch is CancellationError {}
      catch { self.error = error.localizedDescription }
      if let i = history.indices.last { history[i].a = answer }
      answer = ""
      busy = false
    }
  }
}
