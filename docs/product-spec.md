# StoryPointless: Product vision and specification

**Status:** Working draft 0.9  
**Date:** 22 July 2026  
**Working title:** StoryPointless  
**Audience:** Founder, product, design, engineering, and prospective design partners

## 1. Executive summary

StoryPointless is an AI-native product delivery system for people who have a
product they want to build but do not have a conventional software team.

The MVP is a self-contained macOS application. The user installs one app,
describes a product, signs in to supported services, and StoryPointless creates
and manages the repository, toolchain, agent runtimes, workspaces, previews, and
delivery history. It exposes product concepts—not terminals, CLIs, Git commands,
or local runner configuration.

The product gives a human product owner a familiar agile control surface—a
backlog, work items, planning, a live delivery board, acceptance, release, and
retrospectives—while AI agents perform much of the planning, implementation,
review, testing, documentation, and operational work.

The product is not merely a Jira clone with AI assignees. Jira and Linear
already let users delegate issues to Codex, Claude, Cursor, Copilot, and other
agents. StoryPointless must instead own the difficult layer between an idea and
a safe release:

- turning product intent into an executable, testable work contract;
- assigning Codex model, reasoning-effort, role, and permission profiles to work;
- scheduling parallel work without creating code conflicts or runaway spend;
- showing evidence of correctness, not just agent-authored status updates;
- forecasting and controlling monetary cost, elapsed time, and human attention;
- preserving decisions and verified knowledge as the product evolves; and
- giving a non-engineer a safe path to preview, accept, release, and roll back.

The recommended initial position is:

> **Your AI product team, from outcome to verified release.**

The first target should be technically literate solo founders and small product
teams, not every non-technical entrepreneur. They have the urgency and context
to evaluate the system while tolerating an early product's limits. Broader
non-technical use should follow only after the release and governance model is
proven.

## 2. Recommendation at a glance

### Keep

- The agile mental model. Backlogs, readiness, small batches, review,
  acceptance, release, and retrospectives remain useful coordination tools.
- Work items as the place where intent, constraints, discussion, decisions, and
  delivery evidence meet.
- A visible team of agents with capabilities, roles, availability, cost, and a
  performance history.
- A parallel knowledge system that improves the context supplied to later work.
- User-defined quality expectations and human approval for meaningful releases.

### Change

- Do not make story points equal tokens. Show a probabilistic forecast in money,
  elapsed time, and likely human attention. Keep tokens as an underlying cost
  signal.
- Do not start every sprint item at once. Starting a sprint should activate a
  dependency-aware scheduler with work-in-progress, budget, repository, and
  environment constraints.
- Do not treat an agent's comment as proof of progress. Status should be backed
  by observable events and artifacts such as commits, checks, test results,
  previews, screenshots, and deployment records.
- Do not allow agents to be the sole accountable assignee. A human owns the
  outcome; agents are implementers, reviewers, or contributors.
- Do not let generated prose silently become institutional truth. Knowledge
  needs provenance, review state, freshness, and links to the code and decisions
  that support it.

### Defer

- Additional model providers and an agent marketplace.
- Fully autonomous production releases.
- Enterprise Jira/Confluence feature parity.
- Complex custom workflows and reports.
- Native mobile applications.
- Windows and Linux desktop applications.
- Multi-user and cross-device synchronization.
- Remote execution while the owner's Mac is unavailable.
- General-purpose project management outside software products.

## 3. Product thesis

### 3.1 Problem

Coding agents have made software creation dramatically more accessible, but the
user is still acting as an engineering manager, delivery manager, release
engineer, and repository traffic controller. Work is fragmented across chat
sessions, issue trackers, pull requests, terminal windows, CI systems, hosting
platforms, and documents.

A founder can ask an agent to implement a feature, but still struggles to answer:

- Is the requested outcome defined well enough to build?
- What does this depend on, and what can happen in parallel?
- Which agent is most likely to do it well?
- What will the accepted result cost—not merely the first attempt?
- Is the agent actually progressing, stuck, or repeatedly trying the same thing?
- Did the result satisfy the product intent as well as the tests?
- Is it safe to release, and can it be rolled back?
- What was learned, and will the next agent receive that context automatically?

Existing trackers record work. Agent products execute work. StoryPointless is
intended to connect planning, execution, verification, learning, and release
into one governed loop.

### 3.2 Hypothesis

If a product owner can express outcomes in a guided backlog, delegate them to
specialized Codex profiles, and receive verified previews within explicit effort
and risk limits, then they can ship useful software without assembling a
traditional development team for every discipline.

### 3.3 Product promise

StoryPointless converts a prioritized product backlog into a stream of
observable, independently checked, releasable product increments while the
human owner retains control of scope, spend, permissions, and release.

### 3.4 Why agile remains relevant

The valuable part of agile is not estimation theatre or moving cards. It is:

- short feedback loops;
- small, valuable increments;
- explicit prioritization;
- frequent inspection of working software;
- adapting plans based on evidence; and
- continuously improving how the team works.

Those properties become more important when execution is cheap and fast. The
ceremonies should be compressed or automated, but the feedback and governance
loops should remain.

## 4. Target customer

### 4.1 Primary early adopter

A solo founder or product-led micro-team that:

- uses macOS and has a Codex-compatible ChatGPT plan or OpenAI API account;
- is comfortable describing user and business outcomes;
- may have used a coding agent but does not want to operate developer tooling;
- has no dedicated delivery team, or a very small one;
- can evaluate a preview even if they cannot inspect every line of code;
- is willing to approve access, effort, and potentially consequential actions;
- is building a web product with conventional infrastructure.

This user is often a product manager, designer, technical founder, consultant,
or experienced operator building a new product.

### 4.2 Later customer

- Non-technical founders using constrained templates and managed hosting.
- Small agencies operating several client products.
- Internal innovation teams that need auditable multi-agent delivery.
- Existing engineering teams that want a governed Codex orchestration layer.

### 4.3 Deliberate exclusions for the first version

- Safety-critical, medical, financial, or regulated production systems.
- Products that cannot be tested or previewed in an isolated environment.
- Large monorepos with many active human teams.
- Legacy systems requiring privileged access to production data.
- Native mobile, embedded, or hardware-dependent delivery.
- Users expecting the system to determine business desirability without their
  involvement.

## 5. Jobs to be done

### Core job

> When I have a product outcome in mind, help me turn it into a safely shipped
> increment without requiring me to coordinate several coding tools or become an
> engineering manager.

### Supporting jobs

- Help me express a buildable requirement without forcing me to write a perfect
  technical specification.
- Tell me what information or decisions are missing before expensive work starts.
- Show me realistic choices between scope, quality, speed, and spend.
- Let me use agent subscriptions or API accounts I already pay for where this is
  technically and contractually supported.
- Keep multiple agents productive without letting them overwrite one another.
- Explain progress and blockers in product language.
- Give me a working preview and a clear acceptance checklist.
- Preserve why the system works as it does so later changes do not regress old
  decisions.
- Show whether the delivery system is becoming cheaper, faster, and more reliable.

## 6. Positioning and market boundary

### 6.1 The crowded category

By July 2026, the obvious interaction—assign an issue to a coding agent and get
a pull request—is available in major incumbent workflows:

- Linear represents agents as workspace participants, supports issue delegation,
  keeps human accountability, and exposes agent activity and custom agent APIs.
- Jira presents itself as an orchestration layer for Claude, Cursor, Codex,
  GitHub Copilot, native agents, and MCP agents.
- GitHub Copilot can accept issues, work in an isolated environment, run checks,
  and open pull requests.

Therefore, a cleaner board plus agent avatars is easy to understand but not a
defensible product.

### 6.2 Recommended category

Use **AI product delivery** or **AI product team** as the category. Avoid leading
with “Jira alternative”; it frames the product as a cheaper tracker and invites
an unwinnable checklist comparison.

### 6.3 Positioning statement

For product-minded founders who want to ship software without assembling a
development team, StoryPointless is an AI product delivery system that plans,
orchestrates, verifies, and releases work through a team of coding agents.
Unlike issue trackers that merely hand tickets to agents, StoryPointless
controls the whole outcome loop: readiness, budget, execution, independent
verification, product acceptance, release, and organizational memory.

### 6.4 Candidate messages

- **Your AI product team, from backlog to release.**
- **Describe outcomes. Review working software. Ship with confidence.**
- **The control plane for your AI development team.**
- **Product delivery without the coordination tax.**

“StoryPointless” is memorable and accurately rejects ritualized points. It may,
however, sound dismissive of the useful parts of agile. Test whether the joke
helps recall without undermining trust for deployment and security.

### 6.5 Differentiation to validate

1. **Outcome governance:** every item becomes a bounded, testable work contract.
2. **Calibrated Codex team:** choose model, effort, tools, and role instructions
   by task and observed results rather than using one undifferentiated agent.
3. **Economics:** forecast and enforce total cost per accepted outcome.
4. **Evidence:** make correctness and release readiness visible to a
   non-engineer.
5. **Safe execution:** user-owned credentials and isolated workspaces with
   explicit permissions.
6. **Learning:** turn delivery history into better context, routing, estimation,
   and definition-of-done recommendations.

None of these is a moat alone. The potential moat is the accumulated,
privacy-preserving mapping between types of product work, agent configurations,
quality gates, intervention patterns, accepted outcomes, and true cost.

## 7. Product principles

1. **The human owns the outcome.** Agents may act, but responsibility and
   high-impact approval remain human.
2. **Evidence over narration.** Prefer a check, artifact, or observable event to
   an agent saying that something is done.
3. **Progressive autonomy.** Earn broader permissions through successful work;
   do not begin with unrestricted access.
4. **Small batches win.** Limit simultaneous work to reduce conflicts, spend,
   and review overload.
5. **Cost means accepted cost.** Include retries, review, compute, CI, and
   rework—not just the first model call.
6. **Context must be earned.** Supply the smallest relevant, verified context;
   more tokens are not automatically better.
7. **Learning must be inspectable.** Recommendations should cite the delivery
   history that produced them.
8. **The board is a control surface, not a theatre.** Optimize it for decisions
   and intervention, not pleasing animation.
9. **Releases are reversible.** A release action without health checks and a
   rollback path is incomplete.
10. **Interoperability before captivity.** Repositories, documents, work-item
    history, and decisions must be exportable.

## 8. Core domain model

### 8.1 Product space

A workspace containing the product vision, members, repositories,
environments, knowledge, delivery policies, safety limits, and one or more
delivery views.

Each product has a durable identifying color used by its initial tile in the
product library and current-product header. The first product uses the app accent
color; later products receive a distinct color from a curated light/dark-safe
palette so switching products is immediately visible. Assigned colors do not
change across relaunches.

Switching the selected product changes only what the Product Owner is viewing.
Active delivery continues in the background for every product without
interrupting, restarting, or requeuing its Implementer, Integrator, or Tech Lead.
Product-scoped progress and permission requests become visible when that product
is opened.

Product settings provide a destructive-looking but non-destructive **Archive
product** action with explicit confirmation. Archiving safely suspends live
delivery, removes the product from active navigation and selection, and
preserves its Backlog, Work logs, Product knowledge, source workspace, and
delivery history. Archived products remain available from the product library
and can be restored and reopened. Product archival does not silently cancel
ticket scope, discard worktrees, or physically delete audit records.

### 8.2 Human owner

The accountable person for a product or work item. The owner approves material
scope changes, secrets and permissions, acceptance, and release according to
policy.

### 8.3 Agent profile

An installed execution capability, not merely a model name. It records:

- Codex model, reasoning effort, role instructions, and tool configuration;
- supported task types and tools;
- role labels such as implementer, reviewer, QA, researcher, or lead;
- repository and environment access;
- concurrency and rate limits;
- price signals and budget source;
- observed success, rework, and intervention rates;
- supported event and artifact types; and
- whether credentials live locally, in a customer cloud, or in the hosted vault.

Instructions are composed in explicit layers: immutable StoryPointless safety
and governance; editable product-wide guidance; the profile's versioned default
or owner override; and the frozen ticket contract plus definition of done. Later
layers cannot grant permissions or bypass earlier governance. The exact model,
effort, and composed-instruction version used by a run are retained for audit
and reproducibility.

“Senior” and “junior” should be presentation shortcuts derived from capability
and performance, not hard-coded claims based solely on model price.

### 8.4 Work item

The durable record of a desired outcome. It contains the user-facing problem,
type, priority, ownership, workflow state, dependencies, discussion, and linked
runs. The initial types are deliberately small:

- **Story:** a user-visible product outcome;
- **Task:** supporting delivery, research, documentation, or maintenance work;
  and
- **Bug:** behaviour that should already work but does not.

Type supports scanning, routing, definitions of done, and normalized reporting;
it must not create three unrelated workflows. Bugs should eventually link to
the delivered ticket or version that introduced the regression when known.

An **epic** is a separate planning container, not a fourth ticket type and not
an executable work item. It describes a broader outcome and contains zero or
more tickets. Its progress, forecast, usage, blockers, and quality signals are
derived from those children; it is never directly assigned to an agent or moved
into a sprint. Tickets may belong to at most one epic initially. An open epic's
progress is derived from its accepted, non-archived tickets:

- **Created:** it has no accepted tickets;
- **Planned:** it has tickets, but none has entered delivery;
- **In progress:** at least one ticket has entered delivery or is delivered,
  while at least one remains undelivered; and
- **Complete:** every accepted ticket is **Done**.

Complete ticket delivery does not by itself confirm the broader product outcome.
A complete epic presents a prominent **Close epic** action. Closing is the
Product Owner's durable confirmation that the outcome has been achieved. Closed
epics are read-only delivery history until explicitly reopened; tickets and
ticket proposals can belong only to an open epic.

The backlog should present epics as compact, collapsible groups with an outcome,
derived progress, and clear **No epic** group. Open epics appear first; closed
epics collapse into one full-width summary row within the same epic table and can
be expanded inline without duplicating the table headers. The disclosure choice is
remembered per product. Each Epic receives the next durable color from the
product's contrast-spaced blue, green, indigo, orange, teal, and pink sequence,
cycling only after the palette is exhausted. Its Epic row and every associated
ticket row show the same left-edge marker in the Backlog, and associated ticket
cards retain that marker on the Sprint Board. Owners can drag tickets between
groups without affecting workflow state. Small products do not need an epic,
and autosuggestion should avoid generating empty hierarchy for its own sake.
Archiving an epic also archives its unfinished backlog tickets and rejects its
outstanding proposed tickets atomically while preserving their epic association
for history. Any in-flight proposal generation is cancelled so late results
cannot return to the active backlog. Delivered tickets remain delivered, and an
epic with tickets in active delivery cannot be archived until that work is
finished or removed from delivery.

### 8.5 Work contract

The executable version of a work item. A ready contract contains:

- desired user or operational outcome;
- acceptance criteria with observable examples;
- non-goals;
- constraints and applicable product decisions;
- repository and likely scope;
- dependencies and conflict hints;
- definition-of-done policy;
- security and permission tier;
- system-derived forecast and execution safety envelope;
- human owner and agent roles;
- required deliverables, such as code, tests, preview, migration, or docs; and
- escalation questions that must be answered before execution.

The contract is versioned and immutable for an active run. Material changes
create a new version so the system can explain what an agent was asked to do.

