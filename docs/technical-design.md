# StoryPointless technical design

**Status:** Initial implementation baseline  
**Date:** 22 July 2026

## 1. First executable outcome

The first vertical slice is a native Apple Silicon macOS application that can
persist a local product, work items, workflow transitions, comments, agent
profiles, runs, decisions, knowledge proposals, and an audit timeline. It then
grows into the walking skeleton defined in the product specification:

1. start a pinned Codex App Server without exposing a terminal;
2. create a new local product repository;
3. execute two contracts in separate worktrees;
4. integrate exact candidate commits through a local merge queue;
5. run checks, review, and a local preview;
6. accept or reject with ticket feedback;
7. publish reviewed ticket documentation and knowledge; and
8. interrupt, reopen, reconcile, and resume work.

The first implementation proves the durable control plane before adding the
Codex process adapter. The board must project real state; it will not initially
simulate agents moving cards.

## 2. Technology baseline

- **Application UI:** SwiftUI, using AppKit only for macOS lifecycle, Keychain,
  process, file-panel, and preview integration that SwiftUI does not cover.
- **Language:** Swift 6 with strict concurrency.
- **Deployment target:** macOS 14+, Apple Silicon for private builds.
- **Application data:** system SQLite, with no database daemon or third-party
  dependency.
- **Generated source:** local Git repository and isolated worktrees; source and
  large artifacts never live in SQLite.
- **Agent engine:** an exact, StoryPointless-managed Codex runtime controlled
  over App Server JSONL/JSON-RPC through a versioned adapter.
- **Execution isolation:** Codex's native macOS sandbox first, behind an
  execution-backend protocol.
- **Testing:** Swift Testing for domain, migration, persistence, state-machine,
  scheduling, recovery, and adapter-contract tests.

The repository begins as a Swift package so the domain and engine can be built
and tested without generated project files. A signed Xcode application target
will wrap the same modules before distribution.

## 3. Module boundaries

### StoryPointlessCore

- Domain records and identifiers.
- Workflow transition policy.
- SQLite schema, migrations, repositories, and transactions.
- Scheduler and run leases.
- Project execution manifest and autonomy envelope.
- Git workspace and merge-queue interfaces.
- Codex and execution-backend interfaces.
- Conversation context boundaries and typed action-proposal validation.
- Evidence, decision, ticket-documentation, and knowledge promotion rules.

### StoryPointlessApp

- Product, board, team-activity, ticket, acceptance, knowledge, retrospective,
  and longitudinal report views.
- A page-owned action hierarchy, nested vertical-page/horizontal-board scrolling,
  compact aligned team selectors, explicit editing surfaces, and a bottom
  runtime status bar kept separate from agent-profile identity.
- Local notifications and permission presentation.
- Composition root for concrete persistence and execution components.

No UI type is allowed to become the authoritative workflow state machine.

## 4. Durable storage boundary

SQLite contains normalized current state and an append-only audit/activity log.
Initial tables cover:

- products;
- work items and immutable contract versions;
- Story/Task/Bug work-item classification, with a later optional epic foreign
  key whose aggregate state remains derived from child tickets;
- comments and activity events, including an optional structured Product Owner
  question with two to four answer options;
- agent profiles and runs;
- product-wide guidance and optional per-profile instruction overrides;
- built-in and custom persona identities, governed capability archetypes, and
  active/archive state;
- ticket-suggestion sessions, proposals, proposal dependencies, and accepted
  work-item dependency edges;
- sprints, sprint assignments, forecast slots, concurrency policy, internal
  safety limits, and frozen ticket snapshots;
- decision records and knowledge claims; and
- schema migrations.

Candidate execution results also retain a schema-versioned demo launch
specification. Durable demo-session rows record the candidate, state, preview
worktree, allocated loopback port, bounded captured output, and recoverable
failure explanation. The process object itself remains an in-memory operating
system resource and is never inferred to be alive merely because SQLite says it
was running.

Every consequential state transition and its audit event are written in one
transaction. Source, worktrees, previews, screenshots, build outputs, and large
logs are files referenced by stable paths and hashes. Secrets use Keychain or
the Codex credential store.

