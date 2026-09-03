# Spedito technical design

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

### SpeditoCore

- Domain records and identifiers.
- Workflow transition policy.
- Declarative SQLite schema, legacy importer, repositories, and transactions.
- Scheduler and run leases.
- Project execution manifest and autonomy envelope.
- Git workspace and merge-queue interfaces.
- Codex and execution-backend interfaces.
- Conversation context boundaries and typed action-proposal validation.
- Evidence, decision, ticket-documentation, and knowledge promotion rules.

### SpeditoApp

- Product, board, team-activity, ticket, acceptance, knowledge, retrospective,
  and longitudinal report views.
- A page-owned action hierarchy, nested vertical-page/horizontal-board scrolling,
  compact aligned team selectors, explicit editing surfaces, and a bottom
  runtime status bar kept separate from agent-profile identity.
- Local notifications and permission presentation.
- Composition root for concrete persistence and execution components.

No UI type is allowed to become the authoritative workflow state machine.

`AppModel` is the application composition and navigation boundary: it constructs
feature coordinators, tracks the selected product and page, and routes owner
commands. Long-lived tasks, polling, cancellation, wake signals, and multi-step
workflow state belong to focused feature coordinators that expose bounded
snapshots or query methods. `ContentView` provides only the root scene routing;
feature screens and reusable presentation policies live in files named for the
owner-facing feature so contributors can change one journey without loading the
entire application surface.

## 4. Durable storage boundary

Each product owns one authoritative database at
`<product workspace>/.spedito/product.sqlite`. SQLite contains normalized
current state and an append-only audit/activity log for that product. There is
no continuously maintained projection or second copy of product truth.
Before the repository's first snapshot, Spedito adds `/.spedito/` to the
repository-local Git exclusion file. The database and its WAL/shared-memory
files therefore never become candidate or accepted Git content, and Spedito
does not modify the Product's tracked `.gitignore` to protect its control data.

The Spedito rename is a one-time compatibility boundary. On first launch, the
app moves an existing `~/Library/Application Support/StoryPointless` directory
to `~/Library/Application Support/Spedito` when the new directory does not yet
exist. Each product's legacy `.storypointless` control directory is then moved
to `.spedito` before its database opens. Preferences from the former
`com.storypointless.app` bundle domain are copied only when Spedito has no value
for the same key. The old names remain accepted only by these migration and
sandbox-denial paths; new data, runtime profiles, and artifacts use Spedito.
Initial tables cover:

- products with an indexed active/archive lifecycle state, a durable curated
  display-color token, and the product's durable ticket key counter — the
  single allocation source for `T` keys, advanced inside the allocating
  transaction and never rolled back by a rejection, so retired keys are never
  reused;
- work items and immutable contract versions;
- Story/Task/Bug work-item classification and an optional epic foreign key;
  epic Created/Planned/In progress/Ready to complete progress remains derived
  from non-archived child tickets, while persisted Open/Closed/Archived values
  record only owner lifecycle decisions. The closed value is presented to the
  product owner as Completed. A durable display-color token visually connects an
  epic to its tickets;
- comments and activity events, including an optional structured product owner
  question with two to four answer options;
- agent profiles and runs;
- product-wide guidance and optional per-profile instruction overrides;
- built-in and custom persona identities, governed capability archetypes, and
  active/archive state;
- ticket-suggestion sessions, proposals, proposal dependencies, and accepted
  work-item dependency edges; a persisted proposal batch allocates final
  durable ticket keys from the product counter and substitutes batch-internal
  temporary references in its prose, so acceptance copies the reviewed key and
  text verbatim instead of renumbering;
- sprints, sprint assignments, forecast slots, dependency admission, internal
  safety limits, and frozen ticket snapshots;
- immutable retrospective notes and action candidates from team runs, product
  owner action ideas that remain owner-deletable only while their sprint is
  active, one durable synthesis state per completed sprint, frozen
  synthesis-source links, consolidated final actions, and their many-to-many
  evidence links;
- decision records and knowledge claims;
- imported-repository provenance, versioned repository-analysis attempts,
  evidence-backed drafts, independent review decisions, and verified knowledge
  publication state;
- GitHub repository connections, immutable observations, safe-sync proofs,
  publication manifests, branches, and pull-request snapshots; and
- product-level conversation threads and messages.

Fresh product databases are created directly from one declarative final schema
and the first distributed build establishes `PRAGMA user_version = 1` as the
public persistence baseline; it does not carry the application's development
migration history. Every schema change after that baseline increments the
version and applies an ordered, restart-safe transactional migration before the
database is used. At the distribution cutover, a one-time,
restart-safe importer snapshots the former shared schema-53 database, isolates
each product through its foreign-key relationships, copies common final-schema
columns into a staged product database, verifies foreign keys and product
identity, and then moves it atomically into place. A completion marker prevents
repeat work while the former shared database remains intact as a recovery
backup. Runtime persistence contains no `schema_migrations` table or historical
migration chain.

Schema version 2 upgrades the released 0.1.0 database with imported-repository
and repository-knowledge provenance, remote repository connections, safe
synchronization attempts, immutable publication attempts and their pull-request
snapshots, external comment provenance and GitHub review context, a non-null
candidate delivery kind, durable owner notifications, and durable agent-run
execution constraints. It generalizes demo sessions from accepted candidates
to any launch source and clears the placeholder draft-sprint goal. Schema
version 3 adds durable delivery-settlement operation and candidate-version
identities, immutable candidate review bindings, and cumulative token usage
that does not reset with context compaction. Status-specific compare-and-swap
updates guard every remote transition, and active-operation partial indexes
enforce one synchronization, one publication, and one repository-knowledge run
at a time per Product. Each migration runs in one immediate transaction with
foreign-key enforcement in force and the resulting version validated before
commit.

Versions the application only ever used before its first release are not
reproduced. Development databases that carry one of those versions cannot be
upgraded and are rejected with an explanation rather than repaired, and a
database written by a newer Spedito is rejected as well. A fresh install and an
upgraded 0.1.0 database are held to producing byte-identical schemas by test.

The application catalog is the set of valid product workspace identifiers and
their databases. Cross-product operations enumerate these stores; product
delivery reads and writes only the owning store. SQLite WAL snapshots allow the
UI and read-only agents to inspect current state safely while it changes.

`SQLiteStore.swift` owns the actor, connection, migration, transaction, binding,
and decoding primitives. Product, epic, work-item, conversation, sprint, run,
candidate, permission, knowledge, activity, retrospective, repository-analysis,
and remote-repository operations are grouped in domain-named `SQLiteStore+…`
extensions. The split is source organization only: one actor remains the
authority, each multi-row mutation stays inside one named transaction, and no
in-memory aggregate becomes a second database.

Selected-product presentation reads a `ProductWorkspacePersistenceSnapshot` in
one SQLite read transaction. Sprint scheduler wakes use a narrower
`SprintExecutionPersistenceSnapshot` under the same rule. That scheduler
snapshot reads only active-sprint tickets, their direct prerequisites, the
active sprint's runs, candidates, and permission requests, plus current
product-scoped profiles, grants, and verified knowledge. Historical backlog,
run, candidate, and permission rows therefore do not amplify every scheduler
wake. Startup preparation owns migration and default seeding; ordinary reloads
are read-only. The product catalog is fetched across stores once and
partitioned into active and archived records in memory. Conversation thread
summaries are part of the selected product snapshot, while message bodies are
loaded only for the selected thread, so query count does not grow with archived
or inactive conversation history. Focused observable application models hold
bounded product-library, conversation, planning, suggestion, retrospective,
demo, Codex, and delivery presentation snapshots. `AppModel` composes those
dependencies and retains application lifecycle, selected-Product, navigation,
and presentation authority; feature orchestration remains in Core-owned
coordinators.

`PlanningConversationWorkflowCoordinator` owns ticket refinement and ordinary
ticket and Epic conversation commands, Codex turn identity and interruption,
same-recipient thread reuse, ticket live activity, durable reply and failure
recording, and post-persistence owner notifications. Its bounded snapshot
contains only active source and recipient identifiers, ticket activity, and
ticket result projections. `AppModel` supplies product-scoped stores, the Codex
client, inherited instructions, notification presentation, and selected-product
projection callbacks, then forwards owner commands.

`EpicPlanningWorkflowCoordinator` owns epic clarification, plan and general
ticket-suggestion generation, invalid-result repair, durable session recovery,
suggestion edits and decisions, owner routing, Codex turn interruption, and
post-persistence notifications. Its bounded snapshot contains the active epic
conversation, outstanding suggestion batches, and decision state. SQLite
remains authoritative for every proposal field and dependency edge. Owner-
reviewed Epic metadata is supplied to retry prompts and retained when a
successful retry persists its plan, so generated output cannot overwrite an
owner edit. `AppModel` supplies product-scoped stores, the selected product and
Codex client, inherited instructions, workspace and notification adapters, and
selected-product projection callbacks, then forwards owner commands.

`SprintPlanningWorkflowCoordinator` owns candidate sprint scope and ranking,
ticket-planning conversations and interruption, exact-version goal generation,
draft persistence and reassignment, readiness evaluation, sprint start, and
product-scoped cancellation and settlement. Its bounded snapshot contains only
message and goal activity plus current readiness issues. `AppModel` supplies
product-scoped stores, selected-product planning context, the Codex client,
workspace and instruction adapters, and presentation callbacks, then forwards
owner commands.

Ticket delivery uses Core-owned workflow boundaries rather than AppModel-owned
transitions or task dictionaries. `TicketDeliveryRuntimeCoordinator` owns
scheduler wake-ups and the identity-safe lifecycle and settlement of
implementation, review, integration, live-activity, permission, acceptance,
and product-cancellation tasks. `TicketDeliveryWorkflowCoordinator` owns the
delivery commands and transitions: implementation execution and evidence,
candidate creation, exact-candidate review, serialized integration and conflict
resolution, return-to-implementation decisions, acceptance and promotion,
completion handoffs and reviewed knowledge, sprint pause/stop, and relaunch
recovery. `TicketDeliveryPermissionWorkflowCoordinator` owns server-request
routing, durable intent-before-delivery resolution, saved-grant replay, and
recoverable acknowledgement.

