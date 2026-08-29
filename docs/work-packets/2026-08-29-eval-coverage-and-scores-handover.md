# Handoff: permission grading, effort pinning, and the all-4s score campaign

This document is self-contained: an agent starting fresh can implement it
without the originating conversation. Read `docs/architecture/evals.md` first —
especially **Fixture discipline** — and follow the change and commit protocol in
`AGENTS.md`. It continues
`docs/work-packets/2026-08-28-planner-escape-and-demo-path-handover.md`.
Implement and commit one packet at a time, in the order below.

## What has already landed (commits on `pilot`, all pushed)

- `fbf11b0` — the sanctioned planner escape: the final epic-plan turn returns
  owner questions instead of a plan when a consequential choice survived
  clarification (questions XOR plan behind a required `reply` envelope; the
  structured-output endpoint rejects a top-level `anyOf` — proven by 400s in
  bundle `20260828-172836`). E16 journey, `epic-plan/unresolved-provider`
  scenario.
- `0f44fd0` — clarification options no longer restate the whole epic outcome.
  Deterministic `optionsShareNoLongPrefix` went 6/18 failing → 0/18
  (baseline `20260828-212915`, comparison `20260828-214122`).
- `8f38bd6` — retrospective grading: delivery/review retro checks and rubric
  dimensions plus the `retrospective/synthesis` scenario
  (bundles `20260829-011325`, `20260829-032332`).
- `02d148f` — eval stall fix: total caps 900s/600s, one fresh-thread retry per
  stalled cell, and per-cell `approvalDecisions` / `stalledAttempts` recorded
  in `results.json` facts. The retry path has not yet been exercised by a real
  run — confirm it behaves on this handoff's first eval run.

## Decisions already made — do not relitigate

1. **Demo-path schema patterns are REJECTED; do not retry.** Three approved
   iterations each failed differently (bundles `20260828-151031`,
   `20260828-201302`, `20260829-011325`): `pattern` constraints on the demo
   anyOf variants fix path shapes but induce demo-kind mis-selection with
   increasingly deceptive payloads — the final iteration produced fabricated
   conforming paths such as `prototype/index.html.app`. The baseline schema is
   restored; the occasional `"."` placeholder repair turn (~1 in 8 delivery
   runs) is the accepted cost. The rejected diff sits in `git stash`
   ("REJECTED packet-b…") as evidence only.
2. **Retrospective guidance stays exactly as-is** (see the 2026-08-28
   handover); an empty retro list on an unremarkable run is CORRECT and never
   a deterministic failure.
3. The product owner approved, on 2026-08-29: Packet A (permission-request
   grading), Packet B (sprint-goal effort pinning), Packet C (the
   native-product UX demo scenario), Packet D (knowledge page creation and
   review grading), and Packet E (the score campaign). The owner explicitly
   ordered D before E so the campaign can also improve the new knowledge
   grading if its first scores warrant it; E's all-4s bar includes every
   scenario that exists by then, the C and D additions included.
4. The owner authorised pushing this session's work on 2026-08-29; push
   `pilot` after each accepted packet unless newer instructions say otherwise.

## Current judged baselines (comparators for every packet)

Terra unless stated; infra failures excluded from means.

| Scenario | Checks | Judge | Bundle |
| --- | --- | --- | --- |
| epic-plan/greenfield | pass | 3.2 | 20260828-174039 (medium, n=2) |
| epic-plan/established | pass | 4.1 | 20260828-174039 (medium, n=2) |
| epic-plan/unresolved-provider | pass | 3.4 | 20260828-174039 (medium, n=2) |
| clarification/vague | pass | 2.96 | 20260828-214122 (med+high, n=6) |
| clarification/resolved | pass | 4.8 | 20260828-214122 (med+high, n=6) |
| clarification/detailed-outcome | pass | 3.0 healthy | 20260828-214122 (one degenerate reply at 1.0 in the raw 2.6 mean) |
| review/clean-candidate | pass | 4.5 | 20260829-032332 (medium, n=1) |
| review/flawed-candidate | pass | 4.2 | 20260829-032332 (medium, n=1) |
| retrospective/synthesis | pass | 4.7 | 20260829-032332 (medium, n=1) |
| delivery/implement-feature | 3/4 clean (one "." repair) | ~4.0 | 20260828-100742 (the restored baseline schema) |
| delivery/ux-prototype | 4/4 clean | ~4.3 | 20260828-100742 |

---

## Packet A: grade agent permission requests (approved)

