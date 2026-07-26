# StoryPointless

StoryPointless is a working concept for a local-first, macOS-native AI product
delivery system. A product owner defines outcomes, assembles a team of coding
agents, controls cost and risk, and moves work from backlog to verified release
through an agile workflow without installing developer tools or using a terminal.

The project now has an initial native implementation foundation: a SwiftUI macOS
executable, a dependency-free SQLite control plane, guarded ticket workflow,
role-aware AI team, comments, and a durable activity timeline. The app discovers
an exact compatible Codex runtime, performs the hidden App Server handshake, and
shows its real connection state. **Autosuggest Tickets** runs one read-only,
schema-constrained Business Analyst turn and can produce a coherent set of up
to 24 analysis, UX, and implementation proposals. Roles are recommended future
owners and may repeat; they are not separate suggestion agents or quotas.
Proposals are classified as Story, Task, or Bug and appear as a vertically
staggered dependency outline above the backlog; suggestions remain outside
backlog scope until the owner accepts them. The backlog itself is now a compact,
ranked list split into **Next sprint** and **Backlog** sections. Entire ticket
rows can be dragged between them, and top/bottom ranking actions reject
dependency-invalid orders. Full-width separators reinforce the shared column
layout. Explicit row selection, section-wide select-all, bulk actions, and
grouped drag/drop move several tickets between Backlog and Next sprint in one
dependency-safe plan update. Any row opens a full editor for type, priority, context, acceptance
criteria, flexible custom fields, dependency context, and a durable ticket-level
conversation addressed to one selected team member at a time; there is no implicit
team-wide broadcast. Owners can add or remove blockers while creating or editing manual
tickets; cycles are rejected, prerequisites are re-ranked automatically, and
unfinished blockers outside the sprint prevent it from starting. Suggested work
uses aligned cards with explicit **Blocked by** and **Blocks** relationships rather
than tree indentation. Sprint Planning now places an editable ticket beside its durable
conversation. The owner chooses exactly one team member for each message; that member
runs one real read-only, schema-constrained turn using its configured model, effort, and
instructions. It can reply normally or propose a business-readable ticket change. A
proposal can be accepted or rejected, but acceptance is disabled if the owner or another
process changed the exact ticket snapshot the agent saw. Hung turns are interrupted after
a bounded wait instead of leaving an endless spinner. Scoped tickets can be reviewed
ticket by ticket and assigned in a persisted sprint plan. **Start Sprint** validates
readiness, freezes the approved contracts, creates recoverable internal execution
records, and starts every dependency-free delivery run. Each assigned member works
through a hidden, workspace-write Codex thread on an isolated `ticket/TN` Git branch
and worktree. Material progress, checks, delivery
notes, questions, failures, permission requests, run context, candidate revisions,
knowledge changes, follow-up recommendations, and demo submissions are shown in
chronological order in the ticket Work log with attribution.
An agent that needs a Product Owner choice enters a durable attention state; its
structured options are selectable in the Work log, with a free-form response still
available, and the submitted owner response queues the same thread to resume. Delivery
and Tech Lead runs use App Server approval requests rather than treating every sandbox
boundary as a failure. The ticket shows the exact command or capability with
**Allow once**, **Always allow for this product**, and **Deny** actions where applicable.
One-time decisions apply to the current agent run; saved product access can be
reviewed and revoked in Product settings. Every decision remains auditable after
relaunch. The delivery profile grants the exact
ticket worktree plus Codex's minimal macOS runtime paths; it does not deny a parent
directory that the worktree must traverse. Extra Homebrew, SDK, service, or other
system access therefore becomes a scoped Product Owner permission request instead of
a failed workspace write or an agent-created `/tmp` copy. StoryPointless enables and
checks Codex's explicit permission-request tool rather than discovering or whitelisting
package managers and runtime installations itself. Agents diagnose blocked executables,
request the narrowest exact filesystem or network capability, and do not repeat an
ineffective command approval or add shell wrappers. Agents are explicitly
forbidden from copying a ticket workspace elsewhere to bypass that decision. They
receive read-only access to the active product's central Git metadata, so status,
diff, history, and conflict inspection do not need Product Owner approval. Their
App Server process disables optional Git locks, ignores the user's global Git
configuration, and uses a noninteractive pager. The assigned worktree remains
writable, while StoryPointless alone owns Git mutations such as staging, commits,
branches, integration, and promotion.
Completed implementation becomes a
versioned candidate with a host-created commit and exact head SHA.
StoryPointless places it in a rank-ordered serial integration queue and merges it
against current `trunk` in a detached integration worktree. Unambiguous conflicts are
handled by an internal Integrator turn in that preserved worktree; material choices
pause as **Needs your input** without inventing a new board state. The exact integrated
revision is then inspected by a separate read-only Tech Lead run. Approval moves the
ticket to **Ready for Demo** only after its typed demo recipe successfully smoke-tests
the exact integrated revision. The ticket acceptance room then provides one **Demo**
button. StoryPointless prepares a detached preview checkout, starts a sandboxed local
service through the same pinned Codex App Server runtime and opens its loopback browser URL, launches a reviewed macOS app, opens a
review artifact, or captures a bounded scenario result according to that reviewed
recipe. Repeated web and app demo clicks reuse a healthy process. **Stop demo**,
Product Owner feedback, approval, product switching, and app shutdown terminate the
managed App Server command session; approval and feedback also remove the preview checkout.
If the Tech Lead has approved the candidate but demo smoke preparation stops, the ticket
offers **Retry demo preparation** immediately. The retry reuses the exact reviewed SHA and
does not require a comment, repeat implementation, or another Tech Lead review.
Requested changes return it to **In Progress** and resume the original implementation
thread with the review comment. In Ready for Demo, a comment receives an explanatory
reply without changing the reviewed candidate. It routes to the assigned Implementer,
falling back to the latest participating team member and then the Tech Lead.
Owner demo feedback follows the same revision loop,
while **Approve and complete** promotes the reviewed integrated SHA to local `trunk`,
moves the ticket to Done, and admits newly unblocked work. Interrupted runs are
recovered from their durable records and preserved workspace on the next launch.
An **In Progress** implementation paused by app shutdown is requeued automatically
unless it was waiting on a permission decision. Ordinary work explicitly resumes
the persisted Conversation and continues in the same ticket workspace with a focused
recovery instruction; it does not receive the original “start the ticket” briefing again.
Any completed structured result is recovered before another implementation turn is
started. A Product Owner stop remains paused until they explicitly resume it.
An expired permission request remains visibly actionable and keeps its implementation,
Tech Lead review, or conflict-resolution run paused after relaunch. Once the Product
Owner chooses Allow or Deny, StoryPointless explicitly resumes the persisted Conversation
and applies that decision if the same request is still needed. Tech Lead recovery remains
bound to the same integrated SHA; StoryPointless reconstructs that exact detached checkout
when needed and repeats integration or full review only when the recorded revision cannot
be verified. If an In Progress ticket workspace itself is missing, StoryPointless explains
that uncaptured implementation work could not be recovered before preparing a fresh
isolated workspace. Backlog and refinement are separate from the simplified
active sprint board, whose owner-facing stages are In Progress, In Review, Ready for
Demo, and Done.
Each team profile has a role-specific default prompt and sensible model/effort
policy. The sidebar exposes live account-supported model and effort selectors,
while Team Settings provides shared product guidance without making safety or
workflow policy editable. It exposes model, reasoning effort, and an always-editable appended
prompt for every built-in or custom team member; resetting instructions to the role
default does not require a separate customise mode. Pending ticket suggestions
must be accepted or rejected before another gap analysis can begin. Later runs
receive the accepted backlog and the previous rejected proposals to avoid
quietly resurfacing reviewed work. Once every proposal is reviewed, the
suggested-work panel disappears while those decisions remain durable context.
Team controls use aligned compact selectors, while Codex connectivity lives in
a workspace status bar rather than appearing as a teammate. Backlog actions are
owned by the relevant section instead of the macOS title bar, and the full
list-first backlog page scrolls vertically. Creation and
configuration sheets use explicit left-aligned labels, bordered text fields,
and multiline editors rather than macOS Form value rows.
The Team sidebar is configuration only: it shows reusable members, capabilities,
models, effort, and instructions without pretending those profiles are idle or
online. Live agent-run counts, assignment, state, and current context health live
with their tickets on the Sprint Board.
The starter team is Business Analyst, UX Designer, Tech Lead, and Implementer. The
Tech Lead performs normal delivery review; specialist frontend, backend, security,
and other team members are optional additions rather than permanent headcount.
The current product header opens a searchable, launcher-style product library
with scrollable descriptions, current-workspace state, double-click/open, and
new-product creation. Each product loads its own backlog, team, sprints, and
knowledge, and the most recently opened product is restored on restart. When
multiple products exist without a valid remembered selection, the library is
shown automatically once rather than interrupting every launch.
Product Context keeps the potentially long product description out of the
sidebar while allowing the owner to review and edit what future agents receive.
Manual ticket creation also requires the same simple Story/Task/Bug choice.
Backlog tickets are archived rather than physically deleted so comments and
audit history survive; unresolved dependents must be unlinked first.
Backlog rows show the persisted draft delivery assignment inline, or explicitly
show Unassigned. Moving a ticket into Next sprint changes scope only and never
silently chooses a team member. Every ticket in Next sprint is already in scope;
the owner returns unwanted work to Backlog rather than excluding it again inside
Sprint Planning. Sprint Planning keeps edits local until the owner saves, with
**Save draft & close** available mid-review and **Discard changes** retaining the
last saved plan. Ordinary Tech Lead review is an execution-stage system run rather
than a second per-ticket planning picker.
Epics are optional backlog groups rather than executable ticket types. The Backlog
keeps open epics prominent while completed epics collapse into a remembered inline
summary that expands within the same table.
An **Improve** sidebar section now separates sprint Retrospectives from
longitudinal Reports. Both are evidence-first: the UI shows current operational
counts but withholds trend claims until comparable completed sprints exist.
Custom team-member creation is currently hidden from Team settings while that
workflow is deferred. Existing custom team members remain configurable and are
archived rather than destructively deleted.

