# StoryPointless technical design

- **Status:** Architecture baseline for the early implementation
- **Date:** 1 August 2026

This document describes the architecture and the invariants the implementation
must preserve. It is not a release-support statement. The
[README](../README.md) records what is available in the current early preview,
and the [product specification](product-spec.md) records intended behaviour.

## 1. Executable outcome

The implemented vertical slice is a native Apple Silicon macOS application that can
persist a local product, work items, workflow transitions, comments, agent
profiles, runs, decisions, knowledge proposals, and an audit timeline. It then
grows into the walking skeleton defined in the product specification:

1. discover and start a compatible installed Codex App Server without exposing
   a terminal;
2. create a new local product repository;
3. execute two contracts in separate worktrees;
4. integrate exact candidate commits through a local merge queue;
5. run checks, review, and a local preview;
6. accept or reject with ticket feedback;
7. publish reviewed ticket documentation and knowledge; and
8. interrupt, reopen, reconcile, and resume work.

The board projects durable state and supported Codex events; it does not
simulate agents moving cards or treat agent-authored narration as authority.

## 2. Technology baseline

- **Application UI:** SwiftUI, using AppKit only for macOS lifecycle, Keychain,
  process, file-panel, and preview integration that SwiftUI does not cover.
- **Language:** Swift 6 with strict concurrency.
- **Deployment target:** macOS 14+, Apple Silicon for early builds.
- **Application data:** one system SQLite database per product, with no database
  daemon or third-party dependency.
- **Generated source:** local Git repository and isolated worktrees; source and
  large artifacts never live in SQLite.
- **Agent engine:** the official installed Codex app by default, or an
  owner-selected custom Codex installation, controlled over App Server
  JSONL/JSON-RPC through a capability-checked adapter.
- **Execution isolation:** Codex's native macOS sandbox first, behind an
  execution-backend protocol.
- **Testing:** Swift Testing for domain, schema/import, persistence, state-machine,
  scheduling, recovery, and adapter-contract tests.

The repository is a Swift package so the domain and engine can be built and
tested without generated project files. `scripts/build_app.sh` assembles those
modules into a conventional application bundle. Early bundles are ad-hoc signed;
Developer ID signing, notarization, and an update channel remain distribution
work.

## 3. Module boundaries

### StoryPointlessCore

- Domain records and identifiers.
- Workflow transition policy.
- Declarative SQLite schema, legacy importer, repositories, and transactions.
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

Each product owns one authoritative database at
`<product workspace>/.storypointless/product.sqlite`. SQLite contains normalized
current state and an append-only audit/activity log for that product. There is
no continuously maintained projection or second copy of product truth.
The product workspace's root `.gitignore` contains `/.storypointless/` before
the repository's first snapshot, so the live database and its WAL/shared-memory
files never become candidate or accepted Git content.
Initial tables cover:

- products with an indexed active/archive lifecycle state and a durable
  curated display-color token;
- work items and immutable contract versions;
- Story/Task/Bug work-item classification and an optional epic foreign key;
  Epic Created/Planned/In progress/Complete progress remains derived from
  non-archived child tickets, while persisted Open/Closed/Archived status
  records only owner lifecycle decisions and a durable display-color token
  visually connects an Epic to its tickets;
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
- immutable retrospective notes and action candidates from team runs, Product
  Owner action ideas that remain owner-deletable only while their sprint is
  active, one durable synthesis state per completed sprint, frozen
  synthesis-source links, consolidated final actions, and their many-to-many
  evidence links;
- decision records and knowledge claims; and
- product-level conversation threads and messages.

Fresh product databases are created directly from one declarative final schema
and carry one `PRAGMA user_version`; they do not replay the application's
development migration history. At the distribution cutover, a one-time,
restart-safe importer snapshots the former shared schema-53 database, isolates
each product through its foreign-key relationships, copies common final-schema
columns into a staged product database, verifies foreign keys and product
identity, and then moves it atomically into place. A completion marker prevents
repeat work while the former shared database remains intact as a recovery
backup. Runtime persistence contains no `schema_migrations` table or historical
migration chain.

