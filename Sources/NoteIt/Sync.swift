import AppKit
import Observation

/// The Firebase project notes sync through. The web API key only identifies the project;
/// access is controlled by Firebase Auth and the Firestore security rules (see README).
enum FirebaseConfig {
  static let apiKey = "AIzaSyAcuH_GTPeK6XR2CO4DT1PUjnzTPEgGauE"
  static let projectId = "its-ash"
  static var documents: String { "projects/\(projectId)/databases/(default)/documents" }
  static let firestore = "https://firestore.googleapis.com/v1/"
}

struct SyncError: LocalizedError {
  let message: String
  var status = 0
  var errorDescription: String? { message }
}

private let session: URLSession = {
  let c = URLSessionConfiguration.ephemeral
  c.timeoutIntervalForRequest = 30
  c.urlCache = nil
  return URLSession(configuration: c)
}()

@MainActor
private func post(_ url: URL, json: Any? = nil, form: String? = nil, token: String? = nil) async throws -> Any {
  var req = URLRequest(url: url)
  req.httpMethod = "POST"
  if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
  if let form {
    req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    req.httpBody = Data(form.utf8)
  }
  else {
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = try JSONSerialization.data(withJSONObject: json ?? [:])
  }
  let data: Data
  let res: URLResponse
  do { (data, res) = try await session.data(for: req) }
  catch { throw SyncError(message: "Can't reach Firebase. \(error.localizedDescription)") }
  let status = (res as? HTTPURLResponse)?.statusCode ?? 0
  let body = try? JSONSerialization.jsonObject(with: data)
  guard (200..<300).contains(status) else {
    let e = (body as? [String: Any])?["error"] ?? ((body as? [[String: Any]])?.first?["error"])
    let msg = ((e as? [String: Any])?["message"] as? String) ?? (e as? String) ?? HTTPURLResponse.localizedString(forStatusCode: status)
    throw SyncError(message: msg, status: status)
  }
  return body ?? [:]
}

// MARK: auth

/// Firebase Auth with email and password, over its REST API.
@MainActor
enum FirebaseAuth {
  struct Tokens: Sendable {
    let idToken: String
    let refreshToken: String
    let uid: String
    let expires: Date
  }

  private static func url(_ path: String) -> URL {
    URL(string: "https://identitytoolkit.googleapis.com/v1/\(path)?key=\(FirebaseConfig.apiKey)")!
  }

  static func signIn(email: String, password: String, create: Bool) async throws -> Tokens {
    do {
      let j = try await post(url(create ? "accounts:signUp" : "accounts:signInWithPassword"), json: ["email": email, "password": password, "returnSecureToken": true]) as? [String: Any] ?? [:]
      guard let id = j["idToken"] as? String, let r = j["refreshToken"] as? String, let uid = j["localId"] as? String else { throw SyncError(message: "Firebase sent an unexpected reply.") }
      return Tokens(idToken: id, refreshToken: r, uid: uid, expires: Date().addingTimeInterval(Double(j["expiresIn"] as? String ?? "3600") ?? 3600))
    }
    catch let e as SyncError { throw SyncError(message: friendly(e.message), status: e.status) }
  }

  static func refresh(_ token: String) async throws -> Tokens {
    let u = URL(string: "https://securetoken.googleapis.com/v1/token?key=\(FirebaseConfig.apiKey)")!
    let escaped = token.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? token
    do {
      let j = try await post(u, form: "grant_type=refresh_token&refresh_token=\(escaped)") as? [String: Any] ?? [:]
      guard let id = j["id_token"] as? String, let r = j["refresh_token"] as? String, let uid = j["user_id"] as? String else { throw SyncError(message: "Firebase sent an unexpected reply.") }
      return Tokens(idToken: id, refreshToken: r, uid: uid, expires: Date().addingTimeInterval(Double(j["expires_in"] as? String ?? "3600") ?? 3600))
    }
    catch let e as SyncError { throw SyncError(message: friendly(e.message), status: e.status == 400 ? 401 : e.status) }
  }

  static func sendPasswordReset(email: String) async throws {
    do { _ = try await post(url("accounts:sendOobCode"), json: ["requestType": "PASSWORD_RESET", "email": email]) }
    catch let e as SyncError { throw SyncError(message: friendly(e.message), status: e.status) }
  }

