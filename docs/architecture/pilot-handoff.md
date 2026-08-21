# Pilot loop handoff

- **Date:** 21 August 2026
- **Branch:** `pilot` (24 commits ahead of `main`, tree clean)
- **Harness:** `Tests/SpeditoAppTests/Pilot/`, runner `scripts/pilot.sh`
- **Design rationale:** `docs/architecture/pilot.md`

Read `docs/architecture/pilot.md` first for why this layer exists. This document
covers only what a continuing agent needs to pick the loop up.

## Where the loop is

Eleven live runs. The last four are the only ones whose observations can be
trusted; everything before run 8 was reported by a harness watching an
application it had already closed.

**Run 9 (`static-converter`) completed a ticket end to end and filed no
findings**: plan, sprint, delivery, tech lead review, demo, acceptance,
released, with the dependant ticket starting as soon as its prerequisite
released. That remains the only complete journey.

**Runs 10, 11 and 12 (`native-notes`) all failed to reach a demo.** Between them
they produced every fix listed below. Run 12 came closest: two reviewed
candidates, no requeue loop, correct prerequisite handling, and then both runs
hung with completed turns Spedito never processed. That hang is fixed but
unconfirmed on a live run.

Still unexercised: retrospectives, app versions, and the `script-log-summary`,
`library-csv`, `web-reading-list`, `vague-dashboard`, `static-weather` and
`import-repository` briefs.

## What to do first

1. **Run `native-notes` again.** Three fixes landed after run 12 and none has
   been seen working live: the turn-wait hang, the coherent-capability guidance,
   and the pilot's retry behaviour. The specific thing to watch for is whether
   the agent now makes **one batched permission request instead of five**.
2. **Then run the briefs nobody has run.** `script-log-summary`, `library-csv`,
   `web-reading-list`, `vague-dashboard`. Each exercises a
   `DemoPresentationKind` that has never been reached, and the product owner has
   asked for breadth.
3. **Make the relaunch a genuinely cold start.** `simulateRelaunch` reuses the
   `ProductStoreRegistry`, so the same SQLite connections survive a quit that
   should have closed them. This is now the least faithful part of the harness
   and the most likely source of the next wrong conclusion.

## Fixed this session

Every fix below has a regression test that was verified to fail without it.

### In Spedito

**Delivery recovery looped, twice.** `recoverDelivery` adopts runs the database
still calls running, on the assumption a process stopped and orphaned them. It
is invoked from `prepareScheduler`, which runs every time a scheduler is
created, and schedulers are created and retired constantly during a sprint.

The first fix (`de417d2`) skipped runs the runtime coordinator was executing.
That removed one path and was declared done a run too early: run 10 looped
between turns instead, when nothing owned the run and recovery was correct to
call it an orphan. Each pass also resumed both agent threads to look for a
missed result, at roughly 175,000 input tokens a time — about **fifteen million
tokens of the product owner's usage in eight minutes, for no delivered work**.

`8fd8784` fixed the cause: recovery runs once per product per process, which is
what "recovery after restart" always meant. Run 12 recorded **0 requeue events,
down from 64**.

**A completed turn could hang forever.** Two tickets in run 12 reported a
working agent for fifty minutes after their turns had finished. A turn's wait
suspends its inactivity timeout while the turn is awaiting an approval decision
— correct, since an owner may take minutes — but the flag saying so was cleared
only after the response was delivered successfully. One failed delivery left the
turn flagged as awaiting an answer it had already been given, removing the only
bound on the wait. `c04bdb5` defers the clear.

Deliberately **not** capped with an absolute timeout: a turn genuinely waiting
for the owner should wait indefinitely, and the board already says it needs
their input. A blanket cap would fail runs that are behaving correctly.

**Agents were never told how to scope a permission request.** Spedito's guidance
— treat a runtime and the files it predictably needs as one coherent capability,
diagnose the foreseeable boundary, make one batched request — shipped only from
`permissionRecoveryContext` when there was an interrupted decision to recover.
An ordinary turn got `"No interrupted permission request was recorded."` and
nothing about scope. Both agents in run 12 were told exactly that and nothing
else, which is why the owner saw five escalating requests in two minutes.
`9f67a88` puts the guidance in both branches.

