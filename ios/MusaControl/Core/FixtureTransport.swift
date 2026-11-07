import Foundation

/// UI-test transport: answers API calls from JSON captured from the real
/// gateway (Resources/Fixtures), so layout screenshots can be produced on a
/// CI simulator with no route to the VPS. Only used when the app is launched
/// with -UITestFixtures; a normal launch never touches it.
struct FixtureTransport: GatewayTransport {
    static let routes: [(method: String, pattern: String, file: String)] = [
        ("GET", "^/api/me$", "me.json"),
        ("GET", "^/api/overview$", "overview.json"),
        ("GET", "^/api/projects$", "projects.json"),
        ("GET", "^/api/agents$", "agents.json"),
        ("GET", "^/api/agents/[^/]+/timeline$", "agent-timeline.json"),
        ("GET", "^/api/agents/[^/]+/screen$", "agent-screen.json"),
        ("GET", "^/api/projects/[^/]+$", "project-detail.json"),
        ("GET", "^/api/projects/[^/]+/files$", "files.json"),
        ("GET", "^/api/projects/[^/]+/file$", "file.json"),
        ("GET", "^/api/projects/[^/]+/git/status$", "git-status.json"),
        ("GET", "^/api/projects/[^/]+/git/diff$", "git-diff.json"),
        ("GET", "^/api/projects/[^/]+/git/log$", "git-log.json"),
        ("GET", "^/api/projects/[^/]+/git/branches$", "git-branches.json"),
        ("GET", "^/api/projects/[^/]+/revisions$", "revisions.json"),
        ("GET", "^/api/revisions/\\d+/diff$", "revision-diff.json"),
        ("GET", "^/api/projects/[^/]+/previews$", "previews.json"),
        ("GET", "^/api/projects/[^/]+/builds$", "builds.json"),
        ("GET", "^/api/builds/[^/]+$", "build-log.json"),
        ("GET", "^/api/screenshots$", "screenshots.json"),
        ("GET", "^/api/timeline$", "timeline.json"),
        ("GET", "^/api/vnc/displays$", "displays.json"),
        ("GET", "^/api/tmux$", "tmux.json"),
        ("GET", "^/api/devices$", "devices.json"),
        ("GET", "^/api/push$", "push.json"),
        ("GET", "^/api/trash$", "empty-array.json"),
        ("GET", "^/api/github/[^/]+/[^/]+/runs$", "runs.json"),
        ("GET", "^/api/github/[^/]+/[^/]+/pulls$", "empty-array.json"),
    ]

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        var path = url.path
        if let r = path.range(of: "/api/") { path = String(path[r.lowerBound...]) }
        let method = request.httpMethod ?? "GET"
        func reply(_ data: Data, _ status: Int = 200, type: String = "application/json") -> (Data, HTTPURLResponse) {
            (data, HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": type])!)
        }
        if method == "GET", path.range(of: "^/api/projects/[^/]+/(thumb|raw)$", options: .regularExpression) != nil,
           let u = Bundle.main.url(forResource: "shot-1", withExtension: "jpg", subdirectory: "Fixtures"), let d = try? Data(contentsOf: u) { return reply(d, type: "image/jpeg") }
        if method == "GET", path.range(of: "^/api/screenshots/\\d+/image$", options: .regularExpression) != nil {
            let id = path.split(separator: "/")[2]
            let n = (Int(id) ?? 0) % 4
            if let u = Bundle.main.url(forResource: "shot-\(n)", withExtension: "jpg", subdirectory: "Fixtures"), let d = try? Data(contentsOf: u) { return reply(d, type: "image/jpeg") }
        }
        for r in Self.routes where r.method == method && path.range(of: r.pattern, options: .regularExpression) != nil {
            let name = (r.file as NSString).deletingPathExtension
            if let u = Bundle.main.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"), let d = try? Data(contentsOf: u) { return reply(d) }
        }
        if method != "GET" { return reply(Data("{\"ok\":true}".utf8)) }
        return reply(Data("{\"error\":\"No fixture for \(path)\"}".utf8), 404)
    }
}
