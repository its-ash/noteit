import Foundation
import Security

/// The two request formats NoteIt speaks. Most providers accept the OpenAI chat format.
enum Wire: String, Codable, CaseIterable, Sendable {
  case openai, anthropic

  var title: String { self == .openai ? "OpenAI-compatible" : "Anthropic Messages" }
}

struct ProviderPreset: Identifiable, Hashable, Sendable {
  let id: String
  let name: String
  let base: String
  let wire: Wire
  let needsKey: Bool
  let model: String
  let keyURL: String?

  static let all: [ProviderPreset] = [
    .init(id: "router", name: "Router (local)", base: "http://127.0.0.1:9694/v1", wire: .openai, needsKey: false, model: "router/auto", keyURL: nil),
    .init(id: "anthropic", name: "Anthropic", base: "https://api.anthropic.com/v1", wire: .anthropic, needsKey: true, model: "claude-opus-5-5", keyURL: "https://platform.claude.com/settings/keys"),
    .init(id: "openai", name: "OpenAI", base: "https://api.openai.com/v1", wire: .openai, needsKey: true, model: "", keyURL: "https://platform.openai.com/api-keys"),
    .init(id: "openrouter", name: "OpenRouter", base: "https://openrouter.ai/api/v1", wire: .openai, needsKey: true, model: "", keyURL: "https://openrouter.ai/keys"),
    .init(id: "gemini", name: "Google Gemini", base: "https://generativelanguage.googleapis.com/v1beta/openai", wire: .openai, needsKey: true, model: "", keyURL: "https://aistudio.google.com/apikey"),
    .init(id: "groq", name: "Groq", base: "https://api.groq.com/openai/v1", wire: .openai, needsKey: true, model: "", keyURL: "https://console.groq.com/keys"),
    .init(id: "ollama", name: "Ollama", base: "http://localhost:11434/v1", wire: .openai, needsKey: false, model: "", keyURL: nil),
    .init(id: "lmstudio", name: "LM Studio", base: "http://localhost:1234/v1", wire: .openai, needsKey: false, model: "", keyURL: nil),
    .init(id: "custom", name: "Custom", base: "", wire: .openai, needsKey: false, model: "", keyURL: nil),
  ]

  static func find(_ id: String) -> ProviderPreset { all.first { $0.id == id } ?? all[0] }
}

/// What to do with the model's answer.
enum ApplyMode: String, Codable, CaseIterable, Sendable {
  case replace, below, review

  var title: String {
    switch self {
    case .replace: "Replace the text"
    case .below: "Insert below the text"
    case .review: "Show a preview first"
    }
  }
}

struct AIAction: Codable, Identifiable, Hashable, Sendable {
  var id = UUID()
  var name: String
  var icon: String
  var prompt: String
  var enabled = true

  static let defaults: [AIAction] = [
    .init(name: "Refine", icon: "sparkles", prompt: "Refine this note. Improve clarity, flow, and wording. Keep the meaning, tone, and language, and keep it about the same length."),
    .init(name: "Fix Spelling and Grammar", icon: "textformat.abc", prompt: "Fix spelling, grammar, and punctuation only. Change nothing else."),
    .init(name: "Make Shorter", icon: "arrow.down.right.and.arrow.up.left", prompt: "Make this note shorter and tighter. Keep every key point."),
    .init(name: "Make Longer", icon: "arrow.up.left.and.arrow.down.right", prompt: "Expand this note with useful detail. Keep the same voice."),
    .init(name: "Summarize", icon: "text.append", prompt: "Summarize this note in two or three sentences."),
    .init(name: "Make a List", icon: "list.bullet", prompt: "Turn this note into a concise bulleted list. Use \"- \" for each bullet."),
    .init(name: "Make a Checklist", icon: "checklist", prompt: "Turn this note into a to-do checklist. Start each item with \"☐ \"."),
    .init(name: "Professional Tone", icon: "briefcase", prompt: "Rewrite this note in a clear, professional tone."),
    .init(name: "Friendly Tone", icon: "face.smiling", prompt: "Rewrite this note in a warm, friendly tone."),
    .init(name: "Translate to English", icon: "character.bubble", prompt: "Translate this note into English. Keep the formatting."),
  ]
}

let DEFAULT_SYSTEM = """
You edit text from a sticky note. Return only the edited text: no preamble, no explanation, no quotes, and no code fences. \
Keep the original language unless the instruction says to translate. Write plain text; simple "- " bullets and line breaks are fine.
"""

struct AIConfig: Codable, Equatable, Sendable {
  var provider = "router"
  var base = ProviderPreset.find("router").base
  var wire: Wire = .openai
  var model = ProviderPreset.find("router").model
  var system = DEFAULT_SYSTEM
  /// Anthropic only. Empty means the model's default.
  var effort = "low"
  /// OpenAI-compatible only. nil means the provider's default.
  var temperature: Double?
  var maxTokens = 16_000
  var timeout: Double = 90
  var apply: ApplyMode = .replace
  var stream = true
  var actions = AIAction.defaults
  var defaultAction: UUID?