`SprintWorkRecoveryPolicy` derives restart actions from durable evidence;
`SQLiteStore.performTicketDeliveryRecovery` applies each resulting multi-record
cutover atomically; `AgentPermissionResolver` preserves decision intent across
transport failure; and `GitWorkspaceManager` serializes repository mutations.
The application composition layer supplies store, Codex, remote, demo, and
presentation adapters through the coordinator delegate and forwards owner
commands. Those adapters cannot bypass Core persistence, permission,
cancellation, candidate, or Git invariants.

Repository-changing candidate execution results also retain a schema-versioned
demo launch specification. Durable demo-session rows record the candidate, state,
worktree, allocated loopback port, bounded captured output, and recoverable
failure explanation. The process object itself remains an in-memory operating
system resource and is never inferred to be alive merely because SQLite says it
was running.

Before candidate creation, `TicketDeliveryWorkflowCoordinator` validates the structured execution
result and its Demo recipe against the actual ticket-workspace changes. The model-facing JSON schema
is a discriminated union on `presentation.kind` that mirrors
`DemoLaunchSpecificationValidator`'s structural rules per branch: `artifact` forbids commands and
takes an inert workspace-relative file path; `mac_application` takes a `.app` path with null launch
command, port, and readiness; `command_output` requires a launch command and no path; `static_web`
takes a non-root workspace-relative directory with no commands, port, or readiness; `browser`
requires a launch command and an HTTP readiness check with loopback paths beginning with `/`;
`terminal_application` requires a launch command whose executable is a workspace-relative path
containing `/` (a bare tool name such as `go` or `python3` is rejected) with null path, port, and
readiness, and its command timeout is ignored at launch because the session is interactive. Path
content rules are stated in the branch descriptions but enforced only by the validator's hard-stops
inside the turn's repair loop: schema `pattern` constraints were tried live and rejected
(2026-08-29) because constrained decoding then fabricates conforming-but-false paths and
mis-selects kinds. Empty
command, title, and presentation-path fields stay inexpressible. The demo kind enum is itself derived per
delivery turn from a demo policy. A ticket that stores an owner-approved demo kind — one of the six
presentation kinds, `none` for code-only work, or SQL `NULL` for a pre-contract ticket — is the
primary source: a contracted kind receives a schema admitting only that kind's branch, and a `none`
contract admits only a null demo, so a contract-breaking recipe is structurally inexpressible instead
of a repair turn. The suggestion generator requires the kind on every proposal under a mechanical
product-surface rule — setup and story tickets take the product surface, design tickets about a
visible interface take `static_web` (an HTML screen set or prototype), research and document-first
design outcomes take `artifact` — persistence copies it from the accepted proposal onto the work item, and only
the product owner — through the contested-kind question or an owner decision — may change it; a
contracted delivery that concludes the kind is genuinely wrong returns `awaiting_owner` with
`proposedDemoKind`, Spedito stores the question with its own canonical decision options, and the
owner's exact answer option updates the work item durably before the continuation turn runs
(`DemoKindContestPolicy`, `SQLiteStore.updateWorkItemDemoKind`). For a `NULL` contract the role
heuristic survives as the fallback: a UX designer ticket whose contract promises a reviewable
prototype is contracted by `DeliveryDemoPolicy` to `static_web` alone, exactly as a planned design
ticket is, so the schema admits nothing else; the prompt states that derived medium, and a contest
from such a ticket uses the derived kind as the "keep" option. Until 2 September 2026 that fallback
admitted `browser` and `mac_application` too, and measured pre-contract UX turns committed to
`browser` whenever the model emitted `launchCommand` or `readiness` before `presentation`, a key
order the grammar does not fix and no wording controls; the product owner chose the structural
narrowing. Every other pre-contract delivery turn keeps the full enum. A validation failure receives
at most two
focused repair turns on the same thread, each constrained by the same schema — including the
delivering turn's narrowed demo policy — and the latest exact
failure. Demo-specific repair guidance distinguishes a Spedito-hosted `static_web` directory from an
inert artifact, bounded command output, an interactive terminal program (`terminal_application`,
whose launch command names the built workspace-relative executable), and a product-owned browser
service. Delivery and review guidance both forbid wrapping the product in another surface — a Cocoa
window around a terminal program, a web page that embeds or launches a Mac app, a bundle around a
script — to satisfy a contracted medium; the delivery contests the medium and the tech lead returns
a wrapper with changes requested. A design prototype is not a wrapper: an HTML mock of a native
window or of a web screen is `static_web`, never `mac_application` or `browser`. The delivery
guidance carries one literal, validator-passing recipe shape per kind, presentation object first,
and the catalogue is role-specific (`CodexLifecycleGuidance.ticketDeliveryInstructions(mode:role:)`):
implementation roles read all six shapes, while the UX designer reads a two-shape design catalogue
— `static_web` for a prototype or HTML screen set, `artifact` only for an explicitly document-first
contract — followed by the rule that a design delivery never returns `browser`, `mac_application`,
`command_output`, or `terminal_application`. Pre-contract UX delivery samples copied the shared
catalogue's `browser` shape verbatim, placeholder path included, or handed the HTML directory over
as a bundle whenever those shapes were in the designer's instructions. Repair never discards the
workspace or repeats successful checks; a second invalid repair settles as a reviewable failed run
whose existing thread and workspace remain available to **Retry work**.

Acceptance of a repository-changing candidate also publishes or updates the
product's canonical demo recipe knowledge page for that recipe's presentation
kind (`SQLiteStore.upsertCanonicalDemoRecipePage`, rendered by
`CanonicalDemoRecipeKnowledge` with the exact recipe JSON and a plain-language
summary, under the canonical Operations section). The page is durable domain
state derived at acceptance: owner-visible, included in every delivery run's
context for the ticket's contracted kind with the instruction to reuse it and
extend it only for a genuinely new surface, authoritative over README wording
for how the demo runs, and idempotent under re-acceptance after a preserved
interruption. It is never read back as authority for launching accepted
versions — `AcceptedAppLaunchPolicy` still reads candidate rows — and no
delivery run may update it directly. Within a ticket's revisions the Layer 1
recipe pin wins; the canonical page seeds the first turn of a new ticket.

A revision or continuation turn does not re-decide a demo contract its feedback
did not name. When tech lead feedback requests no demo change,
`DemoRecipeRevisionPolicy` pins the prior candidate's validated demo recipe: the
revision prompt states the pinned recipe, and the coordinator replaces the
turn's returned demo with it before validation, so an unrelated fix can neither
change a working recipe nor fail a demo hard-stop it was not asked to touch. A
result awaiting the product owner keeps its contractual null demo. Recovered
continuations derive the same pin from durable state — the sent-back candidate
row and the ticket comments made since it by anyone other than the implementer —
so a demo-failure send-back or a reviewer naming the demo re-opens the recipe
while unrelated direction does not. Only feedback that names the demo may change
it.

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
- A **run** is one bounded attempt with one Codex thread and, for delivery work,
  one writable ticket worktree.
- A **scheduler lease** prevents the same run from executing twice.

The built-in starter profiles are business analyst, UX designer, Lead, and
implementer. The Lead is the default reviewer for ordinary tickets. Frontend,
backend, security, and other specialist profiles are owner-added capabilities,
not required permanent roles. Implementation and review remain separate runs;
no profile can attest independently to work it produced. Sprint planning assigns
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
post-approval finalization into four decision-oriented stages: **In progress**,
**In review**, **Ready for demo**, and **Done**. Integration and tech lead review
share **In review**, with the card and work log stating which activity is current.

`TicketDeliveryRuntimeCoordinator` is the single lifecycle registry for product
schedulers and delivery child operations. It keys every operation by durable
product, run, candidate, or work-item identity; duplicate scheduling wakes the
existing scheduler, replacement tokens prevent stale completions from clearing
newer work, and product cancellation or shutdown cancels and awaits every owned
child. `TicketDeliveryWorkflowCoordinator` is the corresponding transition
authority and uses the runtime registry to admit implementation, review,
integration, acceptance, and recovery work without storing a second workflow
state. `TicketDeliveryPermissionWorkflowCoordinator` applies the same boundary
to live and recovered capability decisions.

Focused non-delivery runtimes apply the lifecycle-ownership rule to ticket
suggestions, planning conversations, retrospective synthesis, product
conversations, and Codex connection monitoring. Short-lived owner commands are
retained by a product-scoped command runtime so product archival and
application shutdown also settle them before persistence closes.

Thirty dependency-free tickets produce thirty admitted runs in the local MVP.
Account or machine back-pressure may delay the underlying turns, but there is no
owner-entered concurrency number and reusable profiles do not represent finite AI
headcount.

## 6. Repository and integration lifecycle

Every delivery run starts from a recorded local-trunk commit in a private branch
and worktree. On completed structured output, Spedito compares reported paths with
the actual workspace:

- actual repository changes produce an immutable `repository_change` candidate,
  a host-owned candidate commit, and a required managed demo recipe;
- an empty workspace may produce a `local_outcome` candidate only for the
  business analyst role. Its immutable evidence is the completion handoff,
  reported checks, review instructions, and candidate-bound product knowledge
  proposals already persisted in SQLite. Its base and head identify the unchanged
  checkout, but Spedito creates no commit and requires no demo; and
- every other role fails closed when it reports completion without repository
  evidence.

Repository-changing candidates follow the Git integration lifecycle:

1. Replay each candidate into its own ephemeral integration worktree based on
   the latest accepted trunk. All eligible candidates may proceed in parallel.
2. For a connected Product, fetch and validate the exact GitHub default-branch
   head, then merge that verified revision into the ticket integration.
3. Surface local or GitHub conflicts as explicit integrator work; resolve only
   unambiguous overlap and pause material choices for the product owner through
   the ticket's existing question and work log lifecycle.
4. Run independent Lead reviews in parallel against detached workspaces pinned
   to the exact integrated commits.
5. Pin the preview to the reviewed integrated candidate and advance trunk only
   after human acceptance of that exact commit.

