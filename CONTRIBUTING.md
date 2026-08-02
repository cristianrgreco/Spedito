# Contributing to Spedito

Thank you for helping improve Spedito. The project is at an early stage,
so bug reports, documentation, accessibility feedback, tests, design critique,
and focused code contributions are all valuable.

By participating, you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md).
For vulnerabilities or other sensitive security reports, use the private process
in [SECURITY.md](SECURITY.md).

## Before starting

Open an issue before investing in a large feature, workflow change, persistence
change, or architectural rewrite. Describe the Product Owner problem and desired
outcome before proposing implementation details. This lets maintainers confirm
that the change fits the product direction and avoids duplicated work.

Small fixes—such as an obvious bug, typo, focused test, or documentation
correction—may go directly to a pull request.

Good first contributions are narrow and independently reviewable. A pull request
should normally solve one problem rather than combine unrelated cleanup.

## Product language

Spedito is designed for a Product Owner who may not be a software
engineer. Use the established owner-facing terms consistently:

- Product Owner and Team member;
- Backlog, Epic, Sprint, Ticket, Conversation, Work log, and Product knowledge;
- Ready to Pick, In Progress, In Review, Ready for Demo, and Done; and
- Needs your input and Integrating as inline states, not board columns.

Tickets are the source of truth for delivery. Consequential scope, dependency,
permission, and product decisions remain reviewable by the Product Owner. Agent
narration is not proof of progress; use observable events, checks, artifacts,
and reviewed handoffs.

Read the [product specification](docs/product-spec.md) before changing product
behaviour and the [technical design](docs/technical-design.md) before changing
persistence, execution, Git workspaces, permissions, review, integration, or
recovery.

## Development setup

You need:

- an Apple Silicon Mac running macOS 14 or later;
- Xcode with a Swift 6.2-compatible toolchain; and
- Git.

Clone the repository and run the full test suite:

```sh
git clone https://github.com/cristianrgreco/spedito.git
cd spedito
env \
  SWIFT_MODULECACHE_PATH="$PWD/.build/module-cache" \
  CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache" \
  swift test -Xswiftc -warnings-as-errors
```

Run the development application with:

```sh
./scripts/relaunch.sh
```

The relaunch script stops the existing debug process. Do not use it while an
active agent turn needs to be preserved.

## Architecture and code conventions

- Put UI-independent domain policy, persistence, Git, and Codex adapter logic in
  `Sources/SpeditoCore`.
- Put SwiftUI presentation and application coordination in
  `Sources/SpeditoApp`.
- Keep Codex protocol details behind the adapter boundary.
- Prefer extending existing models and reusable views over creating parallel
  representations of the same concept.
- Keep SQLite changes durable, idempotent, and valid for every product.
- Preserve archived records for audit without including them in active planning
  or suggestions.
- Keep permissions least-privilege and fail closed when required isolation is
  unavailable.
- Do not add example-product-specific behaviour, prompts, migrations, or
  defaults to demonstrate a generic feature.

Use sentence case for buttons and menu items. Write out “and” rather than using
an ampersand. Reuse established semantic colours and shared table geometry, and
check compact, light, and dark layouts when changing presentation.

## Tests

Add or update tests for domain policy, persistence, decoding, migrations,
recovery, scheduling, permissions, and other non-visual behaviour. A change is
not complete while relevant tests are failing.

Before opening a pull request, run:

```sh
env \
  SWIFT_MODULECACHE_PATH="$PWD/.build/module-cache" \
  CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache" \
  swift test -Xswiftc -warnings-as-errors

git diff --check
```

If you cannot run the full suite, explain exactly what you ran and why the rest
was unavailable.

Release publishing is maintainer-only and follows
[docs/releasing.md](docs/releasing.md). Ordinary pushes and pull requests never
receive signing or release credentials.

## Pull requests

A useful pull request includes:

- the Product Owner-visible problem and outcome;
- the implementation approach and any material trade-offs;
- tests or other evidence appropriate to the risk;
- screenshots for meaningful UI changes;
- documentation updates when behaviour or architecture changed; and
- limitations or follow-up work that remain.

Keep generated files, local databases, credentials, build products, and personal
configuration out of the change. Never include customer or production data in a
test fixture, screenshot, issue, or Work log example.

AI-assisted contributions are welcome, but the human contributor remains
responsible for understanding, testing, licensing, and explaining the submitted
change. Do not submit unreviewed agent output or fabricated test results.

## Licence of contributions

Unless you explicitly state otherwise, an intentional contribution submitted
for inclusion in Spedito is provided under the
[Apache License 2.0](LICENSE), as described by section 5 of that licence. The
project does not currently require a separate contributor licence agreement.
