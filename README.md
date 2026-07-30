# StoryPointless

StoryPointless is a working concept for a local-first, macOS-native AI product
delivery system. A product owner defines outcomes, assembles a team of coding
agents, controls cost and risk, and moves work from backlog to verified release
through an agile workflow without installing developer tools or using a terminal.

The project now has an initial native implementation foundation: a SwiftUI macOS
executable, one dependency-free SQLite control plane per product, guarded ticket workflow,
role-aware AI team, comments, and a durable activity timeline. The app discovers
the installed Codex app or an explicitly selected custom installation, performs
capability and App Server handshakes, and shows its real connection state.
Codex versions remain visible for diagnostics but are not rejected merely for
being newer. **Autosuggest Tickets** runs one read-only,
schema-constrained Business Analyst turn and can produce a coherent set of up
to 24 analysis, UX, and implementation proposals. Roles are recommended future
owners and may repeat; they are not separate suggestion agents or quotas.
Starter-backlog and Epic planning now inspect verified **Environments**
knowledge and repository evidence before treating executable work as ready.
Their structured results classify environment readiness and each ticket's
relationship to it. If a reusable environment is missing, the plan must include
one concrete Implementer foundation task and every ticket that needs to build,
test, run, prototype, or demo the product must depend on it directly or
transitively; contradictory plans fail validation. Business-friendly
clarification resolves material technology or hosting constraints, while
runtime paths, caches, and sandbox plumbing stay out of the non-technical
Product Owner's questions.
Proposals are classified as Story, Task, or Bug and appear as a vertically
staggered dependency outline above the backlog; suggestions remain outside
backlog scope until the owner accepts them. The backlog itself is now a compact,
ranked list split into **Next sprint** and **Backlog** sections. Entire ticket
rows can be dragged between them without changing rank when the destination
does not express a new ordering. Every Epic receives the next durable color in
a contrast-spaced, stable per-product palette; matching left-edge markers connect
its Epic row and tickets across the backlog and Sprint Board. During a drag,
dependency-safe insertion positions are shown in blue and an invalid hovered
position turns red with its constraint. Invalid destination rows are
de-emphasized while valid targets stay at full opacity. Insertion lines and
constraint labels overlay the fixed row boundaries rather than resizing the
table; top/bottom ranking actions also reject dependency-invalid orders.
Full-width separators reinforce the shared column layout. Explicit row
selection, section-wide select-all, visible section buttons that move selected
tickets (or the whole section when none are selected there), and grouped
drag/drop move several tickets between Backlog and Next sprint in one
dependency-safe plan update. Any row opens a full editor for type, priority,
context, acceptance criteria, flexible custom fields, dependency context, and a
durable ticket-level conversation addressed to one selected team member at a
time; there is no implicit team-wide broadcast. Owners can add or remove blockers
while creating or editing manual tickets; cycles are rejected, prerequisites are
re-ranked automatically, and unfinished blockers outside the sprint prevent it
from starting. Suggested work
uses aligned cards with explicit **Blocked by** and **Blocks** relationships rather
than tree indentation. Sprint Planning now places an editable ticket beside its durable
conversation. The owner chooses exactly one team member for each message; that member
runs one real read-only, schema-constrained turn using its configured model, effort, and
instructions. Pending Business Analyst questions keep their own choices, inline
**Other** fields, and explicit **Submit answers** action without hiding or repurposing
the ordinary team composer. Question cards remain where they were asked in the
conversation timeline, so later chat follows them chronologically. Ticket and Epic
details use the same adaptive sheet and conversation proportions. Their initial
Business Analyst refinement starts automatically rather than presenting a redundant
header action. Once consequential questions are answered, both flows apply the
Business Analyst's completed refinement as one versioned update; Ticket refinement
also preserves existing blockers while adding newly recommended prerequisites.
Epic details also reuses the same recipient picker, composer,
empty state, and replying status for durable read-only questions to any selected team
member; ordinary Epic chat remains separate from governed refinement answers. A ticket
team member can reply normally or propose a business-readable ticket change. A
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
available, and the submitted owner response queues the same thread to resume. The
question may include a safe **Open evidence** action for a workspace-relative decision
artifact. Awaiting-owner results cannot also create candidate-bound Product knowledge
proposals or demos; after the owner answers, the same agent updates the evidence and
returns the completed candidate, final knowledge proposals, and review recipe.
When a ticket newly enters **Needs your input**, StoryPointless plays a brief
notification chime. Refreshing or reopening an already-waiting ticket does not
repeat the sound.
Delivery and Tech Lead runs use App Server approval requests rather than treating every sandbox
boundary as a failure. The ticket leads with the plain-language reason for a request and
keeps the exact command or capability available in a technical-details disclosure, with
**Allow once**, **Always allow for this product**, and **Deny** actions where applicable.
One-time decisions apply to the current agent run; saved product access can be
reviewed and revoked in Product settings. Every decision remains auditable after
relaunch on its original permission request, without a duplicate Product Owner
message. The delivery profile grants the exact
ticket worktree plus Codex's minimal macOS runtime paths; it does not deny a parent
directory that the worktree must traverse. Extra Homebrew, SDK, service, or other
system access therefore becomes a scoped Product Owner permission request instead of
a failed workspace write or an agent-created `/tmp` copy. StoryPointless enables and
checks Codex's explicit permission-request tool rather than discovering or whitelisting
package managers and runtime installations itself. Agents diagnose blocked executables,
inspect their foreseeable symlink and runtime dependencies, and request the smallest
coherent capability in one batch rather than asking for an executable, its parent, and
each shared library separately. A package-manager runtime request may therefore include
its executable, link, and installation roots while excluding unrelated data,
configuration, and credentials. Agents do not repeat an ineffective command approval or
add shell wrappers. Agents are explicitly
forbidden from copying a ticket workspace elsewhere to bypass that decision. They
also treat a recovered permission request as audit display rather than executable
command text: retries invoke the underlying executable directly, never paste an already
wrapped `/bin/zsh -lc` command, and replace an interrupted leaf permission with one
consolidated runtime request instead of continuing a path-by-path cascade. Before
routine checks, agents consult verified Environments guidance and use the repository's
established native build system and shortest maintained, purpose-named entry point.
An Implementer may add a version-controlled, non-interactive task or script when a
recurring coherent workflow has no suitable entry point, but never to substitute an
unrelated package manager or runtime, conceal operations, or broaden an approval.
Verified changes to build, test, launch, demo, runtime, readiness, capability, or
limitation guidance are proposed as a complete Environments update for Tech Lead
review. Agents receive
read-only access to the active product's central Git metadata, so status,
diff, history, and conflict inspection do not need Product Owner approval. Their
turns also receive read-only access to that product's `.storypointless` control
directory. Stable SQLite views expose live tickets, Work logs, Epics, sprints,
verified Product knowledge, decisions, delivery provenance, retrospectives, and
team configuration. Agents can therefore discover evidence such as which ticket
implemented a feature by querying current product data and Git history instead
of receiving a copied projection of the whole product in every prompt. Their
turns inherit that product-scoped thread profile so the exact Git grant is not
replaced by the generic delivery profile when work begins or resumes. Their
App Server process disables optional Git locks, ignores the user's global Git
configuration, uses a noninteractive pager, and places the Git-only executable
directory from the Mac's active Apple developer directory first on the managed
path. Plain `git` commands therefore bypass `/usr/bin/git`'s `xcrun` shim without
changing how unrelated tools resolve. They do not need write access to an `xcrun`
cache or the host temporary directory, and agents must not request either for Git
inspection. The assigned worktree remains writable, while StoryPointless alone
owns Git mutations such as staging, commits, branches, integration, and promotion.
Completed implementation becomes a
versioned candidate with a host-created commit and exact head SHA.
StoryPointless gives each immutable candidate to a separate read-only Tech Lead
run, so reviews can proceed in parallel. Approved candidates enter a rank-ordered
serial integration queue and merge against current `trunk` in a detached integration
worktree. Unambiguous conflicts are
handled by an internal Integrator turn in that preserved worktree; material choices
pause as **Needs your input** without inventing a new board state. The exact integrated
revision receives a focused Tech Lead re-review only when conflict resolution changed
the merge result; clean merges retain the immutable candidate review. The ticket moves
to **Ready for Demo** only after its typed demo recipe successfully smoke-tests the
integrated revision. Tech Lead findings block only when a material defect
justifies another implementation and review cycle; whitespace, formatting, and
optional style-only checks are informational unless they have a concrete product,
validity, required-gate, reviewability, or security consequence. A ticket may return
from review to In Progress five times before StoryPointless pauses automatic revisions
for Product Owner direction. The ticket acceptance
room then provides one **Demo**
button. StoryPointless prepares a detached preview checkout, starts a sandboxed local
service through the selected Codex App Server runtime and opens its loopback browser URL, launches a reviewed macOS app, opens a
review artifact, or captures a bounded scenario result according to that reviewed
recipe. Repeated web and app demo clicks reuse a healthy process. **Stop demo**,
Product Owner feedback, approval, product switching, and app shutdown terminate the
managed App Server command session; approval and feedback also remove the preview checkout.
If the Tech Lead has approved the candidate but demo smoke preparation stops, the ticket
offers **Retry demo preparation** immediately. The retry reuses the exact reviewed SHA and
does not require a comment, repeat implementation, or another Tech Lead review.
Requested changes return it to **In Progress** and resume the original implementation
thread with the review comment. After post-conflict review or demo feedback,
StoryPointless first fast-forwards the clean preserved ticket workspace to the exact
reviewed integrated revision and tells the Implementer that accepted trunk work and
the Integrator's resolution are now its baseline. In Ready for Demo, a comment receives
an explanatory reply without changing the reviewed candidate. It routes to the assigned Implementer,
falling back to the latest participating team member and then the Tech Lead.
During active delivery, including review and a paused permission request, the
Product Owner can either leave an informational comment or explicitly ask the
currently responsible team member without resuming or changing the run. A
previously saved owner comment after a pending permission request remains
individually routable until an agent replies. Ticket replies stream the same
concise inline activity summary and Stop action as product Chat.
Owner demo feedback follows the same revision loop,
while **Approve and complete** promotes the reviewed integrated SHA to local `trunk`,
moves the ticket to Done, and admits newly unblocked work. Interrupted runs are
recovered from their durable records and preserved workspace on the next launch.
An **In Progress** implementation paused by app shutdown is requeued automatically
unless it was waiting on a permission decision. Ordinary work explicitly resumes
the persisted Conversation and continues in the same ticket workspace with a focused
recovery instruction; it does not receive the original “start the ticket” briefing again.
Any completed structured result is recovered before another implementation turn is
started. A final-answer item is retained until its matching Codex turn reports completion,
so validation or repair never submits a second turn while the first is still closing. A
Product Owner stop remains paused until they explicitly resume it.
Switching products does not suspend delivery. Every active product keeps its own
scheduler, agent turns, telemetry, permissions, and durable execution context while the
selected product changes only the visible UI projection. Returning to a product shows
the work at its current stage without interrupting or restarting its Implementer,
Integrator, or Tech Lead.
An expired permission request remains visibly actionable and keeps its implementation,
Tech Lead review, or conflict-resolution run paused after relaunch. Once the Product
Owner chooses Allow or Deny, StoryPointless explicitly resumes the persisted Conversation
and applies that decision if the same request is still needed. Tech Lead recovery remains
bound to the same immutable candidate SHA, or the integrated SHA for a post-conflict
re-review; StoryPointless reconstructs that exact detached checkout when needed. It
repeats integration and focused review only when a recorded post-conflict revision cannot
be verified. If an In Progress ticket workspace itself is missing, StoryPointless explains
that uncaptured implementation work could not be recovered before preparing a fresh
isolated workspace. Backlog and refinement are separate from the simplified
active sprint board, whose owner-facing stages are In Progress, In Review, Ready for
Demo, and Done.
Each team profile has internal role guidance and a sensible model/effort policy.
The sidebar exposes live account-supported model and effort selectors, while
Team settings provides shared product guidance without making safety or workflow
policy editable. It exposes model, reasoning effort, and an optional custom-instructions
overlay for every built-in or custom team member. The overlay starts empty and is
appended after StoryPointless's lifecycle and role guidance, so owners can adjust how
a member approaches authorised work without having to maintain the built-in prompt.
Pending ticket suggestions
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
The Team sidebar keeps **Chat** at its top level. Team settings and the reusable
member roster are nested inside a separate **Team members** disclosure group, so
configuration does not compete with Chat as a destination. The roster shows
capabilities, models, effort, and instructions without pretending those profiles
are idle or online. Its expand/collapse transition is clipped to the nested group,
and the compact model and effort controls keep normal horizontal insets with each
caret beside its label. Live agent-run counts, assignment, state, and current
context health live with their tickets on the Sprint Board.
Chat is the product-level place to ask any selected team member a question. Each
top-level message creates an independent thread, replies resume only that thread,
and separate threads can respond concurrently. A new top-level thread receives
at most the latest 100 active-room messages; a reply retains only its parent
thread's conversation context. Chat prefers the stable agent-facing database
views, but it can inspect other active-product tables read-only when an
operational question needs evidence those views do not contain. Run-status
answers use persisted activity rather than an empty comment history, and
permission answers report the owner-facing reason and exact scope without
exposing Codex protocol identifiers, signatures, or worktree paths. The
responding agent supplies a concise durable thread title and a Markdown-formatted
answer, rendered with the same chat bubbles used by Ticket and Epic
conversations. Those bubbles hug short content and use a relaxed maximum width so
longer replies remain readable without becoming a narrow column. Thread titles
aim for five words rather than collapsing into a one-word topic. While an agent works, the bottom
status strip streams supported,
concise Codex activity summaries instead of showing an indefinite generic
spinner. Thread-list timestamps are fixed send/update times rather than ticking
relative timers. The thread pane uses the same quiet sidebar treatment as the
rest of the app, with a pale accent selection. Completed threads can be archived,
shown again, and restored without deleting their messages or Codex context;
archived messages no longer seed new top-level threads. Archive actions use the
same red destructive treatment as Backlog ticket archival. A new thread offers
the team-member picker, and every follow-up can address a different member. A
same-member reply resumes that member's Codex session; changing members starts a
role-specific session with the durable visible thread transcript and current
product evidence.
The starter team is Business Analyst, UX Designer, Tech Lead, and Implementer. The
Tech Lead performs normal delivery review; specialist frontend, backend, security,
and other team members are optional additions rather than permanent headcount.
The current product header opens a searchable, launcher-style product library
with scrollable descriptions, current-workspace state, double-click/open, and
new-product creation. The first product uses the app accent color for its initial
tile, while later products follow the Epics' contrast-spaced green, indigo,
orange, teal, pink, and blue rotation. Each product loads its own backlog,
team, sprints, and knowledge, and the most recently opened product is restored on restart. When
multiple products exist without a valid remembered selection, the library is
shown automatically once rather than interrupting every launch.
Product settings can archive the current product after safely suspending its
active delivery. Archived products leave active navigation but retain their
backlog, Work logs, Product knowledge, source workspace, and delivery history;
the product library can show, restore, and reopen them.
Each product keeps its authoritative database beside its repository at
`<product workspace>/.storypointless/product.sqlite`. New databases are created
directly from one declarative final schema; distributed builds do not replay the
development migration history. The one-time development cutover splits the old
shared `storypointless.sqlite` into these product stores, preserves identifiers
and relationships, and leaves the shared source database intact as a backup.
Product Context keeps the potentially long product description out of the
sidebar while allowing the owner to review and edit what future agents receive.
Manual ticket creation also requires the same simple Story/Task/Bug choice.
Backlog tickets are archived rather than physically deleted so comments and
audit history survive; unresolved dependents must be unlinked first.
Backlog rows show the persisted draft delivery assignment inline, or explicitly
show Unassigned. Moving a ticket into Next sprint changes scope only and never
silently chooses a team member. Every ticket in Next sprint is already in scope;
the owner returns unwanted work to Backlog rather than excluding it again inside
Sprint Planning. Opening an uncustomized plan automatically proposes an editable
sprint goal from the scoped ticket titles. A small purple AI action can regenerate
it, while a previously saved owner-written goal remains untouched; the result
stays a draft until the owner saves the plan. Sprint Planning keeps edits local
until the owner saves, with **Save draft & close** available mid-review and
**Discard changes** retaining the last saved plan. Ordinary Tech Lead review is
an execution-stage system run rather than a second per-ticket planning picker.
Epics are optional backlog groups rather than executable ticket types. The Backlog
derives **Created**, **Planned**, **In progress**, and **Complete** from accepted
ticket delivery, while closed epics collapse into a remembered inline summary that
expands within the same table. Closing separately records the Product Owner's
confirmation of the broader outcome. Ticket details show their Epic as a clickable
relationship in both planning and delivery history.
An **Improve** sidebar section now separates sprint Retrospectives from
longitudinal Reports. Both are evidence-first: each starts with a clear empty
state, and Reports shows current operational counts after the first completed
sprint while withholding trend claims until comparable completed sprints exist.
A compact tabbed chart switches between cycle time, agent time per delivered
outcome, and outcomes with correction cycles across the latest twelve sprints or
the full history, with exact values available for a selected sprint.
Custom team-member creation is currently hidden from Team settings while that
workflow is deferred. Existing custom team members remain configurable and are
archived rather than destructively deleted.

