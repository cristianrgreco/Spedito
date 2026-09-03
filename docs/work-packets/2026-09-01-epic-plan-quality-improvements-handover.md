# Handoff: epic-plan quality improvements — closing packet set

This document is the complete remaining work for the epic-plan quality
workstream. When every packet below is done, the workstream is closed. The
final handoff reports deltas against the approved baseline and states that
the workstream is closed; it must not contain follow-up proposals, open
questions, or suggested next packets. That is an explicit owner instruction
(2026-09-01), not a style preference.

If a genuinely new defect class is observed while executing this work, add
its deterministic check inside the packet that observed it (measurement is
cheap) and finish. Do not open a new improvement campaign for it; later
defects arrive through pilot runs and live usage as ordinary bugs.

## Context

The measurement packet
(`docs/work-packets/2026-09-01-epic-plan-quality-evals-handover.md`) landed
2026-09-01: 11 deterministic structural checks in
`Tests/SpeditoCoreTests/Evals/EvalEpicPlanChecks.swift`, the
`parallelismWidth` and archetype metrics, the per-cell cross-sample
consistency block in `EvalReport.swift`, and the two launch-brief cells
`epic-plan/native-weather` and `epic-plan/web-markdown-notes`.

Approved baseline: `.eval-runs/20260901-104954` — `SPEDITO_EVAL_REPS=3
scripts/evals.sh epic-plan medium`. All structural checks pass on every
decoded sample. The measured problems this document fixes:

- Design-ticket presence is sampling luck: 1/3 on native-weather, 1/2 on
  web-markdown-notes, 0/3 on greenfield. Plans without it are fully serial
  (`parallelismWidth` 1.00; 1.50 when design appears).
- Setup-ticket criteria leak jargon the mined list misses: "managed check",
  "cached files", "team-owned commands", "stored build data" (ownerClarity
  2–3 on five samples).
- The notes cell's storage handling is unstable: two samples silently
  committed browser-only storage, one escaped to ask. Three samples, two
  different behaviours, neither stated plainly to the owner.
- Degenerate constrained-decoding replies (recorded 2026-08-29: a reply of
  `"x"`, options of `":{"`, a path of `"/?"`) decode as low-content garbage
  instead of failing into an ordinary repair turn.

## Decisions recorded (do not re-ask the owner)

1. **Medium effort** is the eval configuration for epic-plan baselines and
   comparisons. It matches the production business analyst profile
   (`AgentPersonaDefaults`). Owner confirmed 2026-09-01.
2. **The 11-check list and the 20260901-104954 baselines are approved.**
   Owner reviewed them in the 2026-09-01 session.
3. **Storage default for greenfield briefs (Packet C):** when a launch brief
   leaves the storage approach unstated and a default committing no external
   service exists (browser/local storage for a webapp, on-device files for a
   native app), the planner commits that default with its recommendation
   recorded and states the behaviour plainly in owner-facing scope (for
   example "notes are saved in this browser on this device"). Escaping to a
   storage question for such a brief is the wrong behaviour. This applies
   the epic prompt's existing "sensible recommended default that commits no
   external service" rule; the defect was committing it silently.
4. **The minimum-content decode validator (Packet D) is authorised** as a
   production change by this document. It was pending owner sign-off since
   the 2026-08-29 handover; folding it here is that sign-off.
5. **Demo path patterns remain rejected** (owner decision, 2026-08-29 eval
   handovers). Do not retry them in any form.
6. **Judge-score bar:** attempt ≥ 4.0 mean per epic-plan cell at REPS=3
   medium, inherited from the approved score campaign. It is a bar to
   attempt, not a promise: after two targeted iterations without movement on
   a cell, record the plateau in the final handoff and stop. Stopping at a
   plateau closes the item; it is not grounds for a follow-up proposal.

## Method (applies to every packet)

One theme per iteration, the loop that already worked: deterministic anchor
first, family baseline, ONE targeted prompt change, re-run the same matrix,
compare against repeat-run variance. Never tune against the judge without a
deterministic anchor. On a surprising score, audit the fixture before the
prompt. A regression on any untouched epic-plan cell blocks the iteration
that caused it.

Comparison runs: `SPEDITO_EVAL_REPS=3 scripts/evals.sh epic-plan medium`.
Check the primary usage window before each run (`metadata.json` records
before/after; the baseline run cost 17 points). Wait for a fresh window
rather than starting a run that cannot finish.

## Packet A: make the design ticket deterministic on greenfield visible-experience epics

**Problem.** Whether a greenfield plan for a visible product includes a
design/experience ticket is currently sampling luck, and its absence makes
the plan fully serial.

**Change.** Strengthen the planning guidance in
`CodexTicketSuggestionGenerator.epicPrompt` (and, only if the prompt alone
plateaus, `CodexLifecycleGuidance`): an epic whose outcome includes a visible
interface or interaction gets a UX design ticket producing an independently
reviewable outcome, proceeding in parallel with environment setup (the
existing `independentWorkNotSerialised` check already guards the parallel
part). Keep the existing right-sizing rule intact — this must not push
established single-feature epics into padded design tickets.

**Done when:**
- Design-archetype presence is 3/3 on `epic-plan/native-weather` and 3/3 on
  `epic-plan/web-markdown-notes` in the comparison run.
