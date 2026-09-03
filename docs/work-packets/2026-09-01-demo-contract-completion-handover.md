# Work packet: finish the demo contract — owner-approved kind, inherited recipe, per-kind schema

This handover completes `2026-09-01-demo-contract-root-cause-handover.md`. It
is terminal. Finish every layer, every acceptance step, and every document in
this packet. Do not create a further handover, defer a decision, leave a
"follow-up lever" note, or propose follow-up work of any kind. Every decision
the root-cause packet left open is decided below. If live evidence materially
contradicts a decision in this document, stop and ask the product owner; do
not park the conflict in a new document.

## Context

The demo kind and recipe used to be re-derived from scratch on every delivery,
revision, and repair turn. Independent re-sampling of a closed decision burned
weeks: kind flips killed tickets on hard-stop validators, reviewers ruled on
kind by taste, and README-vs-recipe ping-pong consumed five-cycle reviews.
The agreed direction: the kind is decided at planning and approved with the
plan; the recipe is established once and inherited; revisions cannot silently
change either.

**Layer 1 is already implemented** (2026-09-01, in the shared working tree):
a revision or continuation whose feedback does not name the demo carries the
prior candidate's validated recipe forward verbatim. `DemoRecipeRevisionPolicy`
(`Sources/SpeditoCore/Domain/DemoLaunch.swift`) decides the pin;
`CodexTicketExecutor.decode(_:pinnedDemoRecipe:)` substitutes it before demo
validation; `applyTechLeadReviewResult` and `executeImplementationRun` thread
it; the revision and recovery prompts state the pinned recipe JSON. Tests:
`DemoLaunchTests.feedbackDemoChangeDetection`, `.revisionFeedbackPinsPriorRecipe`,
`.continuationPinsChangesRequestedRecipe`,
`TicketDeliveryWorkflowCoordinatorTests.d10PinnedDemoRecipeSurvivesKindFlippingRevision`,
`CodexAdapterTests.promptsCarryPinnedDemoRecipe`. Journey row D10, the product
spec, and the technical design already describe it. Preserve all of it: Layer 2
narrows what a turn can emit; the Layer 1 pin remains the recipe-level guarantee
and the only defense for pre-contract tickets.

Remaining: Layers 2–4 below, plus the live acceptance evidence for the whole
packet. The demo-preparation parity packet's runtime fixes landed 2026-09-01,
so Layer 3's sequencing precondition is satisfied.

## Definition of done

The packet is done when all of the following are true:

1. Layers 2, 3, and 4 are implemented, each as its own accepted commit, in
   order.
2. The full default validation passes for each layer, plus the affected
   launched-process contracts for the Layer 2 proposal-card change.
3. Weather Webapp T1 and T2 (preserved workspaces, product workspace
   `E6C25AFF-148D-4D9B-BA83-D1933B853FB5`) converge without a kind failure.
4. Fresh pilot runs of `native-weather` and `web-markdown-notes` finish with
   zero kind-related rejections in their bundles and story tickets demoing as
   the product surface.
5. The epic-plan eval suite records a baseline for
   `plannedDemoKindMatchesProductSurface`.
6. The product owner has inspected the proposal card's review-medium line and
   the contested-kind question, and accepted both.
7. `docs/product-spec.md`, `docs/technical-design.md`, and
   `docs/architecture/owner-journey-test-plan.md` describe the finished
   behavior; the root-cause handover's completion evidence records every layer.

## Layer 2 — the ticket carries an owner-approved demo kind

### Decisions (made; do not reopen)

- The contract value is one of the five `DemoPresentationKind` raw values, the
  literal `none` (code-only work: the delivery must return a null demo through
  the existing code-only path), or SQL `NULL` (pre-contract ticket: delivery
  decides, protected only by the Layer 1 pin).
- Owner-facing phrasing on the proposal card: "You'll review this as:" followed
  by plain language per kind — opens in your browser (browser), an interactive
  prototype (static_web), opens as a Mac app (mac_application), a file you read
  (artifact), command output (command_output), or "a code change with no demo"
  (none). Sentence case, no jargon.
- Accepting the plan accepts the review medium. Changing a stored ticket's kind
  afterwards is a product owner decision, reached only through the
  contested-kind question or an owner edit — never by a delivery turn.

### Implementation