The execution path now admits every dependency-free ticket in parallel. Implementation
is isolated in ticket-named Git worktrees, concurrent Codex notifications are routed
to the correct run, and candidate revisions preserve the agent's full commit range.
Candidates integrate serially against current local `trunk`; the Integrator resolves
safe conflicts in the detached merge workspace and the Tech Lead reviews the exact
resulting SHA. Product Owner approval alone promotes that reviewed revision. Ready
for Demo candidates do not occupy the integration lane. When one approval advances
trunk, any other prepared demo that no longer contains current trunk automatically
returns to the integration queue; a clean merge retains its candidate review, while
conflict resolution receives focused re-review. Release automation, streamed
fine-grained progress, and agent-authored quit checkpoints remain to be implemented.
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
Markdown into the integrated revision. Candidate-sourced Markdown is not synchronized
into the accepted `trunk` workspace until the Product Owner approves that candidate,
so working-tree checkpoints cannot bypass the normal promotion gate. The ticket keeps
the full proposal, rationale, status, and page history visible. Set
`STORYPOINTLESS_REQUIRE_KNOWLEDGE_APPROVAL=1` when launching the development app to
restore the stricter per-proposal Product Owner accept/reject gate. Material unstated
Product Owner decisions must still pause the ticket and cannot be smuggled through a
knowledge proposal. The Knowledge view provides a seeded page
tree, Markdown editing, search, breadcrumbs, contents, backlinks, version history,
provenance metadata, and citation-backed **Ask Knowledge** over verified pages only.
Unused canonical pages are stored with genuinely empty bodies so their guidance is
presentation-only rather than false verified content. Delivery runs receive a bounded
set of non-empty verified reference pages plus a separate canonical destination
directory. Verified Overview, Product principles, Glossary, Ways of working, and
Environments pages are always included; the Work log separates them from pages selected
for the ticket. Empty mandatory pages remain writable destinations rather than false
context. Implementers may propose a complete Environments replacement when verified
operational guidance is absent or stale; reviewers receive it read-only and verify the
proposal with the candidate. Other empty canonical pages and relevant populated pages
may receive complete updates, while sections may receive focused child pages; persisted
per-run destination authorization prevents an agent from using an unrelated page as a
catch-all.

