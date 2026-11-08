import Foundation

/// Minimal RSS 2.0 + Atom parser (arXiv, Substack, lab blogs).
final class FeedParser: NSObject, XMLParserDelegate {
    struct Entry: Sendable {
        var title = ""
        var link = ""
        var summary = ""
        var author = ""
        var date = ""
        var categories: [String] = []
    }

    private var entries: [Entry] = []
    private var current: Entry?
    private var text = ""
    private var inAuthor = false

    static func parse(_ data: Data) -> [Entry] {
        let p = FeedParser()
        let xml = XMLParser(data: data)
        xml.delegate = p
        xml.parse()
        return p.entries
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String] = [:]) {
        text = ""
        switch name {
        case "item", "entry":
            current = Entry()
        case "author":
            inAuthor = true
        case "link":
            // Atom: <link href="..." rel="alternate"/>
            if let href = attributes["href"], current != nil {
                let rel = attributes["rel"] ?? "alternate"
                if rel == "alternate" || current?.link.isEmpty == true { current?.link = href }
            }
        case "category":
            if let term = attributes["term"] { current?.categories.append(term) }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        text += String(decoding: CDATABlock, as: UTF8.self)
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName qName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard current != nil else { return }
        switch name {
        case "item", "entry":
            if let c = current { entries.append(c) }
            current = nil
        case "title":
            if current?.title.isEmpty == true { current?.title = value }
        case "link":
            if !value.isEmpty, current?.link.isEmpty == true { current?.link = value }
        case "description", "summary", "content:encoded", "content":
            if current?.summary.isEmpty == true || name == "summary" { current?.summary = value }
        case "pubDate", "published", "dc:date", "updated":
            if current?.date.isEmpty == true { current?.date = value }
        case "name", "dc:creator":
            if (inAuthor || name == "dc:creator"), current?.author.isEmpty == true { current?.author = value }
        case "author":
            inAuthor = false
            if current?.author.isEmpty == true, !value.isEmpty { current?.author = value }
        case "category":
            if !value.isEmpty { current?.categories.append(value) }
        default: break
        }
    }
}

enum Text2 {
    /// Strips HTML tags and common entities, collapses whitespace.
    static func plain(_ html: String, limit: Int = 600) -> String {
        var s = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'",
                        "&apos;": "'", "&nbsp;": " ", "&#8217;": "’", "&#8220;": "“", "&#8221;": "”", "&#8212;": "—"]
        for (k, v) in entities { s = s.replacingOccurrences(of: k, with: v) }
        // Remaining numeric entities: &#8230; and &#x2026;
        if let re = try? NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);") {
            for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
                guard let whole = Range(m.range, in: s), let hex = Range(m.range(at: 1), in: s),
                      let num = Range(m.range(at: 2), in: s),
                      let code = UInt32(s[num], radix: s[hex].isEmpty ? 10 : 16),
                      let scalar = Unicode.Scalar(code) else { continue }
                s.replaceSubrange(whole, with: String(Character(scalar)))
            }
        }
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return s.count > limit ? String(s.prefix(limit)) + "…" : s
    }

    static func date(_ s: String) -> Date? {
        if s.isEmpty { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) { return d }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for fmt in ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm:ss zzz", "EEE, d MMM yyyy HH:mm:ss Z", "yyyy-MM-dd"] {
            f.dateFormat = fmt
            if let d = f.date(from: s) { return d }
        }
        return nil
    }
}
