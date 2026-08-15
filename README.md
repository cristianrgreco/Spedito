# Spedito

Spedito is a local-first, macOS-native product-delivery app for product
owners working with coding agents. Turn product ideas into a backlog, plan
sprints, and let an AI team implement and review tickets while you stay in
control of scope, permissions, demos, and acceptance.

Learn more at [spedito.io](https://spedito.io/).

> [!NOTE]
> **Early access**
>
> Spedito is under active development, so expect bugs and breaking changes.
> For now, it supports macOS and Codex only. Contributions, bug reports, design
> feedback, and documentation improvements are welcome.

![Spedito sprint board](Website/screenshots/1.webp)

## Install

Download the latest Apple Silicon build as
[Spedito.dmg](https://github.com/cristianrgreco/spedito/releases/latest/download/Spedito.dmg),
open it, and drag **Spedito** into **Applications**.

The app is not yet signed with an Apple Developer ID. On first launch, macOS may
block it: open **System Settings → Privacy & Security**, choose **Open Anyway**,
then confirm. If there is enough demand, we will get a developer certificate and
notarize future releases.

Spedito requires an Apple Silicon Mac running macOS 14 or later, Git, and
a compatible Codex app or `codex` installation.

## What it does

- Organises products into epics, tickets, a backlog, and sprints.
- Creates blank Products or imports a public or private repository selected from
  the repositories available to an authorized GitHub account, with canonical
  public HTTPS links from GitHub, GitLab, Bitbucket, or Codeberg as a fallback;
  full Git history, `origin`, default branch, and exact accepted revision are
  preserved.
- Connects imported or local Products through a guided GitHub authorization and
  repository-access flow, reuses the sole authorized account for later Products,
  and links to existing installation settings when access must change. It checks
  GitHub automatically before tech lead review, incorporates verified incoming
  changes through the ticket lifecycle, reuses the ticket's Integrator and owner
  questions for conflicts, and runs one tech lead review against each exact
  candidate. Repository-changing candidates publish as draft pull requests,
  bring actionable inline GitHub review context into the ticket work log, and
  merge the exact revision on product owner approval. Repository-free business
  analyst outcomes remain in Spedito for review and acceptance without an empty
  commit or pull request. Pull-request mechanics stay out of the sprint board
  and ticket header; the work log keeps any publication link.
- Coordinates specialist AI team members for refinement, implementation, and
  independent review.
- Isolates delivery in Git branches and worktrees before product owner approval.
- Lists independently verified imported source and accepted runnable browser or
  macOS app revisions in the product's **App versions** workspace, and reopens
  any selected version from its exact commit.
- Keeps questions, permission requests, progress, and decisions in each ticket's
  work log.
- Keeps delivery running across products and surfaces unresolved **Needs your
  input** tickets alongside unread background refinement results and agent
  replies through cross-product and workspace counts, contextual in-app and
  macOS notifications, and direct navigation back to the ticket, epic, or Chat
  thread.
- Builds versioned product knowledge from an isolated repository snapshot,
  requires independent tech lead approval, and stores the verified result only
  in the Product's local `.spedito` control data rather than its Git history.
- Runs locally, with product state stored in the product workspace.

## Build from source

```sh
git clone https://github.com/cristianrgreco/Spedito.git
cd Spedito
swift test
swift run Spedito
```

GitHub repository workflows require a Spedito GitHub App with Device Flow and
expiring user-to-server tokens enabled. Local builds remain fully usable without
it; GitHub actions show as unavailable. To enable them in a development bundle:

```sh
export SPEDITO_GITHUB_CLIENT_ID="<public client ID>"
export SPEDITO_GITHUB_APP_SLUG="<public app slug>"
./scripts/build_app.sh debug
```

The App requests only Metadata read, Contents read/write, Pull requests
read/write, and Workflows write. It does not use a client secret or private key.

See the [product specification](docs/product-spec.md),
[technical design](docs/technical-design.md), and
[release guide](docs/releasing.md) for more detail.

The static product website lives in [`Website`](Website).

## Privacy

Spedito has no cloud backend or analytics service. Product state stays in the
local workspace, but Codex may send the context needed to perform work to
OpenAI under the data controls for your account. Imported-repository analysis
sends files from a sanitized snapshot of the accepted revision while excluding
credential-shaped paths, Git internals, local control data, symlinks, and
non-regular objects. GitHub authorization uses Device Flow, stores expiring
tokens atomically in Apple Keychain, and supplies them to `/usr/bin/git` only
through isolated, short-lived credential-cache sockets. Do not store secrets in
source files or include them in tickets, product knowledge, pull-request text,
screenshots, issues, or bug reports.

## Contributing

Please read [CONTRIBUTING.md](CONTRIBUTING.md), the
[Code of Conduct](CODE_OF_CONDUCT.md), and [SECURITY.md](SECURITY.md) before
participating.