**Owner-facing text.** An Epic has no title until the plan names it, so the
first alert a product owner ever receives was titled `" needs your input"`
(`369e58d`). The live permission prompt said "Network access" for a scoped
request while the saved grant said "Restricted network access" — the broader
wording where consent is given, the narrower one where it is merely recorded
(`f29f1f4`). Every demo kind may declare an HTTP readiness check, so a native
Mac app with a malformed readiness path was told about "browser paths"
(`2339a1e`).

### In the harness

**It was watching an application it had already closed.** `superviseDelivery`
bound `model` once before its loop; `simulateRelaunch` replaces it. From the
relaunch onwards the board snapshot, the invariants, and the completion check
all read the shut-down application, whose board froze with every run queued.
This produced the previous handoff's entire "delivery stall" blocker, which did
not exist. Fixed in `eb545f0` by `superviseTick`, which reads `model` every turn.

**Evidence capture dropped the write-ahead log** (`4aa3a98`). Run 9 — the first
run ever to reach a demo — left a 4KB evidence database with no schema in it.
Its data is unrecoverable.

**A hung run was invisible** (`c7fb203`). `stalledRuns` only looks at queued runs
and `deadEnds` skips any ticket offering an action, which a running run always
does because it offers **Stop**. `silentRuns` now reports a running run whose
last activity is older than the tolerance. It caught a real defect on its first
live run.

**The completion-handoff check could never fire** (`12827bd`). It asked whether
every run's `lastActivityText` was empty — a transient activity summary, never
empty on a finished run. It now reads the work log.

**Tickets waiting on prerequisites were reported as stalls** (`cf51ef3`). That is
the dispatcher working as designed, and the noise cost real triage time in runs
7 and 8. Board lines now say `waiting-on=T1+T2`.

**Leaked diagnostics were matched against a fixed marker list** (`2339a1e`), so
an owner-facing failure assembled from chained internal errors went unreported.
Now detected structurally.

**The pilot never clicked Retry** (`46eacdc`). Run 11 sat with a failed ticket
and "Retry work" on screen for its whole budget. It now retries as the ticket
sheet does, capped at two attempts per run.

## Open, and what is known about each

**Does the coherent-capability fix work?** Unconfirmed. The next `native-notes`
run answers it: one batched request instead of five.

**A second cause of the hang may exist.** The stuck-approval mechanism explains
T1 in run 12 cleanly — five approval round-trips, one denied mid-turn. **T2 had
no owner decision in its final turn and hung the same way.** Either it stuck
through a different path or there is a second cause. The transport error that
would have proved it was not recorded anywhere, which is its own small gap.

**Three permission-UX items the product owner has not objected to**, none done:

- coalesce requests of the same shape arriving in one turn into one decision;
- tell the owner when a request is the Nth for one ticket;
- make refusal end in a real choice — "I can't build a native Mac app without
  the developer tools on your Mac; allow that, or I can deliver this
  differently" — instead of a failed run and a chained internal error.

A fourth idea, standing consent scoped by *access shape* rather than path, was
**proposed and withdrawn**. It duplicated coverage that
`AgentPermissionGrantPolicy` already provides, and it either re-asks on every
sibling path or grants far too much. Do not resurrect it without reading
`docs/product-spec.md` around line 2090 first: the permission model is more
settled than it looks, and the escalation problem was an undelivered
instruction, not a missing mechanism.

**Agent work escapes into the owner's desktop session.** Run 12's `xcodebuild
test` invocations triggered a macOS *"wants permission to control your
computer"* prompt on the owner's Mac; an earlier session produced repeated
Google Chrome crash dialogs. Spedito's own instructions forbid the agent from
driving the desktop, and it was not trying to — the toolchain asks regardless.
This is a product question about mediating toolchain side effects, not a defect
with an obvious fix. **Report it; do not invent a policy.**

## Running it

```sh
./scripts/pilot.sh                      # static-converter, 1800s
./scripts/pilot.sh native-notes 2400    # a named brief and budget in seconds
```

Nine briefs, spanning every `DemoPresentationKind`. `import-repository` needs
`SPEDITO_PILOT_REPO` set to a repository the owner nominates; it has no default
on purpose.

Evidence lands in `.pilot-runs/<timestamp>-<brief>/`. **Read the bundle named by
`.pilot-runs/current-run`,** never "the newest directory": while a run rebuilds,
the previous run's bundle is still newest, and reading it produces a confident
report about the wrong run.