  nonisolated static func friendly(_ code: String) -> String {
    let c = code.components(separatedBy: " ").first ?? code
    switch c {
    case "EMAIL_EXISTS": return "An account with this email already exists. Sign in instead."
    case "EMAIL_NOT_FOUND", "INVALID_PASSWORD", "INVALID_LOGIN_CREDENTIALS": return "The email or password is wrong."
    case "INVALID_EMAIL": return "That email address isn't valid."
    case "WEAK_PASSWORD": return "Use a password of at least 6 characters."
    case "USER_DISABLED": return "This account has been disabled."
    case "TOO_MANY_ATTEMPTS_TRY_LATER": return "Too many attempts. Try again later."
    case "OPERATION_NOT_ALLOWED": return "Email sign-in is turned off for this Firebase project. Turn on Email/Password in Firebase Console → Authentication → Sign-in method."
    case "TOKEN_EXPIRED", "INVALID_REFRESH_TOKEN", "USER_NOT_FOUND": return "Your sign-in expired. Sign in again."
    default: return code
    }
  }
}

// MARK: Firestore documents

/// A note as stored in Firestore at users/{uid}/notes/{noteId}.
struct RemoteNote: Equatable {
  var id: UUID
  var deleted = false
  var modified: Date
  var name = ""
  var text = ""
  var rtfd: Data?
  var rtf: Data?
  var markdown: String?
  var color: NoteColor = .yellow
  var notebook = ""
  var favorite = false
  var archived = false
  var trashed: Date?
  var remind: Date?
  var created = Date()
  /// Server time of the last write; the pull cursor.
  var syncedAt: String?
  var path = ""
}

enum MergeAction: Equatable { case apply, delete, keepLocal, skip }

enum FireCodec {
  /// Firestore documents hold at most 1 MiB; keep rich text well under that.
  static let maxBytes = 900_000
  static let eps = 0.001
  /// Every field the Mac writes. Writes replace only these, so fields added by other apps (such as Android) survive.
  /// A field in this list but missing from a write is removed, which clears stale `rtfd`, `rtf`, or `markdown`.
  static let fieldNames = [
    "name", "text", "markdown", "rtfd", "rtf", "color", "notebook", "favorite", "archived",
    "trashed", "remind", "created", "modified", "deleted", "schema",
  ]

  /// One Firestore write: set the Mac's fields, keep any others, and stamp `syncedAt` with the server time.
  static func write(_ name: String, _ fields: [String: Any]) -> [String: Any] {
    [
      "update": ["name": name, "fields": fields],
      "updateMask": ["fieldPaths": fieldNames],
      "updateTransforms": [["fieldPath": "syncedAt", "setToServerValue": "REQUEST_TIME"]],
    ]
  }

  private static func s(_ v: String) -> [String: Any] { ["stringValue": v] }
  private static func b(_ v: Bool) -> [String: Any] { ["booleanValue": v] }
  private static func d(_ v: Date?) -> [String: Any] { v.map { ["doubleValue": $0.timeIntervalSince1970] } ?? ["nullValue": NSNull()] }
  private static func bytes(_ v: Data) -> [String: Any] { ["bytesValue": v.base64EncodedString()] }

  /// Firestore fields for a note. Desktop state (pinned, position, size) stays on each Mac.
  static func fields(_ n: Note) -> [String: Any] {
    let a = n.attributed
    let text = a.string
    var f: [String: Any] = [
      "name": s(n.name), "text": s(text), "color": s(n.color.rawValue), "notebook": s(n.notebook),
      "favorite": b(n.favorite), "archived": b(n.archived), "trashed": d(n.trashed), "remind": d(n.remind),
      "created": d(n.created), "modified": d(n.modified), "deleted": b(false), "schema": ["integerValue": "1"],
    ]
    var budget = maxBytes - text.utf8.count - n.name.utf8.count
    let md = MarkdownText.from(a)
    if md.utf8.count < budget / 2 {
      f["markdown"] = s(md)
      budget -= md.utf8.count
    }
    if n.rtfd.count <= budget { f["rtfd"] = bytes(n.rtfd) }
    else if let rtf = try? a.data(from: NSRange(location: 0, length: a.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]), rtf.count <= budget {
      f["rtf"] = bytes(rtf)
    }
    return f
  }

  static func tombstone(_ at: Date) -> [String: Any] {
    ["deleted": b(true), "modified": d(at), "schema": ["integerValue": "1"]]
  }

