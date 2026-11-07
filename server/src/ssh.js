// SSH bootstrap for the app's real terminal.
// * Host keys: fingerprints are served over the authenticated TLS channel so
//   the app can pin them and verify the SSH server on every connection.
// * Device keys: the iPad generates an Ed25519 key in its Keychain and sends
//   only the public half; it is added to ~/.ssh/authorized_keys tagged with
//   the device id, and removed again when the device is revoked.
import fs from "node:fs";
import crypto from "node:crypto";
import os from "node:os";
import path from "node:path";

const AUTH = path.join(os.homedir(), ".ssh", "authorized_keys");

export function hostKeys() {
  const out = [];
  for (const f of fs.readdirSync("/etc/ssh").filter((n) => /^ssh_host_.*_key\.pub$/.test(n))) {
    const [type, b64] = fs.readFileSync(path.join("/etc/ssh", f), "utf8").trim().split(/\s+/);
    const fp = "SHA256:" + crypto.createHash("sha256").update(Buffer.from(b64, "base64")).digest("base64").replace(/=+$/, "");
    out.push({ type, fingerprint: fp, key: `${type} ${b64}` });
  }
  return { host: "musastudios.co.uk", port: 22, user: os.userInfo().username, keys: out };
}

// Only plain ssh-ed25519 keys with a 32-byte body are accepted.
export function validEd25519(pub) {
  const m = String(pub || "").trim().match(/^ssh-ed25519 ([A-Za-z0-9+/]+={0,2})(?: .*)?$/);
  if (!m) return null;
  const blob = Buffer.from(m[1], "base64");
  const tlen = blob.readUInt32BE(0);
  if (blob.subarray(4, 4 + tlen).toString() !== "ssh-ed25519") return null;
  const klen = blob.readUInt32BE(4 + tlen);
  if (klen !== 32 || blob.length !== 4 + tlen + 4 + 32) return null;
  return m[1];
}

export function authorize(deviceId, deviceName, pub, file = AUTH) {
  const b64 = validEd25519(pub);
  if (!b64) throw Object.assign(new Error("Expected an ssh-ed25519 public key"), { status: 400 });
  const tag = `musa-control:${deviceId}`;
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  const lines = fs.existsSync(file) ? fs.readFileSync(file, "utf8").split("\n") : [];
  if (lines.some((l) => l.includes(b64))) return { ok: true, already: true };
  const kept = lines.filter((l) => l.trim() && !l.split(" ").includes(tag)); // one key per device
  kept.push(`ssh-ed25519 ${b64} ${tag} ${String(deviceName).replace(/[^\w .-]/g, "").slice(0, 40).replace(/ /g, "_")}`);
  const tmp = file + ".mc-tmp";
  fs.writeFileSync(tmp, kept.join("\n") + "\n", { mode: 0o600 });
  fs.renameSync(tmp, file);
  return { ok: true };
}

export function deauthorize(deviceId, file = AUTH) {
  if (!fs.existsSync(file)) return;
  const tag = `musa-control:${deviceId}`;
  const lines = fs.readFileSync(file, "utf8").split("\n");
  const kept = lines.filter((l) => !l.split(" ").includes(tag));
  if (kept.length !== lines.length) { fs.writeFileSync(file + ".mc-tmp", kept.join("\n"), { mode: 0o600 }); fs.renameSync(file + ".mc-tmp", file); }
}
