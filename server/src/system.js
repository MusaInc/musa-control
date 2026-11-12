// Server health for the Home screen, from the host itself.
import os from "node:os";
import fs from "node:fs";
import * as platform from "./platform.js";

export function createSystem(cfg, events) {
  const lastState = new Map();
  let lastDiskAlert = 0;

  async function snapshot() {
    const [svc, dsk, top, ports, mem] = await Promise.all([
      platform.services(cfg.services), platform.disk(), platform.topProcesses(8), platform.listeningPorts(), platform.memory(),
    ]);
    const load = os.loadavg();
    const snap = {
      host: os.hostname(), os: platform.osName(), uptime: os.uptime(), cpus: os.cpus().length, load,
      memory: mem, disk: dsk, services: svc, topProcesses: top, listening: ports.length,
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
    const diskPct = snap.disk.size ? snap.disk.used / snap.disk.size : 0;
    if (diskPct > 0.9) { issues.push(`Disk ${Math.round(diskPct * 100)}% full`); if (Date.now() - lastDiskAlert > 6 * 3600_000) { lastDiskAlert = Date.now(); events.emit({ kind: "server.alert", title: `Disk ${Math.round(diskPct * 100)}% full`, detail: {}, notify: true }); } }
    if (snap.memory.available / snap.memory.total < 0.05) issues.push("Memory nearly exhausted");
    if (load[0] > snap.cpus * 2) issues.push(`High load ${load[0].toFixed(1)}`);
    snap.issues = issues;
    snap.healthy = issues.length === 0;
    return snap;
  }

  const listeningPorts = () => platform.listeningPorts();

  return { snapshot, listeningPorts };
}