Ticket edits use optimistic version checks. Agent change proposals retain the
complete ticket snapshot and version supplied to their turn; applying a proposal
fails closed when either the saved ticket or the owner's in-memory draft has moved.
Codex turn waits are bounded and issue `turn/interrupt` on timeout so a missing
final notification cannot strand the owner-facing UI indefinitely.

Full event sourcing is deliberately avoided. Current relational state is
authoritative; events explain how it changed and support recovery and audit.

## 5. Execution identities

- An **agent profile** is a reusable Codex configuration.
- An **assignment** links a profile to a contract.
- A **run** is one bounded attempt with one Codex thread and, for code-changing
  work, one writable worktree.
- A **scheduler lease** prevents the same run from executing twice.

The built-in starter profiles are Business Analyst, UX Designer, Lead, and
Implementer. The Lead is the default reviewer for ordinary tickets. Frontend,
backend, security, and other specialist profiles are owner-added capabilities,
not required permanent roles. Implementation and review remain separate runs;
no profile can attest independently to work it produced. Sprint Planning assigns
the delivery member only; the scheduler creates the ordinary Lead review run
after integration, with specialist review added later by policy when warranted.

The PO starts a **sprint**, not a run. Starting the sprint freezes its approved
goal, contracts, assignments, and dependency-led execution plan, then authorizes the
scheduler to create and admit the necessary internal runs under system-managed
safety limits. The PO sees system forecasts and remaining shared usage rather
than entering token budgets. Individual-run controls are limited to intervention
actions such as pause, retry, cancel, or resume.

The durable execution state remains granular, but the active owner-facing board
projects queueing, implementation, integration, verification, review, and
post-approval finalization into four decision-oriented stages: **In Progress**,
**In Review**, **Ready for Demo**, and **Done**. Integration and Tech Lead review
share **In Review**, with the card and Work log stating which activity is current.

Thirty dependency-free tickets produce thirty admitted runs in the local MVP.
Account or machine back-pressure may delay the underlying turns, but there is no
owner-entered concurrency number and reusable profiles do not represent finite AI
headcount.

## 6. Repository and integration lifecycle

1. Record the current local-trunk commit when admitting a contract.
2. Create a private branch and worktree for the implementation run.
3. Produce a candidate commit after fast checks.
4. Replay candidates in dependency order into an ephemeral integration
   worktree based on the latest trunk.
5. Surface conflicts as explicit Integrator work; resolve only unambiguous overlap
   and pause material choices for the Product Owner.
6. Pin full checks, a separate Lead review run, documentation review, and
   preview to the exact integrated candidate; add a specialist reviewer when
   ticket policy requires one.
7. Advance trunk only after human acceptance of that exact commit.

The merge path is deterministic first and agentic only when necessary. Git attempts
the candidate merge before an agent is involved. A clean merge advances directly
to checks and Tech Lead review. A conflict creates an **Integrator** system run with
the base, both candidate diffs, affected ticket contracts, dependency context, and
test evidence. The Integrator may resolve mechanical conflicts but must return
semantic or product conflicts to the relevant implementation ticket or Product
Owner. It is not an independent product persona and it cannot approve its own
resolution. The Tech Lead reviews the final integrated candidate, not an isolated
branch. The board keeps this understandable as **In Review**, while the card and
Work log distinguish **Integrating changes**, **Resolving a conflict**, and
**Tech Lead reviewing**.

Git implementation is behind a protocol. The spike may use a known executable;
the distributed product must provide its own compatible Git implementation and
must not depend on Xcode Command Line Tools being installed.

### 6.1 Managed candidate demos

Every newly completed delivery includes a typed demo recipe. The supported
presentations are a loopback browser preview, a reviewed macOS application, a
workspace-relative artifact, or captured output from a bounded scenario. Recipes
contain executable and argument arrays, never shell command strings. Working
directories and artifacts resolve inside the reviewed checkout, browser URLs
contain only a path, and StoryPointless allocates and injects the loopback port.

