import Foundation
import NaturalLanguage

/// Finds notes by meaning, not just matching words, with Apple's on-device sentence embeddings.
/// Nothing leaves the Mac. Falls back to plain word search when no embedding is available.
@MainActor
final class SmartSearch {
  private var models: [NLLanguage: NLEmbedding] = [:]
  private var cache: [UUID: (Date, [Double])] = [:]
  /// Notes scoring below this are not shown as meaning matches.
  static let minScore = 0.55

  private func model(for text: String) -> NLEmbedding? {
    let lang = NLLanguageRecognizer.dominantLanguage(for: text) ?? .english
    for l in [lang, .english] {
      if let m = models[l] { return m }
      if let m = NLEmbedding.sentenceEmbedding(for: l) {
        models[l] = m
        return m
      }
    }
    return nil
  }

  var available: Bool { model(for: "hello") != nil }

  /// Similarity (0…1) between the query and each note.
  func scores(_ query: String, notes: [(id: UUID, modified: Date, text: String)]) -> [UUID: Double] {
    guard let m = model(for: query), let q = m.vector(for: query) else { return [:] }
    var out: [UUID: Double] = [:]
    for n in notes {
      let v: [Double]
      if let c = cache[n.id], c.0 == n.modified { v = c.1 }
      else {
        guard let nv = m.vector(for: String(n.text.prefix(1500))) else { continue }
        cache[n.id] = (n.modified, nv)
        v = nv
      }
      out[n.id] = Self.cosine(q, v)
    }
    return out
  }

  nonisolated static func cosine(_ a: [Double], _ b: [Double]) -> Double {
    guard a.count == b.count, !a.isEmpty else { return 0 }
    var dot = 0.0, na = 0.0, nb = 0.0
    for i in a.indices {
      dot += a[i] * b[i]
      na += a[i] * a[i]
      nb += b[i] * b[i]
    }
    return na == 0 || nb == 0 ? 0 : dot / (na.squareRoot() * nb.squareRoot())
  }
}
