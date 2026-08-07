# Gauntlet review — blind A/B against a named reference

**Status:** approved (design) — 2026-08-08
**Branch:** `feat/gauntlet-review` (off `origin/main` @ `581466b` / #120)

## Problem

REVIEW grades the build against the PRD's own `## Acceptance criteria`
(`prompts/review.md:1`). That bar is self-referential: the same fleet wrote the
PRD, decomposed it, and implemented it — so "review passed" means *"it meets the
spec we wrote for ourselves"*, never *"it is any good"*. Nothing in the pipeline
compares the artifact to anything outside the repo, so a fleet can drive a PRD to
COMPLETE with every criterion green and still ship something visibly worse than
the thing it is supposed to replace.

The **Gauntlet Loop** (Matt Shumer; `robonuggets/gauntlet-loop`) targets exactly
that gap: a builder plus a **fresh-context critic**, a **blind A/B** against a
**named, fetchable, comparable** real-world reference, a **binary** verdict, and
a loop that repeats until the artifact wins.

Harness already has the loop skeleton. `prompts/review.md` step 3b files
`{{LABEL_READY}}` gap issues on failure, the pool implements them, and REVIEW
re-dispatches once they close — that *is* build → critic → rebuild. Three pieces
are missing:

1. an **external** bar (today: our own acceptance criteria),
2. a **blind** comparison (today: the reviewer knows which artifact is ours),
3. a **binary** verdict (today: a criterion checklist).

## Non-goal: a new pipeline stage

The obvious reading of the upstream pattern — a `GAUNTLET` dispatch action that
decomposes the goal into parts and spawns builder/critic pairs per part — is
rejected. `DECOMPOSE` already splits a PRD into independently-implementable
issues and `IMPL` already runs them in parallel lanes; a gauntlet stage would
duplicate both and add a state to `scripts/issuelib.py`. This design changes
**prompts plus one helper**, and reuses the existing REVIEW → refile → IMPL →
REVIEW edge as the loop.

## Design

Five pieces.

### 1. The bar lives in the PRD issue (`prompts/prd.md`)

The PRD stage emits one extra section when — and only when — an honest reference
exists:

```markdown
## Quality bar
Beat: <one named artifact + URL — a specific thing, not a category>
Judged on:
- <dimension — decidable by running something>
- <dimension>
```

Validation rules the PRD prompt must enforce, straight from upstream:

- **Named** — a specific artifact, not a category. `ripgrep` (with URL), not
  "fast grep tools".
- **Fetchable** — the critic can clone, install, run, open, or screenshot it.
- **Comparable** — ours and it can sit side by side and a judge can pick one.
- Each `Judged on` dimension must be **decidable by running a task**, not by
  opinion. 2–4 of them.

If no reference passes all four, the PRD **omits the section entirely**. Omission
is the off switch: a PRD without a `## Quality bar` reviews exactly as it does
today. This is why the bar lives in the PRD and not in `.harness/config` — it is
per-PRD, it survives `/harness-prd` scope injection, and like every other piece
of Harness state it lives in GitHub, so a resume on another host reads the same
bar.

### 2. Round state lives in PRD comments, counted by the engine (`scripts/lib.sh`)

```sh
# gauntlet_round <prd> — echo the round this review pass will run (1-based).
# State is the PRD's own comment stream: every losing round leaves a
# `<!-- harness-gauntlet round=N -->` marker. Nothing on disk → any host resumes
# mid-gauntlet and picks up at the right round.
gauntlet_round(){ local prd="$1" n
  n="$(gh issue view "$prd" -R "$SLUG" --json comments \
       -q '[.comments[].body | select(test("<!-- harness-gauntlet round="))] | length' \
       2>/dev/null || echo 0)"
  echo $(( n + 1 )); }
```

Counting markers rather than parsing the highest `N` keeps it monotonic under a
duplicated comment and needs no ordering assumption.

The **engine** calls this, not the agent. A reviewer session is a Claude process
in a checkout — it cannot call a `lib.sh` function, and asking it to count its
own comments in-prompt makes the cap a thing the agent can miscount its way past.
`spawn_orch` computes the round once, before launch, and templates it in. One
dispatch = one round, so the value is stable for the whole session (including
every Ralph iteration inside it).

### 3. Three render vars (`scripts/drive.sh:145`)

`spawn_orch`'s `render` call gains:

```sh
GAUNTLET_DIR="$STATE_DIR/gauntlet/$UNIT" \
GAUNTLET_ROUNDS="$HARNESS_GAUNTLET_ROUNDS" \
GAUNTLET_ROUND="$([[ $action == REVIEW ]] && gauntlet_round "$payload" || echo '')"
```

`GAUNTLET_ROUND` is computed for `REVIEW` only — the other three orchestration
actions (`PLAN`, `PRD`, `DECOMPOSE`) carry no PRD payload and render it empty.

`GAUNTLET_DIR` sits under `STATE_DIR`, **outside** the review `CHECKOUT`. A
review session runs in a real clone of the target repo; writing A/B transcripts,
screenshots, and a fetched reference tree inside it would dirty the working tree
and risk a `git add -A` sweeping megabytes of reference build output into a
commit.

### 4. `prompts/review.md` becomes two-phase

Phase 1 is today's review, unchanged. Phase 2 runs only after it passes.

```
1. criteria gate — today's steps 1–2 and 3b. Any acceptance criterion unmet:
   file gap issues, comment, exit. The gauntlet NEVER runs on an incomplete
   build — A/B-ing a half-built artifact against a finished product wastes a
   full round to learn what the criteria already said.
2. PRD has no `## Quality bar` -> today's step 3a (sign off, close). done.
3. this pass is round {{GAUNTLET_ROUND}} of {{GAUNTLET_ROUNDS}} (the engine
   counted it). Round > rounds -> concede (§5).
4. provision the reference into {{GAUNTLET_DIR}}/ref/ (clone / install / launch).
   Unprovisionable — paywall, no public build, needs a credential the fleet
   does not have: comment on the PRD saying exactly what failed, then sign off
   on criteria alone. NEVER apply agent-blocked; an autonomous fleet must not
   park on a quality gate (README AUTONOMY).
5. derive a FIXED task list from the `Judged on` dimensions, run it against
   ours and against ref/, capture both:
       {{GAUNTLET_DIR}}/r{{GAUNTLET_ROUND}}/A/  transcript.txt screenshot.png timings.txt
       {{GAUNTLET_DIR}}/r{{GAUNTLET_ROUND}}/B/  (same shape)
       {{GAUNTLET_DIR}}/r{{GAUNTLET_ROUND}}/.mapping  -> "A=ours" or "A=ref"
   Side assignment is coin-flipped per round. `.mapping` is a SIBLING of A/
   and B/, never inside them.
6. spawn the critic sub-agent (fresh context). It receives exactly: the two
   absolute dir paths and the dimension list. It is instructed to read nothing
   outside those two dirs — not `.mapping`, not the repo, not git history — and
   to answer in exactly two lines:
       winner: A|B
       gap: <one sentence — the single largest meaningful difference>
   Binary only. No scores, no per-dimension table: numeric scoring drifts
   upward every round and the loop stops meaning anything.
7. reviewer reads `.mapping` AFTER the verdict lands, then:
   WIN  -> comment "round {{GAUNTLET_ROUND}}: won vs <bar>", add
           {{LABEL_REVIEWED}}, close PRD. No round marker — the gauntlet is over.
   LOSE -> create exactly ONE {{LABEL_READY}} issue for the critic's single
           largest gap (not a checklist — one gap per round is what makes this
           a loop and not a shotgun), then comment
             <!-- harness-gauntlet round={{GAUNTLET_ROUND}} -->
             round {{GAUNTLET_ROUND}}: lost vs <bar>. gap: <gap>. filed #<issue>.
           and do NOT add {{LABEL_REVIEWED}}.
   The marker is written on LOSE only, so the engine's count of markers is
   exactly the number of rounds already spent.
```

Step 7's LOSE branch is the existing 3b path with a different trigger, so the
pool picks the gap issue up, implements it, closes it, and REVIEW re-dispatches
at round N+1. No dispatch change is required for the loop to turn.

### 5. Cap and concede

`HARNESS_GAUNTLET_ROUNDS` (default `3`). At the cap the reviewer **concedes**:
comment the standing gap, apply `{{LABEL_REVIEWED}}`, close the PRD.

Upstream's stop condition is "the artifact wins, or the human stops it". Harness
runs unattended, and a bar can be honestly unbeatable (a decade-old product, a
team of fifty). Without a cap the fleet loops on one PRD until the token budget
dies, and — worse — the unit never reaches COMPLETE, so in `multi` topology
every dependent target stays blocked forever behind a cosmetic gate. Concede is
the only autonomous-safe exit.

### 6. Config

`scripts/lib.sh:56` gains `: "${HARNESS_GAUNTLET_ROUNDS:=3}"`, and the name joins
the export list at `scripts/lib.sh:67`. README gains one config row and a
`### Gauntlet review` section under the review docs.

## Properties

- **Off by default, byte-identical.** A PRD without `## Quality bar` produces the
  same review behaviour as today. Every existing fleet is unaffected until its
  next PRD names a bar.
- **Criteria first, always.** The gauntlet is a quality gate stacked on top of
  the correctness gate, never a substitute for it. A build that fails its
  criteria never reaches phase 2.
- **Bounded burn.** Rounds are capped, and each round costs one review session
  plus one implementation lane — the same unit cost as any other review failure.
- **Resumable.** Round state is PRD comments; `GAUNTLET_DIR` holds only the
  current round's evidence and is safe to lose (a resumed review re-runs the
  round it is on).
