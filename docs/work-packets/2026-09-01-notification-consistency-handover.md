# Work packet: the bell tells the truth — notification lifecycle consistency

Handover for the notification-dismissal gaps found on 2026-09-01. The audit
below is complete and cited; do not re-derive it. Implement as four small
packets in order, each independently verifiable and committable, plus one
optional cleanup packet. The owner has accepted the governing rule and the
specific semantics named here.

## Governing rule (owner-accepted)

**A row in the bell stays while a decision is owed; clicking clears only
unread updates.** Consequences:

- An owed decision (unanswered question, undecided proposal batch, ticket
  awaiting acceptance) keeps its row until the decision is made — reading,
  clicking, or launching a demo does not clear it.
- An unread update (new reply, refinement complete with nothing left to
  decide) clears when its exact source is read.
- When the awaited state ends by any route, the question notification must
  end with it. A pending question must never outlive the wait it announces.

## Problem

Two artifact systems feed the bell and badges:

- **Stored `OwnerNotification`** rows (SQLite; kinds `needs_input`,
  `refinement_complete`, `new_reply`; targets ticket/epic/conversationThread).
  Active predicate (`SQLiteStore+OwnerNotifications.swift:83-101`):
  `read_at IS NULL OR (kind='needs_input' AND resolved_at IS NULL)`.
  All eight publish sites are in planning/chat code; ticket delivery
  publishes none.
- **Derived `TicketAttention`** rows (`AppModel.swift:930-1015`): agent runs
  in `awaitingOwner`, plus work items in `.acceptance` ("Ready for demo").
  Cleared only when `refreshTicketAttentions` re-derives them.

Both have lifecycle holes. Confirmed defects, ranked:

1. **Acceptance attention is stale in both directions.** The attention cache
   refreshes only on an `awaitingOwner` transition (`AppModel.swift:5090`), a
   product switch, or relaunch. Ticket transitions into and out of
   `.acceptance` never refresh the selected product:
   `reloadSelectedProduct()` (`AppModel.swift:4420-4487`) does not touch
   `ticketAttentionsByProductID`, and `reloadSelectedProductIfCurrent`
   refreshes attentions only in its not-selected branch
   (`AppModel.swift:3716-3721`). So the "Ready for demo" row arrives late
   (finalize does `updateAgentRun(.completed)` then
   `transitionWorkItem(.acceptance)`,
   `TicketDeliveryWorkflowCoordinator.swift:3584`/`:3602`) and survives
   approving the ticket; a click on the stale row navigates to a released
   ticket (guard at `AppModel.swift:1310-1314` passes against the stale
   cache).