### 8.6 Agent run

One bounded attempt by one agent against one contract version. It owns its
execution environment, event stream, costs, artifacts, outcome, and termination
reason. Retries are new runs, not erased history.

### 8.7 Evidence

A typed artifact used to support a claim. Examples include a commit, diff,
test report, code-coverage report, security scan, screenshot, video, preview
URL, accessibility report, benchmark, migration result, deployment record, or
human acceptance note.

### 8.8 Decision

A versioned record of a meaningful product or technical choice: context,
options, selection, consequences, owner, date, and supporting work items.

### 8.9 Knowledge claim

A retrievable statement with provenance, scope, confidence, freshness, and
links to supporting code, evidence, decisions, or external sources. A claim may
be proposed, verified, disputed, or stale.

### 8.10 Delivery policy

A reusable definition of ready, definition of done, action permissions, quality
gates, review independence, budget thresholds, release approvals, and rollback
requirements.

### 8.11 Ticket knowledge change set

The documentation and durable knowledge produced by one work item. It is linked
to the contract, runs, candidate commit, review, and acceptance, and contains:

- a plain-language delivery note explaining what changed and how it works;
- version-controlled product, technical, or operational documentation diffs;
- material product or architecture decisions, including rejected alternatives
  and tradeoffs;
- proposed new or updated knowledge claims;
- claims made potentially stale by the change;
- known limitations and follow-up questions; and
- sources and evidence supporting each substantive statement.

The change set is versioned with the candidate. Agent comments and raw traces can
support it, but they do not automatically become durable product knowledge.

### 8.12 Sprint

The owner-facing unit that authorizes coordinated delivery. A sprint records its
goal, selected contract versions, dependencies, assignments, forecast,
parallelism policy, planned acceptance capacity, state, and actual outcome.

**Start sprint** freezes the initial plan and enables scheduler admission. It can
create many internal agent runs, but “run” remains execution terminology rather
than a primary PO action. Plan changes after start are versioned and explained;
they do not rewrite what the owner originally authorized.

### 8.13 Conversation and action proposal

A conversation room is a durable inbox with human and profile participants,
unread state, and an explicit context scope. Its kind is direct message,
product, sprint, ticket, or named group. Messages may cite work items,
decisions, knowledge, evidence, and exact repository revisions, but messages
are not authoritative product records by themselves.

Each top-level owner message starts an independent **conversation thread**.
Replies remain nested beneath it, and the thread has a visible state such as
working, needs input, proposal ready, complete, failed, or cancelled. The owner
can therefore start several questions or requests without waiting for a
previous agent response or worrying about one request corrupting another's
context. Follow-ups inside one conversation thread retain that thread's context
and are processed in order; separate conversation threads may run concurrently
subject to the normal scheduler and shared-usage constraints.

The room composer creates a new top-level thread by default; replying from an
open thread keeps the message there. If an agent is already working, a follow-up
is accepted immediately and shown as pending for the next safe turn boundary
rather than being lost or unpredictably injected mid-action. An explicit
**Interrupt and redirect** control is available when the owner genuinely wants
to stop the current turn.

A conversation thread is a product-level UI record, not necessarily one Codex
thread. A direct conversation may resume one bounded Codex thread for follow-up
turns. A group conversation may coordinate separate Codex threads for the
mentioned profiles and optionally ask the lead profile to synthesize their
responses. The UI keeps this implementation detail hidden while preserving the
underlying run and provenance links for audit and recovery.

An action proposal is a typed, versioned command produced from a conversation or
refinement session. It records the source message, proposer, target record and
version, before/after business diff, rationale, affected fields, validation
result, and state: proposed, partially accepted, accepted, rejected, stale, or
applied. Applying it requires owner authorization and writes the normal domain
transaction and audit event. A proposal becomes stale rather than overwriting a
ticket that changed after the proposal was created.

Concurrent conversation threads may read the same ticket version, but they
cannot silently overwrite one another. Every proposal carries its base ticket
version. Applying the first accepted proposal increments that version; other
open proposals against the old version become **stale** and must be refreshed,
rebased as a new business-readable diff, or rejected. Threads can continue
discussing after this happens, but stale actions are never auto-applied.

## 9. End-to-end experience

### 9.1 Onboarding

1. The owner creates a product space and describes the product, target user,
   current stage, and risk tolerance, or chooses to import an existing Git
   repository.
2. StoryPointless creates a local product directory and Git repository. It may
   begin with an empty, agent-planned product, an approved starter template, or
   a managed clone whose existing history and default branch become the
   product's accepted starting point.
3. The owner adds Codex through an in-app “Sign in with ChatGPT” flow or an
   OpenAI API key.
4. StoryPointless creates an opinionated starter team: business analyst, UX
   designer, lead/reviewer, and general implementer. The owner can add optional
   specialist team members such as frontend, backend, security, accessibility, or
   marketing when the product actually needs them. Profiles use Codex models,
   reasoning effort, role instructions, permission policies, and concurrency
   limits.
5. StoryPointless proposes a starter delivery policy based on the stack and
   risk tier.
6. A diagnostic work item verifies the local repository, sandbox, agent,
   permission prompts, event reporting, and credential revocation before real
   work begins.

The onboarding must make data and credential boundaries explicit. “Connected”
should show exactly what can be read, changed, deployed, and billed.

### 9.2 Backlog creation

The owner can type an idea in ordinary product language. AI assistance can:

- rewrite it as an outcome rather than an implementation instruction;
- suggest acceptance examples and edge cases;
- identify missing product decisions;
- retrieve related decisions and prior work;
- detect duplicates and contradictions;
- propose dependencies, splits, and non-goals; and
- warn when a request is too broad or not safely testable.

For a new product, one business-analyst profile can also propose a starter
backlog rather than waiting for the owner to invent every ticket. This is one
coherent analysis, not one ticket authored by each team member. Each proposal
includes its rationale, draft acceptance criteria, uncertainty, likely future
owner, Story/Task/Bug classification, forecast range, and explicit dependency edges. The proposal view should
make useful parallelism visible: for example, a weather-provider investigation
may block the real data adapter while a UI can proceed against an agreed mock
contract.

Scope determines proposal count, not team size. The initial structured turn can
return 1–24 tickets and should normally use as many as the product genuinely
needs. Business Analyst, UX Designer, and Implementer roles may repeat freely;
the role is a routing recommendation for later delivery. The decoder rejects
unknown dependency references, self-dependencies, and dependency cycles.

Epic planning must cover the complete path to the agreed outcome without
forcing every outcome through the same delivery stages. When the owner has
authorised research, its recommendation can be a prerequisite for downstream
work, but it must not replace delivery when the epic success criteria require a
product change. Ticket boundaries follow independently valuable outcomes,
genuine dependencies, and useful parallelism rather than a default research,
design, implementation, and verification sequence. Verification is explicit in
the relevant acceptance criteria and becomes a separate ticket only when its
outcome should be delivered, reviewed, or scheduled independently. The epic
details view keeps proposed tickets in its **Tickets** section and exposes
**Accept all** and **Dismiss all** in that section's header; row selection is a
convenience, not the only discoverable way to continue. In the Backlog, the
same actions sit in a full-width proposed-ticket group row between the shared
table headings and the proposed rows, so normal ticket columns remain aligned
and the scope of "all" stays explicit.

When a ticket belongs to an epic, both its editable details and delivery Work
log show that relationship as a compact link to the Epic details. The link
remains available from completed delivery history and preserves any unsaved
ticket edits while the owner inspects the epic. Closed and archived Epic details
are read-only.

Agreeing constraints for an unnamed real external source does not select that
source when current evidence about candidates, terms, suitability or operation
is still required. Clarification choices distinguish a separate Business
Analyst comparison and recommendation from an already approved owner-supplied
choice and from explicitly delegating selection to the implementer during
delivery without a separate recommendation. Vague choices such as “let the team
choose” are not used. Authorising the Business Analyst or team to identify,
compare, recommend or choose using current external evidence authorises a
decision-enabling research ticket. When every credible recommendation still
requires the agreed product change, the initial epic plan also includes the
downstream delivery tickets rather than waiting for research to rediscover them.

Epic clarification is durable across application restarts. If its underlying
Codex thread has expired, StoryPointless starts a replacement read-only thread,
supplies the preserved Business Analyst conversation and Product Owner answers,
and continues without asking the owner to re-enter or discard resolved input.
Epic details also keeps the ordinary team composer available before, during, and
after clarification. The Product Owner may address any one team member without
submitting or dismissing the Business Analyst's structured questions. Each
question retains its own choices and inline **Other** text field; only the
separate **Submit answers** action records those governed answers and advances
epic refinement. Ordinary chat remains durable context but is not treated as an
authoritative refinement answer or permission to change epic scope. Active
question cards remain anchored to the Business Analyst message that introduced
them, and any later ordinary chat appears below them in chronological order.

Role-aware suggestions should produce a coherent delivery graph rather than a
list of generic engineering tasks. For a weather product, an illustrative
proposal is:

- **Business Analyst:** investigate and recommend a suitable weather-data
  provider;
- **UX Designer:** design and validate the location-search and forecast
  prototype;
- **Implementer:** build the approved experience, depending on the UX contract
  and provider interface while remaining able to start against mocks; and
- **Implementer:** add a service only if caching, credential protection,
  aggregation, or another backend responsibility is justified. This may be a
  separate parallel ticket, but it does not require a permanent backend team member.

The **Lead** reviews the resulting delivery against the approved ticket
contract. Higher-risk work can add a separate Security Auditor or specialist
review team member without changing the starter team.

The team members influence analysis, deliverables, and dependency reasoning; they
must not cause the system to invent a backend or serialize independent work.

An empty or newly created backlog prominently offers **Autosuggest Tickets**.
The same action remains available later as a way to find missing work. Clicking
it creates one durable suggestion session for the current product; repeated
clicks cannot start another analysis while proposals still await review. Once
the owner has accepted or rejected every proposal, the action becomes **Suggest
Missing Tickets** and supplies accepted scope plus the latest rejected proposals
to the next gap analysis.

Conditional implementation is not treated as committed scope. If a research or
product decision may determine that no implementation is required, autosuggest
creates the decision ticket first. A Business Analyst delivering that authorised
research normally supplies its decision, contract, evidence and caveats to the
already planned dependant tickets through its completion Work log and verified
Product knowledge. It returns no follow-up proposals when active tickets already
cover the downstream work, and it never rewords, splits or replaces those tickets
merely because research added detail. If evidence materially conflicts with an
accepted ticket contract, the Business Analyst asks the Product Owner rather than
silently changing scope.

Research may recommend zero or more fully formed follow-up tickets only when its
evidence establishes genuinely new work absent from every active ticket. The Tech
Lead reviews those exceptional recommendations with the research artefact, the
Product Owner sees them before approving the outcome, and approval publishes them
as a labelled, reviewable suggestion batch in the Backlog. Each accepted follow-up
inherits the research ticket's epic and retains the completed research ticket as a
durable prerequisite; rejected recommendations never become scope. Multiple
outstanding suggestion batches remain queued for review rather than hiding one
another.

While the business analyst works, the backlog view shows one temporary
analysis card with phases such as **Understanding the product outcome**,
**Mapping research, design, and delivery work**, and **Finding dependencies and
parallel paths**. It does not render teammate-shaped cards that imply several
agents are independently generating tickets. These placeholders
are visually distinct from work items, do not count toward backlog totals or
sprint scope, and can be cancelled or recovered after restart. On launch,
StoryPointless automatically retries an interrupted epic suggestion session once,
first recovering any completed structured result from the saved Conversation and
then continuing from the durable refinement transcript when another turn is
needed. The animated ticket placeholders remain visible in the Backlog and epic
ticket list throughout recovery. A genuine repeated generation or validation
failure remains reviewable and does not loop automatically on every launch. As
results arrive, placeholders become vertically stacked ticket proposals inside
a dashed
suggested-work region above the ranked backlog. Dependency depth creates a compact
staggered connector outline, while each card retains explicit dependency labels,
rationale, acceptance criteria, and **Accept**, **Reject**, **Discuss**, and
batch-review actions. Acceptance removes the proposal card and creates the
normal backlog ticket; rejection never creates scope.

Suggested tickets are not backlog records until the owner accepts them. Temporary
references such as `S1` are shown separately and are never part of the ticket title. The
owner can accept, edit, or reject each suggestion, inspect why one item blocks
another, accept the remaining reviewed batch directly, or dismiss the remaining
batch with confirmation. Bulk acceptance only creates backlog records; it never
scopes or starts a sprint.
Accepting a suggestion with still-proposed prerequisites first names the full
transitive prerequisite set, then accepts the selected suggestion and those
prerequisites atomically with their dependency relationships.
Rejecting a prerequisite with dependents first previews the full transitive
impact. Confirmation rejects every remaining dependent proposal and archives any
dependent ticket already accepted into the backlog as one atomic action; tickets
that have entered delivery prevent the cascade and require an explicit recovery
decision. Rejections and edits become refinement feedback; they must not quietly
reappear as committed scope.
After no proposals remain to review, the suggested-work region disappears; its
decisions remain in the audit and future-analysis context rather than occupying
permanent backlog space.

AI edits remain proposed changes with a visible diff. The owner approves
meaningful scope and acceptance changes.

### 9.3 Backlog refinement

Backlog and refinement have their own workspace rather than sharing the active
sprint board. Its primary information is product scope and planning confidence:

- the full workspace is a vertically scrolling, compact ranked list rather than
  a Kanban board;
- **Next sprint** and **Backlog** are the two visible planning sections; dragging
  between them changes sprint intent but never starts execution. A
  cross-section move preserves the ticket's authoritative backlog rank when the
  chosen destination does not express a different relative position;
- rows have explicit multi-selection and section-wide select-all. Bulk buttons
  or dragging any selected row move the selected set in one persisted operation;
  selecting a complete dependency branch succeeds, while an invalid partial
  move explains which prerequisite or dependent must also be selected;
- ticket creation belongs to the Backlog section, and sprint-planning actions
  belong to the backlog header rather than a global title-bar toolbar;
- every row opens a focused ticket surface with editable core and custom fields,
  dependency context, and a durable ticket-level team thread;
- Ticket and Epic detail surfaces share the same laptop-safe adaptive sheet
  geometry. Initial Business Analyst refinement begins automatically when an
  incomplete open item is shown and the team connection is available; the
  header does not repeat that lifecycle as a manual AI action, while a failed
  refinement retains its contextual retry action;
- top/bottom rank shortcuts and row reordering preserve dependency order. While
  dragging, every dependency-safe insertion position is indicated in blue; an
  invalid hovered position turns red and names the sprint-scope or ranking
  constraint before the owner drops the tickets. Invalid destination rows are
  de-emphasized while valid targets remain at full opacity. Insertion lines and
  constraint labels overlay fixed row boundaries so beginning or moving a drag
  never reflows the table. Colour is reinforced by a warning symbol, text, and
  an accessibility label;
- backlog rank is the authoritative delivery order, while priority remains a
  lightweight urgency/value signal rather than silently re-sorting owner intent;
- dependencies remain explicit graph relationships in the canonical flat list.
  Tree indentation is not authoritative because one ticket may have multiple
  blockers; a future grouped dependency-path lens may summarize simple branches
  without duplicating or hiding work;
