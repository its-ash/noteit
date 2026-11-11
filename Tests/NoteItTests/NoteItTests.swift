import AppKit
import Foundation
import Testing
@testable import NoteIt

@Suite struct SSEParserTests {
  @Test func readsOpenAIStream() throws {
    var p = SSEParser(.openai)
    var out: [String] = []
    for l in [
      #"data: {"choices":[{"delta":{"role":"assistant"}}]}"#,
      #"data: {"choices":[{"delta":{"content":"Hello"}}]}"#,
      ": keep-alive",
      #"data: {"choices":[{"delta":{"content":" world"}}]}"#,
      "data: [DONE]",
    ] {
      if let t = try p.feed(l) { out.append(t) }
    }
    #expect(out == ["Hello", " world"])
    #expect(p.text == "Hello world")
    #expect(p.done)
  }

  @Test func readsAnthropicStreamAndSkipsThinking() throws {
    var p = SSEParser(.anthropic)
    for l in [
      "event: message_start",
      #"data: {"type":"message_start","message":{"id":"msg_1"}}"#,
      #"data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
      #"data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hmm"}}"#,
      #"data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Clean "}}"#,
      #"data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"note."}}"#,
      #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#,
      #"data: {"type":"message_stop"}"#,
    ] { _ = try p.feed(l) }
    #expect(p.text == "Clean note.")
    #expect(p.done)
  }

  @Test func throwsOnStreamErrorsAndRefusals() {
    var a = SSEParser(.anthropic)
    #expect(throws: AIError.self) { try a.feed(#"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#) }
    var r = SSEParser(.anthropic)
    #expect(throws: AIError.self) { try r.feed(#"data: {"type":"message_delta","delta":{"stop_reason":"refusal"}}"#) }
    var o = SSEParser(.openai)
    #expect(throws: AIError.self) { try o.feed(#"data: {"error":{"message":"rate limited"}}"#) }
  }

