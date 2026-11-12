// Outbound link from a companion to the Musa Control account service, for
// machines the iPad can't reach directly (a home Mac or PC behind NAT). The
// companion dials out over WSS. Nothing on the machine listens publicly. The
// service forwards the owner's requests down this socket. The link replays
// them against the local gateway on 127.0.0.1, adding the in-memory relay
// secret and the account id the service vouched for (auth.js accepts them
// only when that account is this machine's owner).
//
// Wire format (shared with cloud/src/relay.js):
//   text frames   JSON control: req / res / end / err / cancel / ws / ws-ok /
//                 ws-fail / ws-close / hello / push
//   binary frames [kind u8][stream id u32 BE][payload]
//                 kind 1 = HTTP body chunk, 2 = WS binary message, 3 = WS text message
import http from "node:http";
import os from "node:os";
import WebSocket from "ws";

export const FRAME = { BODY: 1, WS_BIN: 2, WS_TEXT: 3 };
export function frame(kind, id, payload) {
  const head = Buffer.alloc(5);
  head.writeUInt8(kind, 0); head.writeUInt32BE(id >>> 0, 1);
  return Buffer.concat([head, Buffer.isBuffer(payload) ? payload : Buffer.from(payload)]);
}
export function unframe(buf) { return { kind: buf.readUInt8(0), id: buf.readUInt32BE(1), payload: buf.subarray(5) }; }

const HOP = new Set(["connection", "keep-alive", "proxy-connection", "transfer-encoding", "upgrade", "te", "trailer", "host", "content-length"]);
const strip = (h) => Object.fromEntries(Object.entries(h || {}).filter(([k]) => !HOP.has(k.toLowerCase()) && !k.toLowerCase().startsWith("x-mc-relay") && !["x-mc-user", "x-mc-session", "x-mc-device-name", "x-mc-base"].includes(k.toLowerCase())));
const HIGH_WATER = 4 * 1024 * 1024;

