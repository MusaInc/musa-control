import Foundation

/// Parses Server-Sent Events from a stream of lines.
struct SSEParser {
    private var id: String?
    private var event: String?
    private var data: [String] = []

    struct Message: Equatable { let id: String?; let event: String; let data: String }

    mutating func feed(line: String) -> Message? {
        if line.isEmpty {
            defer { event = nil; data = [] }
            guard !data.isEmpty else { return nil }
            return Message(id: id, event: event ?? "message", data: data.joined(separator: "\n"))
        }
        if line.hasPrefix(":") { return nil }
        let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let field = String(parts[0])
        var value = parts.count > 1 ? String(parts[1]) : ""
        if value.hasPrefix(" ") { value.removeFirst() }
        switch field {
        case "id": id = value
        case "event": event = value
        case "data": data.append(value)
        default: break
        }
        return nil
    }
}

/// Live gateway events with automatic reconnection. Resumes from the last
/// event id, so a dropped mobile connection doesn't lose timeline entries.
@MainActor
final class EventStream {
    enum State: Equatable { case idle, connecting, live, retrying(Int) }
    private let client: GatewayClient
    private var task: Task<Void, Never>?
    private(set) var lastId: String?
    var onEvent: ((TimelineEvent) -> Void)?
    var onState: ((State) -> Void)?

    init(client: GatewayClient, lastId: String? = nil) { self.client = client; self.lastId = lastId }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in await self?.loop() }
    }
    func stop() { task?.cancel(); task = nil; onState?(.idle) }

    private func loop() async {
        var attempt = 0
        while !Task.isCancelled {
            onState?(attempt == 0 ? .connecting : .retrying(attempt))
            do {
                var req = client.request("GET", "/api/events", query: ["since": lastId], timeout: 3600)
                req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                if let lastId { req.setValue(lastId, forHTTPHeaderField: "Last-Event-ID") }
                let (bytes, response) = try await client.session.bytes(for: req)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    throw GatewayError(status: code, message: "Event stream refused (\(code))", body: nil)
                }
                attempt = 0
                onState?(.live)
                var parser = SSEParser()
                // `lines` drops empty lines, so dispatch on each data line's
                // completion by feeding a blank after every `data:` line.
                for try await line in bytes.lines {
                    if Task.isCancelled { break }
                    _ = parser.feed(line: line)
                    if line.hasPrefix("data:"), let msg = parser.feed(line: "") { handle(msg) }
                }
            } catch {
                if Task.isCancelled { break }
                if let g = error as? GatewayError, g.isAuth { onState?(.retrying(-1)); return }
            }
            attempt += 1
            let delay = min(30.0, 0.8 * pow(2.0, Double(min(attempt, 6))))
            onState?(.retrying(attempt))
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }

    private func handle(_ msg: SSEParser.Message) {
        if let id = msg.id { lastId = id }
        guard msg.event != "hello", let data = msg.data.data(using: .utf8),
              let ev = try? JSONDecoder().decode(TimelineEvent.self, from: data) else { return }
        onEvent?(ev)
    }
}
