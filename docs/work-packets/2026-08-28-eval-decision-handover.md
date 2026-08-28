# Handover: implement the three eval-campaign decisions

This document is self-contained: an agent starting fresh can implement it
without the originating conversation. Read `docs/architecture/evals.md` first
— especially **Fixture discipline** — and treat `.eval-runs/` bundles from
2026-08-27 as the evidence base. The three packets below are independent;
implement and commit them one at a time, in this order. Each prompt- or
schema-affecting packet ends by re-running the affected eval scenario family
and comparing against the cited baseline; a judged improvement must beat
repeat-run variance (`SPEDITO_EVAL_REPS=2` minimum) before it is claimed.

Evidence summary the packets rely on:

- Delivery demo specifications are the least reliable structured output. At
  medium effort, post-guidance-fix cells still chose wrong presentation kinds
  or non-inert artifact paths (bundles `20260827-194810`, `20260827-202842`);
  at high effort post-fix cells were clean. Every failure was caught by the
  decoder/validators, meaning production absorbs them as repair-loop turns.
- The epic-plan schema offers no sanctioned reply when a consequential owner
  choice survives clarification; see "Fixture discipline" point 3 in
  `docs/architecture/evals.md`.
- The model sweep (`20260827-195956` + `20260827-201142`, n=1 per cell) had
  gpt-5.6-luna matching or beating gpt-5.6-terra and gpt-5.6-sol on judged
  quality across all seven scenario families, with all decodes and checks
  passing on all three models; separately, high effort rarely beat medium on
  single-turn generator quality (multiple bundles).

---

## Packet 1: make wrong delivery demo kinds inexpressible

### Problem

`CodexTicketExecutor.outputSchema` is one static shape for every delivery, so
the demo `presentation.kind` enum always admits all five kinds. Agents at
medium effort repeatedly return a kind the delivery contract forbids (a UX
prototype as `artifact`/`command_output`/`mac_application`, an implementer
artifact in a non-inert format), which the validator rejects and production
pays for as a repair turn.

### Behavior to preserve or add

- A delivery turn for a UX ticket whose contract promises a reviewable
  prototype receives an output schema whose demo kind enum admits only
  `static_web`, `browser`, and `mac_application`.
- Other delivery turns keep the full enum; their inert-artifact rule stays
  enforced by the existing validator and stated in the guidance (already done
  in commit `1792238`).
- Decode behavior, repair prompts, and every non-demo field are unchanged.

### Non-goals

- No effort or model changes (Packet 3 owns those).
- No new demo kinds and no changes to demo validation semantics.
- No UX changes.

### Current authority

- Schema: `CodexTicketExecutor.outputSchema` and
  `demoLaunchSpecificationSchema` in
  `Sources/SpeditoCore/Codex/CodexTicketExecutor.swift`.
- The delivery call sites in
  `Sources/SpeditoCore/Domain/TicketDeliveryWorkflowCoordinator.swift` pass
  `CodexTicketExecutor.outputSchema` to `startStructuredTurn`; the same
  coordinator already computes the ticket's delivery mode and role when
  composing `ticketDeliveryInstructions` (see
  `CodexLifecycleGuidance.ticketDeliveryInstructions` and its callers).

### Target authority

- `CodexTicketExecutor.outputSchema(deliveryDemoPolicy:)` (or an equivalent
  small parametric surface) where the policy is derived at the existing call
  sites from the same facts that select the delivery guidance variant. Keep a
  static `outputSchema` only if every call site can cheaply supply the policy;
  do not leave two competing schema paths.

### Call sites to migrate

- [ ] Every `startStructuredTurn(... outputSchema: CodexTicketExecutor...)`
      delivery call in `TicketDeliveryWorkflowCoordinator.swift`, including
      revision, recovery, and repair turns (the repair turn must reuse the
      same narrowed schema).
- [ ] `Tests/SpeditoCoreTests/CodexAdapterTests.swift` schema assertions.
- [ ] Eval scenarios in `Tests/SpeditoCoreTests/Evals/EvalScenarios.swift`
      (`delivery/ux-prototype` should build the narrowed schema exactly as
      production does).

### Verification

- [ ] New adapter test: the UX-prototype policy schema rejects
      `artifact`/`command_output` kinds structurally.
- [ ] Full suite, `git diff --check`, ratchets.
- [ ] `scripts/evals.sh delivery medium,high` with `SPEDITO_EVAL_REPS=2`.
      Acceptance: zero demo-kind check failures and zero demo-caused decode
      failures at both efforts across reps; compare against bundles
      `20260827-194810`/`20260827-202842`.

---

## Packet 2: sanctioned planner escape for unresolved owner decisions

### Problem

If the epic planner detects that a consequential choice (for example an
unchosen external provider) survived clarification, every reply the schema
permits is wrong: inventing the decision, burying it in a ticket, or asking
in prose that nothing parses. Production relies on clarification always
settling such choices, which is not guaranteed.

### Behavior to preserve or add

- Record the agreed behavior in `docs/product-spec.md` first: the final plan
  turn may return owner questions instead of a plan, and Spedito resumes the
  clarification conversation with those questions; the owner's answers feed
  the next plan attempt. This is a product change — it needs the product
  owner's sign-off on the spec wording before implementation.
