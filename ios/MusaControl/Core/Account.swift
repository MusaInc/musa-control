import Foundation
import Observation
import CryptoKit
import AuthenticationServices
import UIKit

/// Where the account service lives and the signed-in session token. Kept
/// outside the main actor so machines, notification actions and background
/// work can read them.
enum CloudAuth {
    static let defaultURL = "https://musastudios.co.uk/control-cloud"
    static var token: String? { Keychain.string("account.token") }
    static var baseURL: URL {
        URL(string: UserDefaults.standard.string(forKey: "account.cloudURL") ?? defaultURL) ?? URL(string: defaultURL)!
    }
    static func client() -> GatewayClient { GatewayClient(base: baseURL, token: token) }
    /// Base URL for a linked machine reached through the relay.
    static func machineBase(_ cloudId: String) -> URL { baseURL.appendingPathComponent("m").appendingPathComponent(cloudId) }
}

struct CloudUser: Codable, Equatable { let id: String; let email: String?; let emailVerified: Bool; let name: String?; let createdAt: Double; let methods: [String] }
struct CloudAuthResponse: Codable { let token: String; let user: CloudUser }
struct CloudMachine: Codable, Identifiable, Hashable {
    struct Info: Codable, Hashable { let name: String?; let platform: String?; let os: String?; let version: String?; let agents: [String]? }
    let id: String; let name: String; let platform: String?; let hostname: String?; let osUser: String?
    let createdAt: Double; let lastSeen: Double?; let online: Bool; let info: Info?
}
struct CloudSession: Codable, Identifiable, Hashable { let id: String; let deviceName: String?; let platform: String?; let createdAt: Double; let lastSeen: Double?; let expiresAt: Double; let current: Bool }
struct LinkCode: Codable, Equatable { let code: String; let expiresAt: Double; let command: String }
struct AuditEntry: Codable, Identifiable, Hashable { let id: Int; let ts: Double; let action: String; let ip: String?; let session: String?; let machine: String?; let detail: [String: JSONValue]? }
struct CloudPing: Codable { let ok: Bool; let registration: String? }

/// The signed-in Musa Control account (optional: machines reached over SSH
/// or a direct gateway work without one; the relay and push for public
/// users need it).
@MainActor
@Observable
final class Account {
    static let shared = Account()

    var user: CloudUser?
    var machines: [CloudMachine] = []
    var lastError: String?
    var signedIn: Bool { CloudAuth.token != nil && user != nil }
    var hasToken: Bool { CloudAuth.token != nil }

    /// Sign in with Apple: the raw nonce stays here; Apple gets its SHA-256
    /// and puts it in the identity token, which the service checks.
    private(set) var appleNonce = ""
    func prepareApple(_ request: ASAuthorizationAppleIDRequest) {
        appleNonce = Self.randomNonce()
        request.requestedScopes = [.fullName, .email]
        request.nonce = Self.sha256(appleNonce)
    }

    func completeApple(_ result: Result<ASAuthorization, Error>) async throws {
        switch result {
        case .failure(let e):
            if (e as? ASAuthorizationError)?.code == .canceled { return }
            throw e
        case .success(let auth):
            guard let cred = auth.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = cred.identityToken, let idToken = String(data: tokenData, encoding: .utf8) else {
                throw GatewayError(status: 0, message: "Apple didn't return an identity token.", body: nil)
            }
            let name = [cred.fullName?.givenName, cred.fullName?.familyName].compactMap { $0 }.joined(separator: " ")
            var body: [String: Any] = ["identityToken": idToken, "nonce": appleNonce, "deviceName": UIDevice.current.name, "platform": Device.osName]
            if !name.isEmpty { body["name"] = name }
            if let code = cred.authorizationCode.flatMap({ String(data: $0, encoding: .utf8) }) { body["authorizationCode"] = code }
            try await finishSignIn(path: "/v1/auth/apple", body: body)
        }
    }

    func signIn(email: String, password: String) async throws {
        try await finishSignIn(path: "/v1/auth/login", body: ["email": email, "password": password, "deviceName": UIDevice.current.name, "platform": Device.osName])
    }

    func register(email: String, password: String, name: String) async throws {
        try await finishSignIn(path: "/v1/auth/register", body: ["email": email, "password": password, "name": name, "deviceName": UIDevice.current.name, "platform": Device.osName])
    }

