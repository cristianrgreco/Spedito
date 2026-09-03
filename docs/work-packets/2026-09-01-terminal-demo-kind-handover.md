# Work packet: Terminal app demos — a sixth demo kind that opens the reviewed program in Terminal

This handover is terminal. Finish every layer, every acceptance step, and
every document in this packet. Do not create a further handover, defer a
decision, leave a "follow-up lever" note, or propose follow-up work of any
kind. Every decision is made below. If live evidence materially contradicts a
decision in this document, stop and ask the product owner; do not park the
conflict in a new document.

It deliberately reverses the "No new demo kinds" non-goal recorded in
`2026-09-01-demo-contract-root-cause-handover.md` (line 113),
`2026-09-01-demo-contract-completion-handover.md` (line 200),
`2026-08-28-eval-decision-handover.md` (line 54), and
`2026-08-28-planner-escape-and-demo-path-handover.md` (line 92). Those packets
are complete; their behaviour is preserved and extended, never weakened.

## Problem

Spedito has five demo presentation kinds: `browser`, `static_web`,
`mac_application`, `artifact`, and `command_output`, plus the ticket-level
`none`. None of them lets the product owner drive an interactive terminal
program. `command_output` runs a bounded command and shows captured text; it
cannot present a TUI.

Live evidence (product **Battersea Dogs Availability TUI**, workspace
`D7E8B85A-2E89-48F9-934B-0DFAE605380C`, 2026-09-01):

- The epic goal and constraints say "Go terminal application". The
  clarification round asked only about data-source access.
- The planner stored `demo_kind = mac_application` on T2 (setup) and T4
  (story). The mechanical rule in
  `Sources/SpeditoCore/Codex/CodexTicketSuggestionGenerator.swift:64–68` and
  the schema description at `:568–579` name only two product surfaces:
  "mac_application for a native macOS app, browser for a webapp". A terminal
  program is not mentioned, so "a Go TUI on this Mac" became a Mac app.
- The generated acceptance criteria inherited it: T2's fifth criterion reads
  "A reviewer can start the managed Mac application demo on this Mac"; T4's
  fourth reads "A managed Mac application demo lets a reviewer browse…".
  The plan card showed "Opens as a Mac app" and the owner accepted the plan.
- The implementer honoured the contract literally: candidate v1 (worktree
  `t2-5eb9e659`) is a correct Go module plus `mac/DemoApp.swift`,
  `mac/Info.plist`, and `scripts/build-demo-app.sh`, which compiles a Cocoa
  status window with `swiftc` and copies the Go binary into the bundle. The
  delivery guidance says a delivery that cannot fit the contracted medium must
  pause and propose another kind; it wrapped instead. The tech lead approved
  the wrapper as matching the contract.
- Nothing caught it: `plannedDemoKindMatchesProductSurface` takes its expected
  surface from the eval scenario, and every planning scenario is a Mac app or a
  web app. The only command-output pilot brief is a one-shot script.

Owner decision (2026-09-01): add a demo kind that opens the built terminal
program in Terminal so reviewers drive the real TUI. Incorporate it everywhere
the existing kinds are incorporated, and evaluate it to the same standard.

## Behavior to add

Owner-observable contract:

- A product whose surface is an interactive terminal program plans every setup
  and story ticket as **Opens in Terminal**. The proposal card and the stored
  ticket show "You'll review this as: Opens in Terminal".
- Delivery of such a ticket returns a `terminal_application` recipe: sandboxed
  preparation commands build the program into the workspace, and the launch
  command names the built executable. Delivery never wraps the program in a
  Mac app bundle, web page, or any other surface to satisfy a contract.
- Choosing **Demo** prepares the exact reviewed revision, builds it inside the
  managed demo workspace, then opens a Terminal window that runs the program
  from that checkout. The board explains that the program is running in
  Terminal. **Open demo** while it runs brings the Terminal window forward
  without starting a second copy. **Stop demo** ends the program; the owner may
  also just close the window.
- Accepted terminal app candidates appear in the **Demos** workspace like
  browser and Mac app versions: newest first, reopenable, one running version
  per product.
- Acceptance records the canonical "Demo recipe: terminal app" knowledge page
  like every other kind.
- A delivery that finds its contracted medium wrong for a terminal program
  contests with `proposedDemoKind: terminal_application`; the owner's answer
  changes the stored kind. The tech lead returns a candidate that wraps the
  product in another surface with changes requested.

## Non-goals

- No change to the five existing kinds' validation rules, launch behaviour, or
  owner-facing text beyond the sentences that enumerate kinds.
- No streaming of the terminal session into Spedito, no embedded terminal
  view, no PTY handling inside the app. Terminal.app is the surface.
- No support for terminal emulators other than Terminal.app.
- No owner-facing control to edit a stored ticket's review medium. The contest
  question and the planning card remain the only paths.
- No marketing copy change. The website's "no terminal" promise is about
  Spedito's own workflow; a product that is a terminal program is the owner's
  product, and Spedito still opens it with one click.
- No new coordinator. `MacOSDemoLauncher` gains a branch; `AppModel` gains no
  lines, no task, no state.

## Decisions (made; do not reopen)

1. **Name.** Raw value `terminal_application`; Swift cases
   `DemoPresentationKind.terminalApplication` and
   `TicketDemoKind.terminalApplication`. `DemoPresentationKind.title` is
   "Terminal app". `TicketDemoKind.ownerFacingReviewMedium` is "Opens in
   Terminal"; the mid-sentence clause is "opens in Terminal". Sentence case,
   Terminal keeps its capital as the app name.
2. **Recipe shape.** `presentation.path` is null. `launchCommand` is required
   and names the built program: `executable` is a workspace-relative path that
   contains at least one `/` (for example `bin/tui` or `.build/tui`), so a bare
   tool name such as `go`, `python3`, or `sh` is rejected at decode time; the
   existing shell and no-op executable bans stay. `arguments` and
   `workingDirectory` follow the shared command rules. `timeoutSeconds` is
   validated by the shared rule but ignored at launch: an interactive session
   has no timeout. `preparationCommands` are allowed (at most six, as today).
   `portEnvironmentVariable` and `readiness` must be null.
   Guidance example:
   `{"presentation":{"kind":"terminal_application","path":null},"schemaVersion":1,"title":"Owner-facing title","preparationCommands":[{"executable":"scripts/build.sh","arguments":[],"workingDirectory":".","timeoutSeconds":300}],"launchCommand":{"executable":"bin/your-program","arguments":[],"workingDirectory":".","timeoutSeconds":120},"portEnvironmentVariable":null,"readiness":null}`
3. **Launch mechanism.** Spedito writes a launcher script to
   `<preview>/.spedito-demo-runtime/terminal/<launchID>.command`, mode 0755,
   and opens it with
   `NSWorkspace.open([scriptURL], withApplicationAt: terminalURL, configuration:)`
   where `terminalURL` comes from
   `urlForApplication(withBundleIdentifier: "com.apple.Terminal")` and
   `configuration.activates = true`. No `osascript`, no AppleScript, no
   Automation consent, no shell string passed to `open`. The script is
   Spedito-authored, so the validator's shell ban still applies to recipes.
   Script content (single-quoted paths, `'` escaped as `'\''`):

   ```sh
   #!/bin/zsh
   printf '\033]0;%s\007' '<recipe title>'
   cd '<preview workspace>/<workingDirectory>' || exit 1
   export TMPDIR='<preview>/.spedito-demo-runtime/tmp'
   export XDG_CACHE_HOME='<preview>/.spedito-demo-runtime/cache/xdg'
   export SPEDITO_DEMO_DATA_DIRECTORY='<preview>/.spedito-demo-runtime/data'
   printf '%d' "$$" > '<preview>/.spedito-demo-runtime/terminal/<launchID>.pid'
   exec '<preview>/<executable>' '<arg>' ...
   ```

   `exec` keeps the shell's PID, so the pid file identifies the program. The
   three exported variables mirror what `managedRequest` gives sandboxed demo
   commands; `HOME`, `PATH`, and the owner's shell configuration are untouched.
   Spedito creates the three directories before opening the script. Script
   text generation lives in Core as a pure, tested type
   (`TerminalDemoLaunchScript`); the App launcher only writes and opens it.