- every backlog row shows its persisted provisional delivery assignee, or
  **Unassigned**. Moving work into Next sprint records scope intent only; it must
  not silently choose the first eligible member. Unsaved Sprint Planning changes
  never leak into this projection, and Start Sprint refuses unassigned work;
- row separators span the content width so the compact list reads as one aligned
  table rather than unrelated indented fragments;
- editable values use explicit left-aligned labels and visible input surfaces;
  and
- Codex connectivity is a compact workspace status signal, not an AI teammate.

- total backlog and next-sprint scope;
- value and priority;
- computed readiness, open questions, and stale assumptions;
- dependency and likely-conflict edges;
- system-generated cost, elapsed-time, and human-attention forecast ranges;
- which work is in the next sprint.

Next-sprint membership expresses intent rather than commitment. It does not
authorize execution or silently satisfy dependencies. A ticket can be scoped
before every detail is ready; the readiness summary and sprint planner expose
what must still be resolved before **Start Sprint** becomes available.

**Start backlog grooming** opens a structured review rather than an unbounded
group chat.
The business-analyst profile first works with the owner on value, priority,
ambiguity, and acceptance intent. Specialist agents then inspect selected items,
and the lead profile synthesizes:

- readiness failures;
- ambiguity and questions for the owner;
- dependency and likely code-conflict graph;
- opportunities to split by independently valuable outcome;
- possible shared foundations;
- risk tiers;
- suggested implementation and review capabilities; and
- a forecast range with its major uncertainty drivers.

The owner sees proposed diffs and decisions, not a long transcript. They can
accept suggestions individually or as a reviewed batch.

### 9.4 Sprint planning

Once grooming has produced a candidate scope, the owner selects **Start Sprint
Planning**. This is a guided review, distinct from **Start Sprint**. It moves
ticket by ticket through a focused planning room:

- the complete ticket and its acceptance examples are the primary content;
- dependencies, readiness, forecast, delivery assignment, and required evidence are
  visible without opening engineering tools;
- a side conversation addresses one explicitly selected team member at a time
  and shows concise, named replies on the ticket timeline;
- questions are resolved interactively with the owner;
- agent-recommended edits appear as a business-readable proposal that the owner
  can accept wholly, accept in part, edit, or reject; and
- the ticket fields remain directly editable beside the conversation. Every agent
  request records the exact owner-visible ticket snapshot it received; if the owner
  edits that draft or the saved ticket version changes before acceptance, automatic
  apply is disabled and the proposal must be reconciled or regenerated rather than
  overwriting newer work;
- every ticket already placed in **Next sprint** is in scope; the owner returns
  unwanted work to the Backlog before planning rather than excluding it a second
  time inside the planner; and
- the owner explicitly chooses a delivery assignee. Ordinary Lead review is
  scheduled automatically against each immutable candidate rather than configured with a
  redundant reviewer picker during MVP planning.

After the last ticket, the owner reviews the sprint goal, dependency order,
system-generated forecast range, remaining shared usage, concurrency policy,
and acceptance load. When an uncustomized sprint plan opens, AI automatically
proposes one concise outcome from the titles of the tickets in the sprint. The
goal remains directly editable, and a small AI action beside it can generate
another suggestion. A previously saved owner-written goal is never replaced
automatically. The proposal is not saved or treated as approved until the owner
reviews the text and saves the plan. The owner does not guess token counts or set
per-ticket token budgets. The planner proposes a sprint that:

- maximizes user value within the cost and risk envelope;
- respects dependencies and repository conflict zones;
- reserves capacity for rework and review;
- prevents the human acceptance queue from becoming the bottleneck;
- matches tasks to agents using capability and historical performance; and
- explains which items were excluded and why.

The resulting plan is a schedule, not just a bucket of tickets.
The owner may **Save draft & close** part-way through the guided review. Closing
with **Discard changes** restores the last saved draft, so partial planning is
captured only when the owner asks for it and the backlog never presents unsaved
picker state as fact.

### 9.5 Start sprint

Starting a sprint freezes its initial goal and plan, then enables the scheduler.
It does **not** immediately launch every ticket.

The scheduler admits work when dependencies, internal safety limits,
concurrency, environment, available account usage, and likely merge conflicts
permit it. Each run receives a versioned contract and isolated workspace. The
board updates from trusted events emitted by the local execution service and
connected systems.

### 9.6 Active delivery

The product owner primarily sees:

- what changed since the last visit;
- what outcome is being pursued;
- current stage and elapsed/cost budget consumption;
- concrete evidence produced;
- blockers requiring a decision;
- forecast changes; and
- previews ready for acceptance.

Raw agent traces remain available for audit and debugging, but they are not the
main experience.

### 9.7 Team conversations

The product owner can talk to the team without leaving StoryPointless. Ticket
and Epic conversations address exactly one selected profile per message. A
ticket defaults to its assigned implementer when available, otherwise the
business analyst (falling back to the lead); an Epic defaults to the business
analyst. Neither surface fans a message out to every configured profile.
Additional participants must be invited explicitly. Pending structured
Business Analyst questions remain independently answerable and never replace
the ordinary composer. Their question cards remain at the point where the
Business Analyst asked them, while later chat continues below in chronological
order. The
conversation surface supports direct messages, product and sprint rooms,
automatic ticket and Epic rooms, and named groups of selected profiles. Every room shows
its active context boundary—for example product knowledge, selected tickets,
sprint plan, or an exact repository revision—so the owner can see what the
agents know and change that scope deliberately.

Rooms show top-level threads as independently actionable rows with subject,
participants, linked ticket or sprint, last update, unread count, and state.
Agent replies remain inside those threads, allowing the owner to send multiple
messages immediately and return to whichever result or question needs
attention. Thread nesting stops at one reply level; deeper recursive threads
would recreate the navigation problems of general chat products.

Conversation is an interaction surface, not a second source of truth. An owner
can ask the business analyst to review a ticket, ask the lead about sequencing,
or ask a group to challenge a plan. Agents may perform bounded analysis and
return a typed action proposal. A ticket proposal shows, in business language:

- what will change before and after;
- why the change is recommended;
- affected scope, acceptance criteria, dependencies, priority, and forecast;
- disagreements or uncertainty from other agents; and
- buttons to accept all, accept selected changes, edit, reject, or ask a
  follow-up question.

Only acceptance applies the proposal to the versioned ticket and audit log.
Chat prose never silently edits tickets, starts code work, changes permissions,
or bypasses sprint authorization. Code-changing requests raised in chat become
or link to governed work items. The MVP needs messaging, context-bound rooms,
mentions, proposals, and unread/action state—not calls, presence theatre, emoji
ecosystems, or a general Slack replacement.

Interactive turns have a visible bounded lifecycle. A hung response is interrupted
and becomes a retryable authored error; the UI never presents an unbounded spinner as
progress. Only one response consumes the local Codex event stream at a time in the
initial implementation.

### 9.8 Blocking and escalation

An escalation should contain:

- the decision required;
- why work cannot safely continue;
- two or three concrete options;
- cost, product, and risk implications;
- the agent's recommendation; and
- what the scheduler can continue in parallel.

The system deduplicates repeated questions and routes them to the responsible
human. A blocker is an explicit condition on a work item; it need not become a
permanent board column.

### 9.9 Worktrees, integration, verification, and review

Every code-changing implementation run receives its own Git worktree and branch
from a recorded local-trunk commit. Thirty implementation runs therefore have
thirty isolated writable worktrees; no implementer writes directly to the trunk
or another ticket's workspace. Business-analysis and planning runs can use a
read-only repository snapshot and do not need writable worktrees.

Integration happens continuously as candidates become ready, not in one risky
merge at the end of the sprint:

1. The implementer creates a candidate commit and runs fast deterministic checks
   in its ticket worktree.
2. Independent Tech Lead reviews run in parallel against detached read-only
   workspaces pinned to each immutable candidate commit.
3. Approved candidates enter a StoryPointless-owned local merge queue, which
   orders them by dependencies and replays each one onto the latest trunk in a
   separate integration worktree.
4. A conflict becomes a visible **Resolving conflict** integration activity. An
   internal Integrator may resolve mechanically or semantically unambiguous overlap
   inside that detached worktree. Material product ambiguity pauses with **Needs your
   input**; no agent may silently choose it or push directly to trunk.
   Because conflict resolution changes the merge result, the Tech Lead then
   re-reviews that exact integrated revision. A clean merge preserves the earlier
   candidate review and does not repeat it.
5. The preview is built from the integrated commit and the acceptance room displays
   its immutable identifier.
6. Human acceptance authorizes StoryPointless to advance local trunk to that
   exact commit. Agents do not perform this promotion themselves.

Implementation and immutable-candidate review remain parallel. The local MVP
allows one reviewed candidate at a time to occupy integration, conflict resolution,
or post-conflict re-review. Ready for Demo releases that serial lane, so other
approved candidates continue integrating in backlog-rank and completion order.
Multiple demo candidates may therefore be prepared from the accepted trunk current
at their integration time.

If trunk advances before an integrated candidate is accepted, the queue must
stop its stale preview, re-integrate it, and repeat demo preparation. A clean
re-integration retains the immutable candidate review; conflict resolution requires
focused Tech Lead re-review. Materially changed behavior requires a refreshed
preview and acceptance; the product must not treat approval of an older candidate
as approval of a different commit. Rejected candidates retain their worktrees for
revision. Accepted worktrees can be removed after a configurable recovery period
because their commits and evidence are durable.

Before resuming implementation after a post-conflict review return or Product
Owner demo feedback, StoryPointless validates that the preserved ticket workspace
is clean and still points to the immutable candidate, then fast-forwards its ticket
branch to the exact reviewed integrated revision. This host-owned handoff preserves
accepted trunk work and the Integrator's resolution as the baseline for the next
candidate without changing the earlier candidate record. The continuation prompt
states that the baseline was refreshed so the Implementer treats the current files
as authoritative. A dirty, divergent, missing, or unverifiable workspace fails
closed for recovery rather than asking an agent to infer or rewrite Git history.

Implementation completion therefore triggers fast deterministic checks first.
An independent review agent then receives the contract, exact immutable candidate
diff, relevant decisions, and evidence—but not the implementer's unverified
conclusions. Integration consumes only approved candidates. Conflict resolution
creates a changed integrated revision and therefore requires focused re-review.

Review can request changes, reject the result, or attest that specified gates
passed. High-risk items require a stronger independent review profile or human
technical review because two Codex turns can still make correlated mistakes.

Reviewer findings are durable, author-attributed ticket comments linked to the
exact candidate revision. Blocking findings return the implementation run to
active work; informational findings remain visible without changing state. The
reviewer requests changes only when a concrete material defect independently
justifies another implementation, integration, and review cycle. Cosmetic
whitespace, formatting, spelling, naming, comment phrasing, code-style
preferences, and optional lint or style-only failures are informational at most,
including when the delivery note mistakenly reports such an optional check as
passing. They block only when they have a concrete consequence for behaviour,
rendering, valid syntax or structured data, an explicitly required acceptance
gate, reviewability of a material change, or security. A focused re-review
reassesses earlier feedback against this threshold rather than preserving its
blocking classification automatically. A ticket may return from review to
**In Progress** five times. On the fifth return, StoryPointless preserves the
workspace and findings but pauses automatic revision for Product Owner direction.
The Lead performs the ordinary review run automatically. A specialist reviewer can
be introduced later by policy without restoring a required reviewer field to
every planning row.

### 9.10 Product acceptance

The owner receives a focused acceptance room containing:

- a preview link;
- a plain-language explanation of what changed;
- acceptance scenarios to try;
- before/after captures where useful;
- known limitations and deferred cases;
- automated evidence and review findings; and
- buttons to accept, reject with feedback, or split follow-up work.

Acceptance tests product intent. It is not a substitute for engineering checks.
Rejecting with feedback creates a durable, author-attributed ticket comment and
a new candidate revision. While a ticket is **Ready for Demo**, the Product Owner
can comment to receive an explanatory reply without invalidating the reviewed
candidate. The comment routes to the assigned Implementer, then the latest participating
team member, then the Tech Lead when the earlier recipient is unavailable. **Request
changes** explicitly begins the revision loop. Likewise, when an item is waiting for
the owner, a new
owner comment addressed to its active assignee wakes that existing run and moves
the item visibly back to **In Progress** unless the comment is explicitly marked
as informational. The item normally resumes
the same implementation thread and isolated workspace. When feedback follows an
integrated review or demo, StoryPointless first advances that workspace to the
reviewed integrated result so accepted trunk work and conflict resolution are not
lost or repeated. The replacement must pass checks and review again before a new
preview version reaches acceptance. If context health
is poor after repeated compaction, StoryPointless starts a fresh thread with a
structured handoff while retaining the same ticket workspace. Previous previews
and feedback remain available in the item history.

### 9.11 Ticket documentation and knowledge promotion

Agents update the ticket throughout execution with milestones, discoveries,
blockers, and decisions. Before acceptance, the implementation run also proposes
a ticket knowledge change set that explains:

- what changed and how the resulting behavior works;
- why the chosen approach was used;
- alternatives considered and why they were rejected;
- product, architectural, security, operational, and cost consequences;
- how the result was verified;
- known limitations and follow-up work; and
- which existing documents or knowledge claims are now stale.

Repository documentation changes travel through the same worktree, merge,
review, and exact-commit acceptance path as code. Structured decisions and
knowledge claims remain proposals until the configured reviewer accepts them.
Reviewed claims publish automatically by default and become eligible for future
context packs, while a feature flag can require explicit Product Owner approval.
Material unstated Product Owner decisions always block the ticket rather than
publishing through this automatic path. Rejected or unverified notes remain
attached to the ticket but are not presented as truth.

Publishing reviewed ticket knowledge updates the isolated integrated revision and
the local knowledge control plane; it does not modify accepted `trunk`. Markdown
originating from a ticket reaches the accepted product workspace only when the
Product Owner approves and promotes that exact reviewed candidate.

The product owner can browse decisions or ask questions in ordinary language,
including “Why did we choose this?”, “How does this work?”, and “What alternatives
were rejected?”. Answers must distinguish current from historical decisions and
link to the originating ticket, exact code version, decision record, documents,
and evidence. When the evidence is insufficient, the answer is **Unknown** rather
than an agent-generated rationale invented after the fact.

### 9.12 Release

Deployment is not built into the MVP. The owner creates an ordinary work item
such as “Deploy this product to a cloud service.” Codex investigates the options,
asks product and cost questions, proposes the required accounts and permissions,
and blocks at every credential or consequential-action boundary.

When StoryPointless later introduces a dedicated release action, it must invoke
an approved, repeatable deployment workflow rather than inventing shell commands
at click time. The interface will show the target environment, included changes,
migrations, risk tier, health checks, and rollback plan before approval.

### 9.13 Retrospective

At sprint end, the system generates an evidence-based retrospective:

- forecast versus actual cost and time;
- accepted versus rejected work;
- first-pass acceptance and rework;
- blocker and intervention patterns;
- agent routing performance;
- escaped defects or rollbacks;
- context that was missing or stale; and
- suggested policy, knowledge, and backlog changes.

