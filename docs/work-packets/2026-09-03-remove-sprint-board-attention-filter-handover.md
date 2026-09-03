# Work packet: remove the product-library attention routing and the sprint-board "need your attention" filter

Owner decision (2026-09-03): remove this functionality. It predates the
notification bell and tray, which now carry every owner-attention target with
a direct route to the exact ticket, epic, or thread. The product library keeps
its counts and "N need your attention" labels; opening a product from the
library only selects it.

This handover is for a fresh session. Everything below was read from commit
`897e4af` on `pilot`; line numbers refer to that commit. When it was written
the tree also held unrelated uncommitted work (diff syntax highlighting in
`CodebaseView.swift`, a header bell alignment packet, and one hunk at
`SprintBoardView.swift:5974`); none of it touches the ranges cited here, but
start from an explicitly understood tree and keep that work intact.

## Problem

Opening a product from the product library while it has attention targets does
not simply open the product. `ProductLibraryView.openSelectedProduct` calls
`AppModel.openOwnerAttentions(for:)`, which:

- with one target, opens that ticket, epic, or thread directly; or
- with several ticket targets and no active bell notification, navigates to
  the sprint board and publishes a `TicketAttentionNavigationRequest` whose
  `workItemIDs` become `ContentView.attentionWorkItemIDs`. The board then
  renders only those tickets and shows an orange "N need your attention" chip
  whose only action is to clear the filter.

Observed on 2026-09-03 in Native Weather App (product
`9F5ADA0D-15E4-47ED-A91E-8EE33DFC1FFD`): T1 (run awaiting a command approval)
and T2 (ready for demo) were shown; T3 (ready to pick) was hidden until the
chip was clicked. The chip reads as a status badge, not a filter, so the owner
believed T3 was missing. The bell tray already lists T1 and T2 with direct
routes, so the filter duplicates the tray with a worse presentation.

## Behavior to preserve or add

- Opening a product from the product library (row double-click or **Open**)
  selects it and restores its last workspace destination. Nothing else.
- The sprint board always shows every ticket in the selected sprint. No chip,
  no filter.
- The product library still sorts products with attention first and still
  shows the "N need your attention" label with orange/purple treatment.
- The product switcher count in the sidebar is unchanged.
- The bell tray, in-app banner, and macOS notification click keep routing to
  the exact target through `AppModel.openOwnerNotification` and
  `OwnerNotificationNavigationRequest`. This path does not use anything
  removed here (verified: `openOwnerNotification(notificationID:productID:target:)`
  publishes `ownerNotificationNavigationRequest`, AppModel.swift:1410).

## Non-goals

- No change to how attention is derived (`fetchTicketAttentions`,
  `ticketAttentionsByProductID`, `ownerAttentionCount`,
  `ownerAttentionRequiresAction`).
- No change to the bell tray, banner, sound policy, or notification
  persistence.
- No change to ticket detail presentation or to sprint selection.

## Scope decision already taken

Remove the single-target shortcut too, not only the multi-ticket filter. Both
live in `openOwnerAttentions(for:)`, both are described in the same product
spec paragraph, and the bell already covers the single-target route (journey
proofs D03, C09, C10). If the owner reverses this and wants to keep the
single-target shortcut, keep `openOwnerAttentions(for:)` and
`openTicketAttention(_:)` and remove only `openTicketAttentions(for:)`, the
`workItemIDs` field, and the board filter; the rest of this packet still
applies.

## Current authority

- Durable state: none. Nothing about the filter is persisted.
- Task owner: none. `openOwnerAttentions` is a one-shot async routine on
  `AppModel`.
- Presentation state: `ContentView.attentionWorkItemIDs: Set<UUID>?` bound
  into `SprintBoardView`; `AppModel.ticketAttentionNavigationRequest`
  (`@Published`, transient one-shot request).
- Known duplicate state: the filter set duplicates
  `ticketAttentionsByProductID` for the selected product, which the bell tray
  already presents.

## Target authority

- Coordinator: none. This packet deletes a path; it introduces nothing.
- Commands: none.
- Snapshot: none.
- Persistence operations: none.
- View boundary: `SprintBoardView` no longer takes an attention binding.
  `ProductLibraryView.openSelectedProduct` calls only `reloadSelectedProduct`
  (same product) or `selectProduct` (other product).

## State table

| State | Entered by | Durable evidence | Owner sees | Available actions | Recovery |
| --- | --- | --- | --- | --- | --- |
| Product opened from library | Row double-click or **Open** | Selected product ID in defaults (existing A03/A05 behavior) | Product's last workspace destination, unfiltered | Everything the destination offers; bell tray for attention | Existing A05 relaunch restore |

No new intermediate state. No `Shell = Y` change: B02 keeps its existing
launched-process contract (see verification).

## Call sites to migrate (delete unless stated)

Application code:

- [x] `Sources/SpeditoApp/SprintBoardView.swift`
  - line 51: `@Binding var attentionWorkItemIDs: Set<UUID>?` — remove.
  - lines 79–96: the orange chip `if let attentionWorkItemIDs` block inside the title `HStack` — remove.
  - lines 245–247: `displayedItemIDs` — remove; pass `planItemIDs` to
    `boardItems(for:plan:itemIDs:)` and `boardPositionSignature(itemIDs:)`.
  - line 405 in `selectSprint(_:)`: `attentionWorkItemIDs = nil` — remove.
- [x] `Sources/SpeditoApp/ContentView.swift`
  - line 233: `@State private var attentionWorkItemIDs` — remove.
  - line 260: `attentionWorkItemIDs: $attentionWorkItemIDs,` — remove from
    the `SprintBoardView` call.
  - lines 298–300 in `.onAppear`: the `ticketAttentionNavigationRequest`
    replay — remove. Keep the `ownerNotificationNavigationRequest` replay.
  - line 313 in `.onChange(of: model.selectedProductID)`: remove the
    `attentionWorkItemIDs = nil` line.
  - lines 329–333: `.onChange(of: model.ticketAttentionNavigationRequest)` —
    remove the whole modifier.
  - lines 417–436: `handleAttentionNavigationRequest(_:)` — remove.
  - lines 426 and 454: `attentionWorkItemIDs = nil` inside
    `handleOwnerNotificationNavigationRequest` — remove those lines only; the
    rest of that function stays.
- [x] `Sources/SpeditoApp/AppModel.swift`
  - line 184: `@Published private(set) var ticketAttentionNavigationRequest`
    — remove.
  - lines 1227–1247: `openTicketAttention(_ attention:)` — remove.
  - lines 1249–1256: `openTicketAttention(productID:workItemID:)` — remove
    (no callers outside this file).
  - lines 1258–1274: `openTicketAttentions(for:)` — remove.
  - lines 1276–1311: `openOwnerAttentions(for:)` — remove.
  - lines 1313–1316: `consumeTicketAttentionNavigationRequest(id:)` — remove.
  - Keep `ownerAttentionCount(for:)`, `ownerAttentionCount(excluding:)`,
    `ownerAttentionRequiresAction(productID:)`, and
    `ownerAttentionTargets(productID:)` (lines 1162–1191); the library rows
    and sidebar count still use them.
- [x] `Sources/SpeditoApp/OwnerNotificationCoordinator.swift`
  - lines 18–24: `struct TicketAttentionNavigationRequest` — remove.
- [x] `Sources/SpeditoApp/ProductLibraryView.swift`
  - lines 304–317 `openSelectedProduct()`: drop the
    `else if model.ownerAttentionCount(for:) > 0 { openOwnerAttentions }`
    branch so the body is: same product → `reloadSelectedProduct()`, otherwise
    → `selectProduct(selectedProduct)`.

Tests (`Tests/SpeditoAppTests/TicketAttentionTests.swift`):

- [x] "Opening one attention request selects its product and targets its
  ticket" (line 136): keep the first half that drives `openOwnerNotification`
  and asserts `ownerNotificationNavigationRequest`; delete everything from
  `await model.openTicketAttentions(for: sourceProduct)` (line 180) to the
  `multipleRequest` assertions (line 206), including the second work item.
- [x] "A single background result routes from the product attention count"
  (line 578): it exists only to prove `openOwnerAttentions`. Delete it. C10
  (`notificationRouteRoundTrips`) and the tray route already prove that an
  epic result routes to its target.
- [x] "B02 closing an incomplete Ticket can return from another Product to
  that Ticket" (line 625): rewrite the navigation half in the D03 shape
  (line 765). After `selectProduct(otherProduct)`, build
  `OwnerNotificationPresentation(attention:)` from
  `model.ticketAttentionsByProductID[sourceProduct.id]`, call
  `openOwnerNotification(OwnerNotificationRoute(userInfo:))`, and assert
  `selectedProductID == sourceProduct.id`,
  `ownerNotificationNavigationRequest.target == .ticket(item.id)`, and the
  durable state is still `.refining`. Keep the test name so the journey row
  stays valid.
- [x] "A stale ready-for-demo click refreshes and drops instead of
  navigating" (line 974): delete the single line
  `#expect(model.ticketAttentionNavigationRequest == nil)` (line 1019). The
  remaining two expectations are the contract.

Documents:

- [x] `docs/product-spec.md` lines 1740–1744: replace
  "Opening a different product with one target opens that exact ticket, epic,
  or Chat thread. Opening one with several targets selects the product and
  leaves its workspace and row indicators visible; the existing
  multiple-ticket **Needs your input** filter remains available when every
  target is an active sprint ticket." with one sentence: opening a product
  from the library selects it and restores its last workspace destination; the
  notification bell is the route to each attention target. Keep the last
  sentence about labels clearing.
- [x] `docs/technical-design.md` lines 1301–1302: delete "Product-library
  navigation opens a single attention ticket directly or publishes a
  multi-ticket sprint-board filter."