- **Clean tree.** No gauntlet artifact is ever written inside the checkout.
- **Blindness is prompt discipline, not a sandbox.** The reviewer wrote
  `.mapping`, so it knows the mapping; only the critic sub-agent is blind, via
  fresh context plus an explicit read boundary. A determined agent could peek.
  This is the same trust model as the rest of the engine and the README must say
  so plainly rather than imply a guarantee.

## Out of scope (flagged, not silently dropped)

- **Per-issue gauntlet.** Judging each impl issue's artifact before merge is
  strictly stronger, but every issue would need its own fetchable reference
  ("beat what, exactly?" is unanswerable for most refactor issues) and the cost
  scales with issue count. Revisit if PRD-level rounds prove too coarse to point
  at a real gap.
- **A `gauntlet-conceded` label.** The concede comment is greppable; a label
  earns its place when an operator actually wants conceded PRDs on the
  `harness status` dashboard.
- **The bug lane** (`priority-worker.sh`) is untouched — bug fixes have no PRD
  and no bar.
- **Builder/critic pairs per part.** `DECOMPOSE` + parallel `IMPL` already own
  the split; adding a second decomposition would fork the issue board.

## Testing (tests-first)

New `test/test_gauntlet.sh`, using the existing `make_env` + `gh`-stub pattern:

