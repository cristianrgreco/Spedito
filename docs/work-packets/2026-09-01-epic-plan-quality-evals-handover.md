# Work packet: measure proposed-ticket quality in epic refinement

## Problem

Epic refinement's proposed tickets are the contract everything downstream
inherits, and today their quality is measured almost entirely by the LLM judge.
The three `epic-plan/*` eval cells (`Tests/SpeditoCoreTests/Evals/
EvalScenarios.swift`) carry a `planShape` rubric dimension covering
right-sizing, genuine dependencies, and parallelism — but a rubric score is one
number per sample. It cannot say *which* structural property regressed, it
cannot fail a build, and it says nothing about consistency across samples.

Live evidence of what slips through:

- **Spurious time sensitivity.** Battersea product, T1 acceptance criterion,
  observed by the product owner 2026-09-01: "Within two working days, review
  Battersea's current public terms, access limits, and the pages that expose
  available dog listings." An agent delivers in minutes and has no calendar; a
  working-day deadline in an acceptance criterion is unfalsifiable noise the
  owner reads as silly. Nothing catches it.
- **Deliverable-format mandates the sandbox cannot satisfy.** Pilot run
  `.pilot-runs/2026-08-31-034551-native-weather` (and its predecessor): a
  design ticket's criteria hard-required "a managed Demo containing a static
  PNG visual screen set"; the sandbox cannot rasterize PNG, the ticket burned
  its runs and failed. The generating guidance was fixed on 2026-08-31
  (`uxTicketContractGuidance`), but no eval guards against regression.
- **Plan-shape variance on identical prompts.** The same weather prompt
  produced a 2-ticket plan (no design ticket) on one run and 3-ticket plans on
  others; the notes prompt produced 3 then 2. Whether a design ticket exists at
  all is currently sampling luck, and per-sample judging cannot see it.
- **Dependency and parallelism shape is judge-only.** When the weather plan
  parallelised setup and design correctly (bundle
  `.pilot-runs/2026-08-31-163913-native-weather`), that was observed in a live
  run, not asserted anywhere.

The owner's goal: proposed tickets must be **measurable** (structural
properties become named pass/fail checks and numeric metrics), **improvable**
(a guidance change shows up as a check or score moving, with a recorded
baseline), and **high quality** along the dimensions below.

## Behavior to add

Extend the epic-plan eval cells so each generated plan is scored on named,
per-dimension outcomes, and so repeated samples of one cell yield a
consistency measure. Follow the suite's established philosophy (stated in
`EvalScenarios.swift` comments): deterministic checks encode *observed* defect
classes with small literal term lists; the judge remains the qualitative layer
for wording no list can catch. Do not invent speculative checks with no
observed failure behind them.

### Dimensions and their checks

Owner-specified dimensions first, then proposed additions. Each deterministic
check gets a name, a passed flag, and a detail string naming the offending
ticket reference — matching `criteriaAvoidVaguePhrases` and
`ownerFacingFieldsAvoidJargon`.

1. **Ticket count and right-sizing** (owner). Deterministic bounds per cell:
   each scenario declares an expected count range (greenfield weather-class
   epic: 2–5; established single-feature epic: 1–3). Outside the range fails
   `ticketCountWithinExpectedShape`. Proxy for mega-tickets: a ticket with more
   than ~7 acceptance criteria fails `ticketScopeNotOverloaded`. The judge
   keeps scoring right-sizing qualitatively.

2. **Title quality** (owner). Existing `noReferencePrefixInTitles` stays. Add
   `titlesAreDistinctOutcomes`: titles must be pairwise distinct and must not
   be bare role labels ("Research", "Design", "Implementation"). Sentence-case
   and jargon are already covered by `ownerFacingFieldsAvoidJargon`.

