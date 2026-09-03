# Work packet: design tickets deliver HTML screen sets under `static_web`, not PDFs

Owner decision (2026-09-01, evening): UX design tickets were steered to PDF
screen sets and the results were poor — misaligned layouts, wrong or missing
fonts. Design mock-ups are to be built as HTML instead, integrated as deeply
as the terminal demo kind (`2026-09-01-terminal-demo-kind-handover.md`).

This handover is for a fresh session: the session that wrote it ran out of
context. It records what landed in the working tree, what the measurements
say, and the exact run plan to reach the bar. The bar is the 29 August
baseline: the two UX delivery eval cells at ten of ten `static_web` with real
markup text, plus the new planning rule holding on every launch brief. Finish
every step, record every number in the completion evidence, and do not
create a further handover.

## Run plan (do in order)

1. **Already done — read the result, do not rerun.** The third run
   (`.eval-runs/20260902-085455`, 08:54–09:35 on 2 September) is recorded in
   the table below: `ux-prototype` 3 of 6 `static_web`, `ux-native-prototype`
   0 of 3 at medium (every miss a `mac_application` whose path is the HTML
   directory), and its three high samples failed on the Codex usage limit,
   which the run drove from 61% to 100%. Wait for the window to reset before
   any eval (resets were observed at about 01:13 and before 06:30 on
   2 September, so expect roughly five hours after it filled at 09:35). The
   narrowed anti-wrapper sentence did not move the `mac_application` misses,
   so the cause is elsewhere: start at step 2. To read any bundle's kinds:

   ```sh
   python3 - <<'EOF'
   import json
   r = json.load(open(".eval-runs/20260902-085455/results.json"))
   for rec in (r if isinstance(r, list) else r.get("records") or r.get("results")):
       d = json.loads(rec.get("rawResponse") or "{}"); p = ((d.get("demo") or {}).get("presentation") or {})
       print(rec["scenarioID"], rec["effort"], rec["repetition"], p.get("kind"), p.get("path"), rec.get("decodePassed"))
   EOF
   ```

   Record the counts in the table below. Both cells at 3 of 3 for both
   efforts on `demoIsStaticWeb` (a miss on another check is not a kind miss)
   means the guidance is at the bar: go to step 5.
2. **First probe: a designer-only demo catalogue.** Every `browser` miss so
   far copied the catalogue's literal browser shape (`path/to/your-service`,
   `npm`, `python3`), and every `mac_application` miss handed over the HTML
   directory as a bundle. The catalogue is one shared block,
   `CodexLifecycleGuidance.productChangeDelivery`, used for every
   product-change role. Give `ticketDeliveryInstructions(mode:)` a `role:`
   parameter (call site: `CodexTicketExecutor.developerInstructions`, line
   ~317) and, for `.uxDesigner`, replace the six-bullet catalogue with a
   design catalogue of two shapes: `static_web` (the prototype or HTML
   screen set) and `artifact` (only for a document-first contract), each
   with its literal JSON shape, followed by one sentence: "A design delivery
   never returns browser, mac_application, command_output, or
   terminal_application; a working product surface is a delivery ticket's
   demo, not a design ticket's." Keep the anti-wrapper sentence, the contest
   paragraph, and the fidelity paragraph. Update
   `CodexLifecycleGuidanceTests.deliveryGuidanceCarriesEveryDemoShape` (six
   shapes for the implementer, two for the designer, none for the analyst)
   and `DemoGuidanceTests.visibleUXContractsRequireVisualReview`. Run the
   focused suites, then `SPEDITO_EVAL_REPS=3 ./scripts/evals.sh delivery/ux
   medium` (six runs, about a quarter of a rate-limit window; the report's
   first lines print the window before and after). Then the full matrix once
   the reduced run is six of six.