export function createRelayLink(cfg, auth, { localPort, info, onState } = {}) {
  let ws = null, stopped = false, retry = 0, timer = null, state = "off";
  const streams = new Map(); // id → {req?, res?, ws?}

  const setState = (s, detail) => { state = s; onState?.(s, detail); };

  function connect() {
    if (stopped || !cfg.relay?.url || !cfg.relay?.machineSecret) return;
    setState("connecting");
    const url = cfg.relay.url.replace(/^http/, "ws").replace(/\/+$/, "") + "/v1/relay/connect";
    ws = new WebSocket(url, { headers: { Authorization: `Bearer ${cfg.relay.machineSecret}` }, maxPayload: 32 * 1024 * 1024, handshakeTimeout: 15_000 });
    let alive = true;
    const ping = setInterval(() => { if (!alive) return ws.terminate(); alive = false; try { ws.ping(); } catch {} }, 25_000);
    ws.on("pong", () => { alive = true; });
    ws.on("open", () => { retry = 0; setState("online"); send({ t: "hello", info: info?.() || {} }); });
    ws.on("message", (data, isBinary) => (isBinary ? onBinary(data) : onControl(JSON.parse(String(data)))));
    ws.on("unexpected-response", (_req, res) => {
      setState(res.statusCode === 401 || res.statusCode === 403 ? "unlinked" : "error", `relay refused: ${res.statusCode}`);
      if (res.statusCode === 401 || res.statusCode === 403) stopped = true; // machine was removed from the account
    });
    ws.on("error", (e) => setState("error", e.message));
    ws.on("close", () => {
      clearInterval(ping);
      for (const [id, s] of streams) { s.req?.destroy(); s.ws?.close(); streams.delete(id); }
      if (stopped) return;
      setState("offline");
      retry++;
      timer = setTimeout(connect, Math.min(60_000, 1000 * 2 ** Math.min(retry, 6)) + Math.random() * 1000);
    });
  }

  function send(obj) { if (ws?.readyState === 1) ws.send(JSON.stringify(obj)); }
  function sendBin(kind, id, payload) { if (ws?.readyState === 1) ws.send(frame(kind, id, payload)); }

  function trustedHeaders(m) {
    return {
      ...strip(m.headers),
      host: `127.0.0.1:${localPort()}`,
      "x-mc-relay": auth.relaySecret, "x-mc-user": String(m.user || ""), "x-mc-session": String(m.session || ""),
      "x-mc-device-name": String(m.device || "").slice(0, 80), "x-mc-base": String(m.base || ""),
    };
  }

  function onControl(m) {
    if (m.t === "req") return startRequest(m);
    if (m.t === "end") { const s = streams.get(m.id); s?.req?.end(); return; }
    if (m.t === "cancel") { const s = streams.get(m.id); s?.req?.destroy(); s?.res?.destroy(); s?.ws?.close(); streams.delete(m.id); return; }
    if (m.t === "ws") return startSocket(m);
    if (m.t === "ws-close") { const s = streams.get(m.id); try { s?.ws?.close(m.code && m.code >= 1000 && m.code < 5000 && m.code !== 1005 && m.code !== 1006 ? m.code : 1000); } catch {} streams.delete(m.id); return; }
    if (m.t === "unlinked") { stopped = true; setState("unlinked"); ws?.close(); }
  }

  function onBinary(buf) {
    const { kind, id, payload } = unframe(buf);
    const s = streams.get(id);
    if (!s) return;
    if (kind === FRAME.BODY) s.req?.write(payload);
    else if (s.ws?.readyState === 1) s.ws.send(kind === FRAME.WS_TEXT ? payload.toString("utf8") : payload, { binary: kind === FRAME.WS_BIN });
  }

  function startRequest(m) {
    if (!/^\/(api|vnc\.html|web|novnc|static)\b/.test(String(m.path || ""))) { send({ t: "res", id: m.id, status: 404, headers: { "content-type": "application/json" } }); sendBin(FRAME.BODY, m.id, Buffer.from('{"error":"Not found"}')); send({ t: "end", id: m.id }); return; }
    const req = http.request({ host: "127.0.0.1", port: localPort(), method: m.method, path: m.path, headers: trustedHeaders(m) }, (res) => {
      const s = streams.get(m.id); if (s) s.res = res;
      send({ t: "res", id: m.id, status: res.statusCode, headers: strip(res.headers) });
      res.on("data", (c) => {
        sendBin(FRAME.BODY, m.id, c);
        if (ws && ws.bufferedAmount > HIGH_WATER) { res.pause(); const t = setInterval(() => { if (!ws || ws.readyState !== 1 || ws.bufferedAmount < HIGH_WATER / 4) { clearInterval(t); res.resume(); } }, 30); }
      });
      res.on("end", () => { send({ t: "end", id: m.id }); streams.delete(m.id); });
      res.on("error", () => { send({ t: "err", id: m.id, message: "local response failed" }); streams.delete(m.id); });
    });
    req.on("error", (e) => { send({ t: "err", id: m.id, message: e.message }); streams.delete(m.id); });
    streams.set(m.id, { req });
    if (m.bodyless) req.end();
  }

  function startSocket(m) {
    const local = new WebSocket(`ws://127.0.0.1:${localPort()}${m.path}`, m.protocols?.length ? m.protocols : undefined, { headers: trustedHeaders(m) });
    streams.set(m.id, { ws: local });
    local.on("open", () => send({ t: "ws-ok", id: m.id, protocol: local.protocol || null }));
    local.on("message", (d, isBinary) => sendBin(isBinary ? FRAME.WS_BIN : FRAME.WS_TEXT, m.id, Buffer.isBuffer(d) ? d : Buffer.from(d)));
    local.on("unexpected-response", (_q, res) => { send({ t: "ws-fail", id: m.id, status: res.statusCode }); streams.delete(m.id); });
    local.on("close", (code) => { if (streams.has(m.id)) send({ t: "ws-close", id: m.id, code }); streams.delete(m.id); });
    local.on("error", () => {});
  }

  // Push notifications for the owner's devices go through the service,
  // which holds the APNs key; nothing on this machine needs one.
  function push(message) {
    if (ws?.readyState !== 1) return Promise.resolve({ status: 503, reason: "relay offline" });
    send({ t: "push", message });
    return Promise.resolve({ status: 200 });
  }

  function start() { stopped = false; connect(); }
  function stop() { stopped = true; clearTimeout(timer); try { ws?.close(); } catch {} setState("off"); }
  return { start, stop, push, get state() { return state; }, hostname: os.hostname() };
}
