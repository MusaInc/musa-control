// Server health for the Home screen, from the host itself.
import os from "node:os";
import fs from "node:fs";
import { run } from "./exec.js";

export function createSystem(cfg, events) {
  const lastState = new Map();
  let lastDiskAlert = 0;

  async function services() {
    const r = await run("systemctl", ["show", ...cfg.services.map((s) => `${s}.service`), "--property=Id,ActiveState,SubState,ActiveEnterTimestamp", "--no-pager"]);
    const out = [];
    for (const block of r.stdout.split("\n\n")) {
      const kv = Object.fromEntries(block.split("\n").filter(Boolean).map((l) => [l.slice(0, l.indexOf("=")), l.slice(l.indexOf("=") + 1)]));
      if (!kv.Id) continue;
      out.push({ name: kv.Id.replace(/\.service$/, ""), active: kv.ActiveState, sub: kv.SubState, since: kv.ActiveEnterTimestamp || null });
    }
    return out;
  }

  async function snapshot() {
    const [svc, df, top, ports] = await Promise.all([
      services(),
      run("df", ["-P", "-B1", "/"]),
      run("ps", ["-eo", "pid=,pcpu=,pmem=,etimes=,comm=", "--sort=-pcpu"]),
      run("ss", ["-ltnpH"]),
    ]);
    const [, size, used, avail] = df.stdout.trim().split("\n").pop().split(/\s+/);
    const memInfo = Object.fromEntries(fs.readFileSync("/proc/meminfo", "utf8").split("\n").filter(Boolean).map((l) => { const [k, v] = l.split(":"); return [k, parseInt(v) * 1024]; }));
    const load = os.loadavg();
    const snap = {
      host: os.hostname(), uptime: os.uptime(), cpus: os.cpus().length, load,
      memory: { total: memInfo.MemTotal, available: memInfo.MemAvailable, swapTotal: memInfo.SwapTotal, swapFree: memInfo.SwapFree },
      disk: { size: +size, used: +used, available: +avail },
      services: svc,
      topProcesses: top.stdout.split("\n").slice(0, 8).map((l) => l.trim().split(/\s+/)).filter((a) => a.length >= 5).map(([pid, cpu, mem, et, comm]) => ({ pid: +pid, cpu: +cpu, mem: +mem, elapsed: +et, command: comm })),
      listening: ports.stdout.split("\n").filter(Boolean).length,
    };
    const issues = [];
    for (const s of svc) {
      const prev = lastState.get(s.name);
      if (s.active !== "active" && s.active !== "inactive") issues.push(`${s.name} is ${s.active}`);
      if (prev && prev === "active" && s.active !== "active") {
        events.emit({ kind: "server.alert", title: `${s.name} is ${s.active} (${s.sub})`, detail: { service: s.name, state: s.active }, notify: true });
      }
      lastState.set(s.name, s.active);
    }
    const diskPct = snap.disk.used / snap.disk.size;
    if (diskPct > 0.9) { issues.push(`Disk ${Math.round(diskPct * 100)}% full`); if (Date.now() - lastDiskAlert > 6 * 3600_000) { lastDiskAlert = Date.now(); events.emit({ kind: "server.alert", title: `Disk ${Math.round(diskPct * 100)}% full`, detail: {}, notify: true }); } }
    if (snap.memory.available / snap.memory.total < 0.05) issues.push("Memory nearly exhausted");
    if (load[0] > snap.cpus * 2) issues.push(`High load ${load[0].toFixed(1)}`);
    snap.issues = issues;
    snap.healthy = issues.length === 0;
    return snap;
  }

  async function listeningPorts() {
    const r = await run("ss", ["-ltnpH"]);
    const out = [];
    for (const line of r.stdout.split("\n")) {
      const m = line.match(/\s(127\.0\.0\.1|0\.0\.0\.0|\[::1?\]|\*|[\d.]+):(\d+)\s.*?users:\(\("([^"]+)",pid=(\d+)/);
      if (!m) continue;
      let cwd = null; try { cwd = fs.readlinkSync(`/proc/${m[4]}/cwd`); } catch {}
      out.push({ address: m[1], port: +m[2], process: m[3], pid: +m[4], cwd });
    }
    return out;
  }

  return { snapshot, listeningPorts };
}
