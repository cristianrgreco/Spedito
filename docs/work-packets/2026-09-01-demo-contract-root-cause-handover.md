# Work packet: the demo contract is decided once, owner-approved, and inherited

## Problem

The demo kind and recipe are re-derived from scratch at the end of every
delivery turn — by the implementer, inside a full context, as one field of the
structured execution result — and re-derived again on every revision and
repair. Each derivation is an independent sample of a decision that was never
supposed to be open. The compounding misses have consumed weeks of iteration:
guidance, repair prompts, validator messages, and hard-stop validators all
police the individual sample; none stop the re-sampling.

Evidence across products and pilots:

- **Weather Webapp** (workspace `E6C25AFF-148D-4D9B-BA83-D1933B853FB5`,
  2026-09-01): T1 candidate v1 correctly declared `browser`. Review asked for
  a one-line fix to a Markdown command. The revision re-emitted the result
  with `mac_application`; the hard-stop validator killed the run. T2 died on
  the no-op-command rule. T3 blocked. The correct decision existed and was
  destroyed by an unrelated edit.
- **Pilot native-weather** (`.pilot-runs/2026-08-31-163913-native-weather`):
  T1 resubmitted `command_output` three times against an identical review
  blocker demanding `mac_application` (five candidate versions). T3 — the
  story whose outcome *is* the app — was accepted with a `command_output`
  demo while T1's reviewer had demanded the opposite: review judges kind by
  taste because no contract exists.
- **Pilot web-markdown-notes** (`.pilot-runs/2026-08-31-172712-…`): T2's PDF
  screen set was submitted first under a literal `placeholder.app` recipe,
  then as `static_web`, then as `mac_application`, with rejection text naming
  the right kind each time.
- **Pilot web-markdown-notes** (`.pilot-runs/2026-08-30-223943-…` T1, five
  review cycles): README described one demo workflow while the recipe did
  another; the reviewer correctly flagged the inconsistency each round and
  the implementer alternated which side it changed. No canonical recipe
  exists for docs to match.

The recent hard-stop validators did not cause the defect — they changed its
cost from wasted review cycles to dead tickets, which is why the current state
feels like the worst yet. They must stay; the fix belongs upstream.

Owner-agreed direction (2026-09-01): the kind is decided at planning and
approved with the plan; the recipe is established once and inherited;
revisions cannot silently change either.

## Behavior to add

Four layers, delivered as separate commits in this order. Layer 1 stops
today's bleeding; each layer is independently valuable.

### Layer 1 — pin the recipe through revisions

A revision or repair turn whose review feedback does not request a demo or
recipe change carries the prior candidate's validated demo recipe forward
verbatim. Only feedback that names the demo may change it, and then only the
named part. A doc-string fix can never again break a working demo contract.
Look at how `CodexTicketExecutor` builds revision turns and where a new
execution result replaces the prior candidate's; the prior recipe is durable
on the previous `candidate_revisions` row.

### Layer 2 — the ticket carries an owner-approved demo kind

- Epic refinement proposes, per ticket, how the owner will review it: the
  expected `DemoPresentationKind` (or "no demo" for code-only work), phrased
  owner-facing on the proposal card — "You'll review this as: opens in your
  browser / opens as a Mac app / a file you read / command output."
  Accepting the plan accepts the review medium. The suggestion schema,
  persistence (`ticket_suggestions`, `work_items`), and proposal presentation
  gain the field; a durable, idempotent migration adds it with a null
  fallback meaning "delivery decides" for pre-existing tickets.
- Planning derives it mechanically: setup and story tickets use the product's
  surface (the clarification round already fixes native app vs webapp);
  design/research tickets use `artifact`; code-only tickets use none. The
  planner prompt states this; the epic-plan evals measure compliance (see
  the evals handoff — add `plannedDemoKindMatchesProductSurface`).
- Delivery receives the kind as a constraint, not a choice: the run's
  structured result schema admits only the contracted kind's shape, so
  the model cannot emit another kind — rejection happens inside the turn,
  where structured-output retries are cheap, not as a failed run.
- If delivery concludes the contracted kind is genuinely wrong, it returns
  `awaiting_owner` with a question proposing the change — the existing
  reviewable-scope-change path. It never silently diverges. Tech lead review
  checks the recipe against the contract, ending taste-based kind rulings.

### Layer 3 — the product's demo recipe is established once and inherited