  @Test func readsWholeJSONReplies() throws {
    var o = SSEParser(.openai)
    try o.whole(Data(#"{"choices":[{"message":{"content":"hi"}}]}"#.utf8))
    #expect(o.text == "hi")
    var a = SSEParser(.anthropic)
    try a.whole(Data(#"{"content":[{"type":"thinking","thinking":""},{"type":"text","text":"a"},{"type":"text","text":"b"}],"stop_reason":"end_turn"}"#.utf8))
    #expect(a.text == "ab")
  }
}

@Suite struct AIClientTests {
  @Test func buildsOpenAIBody() {
    var cfg = AIConfig()
    cfg.temperature = 0.3
    let b = AIClient.body(cfg, user: "u")
    let msgs = b["messages"] as? [[String: Any]] ?? []
    #expect(b["model"] as? String == "router/auto")
    #expect(msgs.first?["role"] as? String == "system")
    #expect(msgs.last?["content"] as? String == "u")
    #expect(b["temperature"] as? Double == 0.3)
    #expect(b["max_tokens"] == nil)
  }

  @Test func buildsAnthropicBodyWithoutSamplingParams() {
    var cfg = AIConfig()
    cfg.use(ProviderPreset.find("anthropic"))
    cfg.temperature = 0.9
    let b = AIClient.body(cfg, user: "u")
    #expect(b["model"] as? String == "claude-opus-5-5")
    #expect(b["system"] as? String == DEFAULT_SYSTEM)
    #expect(b["max_tokens"] as? Int == 16_000)
    #expect(b["temperature"] == nil)
    #expect((b["output_config"] as? [String: Any])?["effort"] as? String == "low")
    #expect(b["fallbacks"] as? String == "default")
    #expect((b["messages"] as? [[String: Any]])?.count == 1)
  }

  @Test func fallbackOnlyForSupportedModelsOnTheClaudeAPI() {
    var cfg = AIConfig()
    cfg.use(ProviderPreset.find("anthropic"))
    #expect(AIClient.usesFallback(cfg))
    cfg.model = "claude-haiku-5-5"
    #expect(!AIClient.usesFallback(cfg))
    cfg.model = "claude-opus-5-5"
    cfg.base = "https://proxy.example.com/v1"
    #expect(!AIClient.usesFallback(cfg))
  }

  @Test func rejectsBadURLs() {
    var cfg = AIConfig()
    cfg.base = "not a url"
    #expect(throws: AIError.self) { try AIClient.baseURL(cfg) }
    cfg.base = "ftp://x.com"
    #expect(throws: AIError.self) { try AIClient.baseURL(cfg) }
  }

  @Test func cleansWrappers() {
    #expect(AIClient.clean("  hello \n") == "hello")
    #expect(AIClient.clean("<note>\nhi\n</note>") == "hi")
    #expect(AIClient.clean("```\nline 1\nline 2\n```") == "line 1\nline 2")
    #expect(AIClient.clean("```text\nx\n```") == "x")
    #expect(AIClient.clean("use ``` inline") == "use ``` inline")
  }

  @Test func promptWrapsTheNote() {
    let p = AIClient.prompt(AIAction.defaults[0], "my text")
    #expect(p.hasPrefix(AIAction.defaults[0].prompt))
    #expect(p.hasSuffix("<note>\nmy text\n</note>"))
  }

  @Test func switchingProviderResetsModelAndFormat() {
    var cfg = AIConfig()
    cfg.use(ProviderPreset.find("anthropic"))
    #expect(cfg.wire == .anthropic)
    cfg.use(ProviderPreset.find("ollama"))
    #expect(cfg.wire == .openai)
    #expect(cfg.base == "http://localhost:11434/v1")
    #expect(cfg.model.isEmpty)
    cfg.base = "https://mine.example/v1"
    cfg.use(ProviderPreset.find("custom"))
    #expect(cfg.base == "https://mine.example/v1")
  }

  @Test func primaryActionFallsBackToFirstEnabled() {
    var cfg = AIConfig()
    #expect(cfg.primary?.name == "Refine")
    cfg.defaultAction = cfg.actions[2].id
    #expect(cfg.primary?.id == cfg.actions[2].id)
    cfg.actions[2].enabled = false
    #expect(cfg.primary?.name == "Refine")
    for i in cfg.actions.indices { cfg.actions[i].enabled = false }
    #expect(cfg.primary == nil)
  }

  @Test func configRoundTripsThroughJSON() throws {
    var cfg = AIConfig()
    cfg.use(ProviderPreset.find("anthropic"))
    cfg.apply = .review
    let back = try JSONDecoder().decode(AIConfig.self, from: JSONEncoder().encode(cfg))
    #expect(back == cfg)
  }
}

@MainActor
@Suite struct NoteStoreTests {
  @Test func savesAndLoadsRichText() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "noteit_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appending(path: "notes.json")

    let store = NoteStore(file: file)
    var n = Note()
    n.color = .pink
    n.floating = true
    n.attributed = NSAttributedString(string: "Groceries\nmilk", attributes: [.font: NSFont.boldSystemFont(ofSize: 15)])
    store.add(n)
    store.saveNow()

    let loaded = NoteStore(file: file)
    let back = try #require(loaded.note(n.id))
    #expect(back.color == .pink)
    #expect(back.floating)
    #expect(back.plain == "Groceries\nmilk")
    #expect(back.title == "Groceries")
    let font = back.attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
    #expect(font?.fontDescriptor.symbolicTraits.contains(.bold) == true)

    loaded.remove(n.id)
    loaded.saveNow()
    #expect(NoteStore(file: file).notes.isEmpty)
  }

  @Test func everyPaperColorIsEasyToRead() {
    #expect(NoteColor.allCases.count == 8)
    for c in NoteColor.allCases {
      #expect(c.contrast >= 7, "\(c.title) contrast \(c.contrast) is below WCAG AAA")
    }
  }

  @Test func savedFramesOnAMissingScreenMoveBack() {
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)
    let visible = CGRect(x: 100, y: 300, width: 260, height: 220)
    #expect(AppDelegate.onScreen(visible, screens: [screen]) == visible)
    let gone = CGRect(x: 3000, y: 300, width: 260, height: 220)
    let moved = AppDelegate.onScreen(gone, screens: [screen])
    #expect(screen.contains(moved))
    #expect(moved.size == gone.size)
  }

  @Test func emptyNoteHasPlaceholderTitle() {
    #expect(Note().title == "Empty note")
  }

  @Test func typedTitleWinsOverFirstLine() {
    var n = Note()
    n.attributed = NSAttributedString(string: "\n  Groceries\nmilk")
    #expect(n.title == "Groceries")
    n.name = "  Shopping  "
    #expect(n.title == "Shopping")
    n.name = "   "
    #expect(n.title == "Groceries")
  }

  @Test func notesFromOlderVersionsLoadPinnedAndUntitled() throws {
    let id = UUID()
    let json = #"[{"id":"\#(id.uuidString)","color":"pink","floating":true}]"#
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    let n = try #require(try d.decode([Note].self, from: Data(json.utf8)).first)
    #expect(n.id == id)
    #expect(n.pinned)
    #expect(n.name.isEmpty)
    #expect(n.color == .pink)
    #expect(n.floating)
  }

  @Test func nameAndPinRoundTrip() throws {
    var n = Note()
    n.name = "Plan"
    n.pinned = false
    let back = try JSONDecoder().decode(Note.self, from: JSONEncoder().encode(n))
    #expect(back == n)
  }

  @Test func sharedTextIsSavedToTheStore() async throws {
    let file = FileManager.default.temporaryDirectory.appending(path: "noteit_\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: file) }
    let store = NoteStore(file: file)
    let texts = NoteTexts(store: store)
    let n = Note()
    store.add(n)
    let a = texts.makeTextView(n.id, size: NSSize(width: 200, height: 100))
    let b = texts.makeTextView(n.id, size: NSSize(width: 200, height: 100))
    a.insertText("hello", replacementRange: NSRange(location: 0, length: 0))
    #expect(b.string == "hello")
    texts.commit(n.id)
    #expect(store.note(n.id)?.plain == "hello")
    texts.detach(b)
    #expect(b.string.isEmpty)
    #expect(a.string == "hello")
  }

  @Test func reloadTakesStoredTextWithoutSavingItBack() throws {
    let file = FileManager.default.temporaryDirectory.appending(path: "noteit_\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: file) }
    let store = NoteStore(file: file)
    let texts = NoteTexts(store: store)
    var n = Note()
    n.attributed = NSAttributedString(string: "old")
    store.add(n)
    let tv = texts.makeTextView(n.id, size: NSSize(width: 200, height: 100))
    n.attributed = NSAttributedString(string: "from another Mac")
    n.modified = Date(timeIntervalSince1970: 1000)
    store.update(n)
    texts.reload(n.id)
    #expect(tv.string == "from another Mac")
    texts.commitAll()
    #expect(store.note(n.id)?.modified == Date(timeIntervalSince1970: 1000))
  }

  @Test func trashOlderThan30DaysIsPurged() {
    let file = FileManager.default.temporaryDirectory.appending(path: "noteit_\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: file) }
    let store = NoteStore(file: file)
    let now = Date()
    var old = Note()
    old.trashed = now.addingTimeInterval(-31 * 86_400)
    var recent = Note()
    recent.trashed = now.addingTimeInterval(-2 * 86_400)
    let live = Note()
    [old, recent, live].forEach(store.add)
    #expect(store.purgeTrash(now: now) == 1)
    #expect(store.note(old.id) == nil)
    #expect(store.note(recent.id) != nil)
    #expect(store.note(live.id) != nil)
  }

  @Test func onlyLivePinnedNotesGoOnTheDesktop() {
    var n = Note()
    #expect(n.onDesktop)
    n.archived = true
    #expect(!n.onDesktop)
    n.archived = false
    n.trashed = Date()
    #expect(!n.onDesktop && !n.isLive)
  }

  @Test func findsTags() {
    #expect(Note.tags(in: "Plan #Work and #ideas, not a#b or http://x.com/#frag or #1") == ["ideas", "work"])
  }
}

@Suite struct ChecklistTests {
  @Test func countsProgress() {
    let p = Checklist.progress("☐ milk\n☑ eggs\n  ☒ bread\nplain line")
    #expect(p.done == 2)
    #expect(p.total == 3)
  }

  @Test func togglesBoxesOnLines() {
    let text = "milk\neggs\nbread" as NSString
    let (r, on) = Checklist.toggleLines(text, range: NSRange(location: 0, length: 9))
    #expect(r == NSRange(location: 0, length: 10))
    #expect(on == "☐ milk\n☐ eggs\n")
    let (_, off) = Checklist.toggleLines(on as NSString, range: NSRange(location: 0, length: 3))
    #expect(off == "milk\n")
    #expect(Checklist.toggled("☐") == "☑")
    #expect(Checklist.toggled("☑") == "☐")
  }
}

@Suite struct SnapTests {
  let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)

  @Test func snapsToScreenEdges() {
    let f = NSRect(x: 6, y: 500, width: 260, height: 220)
    #expect(Snap.origin(for: f, screens: [screen], others: []) == NSPoint(x: 0, y: 500))
  }

  @Test func stacksBelowAnotherNote() {
    let other = NSRect(x: 300, y: 500, width: 260, height: 220)
    let f = NSRect(x: 304, y: 500 - 8 - 220 + 5, width: 260, height: 220)
    #expect(Snap.origin(for: f, screens: [screen], others: [other]) == NSPoint(x: 300, y: 272))
  }

  @Test func leavesFarNotesAlone() {
    let f = NSRect(x: 600, y: 400, width: 260, height: 220)
    #expect(Snap.origin(for: f, screens: [screen], others: [NSRect(x: 0, y: 0, width: 100, height: 100)]) == f.origin)
  }
}

@MainActor
@Suite struct MarkdownTests {
  @Test func exportsTitleFormattingAndChecklists() {
    let a = NSMutableAttributedString(string: "Plan ", attributes: [.font: NSFont.systemFont(ofSize: 14)])
    a.append(NSAttributedString(string: "today", attributes: [.font: NSFont.boldSystemFont(ofSize: 14)]))
    a.append(NSAttributedString(string: "\n☐ milk\n☑ eggs", attributes: [.font: NSFont.systemFont(ofSize: 14)]))
    #expect(MarkdownText.from(a, title: "Shop") == "# Shop\n\nPlan **today**\n- [ ] milk\n- [x] eggs")
  }

  @Test func importsTitleAndChecklists() {
    let (title, text) = MarkdownText.toNote("# Shop\n\nBuy **milk**\n- [ ] eggs\n- [x] bread", font: .systemFont(ofSize: 14))
    #expect(title == "Shop")
    #expect(text.string == "Buy milk\n☐ eggs\n☑ bread")
    let f = text.attribute(.font, at: 4, effectiveRange: nil) as? NSFont
    #expect(f?.fontDescriptor.symbolicTraits.contains(.bold) == true)
  }
}

@MainActor
@Suite struct SyncCodecTests {
  @Test func noteRoundTripsThroughFirestoreFields() throws {
    var n = Note()
    n.name = "Trip"
    n.attributed = NSAttributedString(string: "Pack bags\n☐ passport")
    n.color = .teal
    n.notebook = "Travel"
    n.favorite = true
    n.remind = Date(timeIntervalSince1970: 2_000_000_000)
    n.modified = Date(timeIntervalSince1970: 1_800_000_000.25)
    // Firestore returns doubles as JSON numbers; go through JSON as the API would.
    let json = try JSONSerialization.data(withJSONObject: ["name": "projects/p/databases/(default)/documents/users/u/notes/\(n.id.uuidString)", "fields": FireCodec.fields(n)])
    let doc = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
    let r = try #require(FireCodec.decode(doc))
    #expect(r.id == n.id)
    #expect(!r.deleted)
    #expect(r.name == "Trip")
    #expect(r.text == "Pack bags\n☐ passport")
    #expect(r.color == .teal && r.notebook == "Travel" && r.favorite)
    #expect(r.remind == n.remind)
    #expect(abs(r.modified.timeIntervalSince1970 - n.modified.timeIntervalSince1970) < 0.001)
    let merged = FireCodec.merge(r, into: nil, font: .systemFont(ofSize: 14))
    #expect(merged.plain == n.plain)
    #expect(!merged.pinned)
  }

  @Test func lastWriterWins() {
    var local = Note()
    local.modified = Date(timeIntervalSince1970: 100)
    var r = RemoteNote(id: local.id, modified: Date(timeIntervalSince1970: 200))
    #expect(FireCodec.decide(r, local: local, tombstoned: false) == .apply)
    #expect(FireCodec.decide(r, local: nil, tombstoned: false) == .apply)
    #expect(FireCodec.decide(r, local: nil, tombstoned: true) == .skip)
    r.modified = Date(timeIntervalSince1970: 50)
    #expect(FireCodec.decide(r, local: local, tombstoned: false) == .keepLocal)
    r.deleted = true
    #expect(FireCodec.decide(r, local: local, tombstoned: false) == .keepLocal)
    r.modified = Date(timeIntervalSince1970: 300)
    #expect(FireCodec.decide(r, local: local, tombstoned: false) == .delete)
    #expect(FireCodec.decide(r, local: nil, tombstoned: false) == .skip)
  }

  @Test func remoteChangesKeepThisMacsDesktopState() {
    var local = Note()
    local.pinned = true
    local.frame = CGRect(x: 10, y: 20, width: 300, height: 200)
    var r = RemoteNote(id: local.id, modified: Date())
    r.text = "new"
    let m = FireCodec.merge(r, into: local, font: .systemFont(ofSize: 14))
    #expect(m.pinned)
    #expect(m.frame == local.frame)
    #expect(m.plain == "new")
    r.trashed = Date()
    #expect(!FireCodec.merge(r, into: local, font: .systemFont(ofSize: 14)).pinned)
  }

  @Test func androidMarkdownKeepsFormatting() {
    var r = RemoteNote(id: UUID(), modified: Date())
    r.text = "Buy milk\n☐ eggs"
    r.markdown = "Buy **milk**\n- [ ] eggs"
    let m = FireCodec.merge(r, into: nil, font: .systemFont(ofSize: 14))
    #expect(m.plain == "Buy milk\n☐ eggs")
    let f = m.attributed.attribute(.font, at: 4, effectiveRange: nil) as? NSFont
    #expect(f?.fontDescriptor.symbolicTraits.contains(.bold) == true)
  }

  @Test func staleMarkdownLosesToNewerText() {
    var r = RemoteNote(id: UUID(), modified: Date())
    r.text = "Changed on the phone"
    r.markdown = "Old **text**"
    let m = FireCodec.merge(r, into: nil, font: .systemFont(ofSize: 14))
    #expect(m.plain == "Changed on the phone")
  }

  @Test func writesTouchOnlyTheMacsFields() {
    let w = FireCodec.write("projects/p/databases/(default)/documents/users/u/notes/X", FireCodec.tombstone(Date()))
    let mask = (w["updateMask"] as? [String: Any])?["fieldPaths"] as? [String]
    #expect(mask == FireCodec.fieldNames)
    #expect(mask?.contains("rtfd") == true)
    #expect(mask?.contains("syncedAt") == false)
    let transforms = w["updateTransforms"] as? [[String: Any]]
    #expect(transforms?.first?["fieldPath"] as? String == "syncedAt")
  }

  @Test func prunesOldestBackups() {
    let names = (1...16).map { String(format: "notes-2026-01-%02d-120000.json", $0) }
    let gone = Backups.toPrune(names, keep: 14)
    #expect(gone == ["notes-2026-01-02-120000.json", "notes-2026-01-01-120000.json"])
  }

  @Test func cosineOfSameVectorIsOne() {
    #expect(abs(SmartSearch.cosine([1, 2, 3], [1, 2, 3]) - 1) < 1e-9)
    #expect(SmartSearch.cosine([1, 0], [0, 1]) == 0)
  }
}
