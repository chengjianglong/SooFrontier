import Foundation

enum Net {
    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 20
        c.httpAdditionalHeaders = ["User-Agent": "SooFrontier/1.0 (AI research reader)"]
        return URLSession(configuration: c)
    }()

    static func data(_ url: URL) async throws -> Data {
        let (data, resp) = try await session.data(from: url)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode) from \(url.host() ?? "")"])
        }
        return data
    }

    static func json<T: Decodable>(_ type: T.Type, from url: URL) async throws -> T {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            return Text2.date(s) ?? .distantPast
        }
        return try d.decode(T.self, from: try await data(url))
    }

    /// Fetches several feeds concurrently; individual failures are skipped.
    static func feeds(_ urls: [(String, String)]) async -> [(source: String, entry: FeedParser.Entry)] {
        await withTaskGroup(of: [(String, FeedParser.Entry)].self) { group in
            for (name, u) in urls {
                guard let url = URL(string: u) else { continue }
                group.addTask {
                    guard let d = try? await data(url) else { return [] }
                    return FeedParser.parse(d).prefix(12).map { (name, $0) }
                }
            }
            var all: [(source: String, entry: FeedParser.Entry)] = []
            for await batch in group { all += batch.map { (source: $0.0, entry: $0.1) } }
            return all
        }
    }
}