4. **Ownership and stop.** The launcher's `Runtime` gains
   `terminalProcessID: pid_t?`, read from the pid file after open (poll up to
   five seconds, 100 ms interval; `couldNotOpen` if it never appears). Liveness
   is `kill(pid, 0)`. **Stop demo** sends `SIGTERM`, waits up to two seconds
   in 100 ms steps, then `SIGKILL`, then removes the pid file. Spedito never
   closes the Terminal window: like browser tabs, it may belong to the owner.
   Closing the window sends `SIGHUP` and ends the program; the next **Open
   demo** sees the dead pid, drops the runtime, and relaunches. Session status
   is `ready` while open; no liveness poll runs (parity with
   `mac_application`, which also learns of termination only on reuse or stop).
   After a Spedito relaunch the session recovers exactly as other kinds do in
   `recoverDemoSessions`; a stale pid file is ignored, never signalled.
5. **Host trust statement.** The program runs on the host in the owner's login
   session with the owner's privileges, outside the `spedito-demo` sandbox,
   exactly as a `mac_application` bundle does once Launch Services opens it.
   Preparation still runs inside the sandbox. The executable must be a regular
   file with the execute bit inside the reviewed checkout; the smoke test and
   launch both resolve it through `resolveWorkspacePath`. This is recorded in
   `docs/technical-design.md` beside the existing Launch Services sentence.
6. **Smoke test.** After preparation, resolve the executable and require a
   regular, non-symlink, executable file inside the workspace. Do not run it:
   an interactive program would hang a bounded smoke. Return no output.
7. **Failure classification.** Missing or non-executable program after
   preparation → `DemoLauncherError.missingPresentation` → `.correctCandidate`.
   Terminal.app not found, script write failure, `open` failure, or pid file
   never appearing → `DemoLauncherError.couldNotOpen` → `.retryPreparation`.