After Tech Lead approval, StoryPointless creates or reuses a detached preview
worktree pinned to the current integrated SHA and smoke-tests the recipe without
opening its presentation. A candidate enters **Ready for Demo** only after that
test succeeds. The Product Owner's **Demo** action prepares the same exact
revision, starts or reuses the managed process, waits for typed readiness, and
opens the browser, app, artifact, or captured result.

If review succeeds but smoke preparation fails, the failed candidate retains its
integrated SHA and completed-review provenance. The ticket presents **Retry demo
preparation** without requiring a new owner comment. That action reruns only the
candidate-bound smoke preparation and, on success, advances the existing reviewed
candidate to **Ready for Demo**; it does not resume implementation or repeat review.
The acceptance Work log routes **Comment** through the existing read-only
ticket-conversation path, preferring the assigned Implementer, then the latest
participating team member, then the Tech Lead. The answer does not supersede the
candidate or resume delivery; **Request changes** remains the explicit revision-loop
action.

Demo commands use the pinned App Server's standalone `command/exec` API; the app
does not maintain a second `sandbox-exec` implementation. Each demo command gets
a candidate-scoped App Server connection whose dynamically materialized
permission profile names the exact preview root. Preview worktrees live under
the app's cache directory, separate from the denied StoryPointless control plane
and ticket worktrees. The profile grants broad read access for normal macOS,
Homebrew, compiler, SDK, and runtime dependencies without enumerating binaries
or configuration files, while only the current candidate is writable and
credentials and `.env` files remain denied. Demo networking is enabled only for
`localhost` and `127.0.0.1`.

Bounded commands disconnect their candidate-scoped App Server after capturing
the result. Long-running commands retain that connection and use its process
identifier while streaming output. Recipes must remain in the foreground;
detached or daemonized services are invalid because they cannot provide reliable ownership.
**Stop demo**, feedback, approval, product switching, shutdown, and App Server
disconnection terminate the managed command session. Feedback and approval
additionally remove the preview worktree. On restart, a previously active durable
session is marked stopped rather than being mistaken for a live process. Browser
tabs and shared document-viewer windows are not force-closed because they may
belong to the Product Owner rather than the demo session.

## 7. Codex adapter boundary

The current adapter pins Codex `0.144.0-alpha.4`, resolves only explicit bundled
or debug-fixture candidates, performs the required `initialize` / `initialized`
handshake over JSONL stdio, opts into the pinned experimental protocol fields
used by permission profiles, and fails closed on mismatched versions and
unsupported server-initiated requests. Read-only, schema-constrained threads
power backlog suggestions, refinement, and planning conversations. Delivery and
independent Tech Lead review use `approvalPolicy: on-request`.

Delivery selects the named `storypointless-delivery` profile: Codex's minimal
platform/runtime reads, one writable ticket worktree, exact database and
credential exclusions, and no network. The profile deliberately does not deny
the ticket worktree's StoryPointless ancestor: the pinned macOS runtime denies
metadata traversal at that ancestor before a more specific runtime workspace
root can take effect. Other products, sibling ticket worktrees, and the control
plane instead remain inaccessible because delivery has no broad host read
grant. Homebrew, compiler, SDK, local service, and other system capabilities
outside the minimal runtime are requested through App Server approvals for the
current turn. Delivery instructions prohibit copying or staging the workspace
under `/tmp` or another root as a permission workaround. Each delivery thread
overrides that named profile with read-only access to the exact active product's
central `.git` directory. The assigned worktree remains read/write, but Git
metadata is not writable. The StoryPointless-owned App Server process supplies
`GIT_OPTIONAL_LOCKS=0`, `GIT_CONFIG_GLOBAL=/dev/null`, and `GIT_PAGER=cat`, so
read-only status, diff, history, and conflict inspection is noninteractive and
does not attempt optional index refreshes. Agents may inspect Git but cannot
stage, commit, create or change branches, integrate, or promote; the host-side
Git workspace manager owns those mutations and validates candidate ancestry.
Git's object store is product-wide, so this explicitly chooses the product as
the read boundary while retaining ticket-scoped writes and denying every other
product.
When the App Server sends `item/commandExecution/requestApproval`,
`item/fileChange/requestApproval`, or `item/permissions/requestApproval`, the
adapter preserves the bidirectional JSON-RPC request instead of rejecting it.
Application coordination maps its thread and turn to the durable AgentRun,
projects **Needs your input**, and stores the exact scope, rationale, signature,
and decision. **Allow once** accepts only the exact command or file change, or
grants the requested capability for the current turn. For command and permission
requests, **Always allow for this product** stores a durable product-scoped grant.
Its normalized signature retains the exact command and requested capabilities
but excludes the ticket worktree path only after confirming the requested
working directory is within that run's assigned workspace, so the same
capability can follow future ticket workspaces for that product. It does not become a binary-only or
connection-wide App Server rule. Matching future requests are answered with a
turn-scoped approval and recorded in the receiving ticket's Work log. The owner
can inspect and revoke active grants in Product settings. File-change approvals
cannot be persisted. **Deny** declines without cancelling the turn so the agent
can adapt. The turn timeout does not advance while a supported permission
request is outstanding. StoryPointless may also transparently reapply an
identical recorded decision within the same durable AgentRun. If the app
restarts, a pending connection-scoped request becomes interrupted and the
resumed run can request it again; saved product grants remain durable.

