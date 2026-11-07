import Foundation

/// Arbitrary JSON (event details vary by kind).
enum JSONValue: Codable, Hashable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else { self = .null }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .object(let o): try c.encode(o)
        case .array(let a): try c.encode(a)
        case .null: try c.encodeNil()
        }
    }
    subscript(_ key: String) -> JSONValue? { if case .object(let o) = self { return o[key] } else { return nil } }
    var string: String? {
        switch self { case .string(let s): return s; case .number(let n): return n == n.rounded() ? String(Int(n)) : String(n); case .bool(let b): return b ? "true" : "false"; default: return nil }
    }
    var number: Double? { if case .number(let n) = self { return n }; if case .string(let s) = self { return Double(s) }; return nil }
    var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    var array: [JSONValue] { if case .array(let a) = self { return a }; return [] }
    var isNull: Bool { if case .null = self { return true }; return false }
}

struct Project: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let path: String
    let kind: String
    let git: Bool
    let github: String?
    var previews: [PublicPreview]?
    var activeAgents: Int?

    var icon: String {
        switch kind {
        case "godot": return "gamecontroller"
        case "ios": return "iphone"
        case "expo": return "apps.iphone"
        case "android": return "tv"
        case "web": return "globe"
        case "python": return "chevron.left.forwardslash.chevron.right"
        default: return "folder"
        }
    }
}

struct PublicPreview: Codable, Hashable { let label: String; let url: String }

struct ProjectCommand: Codable, Hashable, Identifiable { let id: String; let label: String; let command: String }

struct LocalServer: Codable, Hashable { let port: Int; let process: String?; let pid: Int?; let cwd: String?; var label: String? }

struct ProjectDetail: Codable {
    let id: String
    let name: String
    let path: String
    let kind: String
    let github: String?
    let previews: [PublicPreview]?
    let commands: [ProjectCommand]
    let localServers: [LocalServer]?
    let git: GitStatus?
    let builds: [Build]?
}

struct GitFile: Codable, Hashable, Identifiable {
    var id: String { path }
    let path: String
    let from: String?
    let staged: Bool
    let unstaged: Bool
    let untracked: Bool?
    let conflict: Bool?
    let x: String
    let y: String
    var code: String { untracked == true ? "?" : (staged ? x : y) }
}

struct GitStatus: Codable {
    let git: Bool?
    let branch: String?
    let upstream: String?
    let ahead: Int?
    let behind: Int?
    let files: [GitFile]?
    let error: String?
}

struct Commit: Codable, Hashable, Identifiable { var id: String { sha }; let sha: String; let short: String; let author: String; let date: String; let subject: String; let refs: String? }
struct Branch: Codable, Hashable, Identifiable { var id: String { name }; let name: String; let sha: String; let date: String?; let upstream: String?; let current: Bool }
struct DiffResponse: Codable { let diff: String?; let truncated: Bool? }

struct FileEntry: Codable, Hashable, Identifiable {
    var id: String { path }
    let name: String
    let path: String
    let dir: Bool
    let size: Double
    let mtime: Double
    let ignored: Bool?
    let hidden: Bool?
}
struct DirListing: Codable { let project: String; let path: String; let entries: [FileEntry] }
struct FileContent: Codable { let path: String; let size: Double; let mtime: Double; let mime: String; let text: String?; let binary: Bool; let sha: String?; let tooLarge: Bool? }
struct SaveResult: Codable { let path: String?; let sha: String?; let error: String?; let currentSha: String?; let currentText: String? }
struct SearchResult: Codable, Hashable { let path: String; let line: Int?; let text: String? }
struct SearchResponse: Codable { let mode: String; let results: [SearchResult] }

struct Revision: Codable, Hashable, Identifiable {
    let id: Int
    let path: String?
    let ts: Double
    let sha: String
    let size: Double
    let source: String
    let session: String?
    let added: Int?
    let removed: Int?
}
struct RevisionDiff: Codable { let id: Int; let path: String; let previousId: Int?; let diff: String? }

struct ApprovalOption: Codable, Hashable, Identifiable { var id: Int { index }; let index: Int; let number: Int?; let label: String; let tone: String }
struct ApprovalPrompt: Codable, Hashable {
    let kind: String
    let question: String
    let context: String
    let command: String?
    let options: [ApprovalOption]
    let selected: Int
    let signature: String
}

