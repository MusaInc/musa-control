import Foundation

struct GatewayError: LocalizedError {
    let status: Int
    let message: String
    let body: Data?
    var errorDescription: String? { message }
    var isAuth: Bool { status == 401 }
    var isConflict: Bool { status == 409 }
    func decode<T: Decodable>(_ t: T.Type) -> T? { body.flatMap { try? JSONDecoder().decode(T.self, from: $0) } }
}

/// Where requests go. The live transport talks HTTPS to the gateway; UI tests
/// swap in a fixture transport (see FixtureTransport) so screenshots can be
/// captured on a simulator that has no route to the VPS.
protocol GatewayTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionTransport: GatewayTransport {
    let session: URLSession
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (d, r) = try await session.data(for: request)
        guard let http = r as? HTTPURLResponse else { throw GatewayError(status: 0, message: "No HTTP response", body: nil) }
        return (d, http)
    }
}

final class GatewayClient: @unchecked Sendable {
    let base: URL                  // e.g. https://musastudios.co.uk/control
    private(set) var token: String?
    let transport: GatewayTransport
    let session: URLSession

    init(base: URL, token: String?, transport: GatewayTransport? = nil) {
        self.base = base
        self.token = token
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.waitsForConnectivity = false
        cfg.httpAdditionalHeaders = ["User-Agent": "MusaControl-\(Device.name)/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0")"]
        self.session = URLSession(configuration: cfg)
        self.transport = transport ?? URLSessionTransport(session: session)
    }

    func setToken(_ t: String?) { token = t }

    func url(_ path: String, _ query: [String: String?] = [:]) -> URL {
        // Paths arrive already percent-encoded (see `pathSegment`); don't re-encode them.
        var root = base.absoluteString
        while root.hasSuffix("/") { root.removeLast() }
        var c = URLComponents(string: root + (path.hasPrefix("/") ? path : "/" + path)) ?? URLComponents(url: base, resolvingAgainstBaseURL: false)!
        let items = query.compactMap { k, v in v.map { URLQueryItem(name: k, value: $0) } }
        if !items.isEmpty { c.queryItems = items.sorted { $0.name < $1.name } }
        return c.url!
    }

    func request(_ method: String, _ path: String, query: [String: String?] = [:], body: Data? = nil, contentType: String = "application/json", timeout: TimeInterval = 30) -> URLRequest {
        var r = URLRequest(url: url(path, query))
        r.httpMethod = method
        r.timeoutInterval = timeout
        if let token { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body { r.httpBody = body; r.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        return r
    }

    @discardableResult
    func raw(_ req: URLRequest) async throws -> Data {
        let (data, http) = try await transport.send(req)
        guard (200..<300).contains(http.statusCode) else {
            let msg = (try? JSONDecoder().decode([String: JSONValue].self, from: data))?["error"]?.string ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw GatewayError(status: http.statusCode, message: msg, body: data)
        }
        return data
    }

    func get<T: Decodable>(_ path: String, _ query: [String: String?] = [:], as: T.Type = T.self, timeout: TimeInterval = 30) async throws -> T {
        let d = try await raw(request("GET", path, query: query, timeout: timeout))
        return try JSONDecoder().decode(T.self, from: d)
    }

    func send<T: Decodable>(_ method: String, _ path: String, _ body: [String: Any] = [:], query: [String: String?] = [:], as: T.Type = T.self, timeout: TimeInterval = 60) async throws -> T {
        let data = try JSONSerialization.data(withJSONObject: body)
        let d = try await raw(request(method, path, query: query, body: data, timeout: timeout))
        return try JSONDecoder().decode(T.self, from: d)
    }

    func upload<T: Decodable>(_ path: String, query: [String: String?], data: Data, as: T.Type = T.self) async throws -> T {
        let d = try await raw(request("POST", path, query: query, body: data, contentType: "application/octet-stream", timeout: 300))
        return try JSONDecoder().decode(T.self, from: d)
    }

    func data(_ path: String, _ query: [String: String?] = [:]) async throws -> Data {
        try await raw(request("GET", path, query: query, timeout: 120))
    }

    var host: String { base.host ?? "musastudios.co.uk" }
}

/// Percent-encodes an agent id ("claude:<uuid>") for use as a path segment.
extension String {
    var pathSegment: String { addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? self }
}