- `parallelismWidth` ≥ 1.5 on every sample of both launch cells.
- `epic-plan/established` stays 1 ticket, all checks green (no manufactured
  design work), and `epic-plan/greenfield` stays within 2–5 with all checks
  green.

## Packet B: plain language in setup-ticket criteria

**Problem.** The environment ticket's owner-facing criteria still leak
delivery vocabulary the mined jargon list misses.

**Change.** Two parts, eval first:
1. Add the terms mined from the 20260901-104954 judge rationales to
   `ownerFacingJargonTerms` in `EvalScenarios.swift`: "managed check",
   "cached files", "team-owned commands", "stored build data". Mined terms
   only — do not pad speculatively.
2. Strengthen the plain-language passage of
   `CodexTicketSuggestionGenerator.epicPrompt` (the "never put 'repository',
   'toolchain'… in any owner-visible field" sentence) so the new terms'
   classes are covered: internal check names, cache/build-artifact
   vocabulary, and command/entry-point phrasing. The technical checklist
   stays coverage to satisfy, not wording to copy.

No production validator changes in this packet.

**Done when:** `ownerFacingFieldsAvoidJargon` (with the extended list) is
green on every sample of the comparison run, and greenfield/native-weather
ownerClarity means improve versus the baseline (attempt ≥ 4.0 under the
decision-6 stop rule).

## Packet C: stated storage default on the notes brief

**Problem.** See decision 3. Two baseline samples committed browser-only
storage silently; one escaped to ask.

**Change.**
1. Apply decision 3 to the epic prompt: when committing a
   no-external-service default the plan must state the resulting behaviour
   plainly in the epic goal or a ticket's owner-facing scope, not bury it.
2. Update the `epic-plan/web-markdown-notes` cell brief to declare the
   expected behaviour (plan, not escape; default stated plainly), so
   `returnsPlan` failing on an escape is a real defect signal.
3. Deterministic anchor: extend the notes cell's `extraChecks` with a
   mined check (name it `committedDefaultIsStated`) that fails when no
   owner-facing field of the plan names where notes are kept — keep the
   term list small and literal (for example "browser", "this device",
   "saved locally"), mined from the actual passing samples.

**Done when:** `returnsPlan` and `committedDefaultIsStated` are 3/3 on the
notes cell in the comparison run, and the decision-discipline judge
rationales no longer report a silent storage commitment.

## Packet D: minimum-content decode validator (production change, authorised)

**Problem.** Degenerate constrained-decoding replies (evidence recorded
2026-08-29: prompt `"x"`, option `":{"`, path `"/?"`) decode as garbage
that scores 1.0 instead of failing into the existing repair path.

**Change.** In the production decoders' normalisation
(`CodexEpicClarificationGenerator.normalizedQuestions` and the equivalent
suggestion/refinement entry points), reject fields below a minimum content
bar — a question prompt, option, or ticket title that is a single character
or contains no letters — as `invalidResponse`, so the ordinary repair turn
handles them. Follow the failure contract: the owner-facing behaviour is the
existing recoverable repair flow, nothing new.

**Done when:** unit tests cover each observed degenerate shape (rejected)
and a minimal legitimate reply (accepted); the full suite is green; no eval
cell regresses in the comparison run.

## Packet E: closing run, docs, and commits

1. Run the closing comparison: `SPEDITO_EVAL_REPS=3 scripts/evals.sh
   epic-plan medium`. Record the per-cell table (checks, ticket-count
   spread, design presence, parallelism width, judge means) against
   `.eval-runs/20260901-104954` in this document's completion evidence.
2. Update `docs/architecture/evals.md` and the 2026-09-01 measurement
   packet's evidence section with the final term lists and cell briefs.
3. Commit the accepted packets, one commit per packet, staging by explicit
   path only — the shared tree carries unrelated uncommitted work from other
   sessions; never include files you did not edit. Commits are SSH-signed
   (`ssh-add --apple-load-keychain` if signing prompts).
4. Write the final handoff: deltas versus the baseline, plateaus if any
   (decision 6), and the closing statement. No proposals.

## Non-goals

- No changes to clarification, refinement, sprint-goal, review, delivery, or
  knowledge cells beyond the shared jargon list in Packet B.
- No judge-rubric rewrites.
- No launched-process tests: nothing here touches application-shell wiring;
  say so in each handoff.
- Other workstreams (demo recipe schema, notification consistency, demo
  preparation parity, seatbelt glob issue) keep their own handover docs and
  are not reopened here.

## Verification (every packet)

- Focused unit tests for changed checks/validators with passing and failing
  fixtures.
- Full default validation: `swift test -Xswiftc -warnings-as-errors` (with
  the module-cache env vars; use `--scratch-path` if another session holds
  the repo `.build`), `git diff --check`,
  `./scripts/check_architecture_ratchets.sh`.
- Family comparison run per iteration as described under Method.
- Relaunch only for Packet D (it changes production decode): relaunch and
  leave the app running per the standard protocol. Packets A–C and E touch
  prompts and the test target; prompt text ships in the app binary, so the
  final post-commit relaunch after Packet E covers them.

## Completion evidence

To be filled by the executing session: per-packet changes, closing
comparison table versus `.eval-runs/20260901-104954`, plateaus if any, and
the statement that the epic-plan quality workstream is closed.