Ticket Implementers and reviewers contribute immutable free-text observations
and possible action candidates throughout delivery. Those candidates are
evidence, not separate Product Owner decisions. When the sprint completes, one
read-only Business Analyst retrospective-facilitation turn receives the frozen
sprint evidence, existing Ways of working, earlier retrospective decisions, and
active Backlog scope. It groups differently worded candidates by the decision
the Product Owner would take, removes work already covered elsewhere, and
returns zero to five final actions. Each final action names its destination and
expected measurable effect and links to every supporting source observation, so
recurrence remains visible without creating repeated decisions.

The synthesis is durable and version-safe. An interruption can be retried
without losing or rewriting the source notes; an invalid structured result fails
safely. If Codex remains unavailable, the Product Owner may explicitly continue
without AI suggestions. Synthesis never accepts an action, changes Ways of
working, or creates Backlog scope automatically.

Action items have an owner, due condition, and expected measurable effect. The
next retrospective checks whether each action improved the relevant metric.
Retrospectives live beside Reports in a dedicated **Improve** navigation
section rather than being mixed into the reference knowledge base. Decisions
and validated lessons may still promote into Knowledge after owner review.
Opening Retrospectives selects the latest completed sprint when one exists;
the active sprint is used only until the product has completed its first sprint.
The sprint picker identifies each retrospective as **Needs conclusion**,
**Concluded**, or **In progress**, so the sprint's completed state cannot be
mistaken for the retrospective's conclusion state.
An active sprint presents a read-only preview of accumulating evidence and
explains that final actions will be consolidated after completion. It does not
offer accept, dismiss, bulk-decision, or Product Owner proposal actions until
the sprint is complete.

After the sprint is complete, the final synthesis has completed or been
explicitly skipped, and before its retrospective is concluded, the Product
Owner can add a proposal directly from the Retrospectives view. They
choose whether it changes **Ways of working** or creates a **Backlog ticket**.
The proposal is attributed to the Product Owner and joins the same reviewable
decision queue as agent suggestions; it is not applied silently. Accepting a
ways-of-working proposal updates the inherited verified page. Accepting a
ticket proposal creates the backlog ticket and immediately opens the standard
Business Analyst refinement flow so questions and proposed ticket details
remain reviewable. Every proposal must be accepted or dismissed before the
retrospective can be concluded. A concluded retrospective presents its accepted
decisions as a read-only history with their destination, author, decision date,
and created ticket reference where applicable. Dismissed proposals contribute
to the historical summary but do not appear as adopted changes.

## 10. Workflow and state model

### 10.1 Product-owner workflow

| State | Meaning | Entry requirement | Exit evidence |
| --- | --- | --- | --- |
| Backlog | Captured and ranked product work | Desired outcome exists | Dragged into Next sprint or cancelled |
| Next sprint | Proposed sprint scope, possibly still needing detail | Owner selects the ticket while dependency ordering remains valid | Readiness passes and sprint planning is approved, or owner returns it to Backlog |
| In progress | The assigned delivery member is producing or revising the outcome | Sprint started and prerequisites are complete | An immutable candidate and initial evidence are ready for independent review |
| In review | The immutable candidate is being reviewed, waiting to integrate, integrating, or receiving focused post-conflict re-review | Implementation produces a candidate | Review and integration pass, or attributed findings return the ticket to In progress |
| Ready for demo | The owner can evaluate the actual reviewed result | Integration, required checks, and Tech Lead review pass | Owner gives feedback or approves |
| Done | Approved work is finalized and integrated into its defined delivery target | Human approval and finalization checks pass | Later regression or superseding change |
| Cancelled | Work intentionally stopped | Owner or policy decision | New work item if reconsidered |

The active sprint board exposes **Ready to Pick**, **In Progress**, **In Review**,
**Ready for Demo**, and **Done**. Candidate integration, deterministic testing, and
independent Tech Lead review are grouped under **In Review** rather than becoming
separate mechanism-oriented columns. The card translates the current substate into
plain language such as **Integrating changes**, **Checking quality**, **Tech Lead
reviewing**, or **Resolving a conflict**.

`Blocked`, `usage constrained`, `at risk`, and `attention required` are facets
and prominent filters. Making every implementation mechanism a column causes
boards to become workflow diagrams instead of decision tools. Rejected review
findings and demo feedback return the
ticket to **In Progress** with a versioned comment; approval authorizes
finalization, after which the ticket becomes **Done**.

### 10.2 State transition rules

- Agents may suggest transitions.
- Trusted integrations may automatically transition when objective events occur.
- Human acceptance and production release cannot be inferred from an agent's
  prose.
- Every automated transition records its actor, trigger, policy version, and
  supporting evidence.
- Reopening retains the previous run and contract history.

## 11. Definition of ready and definition of done

### 11.1 Starter definition of ready

A work item is ready when:

- the outcome and affected user are clear;
- acceptance examples are observable;
- material questions are answered;
- non-goals prevent obvious scope expansion;
- dependencies are linked;
- a repository and execution environment are known;
- risk and permissions are approved and system safety limits are available; and
- the item is small enough to produce a reviewable increment.

### 11.2 Starter definition of done

A work item is done when:

- acceptance checks pass;
- relevant automated tests pass;
- no new critical security or dependency findings exist;
- required code review is complete;
- the result is integrated against the current target branch;
- required operational and product documentation is updated;
- the ticket delivery note explains what changed, how it works, how it was
  verified, and its known limitations;
- material decisions record their rationale, alternatives, tradeoffs, owner, and
  applicable code version;
- the ticket knowledge change set is reviewed, with proposed claims either
  verified, rejected, or explicitly left pending;
- a preview or equivalent artifact has been accepted;
- deployment and rollback paths exist for releasable changes; and
- residual limitations are recorded as explicit accepted risk or follow-up work.

### 11.3 Policy profiles

Provide opinionated profiles rather than an empty form:

- **Prototype:** preview deployment, smoke tests, lint, basic secret scan, human
  acceptance.
- **Production web app:** tests, coverage trend, dependency and security scans,
  independent review, accessibility checks, staged deployment, health check,
  rollback.
- **Data change:** backup/restore evidence, migration dry run, backwards
  compatibility, integrity checks, explicit production approval.

Coverage should normally be a trend and risk signal, not a universal percentage
target. A high target can reward weak tests and unnecessary code.

## 12. Agent team model

### 12.1 Roles

- **Business analyst/product partner:** helps the owner clarify the problem,
  expected value, priority, scope, examples, and acceptance intent. It proposes
  product decisions but cannot silently make them for the owner.
- **Lead/planner/reviewer:** decomposes work, identifies dependencies,
  synthesizes specialist and technical input into an executable delivery plan,
  and reviews ordinary delivery against the approved contract.
- **Implementer:** changes the product and produces initial evidence.
- **Specialist reviewer/auditor:** optionally performs an additional independent
  pass for security, privacy, accessibility, or other high-risk concerns.
- **QA/product explorer:** exercises the preview through user scenarios.
- **Security reviewer:** applies threat and policy checks to higher-risk changes.
- **Knowledge curator:** proposes decisions, verified claims, and stale-content
  updates.
- **Release operator:** invokes approved workflows and monitors health signals.

One agent can hold several roles for low-risk work, but its profile and cost
history remain role-specific.

### 12.2 Elastic profile fan-out and team activity

A named teammate is a reusable Codex execution profile, not a fixed headcount or
a persistent person-shaped process. Every assignment instantiates a separate
run and Codex thread from that profile. If the owner parallelizes 30 independent
tickets through `Implementer`, 30 implementer runs exist; the owner does not need
to create 30 implementer profiles first.

Run creation and execution admission are separate. For the local MVP, the scheduler
admits every dependency-free implementation without asking the owner to guess a
concurrency limit. Account rate limits, machine resources, dependencies, and
repository integration still create observable back-pressure; these are runtime
conditions, not a claim that the AI team contains a finite number of employees.

The sidebar represents configuration only. For each reusable team member it
shows name, governed capability, model, effort, and a route to team settings. It
does not show presence dots, “idle,” or aggregate activity attached to the
member, because a profile is not a singleton process.

Execution belongs on the Sprint Board. Every ticket card shows its assigned
member, current run state, blocker or waiting reason, and context-window health
when available. A sprint-level activity summary reports working, waiting,
awaiting-owner, finished, and stopped runs. It can say **12 of 30 requested runs
are executing** and identify the limiting constraint without inventing an
inventory of unused agents. Scheduler leases track the actual runs and prevent
duplicate execution.

The owner-facing sprint lifecycle is **Planning** while a draft still has open
gates, **Ready** once its saved plan can be started, **Active** after Start
Sprint, and **Completed** after every accepted outcome is closed. Every ticket
has one chronological **Work log** that combines attributed comments with
assignment, status, blocker, review, and completion events. Permission requests,
per-run knowledge context, candidate revisions, proposed knowledge changes,
follow-up recommendations, and demo submissions appear at the point when they
occurred rather than in a separate summary rail. Comments remain writable while
the sprint ticket contract is frozen.

### 12.3 Pairing

Pairing should mean one of three explicit patterns:

1. **Plan/implement:** one agent proposes the approach; another executes.
2. **Implement/review:** one creates the change; another independently verifies.
3. **Competitive attempt:** two agents propose or implement alternatives, and a
   selector compares them.

Competitive attempts are expensive and should be reserved for high-uncertainty
or high-value work. Using two agents from the same model family may create the
appearance of independence without meaningfully reducing correlated mistakes.

### 12.4 Capability-based routing

The scheduler should route by capability, observed performance, current cost,
latency, permissions, and task risk. The user may pin an agent, but the system
should explain when historical evidence suggests a different choice.

### 12.5 Progressive trust

Agent profiles begin with narrow permissions. Successful, policy-compliant runs
can justify broader autonomy for a specific repository and action class. An
authentication-mode change, model change, major policy change, or material
failure reduces the applicable trust score until recalibrated.

## 13. Estimation, budgeting, and scheduling

### 13.1 Why tokens are not the estimate

Token totals are useful telemetry but poor product estimates because:

- Codex subscription and API billing expose different cost and quota signals;
- caching and tool execution alter billed usage;
- an inexpensive failed attempt can cause expensive rework;
- compute, CI, preview, and deployment costs may matter;
- task ambiguity dominates precise-looking token forecasts; and
- users ultimately care about accepted outcomes and budget exposure.

### 13.2 Forecast shown to the owner

Each ready item should show:

- estimated accepted cost at P50 and P90;
- estimated elapsed time at P50 and P90;
- expected human-attention minutes;
- probability of first-pass acceptance;
- risk and uncertainty labels; and
- the top forecast drivers, such as unknown API behavior or migration risk.

Underlying details may include input/output/cached tokens, tool calls, compute,
CI, and subscription/API quotas.

### 13.3 Cold-start forecast

The initial version can combine:

- contract size and ambiguity heuristics;
- repository size and test health;
- change-type classification;
- an optional low-cost planning run;
- selected agent rate information; and
- conservative fixed contingency.

The interface must label this as low confidence until enough local history exists.

### 13.4 Learned forecast

After delivery, record predicted and actual values by work type, repository,
agent profile, contract quality, policy, and outcome. Calibrate the intervals;
do not merely optimize average error. P90 estimates should actually contain
roughly 90% of comparable outcomes.

### 13.5 Execution safety limits

- Do not ask a product owner to invent a token budget for a ticket or sprint.
- Use conservative system defaults for runaway-turn, retry, elapsed-time, and
  measurable API-spend protection.
- Warn or pause when consumption is abnormal, shared account usage is nearly
  exhausted, or the cost-to-complete forecast materially changes.
- Reserve execution capacity for review and rework rather than consuming the
  available allowance on implementation alone.
- Require approval to change model class, reasoning effort, API/subscription
  billing mode, or risk tier when that materially affects usage or cost.
- Show sunk cost separately from the cost-to-complete forecast.

Advanced API-key users may configure a monetary safety ceiling in settings, but
it is not a required sprint-planning field. Internal safety envelopes remain
auditable even when they are presented as simple states such as **Normal**,
**Usage constrained**, or **Paused for approval**.

### 13.6 Live usage and context health

The MVP foregrounds remaining shared usage. It keeps separate signals rather
than collapsing them into one misleading percentage:

1. **OpenAI account allowance:** App Server can read rate-limit snapshots and
   emits `account/rateLimits/updated`, including used percentage and reset time
   when the account supplies them. This pool is shared across all runs and must
   appear globally, not as invented remaining quota for each profile.
2. **Current thread context:** App Server emits `thread/tokenUsage/updated` with
   last-turn and cumulative token breakdowns plus the model context-window size,
   and emits context-compaction items. Show **context pressure** and compaction
   count for each active run, not “intelligence remaining.”
3. **Cumulative economics:** consumed input, cached input, output, and reasoning
   tokens; API cost when calculable; elapsed time; retries; and review/rework
   usage. These never reset when a thread compacts.
4. **Internal safety status:** whether bounded turn, retry, elapsed-time, or
   measurable-spend controls are normal, nearing intervention, or paused. The UI
   need not expose an arbitrary token target to explain that protection exists.

Automatic compaction means current context headroom is not the remaining life of
the agent. Compaction summarizes older context and lets the thread continue, but
can lose detail or weaken long-running performance. A useful run indicator is
therefore **Context healthy · 1 compaction · Shared usage resets in 2h**, with
the raw measurements available on inspection. Repeated compaction can trigger a
fresh thread with a StoryPointless-generated handoff pack containing the
contract, current commit, decisions, evidence, and remaining work.

If a field is not exposed for the active authentication mode or Codex version,
the UI says **Unavailable** rather than estimating a false percentage.

### 13.7 Scheduler constraints

The scheduler considers:

- explicit work-item dependencies;
- likely overlap in files, services, schemas, and infrastructure;
- model/profile concurrency and account rate limits;
- available isolated workspaces;
- internal execution safety limits and cost-to-complete changes;
- required reviewers and independence policy;
- preview-environment capacity;
- owner acceptance capacity; and
- deadlines or release ordering.

This makes “start sprint” an authorization to pursue a goal under constraints,
not permission for unlimited parallel execution.

Dependency admission is strict. Starting a sprint creates the authorised run
records, but the dispatcher starts only tickets whose prerequisites are Done.
Downstream tickets remain visible in **Ready to Pick** without consuming a
Codex turn. When an active run needs a product decision, it posts one concise,
author-attributed ticket comment, records the exact question and options, and
enters **Awaiting owner**. The Work log presents those options as selectable
answers, keeps a free-form alternative, and places the chosen text in the
Product Owner response for review before resuming. A Product Owner reply on that
ticket resumes the same run and thread. If StoryPointless relaunches while that
run is active, it preserves and explicitly resumes the same Conversation and
ticket workspace, then starts only a focused continuation turn; it does not
brief the team member as though the ticket were new. If a live permission
request was awaiting a decision, relaunch keeps the run paused and keeps the
durable request actionable until the Product Owner chooses Allow or Deny.

Before completing a prerequisite, its agent posts a concise final ticket comment
containing the requirements, decisions, selected providers or contracts,
evidence, caveats, and safe downstream assumptions that the next team member
needs. Reusable cross-ticket truth is also proposed as Product knowledge.
Completion makes every fully unblocked dependant eligible and the dispatcher
starts it automatically when execution capacity is available.

