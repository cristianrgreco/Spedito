# Work packet: suggested tickets carry durable T keys from the moment they are stored

## Problem

Suggested tickets use temporary `S1`, `S2` references, and acceptance copies each
suggestion into `work_items` while allocating its durable `T` key only at that
moment (`acceptTicketSuggestions` in
`Sources/SpeditoCore/Persistence/SQLiteStore+TicketSuggestions.swift`, via
`insertWorkItem` in `Sources/SpeditoCore/Persistence/SQLiteStore.swift`).

The suggestion generator deliberately makes the model cite exact ticket
references inside dependant acceptance criteria
(`Sources/SpeditoCore/Codex/CodexTicketSuggestionGenerator.swift`, "cite that
exact ticket reference in the dependant criterion"). Those citations are `S`
references, and nothing rewrites them on acceptance. Accepted tickets therefore
carry criteria pointing at keys that no longer exist.

Live evidence (Native Weather App, product workspace
`AC5E8296-6433-4228-B64B-85BFA7318A1C`): accepted ticket T3's criteria say
"Using the setup established by S1" and "the reviewed screen set from S2".
S1 became T1 and S2 became T2. A second Native Weather App product
(`D8CF8972-0F73-4827-BABF-476078681370`) has the same defect on its T2. The
numbers only coincide because the backlog was empty at acceptance; with existing
tickets, S1 could become T6 and a stale "S1" would point at the wrong ticket.

The product owner decided against rewriting `S` → `T` at acceptance time: text
the owner has read and accepted must never change afterwards. The agreed design
assigns the durable key when the proposal batch is persisted, before the owner
reads anything. This decision is settled; do not re-litigate it.

## Behavior to preserve or add

- A generated ticket-suggestion batch is persisted with final durable ticket
  keys (`T7`, `T8`, …) allocated from the product's single key sequence. The
  reference the owner reads on a proposal is the key the accepted ticket keeps.
- Cross-references between proposals in the batch — in the reference field,
  rationale, and acceptance-criteria prose — show those final keys. References
  to already-active backlog tickets keep their existing exact keys.
- Accepting a proposal creates the work item with the proposal's pre-assigned
  key and copies title, body, and criteria verbatim. No text is rewritten at or
  after acceptance.
- Rejecting a proposal, or superseding a batch by regenerating the plan,
  permanently retires its keys. Keys are never reused; gaps in the T sequence
  are expected and correct.
- Manually created tickets and suggestion batches allocate from the same
  sequence and can never collide, including when two epics generate suggestions
  concurrently.
- Generation or validation failure allocates nothing. A failed persist
  transaction rolls back the counter with everything else. There is no state
  where a key is reserved but attached to nothing.

## Non-goals

- Do not unify suggestions into `work_items` as a `proposed` state. That is a
  possible later architecture packet; this packet keeps the
  `ticket_suggestions` table.
- Do not repair the stale `S1`/`S2` text already present in accepted tickets of
  existing products. Historical accepted/rejected suggestions keep their `S`
  references as audit history.
- Do not change the model-facing protocol: the generator prompt still asks the
  model for relative `S1`-style references, because final keys cannot exist
  while the model writes. Substitution to durable keys happens at persist time.
- No changes to delivery, sprint planning, or dependency-graph semantics
  (suggestion dependencies are already stored by ID in
  `suggestion_dependencies` / `suggestion_existing_dependencies` and are
  unaffected).

## Current authority

- Durable state: `ticket_suggestions.reference` holds `S<position>`;
  `work_items.key_number` / `item_key` assigned only in `insertWorkItem`;
  next key computed as `COALESCE(MAX(key_number), 0) + 1` over `work_items`
  (`nextWorkItemNumber`, `Sources/SpeditoCore/Persistence/SQLiteStore.swift`
  around line 1473). Product DB schema is at `PRAGMA user_version = 3`
  (`Sources/SpeditoCore/Persistence/ProductDatabaseSchema.swift`).
- Task owner: `EpicPlanningWorkflowCoordinator` drives generation and review
  decisions; persistence happens in `SQLiteStore+TicketSuggestions.swift`.
- Presentation state: suggestion rows render `suggestion.reference` directly
  (`Sources/SpeditoApp/BacklogView.swift` — accept/reject confirmations and
  table rows), so a `T` value in `reference` flows through without view logic
  changes.
- Known duplicate state: the key exists twice conceptually — implied by batch
  position at proposal time, allocated for real at acceptance. This packet
  removes the duplication by allocating once, at persist.

## Target authority

- Coordinator: unchanged (`EpicPlanningWorkflowCoordinator`).
- Commands: unchanged owner commands (generate plan, accept, reject).
- Snapshot: unchanged shape; `reference` values become durable `T` keys for
  newly persisted batches.
- Persistence operations:
  - New migration `migrationV3ToV4` in `ProductDatabaseSchema.swift`: add a
    per-product durable key counter (recommended: `next_ticket_key_number`
    column on the `products` row, initialized to
    `COALESCE(MAX(work_items.key_number), 0) + 1`, adjusted for any keys the
    migration itself assigns — see migration step below). Idempotent and safe
    for every product.
  - `nextWorkItemNumber` switches to read-and-bump the counter inside the
    caller's transaction. One allocation path for all keys; the retrospective
    ticket-creation call site (`SQLiteStore+Retrospectives.swift`) is covered
    automatically.
  - Batch persist (`insertTicketSuggestionDrafts` path in
    `SQLiteStore+TicketSuggestions.swift`): inside the existing transaction,
    allocate one key per draft in position order, store it in `reference`
    (and/or a dedicated key column — implementer's choice, but `reference` is
    what the UI renders), and substitute batch-internal `S` references in
    rationale and acceptance-criteria prose with the assigned keys.
  - Acceptance (`acceptTicketSuggestions`): create the work item with the
    proposal's stored key instead of allocating a new one. `insertWorkItem`
    gains a way to accept a pre-assigned key, or the acceptance path uses a
    sibling insert that binds the stored key. Remove the renumbering.
- View boundary: no view changes expected. If none are made, the
  launched-process UI suite is not required for this packet.

### Reference substitution rules (the one correctness-sensitive spot)

- Build the substitution map only from the batch's own normalized references
  (`S1`…`Sn` as produced by `CodexTicketSuggestionGenerator`'s
  `proposalReferenceByGeneratedReference` mapping).
- Replace only word-boundary matches (`\bS<digits>\b`) that are in the map.
  Never touch existing active-ticket keys (`T…`) cited in the same prose.
- After substitution, validate: no `\bS\d+\b` token matching a batch reference
  may remain in any persisted reference, rationale, or criteria string. Fail
  the persist (typed, owner-recoverable, consistent with the existing
  generation-failure handling) rather than storing half-substituted text.

## State table

| State | Entered by | Durable evidence | Owner sees | Available actions | Recovery |
| --- | --- | --- | --- | --- | --- |
| Batch persisted with durable keys | Plan generation completes and validates | Counter bumped by n; `ticket_suggestions` rows hold final `T` keys; substituted prose | Proposals labelled T7, T8, … with criteria citing those keys | Accept, reject, discuss, regenerate | Relaunch re-reads rows; keys and text already final |
| Proposal accepted | Owner accepts (prerequisite closure) | `work_items` row with the proposal's stored key; suggestion status `accepted` + `accepted_work_item_id` | Ticket keeps the exact key and text it showed as a proposal | Normal backlog actions | Idempotent: acceptance is a state change, no key allocation |
| Proposal rejected | Owner rejects (dependant closure) | Suggestion status `rejected`; key permanently retired | Proposal leaves the plan; T sequence keeps a gap | Regenerate or accept others | None needed; counter never rolls back |
| Batch superseded | Owner regenerates the plan | Old batch archived per existing versioning; new batch allocates fresh keys | New proposals with higher keys | Accept, reject, discuss | Same as batch persisted |
| Generation or persist failure | Codex failure, validation failure, or transaction rollback | Nothing: counter and rows untouched (single transaction) | Existing owner-facing generation failure state | Retry generation | Nothing to recover |
| Migration applied | First launch on v4 | Counter column initialized; pending `proposed` suggestions re-keyed (see below) | Pending proposals now show `T` keys | Normal | Migration is idempotent |

### Migration of pending proposals

Existing *proposed* (undecided) suggestions still carry `S` references. To
leave exactly one acceptance path, the v3→v4 migration allocates keys for them
too: per session, in `position` order, assign keys from the counter and apply
the same substitution to `reference`, rationale, and criteria JSON. Historical
`accepted`/`rejected` suggestions are left untouched. Doing the prose
substitution in Swift as part of the store's migration step is acceptable if it
runs in the same transaction as the schema change and is idempotent (guard on
`user_version`). Acceptance must then assume every `proposed` suggestion holds
a durable key and treat a legacy `S` reference as corrupt data.

## Call sites to migrate

- [x] `Sources/SpeditoCore/Persistence/ProductDatabaseSchema.swift` — added
      `migrationV3ToV4` (counter column plus initialization), bumped the fresh
      schema and `user_version` to 4.
- [x] `Sources/SpeditoCore/Persistence/SQLiteStore.swift` —
      `nextWorkItemNumber` delegates to `allocateTicketKeyNumbers`
      (read-and-bump inside the caller's transaction); `insertWorkItem`
      accepts `preassignedKeyNumber`; the migration runner accepts v3 and runs
      `assignDurableKeysToPendingSuggestions` in the migration transaction.
      Additionally hardened `importAllRows`: the legacy shared schema has no
      counter column, so the import re-derives it from the copied tickets.
- [x] `Sources/SpeditoCore/Persistence/SQLiteStore+TicketSuggestions.swift` —
      `insertTicketSuggestionDrafts` allocates keys, substitutes
      batch-internal references in body, rationale, and criteria, validates no
      residual batch `S` token, and stores the final key in `reference`;
      acceptance binds the stored key and rejects a legacy `S` reference as
      corrupt data. `TicketSuggestionKeySubstitution` holds the substitution,
      residual check, and key parsing.
- [x] `Sources/SpeditoCore/Codex/CodexTicketSuggestionGenerator.swift` —
      prompts keep model-side `S` refs unchanged. Instead of exposing the
      reference map, `decodeSuggestions` now rewrites prose citations from the
      model's own references to the canonical position-ordered `S` refs, so
      every draft is self-consistent and the store substitutes from draft
      references alone (a no-op when the model already emits `S1`…`Sn` in
      order).
- [x] Tests asserting `"S1"` literals updated in `SQLiteStoreTests.swift`,
      `TicketDeliveryWorkflowCoordinatorTests.swift`,
      `EpicPlanningJourneyTests.swift`, and
      `EpicPlanningPresentationTests.swift`. `CodexAdapterTests.swift` needed
      no change (it tests the model-side layer, which keeps `S` refs), and
      `EditableTicketJourneyTests.swift` only feeds `S` drafts in, which
      remains the correct model-side input.
- [x] Docs updated in the same commit: `AGENTS.md` (`CLAUDE.md` is a symlink)
      product-language rule, `docs/product-spec.md` proposal-reference
      paragraph, and the persistence bullets in `docs/technical-design.md`.

## Obsolete state to remove

- [x] Acceptance-time key allocation in `acceptTicketSuggestions`.
- [x] `MAX(key_number)+1` as the allocation source (it survives only inside
      migration and import SQL that initializes the counter).
- [x] No UI or copy presented suggestion references as temporary; nothing to
      remove.

## Verification

- [x] Existing focused tests: ticket-suggestion store tests, epic planning
      journey tests.
- [x] New observable-contract tests (all in `SQLiteStoreTests.swift` unless
      noted):
      - counter migration initializes correctly on a v3 database with existing
        tickets, and is idempotent
        (`migrationAssignsDurableKeysToPendingProposals`, which also covers
        re-keying pending proposals and leaving decided ones untouched);
      - batch persist assigns sequential durable keys and substitutes
        batch-internal refs while leaving active `T` keys untouched
        (`suggestionBatchPersistsWithDurableKeys`);
      - acceptance preserves reference and criteria text byte-for-byte, and a
        manual ticket during a pending batch takes the next free key
        (`acceptedSuggestionKeepsItsDurableKeyAndText`);
      - rejection and batch regeneration leave gaps
        (`rejectedSuggestionKeysAreNeverReused`);
      - persist-failure rollback leaves the counter unchanged
        (`failedSuggestionPersistRollsBackCounter`);
      - a legacy shared-database import re-derives the counter
        (`ProductStoreRegistryTests.legacySharedDatabaseImport`).
- [x] Interruption and fresh-instance recovery: close-and-reopen assertions in
      the new persist and migration tests show the same durable keys.
- [x] Full suite: 656 tests in 71 suites passed
      (`swift test --scratch-path .build-keys -Xswiftc -warnings-as-errors`).
- [x] `git diff --check` — clean.
- [x] `./scripts/check_architecture_ratchets.sh` — all 6 baselines match.
- [ ] Relaunch: deferred. The debug app is running with a live Codex
      app-server session (pilot T1 approval pending), and relaunching would
      kill that turn. Launched-process UI suite: not required — no view files
      were edited.
- [ ] Product-owner inspection: generate a plan for a fresh epic in a product
      with existing tickets; confirm proposals show final `T` keys, criteria
      cite those keys, and the keys survive acceptance unchanged.

## Completion evidence

```sh
env SWIFT_MODULECACHE_PATH="$PWD/.build-keys/module-cache" \
  CLANG_MODULE_CACHE_PATH="$PWD/.build-keys/clang-cache" \
  swift test --scratch-path .build-keys -Xswiftc -warnings-as-errors
# Test run with 656 tests in 71 suites passed after 27.774 seconds.

git diff --check
# clean

./scripts/check_architecture_ratchets.sh
# Architecture ratchets match all 6 baselines.
```

Observed contract in the new tests: a product with `T1`/`T2` persists a
two-proposal batch as `T3`/`T4`; the dependant's criterion "Using the provider
approved by S1" is stored as "…approved by T3" while "Builds on T1" stays
untouched; acceptance creates `work_items` rows `T3`/`T4` with identical text;
a v3 database with a pending proposal re-keys it to `T3`, rewrites its prose
against the accepted sibling's real key, leaves decided suggestions as `S`
audit history, and allocates `T4` for the next manual ticket.
