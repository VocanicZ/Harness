// web_cdp.mjs — drive one page in headless Chrome for the `harness web` tests (#227).
// usage: node web_cdp.mjs <browser> <url>
// Launches <browser> headless on a free debugging port, opens <url> and waits for it to load, then
// prints {"ok":true}. After that it reads one JSON request per stdin line and answers one per stdout
// line: {"op":"eval","expr":E} → {"ok":true,"value":V}; {"op":"wait","expr":E,"timeout":S} polls E
// until it is truthy. Any failure is {"ok":false,"error":…}. stdin closing closes the browser.
// A test tool only (no npm package: Node >= 22's own WebSocket), never shipped to the page.
import { spawn } from "node:child_process";
import { createInterface } from "node:readline";

const [browser, url] = process.argv.slice(2);
const out = (o) => process.stdout.write(JSON.stringify(o) + "\n");
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const proc = spawn(browser, ["--headless=new", "--remote-debugging-port=0", "--no-first-run",
  "--no-default-browser-check", "--disable-gpu", "--no-sandbox", "about:blank"],
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
  const r = await send("Runtime.evaluate", { expression: expr, returnByValue: true }, session);
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
      const value = req.op === "wait" ? await waitFor(req.expr, req.timeout || 5) : await evaluate(req.expr);
      out({ ok: true, value });
    } catch (e) {
      out({ ok: false, error: String(e.message || e) });
    }
  }
  try { await Promise.race([send("Browser.close"), sleep(2000)]); } catch (e) { /* closing anyway */ }
  stop(0);
}

main().catch((e) => { out({ ok: false, error: String(e.message || e) }); stop(1); });