3. **Dependencies make sense** (owner). Deterministic graph checks on the
   draft's dependency references:
   - `dependenciesResolveAndAreAcyclic`: every reference names a proposal in
     the batch or an existing active backlog ticket; no cycles; no
     self-dependency; no dependency on an archived or released item unless the
     cell's backlog fixture marks it legitimate.
   - `noRedundantTransitiveEdges`: if A→B and B→C, an explicit A→C edge fails
     (it hides the real graph and serialises the board's presentation).
   - `verificationFollowsImplementation`: a verification-type proposal must
     depend (directly or transitively) on the implementation it verifies.

4. **Parallelism maximised** (owner). Two parts:
   - Deterministic: `independentWorkNotSerialised` — a design/experience
     ticket must not depend on the environment/setup task (design needs no
     toolchain; the canonical cat-joke plan in `CLAUDE.md` states T2 "may
     proceed in parallel"). Generalise carefully: only fail edges between
     ticket pairs the cell fixture declares independent, so the check stays
     literal rather than heuristic.
   - Metric: report `parallelismWidth` = ticket count divided by the
     dependency graph's critical-path length, as a recorded numeric metric per
     sample (not pass/fail). Improvements to prompts should move this number
     visibly on the greenfield cell; regressions show as it collapsing toward
     1.0 (fully serial).

5. **Sufficiently scoped, no deferred outcomes** (owner). Existing
   `criteriaAvoidVaguePhrases` covers mined deferral phrases. Add mined terms
   only as the judge surfaces them; do not pad the list speculatively. Two
   structural additions:
   - `everyTicketHasAcceptanceCriteria`: a proposal with zero acceptance
     criteria is not an agreed outcome.
   - `dependantCriteriaCiteExactKeys`: the generator instructs the model to
     cite the exact prerequisite ticket reference in a dependant criterion
     (`CodexTicketSuggestionGenerator.swift`), and durable keys make those
     citations stable — verify a criterion that names another proposal's
     decision uses a reference that resolves to a declared dependency.
     General testability and concreteness stay with the judge's
     `criteriaQuality` dimension.

6. **No spurious time sensitivity** (new, mined 2026-09-01 from Battersea).
   `criteriaAvoidCalendarDeadlines`: acceptance criteria and ticket bodies
   must not impose calendar durations or deadlines — mined literal patterns:
   "working day", "business day", "within \d+ (day|week)", "by end of".
   Delivery has no calendar; a time-box in a criterion cannot be verified by
   the ticket's own delivery. Keep the list literal and small; note that
   "time-boxed research" as a *scope* word in clarification options is a
   different, legitimate usage — the check applies to proposal criteria and
   bodies only.

7. **No unsatisfiable deliverable-format mandates** (new, mined from the
   PNG/SVG failures). `criteriaRespectDeliverableFormats`: criteria must not
   require an artifact file format outside `DemoArtifactPolicy.
   allowedExtensions` (SVG, HTML as inert files) and must not mandate exactly
   one image format by name (the fixed guidance phrases requirements around
   states covered, letting delivery pick any accepted format). This is the
   regression guard for the 2026-08-31 `uxTicketContractGuidance` fix.

8. **Cross-sample consistency** (new). When a cell runs with multiple samples,
   the report should aggregate per-cell: ticket-count spread, presence/absence
   of each ticket archetype (setup, design, story, verification), and
   parallelism-width spread. Surface it in `EvalReport` as a per-cell
   consistency block. A prompt change that stabilises "design ticket present"
   from 60% to 100% of samples is exactly the improvement loop the owner
   wants; today it is invisible.

9. **Foundation discipline** (existing). `readinessIsFoundationRequired` and
   the research-discipline rubric stay as they are.

### Scenario coverage

Add two cells built from the owner's real launch briefs so the improvement
loop measures what he actually runs (prompts verbatim from
`Tests/SpeditoAppTests/Pilot/PilotBriefs.swift`):

- `epic-plan/native-weather` — "Create a native macOS app which uses the
  user's location to show a 7 day weather forecast, use open-meteo free
  non-commercial." Greenfield; expect setup + design + story shape and the
  format/parallelism checks to bite.
- `epic-plan/web-markdown-notes` — "Create a webapp which lets a user create
  and manage notes in markdown." Greenfield.

## Non-goals

- No changes to suggestion-generation prompts or guidance in this packet;
  measurement first, then improvement in follow-up packets with before/after
  scores.
- No judge-rubric rewrites beyond what the new checks make redundant.
- Do not revisit the rejected demo-path-pattern checks (owner decision,
  recorded 2026-08-29 eval handovers).
- The pending owner decisions in
  `docs/work-packets/2026-08-29-eval-coverage-and-scores-handover.md`
  (theme-4 validator, greenfield residual themes) stay open; this packet must
  not silently resolve them.

## Verification

- [x] Every new check has a unit test in `EvalSupportTests.swift` with a
      passing and a failing fixture draft (including a Battersea-style
      "within two working days" criterion and a "static PNG" mandate).
- [x] Graph checks proven against hand-built drafts: cycle, dangling
      reference, redundant transitive edge, serialised design ticket.
- [x] `scripts/evals.sh` runs the epic-plan cells end to end; record the new
      baseline scores and metrics in the eval report and note them in the
      handoff.
- [x] Full default validation (`swift test` with warnings-as-errors,
      `git diff --check`, ratchet script). Use a `--scratch-path` if another
      session may hold the repo `.build`.
- [x] Product owner reviews the check list and baselines before any
      prompt-improvement packet builds on them. (Reviewed 2026-09-01;
      medium-effort baseline configuration confirmed. Remaining work is
      consolidated in `2026-09-01-epic-plan-quality-improvements-handover.md`.)

## Completion evidence

Implemented 2026-09-01. Files: `Tests/SpeditoCoreTests/Evals/
EvalEpicPlanChecks.swift` (new), `EvalScenarios.swift`, `EvalReport.swift`,
`EvalSupportTests.swift`.

Checks added, all applied to every plan-producing epic-plan cell:
`ticketCountWithinExpectedShape`, `ticketScopeNotOverloaded`,
`titlesAreDistinctOutcomes`, `everyTicketHasAcceptanceCriteria`,
`dependenciesResolveAndAreAcyclic`, `noRedundantTransitiveEdges`,
`verificationFollowsImplementation`, `independentWorkNotSerialised`,
`dependantCriteriaCiteExactKeys`, `criteriaAvoidCalendarDeadlines`,
`criteriaRespectDeliverableFormats`. Metrics recorded as facts per sample:
`parallelismWidth`, `criticalPathLength`, `archetypes`. `EvalReport` gained a
per-cell cross-sample consistency block. New cells:
`epic-plan/native-weather` and `epic-plan/web-markdown-notes`, prompts
verbatim from `PilotBriefs.swift`.

Validation: 689/689 tests green with `-warnings-as-errors` (17 new unit
tests), `git diff --check` clean, all 6 ratchet baselines match.

Baseline run `.eval-runs/20260901-104954`: `SPEDITO_EVAL_REPS=3
scripts/evals.sh epic-plan medium` — 15 cells, gpt-5.6-terra at medium (the
production business analyst configuration), quota 44% → 61%.

- Every new deterministic check passed on every decoded sample (14 of 15;
  one `web-markdown-notes` sample escaped to a storage question, failing the
  existing `returnsPlan`). The new checks are regression guards; their
  failure detail strings are exercised by the unit-test fixtures, e.g.
  `criteriaAvoidCalendarDeadlines`: `S1: “Within two working days, review
  Battersea's current public terms, access limits, and the…” (working
  days)`; `criteriaRespectDeliverableFormats`: `S1: “A managed Demo
  containing a static PNG visual screen set is provided” (mandates the png
  format …)`; `independentWorkNotSerialised`: `design ticket S2 is
  serialised behind environment setup: S2 → S1`.
- Consistency baseline (the packet's target measurement): design-archetype
  presence is 1/3 on `native-weather` and 1/2 on `web-markdown-notes` —
  whether a design ticket exists is confirmed sampling luck. Ticket-count
  spread 2–3 on both launch cells; `parallelismWidth` 1.00–1.50 (1.00
  whenever the design ticket is absent, so the plan is fully serial).
  `greenfield` and `established` were shape-stable (2 tickets / 1 ticket in
  all samples).
- Judge residuals for the improvement packets: setup-ticket criteria leak
  jargon the mined list does not yet catch (“managed check”, “cached
  files”, “team-owned commands”; ownerClarity 2–3 on five samples), and
  two `web-markdown-notes` samples silently committed browser-only storage
  (researchDiscipline 1, groundedness 2) while the third escaped to ask —
  the storage decision is unstable across samples.

Those residuals were taken up and closed by
`2026-09-01-epic-plan-quality-improvements-handover.md`, which extended the
term lists this packet established. `ownerFacingJargonTerms` gained the four
mined setup terms (“managed check”, “cached files”, “team-owned commands”,
“stored build data”), and the notes cell gained a brief addendum plus
`committedDefaultIsStated` over `committedStorageStatementTerms`
(“in this browser”, “in the same browser”, “on this device”, “on the same
device”, “saved locally”), mined from the samples in this baseline that
committed the default. See that document's
completion evidence for the closing comparison.