The dependant agent receives its own ticket, the contracts and recent Work log
comments of its direct prerequisites, and verified Product knowledge originating
from those prerequisites. Raw transitive history is not duplicated into every
ticket. Instead, each completed ticket synthesises the prerequisite context it
used with the outcome it produced, so the next direct dependant receives one
deliberate handoff. This attributed source history is the first-release handoff
mechanism; no private cross-agent message or separately maintained summary is
required.

## 14. Knowledge and context system

### 14.1 Purpose

The knowledge system should make later work more correct with less context, not
simply accumulate prose.

### 14.2 Knowledge types

- Product vision, principles, vocabulary, and target users.
- User journeys and externally visible behavior.
- Architecture and service boundaries.
- Versioned decisions and rejected alternatives.
- Operational runbooks and release/rollback procedures.
- Repository-native build, test, launch, demo, and readiness entry points.
- Known limitations, incidents, and failure patterns.
- Verified domain facts and external constraints.
- Delivery policies and definitions of ready/done.

### 14.3 Provenance model

Every generated claim records:

- author or generating run;
- supporting sources, code locations, evidence, and decisions;
- applicable product/repository/version scope;
- verification state and verifier;
- created and last-checked dates;
- invalidation triggers; and
- confidence.

### 14.4 Ticket-to-knowledge workflow

Knowledge accumulates through controlled promotion rather than by indexing every
agent message:

1. During a run, agents post concise ticket comments for progress, discoveries,
   blockers, and requested decisions.
2. The candidate includes documentation diffs and a structured delivery note.
3. Material “why” choices become decision records rather than being buried in a
   comment or code review.
4. Review checks documentation against the exact code candidate and evidence.
5. Acceptance publishes verified claims and decisions into the product knowledge
   base and marks contradicted claims stale.
6. Later work receives only relevant, current, provenance-backed material in its
   context pack.

This creates three intentionally different layers: the full run trace for audit,
the ticket history for delivery context, and the curated knowledge base for
reusable product truth.

Unused canonical pages have empty stored bodies. Owner-facing guidance for an
empty page is presentation text, not verified knowledge and not agent context.
Before delivery, StoryPointless separates the small set of verified pages an
agent may read from a canonical destination directory. The directory explains
where product, journey, architecture, component, integration, operational, and
limitation knowledge belongs. Empty canonical pages and relevant populated pages
may receive complete proposed updates; sections may receive focused child-page
proposals. These permissions are persisted with the run and do not make empty
pages or directory descriptions part of the verified context.

Every product has a canonical **Environments** page under Operations. Verified,
non-empty Environments guidance is mandatory context alongside Overview, Product
principles, Glossary, and Ways of working. It records the repository's established
native build system and maintained build, test, launch, and demo entry points,
working-directory expectations, runtime prerequisites, readiness behaviour,
required capabilities, and known limitations. An Implementer that verifies this
guidance is absent or materially stale may propose a complete page replacement
through the ordinary candidate-bound knowledge workflow. The Tech Lead receives
the page read-only and verifies the proposal with the exact candidate before
automatic publication, unless stricter Product Owner knowledge approval is enabled.
Knowledge does not itself grant a runtime or permission.

### 14.5 Context packs

Before a delivery run starts, StoryPointless builds a small, inspectable context
pack from the contract, relevant decisions, code map, prior failures, policies,
and related work. The agent and owner can see why each item was included.
Review runs still receive their required read-only context, but do not add
repeated **Knowledge used** cards to the ticket Work log.

Page selection prioritises direct provenance, canonical subject and title
relevance, and prerequisite handoffs. Full-body term overlap is capped so a long
general page cannot become the default context and update destination merely by
accumulating vocabulary.

The inspectable **Knowledge used** record separates **Always included** mandatory
pages from pages **Relevant to this ticket**. Empty mandatory pages are shown only
as update destinations and are not described as supplied facts.

Context-pack quality becomes a first-class metric: relevance, token cost,
missing-context escalations, stale-claim rate, and reuse success.

### 14.6 Continuous maintenance

When code or a decision changes, linked claims are marked potentially stale.
The knowledge curator proposes updates during the work item, but verification
occurs through review or human approval. Deletion and supersession remain in
history.

### 14.7 Query experience

Answers should distinguish:

- verified current knowledge;
- a conclusion inferred from current evidence;
- a proposal or unverified agent note; and
- missing or contradictory information.

Every substantive answer links back to supporting decisions, code, evidence,
and work items. A “why” answer should normally state the decision, the original
problem, alternatives, tradeoffs, applicable versions, and whether the rationale
is still current. The owner can open any citation without reading raw agent
transcripts.

## 15. Reporting

Traditional burndown may still show scope movement, but it should not be the
headline measure. Useful reports include:

- cost per accepted outcome;
- median and P90 lead time from ready to accepted;
- first-pass acceptance rate;
- human intervention minutes per accepted item;
- rework and retry rate;
- forecast calibration and budget overruns;
- escaped defects, rollbacks, and time to recovery;
- blocked time by cause;
- agent success by task class, not a single leaderboard;
- knowledge reuse and missing-context rate;
- acceptance-queue age; and
- percentage of releases with complete rollback evidence.

The “efficiency over time” report should normalize for task type and risk. Raw
ticket throughput is easily gamed by splitting work into smaller items.

Reports distinguish a current operational value from an improvement trend. One
completed sprint establishes a baseline; at least two comparable sprints are
needed to suggest direction, and attribution requires a linked retrospective
experiment. Each experiment connects an observation, proposed policy/knowledge/
scope change, baseline, expected effect, and later measurement. Missing evidence
renders as unavailable rather than zero or a reassuring synthetic trend. Before
the first sprint is complete, Reports presents a clear empty state instead of
zero-valued metric cards.

Sprint performance is presented as one tabbed chronological chart rather than a
growing card or vertical stack for every measure. The Product Owner can switch
between cycle time, agent effort, and outcomes and review. Cycle time shows
elapsed wall time, while agent time is normalized per delivered outcome so sprint
size does not dominate the comparison. Duration axes use seconds, minutes, or
hours as appropriate so their tick values remain easy to scan. The latest twelve
sprints are shown by default with an option to see the full history. Selecting a
sprint reveals exact delivery, correction, and interruption values. Missing
measurements leave a visible gap, and outcome counts and correction cycles remain
visually distinct.

## 16. Trust, safety, and governance

### 16.1 Action tiers

| Tier | Examples | Default approval |
| --- | --- | --- |
| 0: Observe | Read code, tickets, docs, logs without personal data | Pre-approved scope |
| 1: Propose | Draft contract, plan, diff, or documentation | No per-action approval |
| 2: Change isolated workspace | Edit branch, run tests, create preview | Policy-controlled |
| 3: Change shared development state | Open PR, update shared test data, merge | Gate or human approval |
| 4: Production or irreversible | Deploy, migrate data, alter access, spend above limit | Explicit human approval |

### 16.2 Credential rules

- StoryPointless never asks users to paste subscription session tokens into the
  application.
- ChatGPT subscription login is offered through Codex App Server's documented
  authentication flow.
- API keys use the macOS Keychain, are never included in model context or logs,
  and can be revoked and rotated.
- Repository permissions are per product and least-privilege.
- Production credentials are separated from build credentials.
- Every Codex connection shows last use, granted scope, billing mode, and revoke
  control.

### 16.3 Supply-chain and prompt-injection controls

- Treat repository, ticket, web, dependency, and knowledge content as untrusted
  data, not authority.
- Separate system policy from retrieved context.
- Allow-list high-risk tools and outbound destinations.
- Scan patches, dependencies, generated artifacts, and logs.
- Require explicit approval for new external services or elevated permissions.
- Preserve a tamper-evident action and policy audit trail.

### 16.4 Non-technical-owner protection

The product must not translate uncertainty into a reassuring green badge. It
should explain residual risk in plain language and refuse unsupported release
paths. “All checks passed” means only the configured checks passed.

## 17. Codex and execution strategy

### 17.1 Codex-only team model

The MVP supports Codex only. A team member is a versioned execution profile,
not a different provider. Profiles can vary by:

- Codex model;
- reasoning effort;
- role and system instructions;
- available skills and tools;
- read/write/network permissions;
- context-pack policy;
- maximum turns, elapsed time, and token/usage envelope; and
- observed performance by work type.

For example, “Lead” may use a stronger model and high reasoning effort for
planning and ordinary review, while “Implementer” uses low effort for a
bounded contract. Review still receives the contract and exact candidate in a
separate Lead thread. A higher-risk ticket can route an additional pass to a
separate specialist reviewer profile.

StoryPointless supplies opinionated defaults but lets the owner change each
profile's model and supported reasoning effort from the team sidebar. Options
come from the signed-in account's live Codex model catalog so the UI does not
offer unsupported combinations. Owners may also add shared product guidance and
opt into a per-profile prompt override; resetting an override restores the
versioned StoryPointless role default. Max and Ultra are not defaults because
they materially increase usage and, for Ultra, change orchestration behaviour.

Custom team-member creation is a deferred workflow and its entry point is hidden
from Team settings in the current product. When exposed, the owner can add any
number of custom team members. A team member has a free-form name and prompt but
selects a governed capability archetype: analysis/research,
experience design, leadership/planning, implementation, independent
review/audit, QA, or knowledge/documentation. The instructions change how the member
approaches authorised work; it cannot expand permissions. StoryPointless offers
optional starting templates such as Security Auditor, Accessibility Auditor,
Market Researcher, Customer Researcher, Product Marketing Expert, SEO Expert,
DevOps/Platform Engineer, Performance Engineer, Privacy Reviewer, Technical
Writer, and Data Analyst. Removing a custom team member archives it so historical
runs and decisions remain attributable.

Codex App Server supports embedded ChatGPT sign-in as well as API-key access.
Credentials remain in the Codex harness or macOS Keychain rather than being
copied into StoryPointless records.

### 17.2 Runtime ownership and compatibility

The production app must not depend on an arbitrary `codex` executable found on
the user's `PATH`. Requiring a separate Codex installation would break the
one-app promise and make behavior depend on an unknown version, configuration,
update cadence, and authentication state.

StoryPointless instead owns a **pinned Codex runtime**. The first release ships a
known-good runtime inside the signed application. Later releases may move the
same pinned artifact into app-managed storage so the runtime can be updated
independently, but downloading and switching versions remains a StoryPointless
operation rather than a user prerequisite or an uncontrolled Codex self-update.

The App Server protocol is currently experimental and its generated schemas are
specific to the Codex version that produced them. The integration must therefore:

- compile its adapter against schemas generated by the exact pinned runtime;
- check the runtime version and initialization capabilities before every run;
- run contract tests for authentication, approvals, interruption, resumption,
  file changes, usage, and streamed events before approving an update;
- stage updates atomically and retain the previous known-good runtime for
  rollback;
- refuse an unknown or incompatible runtime with a clear recovery path; and
- isolate Codex state in a StoryPointless-managed home directory.

A user-installed Codex runtime may be selectable in developer diagnostics when
its exact version passes the compatibility handshake. It is not the default or
a supported dependency for ordinary users. Pinning protects the local protocol;
remote authentication, model availability, and service behavior still require
compatibility monitoring and timely StoryPointless updates.

### 17.3 Recommended execution topology

Use one local macOS application containing the product control plane, local
repository, and an execution-backend abstraction. The first backend can use
Codex's native macOS sandbox; a Docker Sandboxes backend can be tested without
changing ticket or orchestration semantics.

```mermaid
flowchart TB
    PO["Product owner"] --> UI
    subgraph DESKTOP["StoryPointless macOS app"]
        UI["Board, acceptance, and knowledge UI"]
        DB["Local SQLite application store"]
        ORCH["Policy, budget, and dependency orchestrator"]
        EXEC["Local execution service"]
        REPO["Local product and Git repository"]
        CODEX["Pinned, app-managed Codex runtime"]
        NATIVE["Codex Seatbelt and network sandbox"]
        SBX["Optional Docker Sandboxes backend"]
        UI --> ORCH
        ORCH --> DB
        ORCH --> EXEC
        EXEC --> REPO
        EXEC --> CODEX
        CODEX --> NATIVE
        EXEC -. "architecture spike" .-> SBX
        NATIVE --> REPO
        SBX --> REPO
    end
```

The local control plane stores intent, policy, scheduling state, normalized
events, evidence metadata, and knowledge. The execution service manages isolated
workspaces and Codex threads. Source control and checks remain local. Work pauses
when the app or Mac is unavailable. GitHub, CI, hosting, and deployment accounts
are not onboarding requirements.

### 17.4 Adapter contract

Every Codex profile and execution backend implements a normalized lifecycle:

- validate the engine, sandbox, and authentication mode;
- accept a versioned work contract and context pack;
- start, pause, cancel, and optionally resume a run;
- emit heartbeats, milestones, tool/action events, usage, and escalations;
- produce typed artifacts;
- report termination reason and remaining work;
- support credential revocation and permission reset; and
- declare which guarantees it cannot provide.

Codex App Server supplies the detailed session, item, diff, approval, and tool
events. The execution-backend interface adds workspace, process, network, and
tool-installation events that do not belong to the model session.

### 17.5 MCP role

Expose StoryPointless as a local MCP server so Codex can read assigned
contracts, retrieve approved context, post events and evidence, raise questions,
and propose state changes. MCP is an integration surface, not the internal event
model or the sole orchestration mechanism.

### 17.6 Initial integration sequence

Recommended sequence:

1. Pinned, StoryPointless-managed Codex runtime controlled through the App
   Server's bidirectional JSON-RPC protocol.
2. Local repository and isolated worktree manager.
3. Native Codex sandbox and permission bridge.
4. StoryPointless MCP tools for ticket events, questions, and evidence.
5. Docker Sandboxes feasibility spike behind the execution-backend interface.

The user never sees or installs a Codex CLI. StoryPointless launches its managed
runtime as an internal agent engine without a terminal window and renders its
sessions, streamed events, diffs, questions, and approvals through native
product UI.

### 17.7 Toolchains and sandbox options

“Install the app and nothing else” remains the desired product experience. The
minimum signed application bundle contains:

- local Git support, either through a bundled self-contained distribution or an
  embedded Git library;
- a pinned Codex runtime for the supported Mac architecture;
- the application runtime and local database;
- the native execution and permission bridge; and
- base templates and migration logic.

Git is GPLv2 software and Codex is Apache-2.0 software. Distribution must retain
the required licenses, notices, and source/offer obligations, use the Git marks
accurately, and be reviewed before release. Bundled executables must also be
signed as nested application components and included in the software bill of
materials.

There are two credible ways to supply product tools:

1. **Native managed tools.** StoryPointless ships a small baseline and, after
   human approval, downloads verified toolchains into an app-managed directory.
   Codex never installs system-wide packages. This preserves the one-install
   promise and uses Codex's macOS filesystem and network sandbox.
2. **Docker Sandboxes.** Each ticket runs in an Ubuntu microVM that already
   includes Git and common Node, Python, Go, and Java tools. Codex can use `sudo`
   inside the VM, install packages, and retain them for the sandbox lifetime.
   This provides stronger isolation but introduces a Docker account, a separate
   proprietary runtime, large images, and an Early Access dependency.

