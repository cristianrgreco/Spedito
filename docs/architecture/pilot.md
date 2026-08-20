# Live owner pilot

- **Status:** foundation landed; catalog breadth and the engineer loop in progress
- **Runner:** `scripts/pilot.sh`
- **Code:** `Tests/SpeditoAppTests/Pilot/`
- **Journey inventory:** `docs/architecture/owner-journey-test-plan.md`

## Why this layer exists

Every Codex-touching test in the suite injects `ScriptedCodexTransport`. The
reply is a hand-written JSON string that is always well formed, always on the
happy path, and always instant. That proves Spedito's reaction to a perfect
agent, which is the reaction that rarely breaks.

The regressions a product owner actually hits live outside that space:

- real agent output that is slow, verbose, or malformed;
- permission requests arriving at unpredictable moments;
- real Git worktrees, real conflicts, real build output;
- demos that must genuinely serve or launch;
- twenty turns of compounding durable state.

The pilot is the layer that reaches them. It drives the real `AppModel` over a
scratch Application Support root with the production Codex transport, real Git,
and the real demo launcher, and plays the product owner through a whole journey.

This does not replace the deterministic layers. It feeds them: a finding here
should become a fast deterministic test carrying the *real* agent reply captured
from the run's Codex rollout.

## What it drives

The driver only calls commands a view could call and only reads state a view
could read. Anything it cannot do, the owner cannot do either.

```
create product -> ask for an outcome -> answer clarification rounds
  -> accept the suggested plan -> plan and start a sprint
  -> answer questions, decide permissions, open demos, accept work
  -> quit and reopen mid-delivery -> confirm nothing was lost
```

## Product catalog

Briefs are chosen to span every `DemoPresentationKind`, because demo preparation
and launch is where owner-visible delivery most often breaks.

| Brief | Demo kind | Exercises |
| --- | --- | --- |
| `static-weather` | `staticWeb` | scoped network permission, owner memory follow-up |
| `static-converter` | `staticWeb` | smallest end-to-end path, no build step |
| `web-reading-list` | `browser` | build step, mid-sprint scope change |
| `native-notes` | `macApplication` | native launch, app versions, persistence |
| `native-timer` | `macApplication` | native launch, notification behaviour |
| `script-log-summary` | `commandOutput` | non-visual delivery outcome |
| `library-csv` | `artifact` | review-only delivery, test evidence |
| `vague-dashboard` | `browser` | must ask a consequential product question |
| `import-repository` | `artifact` | repository import, knowledge analysis, delivery into existing history |

`import-repository` has no default repository: set `SPEDITO_PILOT_REPO` to one
you would genuinely import. Guessing a third-party repository would clone
something the product owner never chose.

## What counts as a finding

The harness cannot assert exact text, because a real agent words things
differently every run. It asserts the contracts this repository already states,
so a violation is a defect rather than a matter of taste:

- **Dead end** — a non-terminal ticket with no running agent and no available
  action. The owner has been stranded.
- **Convention** — owner-facing text breaking the stated product-language rules:
  sentence case labels, "and" rather than an ampersand, owner vocabulary.
- **Leaked diagnostic** — raw technical evidence reaching the owner instead of a
  typed, concise explanation.
- **Functional** — a broken durable contract: ready for demo that will not open,
  a completed ticket with no handoff, a ticket sequence with gaps, state lost
  across a relaunch.
- **Stalled** — nothing observable happened within the budget.

## Evidence bundle

Each run writes `.pilot-runs/<timestamp>-<brief>/`:

```
journal.jsonl              every owner command, observation, and finding
findings.md                the triage report
evidence/*.sqlite          the product database as the run left it
evidence/codex-threads/    the rollout for every thread the run touched
```

The journal is appended synchronously, so an interrupted or hung run still
leaves a readable trail.

## Deliberate deviations

The verification model requires asynchronous tests to observe explicit operation
events rather than sleeps. The pilot polls on a timer instead. This is
intentional and confined to this harness: it observes a real external agent
whose completion is not an event the app can publish, over minutes to hours.
Deterministic suites must keep using explicit events, and any test mined from a
pilot finding must be written that way.

The pilot reports rather than fails the build. A real agent occasionally
produces a legitimate outcome the harness did not anticipate, and a red build
would train the team to ignore it.

## Cost and safety

- Runs consume real Codex usage under the owner's own authentication. Budget is
  bounded per run by `SPEDITO_PILOT_BUDGET_SECONDS` (default 1800).
- All state is written under a scratch root, never the owner's real products.
- Repository briefs are read-only imports. Nothing is pushed.
