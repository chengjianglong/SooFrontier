import Foundation

/// A figure from a paper, with its caption.
struct PaperFigure: Codable, Hashable, Identifiable, Sendable {
    var url: URL
    var caption: String
    var id: URL { url }

    /// "Figure 2" from "Figure 2: Omni-modal parsing…", if present.
    var label: String? {
        guard let r = caption.range(of: "^(Figure|Fig\\.)\\s*\\d+", options: .regularExpression) else { return nil }
        return String(caption[r])
    }

    var number: Int? { label.flatMap { Int($0.filter(\.isNumber)) } }

    /// Pipeline, framework, architecture, and overview figures come first; early figures beat appendix ones.
    var importance: Int {
        let c = caption.lowercased()
        let words = ["pipeline", "framework", "architecture", "overview", "method", "approach", "illustration of", "workflow"]
        var score = words.filter(c.contains).count * 2
        switch number ?? 99 {
        case ...3: score += 2
        case 4...6: score += 1
        case 11...: score -= 4
        default: break
        }
        return score
    }
}

/// The full text and figures of a paper or article, read from its web page.
struct PaperContent: Sendable {
    var text: String
    var figures: [PaperFigure]

    /// The most informative figures, pipeline and framework diagrams first, in paper order.
    func keyFigures(_ limit: Int = 3) -> [PaperFigure] {
        let ranked = figures.enumerated().sorted { a, b in
            a.element.importance != b.element.importance ? a.element.importance > b.element.importance : a.offset < b.offset
        }
        let picked = Set(ranked.filter { $0.element.importance > 0 }.prefix(limit).map(\.element))
        return figures.filter(picked.contains)
    }
}

enum PaperReader {
    /// Reads arXiv papers through their HTML edition, and other links as plain web pages.
    static func read(_ item: FrontierItem, maxChars: Int = 45_000) async -> PaperContent? {
        var url = item.url
        if let id = arxivID(item.url) { url = URL(string: "https://arxiv.org/html/\(id)")! }
        guard let (data, resp) = try? await Net.session.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let html = String(decoding: data, as: UTF8.self)
        let base = resp.url ?? url
        let figures = parseFigures(html, base: base)
        let text = bodyText(html, maxChars: maxChars)
        guard text.count > 500 || !figures.isEmpty else { return nil }
        return PaperContent(text: text, figures: figures)
    }

    static func arxivID(_ url: URL) -> String? {
        guard url.host()?.contains("arxiv.org") == true else { return nil }
        let parts = url.path().split(separator: "/")
        guard let i = parts.firstIndex(where: { ["abs", "pdf", "html"].contains($0) }), i + 1 < parts.count else { return nil }
        return String(parts[i + 1]).replacingOccurrences(of: ".pdf", with: "")
    }

    private static func parseFigures(_ html: String, base: URL) -> [PaperFigure] {
        guard let figRE = try? NSRegularExpression(pattern: "<figure[^>]*>(.*?)</figure>", options: [.dotMatchesLineSeparators]),
              let imgRE = try? NSRegularExpression(pattern: "<img[^>]*src=\"([^\"]+)\"", options: []),
              let capRE = try? NSRegularExpression(pattern: "<figcaption[^>]*>(.*?)</figcaption>", options: [.dotMatchesLineSeparators])
        else { return [] }
        var out: [PaperFigure] = []
        var seen = Set<URL>()
        let ns = html as NSString
        for m in figRE.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let inner = ns.substring(with: m.range(at: 1))
            let innerNS = inner as NSString
            guard let img = imgRE.firstMatch(in: inner, range: NSRange(location: 0, length: innerNS.length)),
                  let cap = capRE.matches(in: inner, range: NSRange(location: 0, length: innerNS.length)).last
            else { continue }
            let src = innerNS.substring(with: img.range(at: 1))
            let caption = Text2.plain(innerNS.substring(with: cap.range(at: 1)), limit: 400)
            guard let url = URL(string: src, relativeTo: base)?.absoluteURL, !src.hasPrefix("data:"),
                  caption.range(of: "^(Figure|Fig\\.)", options: .regularExpression) != nil,
                  seen.insert(url).inserted else { continue }
            out.append(PaperFigure(url: url, caption: caption))
        }
        return out
    }

    private static func bodyText(_ html: String, maxChars: Int) -> String {
        var h = html
        if let a = h.range(of: "<article"), let b = h.range(of: "</article>", options: .backwards), a.lowerBound < b.lowerBound {
            h = String(h[a.lowerBound..<b.upperBound])
        }
        // arXiv math carries a hidden LaTeX copy of every value; drop it so numbers aren't doubled.
        h = h.replacingOccurrences(of: "<annotation[^>]*>.*?</annotation>", with: "", options: [.regularExpression, .caseInsensitive])
        h = h.replacingOccurrences(of: "<annotation-xml[^>]*>.*?</annotation-xml>", with: "", options: [.regularExpression, .caseInsensitive])
        for tag in ["script", "style", "nav", "header", "footer"] {
            h = h.replacingOccurrences(of: "<\(tag)[^>]*>.*?</\(tag)>", with: " ", options: [.regularExpression, .caseInsensitive])
        }
        // Keep paragraph breaks so the model can see section structure.
        h = h.replacingOccurrences(of: "</(p|h[1-6]|li|figcaption|section)>", with: "\n", options: .regularExpression)
        let text = h.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .components(separatedBy: "\n")
            .map { Text2.plain($0, limit: 100_000) }
            .filter { $0.count > 2 }
            .joined(separator: "\n")
        return text.count > maxChars ? String(text.prefix(maxChars)) + "\n[…truncated]" : text
    }
}