### Problem
The harness *answers* permission requests (`EvalApprovalResponder` in
`Tests/SpeditoCoreTests/Evals/EvalSupport.swift` ~383: approves in-workspace
commands and read/execute grants, declines network and out-of-workspace
writes, rejects unknown request kinds) but nothing *grades* them. The
production contract — request the smallest exact scope; never pre-authorise —
has zero coverage, and `CodexLifecycleGuidance` memorialises a real incident
of an agent requesting five separate paths. As of `02d148f` every cell's
decisions land in its `facts["approvalDecisions"]`.

### Build
- Deterministic checks on the delivery scenarios, computed from the cell's
  recorded decisions: no network requests (neither fixture ticket needs any),
  no out-of-workspace write requests, and a bounded total request count
  (suggest ≤ 4 — both fixtures complete with ≤ 2 today; log the bound in the
  check detail, no silent caps).
- A judge dimension on permission discipline: requests are few, exactly
  scoped, and made when actually blocked — not speculative pre-authorisation.
- Do NOT change `EvalApprovalResponder` semantics or any production
  permission behavior.

### Verification
Ordinary suite green, `git diff --check`, ratchets; then
`SPEDITO_EVAL_REPS=2 scripts/evals.sh delivery medium` and confirm the new
checks appear with sensible details (also confirm `02d148f`'s retry/facts on
this run). Named-check regressions on untouched checks block the packet.

## Packet B: pin scenario families to production-representative efforts (approved)

### Problem
Production generates the sprint goal at the lightest supported effort under a
hard 15-second deadline, but effort sweeps run the sprint-goal family at every
requested effort; the terra/high sprint-goal cells stalled 3/3 in bundle
`20260828-102927` (~53 wasted minutes measuring a configuration the product
never uses).

### Build
- Add an optional per-scenario allowed-efforts declaration to `EvalScenario`
  (`EvalScenarios.swift` ~31) and filter cells in the `EvalRun` matrix loop,
  printing one line per skipped cell (no silent caps).
- Pin the sprint-goal family to the lightest supported effort per model
  (`supportedReasoningEfforts` is already in run metadata). Leave every other
  family unpinned.

### Verification
Ordinary suite, diff check, ratchets. Then a cheap proof:
`SPEDITO_EVAL_REPS=1 scripts/evals.sh sprint-goal low,medium,high` — the run
should execute only the pinned effort and log the skips.

## Packet C: native-product UX demo mis-kind scenario (approved)

### Problem — observed in production
In the owner's "native notes app" product, ticket T2, the UX designer
created a static PNG and submitted it as the demo: a `mac_application`
presentation whose path is `design/forecast-experience.png`. The validator
does not require a `.app` suffix, so this decodes and validates and fails
only at demo launch. This is the exact "valid shape, wrong kind" residual
the rejected pattern experiment documented — schema `pattern` fixes remain
off the table (decision 1), but *detecting* the defect in evals is in scope.

### Build
A third delivery scenario, `delivery/ux-native-prototype`: a UX ticket in a
product whose context and Environments page describe a native macOS
application (keep the fixture in the generic invoicing family — e.g. a
native Ledgerline companion app; no notes-app or weather-app references).
The fixture worktree has no application-building toolchain, so the only
achievable demoable prototype is a self-contained `static_web` mock of the
native interface. Deterministic checks:
- `demoIsNotStaticImageShoehorn`: fail when the demo kind is
  `mac_application` and the path does not end in `.app` — the exact
  production defect signature; the detail must name the offending path.
- The existing `demoIsStaticWeb`-style expectation for the achievable kind,
  and the shared delivery checks (including retro and, once Packet A lands,
  permission checks).
Rubric: reuse the ux-prototype dimensions; state in the brief that a static
image or a fabricated application path is the failure this scenario probes.
Verify the fixture with one real run before trusting the checks (fixture
discipline lesson 1).

### Verification
Ordinary suite, diff check, ratchets; then
`SPEDITO_EVAL_REPS=2 scripts/evals.sh delivery medium` — report the new
scenario's first results alongside the existing delivery cells.

## Packet D: grade knowledge page creations and review (approved)

### Problem
Knowledge **answers** are graded (`knowledgeScenarios`, citation fidelity)
and the repository-analysis scenario covers analyzer-proposed pages, but two
steps are ungraded: delivery-created `knowledgePageProposals`
(`TicketExecutionResult`; decode caps at 4) and the knowledge review step
(`CodexRepositoryKnowledgeReviewer`, listed in evals.md as not yet covered).

### Build
Follow the retrospective-grading commit (`8f38bd6`) as the template; evals
and fixtures only, no production changes.

