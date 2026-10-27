# Critique rounds — `harness web`

The same process as design-to-print's `docs/design/ROUNDS.md`. Each round: screenshot every view (the host overview `/`, the fleet DAG `/fleet/hz`, and the issue drawer open on #13) at 1440 px and 400 px, light and dark, then review them side by side with design-to-print's references (`docs/design/refs/`: Linear, Stripe docs, the shadcn dashboard and tasks blocks) and its own screens, the way a product designer at Stripe or Linear would: hierarchy, alignment, spacing rhythm, type, colour restraint, clutter, WCAG AA contrast, visible focus. What was weak, then what changed.

The capture is `python3 test/web_shots.py docs/web/screens/round-<n>`: the web test fixture (fleets `hz` and `dp`, board `o/arc`, a rate-limit hold, one live session) served and shot in headless Chrome; pages full height, the drawer at the viewport. It prints each page's `scrollWidth`, so a sideways scroll at 400 px shows up as a number, not only in a picture. `test/test_web_design.py` holds the bar every round must keep: all visible text at AA against what it is drawn on (4.5:1, 3:1 for large text), a focus ring on every control Tab reaches, no sideways scroll at 400 px, in both themes.

Calibration taken from the references before round 1: one container (a 1 px border, no shadow); 13 to 14 px body; 12 px muted keys; status as a small dot and a word, coloured only where it means something; one blue for links and focus; mono for paths, session names and labels only; Linear's issue view puts properties in a key/value column with the value aligned.

## Round 1: the dashboard as built (#223–#229)

Screens: [`screens/round-1/`](screens/round-1/) — `overview`, `fleet`, `drawer` × `1440`/`400` × `light`/`dark`.

What was weak:

1. Overview: the rate-limit callout sat flush on the fleet cards (0 px between them); on the fleet page the state legend sat flush on "Awaiting you". There was no vertical rhythm between page blocks.
2. Overview: the cards stretched to the tallest one, so `dp` was a card with 380 px of empty white under its content.
3. Overview: each card's project path was a right-floated `panel__meta` that wrapped under the title, indented to nowhere.
4. Overview: in a 389 px card the sessions table broke "impl" into "imp / l", "10m" into "10 / m" and the session name `hz-arc-i11` one character per line.
5. Overview: a supervisor action that wrapped started its second line under the time, not under the text.
6. Overview: nothing on `/` said what was waiting on a human. "Is anything stuck" was answered (needs attention), "what needs me" took a click into each fleet.
7. Fleet: the legend was six bordered mono pills, identical to the PRD state pills, so it read as a row of filters rather than a key.
8. Fleet: every DAG node had a full coloured border plus its bar: twelve coloured boxes per screen, the page's loudest element, for information the bar alone carries.
9. Fleet: node titles were mono, so the graph read as a log viewer.
10. Fleet: "in review" borrowed the accent's pale border (`#BFD3FE`, 1.5:1 on white): its node bar was nearly invisible.
11. Fleet: the DAGs had 50 px of empty margin above and below and 42 px between stacked nodes; #3's three children took 300 px.
12. Fleet: the PRD heading was bold end to end, children count and token stats included.
13. Fleet: "Awaiting you" tags were mono uppercase on grey, of three different widths, so the three titles started at three different x positions.
14. Drawer: opening it drew a 2 px blue ring round the whole panel (the dialog takes focus to hold it; it is not a control).
15. Drawer: "Blocked by · Parent" over "nothing" / "Parent #3", and "PR · CI" over "PR #60" / "CI success", put two keys in one label and then repeated one of them in the value.

What changed:

1. One rhythm on every page: each block 16 px under the last, the header 24 px (`.page > * + *`).
2. `.fleets` is `auto-fit` with `align-items: start`: cards keep their own height, and two fleets share the row at 592 px each.
3. The path is a full-width quiet line under the name (`.fleet__root`), truncated with its full value in `title`.
4. The table's short columns never wrap; cell padding is 8 px inside a card.
5. Each action is a two-column grid, time and text, so a wrapped line hangs under the text.
6. Each card counts its fleet's open "Awaiting you" items and links to that panel (`/fleet/hz#awaiting-title`): "3 awaiting you". (`web_data.fleet_health` counts them from the boards it already reads.)
7. The legend is a dot-bar and a word, 12 px muted, placed after "Awaiting you", directly above the graphs it explains.
8. Nodes are neutral cards (1 px `--color-border-strong`); the state is the 4 px left bar only. Hover fills the card, focus rings it.
9. Node titles are sans 13 px medium, the number in the secondary colour.
10. In review has its own hue: `--color-violet-solid` `#7C3AED` (dark `#8B5CF6`), text `#6D28D9` / `#C4B5FD`.
11. Rows are 66 px (boxes 50 px, 16 px apart) with a 6 px margin; the graph starts where its panel starts.
12. The counts and stats are regular weight.
13. The tags are 11 px sans caps (design-to-print's tag style) in a 112 px column; titles line up, and "needs first #4" sits under its title.
14. The dialog container has no ring; every control inside keeps its own.
15. "Dependencies" with rows *Blocked by* and *Parent*; "Pull request" with rows *PR* and *CI*: a key column of 80 px, values aligned, as Linear's properties.

## Round 2: after the round 1 fixes

Screens: [`screens/round-2/`](screens/round-2/).

What was weak:

1. "held until in 30m" in the callout and on every card read as a typo.
2. The GitHub budget and its hold were repeated on every card although the token is host-wide (the callout already said so): with two fleets, the same two lines twice.
3. At 400 px the sessions table still broke `hz-arc-i11` across three lines, now because five columns cannot fit a 336 px card.
4. The PRD and drawer state pills were still bordered mono boxes, while the legend had become dots: two vocabularies for the same states.
5. #1's subtitle ("the base layer everything n…") ran its ellipsis past the right edge of its box in sans.

What changed:

1. A hold names its end on the host clock, then how far off: "held until 08:30 (in 30m)"; the callout reads "GitHub token gh-auth hit its rate limit: held until 08:30 (in 30m)".
2. The budget is said once, in the overview's header line ("GitHub gh-auth: core 0/5000 · graphql 4210/5000 (checked 1m ago)"); the hold is the callout's. The cards drop both.
3. Kind joins the issue cell ("#11 impl"); the model shows its short name (`opus-5-5`, the full one in `title`). Four columns fit at 400 px with nothing broken.
4. A state is a 6 px dot and a 12 px word in its text colour everywhere: PRD headings, the drawer, unparented issues.
5. The subtitle truncates at 25 characters.

## Round 3: side by side with the references, dark mode, the small screen

Screens: [`screens/round-3/`](screens/round-3/).

Put the drawer next to Linear's issue view (`refs/linear-home.png`) and the overview next to the shadcn dashboard, and read every view at 400 px in dark.

What was weak:

1. At 400 px the PRD graph and #2's children are wider than their panel and scroll inside it, but the cut was a hard edge in the middle of a node: nothing said there was more to the right.

Checked and kept: the drawer's key/value column reads like Linear's properties; dark mode keeps every status colour distinct (the contrast check passes in both themes); the overview answers "is anything stuck" (the amber verdict) and "what needs me" (the awaiting link) in the first screenful at 1440 and 400; a working issue's PR is two clicks from `/` (its row in the card's sessions table opens the drawer, then the PR link), and the drawer names its live session with its `tmux attach` command.

What changed:

1. A graph wider than its panel fades out over its last 40 px until it is scrolled to the end (a scroll-driven animation on `--dag-fade`; a graph that fits has no scroll timeline, so it never fades).

## Round 4: final

Screens: [`screens/round-4/`](screens/round-4/).

Re-shot every view at 1440 and 400 in both themes and pressed Tab through every page (real key events; `:focus-visible` needs them). `test/test_web_design.py`: every visible text passes AA in both themes, every control Tab reaches draws a focus ring, and `scrollWidth` is 1440 at 1440 and 400 at 400 on every view.

No material issue found. Considered and left: the drawer does not dim the page behind it (Linear's issue peek does not either, and the graph stays readable while an issue is open); the theme button is a word, not an icon (it says what it will do, and the dashboard ships no icon set).
