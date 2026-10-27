// web_cdp.mjs — drive one page in headless Chrome for the `harness web` tests (#227).
// usage: node web_cdp.mjs <browser> <url>
// Launches <browser> headless on a free debugging port, opens <url> and waits for it to load, then
// prints {"ok":true}. After that it reads one JSON request per stdin line and answers one per stdout
// line: {"op":"eval","expr":E} → {"ok":true,"value":V}; {"op":"wait","expr":E,"timeout":S} polls E
// until it is truthy; {"op":"key","key":K,"shift":B} presses a real key (Enter, Escape, Tab);
// {"op":"viewport","width":W,"height":H} resizes the page; {"op":"scheme","dark":B} emulates
// prefers-color-scheme; {"op":"shot","path":P,"full":B} writes a PNG of the page to P —
// full height unless B is false (the viewport only, for a fixed drawer) (#231's
// critique rounds). Any failure is {"ok":false,"error":…}.
// stdin closing closes the browser.
// A test tool only (no npm package: Node >= 22's own WebSocket), never shipped to the page.
import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { writeFileSync } from "node:fs";

const [browser, url] = process.argv.slice(2);
const out = (o) => process.stdout.write(JSON.stringify(o) + "\n");
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const proc = spawn(browser, ["--headless=new", "--remote-debugging-port=0", "--no-first-run",
  "--no-default-browser-check", "--disable-gpu", "--no-sandbox", "--hide-scrollbars", "about:blank"],
  { stdio: ["ignore", "ignore", "pipe"] });
let stopping = false;
function stop(code) {
  if (stopping) return;
  stopping = true;
  try { proc.kill("SIGTERM"); } catch (e) { /* already gone */ }
  setTimeout(() => { try { proc.kill("SIGKILL"); } catch (e) { /* gone */ } process.exit(code); }, 3000).unref();
  proc.once("exit", () => process.exit(code));
}

function wsUrl() {
  return new Promise((resolve, reject) => {
    let buf = "";
    const timer = setTimeout(() => reject(new Error("no DevTools URL in 20s: " + buf.slice(-400))), 20000);
    proc.stderr.on("data", (d) => {
      buf += d;
      const m = buf.match(/DevTools listening on (ws:\/\/\S+)/);
      if (m) { clearTimeout(timer); resolve(m[1]); }
    });
    proc.once("exit", (c) => reject(new Error("browser exited " + c + ": " + buf.slice(-400))));
  });
}

let ws, nextId = 0, session;
const pending = new Map();
function send(method, params = {}, sessionId) {
  const id = ++nextId;
  ws.send(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }));
  return new Promise((resolve, reject) => pending.set(id, { resolve, reject }));
}

async function evaluate(expr) {
  const r = await send("Runtime.evaluate", { expression: expr, returnByValue: true, awaitPromise: true }, session);
  if (r.exceptionDetails) {
    throw new Error((r.exceptionDetails.exception && r.exceptionDetails.exception.description) || r.exceptionDetails.text);
  }
  return r.result.value;
}

async function waitFor(expr, secs) {
  const deadline = Date.now() + secs * 1000;
  let last;
  for (;;) {
    try { last = await evaluate(expr); if (last) return last; } catch (e) { last = String(e.message); }
    if (Date.now() > deadline) throw new Error(`not true within ${secs}s (last: ${JSON.stringify(last)})`);
    await sleep(100);
  }
}

const KEYS = { Enter: [13, "\r"], Escape: [27, ""], Tab: [9, ""] };
async function press(key, shift) {
  const [code, text] = KEYS[key] || (() => { throw new Error("unknown key " + key); })();
  const base = { key, code: key, windowsVirtualKeyCode: code, nativeVirtualKeyCode: code, modifiers: shift ? 8 : 0 };
  await send("Input.dispatchKeyEvent", { type: text ? "keyDown" : "rawKeyDown", text, ...base }, session);
  await send("Input.dispatchKeyEvent", { type: "keyUp", ...base }, session);
  return true;
}

async function viewport(width, height) {
  await send("Emulation.setDeviceMetricsOverride", { width, height, deviceScaleFactor: 1, mobile: false }, session);
  return true;
}

async function scheme(dark) {
  await send("Emulation.setEmulatedMedia", { features: [{ name: "prefers-color-scheme", value: dark ? "dark" : "light" }] }, session);
  await sleep(400);   // past every colour transition (--duration-slow is 260ms), so reads see the new theme
  return true;
}

async function shot(path, full) {
  const params = { format: "png" };
  if (full) {
    const { cssContentSize: c } = await send("Page.getLayoutMetrics", {}, session);
    Object.assign(params, { captureBeyondViewport: true, clip: { x: 0, y: 0, width: c.width, height: c.height, scale: 1 } });
  }
  const { data } = await send("Page.captureScreenshot", params, session);
  writeFileSync(path, Buffer.from(data, "base64"));
  return true;
}

async function main() {
  ws = new WebSocket(await wsUrl());
  await new Promise((resolve, reject) => { ws.onopen = resolve; ws.onerror = () => reject(new Error("ws error")); });
  ws.onmessage = (m) => {
    const msg = JSON.parse(m.data);
    const p = msg.id && pending.get(msg.id);
    if (!p) return;
    pending.delete(msg.id);
    if (msg.error) p.reject(new Error(msg.error.message)); else p.resolve(msg.result);
  };
  const { targetId } = await send("Target.createTarget", { url });
  ({ sessionId: session } = await send("Target.attachToTarget", { targetId, flatten: true }));
  await waitFor("location.href !== 'about:blank' && document.readyState === 'complete'", 20);
  out({ ok: true });
  const rl = createInterface({ input: process.stdin });
  for await (const line of rl) {
    if (!line.trim()) continue;
    try {
      const req = JSON.parse(line);
      const value = req.op === "wait" ? await waitFor(req.expr, req.timeout || 5)
        : req.op === "key" ? await press(req.key, req.shift)
        : req.op === "viewport" ? await viewport(req.width, req.height || 800)
        : req.op === "scheme" ? await scheme(req.dark)
        : req.op === "shot" ? await shot(req.path, req.full !== false)
        : await evaluate(req.expr);
      out({ ok: true, value });
    } catch (e) {
      out({ ok: false, error: String(e.message || e) });
    }
  }
  try { await Promise.race([send("Browser.close"), sleep(2000)]); } catch (e) { /* closing anyway */ }
  stop(0);
}

main().catch((e) => { out({ ok: false, error: String(e.message || e) }); stop(1); });
