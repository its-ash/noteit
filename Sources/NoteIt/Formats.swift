import AppKit
import UniformTypeIdentifiers

// MARK: checklists

/// Checklist items are lines that start with ☐ (open) or ☑ (done).
enum Checklist {
  static let open: Character = "☐"
  static let done: Character = "☑"
  private static let boxes: Set<Character> = ["☐", "☑", "☒"]

  static func isBox(_ c: Character) -> Bool { boxes.contains(c) }

  static func toggled(_ c: Character) -> Character { c == open ? done : open }

  /// Done and total checklist items in the text.
  static func progress(_ text: String) -> (done: Int, total: Int) {
    var done = 0, total = 0
    for line in text.split(whereSeparator: \.isNewline) {
      guard let c = line.drop(while: { $0 == " " || $0 == "\t" }).first, isBox(c) else { continue }
      total += 1
      if c != open { done += 1 }
    }
    return (done, total)
  }

  /// Adds "☐ " to each line in `range`, or removes the boxes when every line already has one.
  /// Returns the range of whole lines touched and their new text.
  static func toggleLines(_ text: NSString, range: NSRange) -> (NSRange, String) {
    let lines = text.lineRange(for: range)
    let body = text.substring(with: lines)
    var parts = body.components(separatedBy: "\n")
    let trailing = parts.last == "" && parts.count > 1
    if trailing { parts.removeLast() }
    let all = parts.allSatisfy { $0.first.map(isBox) ?? false }
    parts = parts.map { line in
      if all { return String(line.dropFirst().drop { $0 == " " }) }
      return line.first.map(isBox) == true ? line : "\(open) " + line
    }
    return (lines, parts.joined(separator: "\n") + (trailing ? "\n" : ""))
  }
}

// MARK: snapping

/// Where a sticky lands when it is dropped near a screen edge or another sticky.
enum Snap {
  static let threshold: CGFloat = 10
  static let gap: CGFloat = 8

  static func origin(for f: NSRect, screens: [NSRect], others: [NSRect]) -> NSPoint {
    var xs: [CGFloat] = []
    var ys: [CGFloat] = []
    for s in screens where s.insetBy(dx: -threshold, dy: -threshold).intersects(f) {
      xs += [s.minX, s.maxX - f.width]
      ys += [s.minY, s.maxY - f.height]
    }
    for o in others where o.insetBy(dx: -40, dy: -40).intersects(f) {
      // Line up edges, or sit next to, above, or below the other note.
      xs += [o.minX, o.maxX - f.width, o.maxX + gap, o.minX - gap - f.width]
      ys += [o.minY, o.maxY - f.height, o.minY - gap - f.height, o.maxY + gap]
    }
    func best(_ v: CGFloat, _ cands: [CGFloat]) -> CGFloat {
      cands.filter { abs($0 - v) <= threshold }.min { abs($0 - v) < abs($1 - v) } ?? v
    }
    return NSPoint(x: best(f.minX, xs), y: best(f.minY, ys))
  }
}

// MARK: Markdown

extension UTType {
  static let markdownText = UTType(filenameExtension: "md", conformingTo: .plainText) ?? .plainText
}

