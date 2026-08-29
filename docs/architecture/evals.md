# Prompt evals

The eval suite gives numeric answers about prompt and model quality that the
deterministic test suite and the pilot cannot: how often each generator's
reply survives the production decoder and validators on the first attempt,
and how well the surviving replies score against owner-facing quality rubrics,
per model and reasoning effort.

It complements the other layers rather than replacing them:

- Deterministic tests prove wiring and serialization with scripted replies.
- The pilot drives whole owner journeys through the real application and
  reports invariant findings for human triage.
- Evals isolate one prompt at a time against real Codex and score the reply,
  so a prompt or effort change produces a comparable number instead of a
  hunch.

## What a scenario is

Each scenario in `Tests/SpeditoCoreTests/Evals/EvalScenarios.swift` sends the
exact triple production sends — the generator's `developerInstructions`, its
`prompt` built from fixture domain models, and its `outputSchema` — through a
real Codex thread of the kind the owning coordinator uses. Fixtures use a
generic invoicing product; none refer to the weather-app example. Three thread
kinds exist:

- **Read-only** for planning, clarification, refinement, sprint goal,
  knowledge answers, and tech lead review. Review scenarios pin their own
  detached candidate checkout, the way production pins review workspaces, with
  one sound candidate and one whose handoff overclaims a criterion the code
  violates.
- **Repository analysis** over a sanitized snapshot prepared with the
  production `GitWorkspaceManager` snapshot pipeline.
- **Workspace** for real write-enabled delivery runs in an isolated ticket
  worktree: the implementer scenario seeds a failing executable specification
  whose passing is deterministic ground truth, and the UX scenario requires a
  demoable prototype per the UX ticket contract. An approval responder plays a
  cautious product owner (commands inside the fixture workspace and
  read-or-execute grants approved; network and outside writes declined), the
  worktree resets to base before every cell, and the actual branch diff is
  handed to the judge as ground truth alongside the handoff.

Two scoring tiers run on every reply:

1. **Deterministic (tier 1).** The production `decode` function and its
   semantic validators, plus scenario-specific checks (readiness matches the
   supplied environment evidence, owner-reviewed epic metadata is preserved,
   snapshots are unchanged while questions are outstanding, citations stay
   within supplied pages). A decode failure here is exactly the failure that
   triggers the repair loop in production, so the decode pass rate is the
   repair-loop rate made visible.
2. **LLM judge (tier 2).** A fresh Codex thread per reply scores a per-
   generator rubric (owner clarity, groundedness, plan shape, question
   materiality, and so on) on a 1–5 scale with rationales. Judge scores are
   directional, not gates: single samples are noisy, and a judged improvement
   must beat repeat-run variance before it is believed.

## Running

```sh
scripts/evals.sh                     # full matrix at medium and high effort
scripts/evals.sh sprint-goal         # one scenario family
scripts/evals.sh "" low,medium,high  # sweep efforts
scripts/evals.sh "" medium gpt-5.6-luna,gpt-5.6-terra,gpt-5.6-sol  # sweep models
```

`swift test` skips the suite unless `SPEDITO_EVALS=1`; the script sets it. A
run needs a working Codex installation and spends real usage — the full
default matrix is roughly forty turns. Results land in
`.eval-runs/<timestamp>/`:

- `metadata.json` — model, efforts, Codex version, and the primary rate-limit
  window before and after the run as a cost proxy.
- `results.json` — every cell's raw reply, decode outcome, named checks,
  derived facts, latency, and judge scores. Rewritten after every cell so an
  interrupted run keeps its evidence.
- `report.md` — per-generator tables and per-dimension judge means by effort,
  plus every failure and failed check.

Environment knobs (`SPEDITO_EVAL_MODEL`, `SPEDITO_EVAL_REPS`,
`SPEDITO_EVAL_JUDGE_MODEL`, `SPEDITO_EVAL_JUDGE_EFFORT`,
`SPEDITO_EVAL_SKIP_JUDGE`, `SPEDITO_EVAL_CODEX`) are documented in
`scripts/evals.sh`.

## Reading the numbers

- **Decode pass rate** is the headline tier 1 metric per generator × effort.
  In production a decode failure is silently absorbed by a repair turn, which
  costs latency and usage; here it is counted.
- **Named checks** capture behavioral contracts the decoder does not enforce
  (for example `readyWithoutQuestions` on the fully-resolved clarification
  scenario). A failed check is a finding, not a build failure.
- **Judge means** compare efforts and prompt revisions directionally. Use
  `SPEDITO_EVAL_REPS` to establish variance before trusting a delta.
- The sprint goal generator runs in production at the lightest supported
  effort under a hard 15-second deadline; its `meetsProductionDeadline` check
  records whether a cell would have met that deadline.

The suite reports rather than fails: a low score is evidence for a prompt
change, and the accepted workflow is propose, re-run, compare, review the
prompt diff. Only infrastructure problems (no Codex runtime, unknown model)
fail the test.

## Fixture discipline

Three fixture lessons were paid for with real runs and must not be relearned:

1. **A scenario's ground truth must be airtight before its check is signal.**
   The first "clean" review candidate omitted the owner-visible surface the
   ticket promised, so the reviewer's block was correct and the judge —
   anchored to the wrong brief — punished it. Verify candidate fixtures with a
   real test run before trusting the scenario.
2. **The judge scores against the scenario brief.** A wrong brief inverts the
   judgement, so a surprising judge score means auditing the fixture first and
   the prompt second.
3. **Scenarios must be reachable production states.** Epic-plan fixtures whose
   outcome hinges on an unresolved consequential choice put the planner in a
   position production would not create (clarification settles such choices
   first) and no available reply scores well. The real unresolved-choice case
   needs a product decision about a sanctioned planner escape hatch before it
   can be a fair scenario.

## Extending

Add a scenario by constructing fixture domain models and reusing the
generator's public `developerInstructions`, `prompt`, `outputSchema`, and
`decode`. Keep fixtures generic, keep deterministic checks about contracts
(not wording), and give the judge a rubric dimension only when a human could
apply it consistently. Generators not yet covered (conversation turns,
conflict integration) need run histories or conflicting-branch fixtures and
are the natural next additions.