Docker Desktop being installed is not sufficient by itself: Docker Sandboxes is
a separate `sbx` product with its own daemon, installation, login, state, and
template store. Its CLI is free for commercial use, but its published binary is
proprietary and “all rights reserved”; StoryPointless must not redistribute it
inside the app without a Docker agreement. Without that agreement, the user
would need a separate supported `sbx` installation and Docker sign-in.

Docker Sandboxes is therefore a worthwhile prototype backend but not yet a
committed production prerequisite. StoryPointless should use it as the default
only after validating its embedding/licensing path, non-interactive lifecycle,
Codex App Server transport, permission-event bridge, recovery behavior, and
installer experience.

### 17.8 Docker Sandboxes spike criteria

The spike succeeds only if StoryPointless can, without exposing a terminal:

1. detect a supported `sbx` version and authenticated Docker account;
2. create, inspect, stop, resume, and remove a named Codex sandbox headlessly;
3. start Codex App Server inside the sandbox and maintain bidirectional JSON-RPC
   for a complete thread, including approvals and questions;
4. mount only the assigned ticket workspace and prove that unrelated host paths,
   localhost services, and the host Docker daemon are unreachable;
5. receive or reliably infer a blocked-network event with the exact destination;
6. implement **Allow once**, **Always for this product**, and **Deny** without
   silently broadening other sandbox policies;
7. install a package such as a JDK inside the sandbox, persist it across stop and
   resume, and discard it when the sandbox is deleted;
8. run a local product preview and publish its port to a StoryPointless web view;
9. preserve or recover all intended source changes after an app or sandbox crash;
10. run two ticket sandboxes against isolated workspaces without cross-access;
11. normalize usage, tool, file, process, and lifecycle events into the same
    schema as the native backend; and
12. pass a licensing review for the intended installation and commercial model.

Failure of criteria 3, 5, 9, or 12 disqualifies Docker Sandboxes as the default
MVP backend. It may still remain an optional advanced execution mode.

## 18. Local application architecture

### 18.1 Application modules

- **Product workspace:** local products, ownership, policies, and service links.
- **Work service:** items, contracts, dependencies, sprint goals, workflow.
- **Orchestrator:** scheduling, leases, state machine, local merge queue,
  cancellation, and retries.
- **Integration service:** Codex, sandbox, local preview, and future external
  action adapters.
- **Application store:** normalized product state plus an append-only run and
  audit timeline.
- **Evidence service:** typed artifact metadata and attestations.
- **Usage ledger:** estimated and actual tokens, turns, elapsed time, context and
  compaction telemetry, subscription quota signals, and API cost when available.
- **Knowledge service:** claims, decisions, provenance graph, context retrieval.
- **Policy engine:** permissions, gates, approvals, and transition evaluation.
- **Notification service:** local decision requests, budget alerts, and the
  acceptance queue.
- **UI projection:** native board, timeline, acceptance, and knowledge views.

Begin as a modular local application with SQLite and background jobs. The
domains should be explicit, but premature microservices would increase the very
coordination cost this product is meant to remove.

### 18.2 SQLite storage boundary

SQLite is the local application's durable operational memory, not where the
generated product's source code lives. It stores structured records such as:

- products, work items, immutable contract versions, comments, and priorities;
- workflow state, plans, dependencies, scheduler leases, and parallelism policy;
- Codex thread/run identifiers, milestones, questions, approvals, and
  interruption reasons;
- usage measurements, check results, review attestations, preview versions, and
  paths and hashes for artifacts; and
- decisions, knowledge provenance, application settings, and schema versions.

Source code and worktrees remain in local Git repositories. Large logs,
screenshots, videos, and build artifacts remain as files referenced by SQLite.
Credentials remain in the Codex credential store or macOS Keychain.

The MVP should use ordinary transactional tables for current state plus an
append-only activity/run log for audit and recovery; it does not need full event
sourcing. SQLite fits the single-user local product because it is transactional,
requires no database service, survives process restarts, supports migrations and
backups, and can atomically coordinate a ticket transition with the scheduler
lease that caused it.

### 18.3 Local execution service

- An internal execution-backend interface and scoped per-product identity.
- Separate writable Git worktree for each code-changing implementation run.
- Ephemeral integration worktree and immutable candidate commit manager.
- Separate candidate checkout for review and preview processes.
- Agent driver process.
- Tool proxy enforcing allow-lists and recording actions.
- Secret injection that prevents values entering logs or prompts.
- Resource, time, usage, and API-cost limits where measurable.
- Artifact upload with integrity metadata.
- Heartbeat and cancellation channel.

### 18.4 App shutdown and crash recovery

Closing StoryPointless suspends active work; it does not semantically cancel or
abandon the tickets. On a normal quit the application:

1. stops admitting queued work;
2. steers each active agent to reach a safe boundary and produce a structured
   checkpoint comment containing progress, changed files, completed checks,
   remaining work, and known blockers;
3. waits for a short, bounded grace period, while offering **Quit now**;
4. interrupts any remaining Codex turns and persists their completion status;
5. releases scheduler leases; and
6. preserves the thread id, isolated workspace, changes, and run metadata for a
   later resume.

The final agent-authored comment is best effort: force quit, power loss, or a
crash may prevent it. Progress events and filesystem changes are persisted
throughout the run so StoryPointless can create a clearly labelled system
recovery note from the last durable milestone, diff, and check result. On next
launch it detects stale leases and reconciles worktrees and processes.
Implementation runs suspended by the app are queued to continue automatically
in the same Conversation and workspace unless they were waiting on a permission
decision. Those runs remain visibly paused for the Product Owner, as do runs
deliberately stopped by the Product Owner until explicitly resumed. Neither
becomes `Cancelled` merely because the app closed.

Before starting another implementation turn, StoryPointless recovers a valid
completed structured result if the previous turn finished after the last
durable run update. Otherwise it explicitly resumes the persisted Conversation
in the new App Server process and sends a focused continuation instruction that
preserves prior work, decisions, and checks. A live permission request that
expired with the old process remains actionable; Allow or Deny queues the run
and its scoped decision is applied if the resumed agent still needs the matching
capability. If explicit Conversation resume reports it missing, a replacement
receives the full ticket contract and the preserved workspace, with an explicit
instruction not to restart completed work. If the ticket
workspace itself is missing, uncaptured changes are not recoverable;
StoryPointless explains that fallback in the Work log before preparing a fresh
isolated workspace.

An interrupted Tech Lead review remains bound to its exact immutable revision.
StoryPointless preserves the review run, Conversation, reviewed SHA, and
detached workspace. The revision is normally the ticket candidate, or the
integrated SHA for focused review after conflict resolution. After relaunch it
verifies or reconstructs that exact
checkout, recovers a completed structured review result when available, and
otherwise explicitly resumes and continues the same Conversation. A live
permission request that expired with the old process keeps the review paused
until the Product Owner decides, and that decision or an existing matching
scoped grant applies to the continuing run. Relaunch alone never causes
review to repeat. An immutable candidate review is reconstructed directly; a new
integration and focused re-review are required only when an exact post-conflict
revision is missing, changed, or cannot be verified, and that fallback is
explained in the ticket Work log. **Ready for Demo**
candidates keep their reviewed revision across relaunch; only the owned demo
process stops.

### 18.5 Event examples

- `contract.approved`
- `run.queued`
- `run.started`
- `run.heartbeat`
- `run.checkpoint_requested`
- `run.interrupted`
- `run.resumed`
- `milestone.reported`
- `question.raised`
- `budget.threshold_reached`
- `artifact.created`
- `candidate.created`
- `integration.queued`
- `integration.conflicted`
- `integration.candidate_created`
- `check.completed`
- `context.compacted`
- `usage.updated`
- `review.attested`
- `preview.ready`
- `acceptance.recorded`
- `documentation.change_proposed`
- `decision.recorded`
- `deployment.started`
- `deployment.healthy`
- `knowledge.claim_proposed`
- `knowledge.claim_verified`
- `knowledge.claim_invalidated`

The board is a projection of durable state and events. Agent messages alone do
not directly mutate authoritative workflow state.

### 18.6 Data retention and export

Source code, work items, contracts, events, decisions, evidence metadata, and
knowledge are local by default and exportable in documented formats. Retention
should be configurable because agent traces may contain code or sensitive
context. Redaction must not destroy the minimal audit record of who acted under
which policy. Optional encrypted sync is post-MVP.

## 19. MVP

### 19.1 MVP outcome

A solo founder can install one macOS application, describe a product, allow
StoryPointless to create its local repository, assign ready contracts to Codex
profiles, observe trustworthy progress, receive an independently checked local
preview, and accept the result—without using GitHub, hosting, or developer-facing
tools.

The product does not ask the owner to choose a predefined project type or
framework. They describe what they want to build. During refinement, the team
identifies the required tools, verification approach, and preview or equivalent
acceptance artifact. StoryPointless may warn, request an approved managed tool,
or block when the current environment cannot safely deliver it; accepting an
arbitrary goal is not the same as falsely guaranteeing every stack.

The first engineering fixture will be a browser-based product because it gives
the walking skeleton a clear local link and feedback loop. That fixture validates
the platform—it is not a permanent product-category restriction in the UI.

### 19.2 Golden path

1. Install and open the signed macOS application.
2. Describe the product; StoryPointless creates a local directory and repository
   and lets the lead profile propose the initial structure.
3. Add a Codex teammate through the embedded ChatGPT sign-in flow.
4. Review the proposed business analyst, lead, implementer, and reviewer
   model/effort profiles and the global/profile parallelism policies.
5. Create a work item with AI-assisted acceptance criteria.
6. Pass a simple definition-of-ready checklist.
7. Groom the backlog interactively, then use **Start Sprint Planning** to review
   candidate work ticket by ticket with agent feedback and proposed edits.
8. Review a system-generated forecast and remaining shared usage, then start a
   one-item sprint without choosing a token budget.
9. The internal execution service creates an isolated worktree and starts the
   pinned, app-managed agent engine.
10. The board streams normalized milestones, usage, questions, and artifacts.
11. Fast local deterministic checks run in the ticket worktree.
12. Full checks and separate reviewer threads inspect immutable ticket
    candidates in parallel.
13. The local merge queue integrates approved candidates against the latest
    local trunk; conflict-resolved results receive focused re-review.
14. The owner opens a local preview link for the same commit, comments with
    changes if needed, sees
    the item return to active work, and then accepts a later preview revision.
15. The system drafts the ticket delivery note, documentation diffs, decisions,
    and knowledge changes; review and acceptance publish verified material.
16. The owner asks why a material choice was made and receives an answer linked
    to its decision, ticket, exact commit, and evidence.
17. If the owner wants the product online, they create a deployment work item;
    it is not an onboarding step or special MVP integration.

### 19.3 Included

- Native macOS application distributed outside the Mac App Store as a signed and
  notarized build.
- One local product workspace and local Git repository.
- Product and repository creation without an existing codebase.
- Local Git support, a pinned app-managed Codex runtime, and an execution
  backend.
- Separate backlog/refinement workspace and simplified sprint board with Ready
  to Pick, In Progress, In Review, Ready for Demo, and Done columns.
- Work items, contract versions, acceptance criteria, dependencies, and comments.
- A business-analyst-proposed starter backlog with individually accept, edit,
  and rejectable tickets and a visible dependency graph.
- AI refinement for one item at a time.
- Whole-sprint planning with an owner-controlled goal, capability-based
  assignments, dependency execution waves, forecast ranges, and readiness risks.
- Context-bound team conversations: profile DMs, product/sprint/ticket rooms,
  simple groups, mentions, and typed ticket-change proposals whose accepted
  diffs alone mutate source-of-truth records.
- One active sprint; every assigned item receives a visible run, and every
  dependency-free implementation is admitted in parallel for the first local MVP.
  Account, machine, and safety back-pressure remain explicit runtime conditions rather
  than a Product Owner concurrency setting.
- Internal local execution service; no separate runner installation or UI.
- Embedded Codex App Server adapter with ChatGPT sign-in.
- Local commits, diffs, checkpoints, tests, and preview evidence.
- Separate implementation worktrees and a StoryPointless-owned local merge queue
  that promotes only the exact checked, reviewed, and accepted candidate.
- Realtime run state and a per-ticket Work log combining comments with audit events.
- Configuration-only Team sidebar plus ticket-level Sprint Board activity with
  working, waiting, blocked, reviewing, and awaiting-owner runs and the reason
  execution is constrained.
- Graceful suspension on normal app quit and recovery of interrupted work after
  restart or crash.
- System-managed run safety limits plus context-health, compaction, cumulative
  token/economic, and available shared account-rate-limit telemetry; no required
  PO-entered token budget.
- Definition-of-ready and definition-of-done profile.
- Human decision request and local acceptance room.
- Per-ticket delivery notes and reviewed product/technical documentation diffs.
- Versioned decision records and a basic provenance-backed knowledge browser and
  natural-language query experience.
- An **Improve** section with evidence-based sprint retrospectives and basic
  reports for lead time, usage per accepted outcome, first-pass acceptance,
  interventions, rework, defects, and missing context. Retrospective actions are
  measurable experiments linked to later report outcomes.

### 19.4 Explicitly not included

- Full Confluence-style collaborative document editor.
- Arbitrary board and workflow configuration.
- Portfolio roadmaps, OKRs, advanced permissions, or enterprise identity.
- Large agent/model marketplace or automatic model arbitrage.
- Multi-repository changes.
- Autonomous production credential creation.
- General cloud-infrastructure provisioning outside a constrained template.
- Fully automatic retrospective action execution.
- Native billing for resold model tokens.
- GitHub, hosted CI, hosting-provider, or deployment integration.
- Guaranteed support for arbitrary languages and frameworks before the sandbox
  and managed-toolchain strategy is validated.

### 19.5 MVP release guardrail

The MVP ends at an accepted local increment. A request to deploy is a normal
ticket whose implementation can ask questions and request scoped permissions,
but StoryPointless must not imply that arbitrary agent-led deployment is already
a safe, repeatable release capability. A dedicated release action comes only
after a deployment path has been configured, verified, and made reversible.

## 20. Roadmap after MVP

### Phase 1: Trustworthy single-agent delivery

- Golden path above.
- Validate work-contract readiness and acceptance experience.
- Measure whether progress events reduce user supervision.
- Validate reviewed ticket documentation, decision capture, and basic sourced
  “why/how” answers.

### Phase 2: Multi-agent coordination

- Multiple implementation and review adapters.
- Capability histories and task routing.
- Dependency/conflict-aware scheduler.
- Parallel work, review queues, and merge sequencing.
- P50/P90 forecasting calibrated on product history.

### Phase 3: Compounding knowledge

- Provenance graph and context-pack inspection.
- Staleness detection linked to code and decisions.
- Advanced historical, contradictory, and impact-aware knowledge queries.
- Retrospective recommendations tied to measurable outcomes.

### Phase 4: Broader founder platform

- Managed preview and hosting templates.
- Visual and synthetic-user QA.
- Customer feedback intake and roadmap linkage.
- Agency/multi-product operation.
- Constrained paths for less technical owners.
- Optional encrypted sync, remote monitoring, and customer-cloud execution.

### Phase 5: Ecosystem