The application catalog is the set of valid product workspace identifiers and
their databases. Cross-product operations enumerate these stores; product
delivery reads and writes only the owning store. SQLite WAL snapshots allow the
UI and read-only agents to inspect current state safely while it changes.

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
Codex turn waits use a 60-second inactivity window and issue `turn/interrupt`
when it expires so a silent turn cannot strand the owner-facing UI indefinitely.
Each matching notification for the exact thread and turn restarts the window;
time spent waiting on a supported approval does not consume it.

Full event sourcing is deliberately avoided. Current relational state is
authoritative; events explain how it changed and support recovery and audit.

Product archival is a reversible status transition, not a cascading delete.
The application suspends the selected product's scheduler and live demo
processes before recording the transition, active product queries exclude the
archived row, and all product-owned records and filesystem workspaces remain
intact. Restoration returns the same product identifier to active selection so
its durable execution state can recover through the normal scheduler path.

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
against the immutable ticket candidate before integration, with specialist review
added later by policy when warranted.

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
4. Run independent Lead reviews in parallel against detached workspaces pinned
   to the immutable candidate commits.
5. Replay approved candidates in dependency order into an ephemeral integration
   worktree based on the latest trunk.
6. Surface conflicts as explicit Integrator work; resolve only unambiguous overlap
   and pause material choices for the Product Owner.
7. Preserve the candidate review after a clean merge. If conflict resolution
   changes the merge result, pin a focused Lead re-review to that exact integrated
   revision.
8. Pin the preview to the integrated candidate and advance trunk only after
   human acceptance of that exact commit.

The merge path is deterministic first and agentic only when necessary. Git attempts
to merge a reviewed candidate without involving an agent. A clean merge advances
directly to demo preparation. A conflict creates an **Integrator** system run with
the reported unmerged paths, ticket context, and preserved conflicted worktree. The
Integrator inspects only the affected files and nearby context, edits the unambiguous
overlap, and returns without running a second review or test pass. StoryPointless
performs mechanical Git validation and owns the merge commit. The Integrator must
return semantic or product conflicts to the relevant implementation ticket or
Product Owner. It is not an independent product persona and it cannot approve its
own resolution. The Tech Lead reviews the immutable ticket candidate before it joins
this serial path, then reviews the final integrated candidate only when conflict
resolution changed it. The board keeps this understandable as **In Review**, while
the card and Work log distinguish **Tech Lead reviewing**, **Queued to integrate**,
**Integrating changes**, and **Resolving a conflict**.

The Tech Lead may return a candidate only for a concrete material defect that
justifies the full implementation, integration, and review loop. Cosmetic diff
hygiene and optional style-only checks are non-blocking unless they cause a
behavioural, rendering, validity, required-gate, reviewability, or security
failure. Re-review applies the same threshold to previous feedback, so an
earlier blocker label does not perpetuate a non-material cycle. The fifth review
return to **In Progress** preserves the workspace and findings but pauses automatic
revision until the Product Owner provides direction.

Git implementation is behind a protocol. The current workspace manager invokes
the host's `/usr/bin/git`, so an early build may depend on an installed Apple
developer toolchain. A later self-contained distribution must provide or embed a
compatible Git implementation and must not trigger an unexpected Command Line
Tools installation during the Product Owner workflow.

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

Ready for Demo is not part of the serialized integration lane. Multiple independently
reviewed candidates may therefore be prepared for Product Owner evaluation. Promotion
still requires the approved revision to contain current accepted trunk. When another
approval advances trunk, StoryPointless stops and removes any now-stale preview,
returns its already reviewed candidate to the integration queue, and prepares a new
exact demo revision. A clean re-integration retains the immutable candidate review;
conflict resolution requires focused Tech Lead re-review.