A local-outcome candidate bypasses integration and GitHub publication. It enters
the same independent Lead review queue, where the reviewer evaluates only the
candidate-bound SQLite outcome and must not infer delivery from the unchanged
checkout. Approval moves it directly to the owner-facing **Ready for demo** state
without a managed demo action. Product owner acceptance publishes accepted
knowledge, records the completion handoff, and completes the ticket without
moving `trunk`.

The merge path is deterministic first and agentic only when necessary. Git first
attempts to merge a candidate with accepted local trunk without involving an
agent. A connected Product then performs an authoritative GitHub identity/head
check, retains the exact verified observation ref for the bounded integration
operation, and merges that remote head into the same isolated worktree. Only
after this integration succeeds does the Lead review begin. If GitHub moves
after review while the publication or demo is prepared, Spedito requeues the
candidate through integration and reviews the newly integrated result.

A file conflict from either source creates an **Integrator** system run with the
reported unmerged paths, ticket context, and preserved conflicted worktree. The
integrator inspects only the affected files and nearby context, edits
unambiguous overlap, and returns without running a second review or test pass.
Spedito performs mechanical Git validation and owns the merge commit. The
integrator must return semantic or product conflicts to the relevant ticket as
a Product Owner question. Its run, question, response, comments, and recovery
remain in that ticket's existing lifecycle; independent tickets may continue
while direct dependants wait. The integrator is not an independent product
persona and cannot approve its own resolution. Conflict resolution completes
before the tech lead reviews the exact final integrated candidate. The board
keeps this understandable as **In review**, while the card and work log
distinguish **Queued to integrate**, **Integrating changes**, **Resolving a
conflict**, and **Tech lead reviewing**.

The tech lead review is an evidence-only once-over, not a second verification
run. For repository-changing work, the reviewer may read the ticket contract,
dependency handoffs, exact delivered diff and integrated workspace, directly
relevant files, reported checks, knowledge proposals, and demo contract. For a
local outcome, it receives the same contract plus the candidate-bound completion
handoff, checks, limitations, decisions, and knowledge proposals from SQLite;
the unchanged checkout is not delivery evidence. It does not build or test,
execute a candidate, launch a preview, revisit research sources, use the network,
or request additional capabilities. Missing evidence blocks only when required
by the contract or when a concrete material claim is unreviewable; the reviewer
reports that gap instead of producing the evidence. Review threads use the
configured reviewer model and reasoning effort.

The tech lead may return a candidate only for a concrete material defect that
justifies the full implementation, integration, and review loop. Cosmetic diff
hygiene and optional style-only checks are non-blocking unless they cause a
behavioural, rendering, validity, required-gate, reviewability, or security
failure. Re-review applies the same threshold to previous feedback, so an
earlier blocker label does not perpetuate a non-material cycle. The fifth review
return to **In progress** preserves the workspace and findings but pauses automatic
revision until the product owner provides direction.

Git implementation is behind a protocol. The current workspace manager invokes
the host's `/usr/bin/git`, so an early build may depend on an installed Apple
developer toolchain. A later self-contained distribution must provide or embed a
compatible Git implementation and must not trigger an unexpected Command Line
Tools installation during the product owner workflow.
Spedito-owned commits and merge commits explicitly skip Git signing so the
non-interactive workflow never requests access to the product owner's personal
signing key. This is scoped to each Spedito command and does not change the
owner's global or repository Git configuration.

All post-activation repository checks, polling reads, and delivery mutations use
the same `GitWorkspaceManager` actor. Multi-process asynchronous remote
operations acquire a FIFO repository lease for their complete check-and-mutate
sequence; nested exact-ref checks inherit that lease. While such an operation is
suspended, an unrelated synchronous command for the same Product fails with the
stable owner-facing `operationInProgress` error instead of starting a competing
Git process. Operations on an exact publication branch query only that ref;
full remote-head enumeration is reserved for proving that a new remote is empty.
Public repository cloning targets an unregistered staging directory before a
Product can poll or deliver against it.

### 6.1 Imported repository activation and knowledge

Repository onboarding accepts only canonical HTTPS URLs from GitHub, GitLab,
Bitbucket, or Codeberg, without credentials, query strings, fragments, or
non-default ports. Git runs with hooks, credential helpers, global/system
configuration, filters, pagers, prompts, and inherited signing disabled. Clone
output is staged beneath a UUID-owned import directory.
Activation requires a named remote default branch with at least one commit, a
byte-safe collision check against `.spedito`, a clean worktree, and local
`trunk` pointing at the exact imported commit. The full history, source default
branch, and `origin` remain in the clone. Only after the product database,
repository provenance, starter team, starter knowledge tree, and pending
analysis run are durable does Spedito atomically move the clone into the normal
product workspace and register the store. Cancellation or failure removes only
Spedito-owned staging and unregistered activation paths.

The Core-owned repository import coordinator is the single operation owner for
both public-link and authorized GitHub imports. Its snapshot bounds transient
catalog, device-authorization prompt, progress, cancellation, and typed retry
state; its completion contains the exact activated product, repository
provenance, and pending knowledge-run identity. GitHub access tokens remain
inside the source resolver and short-lived Git credential session rather than
crossing into App state. AppModel observes that snapshot, changes selection only
after activation completes, and then schedules repository understanding as a
separate operation.

Repository understanding is a product-scoped background state machine:
`pending_analysis`, `analyzing`, `reviewing`, `publishing`, then `completed`,
with durable `failed`, `interrupted`, and `stale` outcomes. Analysis reads an
immutable snapshot materialized from the exact accepted Git tree. Path parsing
uses NUL-safe or private-delimiter Git records, rejects undecodable or colliding
paths, and includes only regular blobs permitted by the source-path policy.
The snapshot excludes `.git`, `.spedito`, credential-shaped paths, symlinks,
submodules, and other non-regular objects, records a content digest, becomes
read-only before Codex can inspect it, and is removed after a terminal attempt.

Completed analysis with no approved or published product knowledge is a terminal
result, not an ambiguous recovery state. Relaunch does not create another Codex
turn. Presentation explains that no verified product knowledge was found and
offers a new versioned attempt only through an explicit product-owner action.

The Core-owned repository knowledge coordinator serializes one command per
product and owns recovery, retry, dedicated clients, live turns, activity
monitors, and snapshot cleanup. SQLite permits only one active knowledge run per
product; interrupted-run retirement and retry creation share one transaction.
AppModel observes a bounded product snapshot only. It keeps knowledge-page
read/unread presentation state and refreshes that projection from the
coordinator's durable completion event. `CodexLiveActivityAccumulator` ignores
raw reasoning deltas and exposes only bounded reasoning-summary, plan, and
tool-category activity; the coordinator clears this ephemeral field when its
run terminates.

Repository analysis uses a dedicated Codex App Server process, not the normal
delivery client. Its process environment is replaced with a minimal allowlist.
Spedito serializes a bounded, line-numbered set of UTF-8 files from the
sanitized snapshot, together with its permitted path manifest and omitted-file
list, directly into both analysis prompts. The agents are instructed not to
invoke tools or shell commands; the exact snapshot remains their only readable
workspace root, model-controlled subprocesses and network access are denied,
approval policy is `never`, and repository instructions remain untrusted
evidence. The Codex host still uses the product owner's internet connection to
send that supplied evidence to the selected model provider; the sandbox rule
prevents the analysis agent from browsing or contacting additional services,
not that provider transport.

A business analyst structured turn prioritizes evidence-backed updates to
supported empty starter pages before proposing additional feature pages. Its
strictly decoded drafts are persisted before a separate tech lead thread
independently evaluates every draft against the same serialized repository
evidence and returns exactly one approve/reject decision per draft. Spedito
revalidates accepted `trunk`, every evidence path, and every canonical page base
before accepting the review.

Publication revalidates accepted `trunk`, every evidence path, and every
canonical page base before changing authoritative knowledge. Approved drafts,
page revisions, provenance, and the completed analysis state are committed
atomically in SQLite. Repository files and `trunk` remain unchanged; existing
repository documents are evidence rather than managed knowledge output.

### 6.2 GitHub synchronization and pull-request publication

The remote boundary uses one GitHub App with Device Flow and expiring
user-to-server tokens. The build contains only the public App client ID and
slug. Tokens are stored as one versioned account payload in Apple Keychain;
refresh and sign-out are serialized around in-flight token leases. The REST
client accepts only fixed GitHub HTTPS hosts, refuses redirects, bounds bodies,
arrays, pages, strings, rate-limit delays, and request timeouts, and exposes
only Metadata read, Contents read/write, Pull requests read/write, and Workflows
write capabilities. Administration write is deliberately omitted, so repository
creation stays on GitHub rather than broadening the App's authority. There is no
client secret, private key, in-app repository creation, or CI/check aggregation.

`GitHubRemoteRepositoryService` is the single Core actor composition root, but
callers depend on narrow state, connection, observation, safe-synchronization,
publication, lifecycle, and import-source protocols. Its implementation is
grouped by those workflows; the credential session, account catalog, API client,
and Git workspace manager remain behind the actor boundary. The app layer's
`RemoteRepositoryFeatureModel` owns remote command serialization, cancellation,
recovery, pull-request polling, and product-scoped presentation state. It
projects one bounded snapshot per product containing repository state, a
short-lived authorization prompt, busy state, a typed failure, and setup
activity. `AppModel` forwards owner commands to that feature model and does not
retain parallel remote dictionaries, tasks, or a broad Core service reference.

Product creation/import, repository settings, repository setup, incoming-change
review, sprint-board repository status, and ticket pull-request status are
separate presentation units. Each renders feature snapshots and sends owner
commands back through `AppModel`; only dismissal, selection, and focus state
remain local to a view. Application active/background changes are delivered as
one feature command, which restarts the single adaptive polling loop so
foreground priority takes effect immediately. Debug builds include a finite
scenario catalog covering unavailable, setup, synchronization, publication,
review, reconciliation, and retry states.

Only active products enter automatic remote recovery. Archiving first settles
or blocks in-flight remote commands and preserves durable connection,
synchronization, and publication records without accessing Keychain, GitHub, or
remote Git. Restoring the product is the authority boundary that allows those
preserved states to resume.

