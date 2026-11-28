import SwiftUI

struct StudioJob: Decodable, Identifiable {
    struct Artifact: Decodable, Identifiable {
        let name: String
        let bytes: Int
        var id: String { name }
    }

    let id: String
    let project: String
    let tool: String
    let version: String
    let commit: String
    let state: String
    let progress: Int
    let message: String?
    let report: JSONValue?
    let artifacts: [Artifact]

    var actions: [String] {
        switch state {
        case "queued": return ["pause", "cancel"]
        case "paused": return ["resume", "cancel"]
        case "running": return ["cancel"]
        case "failed", "interrupted", "cancelled", "blocked": return ["retry"]
        default: return []
        }
    }
}

struct StudioWorkerHealth: Decodable {
    struct Resources: Decodable {
        let admittingJobs: Bool
    }

    let online: Bool
    let resources: Resources?
    let counts: [String: Int]

    var runningCount: Int { (counts["running"] ?? 0) + (counts["cancelling"] ?? 0) }
}

private struct StudioCatalog: Decodable {
    struct Project: Decodable, Identifiable {
        let id: String
        let name: String
    }

    struct Tool: Decodable, Identifiable {
        struct Inputs: Decodable {
            struct Field: Decodable {
                let title: String
            }

            let required: [String]?
            let properties: [String: Field]
        }

        let id: String
        let title: String
        let version: String
        let description: String
        let dependencies: [String]
        let projects: [String]
        let inputSchema: Inputs
    }

    let tools: [Tool]
    let projects: [Project]
}