The setup ticket's accepted, smoke-tested recipe becomes the product's
canonical demo recipe: published to verified product knowledge at acceptance
(or read from the latest accepted candidate per kind — choose whichever fits
the knowledge model; owner-visibility argues for knowledge). Every downstream
run's context includes it with the instruction: reuse this recipe; extend
only if your ticket adds a new surface, and say so in the handoff. Docs must
match the canonical recipe — which also ends the README-vs-recipe review
ping-pong, because one side is now authoritative.

### Layer 4 — per-kind result schema everywhere

Restructure the execution result's demo object as a discriminated union on
`presentation.kind`, mirroring `DemoLaunchSpecificationValidator`'s semantic
rules: `artifact` requires an inert file path and forbids commands;
`mac_application` requires a `.app` path; `command_output` requires a launch
command and no path; `static_web` requires a directory; `browser` requires a
launch command and loopback path. Keep `CodexLifecycleGuidance`'s recipe
shapes in sync. With Layer 2 the schema is usually already narrowed to one
branch; the union is the defense for the null-contract fallback and for
suggestion-time validation.

## Non-goals

- The hard-stop validators stay exactly as strict. Do not weaken them.
- The demo *runtime* — sandbox write/delete scope, readiness ports, failure
  text — is `2026-09-01-demo-preparation-parity-handover.md`, a separate
  packet. See "Relationship" below.
- No change to which kinds exist or how demos launch. Reversed on 2026-09-01 by `2026-09-01-terminal-demo-kind-handover.md`, which adds the `terminal_application` kind.

## Relationship to the demo-preparation parity packet

Complementary, not conflicting: this packet owns *what the recipe is and who
decides it*; the parity packet owns *whether the runtime can execute it*.
They touch disjoint code (planning schema, proposal presentation, executor
result contract here; `MacOSDemoLauncher` sandbox profile, readiness, failure
text there) and can proceed in parallel worktrees.

One sequencing consequence to respect: once Layer 3 lands, a single recipe is
reused product-wide — so a runtime-parity bug in that recipe propagates to
every ticket instead of one. The parity packet's fixes should land before or
alongside Layer 3, and Layer 3's inheritance test should reuse the parity
packet's create/delete round-trip fixture so an inherited recipe is proven
executable, not just well-formed.

Both packets share the same acceptance vehicle: pilot runs of
`native-weather` and `web-markdown-notes` reaching launched demos of the
expected kind.

## Documentation and inventory

- Update `docs/product-spec.md` (proposal cards show the review medium; kind
  changes are owner decisions) and `docs/technical-design.md` (demo contract
  lifecycle) in the same packet that changes the behavior.
- Journey inventory: extend the affected E-rows (plan review) and D-rows
  (delivery/demo) in `docs/architecture/owner-journey-test-plan.md`;
  `Shell = —` unless a real shell-wiring defect appears.
- The feature navigation map in `CLAUDE.md` needs no new coordinator; if one
  is introduced anyway, update the table in the same commit.

## State classification (per the architecture invariants)

- Contracted demo kind on suggestion and work item: durable domain state
  (SQLite, migrated).
- Canonical product demo recipe: durable (knowledge page or accepted
  candidate row — decide and record which).
- Kind shown on a proposal card / "review as" line: presentation projection.
- The executor's narrowed schema per run: derived from durable state at turn
  start; never cached across runs.

## Verification

- [ ] Layer 1: revision test — review feedback without demo mention preserves
      the prior recipe byte-for-byte; feedback naming the demo may change it.
- [ ] Layer 2: suggestion decode/persistence/migration tests; proposal
      presentation test (kind visible pre-acceptance); executor test that the
      run schema admits only the contracted kind; awaiting-owner path test
      for a contested kind. Epic-plan eval check
      `plannedDemoKindMatchesProductSurface` with recorded baseline.
- [ ] Layer 3: a downstream ticket's context contains the canonical recipe;
      its accepted result reuses it; the parity fixture proves the inherited
      recipe executes.
- [ ] Layer 4: per-kind decode tests, legal and illegal shapes.
- [ ] Full default validation (warnings-as-errors suite, `git diff --check`,
      ratchets; `--scratch-path` if the repo `.build` may be held).
- [ ] Relaunch, then retry Weather Webapp T1/T2 (workspaces preserved) — they
      must converge without a kind failure.
- [ ] Pilot `native-weather` and `web-markdown-notes` runs: zero kind-related
      rejections in the bundles; story tickets demo as the product surface.
- [ ] Product owner inspection of the proposal card and the contested-kind
      question.

## Completion evidence