  private static func value(_ f: [String: Any], _ k: String) -> [String: Any]? { f[k] as? [String: Any] }
  private static func str(_ f: [String: Any], _ k: String) -> String? { value(f, k)?["stringValue"] as? String }
  private static func bool(_ f: [String: Any], _ k: String) -> Bool { value(f, k)?["booleanValue"] as? Bool ?? false }
  private static func date(_ f: [String: Any], _ k: String) -> Date? {
    guard let v = value(f, k) else { return nil }
    if let n = v["doubleValue"] as? NSNumber { return Date(timeIntervalSince1970: n.doubleValue) }
    if let s = v["integerValue"] as? String, let i = Double(s) { return Date(timeIntervalSince1970: i) }
    if let s = v["timestampValue"] as? String { return ISO8601DateFormatter().date(from: s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)) }
    return nil
  }
  private static func data(_ f: [String: Any], _ k: String) -> Data? {
    (value(f, k)?["bytesValue"] as? String).flatMap { Data(base64Encoded: $0) }
  }

  /// A note from a Firestore document (`{name, fields}`), or nil if it is not a note.
  static func decode(_ doc: [String: Any]) -> RemoteNote? {
    guard let path = doc["name"] as? String, let id = UUID(uuidString: (path as NSString).lastPathComponent) else { return nil }
    let f = doc["fields"] as? [String: Any] ?? [:]
    var r = RemoteNote(id: id, modified: date(f, "modified") ?? .distantPast)
    r.path = path
    r.deleted = bool(f, "deleted")
    r.syncedAt = value(f, "syncedAt")?["timestampValue"] as? String
    r.name = str(f, "name") ?? ""
    r.text = str(f, "text") ?? ""
    r.rtfd = data(f, "rtfd")
    r.rtf = data(f, "rtf")
    r.markdown = str(f, "markdown")
    r.color = NoteColor(rawValue: str(f, "color") ?? "") ?? .yellow
    r.notebook = str(f, "notebook") ?? ""
    r.favorite = bool(f, "favorite")
    r.archived = bool(f, "archived")
    r.trashed = date(f, "trashed")
    r.remind = date(f, "remind")
    r.created = date(f, "created") ?? r.modified
    return r
  }

  /// Last writer wins, by each note's modified time. A deletion wins unless the note was edited after it.
  static func decide(_ r: RemoteNote, local: Note?, tombstoned: Bool) -> MergeAction {
    let rt = r.modified.timeIntervalSince1970
    if r.deleted {
      guard let local else { return .skip }
      return local.modified.timeIntervalSince1970 > rt + eps ? .keepLocal : .delete
    }
    if tombstoned { return .skip }
    guard let local else { return .apply }
    return rt > local.modified.timeIntervalSince1970 + eps ? .apply : .keepLocal
  }

  /// Rich text from the `markdown` field, as written by Android or another app.
  /// Used only when it matches `text`, so a client that updated `text` alone never gets old Markdown back.
  @MainActor
  static func formatted(_ r: RemoteNote, font: NSFont) -> NSAttributedString? {
    guard let md = r.markdown, !md.isEmpty else { return nil }
    let a = MarkdownText.toNote(md, font: font, takeTitle: false).text
    func norm(_ s: String) -> String { s.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines) }
    return norm(a.string) == norm(r.text) ? a : nil
  }

  /// The local note after taking the remote content. Keeps this Mac's pin, position, and size.
  @MainActor
  static func merge(_ r: RemoteNote, into local: Note?, font: NSFont) -> Note {
    var n = local ?? Note()
    if local == nil {
      n.id = r.id
      n.pinned = false
    }
    n.name = r.name
    n.color = r.color
    n.notebook = r.notebook
    n.favorite = r.favorite
    n.archived = r.archived
    n.trashed = r.trashed
    n.remind = r.remind
    n.created = r.created
    if let d = r.rtfd, d.isEmpty || NSAttributedString(rtfd: d, documentAttributes: nil) != nil { n.rtfd = d }
    else if let d = r.rtf, let a = NSAttributedString(rtf: d, documentAttributes: nil) { n.attributed = a }
    else if let a = formatted(r, font: font) { n.attributed = a }
    else if r.text != n.plain { n.attributed = NSAttributedString(string: r.text, attributes: noteAttributes(font)) }
    if !n.isLive { n.pinned = false }
    n.modified = r.modified
    return n
  }
}

// MARK: engine

/// What this Mac remembers about sync, in Application Support/NoteIt/sync.json.
struct SyncState: Codable, Equatable {
  var uid: String?
  var email = ""
  var cursorTime: String?
  var cursorName: String?
  /// The modified time last sent or received, per note id.
  var synced: [String: Double] = [:]
  /// Notes deleted here and not yet deleted in the cloud, with the time of deletion.
  var tombstones: [String: Double] = [:]
}

