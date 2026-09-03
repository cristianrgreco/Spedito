# Work packet: the notification bell aligns with the title row on every workspace view

Owner decision (2026-09-03): the bell looks right on Backlog, Retrospectives,
Reports, Codebase, Chat, and Demos, and wrong on Product and Sprint board. The
owner reviewed a before-and-after mockup of the fix below and accepted it.
This handover is for a fresh session. Implement it as one packet, verify it,
relaunch, and commit. Do not widen it.

## Problem

`workspaceHeaderLayout()` in `Sources/SpeditoApp/WorkspaceHeaderLayout.swift`
places every view's whole header block and the bell side by side in an
`HStack(alignment: .center)`. The bell therefore centres on whatever height
the header block has.

- On the six views that look right, the header block is one title row:
  title and subtitle on the left, controls on the right. The bell centres on
  that two-line block and sits level with the trailing controls.
- **Product** (`KnowledgeBaseView.swift:145-193`) adds a third row. The Ask
  field lives inside `header`, so the block is about twice as tall and the
  bell lands between the New page button and the Ask field. The Ask field
  also stops short of the bell column instead of reaching the content edge.
- **Sprint board** (`SprintBoardView.swift:100-225`) has a two-row trailing
  `VStack(alignment: .trailing, spacing: 8)`: the sprint picker and
  pause/stop/start actions on top, `SprintBoardGoalView` underneath. The bell
  centres between those rows.

## Behavior to preserve or add

Target geometry, identical on every workspace view:

```text
┌ 24pt padding ─────────────────────────────────────────────────────┐
│ Title                                     [trailing controls] (🔔) │  ← bell centred on
│ Subtitle                                                           │    this two-line row
│                                                                    │
│ [optional full-width row: Ask field / sprint goal]                 │  ← 12pt below the row
└────────────────────────────────────────────────────────────────────┘
  Divider
```

- The bell keeps its size, badge, hover, tray popover, accessibility
  identifier `owner-notification.bell`, and its anchor preference. The banner
  callout still points at it.
- Product: the Ask field moves under the title row and spans the full header
  width, so its right edge lines up with the bell's right edge. It keeps
  `knowledge.ask`, its placeholder, clear button, progress indicator, submit
  behaviour, and its `isAskingKnowledge` disabling. It stays enabled during a
  repository knowledge run; only the title row is disabled by
  `repositoryKnowledgeIsRunning` today (line 163), and that must not change.
- Sprint board: the pause, resume, stop, report, retrospective, review plan,
  and start controls, the sprint picker, and the divider between them stay on
  the title row, level with the bell. The sprint goal line moves under the
  title row, right-aligned to the content edge, keeping its flag icon, single
  line, 420pt maximum width, help text, accessibility label and value, and
  the goal-generation triggers inside `SprintBoardGoalView`.
- Backlog, Retrospectives, Reports, Codebase, Chat, and Demos render
  pixel-identically to today.

## Non-goals

- Do not move the bell into window chrome (a `ContentView` overlay). That
  alternative was considered and not chosen: the owner wants the bell to
  read as a page control in the same spot it already occupies on Backlog.
- Do not change `OwnerNotificationBellView`, the tray, the banner, the
  callout arrow, or `OwnerNotificationBannerOverlay`.
- Do not change goal generation, sprint state actions, or knowledge
  questions.
- Do not restyle any header while you are in there.

## Current authority

- Durable state: none. This packet is presentation only.
- Task owner: unchanged. `SprintBoardGoalView` owns its generation trigger
  through `.onAppear` and `.onChange`; keep it in the view tree whenever a
  plan is selected so those triggers still fire.
- Presentation state: `workspaceHeaderLayout()` and the two view headers.
- Known duplicate state: none.

## Target authority

- Coordinator: not applicable.
- View boundary: `WorkspaceHeaderLayout.swift` gains a second slot for
  content that belongs under the title row.

```swift
extension View {
  func workspaceHeaderLayout<Below: View>(
    @ViewBuilder below: () -> Below = { EmptyView() }
  ) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .center, spacing: 16) {
        frame(maxWidth: .infinity, alignment: .leading)
        OwnerNotificationBellView()
      }
      below()
    }
    .padding(24)
  }
}
```

