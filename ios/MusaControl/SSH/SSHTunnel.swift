import Foundation
import Citadel
import NIOCore
import NIOPosix
import NIOSSH
import CryptoKit

/// Local port forwarding for SSH machines: 127.0.0.1:<local> on the iPad →
/// SSH direct-tcpip → 127.0.0.1:<companion port> on the machine. The
/// companion never listens on a public interface; everything between the
/// iPad and the machine is inside the SSH connection, whose host key is
/// pinned. One listener per machine for the life of the app; the SSH
/// connection behind it reconnects on demand.
final class SSHTunnel: @unchecked Sendable {
    let machineId: String
    private let settings: SSHSettings
    private let remotePort: Int
    // One event loop for the listener and the SSH connection, so the two
    // channels glued together always run on the same thread.
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private var server: Channel?
    private var client: SSHClient?
    private let lock = NSLock()
    private var connecting: Task<SSHClient, Error>?

    init(machineId: String, settings: SSHSettings, remotePort: Int) {
        self.machineId = machineId
        self.settings = settings
        self.remotePort = remotePort
    }

    var localPort: Int? { server?.localAddress?.port }

    /// Starts the listener (once) and makes sure SSH works; returns the local port.
    func start() async throws -> Int {
        _ = try await sshClient()
        if let p = localPort { return p }
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.autoRead, value: false)
            .childChannelInitializer { [weak self] child in
                guard let self else { return child.eventLoop.makeFailedFuture(SSHFailure.closed) }
                let promise = child.eventLoop.makePromise(of: Void.self)
                promise.completeWithTask { try await self.bridge(child) }
                return promise.futureResult
            }
        let ch = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        server = ch
        return ch.localAddress?.port ?? 0
    }

    private func sshClient() async throws -> SSHClient {
        enum Next { case ready(SSHClient), wait(Task<SSHClient, Error>) }
        let s = settings, g = group
        let next: Next = lock.withLock {
            if let c = client, c.isConnected { return .ready(c) }
            if let t = connecting { return .wait(t) }
            let t = Task { () throws -> SSHClient in
                try await SSHClient.connect(host: s.host, port: s.port,
                                            authenticationMethod: .ed25519(username: s.user, privateKey: SSHKeys.privateKey()),
                                            hostKeyValidator: .custom(PinnedHostKeyValidator(pins: s.pinnedFingerprints)),
                                            reconnect: .never, group: g, connectTimeout: .seconds(15))
            }
            connecting = t
            return .wait(t)
        }
        switch next {
        case .ready(let c): return c
        case .wait(let t):
            do {
                let c = try await t.value
                lock.withLock { client = c; connecting = nil }
                return c
            } catch {
                lock.withLock { connecting = nil }
                throw error
            }
        }
    }

    private func bridge(_ local: Channel) async throws {
        let ssh = try await sshClient()
        let origin = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
        let (a, b) = GlueHandler.matchedPair()
        _ = try await ssh.createDirectTCPIPChannel(using: .init(targetHost: "127.0.0.1", targetPort: remotePort, originatorAddress: origin)) { remote in
            remote.pipeline.addHandler(a).flatMap { local.pipeline.addHandler(b) }.map { local.read() }
        }
    }

    /// Runs one command on the machine over the same SSH identity.
    func run(_ command: String) async throws -> String {
        let c = try await sshClient()
        return try await RemoteShell.run(c, command)
    }

    func stop() {
        let s = server, c = client
        server = nil; client = nil
        s?.close(promise: nil)
        Task { try? await c?.close() }
    }

    deinit { group.shutdownGracefully { _ in } }
}

/// Every SSH machine's tunnel, keyed by machine id.
@MainActor
final class SSHTunnels {
    static let shared = SSHTunnels()
    private var tunnels: [String: SSHTunnel] = [:]

