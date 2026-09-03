# Work packet: demo preparation must run the product's own scripts reliably

## Problem

Work that passed every implementation-time check fails when Spedito prepares
its managed demo, because the demo runtime denies operations the product's own
scripts legitimately perform — most visibly, deleting files and directories
those scripts created. The owner presses Demo on reviewed, ready work and gets
a failure wall of raw tool output. This is the purest form of "the agent fails
at creating a demo," and it recurs across products.

Live evidence, three independent occurrences:

1. **Native Weather App, 2026-09-01 10:24** (product workspace
   `ED871CF3-0A51-4C99-9FE2-EAAF41B1CBED`, T1 candidate v1 `ready_for_demo`,
   `demo_sessions` row failed at 10:24:13): preparation ran `xcodebuild`
   (headermap deprecation warning; "DVTFilePathFSEvents: Failed to start fs
   event stream"; "CoreSimulatorService connection became invalid"), then died
   on cleanup:
   `rm: .demo/NativeWeatherApp.app/Contents/MacOS: Operation not permitted`,
   cascading through `.demo/NativeWeatherApp.app`, `.demo` itself.
2. **Markdown notes pilot, 2026-08-30** (bundle
   `.pilot-runs/2026-08-30-223943-web-markdown-notes`, T1 work log 22:56:53):
   after five review revisions finally passed, managed demo verification
   failed with `curl: (7) Failed to connect to 127.0.0.1 port 4174` and
   `rm: …/.spedito-demo-runtime/tmp/markdown-notes-build.UzStjo: Operation
   not permitted` — the product's `mktemp`-based build dir could not be
   removed by the script that created it, and the readiness probe used a port
   the served process did not.
3. The failure text reaching the owner is raw tool output including worktree
   paths — a separate failure-contract violation ("worktree" is a banned
   owner-facing marker in `Tests/SpeditoAppTests/Pilot/PilotConventions.swift`).

## Mechanism, as traced so far

`MacOSDemoLauncher.runPreparation` executes each recipe command through
`runToCompletion` → `managedRequest(...)`
(`Sources/SpeditoApp/MacOSDemoLauncher.swift`, ~line 528 onward), which builds
a `CodexManagedCommandRequest` with
`permissionProfile: CodexPermissionProfiles.demo` (`"spedito-demo"`,
`Sources/SpeditoCore/Codex/CodexManagedCommand.swift` ~line 497). The profile
name is sent to the Codex app server
(`Sources/SpeditoCore/Codex/CodexAppServerClient.swift` ~line 1174), which
enforces the actual sandbox rules. The runtime scaffolds
`.spedito-demo-runtime/{tmp,cache,home,data}` inside the preview worktree and
points `TMPDIR`, module caches, and `CFFIXED_USER_HOME` at it.

Open questions the fix must answer (do not assume — reproduce and observe):

- What exactly does the `spedito-demo` profile allow for write/unlink, and
  where is that defined (app-side configuration at connect, or Codex-side
  named profile)? The denials hit paths *inside* the preview worktree
  (`.demo/…`) and *inside the runtime's own tmp*, both of which preparation
  commands must plausibly own end to end.
- Whether the `.demo` contents were created by an earlier preparation run
  (e.g. the tech-lead smoke verification) such that a later run cannot delete
  them — ownership, flags, or per-run sandbox identity.
- Why the readiness probe and the launched service disagreed on the port in
  occurrence 2 (`{{PORT}}` substitution vs the readiness check's port).
- Whether the CoreSimulator/XPC noise in occurrence 1 is benign (build still
  produced the bundle) or will hard-fail other Xcode project shapes; delivery
  runs obtain granted framework paths via the permission flow, and the demo
  profile's relationship to remembered product grants needs stating.

## Behavior to preserve or add

- A demo recipe whose preparation commands create, overwrite, and delete
  files and directories anywhere inside the preview worktree and the provided
  `TMPDIR` succeeds, from a clean detached checkout, every time — including
  when a previous preparation left artifacts behind.
- The readiness probe always targets the exact port injected into the launch
  command.
- Least privilege is preserved: nothing outside the preview worktree and the
  demo runtime becomes writable or deletable.
- A preparation failure reaches the owner per the failure contract: a stable
  category, one concise owner-facing explanation, retry validity, and the raw
  tool output retained as technical evidence — never pasted whole into the
  work log or alert (no worktree paths, no XPC dictionaries).
- The morning's stray leftover pattern (a demo app process from a prior
  session still running days later — `HandsOff.app`, observed 2026-08-30) is
  in scope only insofar as failed preparations must not strand partial
  `.demo` state that poisons the next attempt.

## Non-goals

- No changes to recipe validation or demo-kind rules
  (`DemoLaunchSpecificationValidator`) — separate packet.
- No weakening of the sandbox as a convenience fallback (`CLAUDE.md` explicit).
- The delivery-run inactivity watchdog and interruption settlement are
  separate packets.

## Approach

1. Reproduce first: a fixture product whose recipe preparation script does
   `mktemp -d` + build + `rm -rf` of its own dir, and a second run whose
   script must delete a `.demo` bundle left by a first run. Drive it through
   the real `MacOSDemoLauncher` against the real Codex app server (this is a
   sandbox-behavior bug; a fake transport cannot prove it — see the pilot or a
   gated integration test).
2. Fix the profile/runtime so both reproduce cases pass; if the profile is
   Codex-side, configure or replace it app-side so Spedito controls the
   writable scope explicitly.
3. Fix the readiness-port injection mismatch with a deterministic test
   (launcher test asserting probe port == injected port).
4. Route the failure through the failure contract (owner-facing summary via
   `ownerFacingLogSummary` is already in the launcher — verify it is actually
   applied on this path and that work-log persistence uses it).
5. Prevention:
   - Deterministic launcher tests for the create/delete round-trip contract at
     whatever seam survives without the real sandbox, plus one gated
     real-sandbox test alongside the pilot (`SPEDITO_PILOT=1` family), so CI
     or a pilot run exercises true parity.
   - Pilot invariant: a candidate that reached `ready_for_demo` and then
     fails demo preparation for an environment reason (denial text, port
     mismatch) files a distinct finding category so bundles surface this
     class explicitly (`Tests/SpeditoAppTests/Pilot/PilotInvariants.swift`,
     `demoContract` is the anchor).
   - Eval angle (optional, owner to confirm): the delivery-cell evals could
     assert generated preparation scripts avoid patterns the runtime cannot
     honour — but prefer fixing the runtime so ordinary script patterns
     (mktemp/rm, rebuild-into-.demo) simply work; do not teach agents to
     tiptoe around a broken sandbox.

## Verification

- [ ] Both reproduce fixtures fail before the fix and pass after it.
- [ ] Readiness-port test, failure-text test (no raw tool output, no
      worktree path in owner-facing strings).
- [ ] Full default validation (`swift test` with warnings-as-errors,
      `git diff --check`, ratchets). Use `--scratch-path` if another session
      may hold the repo `.build`.
- [ ] Relaunch, then a real re-run: open the Demo on Native Weather App
      workspace `ED871CF3-…` T1 (its candidate is still `ready_for_demo`) and
      confirm it launches; that exact failing state is preserved on this Mac.
- [ ] Pilot `native-weather` run reaches a launched `mac_application` demo
      without an environment-parity failure.

## Completion evidence

Record: the identified sandbox rule and what changed, the two reproduce
fixtures, before/after demo session rows for workspace `ED871CF3-…`, and the
owner-facing failure text now produced by a forced preparation failure.

## Findings (2026-09-01 investigation)

Answers to the open questions, from direct observation:

- **The denial rule.** The unified log records kernel Seatbelt denials at
  10:24:29.399: `Sandbox: rm(68981) deny(1) file-write-unlink` on exactly the
  four directories (`.demo`, `.demo/NativeWeatherApp.app`, `…/Contents`,
  `…/Contents/MacOS`). File unlinks inside the same tree succeeded — the
  stranded state on disk was empty directories only. The same morning,
  delivery runs in ticket worktrees were denied directory unlinks the same way
  (10:13:35 `…/.run/test-6sw_momp` with 330 duplicate reports, 10:14:05
  `dist`, 10:20–10:21 `.xcresult` staging directories and `Debug/.xctest`
  from xcodebuild/SWBBuildService). The class hits directories only and is not
  specific to the demo profile.
- **Root cause: a Codex sandbox regression, selected via Launch Services.**
  The running app's app-server is `/Applications/ChatGPT.app/Contents/Resources/codex`
  (`codex-cli 0.149.0-alpha.4.1`), because both ChatGPT.app and Codex.app
  register the bundle identifier `com.openai.codex` and
  `NSWorkspace.urlForApplication` resolves it to ChatGPT.app. Since
  openai/codex PR #39623 ("Prevent protected-path rename bypasses in macOS
  Seatbelt", in 0.145+), every deny glob in a profile also emits
  `(deny file-write-unlink (require-all (vnode-type DIRECTORY) (regex …)))`
  for each ancestor of the glob pattern. For the workspace-relative globs
  Spedito sends (`"**/.env"="deny"`, `"**/.env.*"="deny"`), the ancestor `**`
  compiles to a match-everything regex, so **every directory becomes
  undeletable** inside both the demo and the delivery sandboxes, while files
  still unlink — exactly the observed failure shape, including the delivery
  denials (`.xcresult` staging, `dist`, mktemp build directories) the same
  morning. Both live occurrences reproduce byte-for-byte against the
  ChatGPT.app binary and pass against Codex.app `0.144.0-alpha.4` and
  Homebrew `0.144.1`, whose generators predate the ancestor rule
  (source-verified at the matching tags; the bug is still present on codex
  main). The earlier "works when replayed" behavior was binary selection, not
  time. A restrictive outer sandbox was separately ruled out: nested
  `sandbox_apply` fails loudly under any restrictive outer profile
  (verified), while the failing run's commands executed normally.
- **The `.demo` contents.** Preparation legitimately runs twice per flow
  (candidate smoke verification, then the owner's launch), so the second run
  always deletes a `.demo` created by a different sandbox instance. Worktree
  reuse compounds it: `preparePreviewWorkspace` returned a same-SHA checkout
  as-is, keeping anything a previous failed preparation stranded.
- **The readiness port.** The launcher injects and probes the same allocated
  port (`{{PORT}}`, the port environment variable, and the probe URL all use
  one value); this is now pinned by a deterministic test. The 4174 mismatch in
  occurrence 2 arose inside the recipe's own script chain.
- **CoreSimulator/XPC noise** is benign for macOS app builds; replays with the
  identical noise produced complete bundles.

What changed:

- `GitWorkspaceManager.preparePreviewWorkspace` resets a reused same-SHA
  preview checkout (`reset --hard` + `clean -ffdx`) unless the caller says a
  live demo may be serving from it; `AppModel.prepareLaunchPreview` skips the
  reset only for a stored session in `starting`/`ready`.
- `MacOSDemoLauncher.verifyManagedWorkspaceAccess` proves the full
  create-and-delete round trip inside the managed sandbox before preparation;
  denial fails fast as retryable `managedWorkspaceUnavailable`.
- Owner-facing preparation failure text rewrites workspace-absolute paths as
  workspace-relative paths (no worktree paths in alerts or work log entries).
- Deterministic tests: readiness probe port equals injected port; deletion
  denial fails before preparation with sanitized retryable text; failure text
  hides workspace paths; preview reuse resets stale artifacts.
- Real-sandbox parity tests run the cross-instance create/delete and mktemp
  round trips against the real codex app server in the real preview-worktree
  location: `realSandboxCreateDeleteParity` (ungated, pinned to the Codex.app
  binary as a profile-regression guard) and
  `selectedRuntimeCreateDeleteParity` (`SPEDITO_PILOT=1`, resolves the binary
  the way the app does through Launch Services — red today against
  ChatGPT.app 0.149 until the upstream regression is fixed or the owner pins
  an installation).
- Pilot invariant: environment-signature demo failures on a ready-for-demo
  candidate now file the distinct `environmentParity` finding category.

## Completion evidence (recorded)

- Reproduce fixtures. Against ChatGPT.app codex `0.149.0-alpha.4.1` with the
  production profile: command A creates `.demo/Fake.app/Contents/MacOS` plus
  files; command B `rm -rf .demo` fails with the exact live cascade
  (`rm: .demo/Fake.app/Contents/MacOS: Operation not permitted` … `rm:
  .demo: Operation not permitted`); a same-command
  `mktemp -d "$TMPDIR/build.XXXXXX"` + `rm -rf` fails identically. Both pass
  against Codex.app `0.144.0-alpha.4` and Homebrew `0.144.1`.
- Preflight behavior on the broken runtime
  (`SPEDITO_PILOT=1 swift test --filter selectedRuntimeCreateDeleteParity`):
  fails in 0.17 s with
  `managedWorkspaceUnavailable("rm: .spedito-demo-runtime/access-check/nested:
  Operation not permitted …")` — before any recipe command, workspace paths
  rewritten as relative, disposition `retryPreparation`.
- Demo session row for workspace `ED871CF3-…` candidate `73118E62-…` before
  the fix: `failed` at 2026-09-01 10:24:29 with raw xcodebuild noise plus the
  four absolute-path `rm` denials in `error_message`. The re-run after
  relaunch is pending the owner decision below (with ChatGPT.app still
  selected, the demo now fails fast with the clean retryable message; with
  Codex.app pinned it launches).
- Default validation: full suite green via
  `swift test --scratch-path .build-demo-parity -Xswiftc -warnings-as-errors`,
  `git diff --check` clean, ratchets match all 6 baselines. Launched-process
  suite not run: no application-shell wiring changed (launcher internals,
  Core Git manager, one AppModel call-site parameter; no view or
  accessibility changes).

## Owner decision needed

The `**/.env` deny globs are the trigger, and no glob reformulation avoids
the upstream ancestor rule (any wildcard component blankets the directories
at that depth). Removing them would restore demos today but weakens the
sandbox, which contributor rules forbid as a convenience fallback. Options:

1. **Recommended:** pin the Codex installation to
   `/Applications/Codex.app` (add it as a custom installation in settings;
   the "official" entry now silently resolves to ChatGPT.app because both
   register `com.openai.codex`), and report the regression upstream: for a
   deny glob `**/.env`, `build_seatbelt_unreadable_glob_policy` in
   `codex-rs/sandboxing/src/seatbelt.rs` emits a
   `(deny file-write-unlink … (regex "^.*$"))` ancestor rule; ancestors at or
   after the first glob component should be skipped. Until then Spedito fails
   demo preparation fast with a clean retryable message.
2. Drop or narrow the glob denies in the demo/delivery profiles (owner-level
   sandbox-scope decision; not taken here).

## Superseded: pinning is not a remedy (2026-09-01, later)

Option 1 above is withdrawn. `/Applications/Codex.app` is now `0.152.0` and
carries the same ancestor rule, so pinning only moves the failure. Every
installed runtime on this Mac is affected: ChatGPT.app `0.149.0-alpha.4.1`,
Codex.app `0.152.0`, Homebrew `0.152.0`. The ungated
`realSandboxCreateDeleteParity` guard is red as a result, which is the first
time the default suite has been able to see this class.

Measured directly against Codex `0.152.0` by driving `command/exec` on a real
app-server with the shipped profiles, varying only the `:workspace_roots`
deny entries, and deleting directories at depths 1–4:

| `:workspace_roots` denies | depth 1 | depth 2 | depth 3 | depth 4 |
| --- | --- | --- | --- | --- |
| `"**/.env"`, `"**/.env.*"` (shipped) | denied | denied | denied | denied |
| none | ok | ok | ok | ok |
| `".env"` (literal) | ok | ok | ok | ok |
| `"*/.env"` | denied | ok | ok | ok |

Two consequences the earlier findings did not state:

- **Delivery is broken the same way, not just demos.** The same
  `workspaceRootEntries` constant is spliced into `spedito-delivery`, and the
  probe confirms directory unlink is denied at every depth under that profile
  too. An agent in a ticket worktree cannot remove a build directory, a
  `mktemp -d`, an `.xcresult`, or any directory a checkout or clean would
  remove. That, not the demo step alone, is why every ticket fails.
- **The wildcard's position selects the blast radius.** `**/.env` blankets
  every depth; `*/.env` blankets only depth 1. A literal deny blankets
  nothing. Any deny pattern containing a wildcard is unsafe, but the shallower
  ones are unsafe *invisibly* — see the probe-shape gap below.

The live process confirms the shipped configuration reaches the runtime: the
running app (`Spedito` pid 40749) spawned
`/Applications/Codex.app/Contents/Resources/codex` with
`":workspace_roots"={"."="write","**/.env"="deny","**/.env.*"="deny"}` in both
`spedito-delivery` and `spedito-demo`. The globs have been in the profiles
since `df39952` (2026-07-25); they were inert until Codex 0.145 added the
ancestor rule.

Remaining options, both owner-level:

1. Replace the glob denies with literal `.env` / `.env.*` denies at the
   workspace root, accepting that nested `.env` files below the root lose
   their deny. Narrowest change that restores delivery and demos. Note both
   profiles are already network-constrained (`spedito-delivery` has
   `network.enabled=false`; `spedito-demo` allows loopback only), which bounds
   what a reachable `.env` could be used for.
2. Drop the workspace `.env` denies entirely and rely on the network
   constraint plus `:minimal`/`:root` read scope.

Doing nothing blocks all delivery, so "wait for upstream" is not available.

## How this stayed green (2026-09-01)

The verification system cannot currently observe this class. Five distinct
gaps, each independently sufficient:

1. **CI never runs the sandbox guard.** `realSandboxCreateDeleteParity`
   early-`return`s — and so passes — when
   `/Applications/Codex.app/Contents/Resources/codex` is absent. No step in
   `.github/workflows/ci.yml` installs Codex, so on `macos-26` runners the
   only ungated sandbox test is a guaranteed no-op. Every green CI run has
   been silent about the sandbox, not affirmative.
2. **The test that checks the right binary is opt-in.**
   `selectedRuntimeCreateDeleteParity` resolves the runtime the way the app
   does (Launch Services on `com.openai.codex`), but is gated behind
   `SPEDITO_PILOT=1`, which the documented default validation in `CLAUDE.md`
   does not set.
3. **The ungated guard pins a binary the app need not use.** It hardcodes
   Codex.app while the app resolves through Launch Services, which can return
   ChatGPT.app. The guard was green against Codex.app 0.144 for weeks while
   the app ran ChatGPT.app 0.149. It went red now only because Codex.app was
   upgraded — coincidence, not coverage.
4. **Every other launcher test stubs the executor.**
   `DemoCommandExecutorStub` returns success with no sandbox, so the
   deterministic launcher tests prove control flow and can never prove
   permission behavior.
5. **Evals do not execute anything under a permission profile.** They score
   planning and plan-text quality through Codex planning turns
   (`EvalEpicPlanChecks`). No delivery or demo command runs. "Evals covering
   the same products" cannot cover this class by construction.

A sixth gap is in the shape of the probe itself, and it is the one most likely
to recur: `verifyManagedWorkspaceAccess` and the parity fixture only delete
directories at depth ≥ 2 (`.spedito-demo-runtime/access-check/nested`). The
`*/.env` row above passes a depth-2-only probe and fails a depth-1 delete. A
guard that samples one depth reports "the sandbox is fine" for any denial
whose radius it does not happen to touch.

## Resolution (2026-09-01)

**The deny paths no longer contain a directory wildcard.**
`CodexPermissionProfiles.workspaceDenyPaths` is now `[".env", ".env.*"]`. A
wildcard in the final *filename* component produces no wildcard ancestor and
is safe — measured, not assumed: `.env.*` allows directory deletion at every
depth while still blocking `.env.local`. Root-level protection is therefore
unchanged; what is lost is depth, since a `.env` nested below the workspace
root is no longer denied. Both profiles are already network-constrained, which
bounds the consequence. Restoring depth without a wildcard would mean
enumerating discovered `.env` files as literal paths at profile-construction
time; that is available as a follow-up and was not taken here.

The TOML and JSON renderings of the profile now derive from that one array, so
the launch-time and thread-time profiles cannot drift apart. That duplication
was the same hazard class as the glob itself.

**The guard can no longer skip-pass.** `CodexSandboxRuntimeLocator` resolves
the runtime the application resolves (Launch Services, then
`SPEDITO_CODEX_PATH`, then the usual CLI paths) and **throws** when it finds
none, so an uncovered run reports as a failure rather than as evidence. CI now
installs Codex and sets `SPEDITO_CODEX_PATH`. The `SPEDITO_PILOT`-gated twin
and the hardcoded-binary variant are gone; one test covers what both intended.

**The contract asserts both halves.**
`CodexSandboxProfileContractTests` runs against the real runtime, for
`spedito-delivery` and `spedito-demo`, and requires that ordinary filesystem
work succeeds (directory deletion at depths 1–4, a `mktemp -d` round trip)
**and** that `.env` and `.env.local` stay unreadable. Holding both means a
future breakage of the first cannot be resolved by dropping the denies,
because that fails the second. A static companion test rejects any deny path
with a wildcard in a directory component, and holds even where no runtime is
available.

Negative control, run deliberately: restoring `**/.env` turns the contract red
with 10 issues across both profiles, each naming the depth that failed and
pointing at `workspaceDenyPaths`. The guard is proven to catch the defect it
exists for, rather than merely passing today.

`CLAUDE.md` now carries the rule and the reporting obligation: name the binary
and version exercised, or say plainly that none was.

Still open, and worth doing separately:

- Have the app record the resolved codex path and version alongside each agent
  run, so a runtime change is attributable after the fact.
- Consider enumerating nested `.env` files as literal denies to restore depth
  coverage.