The same adapter owns buffered and streaming `command/exec`, output deltas, and
termination for candidate demos. The durable run stores the thread identifier
and workspace path so an owner answer or review finding can resume the same
implementation context. It also reads `model/list`; the UI uses each returned
model's advertised effort options instead of maintaining a speculative catalog.
Authentication UI and usage telemetry remain subsequent adapter work.

The adapter owns:

- pinned runtime version and generated protocol schema;
- initialization and capability negotiation;
- ChatGPT and API-key authentication presentation;
- thread creation, resumption, steering, and interruption;
- approvals, questions, tool/file changes, diffs, and typed artifacts;
- token/context, compaction, and account-rate-limit telemetry; and
- termination and recovery normalization.

Permission profiles are a beta App Server surface in the pinned runtime.
StoryPointless therefore supplies its definitions as process-local config
overrides, enables the matching experimental capability explicitly, and covers
the exact pinned schema with adapter and local runtime contract tests. It never
falls back to full access or the retired custom Seatbelt allow-list.

Unknown protocol versions fail closed. Runtime updates use contract tests,
atomic activation, and rollback to the previous known-good version.

## 8. Recovery model

Durable writes occur before a UI projection announces a state. On launch the
application reconciles scheduler leases, child processes, Codex threads,
worktrees, candidate commits, and preview processes. A normal quit requests a
structured checkpoint, interrupts after a bounded grace period, and preserves
the run as paused. Crash recovery creates a system note from durable events and
filesystem state when no agent-authored checkpoint exists.

Review recovery is revision-bound. A Tech Lead turn interrupted by shutdown,
including one paused at a scoped permission request, retains its review run,
non-ephemeral Conversation, integration path, and integrated SHA. On restart
StoryPointless verifies or reconstructs the detached checkout at that exact SHA,
recovers a valid completed structured result when one exists, or starts a
continuation turn in the same Conversation. An expired live approval request is
reissued only if the continuing agent still needs it; saved matching run or
product grants apply normally. A missing Conversation starts a replacement
review against the same SHA. Only a missing, mutated, or unverifiable integrated
revision returns the candidate to integration and full review, with an explicit
Work log explanation. A candidate already in **Ready for Demo** keeps its
reviewed revision; only its owned demo process is stopped and restarted.

Owner-facing clarification records are durable independently of their Codex
thread. When a persisted read-only thread is no longer available, the adapter
creates a replacement and rebuilds its context from the saved conversation
before replaying the pending owner response.

## 9. Knowledge model

Every accepted ticket produces a reviewed knowledge change set:

- delivery note;
- repository documentation changes;
- decision records with alternatives and tradeoffs;
- proposed or updated knowledge claims;
- invalidated claims; and
- exact ticket, contract, commit, review, and evidence provenance.