When a post-conflict Tech Lead review or Product Owner demo requests another
implementation revision, the host adopts the exact reviewed integrated SHA into
the preserved ticket branch with an idempotent fast-forward before resuming the
Implementer. It validates a clean ticket worktree, the expected immutable candidate
HEAD, and candidate ancestry first. The candidate record remains immutable; only the
mutable implementation branch advances. The continuation identifies the old candidate
and adopted integrated SHA so the agent preserves accepted trunk behavior and conflict
resolution rather than rediscovering them. Any dirty or divergent state fails closed
instead of delegating Git repair to the agent.

If review succeeds but smoke preparation reports a candidate-controlled failure,
including an invalid recipe, failed or timed-out preparation command, service exit,
readiness timeout, or missing presentation, StoryPointless records the actionable
error, adopts the integrated SHA into the preserved ticket workspace, marks the
candidate as requiring changes, and queues the Implementer automatically. The
correction creates a new immutable candidate and receives Tech Lead review again.
After repeated correction cycles the existing review-return limit pauses for
Product Owner direction. A host/runtime interruption such as an unavailable App
Server or failure to allocate a loopback port instead preserves the failed
candidate's integrated SHA and completed-review provenance and presents **Retry
demo preparation** without a new owner comment. That retry reruns only the
candidate-bound smoke preparation and, on success, advances the existing reviewed
candidate to **Ready for Demo**.
The acceptance Work log routes **Comment** through the existing read-only
ticket-conversation path, preferring the assigned Implementer, then the latest
participating team member, then the Tech Lead. The answer does not supersede the
candidate or resume delivery; **Request changes** remains the explicit revision-loop
action.
In Progress and In Review Work logs keep ordinary comments informational and
offer a separate read-only question action. That action prefers the profile on
the latest active run before the normal participant fallback, remains available
beside a pending permission decision, and can route an owner comment already
saved after that request. Ticket-conversation notifications feed the same
normalized live-activity accumulator used by product Chat, so the responsible
profile and concise current activity appear inline without exposing raw
reasoning.

Demo commands use the selected App Server's standalone `command/exec` API; the app
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

The current adapter discovers the official Codex macOS app by bundle identifier
without consulting `PATH`, supports explicitly selected custom apps and
executables, and remembers one application-wide selection. It checks the
required permission capability, performs the `initialize` / `initialized`
handshake over JSONL stdio, confirms the runtime is macOS, and requests the live
model catalog before reporting a connection. The installed version remains
visible for diagnostics but is not an exact compatibility gate. Missing
capabilities, failed handshakes, and unsupported server-initiated requests fail
closed. Read-only, schema-constrained threads
power backlog suggestions, refinement, planning conversations, and ordinary
single-recipient Ticket and Epic chat. Structured Business Analyst answers
remain separate from ordinary messages and are the only inputs that advance
their governed refinement turn. Delivery and independent Tech Lead review use
`approvalPolicy: on-request`.

Starter-backlog and epic-planning schemas make environment readiness explicit.
The structured result classifies the plan as `sufficient`,
`foundation_required`, or `not_required`; names the proposed or accepted
foundation ticket when required; and classifies every proposal as
`independent`, `establishes`, or `requires`. Decoding rejects an absent
foundation, multiple proposed foundations, a proposed foundation that is not an
Implementer-owned Task, and any `requires` ticket without a direct or transitive
dependency path to the named foundation. This validation happens before
suggestions can become reviewable scope. The assessment itself is not a second
persisted delivery model: accepted tickets, their contracts, and their durable
dependency edges remain the execution source of truth.

Starter-backlog and Epic-planning threads receive bounded accepted-ticket
contracts and relevant verified Product knowledge in their prompt. They are
explicitly prohibited from inspecting repository files or Git history and use
the live database only to refresh mutable context. Other Business Analyst
refinement threads retain their read-only product boundary. None scan unrelated
host installations or pre-authorise runtime paths.
Ticket refinement can attach an existing foundation dependency; when no
sufficient foundation ticket exists, it returns a separate foundation split
recommendation rather than silently expanding the feature contract. Its
structured result also recommends the future delivery role. Once refinement is
complete, the application uses the same ticket-owner routing policy as accepted
Epic proposals to fill an unassigned ticket and its saved draft-sprint item,
while preserving any existing Product Owner assignment.