- Public adapter SDK and certification tests.
- Agent and policy marketplace.
- Enterprise controls and customer-cloud deployment.
- Aggregate privacy-preserving agent/task benchmarks.

## 21. Success metrics

### North-star candidate

**Accepted product outcomes released per owner-hour**, constrained by no increase
in severe escaped defects or rollback rate.

This captures the intended removal of coordination work while resisting raw
ticket-throughput gaming.

### Activation

- Time from signup to successful diagnostic run.
- Percentage completing the sandbox diagnostic, Codex sign-in, initial product
  creation, and local preview.
- Percentage creating a ready work contract.
- Percentage reaching first accepted preview within 24 hours.

### Value

- Weekly accepted outcomes per active product.
- Owner minutes per accepted outcome.
- First-pass product acceptance.
- Cost per accepted outcome.
- 4-week retained active products.

### Trust

- Percentage of status transitions backed by objective evidence.
- Budget overrun rate.
- Unauthorized-action attempts blocked.
- Release rollback and severe escaped-defect rate.
- Questions users answer confidently without opening raw logs.

### Learning

- Forecast calibration by confidence band.
- Missing-context escalations per run.
- Verified knowledge reuse rate.
- Reduction in repeat failure patterns.
- Retrospective actions with measured improvement.

## 22. Business model

### 22.1 Recommended initial model

Charge for the local orchestration and governance product, not a percentage of
token spend:

- monthly product-space subscription;
- included concurrent-run allowance;
- higher tiers for more concurrent runs, history, policies, and environments;
- users bring a compatible ChatGPT plan or OpenAI API account.

This keeps OpenAI usage outside StoryPointless's gross margin and reduces
working-capital risk. Hosted execution can later add compute charges.

### 22.2 Possible tiers to test

- **Builder:** one product, one repository, one concurrent run, core policies.
- **Studio:** several products, multiple agents, higher concurrency, advanced
  knowledge and reporting.
- **Team:** multiple humans, approval policies, audit export, customer-cloud
  runners.

Do not finalize prices before learning the value of an accepted outcome and the
support burden of failed runs.

### 22.3 Economic risks

- BYOK lowers gross-cost exposure but increases setup and support complexity.
- Subscription-based local execution has plan-specific limits and terms.
- OpenAI model, plan, and API-price changes can invalidate estimates.
- Non-technical customers may create high support costs around repositories,
  domains, cloud accounts, and failed deployments.
- If users still spend substantial time supervising raw agent output, willingness
  to pay for the orchestration layer will be weak.

## 23. Major reservations and mitigations

### 23.1 Incumbents already own the obvious workflow

**Risk:** Jira, Linear, and GitHub can copy board-level features and already have
the work and repository graphs.

**Mitigation:** validate the end-to-end founder outcome, economic control, safe
acceptance, and model/effort performance history. Integrate with incumbents if
replacement is not necessary; do not make data migration the first hurdle.

### 23.2 The target user may be unable to verify the product

**Risk:** A non-engineer can approve appearance while missing security,
correctness, operability, or data-loss risks.

**Mitigation:** start with technically literate owners, constrained stacks,
strong deterministic gates, independent review, plain-language residual-risk
disclosure, reversible releases, and escalation to a human expert for high-risk
changes.

### 23.3 “AI team roles” may become cosmetic

**Risk:** Giving models titles creates false confidence without distinct tools,
context, independence, or measured capability.

**Mitigation:** model roles as capability and policy profiles; show observed
performance by work class; test review independence.

### 23.4 Cost estimates may look more precise than they are

**Risk:** Repository state, ambiguity, failures, model behavior, and runtime
variability create fat-tailed costs.

**Mitigation:** ranges, confidence, comparable-history explanations, hard limits,
re-estimation after planning, and calibration reports.

### 23.5 Parallel work can reduce throughput

**Risk:** More agents create merge conflicts, duplicated foundations, review
queues, and inconsistent decisions.

**Mitigation:** WIP limits, code-conflict prediction, shared-foundation tasks,
dependency-aware admission, and integration checks against the current target.

### 23.6 Generated knowledge can become confident misinformation

**Risk:** Agents cite their own stale summaries, reinforcing errors over time.

**Mitigation:** typed knowledge, provenance, verification states, invalidation,
contradiction detection, and inspectable context packs.

### 23.7 Authentication and subscription assumptions may fail

**Risk:** Codex authentication, model availability, subscription entitlements,
and App Server behavior can change independently of StoryPointless.

**Mitigation:** use only documented Codex integration and authentication
surfaces, pin and compatibility-test bundled runtimes, never extract session
tokens, retain an OpenAI API-key path, and recheck terms before marketing plan
compatibility.

### 23.8 Release automation concentrates risk

**Risk:** A single friendly button hides production credentials, migrations,
and irreversible actions.

**Mitigation:** preconfigured release workflows, environment separation,
explicit action tiers, health gates, progressive rollout, and tested rollback.

### 23.9 The board may optimize spectacle

**Risk:** Cards moving in real time looks impressive but may conceal stalled,
low-quality, or unnecessary work.

**Mitigation:** design the default view around goal progress, decisions, evidence,
budget, acceptance queue, and risk. Animation is secondary.

## 24. Product ideas worth exploring

### 24.1 Shadow sprint

Before spending heavily, agents perform read-only planning and contract checks.
The owner sees the proposed schedule, conflicts, unanswered questions, forecast,
and likely artifacts as if the sprint had run.

### 24.2 Agent draft or sealed bid

For uncertain work, two agents independently propose approach, cost band, risks,
and definition-of-done additions. The owner or lead selects a plan without
paying for two full implementations.

### 24.3 Intervention inbox

A single prioritized queue of decisions, preview acceptances, permission
requests, and budget exceptions across all active work. Every item states the
cost of delay.

### 24.4 Confidence budget

The owner allocates not only money but desired confidence. The system recommends
additional testing, independent review, or staged rollout when the confidence
target is higher.

### 24.5 Product constitution

A concise, versioned set of non-negotiable product principles and constraints
automatically included when relevant. Proposed changes require explicit owner
approval.

### 24.6 Capability passport

Each agent profile shows tasks attempted, first-pass acceptance, review defects,
cost distribution, intervention rate, and permission tier by repository and work
class. Avoid a universal score.

### 24.7 Decision-aware conflict detection

Detect not only files likely to conflict but work items that assume contradictory
product or architecture decisions.

### 24.8 Accepted-cost simulator

Let the owner compare a cheaper implementer plus stronger review against a more
expensive implementer, using actual rework history rather than list prices.

### 24.9 Proof-of-done bundle

Every accepted item exports a compact bundle containing the contract, diff,
checks, review attestation, preview evidence, human acceptance, decisions,
actual cost, and release record.

### 24.10 Retro experiments

Turn a retrospective action into a measurable policy experiment, such as
“require concrete error-state acceptance examples for payment work for the next
five items,” then compare outcomes.

## 25. Validation plan

The highest-risk assumptions are product and trust assumptions, not whether a
Kanban board can be built.

### 25.1 Questions to validate

1. Will target users adopt a dedicated local product-delivery application rather
   than operating agents directly in their existing tools?
2. Is their main pain requirements, coordination, verification, cost, release,
   or context?
3. Can they confidently accept a preview using the proposed evidence?
4. Does a single self-contained installation genuinely remove setup anxiety?
5. Will users accept hard pauses for budget and permissions?
6. Do they value sprint cadence, or would a continuous outcome queue fit better?
7. Will they trust model-and-effort recommendations over choosing Codex settings
   manually for every ticket?
8. What is the smallest release scope users will allow the system to operate?

### 25.2 First validation artifact

Build a high-fidelity, mostly simulated prototype of one complete journey:

- idea entry and AI refinement;
- ready contract and forecast;
- sprint plan;
- live board with an escalation and budget update;
- evidence-backed verification;
- preview acceptance;
- release confirmation; and
- retrospective with one proposed process experiment.

Use realistic failures, not an all-green happy path. Test it with 8–12 people in
the primary segment before building the orchestration backend.

### 25.3 Concierge pilot

For three design partners, manually orchestrate real coding agents behind the
prototype. Record owner time, interventions, actual accepted cost, retries,
review findings, and release confidence. The manual work will reveal the event
model and policy needs better than speculative infrastructure.

### 25.4 Go/no-go signals

Proceed to the automated MVP if:

- at least half of qualified testers strongly prefer the unified outcome view to
  operating Codex and local files directly;
- design partners can accept real increments without routinely reading raw agent
  transcripts;
- the contract and evidence model catches meaningful omissions;
- owner intervention time falls over repeated items; and
- at least three partners will pay for continued use.

Reframe or stop if users mainly want a thin Linear/Jira integration, if safe
acceptance consistently requires an engineer, or if Codex's native experiences
make the control plane redundant.

## 26. Initial delivery backlog

The backlog is ordered to retire product risk before technical scale risk.

### Discovery sprint 0

| ID | Item | Acceptance signal |
| --- | --- | --- |
| SP-001 | Recruit 8–12 target users | Participants match the primary segment and have shipped with a coding agent |
| SP-002 | Interview current workflow and failures | Evidence identifies the dominant coordination and trust jobs |
| SP-003 | Prototype end-to-end founder journey | Clickable flow includes ambiguity, a blocker, verification, rejection, and release |
| SP-004 | Test positioning and working title | Users can accurately explain the product without “AI Jira” prompting |
| SP-005 | Run three concierge deliveries | Each produces an accepted or explicitly rejected preview with complete economics |
| SP-006 | Validate Codex auth and embedding | Written matrix for ChatGPT sign-in, API billing, storage, revocation, pinned runtime compatibility, update, and rollback |
| SP-007 | Decide execution backend boundary | Native Codex sandbox and Docker Sandboxes spikes are compared against security, UX, recovery, and programmatic-control criteria |

### MVP foundation

| ID | Item | Acceptance signal |
| --- | --- | --- |
| SP-101 | Signed macOS application and local workspace | One notarized installation opens a product workspace without external developer tooling |
| SP-102 | Local product and repository creation | New product creates a recoverable local Git repository without GitHub or an existing codebase |
| SP-103 | Versioned work items and contracts | Active run always links to an immutable approved contract version |
| SP-104 | Fixed workflow and policy engine | Invalid transitions are rejected with an understandable reason |
| SP-105 | Durable activity and run timeline | Ticket transitions and run events are auditable and current state survives restart without requiring full event sourcing |
| SP-106 | Local execution supervisor | App can start, observe, cancel, recover, and clean up bounded child processes |
| SP-107 | Isolated execution workspace | Each code-changing implementation run uses its own branch/worktree; planning is read-only and review is pinned to an immutable candidate checkout |
| SP-108 | Pinned Codex App Server adapter | Exact-version schemas, embedded sign-in, and JSON-RPC start a bounded run and emit normalized events and artifacts; update and rollback tests pass |
| SP-109 | Secrets and log redaction | Test credentials never appear in prompt, event, artifact, or application logs |
| SP-110 | Realtime board projection | Trusted events update state without agent prose directly mutating authority |
| SP-111 | Sprint activity projection | Thirty parallelized tickets produce thirty visible board runs with assignments, active/waiting/blocked/reviewing state, context health, and an explanation of scheduler constraints |
| SP-112 | Graceful suspension and recovery | Normal quit requests a checkpoint then interrupts; restart preserves work and can reconcile and resume unexpectedly interrupted runs |
| SP-113 | Local merge queue | Independently reviewed candidates integrate continuously against latest trunk in a separate worktree; conflicts are visible, resolved integrations receive focused re-review, and only the exact checked, reviewed, and accepted commit advances trunk |

### MVP outcome loop