- `gauntlet_round` returns `1` on a PRD with no markers, `3` after two markers,
  and `1` when `gh` fails (offline → never skips straight to concede).
- A PRD body with **no** `## Quality bar` renders a review prompt whose gauntlet
  phase is inert, and the criteria-only sign-off path is unchanged.
- At `HARNESS_GAUNTLET_ROUNDS=2` with two markers present, the rendered prompt
  drives the concede branch (`{{LABEL_REVIEWED}}` applied, no new issue).
- `.mapping` is written as a sibling of `A/`/`B/`, never inside either.

Extend the existing suites:

- `test_prompt_labels.sh` — render `review.md` and `prd.md` with the new keys and
  assert no `{{...}}` survives into an executable `gh` line.
- `test_drive.sh` — `spawn_orch` passes `GAUNTLET_DIR` under `STATE_DIR`, not
  under `CHECKOUT`; `GAUNTLET_ROUND` is populated for `REVIEW` and empty for
  `PLAN`/`PRD`/`DECOMPOSE`.
- `test_readme_docs.sh` — `HARNESS_GAUNTLET_ROUNDS` is documented.

Full `test/run.sh` stays green.

## Rollout

PR, squash-merge (this repo forbids `--auto`), then `harness update` on each host
to ff-pull the shared `~/.harness/engine`. Live fleets keep the old prompts until
relaunch. No migration: existing PRDs have no `## Quality bar` and keep their
current review behaviour.

## References

- Matt Shumer, "the Gauntlet Loop" — <https://x.com/mattshumer_/status/2081830214384886228>
- `robonuggets/gauntlet-loop` — <https://github.com/robonuggets/gauntlet-loop>
- AI Loop Engineering & Gauntlet Loops (2026) —
  <https://www.thepromptindex.com/ai-loop-engineering-gauntlet-loop-guide.html>