3. **If the probe is not enough: ablate the wording.** Measure the two cells
   at medium, REPS 3, under (a) the committed `HEAD` text of the demo
   section for the designer (take it from `git show
   HEAD:Sources/SpeditoCore/Codex/CodexLifecycleGuidance.swift`, the
   paragraph beginning "Use static_web for a self-contained interactive
   prototype"), (b) `HEAD` plus the 1 September catalogue, (c) plus this
   packet's sentences. The first state that drops below six of six names
   the cause; keep the smallest text that stays at six of six.
4. **Structural lever, owner decision required.** If wording alone cannot
   hold ten of ten, ask the owner whether a pre-contract UX designer ticket
   with a prototype contract should narrow `DeliveryDemoPolicy` to
   `.contracted(.staticWeb)` instead of `.reviewablePrototype` (see "What is
   not at the bar" below). Do not make that change without the answer.
5. **Close.** Full default validation (`swift test -Xswiftc
   -warnings-as-errors`, `git diff --check`,
   `./scripts/check_architecture_ratchets.sh`), `./scripts/relaunch.sh` left
   running, completion evidence filled in below (bundle ids, per-cell
   `static_web` counts, window before and after, the guidance state each
   bundle measured), `docs/product-spec.md` and `docs/technical-design.md`
   checked against the final wording, and the memory note
   `terminal-demo-kind-packet` updated. Nothing is committed on this tree;
   commit only with the owner's go-ahead, and never rewrite history.

## Problem

`static_web` ("Interactive prototype") already is a workspace directory with
`index.html` that Spedito serves on loopback and opens in the browser. No new
kind was needed. Three rules steered design work to PDFs:

1. The planner's mechanical rule assigned `artifact` to every design ticket.
2. `CodexLifecycleGuidance.uxTicketContractGuidance` (refinement and
   planning) named "one inert reviewable file — PDF or an accepted image
   format" as the screen-set medium.
3. The delivery guidance said a screen set "delivered as one PDF or image
   file is an artifact, never static_web", and the UX persona listed PNG/PDF
   mock-ups as an ordinary fallback.

A PDF rendered inside the sandbox loses typography, alignment, and
interaction, and the sandbox cannot check it (see the pixel-glyph incident in
`2026-09-01-demo-preparation-parity-handover.md`). HTML served by Spedito's own
server renders with the browser's typography and needs no runtime.

## Behavior to preserve or add

- A design ticket about a visible interface plans as `static_web`; the
  proposal card and stored ticket read "You'll review this as: An interactive
  prototype". Research tickets and explicitly document-first design outcomes
  (copy reviews, service blueprints, accessibility audits) plan as `artifact`.
- Refinement criteria for visible design work ask for an HTML screen set or
  clickable prototype covering the named states, never a PDF or image format.
- Delivery of such a ticket returns a `static_web` recipe: a workspace
  directory with `index.html` linking one page per screen or state, real
  markup and CSS, system font stacks, no external network resources, no
  launch command, port, or readiness. Never `browser`, never
  `mac_application`, never a PDF.
- The tech lead returns a PDF or image screen set delivered where the
  contract expects `static_web`, or where the ticket is not document-first,
  with changes requested naming the HTML screen set.
- Changed by owner decision (2 September, 15:20, "sounds good to me"): a
  pre-contract UX designer ticket whose contract promises a prototype is
  contracted by `DeliveryDemoPolicy` to `static_web` alone; the
  `reviewablePrototype` case (admitting `browser` and `mac_application` too)
  is removed. The prompt states the derived medium and a contest from such a
  ticket keeps the derived kind as the "keep" option.
- Unchanged: the artifact validator, every other kind, every other
  pre-contract role (full enum).

## Non-goals

- No new demo kind and no change to how `static_web` is served or validated.
- No owner-facing string change (the "An interactive prototype" medium text
  stays).
- No change to document-first design outcomes: they stay `artifact`.

## Decisions (made)

1. **Planning rule.** One shared string,
   `CodexTicketSuggestionGenerator.designMediumRule`: "design tickets about a
   visible interface use static_web, a self-contained HTML screen set or
   clickable prototype Spedito serves in the browser; research tickets and
   explicitly document-first design outcomes such as copy reviews, service
   blueprints, and accessibility audits use artifact". Interpolated into the
   planning prose, the schema description, and the repair prompt; repeated in
   `docs/product-spec.md` and summarised in `docs/technical-design.md`.
2. **Contract guidance.** `uxTicketContractGuidance` names the HTML screen
   set under `static_web` as the default medium, "real markup and CSS that
   Spedito serves itself, one page per screen or state with an index page
   linking them, needing no established product runtime and no web service",
   and forbids asking for a PDF or image unless the outcome is explicitly
   document-first.
3. **Persona and delivery guidance.** The UX persona builds a `static_web`
   prototype or HTML screen set (system font stacks, consistent spacing
   scale, aligned layouts, realistic content, no external network resources,
   no web service of its own) and says: "its recipe is static_web, never
   browser"; "A prototype of a native window is still static_web, never
   mac_application, which is only a built .app bundle"; "A browser demo is
   only for a product that already runs its own web service"; PNG/PDF only for
   an explicitly document-first contract. The delivery guidance's `static_web`
   bullet admits "or HTML screen set", its artifact bullet steers screen sets
   to HTML, and a fidelity paragraph states the HTML rules and "It is never a
   browser recipe".
4. **Anti-wrapper rule (from the terminal packet) narrowed.** "Never wrap the
   product in another surface … a web page that embeds or launches a Mac app
   …" followed by "A design prototype is not a wrapper: an HTML mock of a
   native window or of a web screen is the prototype medium and is
   static_web, never mac_application … and never browser."
5. **Validator hint.** A `browser` recipe whose path does not begin with `/`
   is rejected with a message naming `static_web` for a workspace directory
   of HTML pages (`DemoLaunchSpecificationValidator`, browser branch). The
   `mac_application` branch already named `static_web` for a page directory.
6. **Measurement.** `EvalEpicPlanChecks.plannedDemoKindMatchesProductSurface`
   requires `static_web` for UX designer tickets unless
   `documentFirstDesignPattern` matches the title or body, and `artifact` for
   research. The two UX delivery cells (`delivery/ux-prototype`,
   `delivery/ux-native-prototype`) require `static_web` and real markup text.

## Current state (landed 2026-09-01/02, uncommitted)

Files: `CodexTicketSuggestionGenerator.swift` (`designMediumRule` and its
three uses), `CodexLifecycleGuidance.swift` (contract guidance, `static_web`
and artifact bullets, HTML fidelity paragraph, narrowed anti-wrapper
sentence, reviewer sentence), `AgentPersonaDefaults.swift` (UX persona),
`DemoLaunch.swift` (browser-path hint), `EvalEpicPlanChecks.swift`,
`EvalSupportTests.swift`, `DemoGuidanceTests.swift`, `CodexAdapterTests.swift`,
`CodexLifecycleGuidanceTests.swift`, `DemoLaunchTests.swift`,
`docs/product-spec.md`, `docs/technical-design.md`.

Tests pinning it: `DemoGuidanceTests.visibleUXContractsRequireVisualReview`,
`CodexAdapterTests.suggestionDemoKindDecoding` (rule text in prose and
schema), `EvalEpicPlanCheckTests.plannedDemoKindMatchesProductSurface`,
`DemoLaunchTests.browserPathThatIsAWorkspaceDirectoryIsPointedAtStaticWeb`,
`CodexLifecycleGuidanceTests.deliveryGuidanceCarriesEveryDemoShape`.

Full suite at 07:30 on 2 September: 764 tests in 79 suites passed;
`git diff --check` clean; ratchets match; app relaunched on that tree.

Planning side is proven:

- Both overnight pilots (`terminal-todo`, `script-log-summary` twice) planned
  their design ticket as `static_web` and delivered it as `static_web`.
- `epic-plan/native-weather` (`.eval-runs/20260902-023305`) and
  `epic-plan/web-markdown-notes` (`20260902-023804`): six of six samples
  each passed `plannedDemoKindMatchesProductSurface` with the design rule.
- `epic-plan/terminal-battersea` (`20260902-063058`) and
  `epic-plan/script-log-summary` (`20260902-063725`), transcript path: six of
  six each, design `static_web` in every sample.

## What is not at the bar: pre-contract UX delivery

The two UX delivery cells use pre-contract tickets (`demo_kind` NULL, so the
`reviewablePrototype` schema admits `static_web`, `browser`, and
`mac_application`). They measure the designer's own kind choice from the
guidance alone, which is exactly what a ticket created before the planning
rule, or edited by hand, still relies on.

| Bundle | Guidance state | `ux-prototype` static_web | `ux-native-prototype` static_web | Misses |
| --- | --- | --- | --- | --- |
| 29 Aug (`20260829-143215`, `-150439`, `-153041`, `-195226`) | before this packet, medium only | 7/7 | 4/7 | 1 `browser`, 3 `mac_application` — the check existed; the earlier "none on kind" reading of these bundles was wrong |
| 29 Aug `20260829-210809` (the real baseline) | before this packet, medium only | 3/3 | 3/3 | none |
| `20260902-014640` | first HTML wording ("the browser renders", "serves on loopback", "or use a supported browser demo") | 1/3 medium, 2/3 high | 3/3 medium, 1/3 high | 7 `browser` (5 with the prototype directory as the browser path, launch `npm`/`python3`/`path/to/your-service`) |
| `20260902-064416` | "static_web, never browser" wording + browser-path validator hint | 2/3 medium, 2/3 high | 2/3 medium, 1/3 high | 2 `browser` at "/", 4 `mac_application` pointing at the HTML directory (3 on the native product) |
| `20260902-085455` | + narrowed anti-wrapper sentence, "a prototype of a native window is still static_web" | 1/3 medium, 2/3 high | 0/3 medium; high not measured (all three turns failed after the window reached 100%) | 1 `browser` at "/", 5 `mac_application` pointing at the HTML directory (3 on the native product); window 61% before, 100% after |
| `20260902-115609` | + designer-only two-shape catalogue (step 2); Mac asleep, lid closed 09:25–14:55 | not measured: all three turns stalled | 0/1 (`browser`, `launchCommand` emitted before `presentation`); two turns stalled | environmental: Codex's 900 s inactivity watchdog fired inside 15-minute sleep cycles; window 0% before, 18% after |
| `20260902-145919` | + designer-only two-shape catalogue (step 2), machine awake under `caffeinate` | 3/3 medium, 10/10 checks each | not measured: weekly usage limit reached before the cell ran (resets Monday 7 September 04:46) | none; window 18% before, 31% after |

Reading of the misses so far:

- The `browser` misses copy the catalogue's browser shape (the placeholder
  `path/to/your-service` appeared verbatim). Naming "browser" and "loopback"
  near the screen-set text was enough to prime it; the second wording cut
  those misses from seven to two.
- The `mac_application` misses appeared only after the 1 September
  catalogue and this packet's sentences entered the delivery guidance, and
  cluster on the native product, whose ticket says the window design "must
  be reviewable as an interactive prototype". Narrowing the anti-wrapper
  sentence (decision 4) did not reduce them (third run: five of nine
  measured samples), so that sentence is not the driver. Two candidates
  remain: the catalogue's `mac_application` bullet and shape sitting in a
  designer's instructions at all, and the persona/paragraph sentences that
  mention `mac_application` by name while forbidding it — each mention is a
  cue. The designer-only catalogue in step 2 removes both at once; the
  ablation in step 3 separates them if needed.

**The baseline is older than it looks.** The UX cells were last measured on
29 August. On 1 September the demo-contract packets
(`2026-09-01-demo-contract-root-cause-handover.md`, `-completion-handover.md`)
rewrote the delivery guidance's demo section into the per-kind catalogue with
literal JSON shapes — including the `browser` example whose placeholder
`path/to/your-service` the misses copied verbatim — and that rewrite is still
uncommitted in the same tree (`git diff HEAD --
Sources/SpeditoCore/Codex/CodexLifecycleGuidance.swift`). No UX cell was run
between that rewrite and this packet's first measurement, so part of the drop
from ten of ten may predate the HTML wording. Any ablation must therefore
include the catalogue text, not only this packet's sentences.

If the third run is still short of ten of twelve, the remaining levers, in
order:

1. **Ablate.** Measure the two cells at medium with REPS 3 (six runs, about
   a quarter of a window) under, in turn: (a) the committed HEAD text of the
   demo section for the UX role (the 29 August state), (b) HEAD plus the
   1 September catalogue, (c) plus this packet's sentences. The first state
   that drops below ten of ten names the cause. A cheaper first probe: keep
   the catalogue but drop the literal `browser` JSON shape from the UX
   designer's instructions only (the shape exists to teach implementers a
   service recipe; a designer never needs it), since every browser miss
   copied that shape. The full matrix (medium and high, REPS 3, both cells)
   costs about 47% of a window.