| ID | Item | Acceptance signal |
| --- | --- | --- |
| SP-200 | Proposed starter backlog | **Autosuggest Tickets** starts one recoverable BA suggestion session; truthful temporary placeholders become rationale-backed ticket proposals with acceptance criteria, forecasts, and dependency edges, and the owner can accept, edit, discuss, or reject each without rejected work becoming scope |
| SP-201 | Business-analyst-assisted refinement | Owner and BA profile clarify value, priority, scope, examples, and acceptance criteria through accept/rejectable diffs |
| SP-202 | Safety controls and live usage telemetry | Run warns or pauses on abnormal consumption; UI foregrounds remaining shared account usage and distinguishes per-thread context/compactions, cumulative economics, and internal safety status without requiring a PO-entered token budget |
| SP-203 | Human decision and permission request | Agent raises a structured, deduplicated decision or scoped permission request in the ticket; the Product Owner sees its plain-language purpose first and can disclose the exact action and additional access, then chooses **Allow once**, **Always allow for this product**, or **Deny**, and the live turn continues without a terminal or global binary whitelist. Before asking for runtime access, the agent inspects the foreseeable executable, traversal, symlink, shared-library, compiler, SDK, or package boundary and submits one reviewable request for the smallest coherent capability; it does not make the Product Owner approve a runtime one file or directory at a time. Agents consult verified Environments guidance and prefer the repository's established native build system and shortest maintained, purpose-named entry point over a shell chain. An Implementer may add a version-controlled, non-interactive task or script only when it represents a coherent reusable workflow, never to substitute an unrelated package manager or runtime, conceal operations, or broaden approval; verified operational changes produce a complete Environments proposal. The persisted request shows the decision in place without adding a duplicate Product Owner message to the Work log. If the app relaunches first, the preserved run remains paused and resumes its Conversation only after that decision; an interrupted leaf request is replaced with one consolidated capability request rather than restarting the cascade. A saved grant is limited to the same command and requested capability, automatically applies to matching future ticket workspaces in that product, remains auditable in each ticket Work log, and can be revoked in Product settings; file-change approvals remain one-time |
| SP-204 | Local checks and evidence ingestion | Test results and artifacts are linked and independently verifiable |
| SP-205 | Review pass | Lead receives the contract and exact immutable ticket candidate in a separate checkout and records a typed attestation in parallel with other candidate reviews; conflict resolution triggers focused review of the changed integrated revision, and policy can require an additional specialist reviewer for higher-risk work |
| SP-206 | Preview acceptance loop | Owner opens a local link for the attested commit, comments with traceable feedback, sees the item return to active work, and accepts or rejects a versioned replacement preview |
| SP-207 | Deployment work-item conversation | A deployment request asks structured questions and blocks before credentials or consequential actions |
| SP-208 | Proof-of-done bundle | Accepted item exports intent, evidence, economics, decisions, and release record |
| SP-209 | Ticket documentation and knowledge change set | Every candidate includes a sourced delivery note, required documentation diffs, decision records, proposed claims, and stale-claim impacts; review controls promotion |
| SP-210 | Core outcome reporting | Lead time, accepted cost, intervention, and first-pass acceptance are correct |
| SP-211 | Basic provenance-backed knowledge query | Owner can ask why or how, receive a current answer linked to decisions, tickets, exact commits and evidence, or receive an explicit unknown when support is insufficient |
| SP-212 | Context-bound team conversations | Owner can DM profiles or use product, sprint, ticket, and simple group rooms; agent work returns typed, business-readable action proposals and only an explicit accepted diff mutates a ticket or authorizes governed work |
| SP-213 | Ticket attachments and visual delivery artifacts | Owners and agents can attach versioned files to a ticket without storing large blobs in SQLite; images, PDFs, and other supported artifacts open in an accessible in-app viewer; UX contracts require a reviewable visual artifact such as wireframes, screenshots, or an interactive prototype before reaching Ready for Demo; the board and ticket show the primary artifact and preserve its author, candidate revision, provenance, and history |
| SP-214 | Managed one-click demo launcher | An agent proposes a typed, candidate-bound demo specification for a loopback browser preview, macOS app, review artifact, or bounded captured result; StoryPointless validates and smoke-tests it against the exact integrated revision before **Ready for Demo**, runs each command through a candidate-scoped connection to the pinned App Server with the exact cache-backed preview as the only writable root under a broad-runtime-read, localhost-only permission profile rather than a binary/path allow-list, allocates the loopback port, waits for typed readiness, opens the correct result from one **Demo** button, reports actionable root failures rather than only trailing test summaries, offers **Retry demo preparation** without requiring a comment or repeating implementation/review when only the post-review smoke preparation failed, and stops the owned App Server command session on **Stop demo**, feedback, approval, product switching, shutdown, or connection loss while removing the preview checkout after feedback or approval |
| SP-215 | Global team chat launcher | A persistent chat control is available from every primary product view and opens the same familiar conversation UI used on tickets; the owner addresses exactly one selected team member for terminology, guidance, product questions, or a request for help without navigating away; the thread is retained per product, can include an explicit summary of the current view or selected object, shows thinking, typing, unread, and failure states, and presents any proposed mutation as a reviewable action rather than changing product state silently |
| SP-216 | Git and Codex degraded-mode resilience | Startup and continuous capability checks distinguish Codex disconnected, incompatible, unauthenticated, or temporarily unreachable states from missing, damaged, or unusable Git support; the product, backlog, sprint history, knowledge, reports, and other unaffected local data remain available; only dependent actions are disabled with a plain-language reason, retry and guided repair paths are offered, interrupted runs and worktrees are reconciled without data loss, and diagnostics expose enough detail for recovery without requiring the owner to use a terminal |
| SP-217 | Action-required notifications | StoryPointless sends deduplicated macOS notifications only when the Product Owner must act—for example to answer a question, review a demo, resolve an integration failure, recover a stopped run, or decide a retrospective action; clicking a notification opens the exact product and relevant ticket, sprint, or retrospective context; resolving the action clears its notification and in-app badge; category preferences, permission-denied guidance, and quiet handling while the relevant view is already focused prevent progress chatter from becoming notification noise |
| SP-218 | Remote product-bundle sync | The Codebase view offers **Connect remote** for an optional, provider-neutral Git remote and clearly shows disconnected, ahead, behind, syncing, conflict, and up-to-date states; the versioned remote contains the complete portable product bundle—accepted source history, product definition, epics and tickets, sprint and retrospective records, knowledge, decisions, reports, delivery provenance, and referenced attachments—rather than source code alone; credentials, Codex sessions, secrets, transient worktrees, caches, and machine-specific runtime state are excluded; the owner can push or synchronize explicitly, interrupted transfers are recoverable, incoming changes are validated against the bundle schema, and divergent history is never overwritten silently |
| SP-219 | Existing Git repository import | **Create product** offers **Import Git repository** for an authenticated or public repository URL; StoryPointless clones the repository into its managed product workspace, preserves branches, history, authorship, default-branch identity, and remote provenance, then treats the imported default branch as the accepted trunk for subsequent ticket worktrees and integration; a recoverable discovery pass identifies the stack, runnable checks, existing product context, incomplete work, and likely delivery risks without modifying the clone; README files, documentation, ADRs, runbooks, and other durable guidance are classified and presented as reviewable, source-linked Product knowledge proposals with page destinations, freshness and originating commit/path metadata; accepting a proposal creates or updates canonical knowledge without deleting the original repository files, while any later consolidation or removal is an explicit reviewed change; clone, authentication, submodule, large-file, unsupported-layout, and partial-import failures remain recoverable and never leave a product that appears ready when its codebase is incomplete |
| SP-220 | Non-disruptive live Codebase updates | While the Codebase view is open, StoryPointless detects newly created or integrated commits and branch changes without requiring a manual reload; the currently visible commit list, selection, file tree, diff, and scroll position remain stable while a compact **New changes** indicator reports the number of unseen commits; selecting it reveals all pending changes together in the correct order, preserves the current selection where possible, and clearly marks the newly inserted history; repeated filesystem events are deduplicated, loading never flashes an empty state over existing content, and unavailable or failed refreshes remain recoverable without replacing the last valid snapshot |
| SP-221 | Strict role-scoped agent permission profiles | Every agent turn uses a capability-detected, named permission profile with explicit runtime workspace roots and least-privilege access: implementers can read and write only their assigned ticket worktree; Tech Leads can read the immutable candidate and relevant product context, gaining narrowly scoped write access only while resolving an authorized integration issue; BA, refinement, suggestion, and planning turns are read-only within the active product workspace. Delivery begins with Codex's minimal platform/runtime reads, the exact writable ticket root, and read-only access to the active product's central Git metadata so status, diff, history, and conflict inspection do not require Product Owner intervention. Git's shared object store makes the product the deliberate read boundary, while other products and other checked-out ticket worktree paths remain inaccessible. The agent environment disables optional Git locks, ignores user-global Git configuration, and uses a noninteractive pager; StoryPointless alone stages, commits, changes branches, integrates, promotes, and cleans up. The profile must not deny an ancestor required to traverse the assigned root, grant broad host reads as a convenience, or copy the workspace to `/tmp` to bypass isolation. StoryPointless does not discover package managers, resolve project runtimes, or grant runtime paths automatically. When a tool is blocked, the assigned agent diagnoses the executable, its foreseeable traversal, symlink and runtime dependencies, or the network boundary and uses Codex's capability-checked permission-request tool to ask once for the smallest coherent capability. A package-manager runtime request may batch its executable, link, and installation roots while excluding data, configuration, credentials, and unrelated user locations; requesting each file or directory sequentially, repeating the same approved command, adding shell wrappers, or substituting stale evidence is not acceptable recovery. Additional Homebrew, compiler, SDK, service, filesystem, or network capabilities use a scoped Product Owner decision rather than a growing binary whitelist. Product-scoped grants match an exact command and its requested capabilities while ignoring the changing ticket-worktree path only after verifying that the requested working directory is inside the assigned workspace; they never broaden into a binary-only rule. Profiles deny the StoryPointless database, other products, other ticket worktrees, credentials, `.env` files, `.ssh`, `.aws`, and other configured sensitive paths. Network access is disabled by default and any temporary or persistent grant requires an explicit Product Owner decision with visible scope and provenance. Startup and run admission verify that the installed Codex App Server supports the required permission-profile, permission-request, and workspace-root capabilities; unsupported, incomplete, or rejected isolation fails closed with a plain-language recovery path rather than silently falling back to a broader legacy sandbox. Automated adversarial tests prove the active nested ticket root remains writable and active-product Git reads succeed while Git writes, cross-product, cross-worktree, secret, database, unauthorized-network, and workspace-copy escape attempts are denied before autonomous execution is described as production-safe. |

### Post-MVP experiments

| ID | Item | Acceptance signal |
| --- | --- | --- |
| SP-301 | Second execution backend | Same contract and event tests pass through native and VM-backed execution without workflow-specific UI branching |
| SP-302 | Dependency-aware scheduler | It avoids known conflicts and enforces WIP and budget constraints |
| SP-303 | Capability-based routing | Recommendation beats user-default routing on accepted cost in a bounded trial |
| SP-304 | Advanced knowledge maintenance | Contradiction detection, impact-based invalidation, richer historical queries, and context-pack quality improve beyond the basic sourced MVP query |
| SP-305 | Forecast calibration | P50/P90 reports are measured and improve with local history |
| SP-306 | Evidence-based retrospective | Suggested experiment is tied to an observed failure and later measured |
| SP-307 | Historical sprint boards | The Sprint Board can switch between the active sprint and read-only past sprint snapshots, preserving each sprint's final ticket placement, assignments, outcomes, comments, evidence, and retrospective links |

## 27. Decisions to make next

### Recommended defaults

- **Category:** AI product delivery system, not Jira alternative.
- **First user:** technically literate solo founder.
- **Product input:** an unrestricted software goal created locally from no
  existing codebase; capability is assessed during refinement rather than by a
  project-type selector.
- **First technical fixture:** a browser-based product with a local preview and
  comment-driven revision loop, not a lasting category restriction.
- **Platform:** Apple Silicon and macOS only for the first private builds.
- **Execution topology:** self-contained local application with an internal
  runner boundary.
- **Agent:** Codex only; tickets select model, reasoning effort, role, and
  permission profiles.
- **Initial roles:** business analyst, lead, implementer, and independent
  reviewer; each profile fans out into one independent run per assignment.
- **Source control:** local only; no GitHub requirement in MVP.
- **Deployment:** a future work-item conversation, not onboarding or a special
  MVP release integration.
- **Codex runtime:** pinned and owned by StoryPointless; a separately installed
  Codex version is not required or trusted by default.
- **Installation:** one signed app remains the target; Docker Sandboxes is being
  evaluated rather than assumed.
- **Availability:** normal quit checkpoints and interrupts active turns; work is
  preserved as paused and can resume when the app reopens.
- **Collaboration:** single user for MVP.
- **Workflow:** opinionated and fixed for MVP.
- **Planning unit:** sprint; **Start sprint** is the owner-facing authorization
  action, while agent runs remain internal scheduler records.
- **Accountability:** human owner plus agent contributors.
- **Estimate:** effort, token/usage range, time, human attention, and API cost
  when available—not story points.
- **Release:** no special MVP release button; deployment begins as a governed
  work item and only becomes a reusable action after it is safely configured.
- **Architecture:** modular monolith, SQLite transactional state plus durable
  run/audit log, and a background scheduler.
- **First build:** a functional technical walking skeleton before a fully
  polished simulated interface.
- **Commercial model:** orchestration subscription with the user's own OpenAI
  account.

### Open decisions

1. Should MVP execution use Codex's native macOS sandbox with managed tool
   downloads, or require Docker Sandboxes for microVM isolation and flexible
   Ubuntu tooling?
2. What evidence lets a product-minded but non-engineering owner safely accept
   the selected class of changes?
3. Which data may be used, with consent, to improve cross-customer estimates?
4. Is StoryPointless the customer-facing name or an internal working title?

## 28. Current source notes

These sources establish the July 2026 competitive and integration boundary;
they should be rechecked before making compatibility or pricing claims.

- [Linear: AI Agents](https://linear.app/docs/agents-in-linear) documents agent
  users, delegation, human responsibility, activity, guidance, and custom agents.
- [Linear for Agents](https://linear.app/agents) presents multi-agent issue
  orchestration and integrations including Codex, Devin, Factory, and others.
- [Jira for AI-native software development](https://www.atlassian.com/software/jira/dev)
  presents Jira as a planning and orchestration layer for Codex, Claude, Cursor,
  GitHub Copilot, and MCP agents.
- [Atlassian: Rovo Dev in Jira](https://www.atlassian.com/blog/announcements/rovo-dev-in-jira)
  describes backlog-to-merge-ready pull-request execution inside Jira.
- [GitHub: Copilot agents](https://github.com/features/copilot/agents) describes
  assigning agents from issue trackers and working through pull requests and
  security checks.
- [OpenAI: Codex authentication](https://learn.chatgpt.com/docs/auth) distinguishes
  ChatGPT subscription sign-in from API-key, usage-based access.
- [OpenAI: Codex command-line options](https://learn.chatgpt.com/docs/developer-commands)
  documents the available local executable and app-server commands.
- [OpenAI: Codex App Server](https://learn.chatgpt.com/docs/app-server)
  describes the deep-integration protocol, interruption lifecycle, streamed
  events, and version-specific generated schemas. The current schema includes
  per-thread token/context updates, compaction events, and account rate-limit
  snapshots; App Server remains an experimental surface whose compatibility
  must be managed explicitly.
- [OpenAI: Unlocking the Codex harness](https://openai.com/index/unlocking-the-codex-harness/)
  recommends Codex App Server as the first-class product-integration method and
  documents bundling a pinned binary in local clients.
- [OpenAI: Codex open-source repository](https://github.com/openai/codex)
  distributes the native harness and App Server under Apache-2.0.
- [Git: About](https://git-scm.com/about.html) documents Git's GPLv2 license;
  the [Git trademark policy](https://git-scm.com/about/trademark.html) governs
  product naming and attribution.
- [Docker Sandboxes: overview](https://docs.docker.com/ai/sandboxes/) documents
  its Codex-capable microVMs, commercial-use status, installation, and Docker
  account requirement.
- [Docker Sandboxes release repository](https://github.com/docker/sbx-releases)
  publishes the proprietary `sbx` binaries and current license notice.
- [Docker Sandboxes: security model](https://docs.docker.com/ai/sandboxes/security/)
  documents the microVM, workspace, credential, and network trust boundaries.
- [Docker Sandboxes: templates](https://docs.docker.com/ai/sandboxes/customize/templates/)
  documents its Ubuntu Codex images, included Git and common language tools,
  persistent package installation, and Early Access customization model.
- [Docker Sandboxes: local policy](https://docs.docker.com/ai/sandboxes/governance/local/)
  documents deny-by-default network policy and per-sandbox allow/deny rules.

## 29. First technical walking skeleton

The first implementation milestone is a functional Apple Silicon macOS build,
not the complete board. It succeeds when one owner can:

1. launch StoryPointless without installing Codex, Git, Docker, or a database;
2. create a product from an unrestricted plain-language description;
3. use the browser-product fixture to create one locally previewable candidate;
4. refine two independent tickets with the business-analyst profile and approve
   versioned contracts;
5. configure business analyst, lead, implementer, and reviewer profiles in the
   sidebar, then see truthful ticket-level active, waiting, blocked, and reviewing
   runs on the Sprint Board;
6. start both items and observe two pinned Codex runs working in separate
   worktrees without seeing a terminal;
7. see durable milestones, questions, approvals, diff summaries, checks,
   context health, compactions, internal safety status, and available shared
   account limits without setting a token budget;
8. see independent reviewer results arrive in parallel, then watch the local
   merge queue create one exact integrated candidate without either implementer
   advancing trunk directly;
9. review the ticket delivery note, documentation changes and decision records,
   then open the loopback preview link, reject it with a ticket comment, and watch the
   affected item return to active work, and receive a replacement candidate;
10. see the replacement reviewed and integrated, then accept it;
11. ask why a material implementation choice was made and receive a sourced
    answer linked to the ticket, decision, exact commit, and evidence; and
12. quit during a subsequent run, then reopen the app and recover or resume the
    interrupted work with its workspace and history intact.

The implementation order should retire integration risk first: pinned runtime
handshake and generated schemas, sandboxed file change, process interruption and
recovery, repository/workspace management, SQLite persistence, and finally the
local merge queue, ticket-knowledge/query slice, and thin native workflow UI.
Signing, notarization, Docker Sandboxes, broad stack coverage, sophisticated
planning, and visual polish follow after this vertical slice works reliably.

## 30. One-sentence test

If StoryPointless cannot make a founder more confident about **what was built,
what it truly cost, why it is safe enough to release, and what the system learned**
than they would be with an issue tracker and a coding agent alone, it has not yet
earned the right to replace either.