`EmptyView` does not take a layout slot, so the six unchanged call sites keep
their exact geometry with no extra 12pt gap. Confirm that in the relaunch on
Backlog (the divider must not move). If it does move, use two overloads (a
no-argument one that keeps today's body, and the generic one) instead of a
default argument, and keep one shared padding value between them.

The 12pt spacing is the one shared value for the below-row gap. Product uses
12 today; Sprint board uses 8. Both adopt 12 so the geometry is shared, per
the reuse rule in `CLAUDE.md`.

## State table

Not applicable: no durable or transient state is introduced or moved.

## Call sites to migrate

- [x] `Sources/SpeditoApp/WorkspaceHeaderLayout.swift`: add the `below` slot
      as above and update the doc comment to say the bell aligns with the
      title row and extra rows go in `below`.
- [x] `Sources/SpeditoApp/KnowledgeBaseView.swift:85`: call
      `header.workspaceHeaderLayout { askField }`. Split `header` (145-193)
      so it holds only the title `HStack` (147-163, including its
      `.disabled(repositoryKnowledgeIsRunning)`), and move the Ask `HStack`
      (165-191) into a new private `askField` view. Remove the outer
      `VStack(alignment: .leading, spacing: 12)` that wrapped both.
- [x] `Sources/SpeditoApp/SprintBoardView.swift:100-226`: replace the trailing
      `VStack(alignment: .trailing, spacing: 8)` with its inner actions
      `HStack(spacing: 0)` so the picker, divider, and action buttons sit
      directly in the title row. Move the `if let plan = selectedPlan {
      SprintBoardGoalView(plan: plan) }` block into the `below` slot with
      `.frame(maxWidth: .infinity, alignment: .trailing)` so it right-aligns
      to the content edge. Keep `SprintBoardGoalView` unchanged.
- [x] Leave `BacklogView.swift:375`, `RetrospectivesView.swift:33`,
      `ReportsView.swift:28`, `CodebaseView.swift:202`,
      `ProductConversationView.swift:56`, and `AppVersionsView.swift:119`
      untouched. They pick up the default empty slot.

## Obsolete state to remove

- [x] The outer `VStack` in `KnowledgeBaseView.header`.
- [x] The trailing `VStack` in the Sprint board header.

Nothing else is removed.

## Documentation

- `docs/product-spec.md:1780` says the bell "sits at the top right of every
  workspace view". That stays true. No spec change is needed.
- `docs/architecture/owner-journey-test-plan.md`: no new journey and no
  `Shell` designation change. The packet does not add a durable state or a
  long-running operation.

## Verification

This change touches view files under `Sources/SpeditoApp`, so the affected
launched-process contracts are required in addition to the default checks.
Run the launched-process tests only while the owner is not using the Mac;
they drive the shared GUI session.

- [x] Default validation:

  ```sh
  env \
    SWIFT_MODULECACHE_PATH="$PWD/.build/module-cache" \
    CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache" \
    swift test -Xswiftc -warnings-as-errors
  git diff --check
  ./scripts/check_architecture_ratchets.sh
  ```

  `ContentView.swift` and `AppModel.swift` are untouched, so
  `scripts/architecture_ratchets.baseline` must not change.

- [ ] Affected launched-process contracts, one at a time through the mutex:

  ```sh
  ./scripts/run_ui_tests.sh \
    -only-testing:SpeditoUITests/PriorityZeroShellJourneyUITests/testK05GroundedAnswerOpensItsExactCitedKnowledgePage
  ```

  ```sh
  ./scripts/run_ui_tests.sh \
    -only-testing:SpeditoUITests/PriorityZeroShellJourneyUITests/testA02BlankProductLaunchesItsCompleteWorkspace
  ```

  ```sh
  ./scripts/run_ui_tests.sh \
    -only-testing:SpeditoUITests/EpicOwnerNotificationUITests/testE02NeedsInputOpensTheExactEpicAcrossProducts
  ```

  K05 proves `knowledge.ask` is still found, enabled, and submits from its
  new position. A02 proves the Sprint board still renders `sprint.board`.
  E02 proves the banner callout still anchors to the bell.

- [x] No new deterministic test. There is no new observable contract: the
      helper is layout only, and SwiftUI geometry is not asserted in this
      repository's policy or coordinator suites.

- [x] Relaunch with `./scripts/relaunch.sh` and leave the app running.

- [ ] Owner inspection script, in light and dark appearance, at a 14-inch
      window width and at full width:
  1. Product: the bell is level with New page and centred on the title
     block. The Ask field sits below and its right edge matches the bell's
     right edge. Type a question and press Return; the answer sheet opens.
  2. Sprint board with an active sprint that has a goal: the bell is level
     with pause and stop. The goal line sits below, right-aligned to the
     content edge, on one line. Repeat with a paused sprint, a completed
     sprint (report and retrospective buttons), and a draft plan (review plan
     and start). With more than one sprint, the picker and its divider stay
     on the title row.
  3. Sprint board with no goal yet: the header collapses to the title row
     with no empty gap underneath.
  4. Backlog, Retrospectives, Reports, Codebase, Chat, and Demos: unchanged.
     Check the divider position against Product and Sprint board; the title
     row must sit at the same height on all eight views.
  5. Trigger any owner notification (a chat reply is enough). The callout
     pops out of the bell with its arrow on the bell, on Product and on
     Sprint board.

## Commit

Start from a clean tree on a branch off `main`. One commit, for example
"Align the notification bell with the workspace title row". No attribution
line in the message.

## Completion evidence

Implemented 2026-09-03 on branch `claude/workspace-header-bell-alignment-112829`
from a clean tree at `dbba5a8`.

Default validation, run from the worktree:

```sh
env \
  SWIFT_MODULECACHE_PATH="$PWD/.build/module-cache" \
  CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache" \
  swift test -Xswiftc -warnings-as-errors
```

Result: `Test run with 767 tests in 79 suites passed after 40.926 seconds`,
exit 0. The Codex sandbox profile contract suite ran against the runtime the
app resolves through Launch Services,
`/Applications/Codex.app/Contents/Resources/codex` (codex-cli 0.152.1).

`git diff --check`: clean.

`./scripts/check_architecture_ratchets.sh`: `Architecture ratchets match all
6 baselines.` `scripts/architecture_ratchets.baseline` is unchanged.

`./scripts/build_app.sh debug` with the resolved GitHub App configuration:
built and signed `.build/app/debug/Spedito.app` from this worktree with
warnings as errors, so the relaunch only has to kill and launch.

Headless geometry check: an `NSHostingView.fittingSize` probe of the helper's
exact shape with a stand-in bell, 900pt wide, compiled with `swiftc` in the
session scratchpad, no window shown.

| Header | Height |
| --- | --- |
| Previous `HStack` helper | 99pt |
| New helper, default empty slot | 99pt |
| New helper, no selected plan | 99pt |
| New helper, selected plan with an empty goal | 99pt |
| New helper, one-line goal | 126pt |

The default `EmptyView` slot takes no layout slot and adds no 12pt gap, so
the six unchanged views keep their geometry and the two-overload fallback is
not needed. A selected plan with no goal collapses to the title row, which
covers inspection step 3.

Launched-process contracts (K05, A02, E02): not run. The owner was at the
keyboard throughout (HID idle time 0 to 1 seconds at 22:16 and 22:18), and
the suite seizes the GUI session. They remain pending, one at a time through
the mutex, with CI as the backstop.

Relaunch: not run for the same reason. The debug app was running, launched
from the main checkout about two minutes earlier with a live Codex app-server
child, and the relaunch kills it. Run `./scripts/relaunch.sh` from this
worktree when convenient.

Owner inspection: pending the relaunch.

## Owner inspection feedback and follow-up (2026-09-03)

The owner inspected the relaunched build and reported two defects:

1. Product: the bell was not level with New page. The title row used
   `HStack(alignment: .firstTextBaseline)`, so the button rode the title's
   baseline while the bell centred on the two-line block.
2. Sprint board: the header was too tall with a goal. The owner asked for the
   goal inline on the left instead of a row below, and after a second look
   asked for it to the right of the phase pill.

Changes, superseding the "Behavior to preserve or add" section for the goal:

- `KnowledgeBaseView.header` aligns its title row `.center`, matching
  Backlog, Codebase, Retrospectives, and Demos.
- `SprintBoardView` renders `SprintBoardGoalView` inside the title
  `HStack(spacing: 9)` after the phase pill, and calls
  `.workspaceHeaderLayout()` with the default empty slot.
- `SprintBoardGoalView` drops the 420pt trailing frame, which would expand
  and push the pill right, and takes `.layoutPriority(-1)` so a long goal
  truncates before the title when the row is narrow. Flag icon, single line,
  help text, accessibility label and value, and generation triggers are
  unchanged.
- The helper's doc comment names the Product ask field as the `below` user.

Evidence:

- `swift test -Xswiftc -warnings-as-errors`: `Test run with 767 tests in 79
  suites passed after 30.399 seconds`, exit 0.
- `git diff --check`: clean. Ratchets: `match all 6 baselines`.
- Headless `NSHostingView.fittingSize` probe of the title row shape:

  | Row | Size |
  | --- | --- |
  | Title and pill, no goal | 213 × 31 |
  | With a short goal | 311 × 31, exactly the goal's own 89pt plus spacing |
  | With a 1,170pt goal, unconstrained | 1383 × 31 |
  | With that goal at 420pt | 420 × 31, one line, same height as no goal |

  So the goal never expands past its text, and it truncates rather than
  wrapping or raising the row.

Pending: K05, A02, and E02 launched-process runs, and owner inspection of
Product and Sprint board.
