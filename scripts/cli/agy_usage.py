#!/usr/bin/env python3
"""agy_usage.py <conversation.db>… — per-model token totals of Antigravity (agy) conversations (#188).

agy keeps no token counts a reader can name: each model call is one `gen_metadata` row of
~/.gemini/antigravity-cli/conversations/<id>.db, a protobuf with no .proto shipped. The fields, read
off a real capture and checked against agy's own `-p --output-format json` totals
(test/fixtures/cli/agy/README.md):

    1.4  ModelUsageStats: 2 input, 3 output, 4 cache write, 5 cache read, 9 thinking
    1.19 the model id

Prints `<model>\\t<input>\\t<output>\\t<cache_read>\\t<cache_write>` per model, thinking folded into
output (Claude Code's output_tokens include its thinking too). An unreadable file is skipped.
"""
import sqlite3, sys


def _varint(b, i):
    v = sh = 0
    while True:
        x = b[i]
        i += 1
        v |= (x & 0x7F) << sh
        sh += 7
        if x < 0x80:
            return v, i


def fields(b):
    """{field number: [values]} of one protobuf message; length-delimited values stay bytes."""
    out, i = {}, 0
    while i < len(b):
        key, i = _varint(b, i)
        f, wt = key >> 3, key & 7
        if wt == 0:
            v, i = _varint(b, i)
        elif wt == 2:
            n, i = _varint(b, i)
            v, i = b[i:i + n], i + n
        elif wt == 1:
            v, i = b[i:i + 8], i + 8
        elif wt == 5:
            v, i = b[i:i + 4], i + 4
        else:
            raise ValueError(f"wire type {wt}")
        out.setdefault(f, []).append(v)
    return out


def row_usage(data):
    """(model, input, output, cache_read, cache_write) of one gen_metadata row, or None."""
    top = fields(data)
    if not top.get(1):
        return None
    meta = fields(top[1][0])
    model = meta.get(19, [b""])[0].decode("utf-8", "replace") or "unknown"
    if not meta.get(4):
        return None
    u = fields(meta[4][0])
    n = lambda f: u.get(f, [0])[0] if isinstance(u.get(f, [0])[0], int) else 0
    return model, n(2), n(3) + n(9), n(5), n(4)


def main(paths):
    acc = {}
    for p in paths:
        try:
            con = sqlite3.connect(f"file:{p}?mode=ro", uri=True)
            rows = con.execute("SELECT data FROM gen_metadata ORDER BY idx").fetchall()
            con.close()
        except sqlite3.Error:
            continue
        for (data,) in rows:
            try:
                r = row_usage(bytes(data or b""))
            except (ValueError, IndexError):
                continue
            if r:
                t = acc.setdefault(r[0], [0, 0, 0, 0])
                for k in range(4):
                    t[k] += r[k + 1]
    for model in sorted(acc):
        print("\t".join([model] + [str(x) for x in acc[model]]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
