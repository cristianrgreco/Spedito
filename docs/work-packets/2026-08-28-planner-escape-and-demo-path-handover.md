# Handover: planner escape implementation and demo-path hardening

This document is self-contained: an agent starting fresh can implement it
without the originating conversation. Read `docs/architecture/evals.md` first —
especially **Fixture discipline**. It continues
`docs/work-packets/2026-08-28-eval-decision-handover.md`; that document's
packets 1 and 3 have landed, its packet 2 is superseded by Packet A below, and
the product owner has additionally directed that the residual demo failures be
fixed (Packet B). Implement and commit one packet at a time; Packet B first is
recommended — it is small, re-runs the same delivery eval family, and closes
the acceptance criterion packet 1 missed.

## What has already landed (commits on `pilot`)

- `5f16164` — the original three-packet handover document.
- `bdee3a0` — packet 1: `DeliveryDemoPolicy` narrows the delivery output
  schema's demo kinds to `static_web`/`browser`/`mac_application` for UX
  tickets whose contract promises a prototype; repair turns reuse the narrowed
  schema. Acceptance bundle `.eval-runs/20260828-100742` (REPS=2, medium+high):
  `delivery/ux-prototype` 4/4 clean. The untouched full-enum
  `delivery/implement-feature` cell produced one demo-caused decode failure at
  high effort — the residual Packet B resolves.
- `56a6e4b` — packet 3: the only defaults change the confirmation run
  supported — lead effort high→medium. Confirmation bundle
  `.eval-runs/20260828-102927` (REPS=3, luna vs terra, 84 cells). Luna was
  rejected for businessAnalyst (epic-plan 4.00 vs 4.27, outside the −0.2
  threshold) and knowledgeCurator (equal means, one infrastructure failure).
  Defaults seed new profiles only (`seedDefaultProfiles` inserts only missing
  roles), so no migration was needed.
- `8d4d2bf` — the planner-escape product-spec wording, approved by the product
  owner on 2026-08-28. Implementation is authorised; that is Packet A.

`.eval-runs/` is gitignored; the cited bundles exist locally on this machine.
Session memory (`eval-open-decisions.md`) mirrors this status.

Working notes: commits are SSH-signed; if signing fails with a passphrase
prompt, run `ssh-add --apple-load-keychain` once. The Codex rate-limit window
was at 82% used as of 2026-08-28T12:09Z; the delivery eval family costs
roughly 24 points of a window at REPS=2, so budget or wait for a fresh window
before eval re-runs.

---

## Packet B: make invalid demo paths inexpressible

### Problem

Packet 1 made wrong demo *kinds* structurally inexpressible; the remaining
first-reply demo failures are all wrong *path shapes*, which the schema still
admits and the validator rejects, costing production a repair turn each time:

1. **Placeholder path `"."`.** Bundle `20260828-100742`,
   `delivery/implement-feature` high rep 2: a logic change returned
   `static_web` with path `"."`; rejected by
   `validateRelativePath(allowsCurrentDirectory: false)` at
   `Sources/SpeditoCore/Domain/DemoLaunch.swift:590` ("the demo artifact path
   is incomplete"). The same `"."` mode appeared historically as an artifact
   path (journey test D10 reproduces it).
2. **Non-inert artifact format.** Baseline bundles `20260827-194810` /
   `20260827-202842`: artifact demos pointing at non-inert files, rejected by
   `DemoArtifactPolicy.validatePath`
   (`Sources/SpeditoCore/Domain/DemoLaunch.swift:325`; allowlist at line 320:
   csv, gif, jpeg, jpg, json, log, markdown, md, pdf, png, txt, webp).

The passing cells show the attractor is correct once bad shapes are blocked:
`command_output` running the test entry point, or `artifact` at `README.md`.

### Behavior to preserve or add

- The `artifact` variant's `presentation.path` schema gains a `pattern`
  requiring one of the inert extensions, **generated from
  `DemoArtifactPolicy.allowedExtensions`** (sorted, regex-escaped) so the
  schema and validator cannot drift. Lowercase-only is acceptable: the
  validator lowercases, so an uppercase extension merely falls back to
  today's validator-plus-repair path.
- The `static_web`, `mac_application`, and `artifact` variants' paths gain a
  `pattern` requiring at least one character that is neither `.` nor `/`
  (`[^./]`), making `"."`, `".."`, and `"./"` unwritable. Do **not**
  anchor-forbid a leading dot: `.build/Spedito.app` is a legitimate
  mac_application path (see `Tests/SpeditoCoreTests/DemoLaunchTests.swift`).
- Validator semantics, decode behavior, repair prompts, demo kinds, and the
  `DeliveryDemoPolicy` narrowing are unchanged. The patterns apply identically
  under `.anyKind` and `.reviewablePrototype`.

### Non-goals

- No validator or `DemoArtifactPolicy` changes — the schema mirrors them.
- No guidance rewrites: two prior guidance fixes (`f057d8a`, `1792238`) left
  exactly these residuals; the schema is the contract. If failures persist
  after the patterns, that is new evidence for a product-owner decision, not a
  deeper schema hack.
- No new demo kinds, no UX changes. Reversed on 2026-09-01 by `2026-09-01-terminal-demo-kind-handover.md`, which adds the `terminal_application` kind.

### Current authority

- Schema: `CodexTicketExecutor.demoLaunchSpecificationSchema(deliveryDemoPolicy:)`
  in `Sources/SpeditoCore/Codex/CodexTicketExecutor.swift` (the five
  `specification(...)` variants near line 1025).
- Schema-shape tests: `DemoLaunchTests.structuredSchemaMatchesValidator` and
  `DemoLaunchTests.reviewablePrototypeSchemaAdmitsOnlyInteractiveKinds`.
- The analyzer reuses the schema with `.anyKind`
  (`CodexRepositoryKnowledgeAnalyzer.swift`); patterns apply there too, which
  is correct — its launch proposals face the same validator.

### Known risk

It is unproven whether Codex constrained decoding honors `pattern`. If it is
ignored, behavior degrades gracefully to today's validator-plus-repair — no
worse, and the eval re-run is the proof either way. A real-but-wrong directory
(for example `static_web` at `src`) also remains expressible; the demo
smoke-test and validator still guard it. Accept both residuals; do not expand
scope to chase them.

### Verification

- [ ] Schema tests: the artifact pattern equals one generated from
      `DemoArtifactPolicy.allowedExtensions`; `"."` fails every
      path-carrying variant's pattern; `.build/Spedito.app` and `prototype`
      still match theirs.
- [ ] Full suite, `git diff --check`, ratchets. No relaunch needed (Core-only
      schema change) unless something app-side is touched.
- [ ] `SPEDITO_EVAL_REPS=2 scripts/evals.sh delivery medium,high`.
      Acceptance: **zero demo-caused decode failures and zero demo-kind check
      failures across the whole delivery family at both efforts across reps**
      — the bar `bdee3a0` explicitly missed. Compare against
      `20260828-100742` and state the delta per cell in the handoff.

---

## Packet A: implement the sanctioned planner escape

The spec wording is approved and committed (`8d4d2bf`, in
`docs/product-spec.md`, paragraph beginning "Clarification normally settles
every consequential product choice…"). Implement exactly that behavior.

### Problem

If the epic planner detects that a consequential choice (for example an
unchosen external provider) survived clarification, every reply the current
schema permits is wrong: inventing the decision, burying it in a ticket, or
asking in prose that nothing parses. Production relies on clarification always
settling such choices, which is not guaranteed (see `docs/architecture/evals.md`,
Fixture discipline point 3).

### Behavior to preserve or add

- Schema: the epic-plan output gains a mutually exclusive alternative to the
  plan — reuse the existing clarification question shape (prompt plus two to
  four options, the same shape `CodexEpicClarificationGenerator.outputSchema`
  uses) so the conversation UI needs no new component.
- Decode enforces exclusivity: questions XOR a complete plan, never both,
  never neither. Unresolved-decision questions must not also appear diluted
  inside ticket criteria (the existing vague-decision validator polices the
  criteria side).
- Coordinator: the final-plan turn returning questions resumes the durable
  clarification conversation with those questions; the owner's answers feed
  the next plan attempt. Recovery after interruption re-presents unanswered
  questions from the durable conversation.
- Prompts: `CodexTicketSuggestionGenerator.epicPrompt` and
  `CodexEpicClarificationGenerator.finalPlanPrompt` describe the escape as a
  last resort after clarification, not an invitation to defer.

### Non-goals

- No changes to backlog (non-epic) suggestion generation.
- No new notification surfaces; the existing clarification conversation flow
  carries the questions.

### Current authority (symbols verified 2026-08-28)

- Schema/decode: `CodexTicketSuggestionGenerator.epicOutputSchema` (line
  ~369), `decodeEpicPlan` (line ~642), `epicPrompt` (line ~137) in
  `Sources/SpeditoCore/Codex/CodexTicketSuggestionGenerator.swift`.
- Final-plan prompts: `CodexEpicClarificationGenerator.finalPlanPrompt` (line
  ~258) and `finalPlanRecoveryPrompt` (used at
  `EpicPlanningWorkflowCoordinator.swift:856`).
- Conversation state and resume: `EpicPlanningWorkflowCoordinator.swift`
  (`continueEpicPlanning` at lines ~322/405, the final-plan turn near line
  820, recovery paths) with durable state in `SQLiteStore+Epics.swift`,
  `SQLiteStore+TicketSuggestions.swift`, `SQLiteStore+Conversations.swift`.

### State table

| State | Entered by | Durable evidence | Owner sees | Available actions | Recovery |
| --- | --- | --- | --- | --- | --- |
| Plan escaped to questions | Final-plan turn returns questions | Conversation message with question payload, no suggestion set | The questions in the epic conversation | Answer; cancel planning | Re-present unanswered questions from the durable conversation |
| Planning resumed | Owner answers | Owner answer message | Running indicator | Interrupt | Existing final-plan recovery prompt |

### Verification

- [ ] Decode tests: questions-only decodes; plan-only decodes; both/neither
      rejected.
- [ ] Coordinator journey test: escape → interruption → fresh-instance
      recovery re-presents the questions; answers produce a plan.
- [ ] New eval scenario `epic-plan/unresolved-provider`: a fixture whose
      clarification transcript delegates provider choice to "whatever the
      analyst recommends at planning time" is now a reachable state; the reply
      either plans with an authorised research ticket or escapes with a
      material question — both acceptable, silently choosing a provider is the
      failure.
- [ ] Full suite, ratchets, **relaunch** (this packet touches app behavior)
      and an owner inspection script for the escape flow in the epic
      conversation.
- [ ] `SPEDITO_EVAL_REPS=2 scripts/evals.sh epic-plan medium` at minimum.
      Fresh epic-plan baseline: bundle `20260828-102927`, terra/medium judged
      mean 4.27 (n=3). A regression on `epic-plan/established` blocks the
      packet.

---

## Next steps and open items

1. **Push decision.** All commits are local on `pilot`; the owner has not yet
   said to push.
2. **Sprint-goal eval cells at terra/high stall.** Bundle `20260828-102927`:
   all three terra/high sprint-goal reps hit the 900-second inactivity
   timeout (~53 wasted minutes; no baseline exists — the 2026-08-27 sweep was
   medium-only). Production is unaffected (the generator runs at forced light
   effort under its 15-second deadline). Optional small packet: pin the
   sprint-goal scenario family to production-representative efforts in the
   eval harness so matrix runs stop burning time on known-stalling cells.
3. **Luna infrastructure failures.** One stream disconnect and one inactivity
   timeout in `20260828-102927` were turn-level failures, not structured-output
   failures; nothing to fix, but do not mistake them for decode failures when
   reading `results.json` (they carry `turnFailure` and an empty
   `rawResponse`).
4. **Stale test title fixed in passing**: `agentRoleDefaults` no longer claims
   Luna.

## Shared completion bar

Every packet's handoff states: what changed, the eval bundle(s) that justify
it, the exact deltas versus the cited baselines, and any check that got worse.
A regression on an untouched scenario family blocks the packet. Do not tune
prompts against the judge without also citing deterministic checks — the judge
is directional; the decoders and named checks are the contract.
