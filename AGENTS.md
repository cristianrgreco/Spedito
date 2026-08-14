# Spedito contributor instructions

These instructions apply to the whole repository.

## Product intent

Spedito is a local-first, macOS-native product-delivery application for
product owners who may not be software engineers. It preserves the useful parts
of agile delivery while hiding terminals, Git commands, Codex threads, and other
implementation machinery behind a clear owner-facing workflow.

Use the following documents as the durable source of truth:

- `docs/product-spec.md` for product behavior, terminology, journeys, and scope.
- `docs/technical-design.md` for architecture, persistence, execution, and
  recovery boundaries.
- `README.md` for the current implemented state and developer entry points.

Keep those documents accurate when a change materially alters their claims.
Record agreed future product work in the product specification rather than
leaving it only in a code comment or chat.

## Product language and workflow

Use owner-facing language consistently:

- Product owner, not administrator or operator.
- Team member, not persona, unless referring to the internal domain concept.
- Backlog, epic, sprint, ticket, conversation, work log, and product knowledge.
- Ready to pick, in progress, in review, ready for demo, and done.
- Needs your input is an inline attention state, not a separate board column.
- Integrating is an inline execution state, not a separate board column.

Capitalize these common nouns only at sentence beginnings or where grammar otherwise requires it.

Tickets are the source of truth for delivery. Agent progress, questions,
review findings, status changes, and product owner comments belong in the
ticket work log with an author and timestamp. Knowledge pages hold durable
cross-ticket information; delivery history may contain a page per ticket.

The product owner remains in control:

- AI suggestions are reviewable and versioned.
- Never silently change ticket scope, dependencies, or product decisions.
- Ask consequential product questions during refinement.
- Create research work only when the product owner requests it or agrees that
  external evidence is needed.
- A normal ticket should deliver an agreed outcome, not defer deciding what
  that outcome is.
- Follow-up tickets discovered by authorised research remain reviewable
  proposals until the product owner accepts them. Publish them only from the
  approved research outcome and preserve its epic and dependency provenance.

## Architecture

- `Sources/SpeditoCore` contains domain policy, persistence, Git
  workspaces, Codex adapters, and other UI-independent behavior.
- `Sources/SpeditoApp` contains SwiftUI presentation and application
  coordination.
- Keep workflow rules and validation in Core when they must remain true
  regardless of the presenting view.
- Keep Codex protocol details behind the existing adapter boundary.
- Prefer extending existing models and reusable views over introducing a
  second representation of the same concept.

SQLite is the local control plane. Schema changes must use durable, idempotent
migrations and work for every product. Never add migrations, fixtures, prompts,
or defaults that refer specifically to the weather-app development example.
Archived records remain available for audit history but must not leak into
active planning, dependency, or suggestion calculations.

## Agent execution model

- Refinement, suggestions, planning, and ordinary review turns are read-only
  unless their explicit contract says otherwise.
- Delivery runs use an isolated ticket worktree and `ticket/TN` branch.
- Parallel implementation happens in separate worktrees.
- Tech lead reviews run in parallel against exact immutable ticket candidates.
- Candidate integration is serialized against current local `trunk`.
- Conflict resolution that changes an integrated result requires focused Tech
  Lead re-review; clean merges retain the candidate review.
- Product owner approval promotes the integrated reviewed candidate and
  completes the ticket.
- On interruption, preserve durable run state and the ticket workspace so work
  can be resumed safely.

Do not expose raw chain-of-thought or fabricate activity. UI activity summaries
must be concise, useful descriptions derived from supported Codex events. A
missing or malformed structured agent result should fail safely with a
recoverable owner-facing explanation.

Agent permissions must remain least-privilege:

- No secrets, credential stores, unrelated products, other ticket worktrees,
  or the Spedito database in an agent context.
- Network access is off unless the product owner explicitly permits it.
- Do not discover package managers or runtime installations and pre-authorize
  their paths. Keep Codex's scoped permission-request tool available so the
  assigned agent can diagnose a blocked capability and request the smallest
  exact filesystem or network access from the product owner.
- Do not weaken sandbox or approval behavior as a convenience fallback.
- Capability-detect required runtime features and fail closed when safe
  isolation cannot be provided.

## Dependency context and ticket handoffs

Dependencies are durable delivery relationships, not placeholders for tickets
that might be invented later. When an epic plan already contains research,
design, implementation, and verification tickets, accept them as one dependency
graph before delivery. The dispatcher waits for direct prerequisites to reach
done before starting a dependant.

Every completed ticket must leave a self-contained completion handoff in its
work log. The handoff records:

- the delivered outcome and material decisions;
- selected providers, contracts, interfaces, or operating requirements;
- evidence, checks, caveats, and known limitations; and
- what direct dependant tickets may safely assume.

Reusable truth also belongs in verified product knowledge. When a dependant
runs, its context includes its own ticket contract, the contracts and recent
work log comments of its direct prerequisites, and verified product knowledge
originating from those prerequisites. Do not copy all raw transitive history
into every downstream ticket. Each completed ticket should deliberately
synthesise the prerequisite context it used with the outcome it produced, so
the next direct dependant receives a concise current handoff. Dependency links
and source work logs preserve the full audit trail.