The account catalog can authorize an account directly from Product creation and
enumerate public and private repositories exposed by every locally authorized
GitHub App installation without exposing tokens to presentation code. Product
connection reuses the sole authorized account when unambiguous; otherwise it
starts Device Flow. Product creation carries only the selected repository ID
into the remote service, which resolves its canonical URL and account. A
repository with history is cloned through a scoped credential session and the
activated Product is linked back to that exact source. An empty repository
creates a blank local Product, then reuses the local-Product initialization flow
to verify and seed that exact remote. Manual public-HTTPS entry remains a
credential-free fallback and continues to require importable history.

The import catalog retains each authorized installation even when it currently
exposes no repositories. Product creation uses those installation identities to
open the exact repository-access settings and refreshes the catalog when the app
becomes active again, so newly granted repositories appear without repeating
Device Flow.

Git receives a token only through a UUID-owned `git credential-cache` socket
with `credential.useHttpPath=true`. Import clone, fetch, and push operations
supply command-scoped configuration, reject inherited helpers and prompts, then
reject the credential, exit the cache daemon, and remove the session directory.
GitHub tokens never appear in a remote URL, process argument, repository config,
`~/.git-credentials`, log, SQLite row, ticket, work log, or pull-request body.

An imported Product may connect only when its canonical GitHub identity,
preserved `origin`, and source default branch still match. A local Product
selects an accessible empty repository. Spedito re-reads its API identity,
proves that it has no heads, pushes the local bootstrap root with create-only
lease semantics, verifies the resulting head, and records the remote connection
before normal publication is allowed.

For an imported Product, connection matches only the immutable imported target.
If the GitHub App lacks repository access or updated permissions need approval,
presentation opens the existing installation settings and refreshes
installations when Spedito becomes active again. Recovery controls remain
available if the browser step is cancelled or GitHub has not propagated the
grant.

Every repository check performs an API repository/head read, fetches the branch
into a disposable quarantine object store with a 512 MiB allocated-storage
ceiling, validates the quarantined observation, and copies only its verified ref
into the product repository before repeating the API read. The observation is
useful only when all identities and SHAs agree. Incoming paths are decoded from
NUL records and checked component-by-component for undecodable values and
case/Unicode collisions with `.spedito`. Before promotion, Git attributes are
read from the candidate tree and every named filter is neutralized with
command-scoped no-op clean/smudge/process configuration. Unsupported
`check-attr --source`, submodules, Git LFS pointers, non-regular entries, unsafe
paths, or manifest inconsistencies fail closed.

Starting a sprint does not perform a blocking repository check. Manual safe-sync
preparation and acceptance remain rejected while a sprint is active or paused
so accepted `trunk` cannot move underneath ticket workspaces.

Before a reviewed ticket is published, the integration lifecycle performs a
fresh repository check. Aligned and local-ahead history require no additional
merge. For remote-ahead, history-alignment, or related divergent history, the
validated observation ref and exact remote SHA become inputs to the ticket's
isolated integration worktree. Git attempts the merge first; conflicts reuse the
durable Integrator run and ticket owner-question path. The observation ref is
released after Git records the remote commit in the integration or preserved
merge state. Unrelated history and repository states that fail quarantine
validation stop before an agent runs.

This automatic ticket integration never advances accepted local `trunk`.
Fast-forward acceptance through the explicit diagnostic workflow still stores
the exact local base, remote candidate, tree, observation ref, commits, and paths
before owner confirmation. Promotion revalidates the current `trunk`, checkout,
candidate tree, and validated path set, updates `trunk` and the worktree without
running hooks or filters, then records completion. If GitHub rewrites a merged
Spedito pull request, manual history alignment remains available only when the
prior immutable publication proves the published head and resulting tree.

Repository-changing ticket publication captures the reviewed candidate SHA and
tree, exact remote base, outbound object manifest, commit/path summaries, and
deterministic `spedito/<product-slug>-<product-id-prefix>-<captured-sha-prefix>`
branch. The first reviewed repository-changing candidate creates a draft pull
request automatically. A later
reviewed candidate for the same ticket may replace its captured revision and
remote base, then update the existing branch only with an exact force-with-lease
against the previously observed pull-request head. The durable transition clears
the old pull-request snapshot while retaining its published head as the branch
lease; recovery re-discovers the same pull request after the new head is pushed.
The publication row retains the ticket and candidate foreign keys so recovery
cannot publish or approve the wrong revision. Branch creation and pull-request
creation remain idempotent through exact head lookup around ambiguous failures.
After GitHub reports the unchanged head merged, Spedito deletes its publication
branch with an exact lease; a moved branch is preserved and fails closed.

For a mature locally created Product, connection captures the accepted local
`trunk` after the minimal bootstrap root, seeds only that root to the empty
remote default branch, and durably creates an
`existing_product_history` publication for the captured head. The publication
is non-draft and automatically invokes the same exact-head merge endpoint and
mechanically proven local reconciliation as ticket approval. Recovery resumes
remote initialization, branch/PR creation, and exact baseline merge from their
durable states without creating another publication.

GitHub review decisions and inline comments are fetched from bounded REST
endpoints and deduplicated into external-author work log comments by stable
GitHub identifiers. Inline comments persist the path, old/new line range,
reviewed and original commit SHAs, and bounded diff hunk; the same structured
context is rendered locally and supplied to resumed delivery agents.
One Product-scoped coordinator serially checks every active
ticket pull request for the selected Product, prioritizing the visible ticket
and tickets in acceptance. It uses 60-second foreground cycles when prioritized
work exists, 120-second ordinary foreground cycles, 300-second inactive cycles,
and conditional REST requests with bounded in-memory ETag response caching.
The polling sleeper is injected at the feature-model boundary, so product
switches, app activity changes, and shutdown cancel the current wait and are
covered without wall-clock sleeps in tests.
Fresh repository checks and product owner approval remain unconditional
authoritative checks. `CHANGES_REQUESTED` converts the pull request back to
draft and requeues the ticket's existing delivery run. After internal review
and demo gates, Spedito uses GitHub's GraphQL draft-state mutation to mark the
repository-changing pull request ready. Product owner ticket approval rechecks the open,
non-draft, unchanged head and exact remote base, then invokes
GitHub's merge endpoint with the
expected head SHA. If the default branch moved or GitHub reports that the exact
ticket is no longer mergeable, Spedito returns the pull request to draft and
requeues the same candidate for remote-aware integration and focused review.

Ticket acceptance is owned by the ticket-delivery runtime coordinator rather
than a detail view or an untracked application task. The view dismisses as soon
as that operation is retained, and a published work-item ID set drives
**Completing ticket** presentation if the owner returns to the board or ticket.
After preflight, candidate `promoting` state remains the durable interruption boundary.
Repository-changing acceptance performs the authoritative remote check, merge,
local reconciliation, and trunk promotion. Local-outcome acceptance skips Git
and GitHub, marks the exact reviewed candidate accepted, publishes its approved
knowledge proposals, appends the completion handoff, and completes the workflow.
Completion failures restore a reviewed candidate to `ready_for_demo`, retain the
ticket in acceptance, append an actionable work-log failure, and permit an
idempotent retry. The workflow does not transition the ticket to Done until all
operations required by that candidate kind succeed. A moved publication branch,
changed pull-request head, closed pull request, or unsafe repository state fails
closed for repository-changing work. External approval never completes a ticket,
and Spedito does not aggregate CI checks.

On launch, stable `accepting`, `checking`, `pushing`, `branch_published`, and
`creating_pull_request` phases resume from their durable proofs. Terminal merged
publications do not initiate GitHub or Keychain access during launch recovery.
Shutdown stops new remote work, cancels bounded external waits, lets Git and
credential cleanup finish, then closes credential sessions without requiring
GitHub to be available.

### 6.3 Managed candidate demos

Every newly completed repository-changing delivery includes a typed demo recipe.
Supported presentations are a product-owned loopback browser preview, a
Spedito-hosted static web prototype, a workspace-relative macOS application
bundle, an interactive terminal program opened in Terminal.app from a built
workspace-relative executable, an inert workspace-relative artifact from an
explicit allowlist, or captured output from a bounded scenario. Product browser recipes contain
executable and argument arrays, never shell command strings. Working directories,
applications, prototypes, and artifacts resolve inside the reviewed checkout;
product browser URLs contain only a path, and Spedito allocates and injects their
loopback port.

A static web recipe names a non-root workspace-relative directory containing
`index.html` and has no preparation command, launch command, port variable, or
readiness declaration. Spedito owns its loopback server and lifecycle, serves
only regular files whose resolved path remains inside that exact directory, caps
individual resources, disables caching and external connections through response
policy, smoke-tests the entry page, and stops the server with the demo session.
It therefore gives a blank Product an interactive prototype path without
treating a machine runtime as approved product infrastructure.

The recipe is the executable form of the readiness sequence the candidate
documents in the repository, its completion handoff, or proposed Environments
knowledge: every documented build, generation, or other preparation step the
product needs before it runs appears in `preparationCommands` in documented
order, so the clean-checkout smoke test proves the same claim the documentation
makes. Delivery guidance forbids documenting a readiness step or check as
verified unless the run executed it and reported it, and the tech lead treats a
documented preparation step that the recipe omits as a materially false
operational instruction that blocks review.

Local outcomes have no demo recipe or demo session. Their **Ready for demo**
presentation is an in-app review card containing the concise outcome, an
expandable copy of the full completion handoff and evidence, and the exact
decision and checks for the product owner. Candidate-bound product knowledge
proposals remain separate reviewable work-log records.