2. **Put the kind in the ticket.** The pre-contract heuristic can also be
   retired for design work: when `demo_kind` is NULL and the assignee is a UX
   designer with a prototype contract, `DeliveryDemoPolicy` could narrow to
   `static_web` alone instead of `reviewablePrototype`. That makes the miss
   structurally impossible, as it already is for planned tickets, at the cost
   of a UX ticket that genuinely needs a working product surface having to be
   planned with that kind. This changes `DeliveryDemoPolicy.init` and its
   tests (`WorkflowPolicyTests.deliveryDemoPolicyHonoursTheStoredContract`,
   `DemoLaunchTests.reviewablePrototypeSchemaAdmitsOnlyInteractiveKinds`) and
   `docs/technical-design.md`'s NULL-contract paragraph; decide it with the
   owner before doing it.

Do not remove the two cells' `demoIsStaticWeb` check or contract the fixture
tickets to make the number green: the cells exist to measure the guidance.

## Verification

- Focused: `swift test --filter 'DemoGuidanceTests|CodexAdapterTests|CodexLifecycleGuidanceTests|DemoLaunchTests|EvalEpicPlanCheckTests'`
- Evals: `SPEDITO_EVAL_REPS=3 ./scripts/evals.sh delivery/ux` (full matrix)
  or `SPEDITO_EVAL_REPS=3 ./scripts/evals.sh delivery/ux medium` (reduced).
  Read `report.md` and, for the kind each sample chose, the `rawResponse`
  field of `results.json` (`demo.presentation.kind` and `.path`).
