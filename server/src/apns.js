// Apple Push Notification service client: HTTP/2 + token (JWT, ES256) auth.
//
// Configuration (none of it lives in the repo):
//   ~/.config/musa-control/apns.json  {"keyFile": "...AuthKey_XXXX.p8", "keyId": "XXXX", "teamId": "YYYY",
//                                      "topic": "uk.co.musastudios.musacontrol"}
// or the same keys under "apns" in config.json. An APNs auth key works for
// every app in the Apple Developer team. Without it, push stays off and the
// app falls back to the live stream + background refresh.
import http2 from "node:http2";
import crypto from "node:crypto";
import fs from "node:fs";
import { expand } from "./config.js";

const HOSTS = { production: "https://api.push.apple.com", sandbox: "https://api.sandbox.push.apple.com" };

export function loadApnsConfig(cfg) {
  let c = cfg.apns || null;
  const file = expand(cfg.apnsConfigFile || "~/.config/musa-control/apns.json");
  if (!c && fs.existsSync(file)) {
    try { c = JSON.parse(fs.readFileSync(file, "utf8")); } catch (e) { return { configured: false, reason: `apns.json is not valid JSON: ${e.message}` }; }
  }
  if (!c) return { configured: false, reason: "No APNs key on the server yet (~/.config/musa-control/apns.json)." };
  for (const k of ["keyFile", "keyId", "teamId"]) if (!c[k]) return { configured: false, reason: `apns.json is missing "${k}".` };
  const keyFile = expand(c.keyFile);
  if (!fs.existsSync(keyFile)) return { configured: false, reason: `APNs key file not found: ${keyFile}` };
  return { configured: true, keyFile, keyId: c.keyId, teamId: c.teamId, topic: c.topic || "uk.co.musastudios.musacontrol", hosts: c.hosts || HOSTS };
}

export function createApns(conf, { transport } = {}) {
  let jwt = null, jwtAt = 0;
  const sessions = new Map(); // host → ClientHttp2Session

  function token() {
    // Apple accepts a token for up to an hour and rejects refreshes more often than every 20 minutes.
    if (jwt && Date.now() - jwtAt < 45 * 60_000) return jwt;
    const b64 = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
    const iat = Math.floor(Date.now() / 1000);
    const unsigned = `${b64({ alg: "ES256", kid: conf.keyId })}.${b64({ iss: conf.teamId, iat })}`;
    const key = crypto.createPrivateKey(fs.readFileSync(conf.keyFile));
    const sig = crypto.sign("sha256", Buffer.from(unsigned), { key, dsaEncoding: "ieee-p1363" }).toString("base64url");
    jwt = `${unsigned}.${sig}`; jwtAt = Date.now();
    return jwt;
  }

  function session(host) {
    let s = sessions.get(host);
    if (s && !s.closed && !s.destroyed) return s;
    s = http2.connect(host);
    s.on("error", () => sessions.delete(host));
    s.on("goaway", () => sessions.delete(host));
    s.on("close", () => sessions.delete(host));
    s.setTimeout(10 * 60_000, () => s.close());
    sessions.set(host, s);
    return s;
  }

  // Sends one notification. Resolves {status, reason, apnsId}; never throws.
  async function send({ deviceToken, environment = "production", payload, pushType = "alert", priority = 10, collapseId, expiration }) {
    const headers = {
      ":method": "POST", ":path": `/3/device/${deviceToken}`,
      authorization: transport ? "bearer test" : `bearer ${token()}`, "apns-topic": conf.topic, "apns-push-type": pushType, "apns-priority": String(priority),
    };
    if (collapseId) headers["apns-collapse-id"] = String(collapseId).slice(0, 64);
    if (expiration) headers["apns-expiration"] = String(Math.floor(expiration / 1000));
    const body = JSON.stringify(payload);
    if (transport) return transport({ headers, body, environment, deviceToken });
    const host = conf.hosts[environment === "sandbox" ? "sandbox" : "production"];
    return new Promise((resolve) => {
      let req;
      try { req = session(host).request(headers); } catch (e) { return resolve({ status: 0, reason: e.message }); }
      let status = 0, apnsId = null, data = "";
      req.setEncoding("utf8");
      req.on("response", (h) => { status = h[":status"]; apnsId = h["apns-id"] || null; });
      req.on("data", (c) => { data += c; });
      req.on("end", () => { let reason = null; try { reason = data ? JSON.parse(data).reason : null; } catch {} resolve({ status, reason, apnsId }); });
      req.on("error", (e) => resolve({ status: 0, reason: e.message }));
      req.setTimeout(15_000, () => { req.close(); resolve({ status: 0, reason: "timeout" }); });
      req.end(body);
    });
  }

  function close() { for (const s of sessions.values()) try { s.close(); } catch {} sessions.clear(); }
  return { send, close };
}