The execution path now admits every dependency-free ticket in parallel. Implementation
is isolated in ticket-named Git worktrees, concurrent Codex notifications are routed
to the correct run, and candidate revisions preserve the agent's full commit range.
Candidates integrate serially against current local `trunk`; the Integrator resolves
safe conflicts in the detached merge workspace and the Tech Lead reviews the exact
resulting SHA. Product Owner approval alone promotes that reviewed revision. One
candidate reaches Ready for Demo at a time so acceptance remains an explicit trunk
gate. Release automation, streamed fine-grained progress, and agent-authored quit
checkpoints remain to be implemented.
Completed agents must now provide concrete Product Owner review instructions and a
schema-versioned one-click demo recipe. Recipes use executable and argument arrays
rather than shell command strings, remain inside the reviewed preview checkout, expose
only loopback web URLs, use allocated ports, and run with external network and
unrelated-file access denied. A candidate cannot reach Ready for Demo until its recipe
passes structural, workspace, launch, and readiness validation.
The managed demo profile deliberately reads ordinary system and Homebrew runtime files
without enumerating individual binaries or library configuration paths. It can write
only the reviewed preview and its temporary data, can reach only localhost, and denies
credentials, `.env` files, other product workspaces, and StoryPointless's control-plane
data. This avoids toolchain-path failures such as Node loading Homebrew OpenSSL while
keeping exceptional access explicit.
They also create a proposed per-ticket delivery note; Tech Lead approval verifies it
before it is used as current knowledge. Agents may propose complete updates or new
pages for the canonical wiki. The Tech Lead reviews those proposals with the exact
candidate, after which StoryPointless publishes them automatically and commits the
Markdown into the integrated revision. The ticket keeps the full proposal, rationale,
status, and page history visible. Set
`STORYPOINTLESS_REQUIRE_KNOWLEDGE_APPROVAL=1` when launching the development app to
restore the stricter per-proposal Product Owner accept/reject gate. Material unstated
Product Owner decisions must still pause the ticket and cannot be smuggled through a
knowledge proposal. The Knowledge view provides a seeded page
tree, Markdown editing, search, breadcrumbs, contents, backlinks, version history,
provenance metadata, and citation-backed **Ask Knowledge** over verified pages only.