The delivery sandbox is intentionally non-interactive and does not own the
logged-in desktop session. An implementer does not call operating-system GUI
launchers, run a graphical executable to prove that a window appears, or
automate desktop interaction. For a macOS app recipe, sandboxed preparation
builds the bundle and smoke testing verifies its workspace-relative path and
executable without launching it. Only Spedito opens the validated bundle through
Launch Services, and only after the product owner explicitly chooses **Demo** or
opens an accepted app version. For a terminal app recipe, sandboxed preparation
builds the program and smoke testing requires the launch command's
workspace-relative executable to be a regular, non-symlink, executable file
inside the reviewed checkout without running it, because an interactive
program would hang a bounded smoke. At launch Spedito writes a zsh launcher
script (`TerminalDemoLaunchScript`) into the preview's
`.spedito-demo-runtime/terminal/` directory with mode 0755 and opens it with
Terminal.app through `NSWorkspace.open(_:withApplicationAt:configuration:)`;
no AppleScript, Automation consent, or shell string is involved. The script
sets the window title, moves into the recipe's working directory, exports the
same `TMPDIR`, `XDG_CACHE_HOME`, and `SPEDITO_DEMO_DATA_DIRECTORY` that
sandboxed demo commands receive, records its pid, and `exec`s the program. The
program then runs on the host in the owner's login session with the owner's
privileges, outside the `spedito-demo` sandbox, exactly as a Mac app bundle
does once Launch Services opens it. Rendered markdown strips non-HTTPS links, and the
application URL-opening boundary independently permits only credential-free
HTTPS destinations with a host.

After tech lead approval, Spedito creates or reuses a detached preview
worktree pinned to the current integrated SHA and smoke-tests the recipe without
opening its presentation. A candidate enters **Ready for demo** only after that
test succeeds. The product owner's **Demo** action prepares the same exact
revision, starts or reuses a managed service where the recipe requires one, and
opens the browser, validated macOS application, Terminal window running the
reviewed program, inert artifact, or captured result.

Multiple independently reviewed candidates may integrate, receive any necessary
conflict resolution and focused re-review, and prepare demos in parallel.
Promotion still requires a clean accepted workspace checked out at current
`trunk`, the approved revision to contain that trunk, and serialized compare-and-
swap ref movement. A durable `promoting` candidate state makes interrupted
acceptance resumable before post-promotion publication runs. When another
approval advances trunk, Spedito stops and removes any now-stale preview,
returns its already reviewed candidate to the integration queue, and prepares a
new exact demo revision. A clean re-integration retains the immutable candidate
review; conflict resolution requires focused tech lead re-review.

When a post-conflict tech lead review or product owner demo requests another
implementation revision, the host adopts the exact reviewed integrated SHA into
the preserved ticket branch with an idempotent fast-forward before resuming the
implementer. It validates a clean ticket worktree, the expected immutable candidate
HEAD, and candidate ancestry first. The candidate record remains immutable; only the
mutable implementation branch advances. The continuation identifies the old candidate
and adopted integrated SHA so the agent preserves accepted trunk behavior and conflict
resolution rather than rediscovering them. Any dirty or divergent state fails closed
instead of delegating Git repair to the agent.

If review succeeds but smoke preparation reports a candidate-controlled failure,
including an invalid recipe, failed or timed-out preparation command, service exit,
readiness timeout, or missing presentation, Spedito records the actionable
error, adopts the integrated SHA into the preserved ticket workspace, marks the
candidate as requiring changes, and queues the implementer automatically. The
correction creates a new immutable candidate and receives tech lead review again.
After repeated correction cycles the existing review-return limit pauses for
product owner direction. A host/runtime interruption such as an unavailable App
Server or failure to allocate a loopback port instead preserves the failed
candidate's integrated SHA and completed-review provenance and presents **Retry
demo preparation** without a new owner comment. That retry reruns only the
candidate-bound smoke preparation and, on success, advances the existing reviewed
candidate to **Ready for demo**.
The acceptance work log routes **Comment** through the existing read-only
ticket-conversation path, preferring the assigned implementer, then the latest
participating team member, then the tech lead. The answer does not supersede the
candidate or resume delivery; **Request changes** remains the explicit revision-loop
action.
In progress and in review work logs keep ordinary comments informational and
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
the app's cache directory, separate from the denied Spedito control plane
and ticket worktrees. The profile grants broad read access for normal macOS,
Homebrew, compiler, SDK, and runtime dependencies without enumerating binaries
or configuration files, while only the current candidate is writable and
credentials and `.env` files remain denied. Demo networking is enabled only for
`localhost` and `127.0.0.1`.

Before preparation runs, a reused preview checkout is reset to a clean detached
state (tracked modifications restored, untracked and ignored artifacts removed)
unless a live demo session may still be serving from it, so artifacts a previous
preparation could not delete never poison the next attempt. A managed access
probe then proves the sandbox honors the full create-and-delete lifecycle the
product's own scripts rely on; a denial fails fast as a retryable host failure.
Owner-facing preparation failure text rewrites absolute workspace paths as
workspace-relative paths before it reaches an alert or a work log entry.

Bounded commands disconnect their candidate-scoped App Server after capturing
the result. Long-running commands retain that connection and use its process
identifier while streaming output. Recipes must remain in the foreground;
detached or daemonized services are invalid because they cannot provide reliable ownership.
**Stop demo**, feedback, approval, product switching, shutdown, and App Server
disconnection terminate the managed command session. Feedback and approval
additionally remove the acceptance preview worktree.

A terminal program is owned through its pid, never through the Terminal
window. The launcher reads the pid the script recorded before `exec` (polling
up to five seconds after the script opens; a pid that never appears is a host
`couldNotOpen` failure), keeps it as transient runtime state, and checks
liveness with `kill(pid, 0)`. **Stop demo** sends `SIGTERM`, waits up to two
seconds, then `SIGKILL`, and removes the pid file. Spedito never closes the
Terminal window: like a browser tab, it may belong to the owner. Closing the
window ends the program; the next **Open demo** sees the dead pid, drops the
runtime, and relaunches. After a Spedito relaunch the durable session is marked
stopped like every other kind and a stale pid file is ignored, never
signalled.

Repository analysis may return a structured imported-app launch proposal
alongside product knowledge drafts. The proposal contains a validated browser,
macOS app, or terminal app `DemoLaunchSpecification` and exact snapshot
evidence. It remains inert until
an independent tech lead returns a separate decision for that exact proposal.
An approved proposal is stored with its repository-analysis run and exact
`analyzedSHA`. Artifact, command-output, executable-artifact, and unsupported
URL presentations fail Core validation. If a proposed recipe fails Core
validation, the same schema-constrained analyzer thread receives the exact
validation failure and one correction turn. Product knowledge drafts from the
first response remain fixed during that correction. A second invalid optional
recipe is omitted with its diagnostic retained in the knowledge-run summary; a
launch-only **Check imported source** run instead fails with the actionable
validation reason. Rejected, missing, unsupported, or under-specified recipes
produce no imported app version.
A product owner may explicitly run **Check imported source** later. That creates a
launch-only analysis run pinned to the original
`ProductRepository.importedSHA`; its analyzer contract requires an empty knowledge
draft list, Core rejects knowledge mutations for the run, and the same independent
review and evidence checks apply. Repository prose is never parsed or executed as
an implicit recipe.

The selected product's **Demos** workspace combines the approved imported
browser, macOS app, or terminal app recipe, when present, with every accepted
browser, static web prototype, macOS app, or terminal app candidate that has a
valid schema-versioned recipe. Entries are ordered by
their publication or acceptance time and the latest is selected by default. Any listed version
recreates a managed preview from its exact imported or integrated SHA. Durable
`DemoSession` identity is `(source_kind, launch_id)`, so imported analysis
proposal IDs and accepted candidate IDs share the lifecycle without masquerading
as each other.

Opening is idempotent: it reuses and reactivates a ready runtime. Only one
managed app version may run per product, so opening or demonstrating another
version stops the current owned runtime while preserving its managed preview
cache. **Stop app** also preserves that cache for a quick reopen. Before a newer
runnable candidate becomes accepted, Spedito stops any running version and
removes the previous latest accepted version's managed preview; historical
accepted candidates and the imported source remain selectable.
Accepting artifact or command-output evidence does not alter app version history
or stop its current runtime. On restart, a previously active durable session is
marked stopped rather than being mistaken for a live process. Browser tabs,
Terminal windows, and shared document-viewer windows are not force-closed
because they may belong to the product owner rather than the demo session.

## 7. Codex adapter boundary

The current adapter discovers the official Codex macOS app by bundle identifier
without consulting `PATH`, supports explicitly selected custom apps and
executables, and remembers one application-wide selection. Runtime version and
feature probes have fixed wall-clock and output limits. The adapter checks the
required permission capability, performs the `initialize` / `initialized`
handshake over JSONL stdio, confirms the runtime is macOS, and requests the live
model catalog before reporting a connection. App Server children receive a
replacement allowlisted process environment; arbitrary inherited credentials
and cloud tokens are not propagated. The installed version remains visible for
diagnostics but is not an exact compatibility gate. Missing capabilities, failed
handshakes, and unsupported server-initiated requests fail closed.
Read-only, schema-constrained threads power backlog suggestions, refinement,
planning conversations, and ordinary
single-recipient ticket and epic chat. Structured business analyst answers
remain separate from ordinary messages and are the only inputs that advance
their governed refinement turn. Delivery uses `approvalPolicy: on-request`.
Independent tech lead review uses `approvalPolicy: never`: its detached candidate
workspace and product knowledge are read-only, network remains unavailable, and
the review contract never requires capability escalation.

Sprint-goal generation is a bounded title-only writing turn rather than a normal
business analyst lifecycle turn. It starts a fresh persistent read-only thread with
only the focused goal contract, product name, sprint number, and ordered ticket
titles; it does not append live database schemas, repository guidance, shared team
guidance, or member instructions. The turn uses the selected model's lightest
advertised reasoning effort. Thread start, turn start, and response waiting share
one 15-second wall-clock budget, which activity cannot extend.

Starter-backlog and epic-planning schemas make environment readiness explicit.
The structured result classifies the plan as `sufficient`,
`foundation_required`, or `not_required`; names the proposed or accepted
foundation ticket when required; and classifies every proposal as
`independent`, `establishes`, or `requires`. Decoding rejects an absent
foundation, multiple proposed foundations, a proposed foundation that is not an
implementer-owned Task, and any `requires` ticket without a direct or transitive
dependency path to the named foundation. This validation happens before
suggestions can become reviewable scope. The assessment itself is not a second
persisted delivery model: accepted tickets, their contracts, and their durable
dependency edges remain the execution source of truth.