An approved Business Analyst research ticket normally hands its decision to already
planned dependant tickets through its completion Work log and verified Product
knowledge. It may publish fully formed follow-up ticket proposals only for genuinely
new work that is absent from the active Backlog. Those exceptional proposals appear
as a labelled suggestion batch, inherit the source epic and research dependency when
accepted, and remain outside committed scope until the Product Owner reviews them.
Bounded verified pages are selected with title, taxonomy, provenance, and capped body
relevance rather than sending the whole wiki or allowing a long page to dominate by
word count. Normal app termination interrupts the active turn, persists the
interruption, preserves its Conversation and workspace, and queues ordinary implementation
to continue on the next launch. A live permission request expires with the old process,
remains paused for an explicit owner decision, and resumes only after that decision.

Execution and Tech Lead results also record at most two concrete observations in
each retrospective category. Their free-text action ideas remain source evidence
rather than becoming repeated Product Owner decisions. At sprint completion, one
read-only Business Analyst turn groups and deduplicates the frozen evidence into
zero to five final actions, each with an expected effect and inspectable source
observations. Existing Ways of working, prior decisions, and active Backlog scope
prevent already-covered work from being proposed again. The durable synthesis can
be retried after interruption or explicitly skipped when Codex is unavailable.
The Retrospectives view presents attributed, ticket-linked evidence for **Went
well** and **Could improve**, plus the consolidated review queue, opening on the
latest completed sprint when one exists. Its sprint picker labels retrospectives
as **Needs conclusion**, **Concluded**, or **In progress**. During an active
sprint, the Product Owner can append attributed action ideas while they are
fresh and delete their own ideas before completion. Those entries remain source
evidence: the Business Analyst considers the ideas that remain with the team’s
observations after the sprint ends, while final actions and decisions still wait
until completion.
After a sprint completes, final action preparation resolves, and before its
retrospective is concluded,
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

Build a local macOS application bundle with the native app icon using:

```sh
./scripts/build_app.sh release
```

The bundle is written to `.build/app/release/StoryPointless.app`. The
`STORYPOINTLESS_BUNDLE_IDENTIFIER`, `STORYPOINTLESS_VERSION`,
`STORYPOINTLESS_BUILD_NUMBER`, and `STORYPOINTLESS_SIGN_IDENTITY` environment
variables supply release metadata and signing identity. Local builds receive an
ad-hoc signature by default; a Developer ID identity opts into hardened-runtime
signing. This is a packaging checkpoint, not yet a customer release: local Git
distribution, third-party notices, notarization, and the installer/update path
still need to be completed and verified.

These developer commands are not part of the customer experience. StoryPointless
uses the official Codex app by default, lets the owner choose another explicitly
added Codex app or executable from the sidebar connection menu, and remembers
that application-wide choice. The shipped product will still require a supported
Codex installation while keeping its CLI and App Server terminal hidden.
