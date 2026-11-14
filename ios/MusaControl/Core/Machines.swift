import Foundation

/// A computer Musa Control can drive. Three ways to reach one:
/// * `direct` – an HTTPS gateway URL + device token (the original Musa
///   Studios server, paired with the workspace password).
/// * `ssh` – any Mac/Linux machine (or Windows via WSL) the iPad can SSH
///   into: the companion listens on the machine's loopback only and the app
///   reaches it through an SSH tunnel it opens itself (end-to-end encrypted,
///   nothing exposed to the internet). The host key is pinned.
/// * `relay` – a machine linked to the user's Musa Control account that
///   dials out to the relay (home computers behind NAT). Requests carry the
///   account session; the relay checks the machine belongs to it.
struct Machine: Codable, Identifiable, Hashable {
    enum Kind: String, Codable { case direct, ssh, relay }

    var id: String
    var name: String
    var kind: Kind
    // direct
    var url: String?
    // ssh
    var host: String?
    var port: Int?
    var user: String?
    var pins: [String]?
    var remotePort: Int?
    // relay (also set on an ssh machine that was linked to the account, for pushes)
    var cloudId: String?
    var platform: String?
    var addedAt: Double

    static let personalId = "personal"

    var isPersonal: Bool { id == Self.personalId }

    /// Keychain item holding this machine's device token (relay machines use
    /// the account session instead). The personal server keeps its original key.
    var tokenKey: String { isPersonal ? "deviceToken" : "machine.\(id).token" }
    var token: String? { kind == .relay ? CloudAuth.token : Keychain.string(tokenKey) }

    var sshSettings: SSHSettings? {
        guard kind == .ssh, let host, let user, let pins, !pins.isEmpty else { return nil }
        return SSHSettings(host: host, port: port ?? 22, user: user, pinnedFingerprints: pins, keyInstalled: true)
    }

    var subtitle: String {
        switch kind {
        case .direct: return URL(string: url ?? "")?.host ?? "Gateway"
        case .ssh: return "\(user ?? "")@\(host ?? "")"
        case .relay: return "Through your Musa Control account"
        }
    }

    var symbol: String {
        switch platform?.lowercased() ?? "" {
        case "darwin", "macos": return "laptopcomputer"
        case let p where p.contains("win") || p.contains("wsl"): return "pc"
        default: return kind == .direct && isPersonal ? "server.rack" : "desktopcomputer"
        }
    }

    var kindLabel: String { kind == .direct ? "HTTPS" : kind == .ssh ? "SSH tunnel" : "Relay" }
}

/// Saved machines (non-secret fields in UserDefaults, tokens in the Keychain).
enum MachineStore {
    private static let key = "machines.v1"
    private static let activeKey = "machines.active"

    static var all: [Machine] {
        guard let d = UserDefaults.standard.data(forKey: key), let list = try? JSONDecoder().decode([Machine].self, from: d) else { return [] }
        return list
    }

    static func saveAll(_ list: [Machine]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(list), forKey: key)
    }

    static func upsert(_ m: Machine) {
        var list = all
        if let i = list.firstIndex(where: { $0.id == m.id }) { list[i] = m } else { list.append(m) }
        saveAll(list)
    }

    static func remove(_ id: String) {
        if let m = all.first(where: { $0.id == id }) { Keychain.delete(m.tokenKey) }
        saveAll(all.filter { $0.id != id })
        if activeId == id { activeId = all.first?.id }
    }

    static var activeId: String? {
        get { UserDefaults.standard.string(forKey: activeKey) }
        set { UserDefaults.standard.set(newValue, forKey: activeKey) }
    }

    static var active: Machine? {
        let list = all
        return list.first { $0.id == activeId } ?? list.first
    }

    /// Builds before multi-machine support kept one gateway (serverURL +
    /// Keychain "deviceToken" + "sshSettings"). That becomes the "personal"
    /// machine, keeping the same Keychain item, so nothing has to be re-paired.
    static func migrateIfNeeded(readLegacyToken: () -> String? = { Keychain.string("deviceToken") }) {
        guard !UserDefaults.standard.bool(forKey: "machines.migrated") else { return }
        // A locked or temporarily unavailable Keychain must not permanently
        // mark migration complete and strand an existing paired computer.
        guard readLegacyToken() != nil else { return }
        let url = UserDefaults.standard.string(forKey: "serverURL") ?? "https://musastudios.co.uk/control"
        let m = Machine(id: Machine.personalId, name: "Musa Studios VPS", kind: .direct, url: url, platform: "linux", addedAt: Date().timeIntervalSince1970)
        upsert(m)
        activeId = m.id
        UserDefaults.standard.set(true, forKey: "machines.migrated")
    }

    /// Per-machine UserDefaults key (the personal server keeps the old names).
    static func scoped(_ base: String, _ machineId: String?) -> String {
        guard let machineId, machineId != Machine.personalId else { return base }
        return "\(base).\(machineId)"
    }
}