Starter-backlog and epic-planning threads receive bounded accepted-ticket
contracts and relevant verified product knowledge in their prompt. They are
explicitly prohibited from inspecting repository files or Git history and use
the live database only to refresh mutable context. Other business analyst
refinement threads retain their read-only product boundary. None scan unrelated
host installations or pre-authorise runtime paths.
Ticket refinement can attach an existing foundation dependency; when no
sufficient foundation ticket exists, it returns a separate foundation split
recommendation rather than silently expanding the feature contract. Its
structured result also recommends the future delivery role. Once refinement is
complete, the application uses the same ticket-owner routing policy as accepted
epic proposals to fill an unassigned ticket and its saved draft-sprint item,
while preserving any existing product owner assignment.

Developer instructions are composed from focused lifecycle guidance rather than
one universal delivery prompt. Conversation, planning, authorised research,
product-changing delivery, recovery, and independent review each receive only
their relevant operating contract. Research delivery explicitly treats historical
delivery notes as analogous context rather than executable instructions and uses
text-native documentation checks where sufficient; implementation-only runtime,
service, and interactive-demo guidance is reserved for product-changing delivery.
The app then appends internal role guidance, shared product owner guidance, and
the selected member's optional custom instructions in that order. The custom
field starts empty and remains an owner-controlled overlay, so the product owner
can redirect an agent's approach without making safety and lifecycle rules UI
configuration.

Team settings are saved through one SQLite transaction covering shared product
guidance and the complete active profile set. The command returns the committed
product-and-profile snapshot; presentation remains open and editable on failure
instead of dismissing before persistence completes.

Delivery selects the named `spedito-delivery` profile: Codex's minimal
platform/runtime reads, read-only system typeface directories
(`/System/Library/Fonts` and `/Library/Fonts`), one writable ticket worktree,
exact read-only access to the active product's Git metadata, credential and
other-product exclusions, and no network. The typeface grant exists because the
minimal read set leaves CoreText without fonts, so `sips`, `qlmanage`, and
CoreText rendered every PDF or PNG a team member checked with blank text;
designers responded by shipping hand-drawn pixel glyphs. The real-sandbox
contract test proves that standard-font text rasterises under both managed
profiles. No agent profile grants the `.spedito` control directory. That
directory holds only `product.sqlite` and its journal files, so granting it is
granting the live database; `Product Workspaces` is denied outright and the
active product's `.git` directory is re-granted as a more specific read, the way
the repository-analysis profile re-grants its snapshot beneath `":root"="deny"`.
Naming database files rather than directories is what previously left the real
per-product databases uncovered while denying a `spedito.sqlite` path that no
longer exists. The profile deliberately does not deny the ticket worktree's
Spedito ancestor under `Run Worktrees`: the active macOS sandbox denies metadata
traversal at that ancestor before a more specific runtime workspace root can take
effect. Sibling ticket worktrees remain inaccessible because delivery has no
broad host read grant, and cross-worktree requests stay an approval-policy
concern. Homebrew, compiler, SDK, local service, and other system capabilities
outside the minimal runtime are requested through App Server approvals for the
current turn. Delivery instructions prohibit copying or staging the workspace
under `/tmp` or another root as a permission workaround. Each delivery thread
overrides that named profile with read-only access to the exact active product's
central `.git` directory. The assigned worktree remains read/write, but Git
metadata is not writable. Delivery
turns inherit the thread-scoped profile;
they do not reselect the process-wide delivery profile at `turn/start`, because
that would discard the product-specific Git rule. The Spedito-owned App
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
When the App Server sends `item/commandExecution/requestApproval` or
`item/permissions/requestApproval`, the adapter preserves the bidirectional JSON-RPC
request for application policy and, when genuinely additional access remains, product
owner review. A native `item/fileChange/requestApproval` does not contain the exact
structured filesystem scope required for an informed decision. The Core adapter
therefore returns `decline` before publishing that request to application subscribers;
it cannot create a pending permission record or project **Needs your input**.
Spedito enables and capability-checks the selected runtime's
`request_permissions_tool`; it does not discover package managers, resolve
project runtimes, or add runtime paths automatically. Delivery guidance tells
the assigned agent to use workspace-relative paths for repository file edits and never
repeat the generated absolute worktree prefix in a patch target. If authorised work
requires an external file change, the agent first requests the smallest exact write
path through `request_permissions`, explains the ticket purpose, and retries the edit
only after the capability is granted. The same guidance tells the agent to diagnose an
`operation not permitted` or `permission denied` result with non-mutating executable,
symlink-chain, and runtime-dependency inspection. The agent establishes the foreseeable
boundary first and submits one batched request for the smallest coherent filesystem or
network capability rather than discovering an executable, its parent directories,
symlink targets, and shared libraries through sequential product owner approvals. For
a Homebrew runtime, that may be one read request for `/opt/homebrew/bin`,
`/opt/homebrew/opt`, and `/opt/homebrew/Cellar`; package-manager data, configuration,
credentials, and unrelated user locations remain excluded. The agent then retries the
original command without adding shell wrappers. An identical sandbox failure after
command approval is treated as evidence that a different capability is missing, not as
a reason to repeat the same approval. Recovery prompts label prior permission details
as audit display only: the agent never pastes a displayed command back into the command
tool, omits explicit `sh -c`, `bash -lc`, and `zsh -lc` launchers, and replaces an
interrupted leaf permission with one consolidated runtime request instead of continuing
a path-by-path cascade. It first consults verified Environments guidance, then prefers
the repository's established native build system and shortest maintained,
purpose-named entry point over a shell chain. When a recurring coherent workflow has
no suitable entry point, an implementer may add a version-controlled, non-interactive,
workspace-relative task or script as normal product tooling; it must not substitute an
unrelated package manager or runtime, conceal operations, or exist only to obtain
broader approval. A service entry point remains in the foreground, accepts the
app-supplied port, and exposes typed readiness. Verified changes produce a complete
Environments proposal describing the commands, working directory, prerequisites,
readiness, required capabilities, and limitations. Read-only reviewers inspect the
declared entry point and reported evidence but do not invoke it or create a replacement.
If the permissions tool is unavailable or a safe coherent capability cannot be
established within the current boundary, a delivery agent fails closed with the
diagnostic and required access instead of silently substituting older verification
evidence.
The permission work log card presents the agent's plain-language purpose first
and places the unchanged exact command and additional access in a disclosure.
Persistence retains the unchanged request for audit and same-run decisions, so
this presentation change does not alter one-time approval semantics.
Application coordination maps a routed request's thread and turn to the durable
AgentRun, projects **Needs your input**, and stores the exact scope, rationale,
signature, and decision. **Allow once** accepts only the exact command or grants the
requested capability for the current turn. For command and permission requests,
**Always allow for this product** stores a durable product-scoped grant.
Permission decisions use separate durable intent and delivery-acknowledgement
states. Spedito persists the exact allow or denial before replying to App
Server, fails closed if that write fails, and advances to the acknowledged
state only after the response is delivered. Replayed requests reuse the same
server-request identity and signature. A newly created product grant is rolled
back if response delivery fails, while the request retains enough durable
intent to retry or audit the outcome.

Before projecting a structured permission request to the product owner, the
coordinator compares it with the assigned read/write ticket worktree, the resolved
baseline transient-storage roots, and structured capabilities already active for
that turn. When their union covers
the complete request, Spedito returns the unchanged requested capability without
changing the permission boundary or projecting **Needs your input**. It persists
the exact request with an existing-access status and shows a compact, non-actionable
**Existing access used** work log entry stating that no permissions changed.
An identical existing-access request in the same turn reuses that record rather
than adding repeated work log entries. Coverage is conservative: only canonical
absolute paths at or below the ticket worktree or resolved transient roots, and exact
current-turn capabilities, qualify. Sibling worktrees and traversal paths are never
inferred from workspace access; patterns and network scopes qualify only when an exact
active current-turn capability covers them; malformed rules and capabilities from
expired turns remain outside this automatic path.

When a delivery thread starts or resumes, the permission-profile coordinator calls
macOS for `_CS_DARWIN_USER_TEMP_DIR`, `_CS_DARWIN_USER_CACHE_DIR`, and Foundation's
user-domain caches directory. It canonicalises and de-duplicates the returned paths
(including `/var` to `/private/var` resolution) and adds them as read/write roots to
that thread's delivery profile. The resolved values are process inputs, not SQLite
permission grants, so app restart and ticket recovery rebuild the profile from the
current operating-system values. A managed demo uses a separate profile: Spedito
removes any broad transient root that contains protected PreviewWorktrees, redirects
its standard temporary and cache environment into its assigned preview, and grants
write access to that exact preview workspace. The demo profile does not combine a
parent PreviewWorktrees denial with a child exception because ordinary recursive
directory creation must be able to traverse the existing parent.

The broad Foundation cache root has a more-specific delivery deny for Spedito's
PreviewWorktrees. Structured delivery requests are also checked against canonical
Spedito product, Run, Integration, and Preview workspace roots. Own-ticket descendants
retain their assigned workspace access; overlapping parent, sibling, or managed
execution paths are declined automatically and persisted with a policy-denied status.
They render as a non-actionable **Protected Spedito storage** work log item authored
by Spedito. The lifecycle prompt explains that a delivery agent must not request
those paths, while the demo command profile grants the exact candidate PreviewWorktree.
Before running any candidate recipe, Spedito executes a bounded nested-directory
write check through that same managed command profile. Failure is a host preparation
error that preserves the reviewed candidate for retry; it is not implementation
feedback or a reason to repeat tech lead review.
Command grants retain the exact command and omit the ticket worktree path only
after confirming the requested working directory is inside that run's assigned
workspace. They never use prefix, fuzzy, or semantic command matching. Structured
filesystem and network grants are canonicalized as order-independent capability
sets. Matching accepts an equivalent or narrower structured request when the
union of active product grants covers every requested rule; write does not imply
read, restricted network scopes match exactly unless unrestricted network consent
exists, and malformed or unknown structures fail back to exact matching. This
allows one coherent runtime request to reuse earlier path and network consent
without turning it into a binary-only or connection-wide App Server rule.

