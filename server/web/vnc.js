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
// ⌘ on the iPad keyboard becomes Ctrl on the (Linux) remote, so ⌘C/⌘V/⌘Z
// do what they look like. The native app also catches these first; this is
// the fallback when a key reaches the page directly.
let cmdAsCtrl = params.get("cmd") !== "super";
let zoom = 0;
// The viewport is in remote pixels, so at 2× it covers half the window's
// width of the remote screen; drag pans it.
function clipForZoom() {
  const size = rfb._screenSize();
  rfb._display.clipViewport = true;
  rfb._display.scale = zoom;
  rfb._display.viewportChangeSize(Math.ceil(size.w / zoom), Math.ceil(size.h / zoom));
  rfb._fixScrollbars?.();
  rfb._setClippingViewport?.(true);
}
function applyZoom() {
  if (!rfb) return;
  try {
    if (zoom > 0) { rfb._scaleViewport = false; rfb._clipViewport = true; rfb.dragViewport = true; clipForZoom(); }
    else { rfb.dragViewport = false; rfb.clipViewport = !scale; rfb.scaleViewport = scale; }
  } catch (e) { /* another noVNC version: fit only */ }
}
const XK = { ctrl: 0xffe3, shift: 0xffe1, alt: 0xffe9, super: 0xffeb, v: 0x76 };

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
  // Zoom: 0 = fit the window; otherwise a fixed scale with one-finger
  // panning. noVNC resets the scale on resize, so keep ours applied.
  const autoscale = rfb._updateScale?.bind(rfb), autoclip = rfb._updateClip?.bind(rfb);
  if (autoscale && autoclip) {
    rfb._updateScale = () => { if (zoom > 0) { try { clipForZoom(); } catch {} } else autoscale(); };
    rfb._updateClip = () => { if (zoom > 0) { try { clipForZoom(); } catch {} } else autoclip(); };
  }
  rfb.addEventListener("connect", () => {
    applyZoom();
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

function combo(keysyms) {
  if (!rfb || mode !== "control") return;
  for (const k of keysyms) rfb.sendKey(k, null, true);
  for (const k of [...keysyms].reverse()) rfb.sendKey(k, null, false);
}

// Mouse helpers for touch: wheel steps and other buttons at the last pointer
// position (or the middle of the screen before the first touch).
function pointer() {
  const p = rfb?._mousePos;
  if (p && (p.x || p.y)) return p;
  return { x: Math.round((rfb?._fbWidth || 2) / 2), y: Math.round((rfb?._fbHeight || 2) / 2) };
}
function buttons(mask) {
  if (!rfb || mode !== "control") return;
  const { x, y } = pointer();
  rfb._handleMouseButton(x, y, mask);
  rfb._handleMouseButton(x, y, 0);
}

window.addEventListener("keydown", (e) => {
  if (!cmdAsCtrl || mode !== "control" || !rfb || !e.metaKey || e.ctrlKey) return;
  const k = (e.key || "").toLowerCase();
  if (k.length !== 1) return;
  e.preventDefault(); e.stopImmediatePropagation();
  const mods = [XK.ctrl]; if (e.shiftKey) mods.push(XK.shift); if (e.altKey) mods.push(XK.alt);
  combo([...mods, k.codePointAt(0)]);
}, true);

// Keyboard focus: the app shows where typing goes.
document.addEventListener("focusin", () => post("focus", { focused: true }));
document.addEventListener("focusout", () => post("focus", { focused: false }));
// Back from the background (or a reparented view): reconnect promptly.
document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "visible" && wanted && !rfb) { retry = 0; connect(); }
});

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
  combo(keysyms) { combo(keysyms.map(Number)); },
  // iPad clipboard → remote clipboard, then the remote's paste shortcut.
  pasteAndSend(text, shift) {
    if (!rfb || mode !== "control") return;
    rfb.clipboardPasteFrom(String(text));
    setTimeout(() => combo(shift ? [XK.ctrl, XK.shift, XK.v] : [XK.ctrl, XK.v]), 60);
  },
  scroll(steps) { const n = Math.max(-20, Math.min(20, Math.round(steps))); for (let i = 0; i < Math.abs(n); i++) buttons(n < 0 ? 1 << 3 : 1 << 4); },
  click(button) { buttons(button === "right" ? 4 : button === "middle" ? 2 : 1); },
  setQuality(q) { if (rfb) { rfb.qualityLevel = Math.max(0, Math.min(9, q)); } },
  setCmdAsCtrl(v) { cmdAsCtrl = Boolean(v); },
  zoom(z) { zoom = Math.max(0, Math.min(4, Number(z) || 0)); applyZoom(); },
  focus() { rfb?.focus(); },
  blur() { rfb?.blur(); },
  state() { return { connected: Boolean(rfb), mode, display, width: rfb?._fbWidth || null, height: rfb?._fbHeight || null }; },
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