- Full default validation, `git diff --check`, ratchets, relaunch, as in
  `AGENTS.md`. Launched-process suite not required: no shell wiring changes.

## Working notes

- Shared, dirty working tree with several uncommitted packets, including the
  terminal demo kind packet; per-layer commits are not separable. Validate and
  relaunch with `--scratch-path` if another session holds `.build`.
- Codex rate-limit windows: a full UX matrix run costs about 47% of a window;
  a planning cell (six samples) about 5–7%; a pilot 15–30%. The window reset
  observed overnight was at about 01:13 and again before 06:30.
- Planning eval cells for briefs whose clarification round answers a material
  question must carry the transcript (`launchBriefScenario(clarification:)`,
  which switches to `finalPlanRecoveryPrompt`); the epic-only path escapes on
  the unanswered question regardless of epic constraints.
- The owner's outstanding Battersea steps from the terminal packet (T4 SQL
  update with the app quit, T2/T4 criterion edits, Request changes on T2 and
  the contest answer, the seven inspection items) are unrelated to this
  packet but still open.

## Completion evidence

Recorded 2 September, 15:20. Steps 1 and 2 are done; the rest of the
measurement plan is blocked on Codex's weekly usage limit (secondary window
100%, resets Monday 7 September 04:46), and step 4 is blocked on the owner's
answer. No further handover is created; this section is the record.

