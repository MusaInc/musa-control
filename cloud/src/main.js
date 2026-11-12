// Musa Control Cloud entry point.
import { createServer } from "./server.js";
const app = createServer();
const addr = await app.start();
console.info(`musa-control-cloud listening on ${addr.address}:${addr.port} (public ${app.cfg.publicUrl}, push ${app.push.enabled ? "on" : "off"})`);
for (const sig of ["SIGTERM", "SIGINT"]) process.on(sig, async () => { setTimeout(() => process.exit(0), 5000).unref(); await app.stop().catch(() => {}); process.exit(0); });