/// Pulls the most important sentences out of a summary and (for papers) the full text, without calling a model.
enum KeyPoints {
    private enum Kind: String {
        case contribution = "Contribution", method = "Method", result = "Result", finding = "Finding", limitation = "Limitation"
    }

    static func extract(summary: String, fullText: String?, exclude: String, limit: Int = 6) -> [String] {
        var candidates: [(kind: Kind, text: String, score: Int, order: Int)] = []
        var order = 0
        func consider(_ source: String, bonus: Int) {
            source.enumerateSubstrings(in: source.startIndex..., options: .bySentences) { s, _, _, _ in
                guard let raw = s?.trimmingCharacters(in: .whitespacesAndNewlines), raw.count > 60, raw.count < 420,
                      !exclude.contains(raw),
                      raw.range(of: "(Section|Appendix|Sec\\.)\\s*[A-Z0-9]", options: .regularExpression) == nil else { return }
                let l = raw.lowercased()
                var kind: Kind?
                var score = bonus
                if l.contains("we propose") || l.contains("we introduce") || l.contains("we present") || l.contains("our contribution")
                    || l.contains("this paper") || l.contains("in this work") { kind = .contribution; score += 3 }
                if l.range(of: "\\d+(\\.\\d+)?\\s?(%|x|×|points|pp)|outperform|state-of-the-art|sota|surpass|improv(es|ement) .*by", options: .regularExpression) != nil {
                    kind = .result; score += 4
                }
                if kind == nil, l.range(of: "consists of|comprises|we (train|design|use|build|employ)|our (pipeline|architecture|framework|model|method)", options: .regularExpression) != nil {
                    kind = .method; score += 2
                }
                if kind == nil, l.range(of: "we (find|show|observe|demonstrate)|reveal|suggest", options: .regularExpression) != nil {
                    kind = .finding; score += 2
                }
                if kind == nil, l.range(of: "limitation|however|fails? to|does not|cannot", options: .regularExpression) != nil {
                    kind = .limitation; score += 1
                }
                guard let kind else { return }
                candidates.append((kind, raw, score, order)); order += 1
            }
        }
        consider(summary, bonus: 2)
        if let fullText { consider(String(fullText.prefix(25_000)), bonus: 0) }

        // Best sentences, at most two of each kind, then shown in reading order.
        var perKind: [Kind: Int] = [:]
        var kept: [Set<String>] = []
        func words(_ t: String) -> Set<String> { Set(t.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 3 }) }
        let chosen = candidates.sorted { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }.filter { c in
            let w = words(c.text)
            // Skip a sentence that mostly repeats one already chosen (abstract vs. introduction).
            let repeats = kept.contains { k in Double(k.intersection(w).count) / Double(max(1, min(k.count, w.count))) > 0.4 }
            guard perKind[c.kind, default: 0] < 2, !repeats else { return false }
            perKind[c.kind, default: 0] += 1
            kept.append(w)
            return true
        }.prefix(limit).sorted { $0.order < $1.order }
        return chosen.map { "**\($0.kind.rawValue):** \(tidy($0.text))" }
    }

    /// Fixes spacing left by markup: "( IDM )" → "(IDM)", "Youtu ," → "Youtu,".
    private static func tidy(_ s: String) -> String {
        s.replacingOccurrences(of: "\\(\\s+", with: "(", options: .regularExpression)
            .replacingOccurrences(of: "\\s+\\)", with: ")", options: .regularExpression)
            .replacingOccurrences(of: "\\s+([,.;:%])", with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
    }
}

extension KeyPoints {
    /// What the authors themselves say is left for future work, as opportunities.
    static func futureWork(_ text: String?, limit: Int = 3) -> [String] {
        guard let text else { return [] }
        var out: [String] = []
        let tail = String(text.suffix(30_000))
        tail.enumerateSubstrings(in: tail.startIndex..., options: .bySentences) { s, _, _, stop in
            guard let raw = s?.trimmingCharacters(in: .whitespacesAndNewlines), raw.count > 50, raw.count < 360 else { return }
            let l = raw.lowercased()
            if l.range(of: "future work|future research|we leave|left for future|remains (open|unexplored|an open)|could be extended|promising direction|natural extension|limitation", options: .regularExpression) != nil {
                out.append("**From the authors:** " + raw)
                if out.count == limit { stop = true }
            }
        }
        return out
    }
}