Developer instructions are composed from focused lifecycle guidance rather than
one universal delivery prompt. Conversation, planning, authorised research,
product-changing delivery, recovery, and independent review each receive only
their relevant operating contract. Research delivery explicitly treats historical
delivery notes as analogous context rather than executable instructions and uses
text-native documentation checks where sufficient; implementation-only runtime,
service, and interactive-demo guidance is reserved for product-changing delivery.
The app then appends internal role guidance, shared Product Owner guidance, and
the selected member's optional custom instructions in that order. The custom
field starts empty and remains an owner-controlled overlay, so the Product Owner
can redirect an agent's approach without making safety and lifecycle rules UI
configuration.

Delivery selects the named `storypointless-delivery` profile: Codex's minimal
platform/runtime reads, one writable ticket worktree, exact read-only access to
the active product's Git metadata and `.storypointless` control directory,
credential and other-product exclusions, and no network. The legacy shared
database remains denied. The profile deliberately does not deny
the ticket worktree's StoryPointless ancestor: the active macOS sandbox denies
metadata traversal at that ancestor before a more specific runtime workspace
root can take effect. Other products, sibling ticket worktrees, and the control
plane instead remain inaccessible because delivery has no broad host read
grant. Homebrew, compiler, SDK, local service, and other system capabilities
outside the minimal runtime are requested through App Server approvals for the
current turn. Delivery instructions prohibit copying or staging the workspace
under `/tmp` or another root as a permission workaround. Each delivery thread
overrides that named profile with read-only access to the exact active product's
central `.git` and `.storypointless` directories. The assigned worktree remains
read/write, but Git metadata and product control data are not writable. Delivery
turns inherit the thread-scoped profile;
they do not reselect the process-wide delivery profile at `turn/start`, because
that would discard the product-specific Git rule. The StoryPointless-owned App
Server process supplies `GIT_OPTIONAL_LOCKS=0`, `GIT_CONFIG_GLOBAL=/dev/null`,
`GIT_PAGER=cat`, and the active developer directory reported by `xcode-select`.
It also places that directory's Git-only `usr/libexec/git-core` directory first
on the managed `PATH`, avoiding changes to unrelated tool resolution. Read-only
status, diff, history, and conflict inspection is therefore noninteractive, does
not attempt optional index refreshes, and bypasses `/usr/bin/git`'s `xcrun` shim
without writing Apple's resolver cache in the host temporary directory. Agents
must not request Git metadata, `xcrun` cache, or host-temporary-directory access
for a Git read. They may inspect Git but cannot stage, commit, create or change
branches, integrate, or promote; the host-side Git workspace manager owns those
mutations and validates candidate ancestry.
Git's object store is product-wide, so this explicitly chooses the product as
the read boundary while retaining ticket-scoped writes and denying every other
product.
When the App Server sends `item/commandExecution/requestApproval`,
`item/fileChange/requestApproval`, or `item/permissions/requestApproval`, the
adapter preserves the bidirectional JSON-RPC request instead of rejecting it.
StoryPointless enables and capability-checks the selected runtime's
`request_permissions_tool`; it does not discover package managers, resolve
project runtimes, or add runtime paths automatically. Delivery guidance tells
the assigned agent to diagnose an `operation not permitted` or `permission
denied` result with non-mutating executable, symlink-chain, and runtime-dependency
inspection. The agent establishes the foreseeable boundary first and submits one
batched request for the smallest coherent filesystem or network capability rather
than discovering an executable, its parent directories, symlink targets, and shared
libraries through sequential Product Owner approvals. For a Homebrew runtime, that
may be one read request for `/opt/homebrew/bin`, `/opt/homebrew/opt`, and
`/opt/homebrew/Cellar`; package-manager data, configuration, credentials, and unrelated
user locations remain excluded. The agent then retries the original command without
adding shell wrappers. An identical sandbox failure after command approval is treated
as evidence that a different capability is missing, not as a reason to repeat the same
approval. Recovery prompts label prior permission details as audit display only: the
agent never pastes a displayed command back into the command tool, omits explicit
`sh -c`, `bash -lc`, and `zsh -lc` launchers, and replaces an interrupted leaf
permission with one consolidated runtime request instead of continuing a path-by-path
cascade. It first consults verified Environments guidance, then prefers the repository's
established native build system and shortest maintained, purpose-named entry point over
a shell chain. When a recurring coherent workflow has no suitable entry point, an
Implementer may add a version-controlled, non-interactive, workspace-relative task or
script as normal product tooling; it must not substitute an unrelated package manager
or runtime, conceal operations, or exist only to obtain broader approval. A service
entry point remains in the foreground, accepts the app-supplied port, and exposes typed
readiness. Verified changes produce a complete Environments proposal describing the
commands, working directory, prerequisites, readiness, required capabilities, and
limitations. Read-only reviewers may use an existing entry point and verify the
proposal but cannot create either. If the permissions tool is unavailable or a
safe coherent capability cannot be established within the current boundary, the
agent fails closed with the diagnostic and required access instead of silently
substituting older verification evidence.
The permission Work log card presents the agent's plain-language purpose first
and places the unchanged exact command and additional access in a disclosure.
Persistence and matching continue to use the exact request, so this presentation
change does not alter one-time or saved-product approval semantics.
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
run remains in **Needs your input** rather than being admitted by the scheduler.
The Product Owner can still Allow or Deny the durable interrupted request. That
decision queues the preserved run, and a matching request from its resumed
Conversation receives the recorded answer automatically. Saved product grants
remain durable.