/// Keeps notes in step with Firestore: pulls changes since the last sync, then pushes local edits.
@MainActor
@Observable
final class Sync {
  static let shared = Sync()
  private static let REFRESH = "firebase.refresh"
  private static let PAGE = 200
  private static let BATCH = 20

  enum Phase: Equatable { case signedOut, idle, syncing, failed(String) }

  private(set) var phase: Phase = .signedOut
  private(set) var lastSync: Date?
  var email: String { state.email }
  var signedIn: Bool { state.uid != nil }

  @ObservationIgnored private let store: NoteStore
  @ObservationIgnored private let texts: NoteTexts
  @ObservationIgnored private let prefs: Prefs
  @ObservationIgnored private let file: URL
  @ObservationIgnored private var state = SyncState()
  @ObservationIgnored private var idToken: (String, Date)?
  @ObservationIgnored private var timer: Timer?
  @ObservationIgnored private var pushSoon: Task<Void, Never>?
  @ObservationIgnored private var running = false
  @ObservationIgnored private var again = false
  @ObservationIgnored private var applyingRemote = false
  @ObservationIgnored private var observing = false

  init(store: NoteStore = .shared, texts: NoteTexts = .shared, prefs: Prefs = .shared, file: URL = AppPaths.support.appending(path: "sync.json")) {
    self.store = store
    self.texts = texts
    self.prefs = prefs
    self.file = file
    if let d = try? Data(contentsOf: file), let s = try? JSONDecoder().decode(SyncState.self, from: d) { state = s }
    if state.uid != nil, Keychain.key(Self.REFRESH).isEmpty { state = SyncState() }
    phase = state.uid == nil ? .signedOut : .idle
  }