An approved Business Analyst research ticket normally hands its decision to already
planned dependant tickets through its completion Work log and verified Product
knowledge. It may publish fully formed follow-up ticket proposals only for genuinely
new work that is absent from the active Backlog. Those exceptional proposals appear
as a labelled suggestion batch, inherit the source epic and research dependency when
accepted, and remain outside committed scope until the Product Owner reviews them.
Bounded verified pages are selected for future execution prompts rather than sending
the whole wiki. Normal app termination interrupts the active turn, persists the
interruption, preserves its Conversation and workspace, and queues ordinary implementation
to continue on the next launch. A live permission request expires with the old process,
remains paused for an explicit owner decision, and resumes only after that decision.

Execution and Tech Lead results also record at most two concrete observations in
each retrospective category. The Retrospectives view presents these as attributed,
ticket-linked evidence for **Went well** and **Could improve**, plus a reviewable
decision queue. After a sprint completes and before its retrospective is concluded,
the Product Owner can add their own attributed proposal for **Ways of working** or a
**Backlog ticket** alongside the agents’ suggestions. Accepting a ways-of-working
proposal updates inherited team guidance; accepting a ticket creates it in the
Backlog and opens the normal automatic Business Analyst refinement flow. Concluded
retrospectives retain a read-only list of the accepted decisions rather than
collapsing them into an empty decision state.

