"""harness-opus arm — the matched arm of PRD #345 (#590): Harness with every role on Opus at plain's effort.

The headline `harness` arm keeps Harness's out-of-the-box defaults (Opus manages, Sonnet implements, effort
high), which differ from the plain arm's model and effort. This arm sets both to the plain arm's, so model and
effort are matched together: the front door and every manager and implementer lane run on `opus` at effort
`medium` (the effort plain ran at in run-20261106). One worker, the same isolated Claude config, the same brief.
Optional, never blocking: `bench/run.py harness-opus --optional` records `skipped: <cause>` when the guard
refuses. Same options as bench/arms/harness.py; `--arm-opt model=…` / `effort=…` override the matched values."""
import importlib.util, os

_spec = importlib.util.spec_from_file_location(
    "bench_arm_harness_base", os.path.join(os.path.dirname(os.path.abspath(__file__)), "harness.py"))
_base = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_base)

MODEL, EFFORT = "opus", "medium"


def run(ctx):
    ctx.opts.setdefault("model", MODEL)
    ctx.opts.setdefault("effort", EFFORT)
    return _base.run(ctx)