  var enabledActions: [AIAction] { actions.filter(\.enabled) }

  var primary: AIAction? {
    enabledActions.first { $0.id == defaultAction } ?? enabledActions.first
  }

  mutating func use(_ p: ProviderPreset) {
    provider = p.id
    wire = p.wire
    if p.id != "custom" { base = p.base }
    model = p.model
  }
}

/// API keys, one per provider, in the login Keychain.
enum Keychain {
  private static let service = "in.itsash.noteit"

  private static func query(_ account: String) -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
  }

  static func key(_ provider: String) -> String {
    var q = query(provider)
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    var out: CFTypeRef?
    guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return "" }
    return String(decoding: d, as: UTF8.self)
  }

  @discardableResult
  static func setKey(_ v: String, for provider: String) -> Bool {
    let v = v.trimmingCharacters(in: .whitespacesAndNewlines)
    SecItemDelete(query(provider) as CFDictionary)
    guard !v.isEmpty else { return true }
    var q = query(provider)
    q[kSecValueData as String] = Data(v.utf8)
    q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
    return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
  }
}

struct AIError: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

/// Reads one server-sent-events stream (or a plain JSON body) and yields text.
struct SSEParser {
  let wire: Wire
  private(set) var text = ""
  private(set) var done = false

  init(_ wire: Wire) { self.wire = wire }