struct AgentCounts: Codable, Hashable { let edits: Int; let commands: Int; let images: Int; let errors: Int }
struct LastEvent: Codable, Hashable { let kind: String; let title: String; let ts: Double?; let follow: JSONValue? }
struct TmuxRef: Codable, Hashable { let session: String; let target: String? }
struct ManagedRef: Codable, Hashable { let id: String; let tmux: String }

struct Agent: Codable, Identifiable, Hashable {
    let id: String
    let agent: String
    let agentName: String
    let sessionId: String?
    let project: String?
    let projectInferred: Bool?
    let cwd: String?
    let title: String
    let lastPrompt: String?
    let lastMessage: String?
    let status: String
    let statusText: String
    let lastActivity: Double
    let startedAt: Double?
    let model: String?
    let pid: Int?
    let mode: String?
    let tmux: TmuxRef?
    let managed: ManagedRef?
    let controllable: Bool
    let approval: ApprovalPrompt?
    let counts: AgentCounts?
    let lastEvent: LastEvent?

    var isLive: Bool { ["working", "approval", "idle"].contains(status) && pid != nil }
    var icon: String { agent == "claude" ? "sparkle" : "terminal" }
}

struct LaunchResult: Codable { let id: String; let tmux: String; let sessionKey: String? }

struct TimelineEvent: Codable, Identifiable, Hashable {
    let id: Int?
    let ts: Double
    let kind: String
    let project: String?
    let session: String?
    let title: String
    let detail: JSONValue?
    let notify: Int?

    var stableId: String { id.map(String.init) ?? "\(kind)-\(ts)-\(title.hashValue)" }
    var follow: JSONValue? { detail?["follow"] }
    var icon: String {
        switch kind {
        case "agent.prompt", "agent.instruction": return "text.bubble"
        case "agent.message": return "sparkle"
        case "agent.command", "agent.command_done": return "terminal"
        case "agent.command_failed": return "xmark.octagon"
        case "agent.test": return "checklist"
        case "agent.edit", "file.changed", "file.saved": return "pencil.line"
        case "agent.image", "screenshot.new": return "photo"
        case "agent.approval", "agent.approval_answered": return "hand.raised"
        case "agent.done": return "checkmark.circle"
        case "agent.error", "server.alert": return "exclamationmark.triangle"
        case "agent.started": return "play.circle"
        case "agent.stopped", "agent.ended": return "stop.circle"
        case "agent.plan": return "list.bullet"
        case "agent.tool": return "wrench.and.screwdriver"
        case "build.started", "build.finished", "build.cancelled": return "hammer"
        case "ci.finished", "ci.rerun", "ci.dispatch", "ci.cancel": return "arrow.triangle.2.circlepath"
        case "git.commit", "git.push", "git.pull": return "arrow.triangle.branch"
        case "vnc.connected": return "display"
        default: return "circle.dashed"
        }
    }
    var tint: String {
        switch kind {
        case "agent.error", "agent.command_failed", "server.alert": return "failed"
        case "agent.approval": return "approval"
        case "agent.done", "git.commit", "git.push": return "succeeded"
        case "build.finished", "ci.finished":
            let ok = detail?["exitCode"]?.number == 0 || detail?["conclusion"]?.string == "success"
            return ok ? "succeeded" : "failed"
        case "agent.edit", "file.changed": return "working"
        default: return "other"
        }
    }
}

struct Screenshot: Codable, Identifiable, Hashable {
    let id: Int
    let ts: Double
    let project: String?
    let session: String?
    let path: String
    let width: Int?
    let height: Int?
    let bytes: Double?
    let source: String
    let note: String?
    var name: String { (path as NSString).lastPathComponent }
}

struct Build: Codable, Identifiable, Hashable {
    let id: String
    let project: String
    let label: String
    let command: String
    let tmux: String?
    let startedAt: Double
    let endedAt: Double?
    let exitCode: Int?
    let status: String
}
struct BuildLog: Codable { let id: String; let status: String; let label: String; let exitCode: Int?; let size: Double?; let text: String; let startedAt: Double; let endedAt: Double? }