- **Suggestion schema:** add the field to
  `CodexTicketSuggestionGenerator.outputSchema` and its decoder as a required
  enum (`browser`, `static_web`, `mac_application`, `artifact`,
  `command_output`, `none`). The planner prompt states the mechanical rule:
  setup and story tickets use the product surface the clarification round
  fixed (native app vs webapp); design and research tickets use `artifact`;
  code-only tickets use `none`.
- **Persistence:** migration to `PRAGMA user_version = 5` in
  `ProductDatabaseSchema.swift` adds a nullable `demo_kind TEXT` column to
  `ticket_suggestions` and `work_items`, with a CHECK on the seven legal
  values, `NULL` for every existing row. Durable and idempotent like the v4
  migration. Acceptance copies the suggestion's kind onto the created work
  item (`SQLiteStore+TicketSuggestions.swift`, `SQLiteStore+WorkItems.swift`).
- **Presentation:** the proposal card in `EpicDetailView.swift` shows the
  review-medium line before acceptance; `TicketDetailView.swift` shows it on
  the stored ticket. Presentation projections only — no view decides or
  mutates the contract.
- **Delivery constraint:** extend `DeliveryDemoPolicy`
  (`CodexLifecycleGuidance.swift`) with a contracted case built from
  `item.demoKind`. The run's structured output schema then admits only the
  contracted kind's branch (with Layer 4's shapes), so another kind is
  inexpressible and rejection happens inside the turn where structured-output
  retries are cheap. `none` admits only a null demo. `NULL` contract keeps
  today's role-derived policy. The existing `reviewablePrototype` heuristic
  survives only as the `NULL`-contract fallback.
- **Contested kind:** if delivery concludes the contracted kind is genuinely
  wrong it returns `awaiting_owner` with one question proposing the change —
  the existing reviewable-scope-change path. State this in the delivery
  guidance. An owner answer that changes the kind updates the work item
  durably before the continuation turn runs.
- **Review:** the tech lead prompt (`CodexTechLeadReviewer`) receives the
  contracted kind and checks the candidate's recipe against it. A reviewer
  finding may cite a contract mismatch; taste-based kind demands end.
- **Eval:** add `plannedDemoKindMatchesProductSurface` to
  `Tests/SpeditoCoreTests/Evals/EvalEpicPlanChecks.swift` following the
  existing check shapes, wire it into the epic-plan scenarios, and record the
  baseline in the eval report. The evals handover
  (`2026-09-01-epic-plan-quality-evals-handover.md`) already reserves this
  check's name.

### Layer 2 verification

- Suggestion decode tests for every legal value and a rejected illegal value.
- Migration test: v4 database migrates, existing rows read back `NULL`,
  round-trip of each stored value on both tables.
- Acceptance test: the accepted work item carries the suggestion's kind.
- Presentation test: the proposal card state exposes the review-medium line
  pre-acceptance without running an external operation.
- Executor test: a contracted run's schema admits only the contracted branch;
  a `none` contract forces a null demo; a `NULL` contract preserves today's
  schema.
- Contested-kind test: the awaiting-owner path with a kind-change question,
  the owner's answer durably updating the ticket, and the continuation turn
  receiving the new contract.
- Launched-process suite: the proposal card is application-shell presentation
  in `Sources/SpeditoApp`, so run only the affected epic-plan review contract
  through `./scripts/run_ui_tests.sh` when the machine is free; keep the
  affected journey rows' `Shell` designation honest.

## Layer 3 — the product demo recipe is established once and inherited

### Decision (made; do not reopen)

The canonical recipe lives in **verified product knowledge** — one page per
presentation kind the product has shipped, published or updated at candidate
acceptance from the accepted candidate's validated recipe. Owner visibility
decides this over reading the latest accepted candidate row; the accepted
candidate remains the audit source. Record the classification in the technical
design: the knowledge page is durable domain state derived at acceptance; it
is never read back as authority for launching accepted versions
(`AcceptedAppLaunchPolicy` still reads candidate rows).

### Implementation

- On acceptance of a repository-changing candidate
  (`completeSprintTicketAcceptance` path), publish or update the canonical
  demo recipe knowledge page for that recipe's kind, rendered with the exact
  recipe JSON and a plain-language summary.
- Every delivery run's context includes the canonical recipe for the
  contracted kind, with the instruction: reuse this recipe; extend it only if
  your ticket adds a new surface, and say so in the completion handoff.
- Documentation must match the canonical recipe: delivery guidance states the
  recipe page is authoritative over README wording, which ends the
  README-vs-recipe review ping-pong.