2. **A `needs_input` notification outlives its wait.** Only structured
   answers resolve it (ticket: `AppModel.swift:2826-2833`; epic:
   `EpicPlanningWorkflowCoordinator.swift:479`) or archival
   (`AppModel.swift:2289`, `:2476`). Every other route leaves it active
   forever: the owner answers in free text (`TicketDetailView.send:2052`, the
   board's `askQuestion`), the epic plan lands anyway
   (`generateEpicPlan` success publishes `refinement_complete` at
   `EpicPlanningWorkflowCoordinator.swift:807` without resolving), or the
   owner retries a failed plan (`retryEpicPlan:1168` never resolves the
   "Planning needs another try" row from `:873`).
3. **"Plan ready for review" dies while the decision is owed.** It is a
   one-shot `refinement_complete` cleared by opening the epic
   (`EpicDetailView.swift:190`), while deciding the proposals
   (`AppModel+EpicPlanning.swift:80-124`) touches nothing — the exact inverse
   of the governing rule, and inconsistent with ready-for-demo.
4. **Reading in the sprint work log does not count as reading.** Ticket
   notifications clear only via `TicketDetailView.swift:513`; the sprint
   ticket sheet (`SprintBoardView.swift:320`, `ContentView.swift:448-455`)
   registers no visible target, so opening a ticket from the board leaves its
   `new_reply` / `refinement_complete` rows unread.
5. Small: clicking a stale macOS system notification silently no-ops when the
   id is missing from the in-memory cache (`AppModel.swift:1305-1315`); a
   second epic plan failure publishes nothing because the retry reuses
   `session.id` and the store's conflict guard throws into a swallowed catch
   (`SQLiteStore+OwnerNotifications.swift:53-63`,
   `OwnerNotificationCoordinator.swift:288`).

## Packet A — attention freshness

**Behavior:** the "Ready for demo" (and awaiting-owner) rows appear when the
state is entered and disappear when it is left, on the selected product,
without a product switch or relaunch.

- Refresh `ticketAttentionsByProductID` whenever work-item state or run
  status changes for a product: add the refresh to
  `reloadSelectedProduct()` (or refresh attentions alongside it), and drop
  the `awaitingOwner`-only guard in `deliveryAgentRunDidUpdate`
  (`AppModel.swift:5090`) in favor of refreshing on any status change that
  can create or clear an attention.
- Keep `openOwnerNotification`'s attention guard honest: a row whose work
  item is no longer in an attention state should refresh-and-drop rather
  than navigate as attention (`AppModel.swift:1215-1222` already refreshes
  first — verify the stale-click path uses it).
- Tests: policy/store level where possible; one journey test that drives
  acceptance → approve on the selected product and asserts the attention set
  empties without a product switch (interruption + fresh-instance recovery
  per the standard shape).

## Packet B — a question never outlives its wait

**Behavior:** `needs_input` rows resolve when the awaited state ends by any
route.

- Epic: resolve the epic target's `needs_input` notifications when a plan
  generation succeeds — same place it publishes "plan ready for review"
  (`EpicPlanningWorkflowCoordinator.swift:807`), via the coordinator's
  existing resolve callback (`onResolveOwnerNotification`, wired at
  `AppModel.swift:534`). This covers the retry route and the
  answered-via-chat route.
- Ticket: resolve the ticket target's `needs_input` when the awaited run
  leaves `awaitingOwner` (`deliveryAgentRunDidUpdate`,
  `AppModel.swift:5090-5095`, already dismisses the system notification
  there) and when a refinement turn completes without questions
  (`PlanningConversationWorkflowCoordinator.swift:375`, complete branch).
- Recovery sweep: on load, retire `needs_input` rows whose wait no longer
  exists (epic has a completed undecided plan or no pending questions;
  ticket has no `awaitingOwner` run). Owner's current database has at least
  one such stuck epic row — the sweep must heal it. Make it idempotent.
- Tests: E-row journey (plan lands after retry / after chat answer → no
  active needs-input), ticket equivalent, plus fresh-instance sweep
  coverage.

## Packet C — owed decisions persist: plan ready to review

**Behavior:** an epic with an undecided suggestion batch keeps a bell row
until every proposal is decided, matching ready-for-demo.

- Derive it like acceptance attentions: an undecided batch produces a
  derived row (epic target, informational purple treatment, title like
  "<Epic> plan ready to review", summary naming the proposal count), cleared
  by deciding all proposals. Extend the tray builder
  (`OwnerNotificationTrayPresentation.make`,
  `Sources/SpeditoApp/OwnerNotificationTrayView.swift`) with this source, or
  extend the attention derivation — keep one canonical derivation path.
- The stored one-shot `refinement_complete` notification then only carries
  the banner/system delivery; the derived row carries persistence. Keep the
  suppression rule (no row when the batch's review surface is visible? No —
  the row stays until decided; only the banner suppresses).
- Update `docs/product-spec.md` §10.1 where it says unread updates clear on
  open: plan-ready now persists as an owed decision.
- Tests: pure tray-presentation tests (undecided batch → row; all decided →
  gone; partial decisions → stays), plus one journey assertion on decide-all.

## Packet D — visibility registration in the sprint work log

**Behavior:** reading a ticket anywhere counts as reading it.

- Register `setOwnerNotificationTargetVisible`/`clear...` for the ticket
  target in the sprint ticket sheet, mirroring `TicketDetailView.swift:513`
  and `:559`.
- Consider the same for the epic chat surface if any non-`EpicDetailView`
  epic surface exists (audit found none — verify).
- Tests: presentation/journey check that opening the sheet marks the ticket
  target read.

## Packet E (optional cleanup)

- Stale macOS notification click: fall back to refreshing from the store
  before the id guard in `AppModel.swift:1305-1315`, or drop the guard for
  system-notification routes and rely on `ownerNotificationTargetExists`.
- Repeat plan failures: give the retry-failure notification a fresh id or
  update-in-place so the second failure is not silently swallowed.
- Remove the dead `AppModel.resolveOwnerNotifications` (`:1187`, zero
  callers) if Packet B does not start using it.

## Non-goals

- No change to banner/callout presentation (separate packet, already
  landed: bell, tray, callout pop animation).
- No change to demo launch semantics; launching a demo intentionally does
  not clear the acceptance row.
- The Demos view intentionally lists only accepted versions; a pending demo
  is launched from the board card. Surfacing pending demos in the Demos view
  is an open product question for the owner, not part of this packet.
- No general notification history.

## Verification (every packet)

- [ ] Focused new tests at the owning boundary (policy / store / journey)
- [ ] Interruption and fresh-instance recovery where durable state changes
- [ ] Full suite: `swift test -Xswiftc -warnings-as-errors` (use a
      dedicated `--scratch-path`; see build-lock note below)
- [ ] `git diff --check`
- [ ] `./scripts/check_architecture_ratchets.sh`
- [ ] Relaunch via `./scripts/relaunch.sh`, leave running for inspection
- [ ] Launched-process suite only if shell wiring changes; the affected
      contract is `EpicOwnerNotificationUITests` (E02). Note: a 2026-08-31
      attempt failed with "Authentication cancelled" — the UI-testing
      automation prompt needs the owner present.

## Working notes

- Concurrent sessions contend on the repo `.build`; validate with
  `--scratch-path .build-<name>` and matching module-cache env vars.
- The tree carries several unrelated uncommitted packets; preserve them.
- Journey ledger: update the C-rows in
  `docs/architecture/owner-journey-test-plan.md` for new coverage, and keep
  the feature navigation map row ("Chat and notifications") accurate if
  ownership moves.

## Completion evidence

Record exact commands and observed results per packet before starting the
next one.

### Packet A — implemented 2026-09-01

- `reloadSelectedProduct()` now ends by refreshing the selected product's
  ticket attentions, so every delivery reload (finalize into acceptance at
  `TicketDeliveryWorkflowCoordinator.swift:3610`, approval at `:4087`) keeps
  the cache fresh; `deliveryAgentRunDidUpdate` reloads on any status change
  and refreshes attentions on same-status `awaitingOwner` updates.
- Stale clicks now refresh-and-drop: `openTicketAttention(_:)`,
  `openTicketAttentions(for:)`, and attention-matched
  `openOwnerNotification` re-check the refreshed cache after reload.
- Tests: `TicketAttentionTests` "Acceptance entry and approval keep
  selected-product attention fresh without a product switch" (includes
  fresh-instance recovery) and "A stale ready-for-demo click refreshes and
  drops instead of navigating".