Delivery developer instructions enumerate the product's effective saved
structured consent while stating that consent is not active sandbox access and
does not expand ticket scope. The assigned agent therefore knows which capability
can be requested rather than rediscovering it through repeated failures. Matching
future requests receive a turn-scoped approval and are recorded in the receiving
ticket's work log. Product settings present overlapping structured grants as one
effective access group and revoke its underlying rows atomically; exact commands
remain separate. Revoked rows remain available for audit. File-change approvals
cannot be persisted. **Deny** declines without cancelling the turn so the agent
can adapt. The turn timeout does not advance while a supported permission request
is outstanding. Spedito may also transparently reapply an identical
recorded decision within the same durable AgentRun. If the app
restarts, a pending connection-scoped request becomes interrupted and the
run remains in **Needs your input** rather than being admitted by the scheduler.
The product owner can still Allow or Deny the durable interrupted request. That
decision queues the preserved run, and a matching request from its resumed
conversation receives the recorded answer automatically. Saved product grants
remain durable.

Every application-owned AgentRun update passes through one coordination boundary.
After the durable write succeeds, a transition from any other status to
`awaiting_owner` plays the bundled ticket-attention sound once. Rewriting or
reloading an already-waiting status stays silent, background-product transitions
use the same path, and shutdown suppresses new playback. Audio failure never
changes the durable attention state.

The application also derives a cross-product attention projection from
`awaiting_owner` AgentRuns and `acceptance` work items in every active product
store. Waiting runs are deduplicated by work item and ordered by the latest run
update; `acceptance` adds any ticket that is **Ready for demo** and is not already
represented by a waiting run. The projection joins the product and work item
with the latest structured owner question, pending permission request summary,
or ready-for-demo state. Startup reloads the projection from SQLite; transitions
into or out of `awaiting_owner`, background product refreshes, and product
switching refresh the affected product so attention counts remain durable rather
than behaving like unread notifications. The cross-product product-switcher and
product-library counts union these owner-action targets with active
owner-notification targets from non-selected products, counting each source
once. The product-switcher capsule uses the app accent color; product-library
attention uses orange when an unresolved action is present and purple for unread
updates alone. Attention within the selected product remains on its workspace
destination.

A newly waiting run publishes one transient in-app presentation containing its
product, ticket, and summary. It slides in from the bottom-right edge. Its action
selects the owning product only after the product owner chooses it, then opens
the ticket. Product-library navigation opens a single attention ticket directly
or publishes a multi-ticket sprint-board filter.
When the app is inactive, `UNUserNotificationCenter` receives an alert
without an additional sound. Notification metadata contains only notification,
product, target-kind, and target identifiers; the application delegate resolves
the click through the same durable attention projection and navigation path.
Notification denial or
delivery failure never changes ticket state or removes the in-app badge.

Background refinement and conversation results are coordinated by one focused
owner-notification coordinator rather than by individual views or `AppModel`
task registries. Core persists an idempotent notification record keyed by the
durable source event. Each record names its product, kind, target kind, target
identifier, owner-facing title and body, creation time, read time, and optional
resolution time. The active projection contains unread updates and unresolved
questions; read ordinary updates and resolved questions remain as deduplication
evidence but do not appear in counts.

Ticket comments, epic-planning snapshots, suggestion sessions, and Chat messages
remain the authoritative result data. The notification row is a navigation and
read-state projection only. Result producers insert it only after their
authoritative transaction succeeds. The coordinator presents a newly inserted
record once, suppresses an in-app banner when the exact target is visible,
posts a macOS notification only while the app is inactive, and removes delivered
or pending system notifications when their record is read or resolved. Startup
loads the bounded active projection without replaying transient presentation.

Navigation metadata contains only the notification, product, target kind, and
target identifiers. Application routing resolves those identifiers against the
current product store before opening a ticket, epic, or Chat thread. Missing or
archived targets fail closed. Ticket and epic detail views and the selected Chat
thread publish a bounded visibility snapshot; they do not own notification
lifecycle state.

The same adapter owns buffered and streaming `command/exec`, output deltas, and
termination for candidate demos. The durable run stores the thread identifier
and workspace path so an owner answer or review finding can resume the same
implementation context. It also reads `model/list`; the UI uses each returned
model's advertised effort options instead of maintaining a speculative catalog.
For structured delivery turns, `item/completed` supplies a candidate final-answer
payload but does not close the waiter. Spedito retains that payload until
the matching `turn/completed` notification or reconciled durable terminal state,
then validates it and may start a repair turn. This prevents a repair submission
from overlapping the turn whose response it is repairing.
Product chat turns consume the same supported Codex activity events as
sprint board runs, but keep that transient projection keyed by conversation
thread rather than creating a delivery AgentRun. The bottom conversation status
strip shows concise reasoning summaries, planning steps, and local inspection
activity; it never exposes raw chain-of-thought. A new conversation concurrently
starts a 15-second, ephemeral read-only title turn using the selected model's
lightest supported reasoning effort. That isolated turn is instructed to use
only the first owner message, not inspect product evidence, and return a
structured four-to-six-word title. Its compare-and-set persistence update
replaces only the original provisional subject, does not change the thread's
last-activity time, and fails independently of the main conversation turn. The
durable conversation turn returns a plain Markdown answer without a title
schema. Same-member
follow-ups resume the stored Codex thread without regenerating the title.
Product selection changes replace only the loaded presentation. Active product
Chat responses, ticket and epic conversation turns, ticket refinement, and epic
clarification or plan generation remain keyed by their owning product and source.
Returning to a product reconstructs its visible state from the runtime or durable
store, and the eventual result reloads the selected projection. Epic plan
generation reloads tickets, profiles, prior suggestions, conversation messages,
and verified knowledge from the owning product store rather than from the
currently selected product. Only explicit product archival or application
shutdown cancels these turns.
When the owner selects another member, the persistence write atomically changes
the current recipient and clears the former role-specific Codex identifier; the
new member starts a fresh read-only session whose prompt contains the durable
visible Chat transcript and whose tools can re-query current product evidence.
Stable agent-facing views are the preferred compatibility contract, not an
artificial limit on that product-scoped read access. When an operational question
requires evidence outside those views, product chat may inspect the read-only
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
Spedito therefore supplies its definitions as process-local config
overrides, enables the matching experimental capability explicitly, and covers
the supported protocol behavior with adapter and local runtime contract tests. It never
falls back to full access or the retired custom Seatbelt allow-list.

Unknown versions are allowed to attempt the capability handshake. Missing
required behavior fails closed with an owner-facing recovery path.

### 7.1 ACP feasibility and parity boundary

As of August 4, 2026, stable Agent Client Protocol (ACP) v1 can support a
product-wide agent boundary, but it cannot by itself guarantee exact feature
parity across arbitrary ACP agents.

| Goal | Verdict | Boundary |
| --- | --- | --- |
| Put every Spedito lifecycle behind one provider-neutral internal interface | **Yes** | Keep one Spedito-owned backend contract with direct Codex and ACP implementations. |
| Send every agent interaction over ACP, including Codex | **Technically yes** | The current Codex ACP adapter starts Codex App Server underneath, so this adds a translation process rather than removing the Codex dependency. |
| Preserve product chat, refinement, planning, implementation, review, recovery, and demo behavior for selected non-Codex agents | **Yes, conditionally** | Spedito must own the durable run and transcript, structured-result validation and repair, worktree and candidate lifecycle, process sandbox, approval policy, crash recovery, and demo process. Each agent must pass a lifecycle-specific capability and isolation conformance suite. |
| Preserve identical context, compaction, detailed token, cost, and shared-account quota metrics across providers | **No, not from stable ACP v1** | ACP standardizes optional current-context usage and optional cumulative cost. Detailed turn token categories, compaction events, and account quotas require provider-specific extensions or APIs. Missing values remain **Unavailable**. |
| Let any ACP-compatible agent perform every Spedito lifecycle | **No** | ACP capabilities are optional, and protocol compliance does not prove Spedito's sandbox boundary. An agent that cannot satisfy a lifecycle contract is limited to eligible work or rejected. |
| Remove all provider-specific code while keeping exact Codex behavior | **No** | Codex rate limits, compaction, structured-output enforcement, and exact permission semantics are outside portable ACP v1 unless an equivalent extension is available. |

The portable ACP v1 surface includes initialization and authentication
negotiation; session creation with optional load and resume; prompts,
streamed messages, plans, tool calls, stop reasons, and cancellation;
session-scoped model and reasoning configuration; permission-choice
interaction; and optional `usage_update` values for current context
`used`/`size` tokens and cumulative cost.

ACP v1 does not standardize Codex-equivalent `outputSchema`, detailed
per-turn input/output/reasoning/cache token accounting, context-compaction
events, provider account quotas, or Spedito's exact structured filesystem
and network capability rules. Generic `session/request_permission` choices
provide a review interaction but not an isolation proof. Spedito therefore
preserves governed structured results by validating and repairing the final
message, and admits code-changing delivery only when it owns or independently
proves the agent process boundary.

Spedito remains the authoritative local control plane for AgentRuns, Work
logs, tickets, scheduler leases, permission decisions, worktrees, candidate
hashes, and recovery. An ACP session identifier is an opaque continuation
handle. If an agent cannot load or resume it, Spedito reconstructs a new
session from the durable transcript or completion handoff rather than
claiming native thread durability.

ACP is agent-agnostic, not a raw model-provider gateway. A selected ACP agent
may expose OpenAI, Anthropic, Google, or local models through its own session
configuration; otherwise model routing would require a separate agent that
owns provider APIs, tools, context, compaction, and safety. Initial ACP
support remains local JSON-RPC over stdio because the official remote
HTTP/WebSocket transport remains work in progress.

The recommended architecture is a product-wide Spedito backend interface
with the direct Codex App Server backend and stable ACP v1 backend beside
each other. Capability-gate each lifecycle instead of presenting one global
“ACP compatible” switch. Start with a transcript-backed read-only lifecycle,
add governed structured workflows after validation-and-repair parity, and
admit implementation or review only after a real-agent isolation and
recovery suite passes. Managed candidate demos remain on Spedito's host-owned
foreground command path until an ACP backend proves the same ownership and
teardown guarantees.

