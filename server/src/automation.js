// The trusted, short-lived CLI talks to SQLite. The gateway never owns a job process.
import path from "node:path";
import { fileURLToPath } from "node:url";
import { expand } from "./config.js";
import { run } from "./exec.js";

const script = fileURLToPath(new URL("../automation/studio.py", import.meta.url));
const actions = new Set(["pause", "resume", "cancel", "retry"]);

export function createAutomation(cfg) {
  const enabled = cfg.profile === "personal" && !cfg.hosted &&
    process.platform === "linux" && cfg.automation?.enabled === true;
  const data = expand(cfg.automation?.dataDir) || path.join(cfg.dataDir, "automation");
  const projects = expand(cfg.automation?.projectRoot) || path.join(cfg.home, "workspace/projects");

  function fault(message, status) {
    return Object.assign(new Error(message), { status });
  }

  async function call(args, input) {
    if (!enabled) throw fault("Studio automation is disabled on this machine.", 503);
    const result = await run(cfg.python3 || "/usr/bin/python3", ["-B", script, "--data", data, "--projects", projects, ...args], {
      input, timeout: 20_000, maxBuffer: 2 * 1024 * 1024,
    });
    let payload;
    try { payload = JSON.parse(result.stdout); }
    catch { throw fault("Studio automation is unavailable.", 503); }
    if (result.code !== 0) throw fault(payload.error || "Studio automation could not process the request.", payload.status || 503);
    return payload;
  }

  return {
    enabled,
    catalog: () => call(["catalog"]),
    health: () => call(["health"]),
    jobs: (project) => call(project ? ["jobs", `--project=${project}`] : ["jobs"]),
    submit: (request) => call(["enqueue"], JSON.stringify(request)),
    get: (job) => call(["get", "--", job]),
    action: (job, action) => {
      if (!actions.has(action)) throw fault("Job action not found.", 404);
      return call([action, "--", job]);
    },
    artifact: (job, name) => call(["artifact", "--", job, name]),
  };
}
