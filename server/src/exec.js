// Small helpers for running host tools without a shell (no injection).
import { execFile, spawn } from "node:child_process";

export function run(cmd, args, { cwd, timeout = 20_000, maxBuffer = 16 * 1024 * 1024, input, env } = {}) {
  return new Promise((resolve) => {
    const child = execFile(cmd, args, { cwd, timeout, maxBuffer, env: env ? { ...process.env, ...env } : process.env, encoding: "utf8" },
      (err, stdout, stderr) => resolve({ code: err ? (typeof err.code === "number" ? err.code : 1) : 0, stdout: stdout || "", stderr: stderr || "", error: err && !stdout ? String(err.message) : null }));
    if (input !== undefined) { child.stdin.end(input); }
  });
}

export async function must(cmd, args, opts) {
  const r = await run(cmd, args, opts);
  if (r.code !== 0) throw Object.assign(new Error((r.stderr || r.error || `${cmd} failed`).trim().slice(0, 2000)), { status: 422 });
  return r.stdout;
}

export function runBuffer(cmd, args, { cwd, timeout = 30_000 } = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(cmd, args, { cwd });
    const chunks = [];
    const t = setTimeout(() => child.kill("SIGKILL"), timeout);
    child.stdout.on("data", (c) => chunks.push(c));
    child.on("error", reject);
    child.on("close", (code) => { clearTimeout(t); code === 0 ? resolve(Buffer.concat(chunks)) : reject(new Error(`${cmd} exited ${code}`)); });
  });
}