ACP v2 was published as a draft on July 20, 2026 and must not ship by
default. Re-evaluate it after stabilization while retaining v1 compatibility.

Primary references: [ACP introduction](https://agentclientprotocol.com/get-started/introduction),
[initialization](https://agentclientprotocol.com/protocol/v1/initialization),
[session setup](https://agentclientprotocol.com/protocol/v1/session-setup),
[prompt turns](https://agentclientprotocol.com/protocol/v1/prompt-turn),
[tool calls and permissions](https://agentclientprotocol.com/protocol/v1/tool-calls),
[session configuration](https://agentclientprotocol.com/protocol/v1/session-config-options),
[stable session usage](https://agentclientprotocol.com/rfds/session-usage),
[draft end-turn token accounting](https://agentclientprotocol.com/rfds/end-turn-token-usage),
[ACP v2 draft status](https://agentclientprotocol.com/announcements/acp-v2-draft),
[Buzz architecture](https://github.com/block/buzz/blob/main/ARCHITECTURE.md),
[Buzz agent design](https://github.com/block/buzz/blob/main/VISION_AGENT.md),
and the current [Codex ACP adapter](https://github.com/agentclientprotocol/codex-acp).

## 8. Recovery model

Durable writes occur before a UI projection announces a state. On launch the
application reconciles scheduler leases, child processes, Codex threads,
worktrees, candidate commits, and preview processes. A normal quit requests a
structured checkpoint, interrupts after a bounded grace period, and preserves
the run as paused. Crash recovery creates a system note from durable events and
filesystem state when no agent-authored checkpoint exists.

Candidate-delivery recovery commits one SQLite transaction for every related
candidate status, AgentRun status and event, ticket transition and event,
permission-request status, and work-log comment. Each mutation carries its
expected durable state. A retry may observe either the complete prior result or
the complete old state; it cannot admit a second run or expose a partial
transition. File-system cleanup happens before that transaction and a cleanup
failure leaves durable authority unchanged.

Recovery error handling has three explicit classes:

- **Owner-visible failure:** every authoritative SQLite read or write, remote
  product-store lookup, and GitHub authorization-state write is propagated or
  projected into the product-scoped failure state. Remote state reads never
  turn a database error into an empty disconnected state.
- **Diagnostic-only probe:** attempting to resume a prior Codex thread and read
  its last completed structured response may fail without becoming the recovery
  result. Recovery then follows the normal interrupted-run path using SQLite and
  the preserved workspace. A failed optional history-alignment proof remains a
  conservative `diverged` observation and never enables synchronization.
- **Benign cleanup:** deleting Spedito-owned temporary credential directories,
  closing credential-cache processes, and deleting stale managed observation
  refs may be best effort after durable state is already safe. These failures
  cannot advance a ticket, candidate, permission, synchronization, or
  publication and are retried by later cleanup or made harmless by
  create-or-replace ref semantics.

Delivery-capacity waits are durable `AgentRun` state, not scheduler cache
authority. A queued run may store a typed execution constraint
(`account_rate_limit` or `safety_backpressure`), the observation time, an
optional retry time, and bounded technical evidence. The coordinator derives
one current capacity policy from the latest Codex observation plus these
durable waits. A fresh available observation clears the constraint before
admission; an absent or stale observation preserves it. The runtime coordinator
then starts at most one child operation for the run identity.

| State | Entered by | Durable evidence | Owner sees | Available actions | Recovery |
| --- | --- | --- | --- | --- | --- |
| Queued for capacity | Current Codex limits or safety back-pressure block an otherwise eligible implementation | `AgentRun.status = queued` plus typed constraint, observation time, optional retry time, and bounded evidence in SQLite | **Waiting for Codex capacity** or **Waiting for safe capacity**, an automatic-recovery explanation, and retry time/evidence when available | Stop or pause the Sprint through the existing delivery controls; no manual retry is required | A fresh coordinator preserves the wait while observations are unavailable or stale, clears it only from current available capacity, and admits one operation |

Implementation recovery is run-bound. App shutdown requeues the existing
implementation AgentRun while preserving its ticket worktree and non-ephemeral
conversation, except when a live permission decision was outstanding; that run
remains awaiting the product owner. A product owner stop also leaves the run
interrupted until they resume it. On restart Spedito explicitly calls App
Server `thread/resume` to load the persisted conversation into the new server
process, then first recovers a valid completed structured result when one exists.
Otherwise it starts a focused continuation turn, telling the team member to use
the current workspace and prior context rather than restart the ticket or repeat
completed work and checks. A live approval request cannot survive the old App
Server connection, so its durable interrupted record remains an actionable
**Needs your input** item. Allow or Deny stores the scoped decision and only then
queues the run; if the resumed agent still needs the matching capability,
Spedito applies that decision automatically. A missing conversation is
established only when `thread/resume` reports it unavailable; the replacement
receives the full ticket contract plus an explicit preserved-workspace
continuation instruction.
If the recorded ticket worktree is missing, Spedito does not claim that
its uncaptured changes were preserved: it records the loss in the work log and
prepares a fresh isolated ticket workspace.

An `awaiting_owner` delivery result is run-bound rather than candidate-bound. It
stores its question, options, and optional decision-artifact title and
workspace-relative path in the ticket comment. The artifact path must resolve
inside the preserved ticket workspace, exist as a changed file, and is opened
directly from the work log. The result must not contain product knowledge or
follow-up proposals or a demo. Those records require a completed immutable
candidate revision and are produced only after the same run resumes with the
product owner's answer.

Review recovery is candidate-bound. A tech lead turn interrupted by shutdown
retains its review run, non-ephemeral conversation, detached path, and reviewed
candidate identifier. For repository-changing work, restart verifies or
reconstructs the detached checkout at the exact reviewed SHA. For a local outcome,
restart reloads the immutable execution result and candidate-bound knowledge
proposals from SQLite; its unchanged base SHA remains only an isolation and
workspace-recovery anchor. Spedito then recovers a valid completed structured
review result or starts a continuation turn after explicitly resuming the same
conversation. Review uses `approvalPolicy: never`; an expired request created by
an older review contract is retired and the run is queued to continue within the
evidence-only boundary. A missing conversation starts a replacement review only
after `thread/resume` fails. A missing, mutated, or unverifiable checkout returns
a repository-changing candidate to review. An unverifiable post-conflict
integrated revision returns it to integration and focused re-review, with an
explicit work log explanation. A candidate already in **Ready for demo** keeps its
reviewed revision; only its owned demo process is stopped and restarted.
Product switching is not an execution suspension boundary. The application owns
one product-scoped scheduler task per active sprint, and each scheduler reloads
its own product, plan, tickets, profiles, permission records, and knowledge from
the durable store. The selected product controls only the published UI
projection. Background implementer, integrator, and tech lead turns therefore
continue without interruption, while their telemetry, permission cards, demo
preparation, and refreshes remain product-scoped. Product archival suspends only
the archived product; app shutdown suspends every product.

Sprint pause is a durable execution boundary rather than a UI-only flag. The
store changes the sprint from `active` to `paused` before the application
interrupts its product-scoped scheduler and active turns. Cancellation recovery
queues preserved implementation work against the same run, conversation, and
ticket workspace, while permission decisions remain owner-controlled. Resume
atomically restores `active` before waking the scheduler. A paused sprint counts
as the product's in-progress sprint and prevents a later draft from starting.

Stopping a sprint first reaches the same suspension boundary, then atomically
marks the sprint `cancelled`, cancels non-terminal runs, supersedes unaccepted
candidates and unpublished knowledge proposals, and returns unfinished tickets
to `ready`. Released tickets and accepted candidates are immutable. Audit rows,
work logs, conversations, and workspace references are retained; no stopped
candidate is promoted to trunk.

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

Product chat instructions alone provide the exact active product database path
and exact column schemas for stable read-only views covering tickets,
dependencies, work logs, epics, sprints, verified knowledge, decisions,
provenance, retrospectives, and team members. This includes the durable ticket
key as `item_key`. Chat re-queries mutable facts before consequential
conclusions so a long-running conversation does not mistake an old read for
current state. Every other agent workflow receives bounded prompt context of
ticket contracts and selected verified knowledge, plus product Git history
where its contract allows repository inspection. Their instructions do not
name the Spedito database: it sits outside the delivery sandbox, so an
invitation to read it can only surface as an owner permission request for
Spedito's own control plane.

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

Overview, product principles, Glossary, Ways of working, and Environments form
the central mandatory-page policy. Every product is idempotently backfilled with
the Operations section and Environments page, but an empty page remains only a
destination. Non-empty verified mandatory pages are supplied to implementation,
tech lead, integrator, and other product agent instructions. Delivery context
records combine these pages with bounded ticket-relevant selection, and the Work
log presents the two groups separately.

Environments is always an authorised update destination for an implementation
run so an agent can propose a complete replacement after verifying operational
guidance is absent or stale. It remains read-only to tech lead and integrator
runs. Tech lead approval uses the existing candidate-bound knowledge proposal
path. For repository-changing delivery, reviewed Markdown may also be
materialized in the integrated candidate. Local outcomes keep the proposal only
in SQLite. Ticket acceptance publishes either kind into canonical product knowledge.
The stricter product owner approval feature flag still adds an explicit per-proposal decision
before ticket acceptance. Stable repository entry points improve exact saved-product
permission matching without converting knowledge into a grant.

An environment-foundation ticket uses that same reviewed knowledge path. Its
delivery contract verifies the approved toolchain and versions, stable
repository-owned build/test/local-run/demo entry points, run-private temporary
and cache locations, required capabilities, a managed readiness check, and
known limitations, then proposes the complete Environments replacement.
Downstream tickets receive the accepted foundation's concise work log handoff
and verified Environments page through the normal direct-prerequisite context
rules. Production credentials, signing identities, and release authority are
not implied by local environment readiness.

## 10. Implementation and distribution boundary

The repository implements the local control plane, owner-facing planning and
delivery workflow, Codex App Server adapter, isolated ticket workspaces,
candidate review and integration, managed local demos, recovery, product
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
