// Authenticated Musa Control clients can talk to the existing dashboard's
// narrow, same-user Unix socket. Public/hosted peers cannot reach it.
import fs from "node:fs";
import http from "node:http";
import path from "node:path";
import { expand } from "./config.js";

const error = (status, message) => Object.assign(new Error(message), { status });

export function createLiveWork(cfg, projects) {
  const socketPath = expand(cfg.liveWork?.socketPath) || path.join(cfg.home, "workspace/.musa-live-work/native/control.sock");
  const personal = cfg.profile === "personal" && !cfg.hosted && process.platform === "linux" && cfg.liveWork?.enabled !== false;
  function available() {
    if (!personal) return false;
    try {
      const endpoint = fs.lstatSync(socketPath);
      const parent = fs.lstatSync(path.dirname(socketPath));
      const uid = process.getuid();
      return parent.isDirectory() && parent.uid === uid && (parent.mode & 0o077) === 0 &&
        endpoint.isSocket() && endpoint.uid === uid && (endpoint.mode & 0o077) === 0;
    } catch { return false; }
  }

  function ident(device) {
    if (!device || device.relay || !personal) throw error(403, "Live Work is available on the paired studio machine.");
    if (!available()) throw error(503, "The original Live Work dashboard is unavailable.");
  }

  async function call(method, endpoint, payload, device) {
    ident(device);
    const body = payload && JSON.stringify(payload);
    if (body && Buffer.byteLength(body) > 32768) throw error(413, "Live Work request is too large.");
    return new Promise((resolve, reject) => {
      const req = http.request({
        socketPath, method, path: endpoint, agent: false,
        headers: body ? {"Content-Type": "application/json", "Content-Length": Buffer.byteLength(body)} : {},
      }, res => {
        const pieces = [];
        let bytes = 0;
        res.on("data", chunk => {
          bytes += chunk.length;
          if (bytes > 512 * 1024) req.destroy(error(502, "Live Work response exceeded its limit."));
          else pieces.push(chunk);
        });
        res.on("error", () => reject(error(502, "The Live Work response was interrupted.")));
        res.on("end", () => {
          let value;
          try { value = JSON.parse(Buffer.concat(pieces)); }
          catch { return reject(error(502, "Invalid Live Work response.")); }
          if (res.statusCode !== 200) return reject(error(res.statusCode || 502, typeof value.error === "string" ? value.error : "Live Work action failed."));
          resolve(value);
        });
      });
      req.setTimeout(110_000, () => req.destroy(error(504, "Live Work did not answer. Check job state before retrying.")));
      req.on("error", failure => reject(failure.status ? failure : error(503, "The original Live Work dashboard is unreachable.")));
      req.end(body);
    });
  }

  async function state(method, endpoint, payload, device) {
    const value = await call(method, endpoint, payload, device);
    const project = value.projectPath ? [...projects.all().values()].find(item => item.path === value.projectPath) : null;
    delete value.projectPath;
    return { ...value, project: project?.id ?? null };
  }

  return {
    available: device => !device?.relay && available(),
    state: device => state("GET", "/state", undefined, device),
    terminal: device => call("GET", "/terminal", undefined, device),
    start: (device, body) => {
      ident(device);
      if (typeof body?.project !== "string" || typeof body?.requestId !== "string" ||
          !/^[a-f0-9-]{36}$/i.test(body.requestId)) throw error(400, "Select a project and provide a request ID.");
      return state("POST", "/start", {projectPath: projects.get(body.project).path, text: body.text, requestId: body.requestId}, device);
    },
    control: (device, body) => state("POST", "/control", {
      action: body?.action, jobId: body?.jobId, pendingId: body?.pendingId, commandId: body?.commandId,
      confirm: body?.confirm === true, nativeBrowser: body?.nativeBrowser === true, text: body?.text, requestId: body?.requestId,
    }, device),
    focus: device => state("POST", "/focus", {}, device),
  };
}
