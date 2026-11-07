// musa-control gateway entry point (systemd: musa-control.service).
import { createServer } from "./server.js";

const app = createServer();
const addr = await app.start();
console.info(`musa-control gateway listening on ${addr.address}:${addr.port}`);
let stopping = false;
for (const sig of ["SIGTERM", "SIGINT"]) process.on(sig, async () => {
  if (stopping) return; stopping = true;
  console.info(`received ${sig}, stopping`);
  setTimeout(() => process.exit(0), 5000).unref();
  await app.stop().catch(() => {});
  process.exit(0);
});
