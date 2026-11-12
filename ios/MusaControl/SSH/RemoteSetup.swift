import Foundation
import Observation
import UIKit
import Citadel
import NIOCore
import NIOSSH
import CryptoKit

/// Captures the server's host key during key exchange and stops there, so
/// the user can compare the fingerprint before any password or key is sent.
final class CapturingHostKeyValidator: NIOSSHClientServerAuthenticationDelegate {
    struct Captured: Error { let fingerprint: String; let type: String }
    private(set) var captured: Captured?
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let line = String(openSSHPublicKey: hostKey)
        let c = Captured(fingerprint: SSHKeys.fingerprint(openSSH: line) ?? "?", type: String(line.split(separator: " ").first ?? "ssh"))
        captured = c
        validationCompletePromise.fail(c)
    }
}

/// Sets up a machine over SSH: verify the host key, install this device's
/// SSH key, upload and install the companion (loopback only), issue a device
/// token, optionally link the machine to the account, then save it.
@MainActor
@Observable
final class RemoteSetup {
    enum Phase: Equatable { case form, verifyHost, running, done, failed }
    struct Step: Identifiable, Equatable {
        enum State: Equatable { case waiting, running, ok, failed, skipped }
        let id: String; let title: String; var state: State = .waiting; var note: String?
    }

    var host = ""
    var port = "22"
    var user = ""
    var password = ""
    var name = ""
    var usePassword = true
    var linkAccount = Account.shared.signedIn
    var phase: Phase = .form
    var fingerprint: String?
    var keyType: String?
    var steps: [Step] = []
    var error: String?
    var machine: Machine?
    var detectedOS: String?