struct ServiceState: Codable, Hashable, Identifiable { var id: String { name }; let name: String; let active: String; let sub: String?; let since: String? }
struct Memory: Codable, Hashable { let total: Double; let available: Double; let swapTotal: Double?; let swapFree: Double? }
struct Disk: Codable, Hashable { let size: Double; let used: Double; let available: Double }
struct SystemSummary: Codable {
    let healthy: Bool
    let issues: [String]
    let load: [Double]
    let cpus: Int
    let memory: Memory
    let disk: Disk
    let uptime: Double
    let services: [ServiceState]
}
struct ChangingProject: Codable, Hashable, Identifiable { var id: String { project }; let project: String; let files: Int; let sample: [String]; let last: Double }
struct WatchState: Codable, Hashable { let project: String; let dirs: Int; let until: Double }

struct Overview: Codable {
    let system: SystemSummary
    let agents: [Agent]
    let attention: [Agent]
    let changingProjects: [ChangingProject]
    let screenshots: [Screenshot]
    let builds: [Build]
    let recent: [TimelineEvent]
    let watching: [WatchState]
}

struct Display: Codable, Identifiable, Hashable {
    var id: String { display }
    let display: String
    let pid: Int?
    let width: Int?
    let height: Int?
    let label: String
    let purpose: String?
    let native: Bool
    let controlledBy: String?
}

struct RepoRef: Codable, Hashable, Identifiable { var id: String { repo }; let project: String; let name: String; let repo: String }
struct WorkflowRun: Codable, Hashable, Identifiable {
    var id: Int { databaseId }
    let databaseId: Int
    let displayTitle: String
    let status: String
    let conclusion: String?
    let workflowName: String
    let headBranch: String?
    let headSha: String?
    let event: String?
    let createdAt: String
    let updatedAt: String?
    let url: String
    let number: Int?
    let attempt: Int?
    var jobs: [WorkflowJob]?
    var state: String { status == "completed" ? (conclusion ?? "completed") : status }
}
struct WorkflowJob: Codable, Hashable, Identifiable {
    var id: String { name + (startedAt ?? "") }
    let name: String
    let status: String
    let conclusion: String?
    let startedAt: String?
    let completedAt: String?
    let url: String?
    let steps: [WorkflowStep]?
}
struct WorkflowStep: Codable, Hashable { let name: String; let status: String; let conclusion: String?; let number: Int? }
struct Workflow: Codable, Hashable, Identifiable { let id: Int; let name: String; let path: String; let state: String }
struct LogText: Codable { let text: String; let truncated: Bool? }
struct PullAuthor: Codable, Hashable { let login: String? }
struct PullRequest: Codable, Hashable, Identifiable {
    var id: Int { number }
    let number: Int
    let title: String
    let state: String
    let headRefName: String?
    let baseRefName: String?
    let author: PullAuthor?
    let updatedAt: String?
    let url: String
    let isDraft: Bool?
    let additions: Int?
    let deletions: Int?
}

struct PreviewsResponse: Codable {
    struct Local: Codable, Hashable { let port: Int; let process: String?; let pid: Int?; let cwd: String?; let label: String }
    struct Static: Codable, Hashable { let label: String; let path: String; let url: String }
    let `public`: [PublicPreview]
    let local: [Local]
    let `static`: [Static]
}

struct HostKey: Codable, Hashable { let type: String; let fingerprint: String; let key: String }
struct HostKeys: Codable { let host: String; let port: Int; let user: String; let keys: [HostKey] }
struct PairResponse: Codable { let token: String; let deviceId: String; let expiresAt: Double }
struct Me: Codable { let id: String; let name: String; let expiresAt: Double }
struct DeviceRow: Codable, Identifiable, Hashable { let id: String; let name: String; let created_at: Double; let last_seen: Double?; let expires_at: Double; let revoked: Int }
struct WebSession: Codable { struct Cookie: Codable { let name: String; let value: String; let path: String; let maxAge: Double }; let cookie: Cookie }
struct TmuxSession: Codable, Hashable, Identifiable { var id: String { name }; let name: String; let created: Double; let attached: Int; let windows: Int; let activity: Double }
struct TmuxList: Codable { let sessions: [TmuxSession] }
struct OK: Codable { let ok: Bool? }
struct ScreenCapture: Codable { let text: String?; let controllable: Bool; let tmux: String? }
struct TrashItem: Codable, Identifiable, Hashable { let id: String; let project: String; let path: String; let at: Double }
