// Remote desktop page hosted inside Musa Control's WKWebView. The native app
// drives it through window.mc.* and receives state through the "mc" message
// handler. Bytes travel over an authenticated WebSocket to the gateway's
// bridge; this page never sees a VNC port.
import RFB from "../novnc/core/rfb.js"; // resolved against /control/web/ → /control/novnc/

const params = new URLSearchParams(location.search);
const display = params.get("display") || "99";
let mode = params.get("mode") === "control" ? "control" : "observe";
const screen = document.getElementById("screen");
const msg = document.getElementById("msg");
const post = (type, data = {}) => { try { window.webkit?.messageHandlers?.mc?.postMessage({ type, ...data }); } catch {} };

let rfb = null, ws = null, bytes = 0, lastBytes = 0, retry = 0, retryTimer = null, wanted = true;
let scale = params.get("scale") !== "native";

function wsUrl() {
  const base = location.pathname.replace(/\/vnc\.html$/, "");
  return `${location.protocol === "https:" ? "wss" : "ws"}://${location.host}${base}/api/vnc/${display}/ws?mode=${mode}`;
}

function connect() {
  clearTimeout(retryTimer);
  msg.textContent = retry ? `Reconnecting (attempt ${retry})…` : "Connecting…";
  msg.style.display = "block";
  ws = new WebSocket(wsUrl(), ["binary"]);
  ws.binaryType = "arraybuffer";
  ws.addEventListener("message", (e) => { bytes += e.data.byteLength || 0; });
  rfb = new RFB(screen, ws, { shared: true });
  rfb.viewOnly = mode !== "control";
  rfb.scaleViewport = scale;
  rfb.clipViewport = !scale;
  rfb.resizeSession = false;
  rfb.qualityLevel = 6;
  rfb.compressionLevel = 2;
  rfb.focusOnClick = mode === "control";
  rfb.addEventListener("connect", () => {
    retry = 0; msg.style.display = "none";
    post("connected", { display, mode, width: rfb._fbWidth, height: rfb._fbHeight, name: rfb._fbName });
  });
  rfb.addEventListener("disconnect", (e) => {
    post("disconnected", { clean: e.detail.clean });
    rfb = null;
    if (!wanted) return;
    retry++;
    const delay = Math.min(15000, 600 * 2 ** Math.min(retry, 5));
    msg.textContent = `Connection lost. Retrying in ${Math.round(delay / 1000)} s…`;
    msg.style.display = "block";
    retryTimer = setTimeout(connect, delay);
  });
  rfb.addEventListener("desktopname", (e) => post("name", { name: e.detail.name }));
  rfb.addEventListener("clipboard", (e) => post("clipboard", { text: e.detail.text }));
}

// Round-trip time to the gateway, plus received throughput.
async function measure() {
  const t0 = performance.now();
  try { await fetch(location.pathname.replace(/\/vnc\.html$/, "") + "/api/ping", { cache: "no-store" }); } catch { return; }
  const rtt = Math.round(performance.now() - t0);
  const kbps = Math.round(((bytes - lastBytes) * 8) / 1000 / 3);
  lastBytes = bytes;
  post("stats", { rtt, kbps, connected: Boolean(rfb) });
}
setInterval(measure, 3000);

window.mc = {
  setMode(m) { if (m === mode) return; mode = m; wanted = true; if (rfb) { rfb.disconnect(); } else connect(); },
  setScale(s) { scale = s; if (rfb) { rfb.scaleViewport = s; rfb.clipViewport = !s; } },
  reconnect() { wanted = true; retry = 0; if (rfb) rfb.disconnect(); else connect(); },
  disconnect() { wanted = false; rfb?.disconnect(); },
  paste(text) { if (rfb && mode === "control") rfb.clipboardPasteFrom(String(text)); },
  key(keysym, code) { if (rfb && mode === "control") rfb.sendKey(keysym, code); },
  ctrlAltDel() { if (rfb && mode === "control") rfb.sendCtrlAltDel(); },
  // Typed text from the native keyboard bar, one keysym per character.
  type(text) {
    if (!rfb || mode !== "control") return;
    for (const ch of String(text)) {
      const cp = ch.codePointAt(0);
      const keysym = ch === "\n" ? 0xff0d : cp < 0x100 ? cp : 0x01000000 + cp;
      rfb.sendKey(keysym, null);
    }
  },
};
connect();