Run traces, ticket history, and curated product knowledge remain separate.
Only reviewed knowledge is injected into future context packs or presented as
current truth. Basic “why/how” queries are part of the first vertical slice and
must return citations or an explicit unknown.

## 10. Near-term implementation sequence

1. **Complete:** core domain model, workflow state machine, SQLite schema, and
   persistence.
2. **Complete:** separate backlog/refinement and simplified sprint-board shells,
   guided ticket-by-ticket planning, readiness validation, frozen authorization,
   and idempotent internal run creation.
3. **Partial:** exact Codex runtime discovery, JSONL transport, initialization
   handshake, structured read-only and workspace-write turns, bounded waits,
   interruption, and truthful connection state are complete; authentication UX
   and usage telemetry remain.
4. **Partial:** a durable, deduplicated **Autosuggest Tickets** session now
   uses one BA thread to present a single analysis progress card followed by up
   to 24 rationale-backed proposals classified as Story, Task, or Bug. Suggested
   owner roles may repeat. A vertically staggered, dashed dependency outline is
   now projected as compact purple rows inside the ranked backlog, and cyclic
   graphs are rejected. Connected paths support group review, references to active
   backlog tickets become real cross-batch edges, and failed proposal sessions can
   be retried or dismissed. Accept/reject is durable and only acceptance creates
   scope. Ticket editing, custom fields,
   dependency-safe ranking, next-sprint drag/drop, and durable ticket comments are
   complete. Ticket chat replies and reviewable action proposals use optimistic
   base versions and stale-proposal protection. Product/sprint conversations,
   profile DMs, context packs, batch review, and independently scheduled
   conversation threads remain.
5. Lightweight epic records and collapsible backlog grouping, without placing
   epics on the execution board or requiring them for small products.
6. **Partial:** the durable scheduler admits all dependency-free implementation
   runs in parallel, routes concurrent Codex notifications by thread and turn,
   records attributed Work log updates, pauses for owner input, resumes the same
   Codex thread, persists paused questions as structured comment data, presents
   their choices natively in the Work log, and chronologically interleaves
   permission requests, run context, candidate revisions, knowledge proposals,
   follow-up recommendations, and demo submissions with comments and audit
   events. It performs independent read-only Tech Lead review, returns findings
   to the original implementer, and supports owner demo feedback and approval.
   Restart recovery requeues interrupted implementation and integration, while
   interrupted Tech Lead review continues in the same Conversation against its
   verified exact integrated SHA and recovers a completed structured result
   before starting another turn.
7. **Partial:** product repository bootstrap, ticket-named private branches and
   worktrees, versioned candidate commit ranges, detached integration worktrees,
   a rank-ordered serial candidate queue, internal Integrator conflict runs,
   exact-SHA Tech Lead review, and Product Owner promotion to `trunk` are
   implemented. Durable multi-process merge-queue leases remain.
8. Pinned checks, reviewer checkout, loopback preview, release finalization, and
   an agent-authored quit checkpoint. Normal termination already interrupts all
   active turns, persists their state, and preserves their workspaces.
9. **Partial:** ticket delivery notes are verified during Tech Lead review;
   agents can propose complete canonical-page creations or updates; and the
   reviewed proposals are published automatically and committed on the integrated
   revision. A runtime feature flag restores per-proposal Product Owner approval
   for testing stricter governance. Material unstated owner choices still pause
   execution rather than entering a proposal. Decision capture and richer sourced
   knowledge-change diffs remain.
10. **Partial:** durable agent observations, reviewable agent and Product Owner
   retrospective proposals, Ways of working promotion, and backlog-ticket
   creation with automatic refinement entry are implemented. Structured sprint
   evidence snapshots, retrospective experiments, and normalized before/after
   reporting remain; the existing UI shell must continue to render unavailable
   metrics honestly until these events exist.
11. Quit checkpoint, stale-lease reconciliation, and resume.

Signing, notarization, managed tool downloads, Docker Sandboxes, cloud release,
and production operations follow only after this slice is reliable.