    var formValid: Bool { !host.trimmingCharacters(in: .whitespaces).isEmpty && !user.trimmingCharacters(in: .whitespaces).isEmpty && Int(port) != nil && (!usePassword || !password.isEmpty) }
    private var cleanHost: String { host.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var portNumber: Int { Int(port) ?? 22 }

    /// Step 1: read the host key only.
    func checkHostKey() async {
        error = nil
        let v = CapturingHostKeyValidator()
        do {
            let c = try await SSHClient.connect(host: cleanHost, port: portNumber, authenticationMethod: .passwordBased(username: user, password: ""),
                                                hostKeyValidator: .custom(v), reconnect: .never, connectTimeout: .seconds(12))
            try? await c.close()
        } catch {
            if v.captured == nil { self.error = Self.explain(error, host: cleanHost); return }
        }
        guard let cap = v.captured else { error = "The server didn't present a host key."; return }
        fingerprint = cap.fingerprint
        keyType = cap.type
        phase = .verifyHost
    }

    /// Step 2 (after the user confirmed the fingerprint): everything else.
    func run() async {
        guard let fp = fingerprint else { return }
        phase = .running
        error = nil
        steps = [
            Step(id: "connect", title: "Connect over SSH"),
            Step(id: "system", title: "Check the system"),
            Step(id: "key", title: "Add this \(Device.name)'s SSH key"),
            Step(id: "upload", title: "Upload the companion"),
            Step(id: "install", title: "Install and start it (loopback only)"),
            Step(id: "token", title: "Pair this \(Device.name)"),
            Step(id: "tunnel", title: "Open the encrypted tunnel"),
        ] + (linkAccount && Account.shared.signedIn ? [Step(id: "link", title: "Link to your account (notifications, relay)")] : [])
        var client: SSHClient?
        do {
            try await step("connect") {
                let auth: SSHAuthenticationMethod = self.usePassword ? .passwordBased(username: self.user, password: self.password) : .ed25519(username: self.user, privateKey: SSHKeys.privateKey())
                client = try await SSHClient.connect(host: self.cleanHost, port: self.portNumber, authenticationMethod: auth,
                                                     hostKeyValidator: .custom(PinnedHostKeyValidator(pins: [fp])), reconnect: .never, connectTimeout: .seconds(15))
                return nil
            }
            guard let c = client else { return }
            var os = ""
            try await step("system") {
                let r = try await RemoteShell.runWithStatus(c, "uname -s; uname -m; uname -r")
                if r.status == nil || r.output.lowercased().contains("not recognized") || r.output.contains("is not recognized") {
                    throw GatewayError(status: 0, message: "This looks like Windows. Install the companion inside WSL2 (Ubuntu) and use \"My computer isn't reachable\" (relay), or enable SSH into WSL.", body: nil)
                }
                let lines = r.output.split(separator: "\n").map(String.init)
                os = lines.first ?? ""
                guard os == "Linux" || os == "Darwin" else { throw GatewayError(status: 0, message: "Unsupported system: \(os). Musa Control supports Linux, macOS and Windows through WSL2.", body: nil) }
                let wsl = (lines.count > 2 && lines[2].lowercased().contains("microsoft")) ? " (WSL)" : ""
                self.detectedOS = (os == "Darwin" ? "macOS" : "Linux") + wsl
                return "\(self.detectedOS ?? os) · \(lines.count > 1 ? lines[1] : "")"
            }
            try await step("key") {
                let line = SSHKeys.openSSHPublicKey(comment: "musa-control-\(Device.name.lowercased())")
                let b64 = String(line.split(separator: " ")[1])
                let cmd = "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && (grep -qF \(RemoteShell.quote(b64)) ~/.ssh/authorized_keys || printf '%s\\n' \(RemoteShell.quote(line)) >> ~/.ssh/authorized_keys)"
                _ = try await RemoteShell.run(c, cmd)
                return "Next time no password is needed"
            }
            try await step("upload") {
                guard let url = Bundle.main.url(forResource: "companion", withExtension: "tgz"), let data = try? Data(contentsOf: url) else {
                    throw GatewayError(status: 0, message: "This build doesn't include the companion bundle.", body: nil)
                }
                let sum = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                let b64 = data.base64EncodedString()
                _ = try await RemoteShell.run(c, "mkdir -p ~/.musa-companion/incoming && chmod 700 ~/.musa-companion && rm -f ~/.musa-companion/incoming/c.b64")
                var i = b64.startIndex
                while i < b64.endIndex {
                    let j = b64.index(i, offsetBy: 60_000, limitedBy: b64.endIndex) ?? b64.endIndex
                    _ = try await RemoteShell.run(c, "printf '%s' '\(b64[i..<j])' >> ~/.musa-companion/incoming/c.b64")
                    i = j
                }
                let got = try await RemoteShell.run(c, "cd ~/.musa-companion/incoming && (base64 -d < c.b64 > c.tgz 2>/dev/null || base64 -D < c.b64 > c.tgz) && (sha256sum c.tgz 2>/dev/null || shasum -a 256 c.tgz) | cut -d' ' -f1")
                guard got.split(separator: "\n").last.map(String.init) == sum else { throw GatewayError(status: 0, message: "The upload was corrupted (checksum mismatch). Try again.", body: nil) }
                _ = try await RemoteShell.run(c, "cd ~/.musa-companion/incoming && rm -rf pkg && mkdir pkg && tar xzf c.tgz -C pkg && rm -f c.b64 c.tgz")
                return "\(data.count / 1024) KB, checksum verified"
            }
            var remotePort = 8170
            try await step("install") {
                let r = try await RemoteShell.runWithStatus(c, "sh ~/.musa-companion/incoming/pkg/musa-companion/bin/install.sh --json")
                let json = r.output.split(separator: "\n").last.map(String.init) ?? ""
                let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
                if let err = obj?["error"] as? String { throw GatewayError(status: 0, message: err, body: nil) }
                guard r.status == 0, let p = obj?["port"] as? Int else { throw GatewayError(status: 0, message: "Install failed: \(r.output.suffix(300))", body: nil) }
                remotePort = p
                return "\(obj?["manager"] as? String ?? "service") · 127.0.0.1:\(p)"
            }
            var token = ""
            var hostname = cleanHost
            try await step("token") {
                // Give a freshly started service a moment before asking it.
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                let out = try await RemoteShell.run(c, "~/.local/bin/musa-companion token --name \(RemoteShell.quote(UIDevice.current.name)) --json")
                let json = out.split(separator: "\n").last.map(String.init) ?? ""
                guard let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any], let t = obj["token"] as? String else {
                    throw GatewayError(status: 0, message: "Couldn't read the device token: \(out.suffix(200))", body: nil)
                }
                token = t
                hostname = obj["hostname"] as? String ?? hostname
                return nil
            }
            try? await c.close()
            var m = Machine(id: "ssh-\(UUID().uuidString.prefix(8).lowercased())", name: name.isEmpty ? hostname : name, kind: .ssh,
                            host: cleanHost, port: portNumber, user: user, pins: [fp], remotePort: remotePort,
                            platform: os == "Darwin" ? "darwin" : "linux", addedAt: Date().timeIntervalSince1970)
            Keychain.setString(token, for: m.tokenKey)
            try await step("tunnel") {
                let p = try await SSHTunnels.shared.port(for: m)
                let gc = GatewayClient(base: URL(string: "http://127.0.0.1:\(p)")!, token: token)
                let me = try await gc.get("/api/me", as: Me.self)
                return "Signed in as \(me.name) on \(me.server?.name ?? hostname)"
            }
            if steps.contains(where: { $0.id == "link" }) {
                try await step("link") {
                    let code = try await Account.shared.linkCode(name: m.name)
                    let out = try await SSHTunnels.shared.tunnel(for: m.id)?.run("~/.local/bin/musa-companion link \(RemoteShell.quote(code.code)) --relay \(RemoteShell.quote(CloudAuth.baseURL.absoluteString)) --name \(RemoteShell.quote(m.name)) --json && ~/.local/bin/musa-companion install-service --json") ?? ""
                    if let line = out.split(separator: "\n").first(where: { $0.contains("machineId") }),
                       let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any], let id = obj["machineId"] as? String { m.cloudId = id }
                    await Account.shared.refreshMachines()
                    return "Linked"
                }
            }
            password = ""
            MachineStore.upsert(m)
            machine = m
            phase = .done
        } catch {
            password = ""
            try? await client?.close()
            phase = .failed
        }
    }

    private func step(_ id: String, _ body: () async throws -> String?) async throws {
        guard let i = steps.firstIndex(where: { $0.id == id }) else { return }
        steps[i].state = .running
        do {
            let note = try await body()
            steps[i].state = .ok
            steps[i].note = note
        } catch {
            steps[i].state = .failed
            let msg = Self.explain(error, host: cleanHost)
            steps[i].note = msg
            self.error = msg
            throw error
        }
    }

    static func explain(_ error: Error, host: String) -> String {
        let text = "\(error)"
        if error is SSHFailure { return error.localizedDescription }
        if text.contains("allAuthenticationOptionsFailed") || text.lowercased().contains("authentication") { return "The username or password wasn't accepted (or the server doesn't allow password sign-in)." }
        if text.contains("connectTimeout") || text.lowercased().contains("timed out") { return "\(host) didn't answer. Check the address, port and that SSH (Remote Login on a Mac) is on." }
        if text.lowercased().contains("refused") { return "\(host) refused the connection on that port. Is SSH running?" }
        if text.lowercased().contains("resolve") || text.contains("NXDOMAIN") { return "Couldn't find \(host). Check the address." }
        return (error as? LocalizedError)?.errorDescription ?? text
    }
}