AI ticket suggestions now appear as compact purple rows inside the ranked Backlog
rather than as a separate card gallery. Connected dependency paths can be accepted
or rejected as a group. Accepting a dependent ticket names and atomically accepts
its still-proposed transitive prerequisites. Rejecting a prerequisite previews the
transitive cascade; confirmation rejects its remaining dependent proposals and
archives dependent tickets already accepted into the backlog. Harmless reference formatting is
normalized, a malformed dependency graph receives one automatic Business Analyst
repair attempt, and a persisted failure can always be retried or dismissed. A
missing-work proposal may also depend on an existing active backlog ticket;
accepting it creates the real cross-batch ordering constraint rather than reducing
it to explanatory prose. If StoryPointless relaunches during epic ticket
generation, it automatically recovers the completed structured result or retries
once from the saved Business Analyst Conversation. Pulsing ticket placeholders
remain visible in both the Backlog and epic ticket list while recovery runs;
ordinary generation failures remain owner-controlled instead of retrying on every
launch.

## Start here

- [Product vision and specification](docs/product-spec.md)
- [Technical design](docs/technical-design.md)

The specification includes the product thesis, competitive boundary, user
journeys, functional requirements, trust model, architecture, MVP scope,
metrics, risks, open decisions, and an initial delivery backlog.

## Development

Requirements for contributors:

- Apple Silicon Mac
- macOS 14 or later
- Xcode 26 or a compatible Swift 6 toolchain

Build and test:

```sh
swift test
```

Run the development executable:

```sh
swift run StoryPointless
```

For subsequent development relaunches, use:

```sh
./scripts/relaunch.sh
```

The development relaunch command intentionally stays simple: it builds, kills
the existing debug process, and launches the verified executable in the
foreground. Do not use it when preserving an active agent turn matters; normal
user-initiated app quit continues to use the app's asynchronous shutdown path.

These developer commands are not part of the customer experience. Debug builds
can use the exact compatible runtime inside the installed Codex app as a
development fixture. The shipped product will be a signed application that
manages its own compatible Codex and Git runtimes without exposing a terminal.
