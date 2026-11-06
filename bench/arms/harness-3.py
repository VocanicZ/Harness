"""harness-3 arm — the harness arm with a 3-worker pool (#383): the optional run of PRD #345.
Same options as bench/arms/harness.py; `workers` defaults to 3 here."""
import importlib.util, os

_spec = importlib.util.spec_from_file_location(
    "bench_arm_harness_base", os.path.join(os.path.dirname(os.path.abspath(__file__)), "harness.py"))
_base = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_base)


def run(ctx):
    ctx.opts.setdefault("workers", "3")
    return _base.run(ctx)
