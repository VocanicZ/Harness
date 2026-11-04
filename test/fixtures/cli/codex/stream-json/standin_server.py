#!/usr/bin/env python3
"""standin_server.py — a local stand-in for the Responses endpoint `codex exec` talks to, so the REAL codex
binary can be run (and its `--json` stdout captured) with no account and no quota: README.md says which
fixtures came from it. `python3 standin_server.py <port> [normal|5xx]` listens on 127.0.0.1:<port>.

normal  every request streams one assistant message — PONG for the first request, DONE for later ones — and
        a `response.completed` whose usage grows with the request count, with the x-codex-* rate-limit
        headers (primary 5h window 7% used, secondary 7d window 51%) that codex writes into the rollout's
        token_count `rate_limits`;
5xx     every request answers 503, so codex retries (`Reconnecting... n/5`) and gives up.

Point codex at it with a throwaway CODEX_HOME and:
  codex exec --json -m <model> -c model_provider=standin \
    -c 'model_providers.standin={name="standin",base_url="http://127.0.0.1:<port>/v1",wire_api="responses",env_key="STANDIN_KEY"}' -
(STANDIN_KEY set to anything)."""
import http.server, json, sys

PORT = int(sys.argv[1])
MODE = sys.argv[2] if len(sys.argv) > 2 else "normal"
count = [0]


def sse(events):
    return "".join(f"event: {e['type']}\ndata: {json.dumps(e)}\n\n" for e in events).encode()


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_POST(self):
        self.rfile.read(int(self.headers.get("content-length", 0)))
        count[0] += 1
        n = count[0]
        if MODE == "5xx":
            self.send_response(503)
            self.send_header("content-type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"error":{"message":"overloaded","type":"server_error"}}')
            return
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        for k, v in (("primary-used-percent", "7"), ("primary-window-minutes", "300"), ("primary-reset-at", "1893456000"),
                     ("secondary-used-percent", "51"), ("secondary-window-minutes", "10080"), ("secondary-reset-at", "1893888000")):
            self.send_header(f"x-codex-{k}", v)
        self.end_headers()
        base = {"id": f"resp_{n}", "object": "response", "status": "in_progress", "output": []}
        item = {"type": "message", "id": "msg_1", "role": "assistant",
                "content": [{"type": "output_text", "text": "PONG" if n == 1 else "DONE"}]}
        usage = {"input_tokens": 120 + n, "input_tokens_details": {"cached_tokens": 50}, "output_tokens": 9,
                 "output_tokens_details": {"reasoning_tokens": 0}, "total_tokens": 129 + n}
        self.wfile.write(sse([{"type": "response.created", "response": base},
                              {"type": "response.output_item.done", "item": item},
                              {"type": "response.completed", "response": {**base, "status": "completed", "output": [item], "usage": usage}}]))
        self.wfile.flush()


if __name__ == "__main__":
    http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