enum MarkdownText {
  /// Markdown for a note: the title as a heading when it has one, bold and italic, links, and checklists.
  static func from(_ a: NSAttributedString, title: String = "") -> String {
    var out: [String] = []
    if !title.isEmpty { out += ["# \(title)", ""] }
    let ns = a.string as NSString
    var loc = 0
    while loc < ns.length {
      var end = 0, contentsEnd = 0
      ns.getLineStart(nil, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: loc, length: 0))
      out.append(line(a, NSRange(location: loc, length: contentsEnd - loc)))
      loc = end
    }
    if ns.length > 0, ns.character(at: ns.length - 1) == 10 { out.append("") }
    return out.joined(separator: "\n")
  }

  private static func line(_ a: NSAttributedString, _ r: NSRange) -> String {
    var s = ""
    a.enumerateAttributes(in: r) { attrs, rr, _ in
      var t = (a.string as NSString).substring(with: rr).replacingOccurrences(of: "\u{FFFC}", with: "")
      guard !t.trimmingCharacters(in: .whitespaces).isEmpty else { s += t; return }
      let traits = (attrs[.font] as? NSFont)?.fontDescriptor.symbolicTraits ?? []
      let lead = String(t.prefix { $0 == " " }), tail = String(t.reversed().prefix { $0 == " " })
      t = t.trimmingCharacters(in: .whitespaces)
      if traits.contains(.italic) { t = "_\(t)_" }
      if traits.contains(.bold) { t = "**\(t)**" }
      if let link = attrs[.link] { t = "[\(t)](\((link as? URL)?.absoluteString ?? "\(link)"))" }
      s += lead + t + tail
    }
    // List markers from the text system, and checklist boxes.
    if let m = s.range(of: #"^\t?[•◦▪–-]\t"#, options: .regularExpression) { s.replaceSubrange(m, with: "- ") }
    if let m = s.range(of: #"^\t?(\d+)[.)]\t"#, options: .regularExpression) {
      let n = s[m].filter(\.isNumber)
      s.replaceSubrange(m, with: "\(n). ")
    }
    if let c = s.first, Checklist.isBox(c) {
      s = (c == Checklist.open ? "- [ ] " : "- [x] ") + s.dropFirst().drop { $0 == " " }
    }
    return s
  }

  /// A note from Markdown. With `takeTitle`, a leading `# Title` becomes the note's title.
  @MainActor
  static func toNote(_ md: String, font: NSFont, takeTitle: Bool = true) -> (title: String, text: NSAttributedString) {
    var lines = md.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    var title = ""
    if takeTitle, let first = lines.first, first.hasPrefix("# ") {
      title = String(first.dropFirst(2)).trimmingCharacters(in: .whitespaces)
      lines.removeFirst()
      while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
    }
    let out = NSMutableAttributedString()
    let base = noteAttributes(font)
    for (i, raw) in lines.enumerated() {
      var l = raw
      var lineFont = font
      if let m = l.range(of: #"^#{1,6} "#, options: .regularExpression) {
        let level = l[m].filter { $0 == "#" }.count
        l.removeSubrange(m)
        lineFont = NSFontManager.shared.convert(font.withSize(font.pointSize + CGFloat(max(0, 4 - level)) * 2 + 1), toHaveTrait: .boldFontMask)
      }
      if l.hasPrefix("- [ ] ") || l.hasPrefix("* [ ] ") { l = "\(Checklist.open) " + l.dropFirst(6) }
      else if l.lowercased().hasPrefix("- [x] ") || l.lowercased().hasPrefix("* [x] ") { l = "\(Checklist.done) " + l.dropFirst(6) }
      else if l.hasPrefix("* ") { l = "- " + l.dropFirst(2) }
      out.append(inline(l, font: lineFont, base: base))
      if i < lines.count - 1 { out.append(NSAttributedString(string: "\n", attributes: base)) }
    }
    return (title, out)
  }

  @MainActor
  private static func inline(_ s: String, font: NSFont, base: [NSAttributedString.Key: Any]) -> NSAttributedString {
    var attrs = base
    attrs[.font] = font
    guard let parsed = try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
      return NSAttributedString(string: s, attributes: attrs)
    }
    let out = NSMutableAttributedString()
    for run in parsed.runs {
      var a = attrs
      var f = font
      let intent = run.inlinePresentationIntent ?? []
      if intent.contains(.stronglyEmphasized) { f = NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask) }
      if intent.contains(.emphasized) { f = NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask) }
      if intent.contains(.code) { f = .monospacedSystemFont(ofSize: f.pointSize, weight: .regular) }
      if intent.contains(.strikethrough) { a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
      a[.font] = f
      if let link = run.link { a[.link] = link }
      out.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: a))
    }
    return out
  }
}
