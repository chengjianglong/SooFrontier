import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// The video-meeting stage, ported from SooTalky's Talk: each panelist is a portrait photo whose mouth
/// moves with their voice. The renderer (stage.html / stage.js, MediaPipe face landmarks) runs offline
/// in a web view served from the app bundle; native code pushes who is speaking and the mouth shape every frame.
@MainActor struct FaceStage {
    var room: BrainstormRoom

    func makeCoordinator() -> Coordinator { Coordinator(room: room) }

    func makeWebView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(context.coordinator.files, forURLScheme: "soofrontier")
        config.userContentController.add(context.coordinator, name: "stage")
        #if os(iOS)
        config.allowsInlineMediaPlayback = true
        #endif
        let web = WKWebView(frame: .zero, configuration: config)
        #if os(iOS)
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.isScrollEnabled = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        #else
        web.setValue(false, forKey: "drawsBackground")
        #endif
        context.coordinator.web = web
        web.navigationDelegate = context.coordinator
        web.load(URLRequest(url: URL(string: "soofrontier://app/stage.html")!))
        return web
    }
}

#if os(iOS)
extension FaceStage: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { makeWebView(context: context) }
    func updateUIView(_ web: WKWebView, context: Context) { context.coordinator.syncPanel() }
    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) { coordinator.stop() }
}
#else
extension FaceStage: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { makeWebView(context: context) }
    func updateNSView(_ web: WKWebView, context: Context) { context.coordinator.syncPanel() }
    static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) { coordinator.stop() }
}
#endif

extension FaceStage {
    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let room: BrainstormRoom
        let files = StageFiles()
        weak var web: WKWebView?
        private var link: CADisplayLink?
        private var ready = false
        private var lastPanel: String?
        private var lastTime: CFTimeInterval = 0
        private var lastFrame = ""
        private var faces: [String: Face] = [:]

        struct Face: Codable { var width: Int; var height: Int; var landmarks: [[Double]] }

        init(room: BrainstormRoom) { self.room = room }

        func stop() { link?.invalidate(); link = nil }

        nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            let type = (message.body as? [String: Any])?["type"] as? String
            Task { @MainActor in
                guard type == "ready" else { return }
                self.ready = true
                self.lastPanel = nil
                await self.loadFaces()
                self.syncPanel()
                self.startDisplayLink()
            }
        }

        /// iOS can kill the web content process under memory pressure; reload so the faces come back.
        nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            Task { @MainActor in self.ready = false; self.lastPanel = nil; webView.reload() }
        }

        /// Face landmarks for each bundled portrait: cached after the first detection, found offline otherwise.
        private func loadFaces() async {
            let cacheDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("SooFrontier/faces", isDirectory: true)
            try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            for p in Panelist.all where faces[p.id] == nil {
                let cache = cacheDir.appendingPathComponent("\(p.id).json")
                if let d = try? Data(contentsOf: cache), let f = try? JSONDecoder().decode(Face.self, from: d) {
                    faces[p.id] = f
                    continue
                }
                guard let web, let url = Bundle.main.url(forResource: p.id, withExtension: "jpg", subdirectory: "Portraits"),
                      let jpeg = try? Data(contentsOf: url) else { continue }
                let dataURL = "data:image/jpeg;base64," + jpeg.base64EncodedString()
                guard let r = try? await web.callAsyncJavaScript(
                    "const r = await SooStage.detectFace(url); return { width: r.width, height: r.height, landmarks: r.landmarks };",
                    arguments: ["url": dataURL], contentWorld: .page) as? [String: Any],
                      let w = (r["width"] as? NSNumber)?.intValue, let h = (r["height"] as? NSNumber)?.intValue,
                      let raw = r["landmarks"] as? [[NSNumber]] else { continue }
                let f = Face(width: w, height: h, landmarks: raw.map { $0.map(\.doubleValue) })
                faces[p.id] = f
                try? JSONEncoder().encode(f).write(to: cache)
            }
        }

        func syncPanel() {
            guard ready, let web else { return }
            let payload: [[String: Any]] = room.panel.map { p in
                var avatar: [String: Any] = ["kind": "illustrated", "style": [:] as [String: Any]]
                if let f = faces[p.id] {
                    avatar = ["kind": "photo", "src": "/portraits/\(p.id).jpg", "landmarks": f.landmarks,
                              "width": f.width, "height": f.height]
                }
                return ["id": p.id, "name": p.name, "avatar": avatar]
            }
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let json = String(data: data, encoding: .utf8), json != lastPanel else { return }
            lastPanel = json
            web.evaluateJavaScript("SooStage.setAgents(\(json))")
        }

        private func startDisplayLink() {
            guard link == nil else { return }
            #if os(iOS)
            let l = CADisplayLink(target: self, selector: #selector(tick(_:)))
            #else
            guard let l = web?.displayLink(target: self, selector: #selector(tick(_:))) else { return }
            #endif
            l.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            l.add(to: .main, forMode: .common)
            link = l
        }

        @objc private func tick(_ l: CADisplayLink) {
            let dt = lastTime == 0 ? 1.0 / 60 : min(0.05, l.timestamp - lastTime)
            lastTime = l.timestamp
            let m = room.voice.mouth(dt: dt)
            let phase: String = switch room.phase {
            case .listening: "listening"
            case .speaking: "speaking"
            default: "idle"
            }
            let speaking = room.voice.speakingPanelist.map { "'\($0)'" } ?? "null"
            var thinking = "null"
            if case .thinking(let name) = room.phase, let p = Panelist.all.first(where: { $0.name == name }) { thinking = "'\(p.id)'" }
            let js = String(format:
                "SooStage.frame({speaking:%@,thinking:%@,phase:'%@',mouth:{open:%.2f,wide:%.2f,round:%.2f,energy:%.2f}})",
                speaking, thinking, phase, m.open, m.wide, m.round, m.energy)
            // The stage keeps animating on its own; only send a frame when something changed.
            guard js != lastFrame else { return }
            lastFrame = js
            web?.evaluateJavaScript(js)
        }
    }
}

/// Serves `soofrontier://app/<path>`: portraits from the bundle's Portraits folder, everything else from Stage.
final class StageFiles: NSObject, WKURLSchemeHandler {
    private let stageRoot = Bundle.main.resourceURL!.appendingPathComponent("Stage", isDirectory: true)
    private let portraitRoot = Bundle.main.resourceURL!.appendingPathComponent("Portraits", isDirectory: true)

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let parts = url.path.split(separator: "/").map(String.init)
        let isPortrait = parts.first == "portraits"
        let relative = isPortrait ? Array(parts.dropFirst()) : parts
        let file = relative.reduce(isPortrait ? portraitRoot : stageRoot) { $0.appendingPathComponent($1) }
        guard !relative.isEmpty, !relative.contains(".."), let data = try? Data(contentsOf: file) else {
            task.didReceive(HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!)
            task.didFinish()
            return
        }
        let mime: String = switch file.pathExtension {
        case "html": "text/html"
        case "js", "mjs": "text/javascript"
        case "wasm": "application/wasm"
        case "json": "application/json"
        case "jpg", "jpeg": "image/jpeg"
        case "png": "image/png"
        default: UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        }
        let headers = ["Content-Type": mime, "Content-Length": "\(data.count)", "Access-Control-Allow-Origin": "*", "Cache-Control": "no-cache"]
        task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}
