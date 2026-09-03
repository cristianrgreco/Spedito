# Handoff: the code-only demo recipe fix and campaign residuals

This document is self-contained: an agent starting fresh can implement it
without the originating conversation. Read `docs/architecture/evals.md` first —
especially **Fixture discipline** — and follow the change and commit protocol in
`AGENTS.md`. It continues
`docs/work-packets/2026-08-29-eval-coverage-and-scores-handover.md`, whose
packets A–F are all complete.

## What has already landed (commits on `pilot`, all pushed)

- `d126967` — permission-request grading: three deterministic checks on
  workspace delivery cells plus a permissionDiscipline judge dimension fed the
  recorded requests as ground truth.
- `fee4bab` — effort pinning: `EvalEffortPolicy.lightestSupported` pins the
  sprint-goal family to production's configuration; skipped cells log one line
  each. A plain `medium,high` matrix therefore never runs sprint-goal — request
  `low` to measure it.
- `325da46` — the `delivery/ux-native-prototype` scenario plus
  `demoIsNotStaticImageShoehorn` and `prototypeIsRealMarkup` (both UX
  scenarios). The mis-kind defect is intermittent (~2 in 5 native cells) and
  judges score those cells 4.0–5.0 — only the deterministic checks see it.
- `68923cd` — multimodal judging: `startStructuredTurn(imageInputPaths:)`
  emits localImage items; the harness attaches ≤ 4 worktree images ≤ 2 MB each
  to the judge turn (drops named); image-bearing cells score a visualFidelity
  dimension. The structured-turn + localImage combination is probe-proven.
- `f4492b8` — knowledge grading: delivery `knowledgePageProposals` checks and
  a knowledgeDiscipline dimension; the `knowledge-review/mixed-drafts`
  scenario over one sound and one evidence-contradicting draft.
- `f960f0f`, `91748bd` — campaign iterations 1 and 3: jargon and
  vague-phrase checks on epic-plan owner-facing fields, each with one
  epicPrompt fix; both checks went to 0/9. Greenfield's judged mean plateaued
  after these two iterations and was reported per the stop rule.
- `f4b0a2c` — campaign iteration 2: the permissionDiscipline rubric is
  calibrated to the delivery contract's sanctioned Homebrew batch; identical
  agent behavior went from scores of 1–2 to 3–5.
- `8b204df` — campaign iteration 4: `optionsShareNoRepeatedContext` (with a
  prompt-echo exclusion) plus the short-distinct-phrase option instruction in
  both clarification blocks; vague 2.58 → 3.12, detailed-outcome 3.00 → 3.25
  in the iteration comparison.
- `6282af2` — a stalled judge turn retries once on a fresh thread, mirroring
  the `02d148f` candidate-turn stall recovery.

## Decisions already made — do not relitigate

1. **Demo-path schema patterns remain REJECTED** (see the 2026-08-29
   eval-coverage handover, decision 1). The fix in Packet A below is an
   instruction change, never a schema `pattern`.
2. **Retrospective guidance stays exactly as-is**; empty retro lists on an
   unremarkable run are CORRECT.
3. **The permissionDiscipline rubric stays calibrated to the delivery
   contract** (`f4b0a2c`): contract-compliant Homebrew batching scores well.
4. The greenfield and vague judged means are **plateaued under the campaign
   stop rule**; do not grind further prompt iterations on them without a new
   owner-approved theme.
5. The owner approved on 2026-08-29: **Packet A below** (the code-only demo
   recipe fix) and the judge stall retry (already landed as `6282af2`).
6. **Theme 4 — a minimum-content validator for degenerate replies — is NOT
   approved.** The owner asked why such replies occur and has the answer
   (schema-constrained decoding guarantees shape, not substance; example in
   bundle `20260828-214122`, detailed-outcome high rep 3: a question of "x"
   with options ":{", "prompt", "options", "x"), but has not yet decided.
   It is a production change; do not implement it without explicit sign-off.
7. Push `pilot` after each accepted packet unless newer instructions say
   otherwise.

## Current judged baselines (final full matrix, 2026-08-29)

Terra, medium effort, REPS=2, bundle `20260829-195226`; sprint-goal at its
pinned low effort, REPS=3, bundle `20260829-202631`. Judge stalls excluded.