Every application-owned AgentRun update passes through one coordination boundary.
After the durable write succeeds, a transition from any other status to
`awaiting_owner` plays the bundled ticket-attention sound once. Rewriting or
reloading an already-waiting status stays silent, background-product transitions
use the same path, and shutdown suppresses new playback. Audio failure never
changes the durable attention state.

The same adapter owns buffered and streaming `command/exec`, output deltas, and
termination for candidate demos. The durable run stores the thread identifier
and workspace path so an owner answer or review finding can resume the same
implementation context. It also reads `model/list`; the UI uses each returned
model's advertised effort options instead of maintaining a speculative catalog.
For structured delivery turns, `item/completed` supplies a candidate final-answer
payload but does not close the waiter. StoryPointless retains that payload until
the matching `turn/completed` notification or reconciled durable terminal state,
then validates it and may start a repair turn. This prevents a repair submission
from overlapping the turn whose response it is repairing.
Product Chat turns consume the same supported Codex activity events as
Sprint Board runs, but keep that transient projection keyed by conversation
thread rather than creating a delivery AgentRun. The bottom conversation status
strip shows concise reasoning summaries, planning steps, and local inspection
activity; it never exposes raw chain-of-thought. The final structured result
contains a four-to-six-word durable thread title that aims for five and a
Markdown-formatted answer. Same-member follow-ups resume the stored Codex thread.
When the owner selects another member, the persistence write atomically changes
the current recipient and clears the former role-specific Codex identifier; the
new member starts a fresh read-only session whose prompt contains the durable
visible Chat transcript and whose tools can re-query current product evidence.
Stable agent-facing views are the preferred compatibility contract, not an
artificial limit on that product-scoped read access. When an operational question
requires evidence outside those views, Product Chat may inspect the read-only
schema and query the relevant tables directly. Run-status answers use durable
activity telemetry rather than inferring progress from comments, and permission
answers expose the request's owner-facing purpose and scope without returning
Codex thread IDs, request IDs, signatures, worktree paths, or other protocol
internals. Archival
uses a terminal thread status in the final product schema rather than another
schema migration: messages and the resumable Codex identifier remain durable,
while archived threads are excluded from new top-level room context until the
owner restores them.
Authentication UI and usage telemetry remain subsequent adapter work.

The adapter owns:

- supported protocol fields, initialization, and required capability checks;
- initialization and capability negotiation;
- ChatGPT and API-key authentication presentation;
- thread creation, resumption, steering, and interruption;
- approvals, questions, tool/file changes, diffs, and typed artifacts;
- token/context, compaction, and account-rate-limit telemetry; and
- termination and recovery normalization.