  /// Returns the new text in this line, if any. Throws when the stream reports an error.
  mutating func feed(_ line: String) throws -> String? {
    let t = line.trimmingCharacters(in: .whitespaces)
    guard t.hasPrefix("data:") else { return nil }
    let payload = t.dropFirst(5).trimmingCharacters(in: .whitespaces)
    if payload == "[DONE]" {
      done = true
      return nil
    }
    guard let j = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { return nil }
    try Self.check(j)
    let piece: String?
    switch wire {
    case .openai:
      let d = (j["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any]
      piece = d?["content"] as? String
    case .anthropic:
      switch j["type"] as? String {
      case "content_block_delta":
        let d = j["delta"] as? [String: Any]
        piece = d?["type"] as? String == "text_delta" ? d?["text"] as? String : nil
      case "message_delta":
        try Self.stop((j["delta"] as? [String: Any])?["stop_reason"] as? String)
        piece = nil
      case "message_stop":
        done = true
        piece = nil
      default:
        piece = nil
      }
    }
    guard let piece, !piece.isEmpty else { return nil }
    text += piece
    return piece
  }

  /// Handles a non-streaming JSON response.
  mutating func whole(_ data: Data) throws {
    guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw AIError(message: "The provider sent a response that is not JSON.")
    }
    try Self.check(j)
    switch wire {
    case .openai:
      text = ((j["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String ?? ""
    case .anthropic:
      try Self.stop(j["stop_reason"] as? String)
      text = ((j["content"] as? [[String: Any]]) ?? []).filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
    }
    done = true
  }

  private static func check(_ j: [String: Any]) throws {
    guard let e = j["error"] else { return }
    throw AIError(message: (e as? [String: Any])?["message"] as? String ?? "\(e)")
  }

  private static func stop(_ reason: String?) throws {
    if reason == "refusal" { throw AIError(message: "The model declined to edit this text.") }
  }
}

enum AIClient {
  /// Claude models that accept the server-side refusal fallback.
  private static let FALLBACK_MODELS: Set<String> = ["claude-fable-5-1", "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5"]
  private static let ANTHROPIC_VERSION = "2026-10-21"

  private static let session: URLSession = {
    let c = URLSessionConfiguration.ephemeral
    c.urlCache = nil
    c.httpCookieStorage = nil
    c.httpShouldSetCookies = false
    return URLSession(configuration: c)
  }()

  static func baseURL(_ cfg: AIConfig) throws -> URL {
    let raw = cfg.base.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: raw), let s = url.scheme?.lowercased(), ["http", "https"].contains(s), url.host() != nil else {
      throw AIError(message: "The provider URL in Settings is not a valid http(s) URL.")
    }
    return url
  }

  static func prompt(_ action: AIAction, _ text: String) -> String {
    "\(action.prompt)\n\n<note>\n\(text)\n</note>"
  }

  static func body(_ cfg: AIConfig, user: String) -> [String: Any] {
    let msgs: [[String: Any]] = [["role": "user", "content": user]]
    switch cfg.wire {
    case .openai:
      var b: [String: Any] = ["model": cfg.model, "messages": [["role": "system", "content": cfg.system]] + msgs, "stream": cfg.stream]
      if let t = cfg.temperature { b["temperature"] = t }
      return b
    case .anthropic:
      var b: [String: Any] = ["model": cfg.model, "max_tokens": cfg.maxTokens, "system": cfg.system, "messages": msgs, "stream": cfg.stream]
      if !cfg.effort.isEmpty { b["output_config"] = ["effort": cfg.effort] }
      if usesFallback(cfg) { b["fallbacks"] = "default" }
      return b
    }
  }

  static func usesFallback(_ cfg: AIConfig) -> Bool {
    cfg.wire == .anthropic && FALLBACK_MODELS.contains(cfg.model) && (try? baseURL(cfg).host()) == "api.anthropic.com"
  }

  private static func request(_ cfg: AIConfig, key: String, path: String) throws -> URLRequest {
    var req = URLRequest(url: try baseURL(cfg).appending(path: path))
    req.timeoutInterval = cfg.timeout
    switch cfg.wire {
    case .openai:
      if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
      if cfg.provider == "openrouter" {
        req.setValue("https://github.com/its-ash/noteit", forHTTPHeaderField: "HTTP-Referer")
        req.setValue("NoteIt", forHTTPHeaderField: "X-Title")
      }
    case .anthropic:
      req.setValue(key, forHTTPHeaderField: "x-api-key")
      req.setValue(ANTHROPIC_VERSION, forHTTPHeaderField: "anthropic-version")
    }
    return req
  }

  /// Model ids from the provider's /models endpoint.
  static func models(_ cfg: AIConfig, key: String) async throws -> [String] {
    var req = try request(cfg, key: key, path: "models")
    req.timeoutInterval = 15
    let (data, res) = try await session.data(for: req)
    let status = (res as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else { throw AIError(message: "Error \(status): \(message(data, status))") }
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let items = (json?["data"] ?? json?["models"]) as? [[String: Any]] ?? []
    return items.compactMap { ($0["id"] ?? $0["name"]) as? String }.sorted()
  }

  /// Runs one edit and streams its text. Returns the whole answer.
  static func run(_ cfg: AIConfig, key: String, user: String, onText: @MainActor @Sendable (String) -> Void) async throws -> String {
    guard !cfg.model.trimmingCharacters(in: .whitespaces).isEmpty else {
      throw AIError(message: "Choose a model in NoteIt Settings → AI.")
    }
    var req = try request(cfg, key: key, path: cfg.wire == .openai ? "chat/completions" : "messages")
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("text/event-stream, application/json", forHTTPHeaderField: "Accept")
    if usesFallback(cfg) { req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta") }
    req.httpBody = try JSONSerialization.data(withJSONObject: body(cfg, user: user))

    let bytes: URLSession.AsyncBytes
    let res: URLResponse
    do {
      (bytes, res) = try await session.bytes(for: req)
    }
    catch let e as URLError where e.code == .cancelled {
      throw CancellationError()
    }
    catch is CancellationError {
      throw CancellationError()
    }
    catch {
      throw AIError(message: "Can't reach \(req.url?.host() ?? "the provider"). \(error.localizedDescription)")
    }
    let http = res as? HTTPURLResponse
    let status = http?.statusCode ?? 0
    var parser = SSEParser(cfg.wire)
    var data = Data()
    let json = (http?.value(forHTTPHeaderField: "Content-Type") ?? "").contains("json")
    if !(200..<300).contains(status) || json {
      for try await b in bytes { data.append(b) }
      guard (200..<300).contains(status) else { throw AIError(message: "Error \(status): \(message(data, status))") }
      try parser.whole(data)
      await onText(parser.text)
      return clean(parser.text)
    }
    for try await line in bytes.lines {
      try Task.checkCancellation()
      if let piece = try parser.feed(line) { await onText(piece) }
      if parser.done { break }
    }
    return clean(parser.text)
  }

  /// Strips wrappers models sometimes add despite the instructions.
  static func clean(_ s: String) -> String {
    var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    for (open, close) in [("<note>", "</note>")] where t.hasPrefix(open) && t.hasSuffix(close) {
      t = String(t.dropFirst(open.count).dropLast(close.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if t.hasPrefix("```"), t.hasSuffix("```"), t.count >= 6 {
      var lines = t.components(separatedBy: "\n")
      lines.removeFirst()
      if lines.last?.trimmingCharacters(in: .whitespaces) == "```" { lines.removeLast() }
      t = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return t
  }

  static func message(_ body: Data, _ status: Int) -> String {
    if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
      if let e = json["error"] as? [String: Any], let m = e["message"] as? String { return m }
      if let m = json["error"] as? String ?? json["message"] as? String { return m }
    }
    let text = String(decoding: body.prefix(400), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? HTTPURLResponse.localizedString(forStatusCode: status) : text
  }
}