- Verified: focused suite green; full suite green (shared with Packet B run
  below); `git diff --check` clean; ratchets pass after the baseline raise
  recorded below.

### Packet B — implemented 2026-09-01

- Live resolves: epic plan success resolves the epic's `needs_input`
  (`EpicPlanningWorkflowCoordinator`, before publishing plan-ready); a run
  leaving `awaitingOwner` resolves the ticket target
  (`AppModel.deliveryAgentRunDidUpdate`, now using the previously dead
  `resolveOwnerNotifications`); a refinement completing without questions
  resolves the ticket target (`PlanningConversationWorkflowCoordinator`, new
  `onResolveOwnerNotification` callback wired in `AppModel`).
- Recovery sweep: `OwnerNotificationCoordinator.load` retires `needs_input`
  rows whose wait ended, per the new pure policy
  `OwnerNotificationRecoveryPolicy`
  (`Sources/SpeditoCore/Domain/OwnerNotificationRecovery.swift`). Idempotent;
  heals the stuck epic row scenario (completed plan, no pending questions).
- Deviations from the packet text, deliberate:
  - The ticket sweep predicate is not the bare "no `awaitingOwner` run":
    stored ticket `needs_input` rows come only from refinement questions,
    which have no run, so the bare predicate would retire every genuinely
    pending question on launch. The policy keeps a row while an agent
    question in the work log has no later owner reply.
  - The Packet E "fresh id for retry-failure rows" fix moved into this
    packet: the failure row reused `session.id`, so the success
    `refinement_complete` publish for a retried session collided and was
    silently swallowed — the resolve alone could not deliver "plan ready
    for review" after a retry.
  - `TicketAttentionTests` C08/C11 fixtures now create real waits (work item
    with an unanswered question; epic with pending durable questions)
    because the sweep correctly retires rows whose target has no wait.
- Tests: `OwnerNotificationRecoveryPolicyTests` (pure matrix), E08 extended
  (sweep keeps the retry row on relaunch; retry success leaves only
  plan-ready), `CodexTransportApplicationTests` "A refinement that completes
  without questions resolves the ticket question", `TicketAttentionTests`
  run-leaves-awaitingOwner and load-sweep idempotence tests.