    private func finishSignIn(path: String, body: [String: Any]) async throws {
        let c = GatewayClient(base: CloudAuth.baseURL, token: nil)
        let r = try await c.send("POST", path, body, as: CloudAuthResponse.self)
        Keychain.setString(r.token, for: "account.token")
        user = r.user
        await refreshMachines()
        Task { await Notifier.shared.syncRegistration() }
    }

    func refresh() async {
        guard hasToken else { user = nil; return }
        do {
            user = try await CloudAuth.client().get("/v1/me", as: CloudUser.self)
            await refreshMachines()
        } catch let e as GatewayError where e.isAuth {
            signOutLocally()
        } catch { lastError = error.localizedDescription }
    }

    func refreshMachines() async {
        guard hasToken else { machines = []; return }
        if let list = try? await CloudAuth.client().get("/v1/machines", as: [CloudMachine].self) {
            machines = list
            syncRelayMachines()
        }
    }

    /// Mirrors the account's machines into the local machine list.
    func syncRelayMachines() {
        let cloudIds = Set(machines.map(\.id))
        for m in MachineStore.all where m.kind == .relay && !cloudIds.contains(m.cloudId ?? "") { MachineStore.remove(m.id) }
        for c in machines {
            if let existing = MachineStore.all.first(where: { $0.cloudId == c.id }) {
                var m = existing
                if m.kind == .relay { m.name = c.name }
                m.platform = c.platform ?? m.platform
                MachineStore.upsert(m)
            } else {
                MachineStore.upsert(Machine(id: "relay-\(c.id)", name: c.name, kind: .relay, cloudId: c.id, platform: c.platform, addedAt: Date().timeIntervalSince1970))
            }
        }
    }

    func signOut() async {
        _ = try? await CloudAuth.client().send("POST", "/v1/auth/logout", [:], as: OK.self)
        signOutLocally()
    }

    func signOutLocally() {
        Keychain.delete("account.token")
        user = nil
        machines = []
        for m in MachineStore.all where m.kind == .relay { MachineStore.remove(m.id) }
    }

    func linkCode(name: String?) async throws -> LinkCode {
        try await CloudAuth.client().send("POST", "/v1/machines/link-code", name.map { ["name": $0] } ?? [:], as: LinkCode.self)
    }
    func renameMachine(_ id: String, _ name: String) async throws {
        _ = try await CloudAuth.client().send("PATCH", "/v1/machines/\(id)", ["name": name], as: CloudMachine.self)
        await refreshMachines()
    }
    func removeMachine(_ id: String) async throws {
        _ = try await CloudAuth.client().send("DELETE", "/v1/machines/\(id)", [:], as: OK.self)
        await refreshMachines()
    }
    func sessions() async throws -> [CloudSession] { try await CloudAuth.client().get("/v1/sessions", as: [CloudSession].self) }
    func revoke(_ id: String) async throws { _ = try await CloudAuth.client().send("DELETE", "/v1/sessions/\(id)", [:], as: OK.self) }
    func revokeOthers() async throws { _ = try await CloudAuth.client().send("POST", "/v1/sessions/revoke-others", [:], as: OK.self) }
    func audit() async throws -> [AuditEntry] { try await CloudAuth.client().get("/v1/audit", ["limit": "150"], as: [AuditEntry].self) }
    func exportData() async throws -> Data { try await CloudAuth.client().data("/v1/account/export") }
    func rename(_ name: String) async throws { user = try await CloudAuth.client().send("PATCH", "/v1/me", ["name": name], as: CloudUser.self) }

    /// Deletes the account, its linked machines and sessions on the service.
    /// Nothing on the machines themselves is deleted.
    func deleteAccount(password: String?) async throws {
        var body: [String: Any] = ["confirm": "DELETE"]
        if let password, !password.isEmpty { body["password"] = password }
        _ = try await CloudAuth.client().send("DELETE", "/v1/account", body, as: OK.self)
        signOutLocally()
    }

    nonisolated static func randomNonce(length: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "[^A-Za-z0-9]", with: "", options: .regularExpression)
    }
    nonisolated static func sha256(_ s: String) -> String { SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined() }
}