- Schema: the epic-plan output gains a mutually exclusive alternative to the
  plan — reuse the existing clarification question shape (prompt plus two to
  four options, the same one `CodexEpicClarificationGenerator.outputSchema`
  uses) so the conversation UI needs no new component.
- Decode enforces exclusivity: questions XOR a complete plan, never both,
  never neither; unresolved-decision questions must not also appear diluted
  inside ticket criteria (the existing vague-decision validator already
  polices the criteria side).
- Prompt: `CodexTicketSuggestionGenerator.epicPrompt` /
  `CodexEpicClarificationGenerator.finalPlanPrompt` describe the escape as a
  last resort after clarification, not an invitation to defer.

### Non-goals

- No changes to backlog (non-epic) suggestion generation.
- No new notification surfaces; the existing clarification conversation flow
  carries the questions.

### Current authority

- Schema/decode: `CodexTicketSuggestionGenerator.epicOutputSchema` /
  `decodeEpicPlan` in
  `Sources/SpeditoCore/Codex/CodexTicketSuggestionGenerator.swift`.
- Conversation state and resume: `EpicPlanningWorkflowCoordinator.swift`
  (`continueEpicPlanning`, the final-plan turn, recovery paths) with durable
  state in `SQLiteStore+Epics.swift`, `SQLiteStore+TicketSuggestions.swift`,
  `SQLiteStore+Conversations.swift`.

### State table

| State | Entered by | Durable evidence | Owner sees | Available actions | Recovery |
| --- | --- | --- | --- | --- | --- |
| Plan escaped to questions | Final-plan turn returns questions | Conversation message with answered-question payload, no suggestion set | The questions in the epic conversation | Answer; cancel planning | Re-present unanswered questions from the durable conversation |
| Planning resumed | Owner answers | Owner answer message | Running indicator | Interrupt | Existing final-plan recovery prompt |

### Verification

- [ ] Product-spec update reviewed by the product owner.
- [ ] Decode tests: questions-only decodes; plan-only decodes; both/neither
      rejected.
- [ ] Coordinator journey test: escape → interruption → fresh-instance
      recovery re-presents the questions; answers produce a plan.
- [ ] New eval scenario `epic-plan/unresolved-provider`: a fixture whose
      clarification transcript delegates provider choice to "whatever the
      analyst recommends at planning time" is now a reachable state; check
      that the reply either plans with an authorised research ticket or
      escapes with a material question — both are acceptable, silently
      choosing a provider is the failure.
- [ ] Full suite, ratchets, relaunch (this packet touches app behavior).

---

## Packet 3: evidence-gated model and effort defaults

### Problem

`Sources/SpeditoCore/Domain/AgentPersonaDefaults.swift` pins gpt-5.6-terra
for all nine roles with high effort on four of them. Sweep evidence (n=1 per
cell) says luna matches or beats terra on single-turn generator quality and
high effort rarely beats medium — enough signal to justify the confirmation
run, not yet enough to change defaults.

### Behavior to preserve or add

1. Confirmation run first:
   `SPEDITO_EVAL_REPS=3 scripts/evals.sh "epic-plan/established,clarification/vague,refinement/decision-needed,sprint-goal/cohesive,knowledge/answerable,review/flawed-candidate,repo-knowledge" medium,high gpt-5.6-luna,gpt-5.6-terra`
   (drop sol — it was neither cheapest nor best). Budget: roughly 84 gen +
   84 judge turns; watch the rate-limit lines in `metadata.json` and split
   the run across usage windows if needed.
2. Apply only what the numbers support, with this decision rule per role
   family: change a default only where the challenger's judged mean is at
   least as high as the incumbent's minus 0.2 AND deterministic checks/decodes
   are perfect across reps.
   - businessAnalyst, knowledgeCurator: candidate luna/medium.
   - lead (reviewer): candidate terra/medium (review cells passed at medium
     on all three models).
   - implementer, uxDesigner, frontendEngineer, backendEngineer: leave model
     unchanged (no delivery model-sweep data exists); effort per Packet 1
     outcome — if narrowed schemas hold at medium across reps, medium is
     acceptable, otherwise keep high.
3. Defaults seed new profiles only; existing products keep their stored
   `AgentProfile` rows — verify this by reading the profile-creation path in
   `ProductStoreRegistry.swift` / `SQLiteStore+AgentProfiles.swift` before
   claiming no migration is needed, and state the finding in the handoff.

### Non-goals

- No changes to `PersonaTemplate.swift` (owner-installable templates are the
  owner's choice).
- No UI changes; `ProductSettingsView` pickers already expose overrides.

### Verification

- [ ] The confirmation bundle committed to the record in the work-log/handoff
      with the per-role decision table filled in from its `report.md`.
- [ ] `AgentPersonaDefaults` tests updated alongside any change.
- [ ] Full suite, ratchets; relaunch only if any app-side default surfaces in
      UI text.

---

## Shared completion bar

Every packet's handoff states: what changed, the eval bundle(s) that justify
it, the exact deltas versus the cited baselines, and any check that got worse.
A regression on an untouched scenario family blocks the packet. Do not tune
prompts against the judge without also citing deterministic checks — the
judge is directional; the decoders and named checks are the contract.