  /// Starts syncing in the background when signed in.
  func start() {
    if !observing {
      observing = true
      NotificationCenter.default.addObserver(self, selector: #selector(localChange), name: .notesChanged, object: store)
      NotificationCenter.default.addObserver(self, selector: #selector(localDelete(_:)), name: .noteDeleted, object: store)
      NotificationCenter.default.addObserver(self, selector: #selector(becameActive), name: NSApplication.didBecomeActiveNotification, object: nil)
    }
    guard signedIn else { return }
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
      MainActor.assumeIsolated { Sync.shared.syncNow() }
    }
    syncNow()
  }

  func signIn(email: String, password: String, create: Bool) async throws {
    phase = .syncing
    do {
      let t = try await FirebaseAuth.signIn(email: email.trimmingCharacters(in: .whitespaces), password: password, create: create)
      if state.uid != t.uid { state = SyncState(uid: t.uid) }
      state.email = email.trimmingCharacters(in: .whitespaces)
      Keychain.setKey(t.refreshToken, for: Self.REFRESH)
      idToken = (t.idToken, t.expires)
      saveState()
      start()
    }
    catch {
      phase = signedIn ? .idle : .signedOut
      throw error
    }
  }

  func signOut() {
    timer?.invalidate()
    timer = nil
    pushSoon?.cancel()
    Keychain.setKey("", for: Self.REFRESH)
    idToken = nil
    state = SyncState()
    saveState()
    phase = .signedOut
    lastSync = nil
  }

  func resetPassword(email: String) async throws {
    try await FirebaseAuth.sendPasswordReset(email: email.trimmingCharacters(in: .whitespaces))
  }

  @objc private func becameActive() { if signedIn { syncNow() } }

  @objc private func localChange() {
    guard signedIn, !applyingRemote else { return }
    pushSoon?.cancel()
    pushSoon = Task { [weak self] in
      try? await Task.sleep(for: .seconds(3))
      guard !Task.isCancelled else { return }
      self?.syncNow()
    }
  }

  @objc private func localDelete(_ n: Notification) {
    guard signedIn, !applyingRemote, let id = n.userInfo?["id"] as? UUID else { return }
    state.tombstones[id.uuidString] = Date().timeIntervalSince1970
    state.synced.removeValue(forKey: id.uuidString)
    saveState()
  }

  /// Syncs now, or again right after the sync that is running.
  func syncNow() {
    guard signedIn else { return }
    if running {
      again = true
      return
    }
    running = true
    phase = .syncing
    Task {
      defer { running = false }
      repeat {
        again = false
        do {
          do { try await once() }
          catch let e as SyncError where e.status == 401 {
            idToken = nil
            try await once()
          }
          lastSync = Date()
          phase = .idle
        }
        catch let e as SyncError where e.status == 401 {
          phase = .failed(FirebaseAuth.friendly("TOKEN_EXPIRED"))
        }
        catch {
          phase = .failed(Self.explain(error))
        }
      } while again && signedIn
    }
  }

  private static func explain(_ error: Error) -> String {
    guard let e = error as? SyncError else { return error.localizedDescription }
    if e.status == 403 || e.message.contains("PERMISSION_DENIED") || e.message.contains("permissions") {
      return "Firestore denied access. Add the security rules from the NoteIt README in Firebase Console → Firestore → Rules."
    }
    if e.status == 404 || e.message.contains("does not exist") {
      return "This Firebase project has no Firestore database yet. Create one in Firebase Console → Firestore Database."
    }
    return e.message
  }

  private func token() async throws -> String {
    if let cached = idToken, cached.1 > Date().addingTimeInterval(60) { return cached.0 }
    let refresh = Keychain.key(Self.REFRESH)
    guard !refresh.isEmpty else { throw SyncError(message: FirebaseAuth.friendly("TOKEN_EXPIRED"), status: 401) }
    let t = try await FirebaseAuth.refresh(refresh)
    Keychain.setKey(t.refreshToken, for: Self.REFRESH)
    idToken = (t.idToken, t.expires)
    return t.idToken
  }

  private func once() async throws {
    let t = try await token()
    guard let uid = state.uid else { return }
    try await pull(t, uid)
    texts.commitAll()
    try await push(t, uid)
    saveState()
  }

  private func pull(_ token: String, _ uid: String) async throws {
    let url = URL(string: FirebaseConfig.firestore + FirebaseConfig.documents + "/users/\(uid):runQuery")!
    while true {
      var q: [String: Any] = [
        "from": [["collectionId": "notes"]],
        "orderBy": [["field": ["fieldPath": "syncedAt"], "direction": "ASCENDING"], ["field": ["fieldPath": "__name__"], "direction": "ASCENDING"]],
        "limit": Self.PAGE,
      ]
      if let ct = state.cursorTime, let cn = state.cursorName {
        q["startAt"] = ["values": [["timestampValue": ct], ["referenceValue": cn]], "before": false]
      }
      let rows = try await post(url, json: ["structuredQuery": q], token: token) as? [[String: Any]] ?? []
      let docs = rows.compactMap { $0["document"] as? [String: Any] }
      applyingRemote = true
      for doc in docs {
        guard let r = FireCodec.decode(doc) else { continue }
        apply(r)
        if let ts = r.syncedAt {
          state.cursorTime = ts
          state.cursorName = r.path
        }
      }
      applyingRemote = false
      if docs.count < Self.PAGE { break }
    }
  }

  private func apply(_ r: RemoteNote) {
    let key = r.id.uuidString
    let local = store.note(r.id)
    switch FireCodec.decide(r, local: local, tombstoned: state.tombstones[key] != nil) {
    case .apply:
      store.update(FireCodec.merge(r, into: local, font: prefs.font))
      texts.reload(r.id)
      state.synced[key] = r.modified.timeIntervalSince1970
    case .delete:
      store.remove(r.id)
      state.synced.removeValue(forKey: key)
    case .keepLocal:
      if let local, abs(local.modified.timeIntervalSince1970 - r.modified.timeIntervalSince1970) <= FireCodec.eps {
        state.synced[key] = r.modified.timeIntervalSince1970
      }
    case .skip:
      break
    }
  }

  private func push(_ token: String, _ uid: String) async throws {
    let prefix = "\(FirebaseConfig.documents)/users/\(uid)/notes/"
    var writes: [(write: [String: Any], done: () -> Void)] = []
    for n in store.notes {
      let key = n.id.uuidString
      let m = n.modified.timeIntervalSince1970
      guard m > (state.synced[key] ?? -1) + FireCodec.eps else { continue }
      writes.append((FireCodec.write(prefix + key, FireCodec.fields(n)), { [weak self] in self?.state.synced[key] = m }))
    }
    for (key, at) in state.tombstones {
      writes.append((FireCodec.write(prefix + key, FireCodec.tombstone(Date(timeIntervalSince1970: at))), { [weak self] in self?.state.tombstones.removeValue(forKey: key) }))
    }
    let url = URL(string: FirebaseConfig.firestore + FirebaseConfig.documents + ":commit")!
    var i = 0
    while i < writes.count {
      let batch = Array(writes[i..<min(i + Self.BATCH, writes.count)])
      _ = try await post(url, json: ["writes": batch.map(\.write)], token: token)
      batch.forEach { $0.done() }
      saveState()
      i += Self.BATCH
    }
  }

  private func saveState() {
    guard let d = try? JSONEncoder().encode(state) else { return }
    try? d.write(to: file, options: .atomic)
  }
}