struct AutomationView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var size
    @State private var catalog: StudioCatalog?
    @State private var health: StudioWorkerHealth?
    @State private var jobs: [StudioJob] = []
    @State private var selectedTool = ""
    @State private var selectedProject = ""
    @State private var parameters: [String: String] = [:]
    @State private var selectedJob: String?
    @State private var detail: StudioJob?
    @State private var evidence: String?
    @State private var pending = false
    @State private var issue: String?
    @State private var actionIssue: String?

    private let endpoint = "/api/automation"

    private var tool: StudioCatalog.Tool? { catalog?.tools.first { $0.id == selectedTool } }
    private var compatibleProjects: [StudioCatalog.Project] {
        catalog?.projects.filter { tool?.projects.contains($0.id) == true } ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Automation").font(.title2.weight(.semibold))
                Spacer()
                if let health {
                    Text(health.online ? (health.resources?.admittingJobs == true ? "Worker online" : "Waiting for resources") : "Worker offline")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(health.online ? Theme.textDim : Theme.yellow)
                }
            }
            .padding()
            Divider()
            if let issue {
                Text(issue).foregroundStyle(Theme.yellow).padding()
            } else if catalog == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if size == .regular {
                HStack(alignment: .top, spacing: 0) {
                    ScrollView { controls.padding() }.frame(width: 330)
                    Divider()
                    ScrollView { history.padding() }.frame(maxWidth: .infinity)
                }
            } else {
                ScrollView {
                    controls.padding()
                    Divider()
                    history.padding()
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.text)
        .background(Theme.bg)
        .task(id: app.activeMachine?.id) {
            catalog = nil
            selectedTool = ""
            selectedProject = ""
            selectedJob = nil
            detail = nil
            jobs = []
            issue = nil
            actionIssue = nil
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Tool Library").font(.headline)
            Picker("Tool", selection: $selectedTool) {
                ForEach(catalog?.tools ?? []) { tool in Text(tool.title).tag(tool.id) }
            }
            .onChange(of: selectedTool) {
                parameters = [:]
                if !compatibleProjects.contains(where: { $0.id == selectedProject }) {
                    selectedProject = compatibleProjects.first?.id ?? ""
                }
            }
            if let tool {
                Text(tool.description).font(.callout)
                Text("Version \(tool.version) · \(tool.dependencies.joined(separator: ", "))")
                    .font(.caption).foregroundStyle(Theme.textDim)
                Picker("Project", selection: $selectedProject) {
                    ForEach(compatibleProjects) { project in Text(project.name).tag(project.id) }
                }
                ForEach(tool.inputSchema.properties.keys.sorted(), id: \.self) { name in
                    TextField(tool.inputSchema.properties[name]?.title ?? name, text: Binding(
                        get: { parameters[name] ?? "" },
                        set: { parameters[name] = $0 }
                    ))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                }
                Text("Uses the latest committed version when queued.")
                    .font(.caption).foregroundStyle(Theme.textDim)
                Button {
                    Task { await submit() }
                } label: {
                    Label("Queue Job", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(pending || selectedProject.isEmpty ||
                          (tool.inputSchema.required ?? []).contains { parameters[$0]?.isEmpty != false })
            }
            if let actionIssue {
                Text(actionIssue).font(.callout).foregroundStyle(Theme.yellow)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Jobs").font(.headline)
            if jobs.isEmpty {
                Text("No jobs have been submitted.").foregroundStyle(Theme.textDim)
            }
            ForEach(jobs) { job in
                Button {
                    selectedJob = selectedJob == job.id ? nil : job.id
                    detail = nil
                    evidence = nil
                    Task { await loadDetail() }
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(catalog?.tools.first { $0.id == job.tool }?.title ?? job.tool).font(.subheadline.weight(.semibold))
                            Spacer()
                            Text(job.state.capitalized).font(.caption)
                                .foregroundStyle(job.state == "failed" ? Theme.yellow : Theme.textDim)
                        }
                        Text(catalog?.projects.first { $0.id == job.project }?.name ?? job.project)
                            .font(.caption).foregroundStyle(Theme.textDim)
                        if job.state == "running" || job.state == "cancelling" {
                            ProgressView(value: Double(job.progress), total: 100)
                            if let message = job.message { Text(message).font(.caption) }
                        }
                    }
                    .padding(12)
                    .background(selectedJob == job.id ? Theme.hover : Theme.surface, in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                if selectedJob == job.id {
                    jobDetail(detail?.id == job.id ? detail ?? job : job)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func jobDetail(_ job: StudioJob) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Commit \(job.commit.prefix(12)) · Tool \(job.version)").font(.caption.monospaced())
            if let message = job.message { Text(message).font(.callout) }
            if !job.actions.isEmpty {
                HStack {
                    ForEach(job.actions, id: \.self) { action in
                        Button(action.capitalized) { Task { await change(job, action: action) } }
                            .buttonStyle(.bordered).disabled(pending)
                    }
                }
            }
            if let report = job.report {
                DisclosureGroup("Structured report") {
                    ScrollView(.horizontal) {
                        Text(formatted(report)).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
            }
            ForEach(job.artifacts) { artifact in
                Button {
                    Task {
                        do {
                            let data = try await app.client.data("\(endpoint)/jobs/\(job.id)/artifacts/\(artifact.name.pathSegment)")
                            if selectedJob == job.id {
                                evidence = String(decoding: data.prefix(64 * 1024), as: UTF8.self)
                                if data.count > 64 * 1024 { evidence?.append("\n… Preview limited to 64 KiB") }
                            }
                        } catch { actionIssue = error.localizedDescription }
                    }
                } label: {
                    Label(artifact.name, systemImage: "doc.text")
                }
            }
            if let evidence {
                ScrollView([.horizontal, .vertical]) {
                    Text(evidence).font(.caption.monospaced()).textSelection(.enabled)
                }
                .frame(maxHeight: 300)
            }
        }
        .padding(.horizontal, 12)
    }

    private func formatted(_ report: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(report) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private func refresh() async {
        do {
            if catalog == nil {
                let registered = try await app.client.get("\(endpoint)/catalog", as: StudioCatalog.self)
                guard !Task.isCancelled else { return }
                catalog = registered
                selectedTool = registered.tools.first?.id ?? ""
                selectedProject = registered.projects.first?.id ?? ""
            }
            async let listing = app.client.get("\(endpoint)/jobs", as: [StudioJob].self)
            async let worker = app.client.get("\(endpoint)/health", as: StudioWorkerHealth.self)
            let (recent, status) = try await (listing, worker)
            guard !Task.isCancelled else { return }
            (jobs, health) = (recent, status)
            app.automationRunning = status.online ? status.runningCount : 0
            issue = nil
            if selectedJob != nil { await loadDetail() }
        } catch let error as GatewayError where error.status == 404 {
            issue = "This gateway does not offer Studio Automation."
        } catch {
            if !Task.isCancelled { issue = error.localizedDescription }
        }
    }

    private func submit() async {
        pending = true
        actionIssue = nil
        defer { pending = false }
        do {
            let job = try await app.client.send("POST", "\(endpoint)/jobs", [
                "tool": selectedTool, "project": selectedProject, "inputs": parameters.filter { !$0.value.isEmpty },
            ], as: StudioJob.self)
            selectedJob = job.id
            detail = job
            evidence = nil
            await refresh()
        } catch { actionIssue = error.localizedDescription }
    }

    private func loadDetail() async {
        guard let selectedJob else { return }
        do {
            let job = try await app.client.get("\(endpoint)/jobs/\(selectedJob)", as: StudioJob.self)
            if self.selectedJob == selectedJob && !Task.isCancelled { detail = job }
        } catch {
            if !Task.isCancelled { actionIssue = error.localizedDescription }
        }
    }

    private func change(_ job: StudioJob, action: String) async {
        pending = true
        actionIssue = nil
        defer { pending = false }
        do {
            let updated = try await app.client.send("POST", "\(endpoint)/jobs/\(job.id)/actions/\(action)", as: StudioJob.self)
            selectedJob = updated.id
            detail = updated
            if updated.id != job.id { evidence = nil }
            await refresh()
        } catch { actionIssue = error.localizedDescription }
    }
}