1. **Delivery scenarios**: deterministic checks and facts for
   `knowledgePageProposals` — unique slugs within the reply, non-empty
   trimmed titles and bodies, plus counts and slugs as facts. A rubric
   dimension mirroring the retro framing: proposals hold durable cross-ticket
   knowledge grounded in this run, in plain language; restated ticket content
   or invented pages are penalized, and NO proposals on an ordinary run
   scores well (the fixture tickets do not obviously warrant a page).
   Proposing a replacement Environments body is legitimate when the run
   verified a workflow, so a duplicate-of-supplied-slug is not a
   deterministic failure.
2. **Knowledge review scenario** (new generator, id prefix
   `knowledge-review/` — distinct from the existing `knowledge/` and
   `review/` prefixes so family filters stay precise): drive
   `CodexRepositoryKnowledgeReviewer`'s production builders, schema, and
   decoder over fixture proposals in the clean/flawed pattern the tech lead
   review scenarios use — one sound page and one that overclaims or
   contradicts the repository content it cites. Deterministic checks on the
   decision per fixture; rubric on evidence fidelity and owner-facing
   clarity. Verify the flawed fixture actually contains the defect before
   trusting the check (evals.md, Fixture discipline lesson 1).

### Verification
Ordinary suite, `git diff --check`, ratchets; then
`SPEDITO_EVAL_REPS=1 scripts/evals.sh delivery,knowledge-review medium` and
report that the new checks and scenario execute, decode, and report, with
observed results in the handoff.

## Packet E: score campaign toward an all-4s minimum (approved as an attempt)

### Goal and bar
Raise every scenario's judged mean to ≥ 4.0 at `SPEDITO_EVAL_REPS=3`, medium
effort, infrastructure failures excluded. This is a stretch target the owner
knows may not fully land: the sub-4 scenarios (greenfield 3.2,
unresolved-provider 3.4, vague 2.96, detailed-outcome 3.0) are deliberately
adversarial. Treat 4.0 as the bar to attempt, not a promise; if a scenario
plateaus after two targeted iterations, stop and report rather than grinding.

### Method — the loop that already worked (2.38 → 2.96 on vague)
One theme per iteration: turn a recurring judge critique into a deterministic
check first, run a baseline, make ONE targeted prompt fix, re-run the same
matrix, compare against repeat-run variance. Never tune against the judge
without a deterministic anchor; on a surprising score, audit the fixture
before the prompt (see evals.md, Fixture discipline).

Themes in recommended order, mined from the recorded judge rationales:
1. **Owner-facing jargon in foundation/establishment tickets** (largest
   greenfield drag: "repository", "caches", "localhost", "managed readiness
   check" in owner-visible titles/bodies). Add a term-list check on epic-plan
   suggestions' owner-facing fields; then strengthen the existing plain-
   language instruction in `CodexTicketSuggestionGenerator.epicPrompt`.
2. **Vague acceptance-criteria phrases** ("relevant", "that matter", "ready
   for build hand-off"). Eval check first; do NOT extend the production
   vague-decision validator without owner sign-off (it changes repair
   behavior).
3. **Clarification option wording follow-up** (options still long-ish and
   jargon-tinged after `0f44fd0`).
4. **Degenerate constrained-decoding replies** (observed twice: a reply of
   `"x"` prompts / `":{"` options scoring 1.0, and a `"/?"` path). A
   minimum-content validator in production decode would convert these into
   ordinary repair turns — that is a PRODUCTION change: propose it to the
   owner with the evidence before implementing.

### Verification per iteration
Family-scoped baseline and comparison runs (REPS=3), deterministic checks
green, ordinary suite, diff check, ratchets. Finish the campaign with one
full-matrix run at medium (REPS=2 minimum) and report the final per-scenario
table against the baselines above. A regression on any untouched scenario
family blocks the iteration that caused it.

## Working notes

- Eval runs spend real usage: check the primary window before any matrix
  (each bundle's `metadata.json` records before/after; a delivery family run
  at REPS=2 costs ~25–42 points of a 5-hour window; clarification ~10–12 at
  REPS=3). Wait for a fresh window rather than starting a run that cannot
  finish.
- Commits are SSH-signed; `ssh-add --apple-load-keychain` if signing prompts.
- Another session's per-epic coordinator refactor may still be uncommitted in
  the shared tree (`EpicPlanningWorkflowCoordinator.swift` and app files).
  Stage your commits by explicit path; never include files you did not edit.
  If the ordinary suite fails inside those files, report it as external.
- The launched-process suite is not required for any packet here (no
  application-shell wiring); say so in each handoff.
- Lead with deltas versus the named baseline bundles in every handoff, and
  state any check that got worse.
