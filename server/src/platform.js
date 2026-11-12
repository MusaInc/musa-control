// Host facts that differ between Linux and macOS (the companion's two native
// platforms; on Windows it runs inside WSL2, which is Linux). Everything
// shells out without a shell and degrades to "unknown" rather than failing.
import fs from "node:fs";
import os from "node:os";
import { run } from "./exec.js";

export const IS_MAC = process.platform === "darwin";
const has = new Map();
export async function hasCommand(name) {
  if (!has.has(name)) {
    const r = await run("/bin/sh", ["-c", `command -v ${name.replace(/[^\w.-]/g, "")}`], { timeout: 4000 });
    has.set(name, r.code === 0 && r.stdout.trim() ? r.stdout.trim() : null);
  }
  return has.get(name);
}

const cwdCache = new Map(); // pid → {cwd, at}
export async function cwdOf(pid) {
  if (!IS_MAC) { try { return fs.readlinkSync(`/proc/${pid}/cwd`); } catch { return null; } }
  const c = cwdCache.get(pid);
  if (c && Date.now() - c.at < 30_000) return c.cwd;
  const r = await run("lsof", ["-a", "-p", String(pid), "-d", "cwd", "-Fn"], { timeout: 4000 });
  const cwd = r.stdout.split("\n").find((l) => l.startsWith("n"))?.slice(1) || null;
  cwdCache.set(pid, { cwd, at: Date.now() });
  return cwd;
}

// [{pid, ppid, started(ms), args}]
export async function processTable() {
  const r = await run("ps", IS_MAC ? ["-axwwo", "pid=,ppid=,lstart=,args="] : ["-eo", "pid=,ppid=,lstart=,args=", "--cols", "800"]);
  const out = [];
  for (const line of r.stdout.split("\n")) {
    const m = line.match(/^\s*(\d+)\s+(\d+)\s+(\w+\s+\w+\s+\d+\s+[\d:]+\s+\d+)\s+(.*)$/);
    if (m) out.push({ pid: +m[1], ppid: +m[2], started: Date.parse(m[3]), args: m[4] });
  }
  return out;
}

export async function topProcesses(n = 8) {
  const r = await run("ps", IS_MAC ? ["-axo", "pid=,pcpu=,pmem=,etime=,comm=", "-r"] : ["-eo", "pid=,pcpu=,pmem=,etimes=,comm=", "--sort=-pcpu"]);
  return r.stdout.split("\n").slice(0, n).map((l) => l.trim().split(/\s+/)).filter((a) => a.length >= 5)
    .map(([pid, cpu, mem, et, ...comm]) => ({ pid: +pid, cpu: +cpu, mem: +mem, elapsed: IS_MAC ? etimeSeconds(et) : +et, command: comm.join(" ").split("/").pop() }));
}
function etimeSeconds(s) { // [[dd-]hh:]mm:ss
  const [d, rest] = s.includes("-") ? s.split("-") : [0, s];
  const p = rest.split(":").map(Number).reverse();
  return (+d * 86400) + (p[0] || 0) + (p[1] || 0) * 60 + (p[2] || 0) * 3600;
}

// [{address, port, process, pid, cwd}]
export async function listeningPorts() {
  const out = [];
  if (!IS_MAC && await hasCommand("ss")) {
    const r = await run("ss", ["-ltnpH"]);
    for (const line of r.stdout.split("\n")) {
      const m = line.match(/\s(127\.0\.0\.1|0\.0\.0\.0|\[::1?\]|\*|[\d.]+):(\d+)\s.*?users:\(\("([^"]+)",pid=(\d+)/);
      if (m) out.push({ address: m[1], port: +m[2], process: m[3], pid: +m[4], cwd: await cwdOf(+m[4]) });
    }
    return out;
  }
  if (!(await hasCommand("lsof"))) return out;
  const r = await run("lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpcn"], { timeout: 8000 });
  let pid = null, cmd = null;
  const seen = new Set();
  for (const l of r.stdout.split("\n")) {
    if (l.startsWith("p")) pid = +l.slice(1); else if (l.startsWith("c")) cmd = l.slice(1);
    else if (l.startsWith("n") && pid) {
      const m = l.match(/^n(.*):(\d+)$/);
      if (!m || seen.has(`${pid}:${m[2]}`)) continue;
      seen.add(`${pid}:${m[2]}`);
      out.push({ address: m[1], port: +m[2], process: cmd, pid, cwd: await cwdOf(pid) });
    }
  }
  return out;
}

export async function memory() {
  if (!IS_MAC) {
    try {
      const m = Object.fromEntries(fs.readFileSync("/proc/meminfo", "utf8").split("\n").filter(Boolean).map((l) => { const [k, v] = l.split(":"); return [k, parseInt(v) * 1024]; }));
      return { total: m.MemTotal, available: m.MemAvailable, swapTotal: m.SwapTotal, swapFree: m.SwapFree };
    } catch {}
  }
  return { total: os.totalmem(), available: os.freemem(), swapTotal: 0, swapFree: 0 };
}

export async function disk() {
  const r = await run("df", ["-Pk", os.homedir()]);
  const [, size, used, avail] = (r.stdout.trim().split("\n").pop() || "").split(/\s+/);
  return { size: +size * 1024 || 0, used: +used * 1024 || 0, available: +avail * 1024 || 0 };
}

// systemd units (Linux only); [] elsewhere or when nothing is configured.
export async function services(names) {
  if (!names?.length || IS_MAC || !(await hasCommand("systemctl"))) return [];
  const r = await run("systemctl", ["show", ...names.map((s) => `${s}.service`), "--property=Id,ActiveState,SubState,ActiveEnterTimestamp", "--no-pager"]);
  const out = [];
  for (const block of r.stdout.split("\n\n")) {
    const kv = Object.fromEntries(block.split("\n").filter(Boolean).map((l) => [l.slice(0, l.indexOf("=")), l.slice(l.indexOf("=") + 1)]));
    if (!kv.Id) continue;
    out.push({ name: kv.Id.replace(/\.service$/, ""), active: kv.ActiveState, sub: kv.SubState, since: kv.ActiveEnterTimestamp || null });
  }
  return out;
}

export function osName() {
  if (IS_MAC) return `macOS ${os.release()}`;
  try {
    const rel = fs.readFileSync("/etc/os-release", "utf8");
    const pretty = rel.match(/^PRETTY_NAME="?([^"\n]+)"?/m)?.[1];
    const wsl = /microsoft/i.test(os.release()) ? " (WSL)" : "";
    return (pretty || `Linux ${os.release()}`) + wsl;
  } catch { return `${process.platform} ${os.release()}`; }
}