Research-generated follow-up tickets are exceptional. If accepted tickets
already cover the downstream work, research must return no follow-up proposals;
it supplies its decision and details through the completion handoff and product
knowledge instead. A follow-up proposal is appropriate only for genuinely new
scope absent from every active ticket. If evidence materially conflicts with an
accepted ticket contract, stop for product owner input or propose a reviewable
edit rather than silently replacing, splitting, or changing that ticket.

For example, an epic to add a cat joke to weather results should normally be
planned as:

1. **T1 — Recommend a suitable content provider:** business analyst research.
2. **T2 — Design the result, loading, attribution, and unavailable states:**
   experience design that may proceed in parallel.
3. **T3 — Integrate the approved provider:** depends on T1 and T2.
4. **T4 — Verify successful, unavailable, privacy, and attribution behaviour:**
   depends on T3.

When T1 completes, it records the approved provider, request contract, content
and privacy constraints, attribution, failure behaviour, evidence, and caveats
in its work log and appropriate product knowledge. It does not create
replacement design, implementation, or verification tickets because T2–T4
already exist. T3 receives the T1 and T2 handoffs, implements the combined
contract, and leaves a new handoff for T4. If T1 instead discovers that every
suitable provider requires a materially different architecture, it asks the
product owner how to change the accepted plan; it does not hide that scope
change in a comment or duplicate ticket.

## SwiftUI and UX conventions

The first supported platform is Apple Silicon macOS. Prefer native SwiftUI and
macOS behavior unless a custom control materially improves clarity.

- Design for a non-technical product owner.
- Use sentence case for every button and menu label across the app. Preserve
  capitalization only for proper nouns and established initialisms such as AI.
- Write out "and" in button and menu labels; do not use ampersands.
- Use `.borderedProminent` as the standard style for actionable buttons. Reserve
  `.bordered`, `.plain`, `.borderless`, and `.link` for controls that genuinely
  need lower visual weight or platform-specific presentation.
- Keep primary actions visually clear; destructive actions use the destructive
  role and red text/icon treatment.
- AI actions use the established purple treatment; ordinary primary workflow
  actions use the app accent color.
- Use semantic colors and verify both light and dark appearances.
- Reuse shared table/grid geometry so headers and cells cannot drift.
- Make an entire backlog row clickable and draggable when the whole row is the
  interaction target.
- Avoid nested cards, repeated labels, decorative icons, and empty containers
  that do not add hierarchy.
- Keep ticket titles readable at compact sizes and allow two lines where the
  current design calls for them.
- Empty states should be centered in their available content area without
  forcing the enclosing view beyond the window.
- Sheets must fit a typical 14-inch MacBook display and remain usable when
  content grows. Put long content in an intentional scroll region.
- Text editors need normal, consistent content insets, visible focus, and
  correctly aligned placeholders.
- Preserve the selected product, main view, and selected sprint across normal
  relaunches when the underlying record still exists.

Completed prerequisites should not be presented as active blockers. Archived
epics and tickets should not appear as active relationships. Suggested tickets
may use temporary `S1`, `S2`, and similar references, but accepted tickets use
the single durable product sequence `T1`, `T2`, and so on.

## Making changes

- Never use Computer Use or any other GUI automation to control or inspect the
  product owner's Mac. Do not click, type, scroll, navigate apps, or capture the
  screen on their behalf. Validate through repository code, tests, durable
  state, and the required relaunch; leave visual UI inspection to the product
  owner.
- Inspect the affected implementation and nearby tests before editing.
- Search with `rg` or `rg --files`.
- Preserve unrelated work in a dirty worktree.
- Use `apply_patch` for hand-authored edits.
- Do not use destructive Git operations to clean up user changes.
- Prefer a small coherent implementation over parallel legacy and replacement
  paths.
- Do not add weather-app-specific behavior to demonstrate a generic feature.
- Add or update tests for domain rules, persistence, decoding, migration,
  recovery, and other non-visual behavior.
- Verify UI changes at representative light/dark and laptop-sized layouts when
  practical.

## Validate changes

Run the full suite with the project-local module caches:

```sh
env \
  SWIFT_MODULECACHE_PATH="$PWD/.build/module-cache" \
  CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache" \
  swift test -Xswiftc -warnings-as-errors
```

Also run:

```sh
git diff --check
```

Do not claim a change is complete if relevant tests are failing. If the full
suite cannot run, state exactly what was and was not validated.

## Relaunch the development app

Use `./scripts/relaunch.sh`. It builds, kills any existing debug
`Spedito` process, and `exec`s the new binary in the foreground. When
called from an agent command, keep the returned command session alive.

After making and validating changes that affect the app, always relaunch it
before handoff and leave it running so the product owner can inspect the result.
Do not wait for a separate relaunch request.

This is deliberately a simple development-only reset. Do not use it while
preserving an active agent turn matters; normal user-initiated app quit still
uses the asynchronous shutdown handler.

## Handoff

Lead with the user-visible outcome. Mention the files or areas changed, the
validation performed, and any real limitation that remains. Do not describe a
mock, placeholder, or hard-coded demo as completed functionality.