**Set `SPEDITO_PILOT_KEEP=1` for any run you expect to be interesting.** The
scratch root is deleted otherwise, and run 9 showed what that costs.

A run takes its budget in wall clock and can hold the machine while doing
nothing. Run 11 sat dead for 45 minutes. Stop a run that cannot progress rather
than waiting it out.

## Traps

**Do not read a live pilot database with external `sqlite3`.** The writer holds
the WAL, so external reads silently fall back to the checkpointed file and
under-report committed rows. Once a run has finished,
`.pilot-runs/<run>/evidence/*.sqlite` is safe, and `activity_events` is the
clearest record of what happened, in order.

**Check every finding against the run's own evidence before believing it.** Six
of the defects found so far were the harness's own, not Spedito's. The worst
cost a whole session and produced a confident handoff naming a blocker that did
not exist. The Codex rollouts in `evidence/codex-threads/` are the ground truth
for what the agent actually did: `task_complete` events, token counts, and the
exact instructions the agent received.

**Count the tokens when a finding mentions repeated turns.** A loop here spends
the product owner's money. Run 10 spent roughly fifteen million input tokens in
eight minutes before anyone noticed.

**A fix that removes a symptom is not a fix for its cause.** The recovery loop
was declared fixed after run 8 and recurred in run 10 through its other path.
Prefer the change that makes the failure impossible over the one that makes the
observation go away.

**Reason no further than the evidence.** Every wrong conclusion in this loop came
from one step past what was established. When stuck, make the harness report a
fact rather than theorising about it.

**The relaunch is not a cold start.** It builds a new `AppModel` but reuses the
`ProductStoreRegistry`. Rule this out before attributing any post-relaunch
finding to Spedito.

## Working with the product owner's tree

The tree is clean and every local change is committed, including work that had
been uncommitted for a long time (`775e4bb`). Do not assume it stays that way:
check `git status` on a path before staging it, and stage explicit paths rather
than `git add -A` unless the owner has asked otherwise.

Validation can run concurrently with a live pilot **only in a separate
worktree**. Building in the main tree while a run is in flight risks replacing
the test binary that run is executing. A detached worktree under the scratch
directory works well: patch it with `git diff`, build and test there, then
commit from the main tree.

## Scope of autonomous fixes

Agreed with the product owner:

- **Fix unattended:** reproducible functional defects, dead-end states, raw
  diagnostics reaching the owner, and product-language or convention violations
  — each with a regression test mined from the real failure.
- **Report only:** visual layout, information architecture, security posture,
  and anything needing taste. Surface with evidence and let the owner judge.
- **All work lands on the long-lived `pilot` branch.** Nothing merges to `main`
  without the owner.

The product owner's stated goal is that Spedito is robust for everyone across
all their use cases, and that nothing hardcodes rules or logic for specific
technologies. A fix that only works for Xcode, Homebrew, or npm is the wrong fix.

## Validation before any commit

```sh
env \
  SWIFT_MODULECACHE_PATH="$PWD/.build/module-cache" \
  CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache" \
  swift test -Xswiftc -warnings-as-errors
git diff --check
./scripts/check_architecture_ratchets.sh
```

Currently 618 tests pass, ratchets match all six baselines, diff is clean. The
pilot run itself is gated behind `SPEDITO_PILOT=1` and does not run in
`swift test`, but the harness's own deterministic tests do and must stay that
way: `PilotSupervisionTests` is the reason a relaunch defect cannot silently
return.

A regression test must be verified to **fail without its fix**. Disable the fix,
watch the test fail, restore it. A test written against an already-fixed
behaviour proves nothing. Make the test faithful to the real failure while you
are at it: one written this session passed against both the old and new code
until its fixture was corrected to carry activity text, which is what the live
run actually had.

## Cost and side effects

Each run consumes real Codex usage under the owner's own authentication, for up
to its budget in wall clock. A defect can spend far more than the budget
suggests: run 10 spent roughly fifteen million input tokens in eight minutes
through a loop that resumed agent threads.

Runs write only under a scratch root and never touch the owner's real products.
They do, however, execute real agent work on the owner's machine, and that work
has twice escaped into their desktop session: Chrome crash dialogs, and a macOS
Accessibility prompt from `xcodebuild test`. Watch for this and say so promptly.