Record per layer: tests added, migration id, the eval baseline for planner
kind accuracy, before/after Weather Webapp ticket states, and the pilot
bundle paths proving zero kind rejections.

Everything after Layer 1 — Layers 2–4, the live acceptance runs, and every
open decision, now decided — is scoped in
`2026-09-01-demo-contract-completion-handover.md`. That handover is terminal:
finishing it closes this packet with no further follow-up work.

### Layer 1 — implemented 2026-09-01

- `DemoRecipeRevisionPolicy` (`DemoLaunch.swift`) decides the pin: narrow
  demo-vocabulary matching over the review feedback (live path) or over the
  non-implementer comments since the sent-back candidate (recovered
  continuations). `CodexTicketExecutor.decode` substitutes the pinned recipe
  before demo validation, so a re-decided demo neither burns repair turns nor
  reaches a hard-stop; awaiting-owner results keep their null demo. The
  revision and recovery prompts state the pinned recipe JSON.
- Both consumers pass the pin: `applyTechLeadReviewResult` (changes-requested
  revisions, from the reviewed candidate's decoded result) and
  `executeImplementationRun` continuations (from the durable
  `candidate_revisions` row). No migration needed — the prior recipe was
  already durable on the previous candidate row.
- Tests: `DemoLaunchTests.feedbackDemoChangeDetection`,
  `.revisionFeedbackPinsPriorRecipe`, `.continuationPinsChangesRequestedRecipe`;
  `TicketDeliveryWorkflowCoordinatorTests.d10PinnedDemoRecipeSurvivesKindFlippingRevision`
  (statically invalid kind flip validates with zero repair turns; awaiting-owner
  keeps a null demo); `CodexAdapterTests.promptsCarryPinnedDemoRecipe`. Journey
  inventory row D10 extended.
- Deliberate bias: unrecognised demo phrasing in feedback pins (bounded
  reviewer ping-pong) rather than unpins (possible dead ticket). Layer 2's
  durable contract removes the residual ambiguity.

### Layer 2 — implemented 2026-09-01

- `TicketDemoKind` (`DemoLaunch.swift`) carries the owner-approved review
  medium: the five presentation kinds plus `none` (Swift case `codeOnly`),
  with the plain-language "You'll review this as" phrase per kind; SQL `NULL`
  stays the pre-contract state. Migration id: `PRAGMA user_version = 5`
  (`migrationV4ToV5`) adds `demo_kind TEXT` with the seven-value CHECK
  (six literals plus NULL) to `ticket_suggestions` and `work_items`; every
  existing row reads back NULL.
- Planner: `CodexTicketSuggestionGenerator` requires `demoKind` on every
  proposal (schema enum plus decoder), and the platform instructions state
  the mechanical rule — setup and story tickets use the fixed product surface,
  design and research use artifact, code-only uses none. Acceptance copies the
  suggestion's kind onto the created work item.
- Delivery: `DeliveryDemoPolicy` gains `.contracted(kind)` and `.codeOnly`
  from `item.demoKind`; the result schema then admits only the contracted
  branch (or only a null demo), `validateDeliveryEvidence` backs the schema up
  with a contract check and lets a `none`-contract repository change return
  the null demo the guidance promised, and the `reviewablePrototype` heuristic
  survives only as the NULL-contract fallback. Prompts state the contract
  (`demoKindContractContext`); the tech lead prompt receives it
  (`reviewMediumContractContext`) and taste-based kind demands end.
- Contested kind: a contracted turn returns `awaiting_owner` with
  `proposedDemoKind`; Spedito stores the question with its own canonical
  options (`DemoKindContestPolicy`), and the owner's exact answer option
  updates the work item durably (`updateWorkItemDemoKind`, version bump,
  audit event) before the continuation turn runs — idempotently, so relaunch
  recovery can repeat it. The accepted answer names the demo, so it also
  unpins the Layer 1 recipe.
- Presentation: the proposal card and stored ticket show the review-medium
  line (`TicketReviewMediumPresentation`); projections only.
- Eval: `plannedDemoKindMatchesProductSurface` added to
  `EvalEpicPlanChecks` and wired into the established and both launch-brief
  epic-plan cells. Baseline recorded from bundle `20260901-151227` (REPS=3,
  medium, run by the epic-plan quality campaign): the check passed on every
  decoded plan — established 3/3, native-weather 3/3, web-markdown-notes 1/1
  (its other two reps and two greenfield reps escaped to storage/surface
  questions, none naming the demo medium — the quality campaign's Packet C
  theme, not a demoKind effect). All 15 samples decoded; the required
  `demoKind` field introduced no decode noise.
- Tests: `CodexAdapterTests.suggestionDemoKindDecoding`,
  `.proposedDemoKindDecoding`, `.promptsCarryTheDemoKindContract`;
  `SQLiteStoreTests.demoKindContractsMigrateAndRoundTrip`;
  `DemoLaunchTests.contractedSchemaAdmitsOnlyTheContractedBranch`,
  `.codeOnlyContractForcesANullDemo`, `.contestedKindOptionsRoundTrip`;
  `WorkflowPolicyTests.deliveryDemoPolicyHonoursTheStoredContract`;
  `TicketDeliveryWorkflowCoordinatorTests.contestedDemoKindAsksTheOwnerAndAppliesTheAnswer`;
  `EpicPlanningPresentationTests.proposalCardStatesTheReviewMedium`.
  Journey rows E09 and D10 extended, Shell designations unchanged.

### Layer 3 — implemented 2026-09-01

- The canonical demo recipe lives in verified product knowledge: one page per
  presentation kind the product has shipped, under Operations next to
  Environments. `CanonicalDemoRecipeKnowledge` (`DemoLaunch.swift`) owns the
  slug, title, and body — a plain-language summary plus the exact recipe JSON
  in one fenced block the page can be decoded back from.
  `SQLiteStore.upsertCanonicalDemoRecipePage` publishes or updates it at
  candidate acceptance (`completeSprintTicketAcceptance`, repository-changing
  candidates with a validated recipe) idempotently: an unchanged recipe adds
  no revision, so re-acceptance after a preserved interruption cannot
  duplicate it.
- Classification (recorded in the technical design): durable domain state
  derived at acceptance; owner-visible; never read back as launch authority —
  `AcceptedAppLaunchPolicy` still reads candidate rows — and no delivery run
  may update the page directly (`KnowledgeContextSelector` excludes it from
  writable destinations).
- Inheritance: `KnowledgeContextSelector.select` always includes the
  contracted kind's canonical recipe page in the run's references; the
  delivery contract context instructs reuse, extension only for a genuinely
  new surface stated in the handoff. Delivery and tech lead guidance state
  the page is authoritative over README wording, ending the README-vs-recipe
  review ping-pong. Within a ticket's revisions the Layer 1 pin wins; the
  canonical page seeds the first turn of a new ticket.
- Tests:
  `TicketDeliveryWorkflowCoordinatorTests.acceptanceEstablishesTheCanonicalDemoRecipe`
  (acceptance publishes; resumed re-publish adds nothing; a changed recipe
  updates in place with one revision);
  `KnowledgeContextSelectorTests.canonicalDemoRecipeReachesTheContractedRun`;
  `MacOSDemoLauncherTests.inheritedCanonicalRecipeIsExecutable` — the parity
  packet's create/delete round-trip fixture run on the recipe recovered from
  the published page body, proving the inherited recipe executable in the
  real sandbox, not just well-formed.

### Layer 4 — implemented 2026-09-01

- The execution result's demo object is a discriminated union on
  `presentation.kind` whose branches mirror the validator's structural
  semantics: artifact forbids commands and takes an inert workspace-relative
  file path (the exact `DemoArtifactPolicy` allowlist, stated in the branch
  description); mac_application takes a `.app` path with null launch command,
  port, and readiness; command_output requires a launch command and no path;
  static_web takes a non-root directory with no commands, port, or readiness;
  browser requires a launch command and an HTTP readiness check with loopback
  paths beginning with `/`. Path content rules are stated in branch
  descriptions and enforced by the validator's hard-stops inside the turn's
  repair loop — deliberately not by schema `pattern` constraints, which the
  owner rejected 2026-08-29 after three live iterations showed constrained
  decoding fabricating conforming-but-false paths and mis-selecting kinds
  (bundles 20260828-151031/201302, 20260829-011325; "do not retry"). With
  Layer 2 the schema is usually narrowed to one branch, and a wrong kind now
  pauses through the contested-kind question instead of fabricating. This
  closes the kind-confusion packet's "schema anyOf" thread. The
  `CodexLifecycleGuidance` recipe shapes state the same rules and remain in
  sync.
- Tests: `DemoLaunchTests.schemaBranchShapesMirrorTheValidator` (per-branch
  structural assertions, plus a guard that no branch reintroduces a path
  `pattern`), `.perKindDecodeShapes` (legal and illegal shape per branch
  through `CodexTicketExecutor.decode`); the existing schema tests continue
  to assert the union's kind coverage per policy.