### Step 1: third run, `20260902-085455` (narrowed anti-wrapper sentence)

- Window 61% before, 100% after. Nine samples ran; the three native high
  samples failed (two stalled while the Mac slept, one hit the usage limit).
- `ux-prototype`: 1/3 medium (1 `browser` at "/" with a no-op launch command,
  1 `mac_application` at `prototype/invoice-list`), 2/3 high (1
  `mac_application` at `prototype/invoice-status`).
- `ux-native-prototype`: 0/3 medium, all `mac_application` pointing at the
  HTML directory.
- Not at the bar, so step 2 ran.

### Step 2: designer-only catalogue

Code: `CodexLifecycleGuidance.productChangeDelivery(role:)` joins
`productChangeDeliveryPreamble`, a role-specific catalogue
(`implementerDemoCatalogue` with six shapes; `designerDemoCatalogue` with
`static_web` and `artifact` plus the sentence "A design delivery never returns
browser, mac_application, command_output, or terminal_application; a working
product surface is a delivery ticket's demo, not a design ticket's"), and
`productChangeDeliveryFidelity`. `ticketDeliveryInstructions(mode:role:)`
takes the role and `CodexTicketExecutor.developerInstructions` passes
`assignee.role`. The implementer text is byte-identical to before. Tests:
`CodexLifecycleGuidanceTests.deliveryGuidanceCarriesEveryDemoShape` (six
shapes for the implementer, exactly `[static_web, artifact]` for the designer,
none for the analyst; the designer text carries no browser shape,
`path/to/your-service`, or `YourApp.app`) and
`DemoGuidanceTests.visibleUXContractsRequireVisualReview`.
`docs/technical-design.md` describes the role-specific catalogue and the
narrowed anti-wrapper sentence.

Measurement:

- `20260902-115609` (reduced run, medium, REPS 3): invalid. The lid was
  closed at 09:25 and the Mac cycled through 15-minute "Maintenance Sleep"
  periods until 14:55 (`pmset -g log`); Codex's inactivity watchdog is 900 s,
  so five of six samples stalled on both attempts. The one sample that ran
  awake (`ux-native-prototype` medium r3) returned `browser` at
  `design/invoice-status-prototype` with `launchCommand {"executable":
  "false", "timeoutSeconds": 1}` although its own progress message said the
  prototype "will be served as a static web review" (see finding 1 below).
- `20260902-145919` (reduced run, medium, REPS 3, under `caffeinate -i`):
  `ux-prototype` 3/3 `static_web` with 10/10 checks each (paths
  `prototype/invoice-status`, `prototype`, `prototype/invoice-status`; judge
  means 4.7, 4.5, 4.7). `ux-native-prototype` did not run: all three turns
  failed with "Codex has reached its usage limit … resets around Sep 7th",
  the weekly window. Primary window 18% before, 31% after.

### Blocked measurement (weekly usage limit, resets Monday 7 September 04:46)

- `ux-native-prototype` at medium under the designer catalogue: 0 of 3
  measured.
- The full matrix (both cells, medium and high, REPS 3).
- Step 3 ablation, if the native cell is short.

Run, in order, once the weekly window has reset and with the Mac awake:
`caffeinate -i env SPEDITO_EVAL_REPS=3 ./scripts/evals.sh delivery/ux-native medium`,
then the full matrix `caffeinate -i env SPEDITO_EVAL_REPS=3 ./scripts/evals.sh delivery/ux`.
Keep the lid open; a closed lid stalls every turn.

### Findings that change the reading of the misses

1. **Key order, not only wording, produces the browser misses.** The emitted
   demo object's key order varies between samples of one run, so the
   structured-output grammar does not fix it; the model chooses it. In every
   `browser` miss since 08:54 (`085455` medium r1, `115609` native r3, and
   `064416` high r2 with `readiness` first) the model wrote a non-null
   `launchCommand` or `readiness` before `presentation`, and under the
   three-branch `reviewablePrototype` schema that commits the recipe to the
   `browser` branch before the kind is written. The `mac_application` misses
   are free choices with `launchCommand` null. Prose cannot remove the first
   mechanism; only the schema can (step 4).
2. **The 29 August baseline was misread.** The `demoIsStaticWeb` check
   existed on 29 August (commit `325da46`). Bundles `143215`, `150439`,
   `153041`, and `195226` contain four kind misses in fourteen UX samples (one
   `browser`, three `mac_application`, three of them on the native product);
   only `210809` was clean at 6/6 (medium only). Wording alone has never held
   ten of ten across consecutive bundles.

### Step 4: owner decision, answered yes and implemented

Asked on 2 September at 15:05 with the recommendation to narrow; the owner
answered "sounds good to me" at about 15:20. Implemented the same afternoon:

- `DeliveryDemoPolicy.init` (`CodexLifecycleGuidance.swift`): a NULL-contract
  UX designer ticket whose title, body, or criteria mention "prototype" is
  `.contracted(.staticWeb)`; the `reviewablePrototype` case and its
  three-branch list in `CodexTicketExecutor.demoLaunchSpecificationSchema`
  are removed, leaving one path. New `contractedKind` accessor.
- `CodexTicketExecutor.demoKindContractContext(_:deliveryDemoPolicy:)`: a
  NULL-contract ticket under a contracted policy states "its review medium is
  static_web — An interactive prototype … the result schema admits no other",
  so the prompt and the schema agree. `prompt` derives the policy from the
  assignee; `revisionPrompt` and `recoveryPrompt` take
  `deliveryDemoPolicy:` (default `.anyKind`, which renders only the stored
  contract) and the coordinator passes the policy it already computes,
  hoisted above the prompt builds.
- `TicketDeliveryWorkflowCoordinator`: a contest from a NULL-contract ticket
  uses the derived kind as the "keep" option
  (`effectiveContract = item.demoKind ?? policy.contractedKind`), and the
  owner's change lands on the ticket exactly as for a stored contract.
- Tests: `WorkflowPolicyTests` (both designer expectations now
  `.contracted(.staticWeb)`, implementer NULL stays `.anyKind`),
  `DemoLaunchTests.preContractPrototypeSchemaAdmitsOnlyStaticWeb` (derived
  policy → schema branches exactly `[static_web]` plus the null branch),
  `CodexAdapterTests.promptsCarryTheDemoKindContract` (derived medium text in
  the context and the full prompt; `.anyKind` renders none), and
  `TicketDeliveryWorkflowCoordinatorTests.preContractPrototypeContestUsesTheDerivedKind`
  (designer harness, NULL contract, contest proposes `artifact`: options are
  Spedito's canonical change and keep-`static_web` pair, and the accepted
  change persists `artifact` on the ticket). `makeRecoveryHarness` gained
  `assigneeRole:` and `acceptanceCriteria:` parameters.
- Docs: `docs/technical-design.md` NULL-contract paragraph rewritten;
  `docs/product-spec.md` gains one sentence on pre-contract design tickets
  reviewing as an interactive prototype and contesting rather than
  substituting.
- Effect on measurement: the two UX cells' `demoIsStaticWeb` check is now
  structural (the schema admits nothing else); they continue to measure
  decode, markup, and quality. The 7 September runs listed above remain
  worthwhile for that, and the ablation (step 3) is moot.

### Step 5: close

Step 2 tree (09:07): full suite 764 tests in 79 suites passed; focused
suites (`DemoGuidanceTests|CodexAdapterTests|CodexLifecycleGuidanceTests|DemoLaunchTests|EvalEpicPlanCheckTests`)
139 tests in 5 suites passed; relaunched 15:13.

Step 4 tree (afternoon): focused suites
(`WorkflowPolicyTests|DemoLaunchTests|CodexAdapterTests|TicketDeliveryWorkflowCoordinatorTests|CodexLifecycleGuidanceTests|DemoGuidanceTests`)
159 tests in 6 suites passed; full suite and relaunch recorded below.

- Full suite on the step 4 tree: 765 tests in 79 suites passed
  (`swift test -Xswiftc -warnings-as-errors --scratch-path .build-claude`,
  15:57). `git diff --check`: clean. `./scripts/check_architecture_ratchets.sh`:
  "Architecture ratchets match all 6 baselines."
- `./scripts/relaunch.sh` at 15:57:40 on the step 4 tree, left running. The
  process exited with code 0 at 01:10 on 3 September as the Mac woke from
  sleep on battery; run `./scripts/relaunch.sh` again before inspecting.
- `docs/product-spec.md` and `docs/technical-design.md` checked against the
  final wording (see step 4 above); no owner-facing string changed.
- Launched-process suite not run: no application-shell wiring changed.
- Memory note `terminal-demo-kind-packet` updated.
- Nothing committed; the tree is shared and dirty. Commit only with the
  owner's go-ahead.