Permission profiles are a beta App Server surface.
StoryPointless therefore supplies its definitions as process-local config
overrides, enables the matching experimental capability explicitly, and covers
the supported protocol behavior with adapter and local runtime contract tests. It never
falls back to full access or the retired custom Seatbelt allow-list.

Unknown versions are allowed to attempt the capability handshake. Missing
required behavior fails closed with an owner-facing recovery path.

## 8. Recovery model

Durable writes occur before a UI projection announces a state. On launch the
application reconciles scheduler leases, child processes, Codex threads,
worktrees, candidate commits, and preview processes. A normal quit requests a
structured checkpoint, interrupts after a bounded grace period, and preserves
the run as paused. Crash recovery creates a system note from durable events and
filesystem state when no agent-authored checkpoint exists.

Implementation recovery is run-bound. App shutdown requeues the existing
implementation AgentRun while preserving its ticket worktree and non-ephemeral
Conversation, except when a live permission decision was outstanding; that run
remains awaiting the Product Owner. A Product Owner stop also leaves the run
interrupted until they resume it. On restart StoryPointless explicitly calls App
Server `thread/resume` to load the persisted Conversation into the new server
process, then first recovers a valid completed structured result when one exists.
Otherwise it starts a focused continuation turn, telling the team member to use
the current workspace and prior context rather than restart the ticket or repeat
completed work and checks. A live approval request cannot survive the old App
Server connection, so its durable interrupted record remains an actionable
**Needs your input** item. Allow or Deny stores the scoped decision and only then
queues the run; if the resumed agent still needs the matching capability,
StoryPointless applies that decision automatically. A missing Conversation is
established only when `thread/resume` reports it unavailable; the replacement
receives the full ticket contract plus an explicit preserved-workspace
continuation instruction.
If the recorded ticket worktree is missing, StoryPointless does not claim that
its uncaptured changes were preserved: it records the loss in the Work log and
prepares a fresh isolated ticket workspace.

An `awaiting_owner` delivery result is run-bound rather than candidate-bound. It
stores its question, options, and optional decision-artifact title and
workspace-relative path in the ticket comment. The artifact path must resolve
inside the preserved ticket workspace, exist as a changed file, and is opened
directly from the Work log. The result must not contain Product knowledge or
follow-up proposals or a demo. Those records require a completed immutable
candidate revision and are produced only after the same run resumes with the
Product Owner's answer.

Review recovery is revision-bound. A Tech Lead turn interrupted by shutdown,
including one paused at a scoped permission request, retains its review run,
non-ephemeral Conversation, detached path, and reviewed SHA. On restart
StoryPointless verifies or reconstructs the detached checkout at that exact SHA,
recovers a valid completed structured result when one exists, or starts a
continuation turn after explicitly resuming the same Conversation. An expired
live approval request keeps the review paused until the Product Owner decides;
saved matching run or product grants apply normally once it resumes. A missing
Conversation starts a replacement review against the same SHA only after
`thread/resume` fails. A missing, mutated, or unverifiable candidate checkout
returns the immutable candidate to review. An unverifiable post-conflict
integrated revision returns it to integration and focused re-review, with an
explicit Work log explanation. A candidate already in **Ready for Demo** keeps its
reviewed revision; only its owned demo process is stopped and restarted.
Product switching is not an execution suspension boundary. The application owns
one product-scoped scheduler task per active sprint, and each scheduler reloads
its own product, plan, tickets, profiles, permission records, and knowledge from
the durable store. The selected product controls only the published UI
projection. Background Implementer, Integrator, and Tech Lead turns therefore
continue without interruption, while their telemetry, permission cards, demo
preparation, and refreshes remain product-scoped. Product archival suspends only
the archived product; app shutdown suspends every product.

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
Only reviewed knowledge is exposed as current truth. Basic “why/how” queries
are part of the first vertical slice and must return citations or an explicit
unknown.