8. **Owner text.** Board button: "Open demo" while ready (never "Run demo
   again"). Ready explanation: "The reviewed program is running in a Terminal
   window. Close that window or choose Stop demo when you are done." Demos
   screen symbol: `terminal`. Source description "<title> · Terminal app".
   Status labels unchanged.
9. **Demos membership.** `AcceptedAppLaunchPolicy.launch(for:)` admits
   `terminalApplication`; the post-acceptance teardown and the "Stop demo"
   button treat it as a running version. Journey row V05 changes from "browser
   and macOS app versions" to "browser, macOS app, and terminal app versions".
10. **Planning rule.** Replace the two-surface clause with four surfaces:
    "mac_application for a native macOS app, browser for a webapp,
    terminal_application for a program the user drives interactively in a
    terminal (a TUI, a menu, a prompt loop), command_output for a program run
    once for its printed result". State it identically in the prompt prose,
    the schema description, the repair prompt, `docs/product-spec.md`, and
    `docs/technical-design.md`. *Wording sharpened 2026-09-02 after the
    `script-log-summary` pilot rerun planned the one-shot program as
    `terminal_application`:* "terminal_application only for a program the
    user keeps interacting with while it runs in a terminal (a TUI, a menu, a
    prompt loop), command_output for a program that is started once with its
    inputs and prints a result, even when the user starts it from a
    terminal". The four surfaces are unchanged; the single copy lives in
    `CodexTicketSuggestionGenerator.productSurfaceRule`.
11. **Anti-wrapper rule.** Delivery guidance and reviewer guidance both state:
    never wrap the product in another surface (a Cocoa window around a
    terminal program, a page around a Mac app, a bundle around a script) to
    satisfy a contracted medium; contest instead. A reviewer returns such a
    candidate with changes requested and names the contest path.
12. **Schema.** Migration v6 removes the enumeration from both `demo_kind`
    CHECK constraints instead of extending it, so a future kind needs no
    migration; the domain enum decode remains the authority. Use the
    rebuild-free sequence (proven locally on SQLite 3.51 with cascading
    foreign keys and the `agent_work_log` view present; no cascade fires):

    ```sql
    ALTER TABLE work_items ADD COLUMN demo_kind_migrated TEXT;
    UPDATE work_items SET demo_kind_migrated = demo_kind;
    ALTER TABLE work_items DROP COLUMN demo_kind;
    ALTER TABLE work_items RENAME COLUMN demo_kind_migrated TO demo_kind;
    ALTER TABLE ticket_suggestions ADD COLUMN demo_kind_migrated TEXT;
    UPDATE ticket_suggestions SET demo_kind_migrated = demo_kind;
    ALTER TABLE ticket_suggestions DROP COLUMN demo_kind;
    ALTER TABLE ticket_suggestions RENAME COLUMN demo_kind_migrated TO demo_kind;
    PRAGMA user_version = 6;
    ```

    The declarative schema drops the CHECK from both columns and keeps each
    `demo_kind` as the last column before the table constraints, which is where
    the renamed column lands, so `ProductDatabaseSchemaTests` parity holds.
    Bump `ProductDatabaseSchema.version` to 6.
13. **Imported repositories.** An imported terminal program is a legitimate
    launch proposal. `CodexRepositoryKnowledgeAnalyzer` admits
    `terminal_application` beside browser and Mac app; **Check imported
    source** validates it with the same smoke test; the Demos workspace lists
    it. Artifact and command-output proposals stay excluded.
14. **UX designer prototypes.** `DeliveryDemoPolicy.reviewablePrototype` keeps
    admitting only `static_web`, `browser`, and `mac_application`. A designer
    prototyping a terminal experience delivers a static web prototype or a
    screen set artifact, as today.
15. **Shell designation.** The new journey row is `Shell = —`. The Demo,
    Open demo, Stop demo, and Demos-screen controls are kind-agnostic wiring
    already proven by D14 and V06 launched-process contracts; the kind
    dispatch lives inside the launcher and is proven deterministically through
    injected seams. Add a launched-process test only if a real shell-wiring
    defect appears.

## Current authority

- Durable state: `work_items.demo_kind`, `ticket_suggestions.demo_kind`
  (CHECK-enumerated), `candidate_revisions.execution_result_json` (recipe),
  `demo_sessions`, canonical demo recipe knowledge pages.
- Task owner: `MacOSDemoLauncher` (in-memory `runtimes`), `AppModel`
  `launchManagedPresentation` / `stopManagedSession` /
  `prepareDemoForAcceptance`.
- Presentation state: `DemoSessionFeatureModel`, `SprintBoardView.demoSection`,
  `AppVersionsView`, `TicketReviewMediumPresentation`,
  `TicketDetailView.reviewMediumSummary`.
- Known duplicate state: none. The kind lists are duplicated as literals in
  code, prompts, schema, and docs; this packet touches every copy and adds no
  new copy.

## Target authority

- Coordinator: unchanged. `MacOSDemoLauncher` remains the launch owner;
  `TicketDeliveryWorkflowCoordinator` remains the contract owner.
- Commands: unchanged (`launchDemo`, `stopAppVersion`, `openAppVersion`,
  `retryFailedPostReviewDemo`, contested-kind answer).
- Snapshot: `DemoSession` unchanged. `Runtime.terminalProcessID` is transient
  operation state inside the launcher.
- Persistence operations: `migrationV5ToV6` in `ProductDatabaseSchema.swift`;
  no new store operations.
- View boundary: unchanged. New strings only.

## State table

| State | Entered by | Durable evidence | Owner sees | Available actions | Recovery |
| --- | --- | --- | --- | --- | --- |
| Planned as terminal app | Plan accepted with a terminal-surface product | `ticket_suggestions.demo_kind` then `work_items.demo_kind = terminal_application` | "You'll review this as: Opens in Terminal" on card and ticket | Accept, reject, edit proposal; contest during delivery | Row survives relaunch; E09 |
| Delivered recipe | Delivery turn returns `terminal_application` recipe | `candidate_revisions.execution_result_json` validated by `DemoLaunchSpecificationValidator` | Candidate ready for demo; work log line "Demo: <title> · Terminal app" | Demo, Request changes, Approve | D10; recipe pinned across revisions |
| Contested | Delivery returns `awaiting_owner` with `proposedDemoKind` | Owner question with canonical options | Question card: change to "opens in Terminal" or keep | Answer | Fresh coordinator applies the answer; existing D10 journey |
| Preparing | Demo, Open demo, or acceptance smoke | `demo_sessions.status = preparing`, `preview_worktree_path` | "Preparing…" | none | Stopped on relaunch like other kinds |
| Ready (running in Terminal) | Script opened, pid file read | `demo_sessions.status = ready`, `output = NULL` | Terminal window with the program; board explanation from decision 8; Stop demo | Open demo (brings Terminal forward), Stop demo, Request changes, Approve | Relaunch marks stopped; stale pid never signalled |
| Stopped | Stop demo, another version opened, product switch, shutdown, window closed then reopened | `demo_sessions.status = stopped` | "The reviewed demo is ready…" | Demo | Idempotent |
| Failed (candidate) | Program missing or not executable after preparation | `status = failed`, `error_message` sanitised | "The demo could not open…"; candidate needs correction | Request changes, Retry demo | D14 semantics |
| Failed (host) | Terminal.app missing, script write or open failure, pid file absent | `status = failed`, `error_message` | Same text; Retry demo preparation | Retry demo | D14 semantics |
| Accepted version | Approve | `candidate_revisions.status = accepted`; canonical page `demo-recipe-terminal-application` | Listed in Demos with `terminal` symbol | Open, stop, switch | V05, V06 |

## Layers (deliver as separate commits, in this order)

### Layer 1 — Domain, validation, schema (Core)

- `Sources/SpeditoCore/Domain/DemoLaunch.swift`: add both enum cases
  (`:3–19`, `:27–64`) with the decision-1 strings; validator branch
  (`:645–765`) per decision 2, including the "contains a `/`" executable rule;
  `AcceptedAppLaunchPolicy.launch(for:)` (`:296–308`) admits the kind;
  `DemoRecipeRevisionPolicy.demoChangeTermPattern` (`:326–327`) gains
  `terminal[-_ ]application|terminal|tui`; `CanonicalDemoRecipeKnowledge`
  needs no change beyond `title` (slug becomes
  `demo-recipe-terminal-application`).
- New `Sources/SpeditoCore/Domain/TerminalDemoLaunchScript.swift`: pure
  builder `TerminalDemoLaunchScript.text(specification:workspaceURL:runtimeDirectoryURL:launchID:)`
  and `quote(_:)`. No Foundation process APIs.
- `Sources/SpeditoCore/Persistence/ProductDatabaseSchema.swift`: declarative
  DDL at `:68–74` and `:194–200` drops the CHECK; `migrationV5ToV6` per
  decision 12; `version = 6`.
- `Sources/SpeditoCore/Domain/TicketDeliveryWorkflowCoordinator.swift`
  `:4033–4036`: the post-acceptance teardown allowlist admits the kind.
- Tests:
  - `DemoLaunchTests.supportedPresentations` gains the sixth literal;
    `schemaBranchShapesMirrorTheValidator`, `perKindDecodeShapes` (legal and
    illegal terminal shapes: path present, readiness present, port present,
    missing launch command, executable `go`, executable `sh`, executable
    `../bin/tui`, executable `/usr/bin/top`), `contestedKindOptionsRoundTrip`
    (terminal option text), `acceptedApplicationPresentations` (terminal
    resolves as an App version), `invalidAcceptedCandidates` unchanged,
    `feedbackDemoChangeDetection` ("open it in Terminal", "the TUI demo").
  - New `TerminalDemoLaunchScriptTests`: exact script text for a workspace
    path containing spaces and an apostrophe, argument quoting, working
    directory join, pid path, exported variables, and the `exec` line.
  - `SQLiteStoreTests.demoKindContractsMigrateAndRoundTrip`: loop covers the
    new case automatically; extend the fixture chain with `migrationV5ToV6`
    and add a test that a v5 database holding every existing kind plus
    dependent `ticket_comments`, `candidate_revisions`, and
    `work_item_dependencies` rows migrates with row counts unchanged, then
    stores `terminal_application`, and that re-running the migration is a
    no-op under the `user_version` guard.
  - `ProductDatabaseSchemaTests` parity passes unchanged.
  - `WorkflowPolicyTests.deliveryDemoPolicyHonoursTheStoredContract` covers
    the case automatically; assert it in the test's expectations table.
  - `KnowledgeContextSelectorTests`: the terminal canonical page reaches a
    terminal-contracted run and not a browser-contracted one.

### Layer 2 — Codex contracts and evals (Core)

- `Sources/SpeditoCore/Codex/CodexTicketExecutor.swift`: schema branch
  (`:1336–1344`, new builder next to `commandOutput` at `:1327–1334`);
  `admittedKinds` `.anyKind` list (`:1345–1351`); repair prompt clause
  (`:665–685`): "an interactive terminal program is terminal_application,
  whose launchCommand names the built workspace-relative executable and whose
  path, port, and readiness are null; a command run once for its printed
  result is command_output".
- `Sources/SpeditoCore/Codex/CodexLifecycleGuidance.swift`: catalogue bullet
  and literal JSON example (`:312–330`) using the decision-2 example;
  disambiguation prose (`:332–334`); anti-wrapper sentence after `:301–305`;
  reviewer guidance (`:475–493`) per decision 11.
- `Sources/SpeditoCore/Codex/CodexTicketSuggestionGenerator.swift`: rule prose
  (`:64–68`), schema description (`:568–579`), repair reminder (`:402`) per
  decision 10.
- `Sources/SpeditoCore/Codex/CodexRepositoryKnowledgeAnalyzer.swift`: prompt
  prose (`:35`, `:189`, `:205`) and runtime allowlist (`:496–504`) per
  decision 13.
- Tests:
  - `CodexLifecycleGuidanceTests.deliveryGuidanceCarriesEveryDemoShape`
    passes with six shapes; add an assertion that the anti-wrapper sentence
    is present in implementer and tech lead guidance.
  - `CodexAdapterTests.suggestionDemoKindDecoding` covers the case
    automatically; add a schema-description assertion that the four surfaces
    are named. `promptsCarryTheDemoKindContract` adds the terminal phrase
    "opens in Terminal". `proposedDemoKindDecoding` adds
    `terminal_application`.
  - `DemoLaunchTests.contractedSchemaAdmitsOnlyTheContractedBranch` covers
    the case automatically; `reviewablePrototypeSchemaAdmitsOnlyInteractiveKinds`
    asserts terminal is absent.
  - `RepositoryImportKnowledgeTests`: a terminal launch proposal decodes
    without `launchProposalIssue`; an artifact proposal still fails.
  - `EvalSupportTests`: add the missing unit test for
    `plannedDemoKindMatchesProductSurface` with passing and failing fixtures
    for each surface, including terminal.
- Eval scenarios (`Tests/SpeditoCoreTests/Evals/EvalScenarios.swift`):
  - `epic-plan/terminal-battersea` via `launchBriefScenario` with
    `productSurface: .terminalApplication` and the Battersea epic goal
    verbatim: "Help a user find currently available Battersea dogs by breed in
    a Go terminal application and open a selected dog's official web page."
    Extra check `criteriaNeverNameAMacApp`: no criterion or body contains
    "Mac app", "macOS app", "Mac application", or ".app".
  - `epic-plan/script-log-summary` via `launchBriefScenario` with
    `productSurface: .commandOutput` and the pilot brief verbatim, proving the
    rule does not over-capture one-shot programs.
  - `delivery/terminal-feature`: a fixture repository holding a small Swift
    standard-library terminal menu program (`Sources/main.swift`,
    `scripts/build.sh` producing `bin/menu` with `swiftc`), a ticket contracted
    `terminal_application` asking for one added menu entry. Checks:
    `providesManagedDemo`, `demoIsTerminalApplication`,
    `launchCommandNamesBuiltExecutable` (relative, contains `/`, under `bin/`),
    `noWrapperSurfaceAdded` (no `.app`, `Info.plist`, `import Cocoa`,
    `import AppKit`, or `index.html` in the diff), and the existing
    completion-handoff checks.
  - `delivery/terminal-contested-kind`: the same fixture with the ticket
    contracted `mac_application` (the Battersea T2 shape). Pass requires
    `status == awaiting_owner`, `proposedDemoKind == .terminalApplication`,
    exactly one owner question, and `noWrapperSurfaceAdded`.
  - Register all four in the assembly order at `:104–112`.
  - Record a baseline per the completion-handover convention: bundle id,
    REPS, effort, per-cell pass counts.

### Layer 3 — Launcher and views (App)

- `Sources/SpeditoApp/MacOSDemoLauncher.swift`:
  - Seams beside `DemoApplicationOpening` (`:92–128`):
    `DemoTerminalOpening` (`openScript(at:) async throws`,
    `activateTerminal()`) and `DemoProcessSignaling` (`isAlive(_:)`,
    `terminate(_:)`, `kill(_:)`), with production implementations using
    `NSWorkspace` and `kill(2)`.
  - `Runtime` (`:145–152`) gains `terminalProcessID`.
  - `smokeTest` switch (`:200–236`) per decision 6; `launch` switch
    (`:286–355`) per decisions 3 and 4; reuse path (`:245–276`) gains the
    terminal branch (alive → `activateTerminal()`; dead → drop and relaunch);
    `stop` (`:358–370`) per decision 4.
  - `DemoPreparationFailurePolicy` (`:45–67`) unchanged in shape; the new
    failure paths reuse `missingPresentation` and `couldNotOpen`.
- `Sources/SpeditoApp/SprintBoardView.swift`: `demoButtonTitle` (`:3462`
  unchanged, terminal is not `commandOutput`), "Stop demo" condition
  (`:3336–3341`) admits terminal, `demoExplanation` ready sentence
  (`:3513–3524`) per decision 8.
- `Sources/SpeditoApp/AppVersionsView.swift`: `presentationSymbol`
  (`:277–283`) returns `terminal`.
- `Sources/SpeditoApp/UIFixtureRuntime.swift`: no change (Shell = —).
- Tests (`Tests/SpeditoAppTests/MacOSDemoLauncherTests.swift`, scripted
  executor, no Terminal.app):
  - `terminalLaunchWritesScriptAndOpensTerminal`: preparation runs through the
    scripted executor; the script file exists with mode 0755 and the exact
    `TerminalDemoLaunchScript` text; the fake opener receives the script URL;
    the fake pid source supplies a pid; outcome has no output or port;
    session-facing runtime holds the pid.
  - `terminalScriptRunsTheProgramFromTheWorkspace`: execute the generated
    script with `Process` (`/bin/zsh`) against a fake executable that records
    its cwd, arguments, and environment to a file; assert cwd equals the
    workspace, arguments survive spaces and quotes, the three variables are
    set, and the pid file equals the recorded process id.
  - `terminalStopTerminatesTheProgram`: with the real child from the previous
    test, `stop(candidateID:)` ends it within the bound and removes the pid
    file; a second stop is a no-op.
  - `terminalReopenActivatesWhileAliveAndRelaunchesWhenDead`.
  - `terminalSmokeTestNeverRunsTheProgram`: the fake executable records
    invocations; smoke leaves zero.
  - `terminalMissingExecutableIsACandidateFailure` and
    `terminalOpenFailureIsAHostFailure` through `DemoPreparationFailurePolicy`.
  - `terminalLaunchRejectsExecutableOutsideWorkspace` (symlink escape).
- Presentation tests (`Tests/SpeditoAppTests/EpicPlanningPresentationTests.swift:776`):
  add "Opens in Terminal" to the literal dictionary. Add a small
  `SprintBoardDemoPresentationTests` suite that pins `demoButtonTitle` and
  `demoExplanation` for every kind, so the two untested switches gain
  coverage in the same packet that grows them.

### Layer 4 — Pilot, journey inventory, documentation

- `Tests/SpeditoAppTests/Pilot/PilotBriefs.swift`: brief `terminal-todo`,
  product "Terminal to-do", outcome "A terminal app where I keep a to-do
  list: add items, tick them off with the keyboard, and see them again next
  time.", `expectedDemoKind: .terminalApplication`,
  `expectsNetworkPermission: false`, no follow-up.
- `Tests/SpeditoAppTests/Pilot/PilotDriver.swift:978–1019`: when the
  candidate belongs to a **story** ticket and its declared kind differs from
  `brief.expectedDemoKind`, file a `.functional` finding naming
  `CodexTicketSuggestionGenerator.swift`; keep recording for other tickets.
  Update the doc comment at `:1011–1019`.
- `docs/architecture/pilot.md:48–58`: add the brief row; also add the two
  existing briefs the table omits (`native-weather`, `web-markdown-notes`).
  `docs/architecture/pilot-handoff.md:313–315`: update the brief count.
- `docs/architecture/owner-journey-test-plan.md`:
  - New row **D24 | P0 |** "Open a terminal app demo in Terminal from the
    exact reviewed revision, bring it forward while it runs, stop it, and
    retry; the program is the reviewed workspace executable, never a host
    command. | J+P | —" in §5.6 (`:576–602`, count 23 → 24) and a ledger
    entry in §3 with **Named:** evidence listing the Layer 1–3 tests by
    `Suite.method`.
  - Extend D10 (`:127`, `:589`) for the terminal contract and contest, D14
    (`:131`, `:593`) for launch and stop, V05 (`:366`, `:639`, state table
    `:373`) for Demos membership, V06 (`:145`, `:640`) for switch and stop,
    E09 (`:260`, `:537`) for the planning medium.
  - Reconcile every count: `:23–30`, `:152–154`, `:479`, `:783`, `:802–806`,
    `:939–942`. State the final numbers once and make all six agree.
- `docs/product-spec.md`: the mechanical rule (`:909–915`), one-page-per-medium
  sentence (`:922–926`), Demos workspace membership (`:1518–1525`), import
  recipes (`:1527–1531`), validation shapes (`:2666–2672`), and one principle
  sentence near `:25`: "Spedito never requires the owner to use a terminal;
  when the product itself is a terminal program, Demo opens it in Terminal for
  the owner." Record the new kind under §20.2 (`:2896–2899`) as delivered.
- `docs/technical-design.md`: schema union (`:279–284`), "one of the five"
  (`:288–293` → six), NULL-contract fallback (`:299–305`), repair
  distinctions (`:305–311`), supported presentations (`:789–793`), Launch
  Services paragraph (`:824–833`, add the host trust statement), what Demo
  opens (`:835–841`), ownership and Stop demo (`:911–917`, add the pid-file
  rule), import exclusions (`:919–932`), Demos composition (`:940–947`),
  runtime policy (`:949–960`), plus migration v6 in the schema history near
  `:168–169`.
- `CLAUDE.md` and `AGENTS.md` (identical files): the "Codebase and app
  versions" row (`:189`) journey list gains D24. No coordinator change.
- `scripts/architecture_ratchets.baseline`: unchanged. If `AppModel` grows,
  the packet is wrong; move the logic into the launcher or Core.

### Layer 5 — Correct the live Battersea product

Perform after Layers 1–4 are validated and the app is relaunched.

1. In the ticket editor, replace T2's criterion "A reviewer can start the
   managed Mac application demo on this Mac and see evidence that the setup
   works." with "A reviewer can open the managed demo, which runs the Go TUI in
   a Terminal window, and see evidence that the setup works." Replace T4's
   criterion "A managed Mac application demo lets a reviewer browse a live
   available breed, select a dog, and confirm that its Battersea page opens."
   with "A managed demo opens the Go TUI in a Terminal window and lets a
   reviewer browse a live available breed, select a dog, and confirm that its
   Battersea page opens."
2. On T2, choose **Request changes** with feedback: "The demo must open the Go
   TUI in Terminal, not a Mac app. Remove mac/DemoApp.swift, mac/Info.plist,
   and scripts/build-demo-app.sh. If the approved review medium blocks this,
   ask me to change it." The feedback names the demo, so the recipe pin lifts.
   The expected path is the contest question proposing "opens in Terminal";
   accept it, and the stored kind changes through `updateWorkItemDemoKind`
   with its activity event.
3. If the revision wraps again instead of contesting, that is a Layer 2
   defect: fix the guidance, add the failing case to
   `delivery/terminal-contested-kind`, and repeat step 2. Do not edit the
   database to get past it.
4. T4 is queued and has no candidate. Its stored kind changes only through an
   owner decision; since no owner control exists (non-goal), apply this
   one-off as the owner's recorded decision and leave an owner comment on T4
   saying so:

   ```sql
   UPDATE work_items
      SET demo_kind = 'terminal_application',
          version = version + 1,
          updated_at = strftime('%s','now')
    WHERE product_id = (SELECT id FROM products WHERE name LIKE 'Battersea%')
      AND item_key = 'T4' AND demo_kind = 'mac_application';
   ```

   Database: `~/Library/Application Support/Spedito/Product Workspaces/D7E8B85A-2E89-48F9-934B-0DFAE605380C/.spedito/product.sqlite`.
   Run it with the app quit.
5. Verify in the app: T2 and T4 show "Opens in Terminal"; T2's next candidate
   returns a `terminal_application` recipe; **Demo** opens the Go TUI in
   Terminal; **Stop demo** ends it; approval lists it in Demos.

## Call sites to migrate

Compile-forced (exhaustive switches):

- [ ] `DemoLaunch.swift:11–18` `title`
- [ ] `DemoLaunch.swift:36–44` `presentationKind`
- [ ] `DemoLaunch.swift:49–57` `ownerFacingReviewMedium`
- [ ] `DemoLaunch.swift:645–765` validator branch
- [ ] `CodexTicketExecutor.swift:1336–1344` `branch(for:)`
- [ ] `MacOSDemoLauncher.swift:200–236` `smokeTest`
- [ ] `MacOSDemoLauncher.swift:286–355` `launch`
- [ ] `AppVersionsView.swift:277–283` `presentationSymbol`
- [ ] `SprintBoardView.swift:3513–3524` `demoExplanation`

Silent (found by hand; each is a test target too):

- [ ] `DemoLaunch.swift:300–302` `AcceptedAppLaunchPolicy` allowlist
- [ ] `DemoLaunch.swift:326–327` `demoChangeTermPattern`
- [ ] `ProductDatabaseSchema.swift:68–74`, `:194–200` declarative CHECKs;
      new `migrationV5ToV6`; `version`
- [ ] `TicketDeliveryWorkflowCoordinator.swift:4033–4036` teardown allowlist
- [ ] `CodexTicketExecutor.swift:1345–1351` `admittedKinds`
- [ ] `CodexTicketExecutor.swift:665–685` repair prompt
- [ ] `CodexLifecycleGuidance.swift:301–334`, `:475–493` guidance
- [ ] `CodexTicketSuggestionGenerator.swift:64–68`, `:402`, `:568–579`
- [ ] `CodexRepositoryKnowledgeAnalyzer.swift:35`, `:189`, `:205`, `:496–504`
- [ ] `SprintBoardView.swift:3336–3341` Stop demo condition
- [ ] `MacOSDemoLauncher.swift:245–276` reuse path, `:358–370` stop
- [ ] `PilotBriefs.swift`, `PilotDriver.swift:978–1019`
- [ ] `EvalScenarios.swift:104–112`, `:434–462`; `EvalSupportTests.swift`
- [ ] `EpicPlanningPresentationTests.swift:776` dictionary
- [ ] All documents listed in Layer 4

## Obsolete state to remove

- [ ] The six-value enumerations inside both `demo_kind` CHECK constraints
      (replaced by migration v6 and the declarative schema).
- [ ] The "five presentation kinds" and "a Mac app or the browser" claims in
      `docs/technical-design.md` and `docs/product-spec.md`.
- [ ] The "No new demo kinds" non-goal lines named at the top of this packet
      stay as history; add one sentence to each pointing at this packet.

## Verification

- [ ] Layer 1 focused: `swift test --filter 'DemoLaunchTests|TerminalDemoLaunchScriptTests|SQLiteStoreTests|ProductDatabaseSchemaTests|WorkflowPolicyTests|KnowledgeContextSelectorTests'`
- [ ] Layer 2 focused: `swift test --filter 'CodexAdapterTests|CodexLifecycleGuidanceTests|DemoGuidanceTests|RepositoryImportKnowledgeTests|EvalSupportTests'`
- [ ] Layer 2 evals: `./scripts/evals.sh epic-plan/terminal`,
      `./scripts/evals.sh epic-plan/script-log-summary`,
      `./scripts/evals.sh delivery/terminal` with `SPEDITO_EVAL_REPS=3`;
      record the bundle ids and per-cell pass counts. The two delivery
      scenarios need `swiftc` (Xcode command-line tools) on the machine; name
      the Xcode and Codex versions exercised.
- [ ] Layer 3 focused: `swift test --filter 'MacOSDemoLauncherTests|EpicPlanningPresentationTests|SprintBoardDemoPresentationTests'`
- [ ] Interruption and fresh-instance recovery: the existing D10 contested
      journey and D14 retry journey parameterised with a terminal recipe;
      relaunch with a `ready` terminal session marks it stopped and never
      signals the stale pid.
- [ ] Real sandbox: `MacOSDemoLauncherTests.realSandboxCreateDeleteParity`
      stays green; add a terminal recipe whose preparation compiles a Swift
      terminal program with `swiftc` inside the `spedito-demo` profile and
      whose smoke test resolves the executable. Name the Codex binary and
      version.
- [ ] Pilot: `SPEDITO_PILOT=1 SPEDITO_PILOT_BRIEF=terminal-todo ./scripts/pilot.sh`
      reaches a launched `terminal_application` demo of a story ticket; record
      the bundle path. Also rerun `script-log-summary` to prove it still
      reaches `command_output`.
- [ ] Full default validation:
      `env SWIFT_MODULECACHE_PATH="$PWD/.build/module-cache" CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache" swift test -Xswiftc -warnings-as-errors`,
      `git diff --check`, `./scripts/check_architecture_ratchets.sh`
      (use `--scratch-path` if the repository `.build` is held by another
      session; never pipe `swift test` through `tail`).
- [ ] Launched-process suite: not required. This packet changes no
      application-shell wiring; the Demo, Stop demo, Demos, and owner-question
      controls are unchanged and D09, D14, D15, and V06 already prove them.
      State this in the handoff. If any file under `Tests/SpeditoUITests` or
      `UIFixtureRuntime.swift` is touched after all, run only the affected
      contract through `./scripts/run_ui_tests.sh -only-testing:…` when the
      machine is free.
- [ ] `./scripts/relaunch.sh`, left running.
- [ ] Layer 5 performed and verified in the relaunched app.
- [ ] Product-owner inspection: (1) the Battersea T2 plan card and ticket read
      "Opens in Terminal"; (2) **Demo** on the new T2 candidate opens a Terminal
      window running the Go TUI from the preview checkout; (3) **Open demo**
      brings that window forward without a second copy; (4) **Stop demo** ends
      the program and the board returns to "The reviewed demo is ready…";
      (5) closing the window and choosing **Demo** again relaunches;
      (6) after approval the version appears in Demos with the terminal
      symbol and can be reopened and stopped from there; (7) light and dark
      appearance of the board demo card and the Demos row.

## Working notes

- Shared, dirty working tree with several uncommitted packets. Preserve
  unrelated work; commit each layer of this packet on its own.
- Build lock contention: validate and relaunch with `--scratch-path` when
  another session holds `.build`.
- The launched-process suite and `relaunch.sh` seize the GUI session; run
  them only when the product owner is free.
- Terminal.app quirks to expect and leave alone: the window stays open with
  "[Process completed]" after the program exits unless the owner's profile
  closes it; when Terminal is not already running it may also open its default
  startup window. Neither is a defect.
- Preview worktrees live under `~/Library/Caches`, which Terminal can read
  without a privacy prompt. Do not relocate them.
- Spedito is not App Sandboxed and sets no `LSFileQuarantineEnabled`, so the
  generated `.command` carries no quarantine attribute and opens without a
  Gatekeeper prompt. If distribution ever adds the sandbox entitlement, this
  kind must be re-verified.
- `CLAUDE.md` navigation map: no new coordinator, so only the journey list in
  the "Codebase and app versions" row changes.

## Completion evidence

Record per layer: tests added (by `Suite.method`), the migration id
(`PRAGMA user_version = 6`, `migrationV5ToV6`), the eval bundle ids with
per-cell pass counts for the four new scenarios, the pilot bundle path for
`terminal-todo` and the rerun of `script-log-summary`, the Codex binary and
version and the Xcode version exercised by the real-sandbox terminal recipe,
the final journey-inventory counts, the before and after states of Battersea
T2 and T4 (stored kind, criteria text, candidate version, demo session
status), and the product owner's inspection result for the seven items above.

## Addendum — owner scope addition (2026-09-01): design work delivers HTML screen sets

Owner decision (2026-09-01, evening): UX design tickets were steered to PDF
screen sets and the results were poor — misaligned layouts, wrong or missing
fonts. Design mock-ups are to be built as HTML instead, integrated as deeply as
the terminal kind.

No new kind was added. `static_web` ("Interactive prototype") already is a
workspace directory with `index.html` that Spedito serves on loopback and opens
in the browser. What steered design work to PDFs was three rules, all
re-pointed in this packet:

1. **Planning rule.** The mechanical rule now has a design clause stated once in
   `CodexTicketSuggestionGenerator.designMediumRule` and interpolated into the
   planning prose, the schema description, and the repair prompt: "design
   tickets about a visible interface use static_web, a self-contained HTML
   screen set or clickable prototype Spedito serves in the browser; research
   tickets and explicitly document-first design outcomes such as copy reviews,
   service blueprints, and accessibility audits use artifact". The product
   specification and technical design repeat it.
2. **UX contract guidance** (`CodexLifecycleGuidance.uxTicketContractGuidance`,
   used by refinement and planning) names the HTML screen set under
   `static_web` as the default medium — one page per screen or state with an
   index page linking them — and forbids asking for a PDF or image screen set
   unless the outcome is explicitly document-first.
3. **Delivery and review.** The UX persona builds HTML screen sets (system font
   stacks, consistent spacing scale, aligned layouts, realistic content, no
   external network resources) and uses PNG/PDF only for a document-first
   contract; the delivery guidance's `static_web` bullet, artifact bullet, and
   fidelity paragraph say the same; the tech lead returns a PDF or image
   screen set delivered where the contract expects `static_web` with changes
   requested, naming the HTML screen set.

Measurement: `EvalEpicPlanChecks.plannedDemoKindMatchesProductSurface` now
requires `static_web` for UX designer tickets unless the title or body names a
document-first outcome (`documentFirstDesignPattern`), and `artifact` for
research; `EvalEpicPlanCheckTests.plannedDemoKindMatchesProductSurface` pins
both. The existing `delivery/ux-prototype` and `delivery/ux-native-prototype`
cells already require `static_web` and real markup text.

Unchanged: `DeliveryDemoPolicy.reviewablePrototype` (the pre-contract
fallback), the artifact validator, the five other kinds.

## Completion evidence (recorded 2026-09-01/02, night session)

Tooling exercised: Swift 6.3.2 (swiftlang-6.3.2.1.108), Xcode 26.5 (17F42),
SQLite 3.51.0, Codex CLI 0.152.0 at `/Applications/Codex.app/Contents/Resources/codex`
(the runtime `CodexSandboxRuntimeLocator` resolves for the app; Homebrew's
`/opt/homebrew/bin/codex` is the same 0.152.0).

### Layer 1 — Domain, validation, schema

- Migration: `ProductDatabaseSchema.migrationV5ToV6`, `PRAGMA user_version = 6`,
  `ProductDatabaseSchema.version = 6`; `SQLiteStore.initializeCurrentSchema`
  accepts versions 1–5 and runs v4→v5 only below 5.
- Tests added or extended: `DemoLaunchTests.supportedPresentations`,
  `.reviewablePrototypeSchemaAdmitsOnlyInteractiveKinds`,
  `.schemaBranchShapesMirrorTheValidator`, `.perKindDecodeShapes` (legal
  terminal shape; illegal path, readiness, port, missing launch command, `go`,
  `sh`, `../bin/tui`, `/usr/bin/top`), `.contestedKindOptionsRoundTrip`,
  `.acceptedApplicationPresentations`, `.feedbackDemoChangeDetection`;
  `TerminalDemoLaunchScriptTests.exactScriptText`,
  `.currentDirectoryRunsFromTheWorkspaceRoot`, `.missingLaunchCommandIsInvalid`,
  `.quoting`, `.runtimeLayout`;
  `SQLiteStoreTests.demoKindContractsMigrateAndRoundTrip` (now expects
  version 6) and `.demoKindMigrationV6DropsTheCheckWithoutLosingRows` (v5
  database with every existing kind plus dependent `ticket_comments`,
  `candidate_revisions`, `work_item_dependencies`, `sprint_items`, and
  `agent_runs` rows migrates with foreign keys enforced, counts unchanged,
  `demo_kind` last column on both tables, then stores `terminal_application`;
  a store opening the v6 database changes nothing);
  `ProductDatabaseSchemaTests` parity unchanged and green;
  `WorkflowPolicyTests.deliveryDemoPolicyHonoursTheStoredContract` (explicit
  expectations table); `KnowledgeContextSelectorTests.terminalCanonicalRecipeFollowsTheContract`.

### Layer 2 — Codex contracts and evals

- `CodexLifecycleGuidanceTests.deliveryGuidanceCarriesEveryDemoShape` (six
  shapes; anti-wrapper sentence in implementer and tech lead guidance),
  `CodexAdapterTests.suggestionDemoKindDecoding` (four surfaces and the shared
  `productSurfaceRule` in the schema description and planning prose),
  `.promptsCarryTheDemoKindContract` ("opens in Terminal"),
  `.proposedDemoKindDecoding` (`terminal_application`),
  `RepositoryImportKnowledgeTests.terminalLaunchProposalImportsWhileArtifactsDoNot`,
  `EvalEpicPlanCheckTests.plannedDemoKindMatchesProductSurface`.
- Eval scenarios registered: `epic-plan/terminal-battersea`,
  `epic-plan/script-log-summary`, `delivery/terminal-feature`,
  `delivery/terminal-contested-kind` (fixture: Swift standard-library menu
  program, `scripts/build.sh` → `bin/menu`, exec bit recorded through the new
  `executablePaths` fixture parameter).

### Layer 3 — Launcher and views

- `MacOSDemoLauncherTests.terminalLaunchWritesScriptAndOpensTerminal`,
  `.terminalScriptRunsTheProgramFromTheWorkspace` (real `/bin/zsh` execution
  of the generated script), `.terminalStopTerminatesTheProgram`,
  `.terminalReopenActivatesWhileAliveAndRelaunchesWhenDead`,
  `.terminalSmokeTestNeverRunsTheProgram`,
  `.terminalMissingExecutableIsACandidateFailure`,
  `.terminalOpenFailureIsAHostFailure`,
  `.terminalLaunchRejectsExecutableOutsideWorkspace`,
  `.realSandboxTerminalRecipeBuildsAndResolves` (swiftc inside the
  `spedito-demo` profile through Codex CLI 0.152.0; passed in the full suite);
  `EpicPlanningPresentationTests.proposalCardStatesTheReviewMedium` ("Opens in
  Terminal"); new `SprintBoardDemoPresentationTests` suite pinning button
  titles, Stop demo visibility, and explanations for every kind, backed by the
  extracted `SprintBoardDemoPresentation` enum.

### Layer 4 — Pilot, journey inventory, documentation

- Journey inventory final counts: 128 rows, 99 Named, 28 Composed, S08
  Blocked; §5.6 has 24 rows; 19 `Shell = Y` rows unchanged. D24 added
  (`Shell = —`); D10, D14, V05, V06, E09 extended.
- Pilot brief `terminal-todo` added; `docs/architecture/pilot.md` now lists all
  twelve briefs; the pilot driver files a functional finding when a story
  ticket's candidate declares a kind other than the brief's product surface.

### Validation

- `swift test -Xswiftc -warnings-as-errors` (full default suite):
  763 tests in 79 suites passed (after the UX scope addition too).
- `git diff --check`: clean. `./scripts/check_architecture_ratchets.sh`:
  all 6 baselines match; `AppModel` gained no lines.
- Launched-process suite: not run. No file under `Tests/SpeditoUITests` or
  `UIFixtureRuntime.swift` changed; the Demo, Stop demo, Demos, and
  owner-question controls are unchanged wiring already proven by D09, D14,
  D15, and V06.

### Battersea before-state (read from the live database, app running)

- Schema `user_version` 5. T2: state `acceptance`, `demo_kind`
  `mac_application`, version 17, candidate v1 `ready_for_demo`, fifth
  criterion "A reviewer can start the managed Mac application demo on this
  Mac and see evidence that the setup works." T4: state `queued`,
  `demo_kind` `mac_application`, version 2, no candidate, fourth criterion
  "A managed Mac application demo lets a reviewer browse a live available
  breed, select a dog, and confirm that its Battersea page opens." All demo
  sessions `stopped`.

### Relaunch (2026-09-01 22:35, `./scripts/relaunch.sh`, left running)

The relaunched debug app (binary built 22:35, carrying the new strings)
opened the products and migrated them: all 19 product databases under
`Product Workspaces` read `PRAGMA user_version` 6 within a minute of launch,
and the Battersea `work_items.demo_kind` is declared `TEXT` with no CHECK
constraint, matching a fresh install. No agent run was
`running` in any product at relaunch time (only `queued` and
`awaiting_owner`), and no demo session was active.

Layer 5 steps 1, 2, 3, and 5 are owner actions in the app (ticket editor,
Request changes, answering the contest question, inspection); the agent may
not drive the GUI. Step 4's `UPDATE` was also left to the owner: the
autonomous session's tool policy refused a write to the owner's live product
database, so the exact statement was handed over instead of applied.

### Eval baselines

- `epic-plan/terminal-battersea` — bundle `.eval-runs/20260901-223658`,
  REPS 3, gpt-5.6-terra at medium and high, judge gpt-5.6-terra high, Codex
  0.152.0. Per cell: medium 1 of 3 samples planned (that sample passed 17/17
  checks including `plannedDemoKindMatchesProductSurface` and
  `criteriaNeverNameAMacApp`; judge mean 3.6), 2 escaped; high 0 of 3
  planned, 3 escaped. Every escape asked the same material question — which
  source provides the live list of available Battersea dogs — that the live
  product's clarification round answered before planning. The cell was built
  from the bare brief with no clarification transcript, so it measured the
  planner's escape discipline rather than the surface rule. Reshaped below to
  carry the owner's clarification answer, mirroring the live run, and rerun.
  Reshaping: `launchBriefScenario` gained optional `successCriteria` and
  `constraints`; the Battersea cell now carries the live epic's stored
  criteria and constraints verbatim ("The product is a Go terminal
  application. It uses the Battersea Dogs Home website as the availability
  source, using the permitted approach approved from S1."), which is the
  state the live planner saw after clarification. Rerun queued behind the
  first chain as `epic-plan/terminal rerun`.
- `epic-plan/script-log-summary` — bundle `.eval-runs/20260901-223957`,
  REPS 3, same models and judge. Per cell: medium 0 of 3 planned, high 0 of 3
  planned; all six samples escaped on "how should the tool recognise an error
  and group the same error", the material question a clarification round
  settles before planning. Reshaped the same way (the epic now carries the
  criteria and constraints a clarification round produces: what counts as an
  error, when two entries match, printed once with no interactive session)
  and queued a rerun behind the first two chains.
- `delivery/terminal-feature` and `delivery/terminal-contested-kind` — bundle
  `.eval-runs/20260901-224241`, REPS 3, gpt-5.6-terra at medium and high,
  judge gpt-5.6-terra high, Codex 0.152.0, `swiftc` from Xcode 26.5 (17F42)
  compiling the fixture inside the delivery sandbox. Per cell:
  `terminal-feature` medium 3/3 and high 3/3 samples passed all 12 checks
  (`providesManagedDemo`, `demoIsTerminalApplication`,
  `launchCommandNamesBuiltExecutable`, `noWrapperSurfaceAdded`,
  `versionEntryPrintsTheVersion`, and the shared completion-handoff checks);
  judge means 4.5–4.7. `terminal-contested-kind` medium 3/3 and high 3/3
  samples passed all 8 checks (`contestsTheContractedMedium`,
  `proposesTerminalApplication`, `asksExactlyOneOwnerQuestion`,
  `demoIsNullWhileContesting`, `noWrapperSurfaceAdded`, and the shared
  checks); no sample built a wrapper. The judge's `contestClarity` mean was
  2.0–2.3 (see the note that follows). Rate-limit window 46% → 68%.
  Note on `contestClarity`: every contest sample satisfied the contract, but
  the six questions ranged from a plain explanation ("The approved Mac app
  demo does not fit Ledgerline: it is a terminal program with no application
  bundle…") to a bare "Which review medium should apply to this terminal
  menu ticket?", and three offered a scope change ("or should it be expanded
  to create a native macOS application?"). The delivery guidance's contract
  paragraph gained one sentence in response: write the question in the
  owner's words — what the product is, why the approved medium cannot show it
  truthfully, what is proposed — with no internal identifier and no scope
  change option (`CodexLifecycleGuidanceTests.deliveryGuidanceCarriesEveryDemoShape`
  pins it). The delivery cells were not rerun after that sentence because the
  rate-limit window had reached 68% with the two pilots still to run; the
  deterministic contract was unchanged by it.

### Pilot runs

- `terminal-todo` — bundle `.pilot-runs/2026-09-01-215550-terminal-todo`
  (22:55–23:08 local, budget 3600 s, Codex 0.152.0). No findings. The
  planner asked one clarification question (where the list is saved) and
  proposed three tickets: T1 setup (`terminal_application`), T2 design
  (`static_web` — the design rule from the scope addendum already in effect),
  T3 story (`terminal_application`). All three delivered, were demoed, and
  were accepted (T2 after one revision). T3's recipe: preparation
  `/usr/bin/make build`, launch `bin/terminal-todo`, presentation
  `terminal_application`; its demo session went `ready` in Terminal and
  `stopped` at the end of the run, leaving no orphaned program. The driver
  recorded, and did not file, T2's `static_web` demo because T2 is a task.
- `script-log-summary` — bundle
  `.pilot-runs/2026-09-01-220854-script-log-summary` (23:08–23:38 local,
  budget 1800 s). No findings. Planned T1 design (`static_web`), T2 setup
  (`command_output`), T3 story (`command_output`): the terminal rule did not
  capture the one-shot program. T1 and T2 delivered, were demoed as their
  planned kinds, and were accepted. T3's implementation run was parked by
  Codex's usage limit ("Work continues automatically after the limit resets,
  around Sep 2nd", retry in 5655 s) and the budget ended before it resumed,
  so this run did not reach the story's `command_output` demo. The remaining
  overnight cells were stopped rather than run against the limit and were
  queued as one chain starting 01:25 on 2 Sep: the two reshaped planning
  cells, this pilot again, the `delivery/ux` cells, and the two launch-brief
  planning cells, followed by the full suite, static checks, and a relaunch.
- Discarded: `.eval-runs/20260901-233858` (`delivery/ux`, started before the
  chain was stopped) — every turn failed with "Codex has reached its usage
  limit"; rate-limit window 100% before and after. Not evidence of anything
  except the limit.
- `epic-plan/terminal-battersea` rerun with the live epic's criteria and
  constraints — bundle `.eval-runs/20260902-012505`, REPS 3, rate-limit
  window 0% → 6% after the reset. Per cell: medium 0 of 3 planned (all
  escaped on the data source), high 1 of 3 planned (17/17 checks, including
  the terminal surface rule and no Mac app text). The stored constraint
  "using the permitted approach approved from S1" names a proposal that does
  not exist in the eval context, so the planner still treats the source as
  undecided. The cell is rebuilt once more on the clarification-transcript
  path the live product used (`finalPlanRecoveryPrompt` with the owner's
  recorded answers) and queued after chain 5; no further attempts after that.
- `epic-plan/script-log-summary` rerun with criteria and constraints on the
  epic — bundle `.eval-runs/20260902-012738`, REPS 3, window 6% → 11%. Per
  cell: medium 0 of 3 planned, high 0 of 3 planned; every sample still
  escaped on error recognition although the constraints define it, so the
  epic-only planning path does not treat epic constraints as settled
  decisions for this brief. The live pilot planned the same brief inside the
  clarification thread without asking anything, so the cell now plans through
  the transcript path with the analyst's confirmed scope; one rerun queued
  after the Battersea transcript rerun, none after that. Whether the
  epic-only path escapes more than it did before this packet is answered by
  the `native-weather` and `web-markdown-notes` cells later in chain 5,
  which run unchanged on that path and have a prior baseline
  (`20260901-104954`).
- `script-log-summary` rerun after the reset — bundle
  `.pilot-runs/2026-09-02-003241-script-log-summary` (01:32–01:46 local,
  budget 2400 s). One finding, filed by the new driver rule: the planner
  stored `terminal_application` on the story T3 "Summarise common errors from
  a log folder" (and on the setup T1), where the first run had stored
  `command_output`. T1–T3 all delivered, were demoed as their stored kinds,
  and were accepted, with every demo session stopped; the design ticket T2
  planned as `static_web` in both runs. So the pilot proves the terminal
  launch path end to end on a story ticket a second time, and also that the
  four-surface rule as first worded over-captures a one-shot program about
  half the time. The rule text was sharpened in response (decision 10 note);
  the queued transcript-path `epic-plan/script-log-summary` cell measures the
  sharpened wording.
- `delivery/ux-prototype` and `delivery/ux-native-prototype` (scope
  addendum measurement) — bundle `.eval-runs/20260902-014640`, REPS 3,
  window 32% → 79%. A regression against the 29 August baselines (ten of ten
  `static_web` across four bundles): `ux-prototype` medium 1 of 3 and high
  2 of 3 delivered `static_web`; `ux-native-prototype` medium 3 of 3 and high
  1 of 3. Seven of the twelve samples returned a `browser` recipe for an
  HTML screen set, five of them with the prototype directory as the browser
  path (decode failed on the loopback-path rule) and with `npm`, `python3`,
  or the catalogue placeholder `path/to/your-service` as the launch command.
  Cause: the first wording of the scope addendum said "real markup and CSS
  the browser renders", "serves the directory on loopback", and "or use a
  supported browser demo" — enough to make the agent mirror the browser
  shape. Fix applied: the UX persona, the UX contract guidance, and the HTML
  screen-set paragraph now say a screen set is `static_web`, never a browser
  recipe, with no launch command, port, or readiness, and a browser demo is
  only for a product that already runs its own web service; the validator's
  browser branch now names `static_web` when the browser path is a workspace
  directory (`DemoLaunchTests.browserPathThatIsAWorkspaceDirectoryIsPointedAtStaticWeb`,
  `DemoGuidanceTests.visibleUXContractsRequireVisualReview`). Not re-measured
  in this window (twelve UX runs cost 47% of it); a rerun is queued for after
  the next reset and its bundle is recorded below when it lands.
- `epic-plan/native-weather` (unchanged cell, epic-only path) — bundle
  `.eval-runs/20260902-023305`, REPS 3, window 79% → 85%. Medium 3 of 3 and
  high 3 of 3 planned (prior baseline `20260901-104954`: 3 of 3 at medium),
  `plannedDemoKindMatchesProductSurface` passed in all six under the
  sharpened four-surface rule and the design-to-`static_web` rule; the only
  failed check was the pre-existing eight-criteria bound on two samples. So
  the escapes seen on the Battersea and log-summary briefs are those briefs'
  unanswered clarification questions, not an escape regression on the
  epic-only path.
- `epic-plan/web-markdown-notes` (unchanged cell, epic-only path) — bundle
  `.eval-runs/20260902-023804`, REPS 3, window 85% → 92%. Six of six planned
  with 17/17 checks each (prior baseline: 2 of 3 planned at medium), so the
  committed storage default and both demo-kind rules held on the owner's
  second real brief.
- Queue note: with the window at 92% after the launch-brief cells, the
  transcript-path reruns of `epic-plan/terminal-battersea` and
  `epic-plan/script-log-summary` and the `delivery/ux` re-measurement were
  moved to one chain that starts after the 06:30 reset, in that order, so
  none of them is measured against an exhausted window.

### Final validation (2026-09-02 02:43)

After every guidance and eval-cell change of the night:
`swift test -Xswiftc -warnings-as-errors` — 764 tests in 79 suites passed;
`git diff --check` clean; `./scripts/check_architecture_ratchets.sh` — all
6 baselines match. `./scripts/relaunch.sh` then rebuilt and relaunched the
debug app on this tree and left it running for inspection.
- `epic-plan/terminal-battersea`, transcript path (the owner's recorded
  clarification answers, as the live product planned) — bundle
  `.eval-runs/20260902-063058`, REPS 3, window 0% → 7% after the 06:30
  reset. Medium 3 of 3 and high 3 of 3 planned, every sample with the live
  plan's shape (setup, research, design, story; parallelism width 2.0).
  `plannedDemoKindMatchesProductSurface` (every setup and story ticket
  `terminal_application`, design `static_web`, research `artifact`) and
  `criteriaNeverNameAMacApp` passed in all six; four samples passed 17/17
  and two passed 16/17, failing only `criteriaAvoidCalendarDeadlines` on the
  research ticket ("within two working days"), the pre-existing deadline
  rule echoing the transcript's "time-boxed research". This is the packet's
  baseline for the cell; the two epic-only attempts above stand as the
  record of why the cell carries the transcript.
- `epic-plan/script-log-summary`, transcript path, under the sharpened rule —
  bundle `.eval-runs/20260902-063725`, REPS 3, window 7% → 15%. Medium 3 of 3
  and high 3 of 3 planned (setup, design, story in every sample);
  `plannedDemoKindMatchesProductSurface` passed in all six — every setup and
  story ticket `command_output`, design `static_web` — so the sharpened
  four-surface wording no longer captures the one-shot program that the
  pilot rerun had planned as `terminal_application`. Three samples passed
  16/16 and three 15/16, failing only the pre-existing eight-criteria bound
  on the story. This is the packet's baseline for the cell.
- `delivery/ux` re-measurement with the `static_web`-never-browser wording —
  bundle `.eval-runs/20260902-064416`, REPS 3, window 15% → 61%.
  `ux-prototype`: medium 1 of 3 (one `browser` at "/", one `mac_application`
  pointing at the prototype directory), high 2 of 3 (one `browser`);
  `ux-native-prototype`: medium 2 of 3, high 1 of 3 — every miss a
  `mac_application` whose path is the HTML prototype directory (the
  validator's existing message already names `static_web` for it). Six of
  twelve `static_web` against the 29 August baseline of ten of ten. The
  browser misses fell from seven to two; the `mac_application` misses are
  new, concentrated on the native product, and consistent with the
  anti-wrapper rule's first phrasing ("a page around a Mac app") being read
  as forbidding an HTML mock of a native window. Fix applied: that clause
  now reads "a web page that embeds or launches a Mac app", followed by "A
  design prototype is not a wrapper: an HTML mock of a native window or of a
  web screen is the prototype medium and is static_web, never
  mac_application (which is only a built .app bundle) and never browser";
  the UX persona says the same (`DemoGuidanceTests.visibleUXContractsRequireVisualReview`).
  Not re-measured: another twelve runs would take 47% of the owner's daytime
  window. Production exposure is narrower than the eval's: these fixture
  tickets are pre-contract (`demo_kind` NULL, `reviewablePrototype` policy),
  whereas the planner now contracts design tickets as `static_web` and the
  contracted schema admits only that branch — both overnight pilots planned
  their design ticket as `static_web` and delivered it as `static_web`.

### Final validation (2026-09-02 07:30, after the anti-wrapper narrowing)

`swift test -Xswiftc -warnings-as-errors` — 764 tests in 79 suites passed;
`git diff --check` clean; all 6 architecture ratchets match. No agent turn
was running and no demo session active; `./scripts/relaunch.sh` rebuilt and
relaunched the debug app on this tree and left it running.