- [x] `docs/architecture/owner-journey-test-plan.md` line 112 (B02 row): the
  proof text becomes "the deterministic journey routes the bell notification
  for cross-Product attention to the exact editable ticket; the launched-process
  contract proves the source-Product switch and ticket sheet." Test names are
  unchanged.
- [x] `scripts/architecture_ratchets.baseline`: `app_model_published` drops
  from 33 to 32 (exact metric, must be lowered). `app_model_lines` (5219) and
  `content_view_lines` (481) will drop by more than the 25-line allowance;
  record the new counts after the edit.

## Obsolete state to remove

- [x] `ContentView.attentionWorkItemIDs`
- [x] `SprintBoardView.attentionWorkItemIDs`
- [x] `AppModel.ticketAttentionNavigationRequest`
- [x] `TicketAttentionNavigationRequest`
- [x] `AppModel.openOwnerAttentions`, `openTicketAttentions`,
  `openTicketAttention` (both overloads),
  `consumeTicketAttentionNavigationRequest`

After the edit, `rg -n "attentionWorkItemIDs|TicketAttentionNavigationRequest|openTicketAttention|openOwnerAttentions|ticketAttentionNavigationRequest" Sources Tests docs`
must return nothing outside this packet.

## Verification

- [x] Focused: `swift test --filter TicketAttentionTests` and
  `swift test --filter SprintBoardSelectionTests`.
- [x] Full default validation:

  ```sh
  env \
    SWIFT_MODULECACHE_PATH="$PWD/.build/module-cache" \
    CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache" \
    swift test -Xswiftc -warnings-as-errors
  git diff --check
  ./scripts/check_architecture_ratchets.sh
  ```

- [ ] Launched-process contracts. This packet touches `ContentView.swift`,
  `SprintBoardView.swift`, and `ProductLibraryView.swift`, so the affected
  shell contracts must run. Only when the owner is idle (the suite seizes the
  GUI):

  ```sh
  ./scripts/run_ui_tests.sh \
    -only-testing:SpeditoUITests/PriorityZeroShellJourneyUITests/testB02ClosingIncompleteTicketReturnsToExactSourceTicket \
    -only-testing:SpeditoUITests/PriorityZeroShellJourneyUITests/testA06ArchivingSelectedProductRoutesToRemainingProduct \
    -only-testing:SpeditoUITests/PriorityZeroShellJourneyUITests/testA05RelaunchRestoresProductDestinationAndSprint
  ```

  B02 should pass unchanged: its fixture (`UIFixtureRuntime.swift:164`) has
  no awaiting-owner run, and the test switches product through the library
  and then clicks the ticket row itself. If it fails, the failure is a real
  shell defect in the new `openSelectedProduct`, not a fixture assumption.
- [x] Interruption and fresh-instance recovery: not applicable; no durable
  state is added or changed. Say so in the handoff.
- [ ] `./scripts/relaunch.sh`, left running.
- [ ] Product-owner inspection, in the relaunched app, with Native Weather App
  (`9F5ADA0D…`) still holding T1 awaiting a command approval and T2 ready for
  demo:
  1. Open the product library. Native Weather App still shows its orange
     attention label when another product is selected.
  2. Open Native Weather App. The sprint board shows T1, T2, and T3 with no
     orange chip in the title row.
  3. Open the bell. T1 (command approval) and T2 (ready for demo) are listed;
     opening each lands on that ticket.
  4. Switch to another product and back. The board is still unfiltered.

## Completion evidence

Implemented 2026-09-03 on branch `claude/remove-sprint-attention-filter-519698`
(worktree off `main` at `dbba5a8`, whose tree is identical to `897e4af`).

- Focused: `swift test -Xswiftc -warnings-as-errors --filter 'TicketAttentionTests|SprintBoardSelectionTests'`
  → 25 tests in 2 suites passed ("Cross-product ticket attention", "Sprint board
  selection"), 22:17 local.
- Full: `swift test -Xswiftc -warnings-as-errors` with the worktree module
  caches → 766 tests in 79 suites passed, exit 0.
- `git diff --check` → clean.
- `./scripts/check_architecture_ratchets.sh` → "Architecture ratchets match all
  6 baselines" after lowering `app_model_lines` 5219→5127,
  `content_view_lines` 481→434, `app_model_published` 33→32.
- Residual grep: the only hits for the removed names are in the dated record
  `docs/work-packets/2026-09-01-notification-consistency-handover.md`, left
  unchanged as history.
- Interruption and fresh-instance recovery: not applicable; no durable state
  was added or changed.
- Launched-process contracts (B02, A06, A05): **not run.** Cristian was active
  at the keyboard (HID idle under 2 s) and the automation authorisation is still
  unresolved; run the command above when free. CI remains the backstop.
- Relaunch: **not run.** The running debug Spedito owned a live Codex
  delivery session (app-server child with the delivery profile), which
  `./scripts/relaunch.sh` would kill. Run it from this worktree when that turn
  has settled.
- Owner inspection: pending the relaunch.
- Commit: not made; the packet is uncommitted on the branch above.