    func port(for m: Machine) async throws -> Int {
        guard let s = m.sshSettings else { throw SSHFailure.notConfigured }
        let t = tunnels[m.id] ?? SSHTunnel(machineId: m.id, settings: s, remotePort: m.remotePort ?? 8170)
        tunnels[m.id] = t
        return try await t.start()
    }

    func tunnel(for id: String) -> SSHTunnel? { tunnels[id] }
    func drop(_ id: String) { tunnels[id]?.stop(); tunnels[id] = nil }
    func stopAll() { tunnels.values.forEach { $0.stop() }; tunnels.removeAll() }
}

/// Passes bytes between two channels (from the swift-nio examples), with
/// back-pressure: a side only reads while its partner can write.
final class GlueHandler {
    private var partner: GlueHandler?
    private var context: ChannelHandlerContext?
    private var pendingRead = false

    static func matchedPair() -> (GlueHandler, GlueHandler) {
        let a = GlueHandler(), b = GlueHandler()
        a.partner = b; b.partner = a
        return (a, b)
    }
    private func partnerWrite(_ data: NIOAny) { context?.write(data, promise: nil) }
    private func partnerFlush() { context?.flush() }
    private func partnerWriteEOF() { context?.close(mode: .output, promise: nil) }
    private func partnerCloseFull() { context?.close(promise: nil) }
    private func partnerBecameWritable() { if pendingRead { pendingRead = false; context?.read() } }
    private var partnerWritable: Bool { context?.channel.isWritable ?? false }
}

extension GlueHandler: ChannelDuplexHandler {
    typealias InboundIn = NIOAny
    typealias OutboundIn = NIOAny
    typealias OutboundOut = NIOAny

    func handlerAdded(context: ChannelHandlerContext) { self.context = context }
    func handlerRemoved(context: ChannelHandlerContext) { self.context = nil; self.partner = nil }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) { partner?.partnerWrite(data) }
    func channelReadComplete(context: ChannelHandlerContext) { partner?.partnerFlush() }
    func channelInactive(context: ChannelHandlerContext) { partner?.partnerCloseFull() }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let e = event as? ChannelEvent, case .inputClosed = e { partner?.partnerWriteEOF() }
        context.fireUserInboundEventTriggered(event)
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
    func channelWritabilityChanged(context: ChannelHandlerContext) { if context.channel.isWritable { partner?.partnerBecameWritable() } }
    func read(context: ChannelHandlerContext) {
        if let partner, partner.partnerWritable { context.read() } else { pendingRead = true }
    }
}

/// Commands over SSH exec. Output and the exit status come back together
/// (Citadel throws on a non-zero exit and drops the output, so the status is
/// echoed instead and parsed here).
enum RemoteShell {
    struct Result { let output: String; let status: Int? }

    static func run(_ c: SSHClient, _ command: String, limit: Int = 4 * 1024 * 1024) async throws -> String {
        let r = try await runWithStatus(c, command, limit: limit)
        if let s = r.status, s != 0 { throw GatewayError(status: 0, message: "Command failed (\(s)): \(r.output.suffix(400))", body: nil) }
        return r.output
    }

    static func runWithStatus(_ c: SSHClient, _ command: String, limit: Int = 4 * 1024 * 1024) async throws -> Result {
        // Through sh, whatever the login shell (fish, zsh…); on Windows' cmd
        // there's no sh, the exec fails, and the status stays nil.
        let wrapped = "sh -c " + quote("{ \(command) ; } 2>&1; echo \"__mc_exit:$?\"")
        let buf: ByteBuffer
        do { buf = try await c.executeCommand(wrapped, maxResponseSize: limit, mergeStreams: true) }
        catch is SSHClient.CommandFailed { return Result(output: "", status: nil) }
        var text = String(buffer: buf)
        var status: Int?
        if let r = text.range(of: "__mc_exit:", options: .backwards) {
            status = Int(text[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines))
            text = String(text[..<r.lowerBound])
        }
        return Result(output: text.trimmingCharacters(in: .whitespacesAndNewlines), status: status)
    }

    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