Agent instructions provide the exact active product database path and exact
column schemas for stable read-only views covering tickets, dependencies, Work
logs, Epics, sprints, verified knowledge, decisions, provenance, retrospectives,
and team members. This includes the durable ticket key as `item_key`. Planning
prompts contain a bounded snapshot of active ticket contracts and selected
verified knowledge, while other agent workflows can discover broader evidence
live with read-only SQL and Git. Agents re-query mutable facts before
consequential conclusions so a long-running conversation does not mistake an
old read for current state.

Canonical page templates store an empty body until verified knowledge exists;
empty-state instructions remain a presentation concern. Delivery context
selection lives in Core and uses direct ticket provenance plus bounded,
taxonomy-weighted relevance. Body overlap contributes only a capped score so
page length cannot create a self-reinforcing catch-all.

Readable context and writable destinations are separate durable run records.
`agent_run_knowledge_pages` contains only non-empty verified pages supplied as
reference material. `agent_run_knowledge_destinations` authorizes complete
updates to empty or relevant canonical pages and child-page creation beneath
canonical sections. Proposal validation uses the destination records rather
than treating every readable page as writable. The prompt still shows the full
canonical directory as routing metadata, without presenting unavailable page
bodies as verified context.

Overview, Product principles, Glossary, Ways of working, and Environments form
the central mandatory-page policy. Every product is idempotently backfilled with
the Operations section and Environments page, but an empty page remains only a
destination. Non-empty verified mandatory pages are supplied to implementation,
Tech Lead, Integrator, and other product agent instructions. Delivery context
records combine these pages with bounded ticket-relevant selection, and the Work
log presents the two groups separately.

Environments is always an authorised update destination for an implementation
run so an agent can propose a complete replacement after verifying operational
guidance is absent or stale. It remains read-only to Tech Lead and Integrator
runs. Tech Lead approval uses the existing candidate-bound knowledge proposal
path. Reviewed Markdown is materialized only in the integrated candidate;
ticket acceptance publishes it into canonical Product knowledge. The stricter
Product Owner approval feature flag still adds an explicit per-proposal decision
before ticket acceptance. Stable repository entry points improve exact saved-product
permission matching without converting knowledge into a grant.

An environment-foundation ticket uses that same reviewed knowledge path. Its
delivery contract verifies the approved toolchain and versions, stable
repository-owned build/test/local-run/demo entry points, run-private temporary
and cache locations, required capabilities, a managed readiness check, and
known limitations, then proposes the complete Environments replacement.
Downstream tickets receive the accepted foundation's concise Work log handoff
and verified Environments page through the normal direct-prerequisite context
rules. Production credentials, signing identities, and release authority are
not implied by local environment readiness.

## 10. Implementation and distribution boundary

The repository implements the local control plane, owner-facing planning and
delivery workflow, Codex App Server adapter, isolated ticket workspaces,
candidate review and integration, managed local demos, recovery, Product
knowledge, conversations, retrospectives, and reporting described above.

Architecture descriptions are invariants and intended behaviour, not evidence
that every path is production-ready. Current availability and known limitations
are maintained in the README. In particular:

- release bundles are ad-hoc signed and are not notarized;
- the app does not bundle Codex and requires a compatible installed runtime;
- the Git workspace manager currently invokes the host's Git implementation;
- supported toolchains depend on the product repository and owner-approved
  capabilities;
- no cloud backend, multi-user synchronization, automatic deployment, or update
  service is implemented; and
- the isolation, recovery, and permission model has not received an independent
  security audit.

GitHub Actions may build the same Swift package using the repository's pinned
Apple Silicon macOS and Xcode versions, then publish a branded disk image with
an Applications shortcut as an explicitly marked early release. Adding
Developer ID signing later must use repository secrets, hardened-runtime
signing, notarization, and release verification without making credentials
available to pull-request workflows or agent runs.

Material changes to workflow, persistence, permissions, execution, integration,
or recovery require corresponding updates to this design and the product
specification. Release-only changes update the README and release workflow as
well.