| Scenario | Judge | Notes |
| --- | --- | --- |
| knowledge/answerable · unanswerable | 5.00 · 5.00 | |
| clarification/resolved | 4.88 | |
| review/clean · flawed | 4.50 · 4.38 | |
| knowledge-review/mixed-drafts | 4.50 | |
| epic-plan/established | 4.30 | |
| delivery/ux-prototype · ux-native-prototype | 4.25 · 4.25 | one mis-kind cell each, caught deterministically |
| retrospective/synthesis | 4.17 | |
| repo-knowledge/initial-analysis | 4.00 | |
| sprint-goal/cohesive · disjoint | 4.00 · 4.00 | meets the 15s deadline |
| delivery/implement-feature | 3.83 | one decode failure (demo recipe — Packet A) |
| epic-plan/greenfield | 3.80 | n=1; plateaued per stop rule |
| clarification/detailed-outcome | 3.75 | improved by `8b204df` |
| refinement/decision-needed | 3.75 | |
| epic-plan/unresolved-provider | 3.50 | adversarial by design |
| clarification/vague | 2.62 | plateaued; high rep variance |

---

## Packet A: let a code-only ticket confidently return no demo (approved)

### Problem
On code-only implementer tickets, roughly 1 run in 3 attaches a broken demo
recipe instead of a null demo. Three distinct variants are recorded, all on
`delivery/implement-feature`: a `static_web` path of `"."` (bundle
`20260829-143215`), a `static_web` path pointing at a JavaScript source file
judged "not credible" (`20260829-143215` rep 1 judge rationale), and an
artifact rejected because "review artifacts must use an inert text, data,
image, or PDF format" (`20260829-150439`). Production absorbs each as a
repair turn (latency + usage), and the invalid recipes drag the
handoffQuality dimension (scores 1–3).

### Build
- ONE targeted change to the delivery guidance in
  `CodexLifecycleGuidance.swift` (the demo/handoff section): a ticket whose
  outcome is logic or data behavior with no visible surface should return a
  null demo and say in the handoff why no demo applies; a demo recipe is for
  something the owner can genuinely open. Do not touch the schema, the demo
  policy, or `DemoLaunchSpecificationValidator`.
- No new deterministic check is needed: `reportsCompleted`, decode
  pass rate, and the judge's handoffQuality dimension already measure this.

### Verification
Ordinary suite, `git diff --check`, ratchets; then a baseline is already on
record (the bundles above — implement decode failures in 2 of 3 recent
delivery runs). Run `SPEDITO_EVAL_REPS=3 scripts/evals.sh delivery medium`
after the fix and compare: the acceptance signal is implement-feature decode
passing all reps with a null demo, and no regression on the ux scenarios'
`providesManagedDemo` (visible work must still ship a demo). If the fix
suppresses demos on UX tickets, that is the failure mode to watch.

## Candidate next themes (need owner approval before acting)

Mined from recorded judge rationales; each would follow the campaign loop
(deterministic check first, baseline, one fix, comparison):

1. **Synonym jargon in epic-plan owner-facing fields** — the term-list check
   is green but rationales now flag "managed check", "managed Demo",
   "approved tools and versions". A synonym sweep risks whack-a-mole; an
   owner conversation about the right instrument comes first.
2. **Unrequested-state invention in epic plans** — groundedness rationales
   flag invented loading/keyboard/responsive states on greenfield. The
   no-invention instruction already exists; this may be a fixture or rubric
   conversation rather than a prompt fix.
3. **Theme 4** (decision 6 above) once the owner decides.

## Working notes

- Eval runs spend real usage. The primary window can be probed without cost:
  send `initialize` → `initialized` → `account/rateLimits/read` over
  `codex app-server` stdio with stdin held open ~8 seconds. The window is a
  fixed 5-hour bucket; `resetsAt` in the response says when it clears. Wait
  for headroom rather than starting a run that cannot finish.
- Commits are SSH-signed; `ssh-add --apple-load-keychain` if signing prompts.
- Other sessions may hold uncommitted work in the shared tree. Stage commits
  by explicit path; never include files you did not edit.
- The launched-process suite is not required for Packet A (no
  application-shell wiring); say so in the handoff.
- Lead with deltas versus the bundles named above in every handoff, and state
  any check that got worse.