- Interaction with Layer 1: the pin carries the prior candidate's recipe
  through revisions; the canonical page seeds the first turn of a new ticket.
  Same recipe in the steady state; the pin wins within a ticket's revisions.

### Layer 3 verification

- A downstream ticket's execution context contains the canonical recipe and
  its accepted result reuses it.
- The inheritance test reuses the parity packet's create/delete round-trip
  fixture so the inherited recipe is proven executable, not just well-formed.
- Acceptance updates the page idempotently; re-acceptance after a preserved
  interruption does not duplicate it.

## Layer 4 — per-kind result schema everywhere

Restructure the execution result's demo object as a discriminated union on
`presentation.kind`, mirroring `DemoLaunchSpecificationValidator`'s semantic
rules: `artifact` requires an inert file path and forbids commands;
`mac_application` requires a `.app` path with null launch command, port, and
readiness; `command_output` requires a launch command and no path;
`static_web` requires a non-root directory and no commands; `browser`
requires a launch command and loopback paths beginning with `/`. Keep
`CodexLifecycleGuidance`'s recipe shapes in sync with the union. With Layer 2
the schema is usually already narrowed to one branch; the union is the
defense for the `NULL`-contract fallback and for suggestion-time validation.
This closes the "schema anyOf" thread from the demo-recipe kind-confusion
work — implement it here, not as a note.

Verification: per-kind decode tests for legal and illegal shapes of every
branch, and the existing `DemoLaunchTests` schema tests updated to assert the
union.

## Non-goals

- Do not weaken any hard-stop validator, the Layer 1 pin, or sandbox and
  approval behavior.
- No change to which kinds exist or how demos launch; the demo runtime was
  fixed by the parity packet. Reversed on 2026-09-01 by `2026-09-01-terminal-demo-kind-handover.md`, which adds the `terminal_application` kind.
- No weather-app-specific prompts, fixtures, or defaults.

## Working notes

- The tree is shared and dirty across sessions. Validate with
  `--scratch-path` (`.build-pin` exists) and never pipe `swift test` through
  `tail`. Begin each layer from an explicitly understood tree and commit the
  accepted layer before starting the next.
- Full default validation per layer: `swift test -Xswiftc
  -warnings-as-errors` (scratch path), `git diff --check`,
  `./scripts/check_architecture_ratchets.sh`, then `./scripts/relaunch.sh`
  left running.
- Pilot runs and evals consume Codex quota; run them when quota and the
  product owner's attention allow. The launched-process suite and relaunch
  seize the GUI — run them only when the machine is free.
- Update the feature navigation map in `CLAUDE.md` only if a new coordinator
  is introduced (none is expected).

## Completion evidence

Record here, per layer: tests added, the migration id, the
`plannedDemoKindMatchesProductSurface` baseline, before/after Weather Webapp
T1/T2 states, the pilot bundle paths proving zero kind rejections, the owner's
inspection outcome, and the commit for each layer. When every line above is
recorded, the demo-contract work is closed.

### Layers 2, 3, and 4 — implemented 2026-09-01

Implementation and test detail per layer is recorded in the root-cause
handover's completion evidence. Migration id: `PRAGMA user_version = 5`
(`migrationV4ToV5`, Layer 2; Layers 3 and 4 need no further migration).
Validation: full suite green with `-warnings-as-errors` on the shared tree,
`git diff --check` clean, architecture ratchets pass. The Layer 3 inheritance
proof ran the recipe recovered from the published canonical page through the
parity packet's create/delete fixture in the real sandbox.

Still pending for the packet: the per-layer commits (blocked on the shared
tree — every touched file also carries other packets' uncommitted work, so a
clean per-layer commit cannot be staged until those packets are committed or
the owner directs otherwise); the affected launched-process contract
(machine-exclusive; the changes touch `Sources/SpeditoApp` view files — run
`./scripts/run_ui_tests.sh -only-testing:SpeditoUITests/PriorityZeroShellJourneyUITests/testD09OwnerQuestionPresentsListedOtherAndSubmitAnswers`
when the machine is free); the Weather Webapp T1/T2
convergence runs and fresh `native-weather` and `web-markdown-notes` pilot
bundles; the relaunch (deferred while a live pilot approval is outstanding in
the running app); and the owner's inspection of the proposal card line and
contested-kind question. The `plannedDemoKindMatchesProductSurface` baseline
is recorded: bundle `20260901-151227`, 7/7 passes across every decoded plan
in the wired cells, zero demoKind decode noise (detail in the root-cause
handover's Layer 2 evidence).
