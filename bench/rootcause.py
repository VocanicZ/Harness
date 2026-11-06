#!/usr/bin/env python3
"""rootcause.py — group fuzz divergences into root-cause classes (PRD #345, #620). Stdlib only.

A fuzz run counts every case where the arm and the reference disagree. Raw counts mislead: one bug (a lone CR in
the ledger) can make a hundred cases diverge and swamp a different bug that diverges once. A *class* is one
distinct pair (input feature, observed difference); the class count is the number of distinct root causes the fuzz
found, and the class counts are what a fleet change is judged on (bench/README.md, "Ship rule").

    classify(items) -> {"classes": N, "class_counts": {"<feature> x <difference>": raw divergences, ...}}

`items` has one entry per divergent case: (features, difference). `features` is the set of input features the
case has (the fuzz module of each fixture names them: only quirks of the input, never the generic shape that every
case shares); `difference` is what differed (`diff_kind`). A case with no feature at all is labelled
`unmarked`; the fuzz modules give such a case its command as a feature, so ordinary inputs that diverge still land
in one class per command.

The grouping is a greedy set cover: the (feature, difference) pair that explains the most still-unexplained
divergences becomes a class and takes them, then the next, until every divergence is explained. A feature that merely
co-occurs with the real cause (a byte order mark that happens to sit in half of the lone-CR cases) explains fewer than
the cause itself, so the cause wins and the bystander does not open a second class. Ties break on how rare the feature
is among all the cases run (the rarer is likelier the cause), then on the label, so the result is the same on every run.
"""

CHANNELS = ("exit", "status", "stdout", "stderr", "file", "type", "allow", "error", "body", "json", "keys")
UNMARKED = "unmarked"


def diff_kind(ref, arm):
    """Which observable differed first (in the order of CHANNELS: exit status, HTTP status, standard output,
    standard error, a file, then the parts of an HTTP answer); "missing" when one side has nothing to compare. `ref` and `arm` are the two canonical results (dicts)."""
    if ref is None or arm is None:
        return "missing"
    names = {"stderr_empty": "stderr"}
    differing = {names.get(k, k) for k in set(ref) | set(arm) if ref.get(k) != arm.get(k)}
    for ch in CHANNELS:
        if ch in differing:
            return ch
    return sorted(differing)[0] if differing else "none"


def label(feature, difference):
    return "%s x %s" % (feature, difference)


def classify(items, population=None):
    """The classes of `items` [(features, difference)] as {"classes": N, "class_counts": {label: raw count}}.
    `population` {feature: cases that have it, over every case run} breaks ties: of two features that explain as many
    divergences, the rarer one is the more likely cause (a lone CR, not the comment lines half the ledgers have)."""
    population = population or {}
    left = [(frozenset(f) or frozenset([UNMARKED]), d) for f, d in items]
    counts = {}
    while left:
        tally = {}
        for feats, diff in left:
            for f in feats:
                tally[(f, diff)] = tally.get((f, diff), 0) + 1
        best = min(tally, key=lambda k: (-tally[k], population.get(k[0], 0), label(*k)))
        taken = [x for x in left if best[0] in x[0] and x[1] == best[1]]
        counts[label(*best)] = len(taken)
        left = [x for x in left if not (best[0] in x[0] and x[1] == best[1])]
    ordered = dict(sorted(counts.items(), key=lambda kv: (-kv[1], kv[0])))
    return {"classes": len(ordered), "class_counts": ordered}