### Packet C — implemented 2026-09-01

- `EpicPlanReviewAttention` (derived, in `OwnerNotificationCoordinator.swift`
  beside `TicketAttention`) produces one bell row per epic with an undecided
  ready batch: purple plan-ready treatment, proposal count summary, cleared
  only by deciding every proposal. Derivation shares the single canonical
  attention path (`AppModel.fetchOwnerAttention` /
  `refreshOwnerAttentionState` / `refreshTicketAttentions`), so every reload
  and refresh keeps it fresh.
- The tray builder takes the new source; a plan-review row covers its epic
  target so the stored one-shot plan-ready row only carries banner and macOS
  delivery. `openOwnerNotification` accepts and re-checks derived plan-review
  rows like ticket attentions (stale click refreshes and drops).
- `docs/product-spec.md` §10.1 updated: plan-ready persists as an owed
  decision; the needs-input lifecycle and launch sweep are documented.
- Tests: `OwnerNotificationTrayPresentationTests` (undecided → row;
  partial → stays; decided/archived → gone; covers stored row), E10 journey
  assertions (row present after reload, survives interrupted decide, clears
  on accept-all and reject-all without a product switch).

### Packet D — implemented 2026-09-01

- `SprintTicketDetailView` now registers
  `setOwnerNotificationTargetVisible`/`clearOwnerNotificationTargetVisible`
  for its ticket target, mirroring `TicketDetailView`. This covers both
  presentation routes (board sheet and `ContentView` delivery-mode sheet).
- Audit confirmed: no epic conversation surface exists outside
  `EpicDetailView`, which already registers.
- Tests: `TicketAttentionTests` "Making a ticket target visible marks its
  pending updates read" proves the model boundary the sheet calls. The
  SwiftUI wiring itself is a shell contract; the launched-process E02-family
  run stays pending until the owner is present for the automation prompt
  (2026-08-31 attempt failed with "Authentication cancelled").

### Packet E — implemented 2026-09-01

- Stale macOS notification clicks: `openOwnerNotification` refreshes the
  product's notification and attention caches from the store before the id
  guard, so a click that arrives before the caches load (or after they fall
  behind) routes instead of silently no-opping. Test:
  `TicketAttentionTests` "A system notification click refreshes stale caches
  before deciding".
- Repeat plan failures: fixed in Packet B (failure rows take a fresh id).
- `AppModel.resolveOwnerNotifications` is no longer dead: Packet B's
  delivery-run resolve uses it, so it stays.

### Verification summary — 2026-09-01

- Full suite after Packets A and B:
  `swift test -Xswiftc -warnings-as-errors` (with `--scratch-path
  .build-notify` and matching cache env vars) — 708 tests in 75 suites,
  all passed.
- Full suite after Packets C, D, and E: same command — 715 tests in 75
  suites, all passed.
- `git diff --check` clean; `./scripts/check_architecture_ratchets.sh`
  matches all 6 baselines (raises recorded below).
- Relaunch deferred: the app is live from a peer session's rebuild with an
  active Codex delivery server and a running demo preview app, so a
  relaunch would kill an active agent turn. The next shared-tree relaunch
  picks these packets up.
- Launched-process suite not run: the view changes (sprint sheet
  visibility, tray source) await the owner-present E02-family run noted in
  Verification above.
- Re-verified later on 2026-09-01, after three unrelated commits landed on
  the shared tree: same full-suite command — 717 tests in 75 suites, all
  passed; `git diff --check` clean; ratchets match all 6 baselines. Relaunch
  still deferred for the same reason (active Codex delivery server, running
  demo preview app, pilot T1 approval pending).

### Ratchet baseline raises (this handover)

- `app_model_lines` 5175 → 5199 (Packets A and B) → 5243 (Packet C) → 5258
  (Packet E stale-click refresh fallback). The
  growth is routing and composition within `AppModel`'s contract: attention
  refresh in `reloadSelectedProduct`, honest stale-click re-checks, resolve
  wiring, and the shared owner-attention derivation. No new workflow state,
  task handles, or recovery rules were added to `AppModel`.
- `app_model_published` 32 → 33 (Packet C): `epicPlanReviewsByProductID`, a
  bounded derived presentation cache mirroring
  `ticketAttentionsByProductID`, rebuilt from durable state on every
  refresh.
- `app_model_try_optional` stays at 27: the new derivation reuses the
  existing one-`try?`-per-refresh-site pattern.
