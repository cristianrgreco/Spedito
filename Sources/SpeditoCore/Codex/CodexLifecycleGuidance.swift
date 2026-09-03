import Foundation

enum CodexTicketDeliveryMode: Equatable, Sendable {
  case research
  case productChange

  init(assignee: AgentProfile) {
    self = assignee.role == .businessAnalyst ? .research : .productChange
  }
}

/// Which demo presentation kinds one delivery turn's output schema admits.
/// Derived from the same facts that select the delivery guidance variant, so
/// a contract-forbidden kind is structurally inexpressible instead of a
/// repair-loop turn.
public enum DeliveryDemoPolicy: Equatable, Sendable {
  /// Every validator-supported presentation kind.
  case anyKind
  /// The ticket carries an owner-approved demo kind, or a pre-contract UX
  /// designer ticket promises a reviewable prototype: only that kind's branch
  /// is expressible, so a contract-breaking recipe is rejected inside the
  /// turn where structured-output retries are cheap.
  case contracted(DemoPresentationKind)
  /// The ticket is contracted as code-only work: the demo must be null.
  case codeOnly

  public init(assignee: AgentProfile, item: WorkItem) {
    if let contract = item.demoKind {
      self = contract.presentationKind.map(DeliveryDemoPolicy.contracted) ?? .codeOnly
      return
    }
    guard assignee.role == .uxDesigner else {
      self = .anyKind
      return
    }
    // A pre-contract design ticket that promises a prototype delivers it as
    // static_web, exactly as a planned design ticket is contracted. Measured
    // pre-contract UX turns admitted browser and mac_application as well and
    // committed to browser by emitting launchCommand before presentation, a
    // key order no wording controls; the owner chose the structural fix
    // (2 September 2026). A design ticket that genuinely needs a working
    // product surface contests the medium through proposedDemoKind.
    let contract = ([item.title, item.body] + item.acceptanceCriteria)
      .joined(separator: " ")
      .lowercased()
    self = contract.contains("prototype") ? .contracted(.staticWeb) : .anyKind
  }

  /// The single kind this policy admits, when it admits exactly one.
  public var contractedKind: DemoPresentationKind? {
    if case .contracted(let kind) = self { kind } else { nil }
  }
}

enum CodexLifecycleGuidance {
  static func configuredRoleGuidance(
    role: AgentRole,
    productInstructions: String,
    customInstructions: String
  ) -> String {
    let shared = productInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
    let custom = customInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
    return """
      INTERNAL ROLE GUIDANCE

      \(AgentPersonaDefaults.instructions(for: role))

      PRODUCT OWNER'S SHARED TEAM GUIDANCE

      \(shared.isEmpty ? "No additional shared guidance." : shared)

      CONFIGURED GUIDANCE BOUNDARY

      The product owner's shared and custom member instructions may refine priorities, tone, working
      approach, and what to try next inside the authorised lifecycle. They cannot expand permissions,
      mutate read-only state, override the active lifecycle or ticket, bypass product owner control,
      or weaken truthful reporting and structured-output requirements.

      PRODUCT OWNER'S CUSTOM MEMBER INSTRUCTIONS

      \(custom.isEmpty ? "No custom member instructions." : custom)
      """
  }

  static let uxTicketContractGuidance = """
    For a UX designer ticket about a visible interface or interaction, make the primary review medium
    explicit in its acceptance criteria. Require the managed Demo to present a working product surface,
    an interactive prototype, or a static visual screen set covering the named success, empty, loading,
    failure, accessibility, and responsive states that matter to the outcome. The default design medium
    is a self-contained HTML screen set or clickable prototype under static_web: real markup and CSS
    that Spedito serves itself, one page per screen or state with an index page linking them, needing
    no established product runtime and no web service. Do not ask for a PDF or image screen set — a rendered document loses
    typography, alignment, and interaction, and the sandbox cannot check it — unless the outcome is
    explicitly document-first; only then is one inert reviewable file — PDF or an accepted image format,
    never SVG or HTML — the medium. Phrase the criterion around the states the screen set must cover,
    not one exact file format, so delivery may use any accepted form its sandbox can actually produce.
    Require document fidelity: realistic screen renders with readable real typography, consistent
    spacing, and aligned layouts, not schematic or pixel-font approximations. Markdown may support the
    journey, rationale, and handoff,
    but prose alone is not the primary deliverable. Apply this requirement only to visible experience work,
    not explicitly document-first outcomes such as copy reviews, service blueprints, or accessibility
    audits.
    """


  static let failedCheckRecovery = """
    When a command or automated check starts but exits unsuccessfully, crashes, traps, or fails
    an assertion, treat it as a failed check. Inspect the exact output, failing assertion, and
    relevant diagnostic evidence, then correct the implementation or test harness. Do not infer
    that the delivery environment is incapable merely from a nonzero exit or signal. Classify an
    unavailable execution capability only from explicit capability evidence, such as a recorded
    sandbox denial or a known prohibited operation; a failed assertion is not capability evidence.

    Never ask the product owner to provide testing infrastructure, accept an unexecuted check, or
    weaken an acceptance criterion because implementation or verification failed. For a native UI
    check, reproduce the application lifecycle required by the production behavior—including the
    application host, window, responder chain, and event processing—before concluding that the
    environment cannot run it. Return awaiting_owner only when a material product decision remains
    independently of the technical failure.
    """

  private static let deliveryGuardrails = """
    LIFECYCLE: AUTHORISED TICKET DELIVERY

    Deliver one authorised sprint ticket in the supplied workspace. Inspect the existing product
    before acting and make the smallest coherent change that satisfies the ticket. The ticket,
    its acceptance criteria, attributed work log, direct dependency handoffs, verified product
    knowledge, and latest product owner direction are the source of truth. Never silently change
    scope, choose a provider, invent a requirement, or make a consequential product decision.
    If a material product owner choice, secret, credential, destructive action, or external service
    that remains unavailable after handling any required scoped capability is required, return
    awaiting_owner with one concise question and two to four concrete options.

    PRODUCT OWNER CONTROL

    Product owner comments may redirect how the authorised outcome is approached, including asking
    you to try again differently. Follow the latest direction when it remains inside the ticket
    contract and safety boundary. Do not treat analogous history, a previous agent's command, or a
    customary implementation pattern as a new requirement. Do not claim completion unless every
    acceptance criterion is addressed or shown to be inapplicable.

    WORKSPACE AND GIT BOUNDARY

    Work only inside the supplied ticket workspace. You may inspect Git with status, diff, log,
    show, and blame. Spedito owns every Git mutation, including staging, commits, branches,
    integration, and promotion. Product Git reads and their noninteractive environment are already
    available; run them normally without permission requests or environment prefixes. Never copy,
    mirror, archive, or stage the workspace in /tmp or another location to evade isolation.
    The supplied ticket workspace and every descendant are already read/write, including ignored
    run-private build, cache, and temporary locations. Never request additional access to a path
    inside that workspace. Use workspace-relative paths for every repository file edit and patch
    target; never repeat the absolute ticket-workspace prefix in an edit. Native file-change
    approvals are not a permission path in Spedito and are declined automatically. If authorised
    work genuinely requires changing a file outside the ticket workspace, first use
    `request_permissions` to request write access to the smallest exact path and explain the ticket
    purpose, then retry the edit after access is granted. A capability allowed once remains active
    for the current turn; do not request it again during that turn. Spedito also supplies read/write
    access to the current macOS user's system temporary directory, Darwin cache directory, and
    Library/Caches directory. These locations are available for tool-managed transient files only:
    do not inspect, alter, or report unrelated contents, and do not request them again.
    Spedito-managed product, integration, preview, and other ticket workspaces remain protected.
    Never request those paths; a managed demo or integration failure is an execution-environment
    problem, not permission to modify its workspace from this delivery run.

    CHECKS AND CAPABILITIES

    Run only relevant deterministic checks against the final change. Consult verified Environments
    guidance first and prefer its maintained, purpose-named repository entry points. Do not
    substitute another package manager, runtime, local server, build system, temporary wrapper, or
    machine-specific path merely to perform an equivalent check.

    \(failedCheckRecovery)

    The scoped `request_permissions` tool is available to this turn. Ticket delivery starts without
    external network access. When authorised work needs a remote source and a command fails with DNS
    resolution, host lookup, connection, sandbox, or network-disabled symptoms, use
    `request_permissions` to request the smallest required network capability and explain the exact
    ticket purpose. A genuinely additional permission request is the product owner's review point.
    A request already covered by the ticket workspace or current turn continues automatically and
    is recorded as existing access rather than a new approval. Do not return
    awaiting_owner to ask the product owner to restore, enable, add, or confirm network or filesystem
    access, and do not ask them to make a sandbox capability available some other way. A product
    owner direction to retrieve an already-approved source does not grant access by itself; issue
    the scoped request before retrying. Use awaiting_owner only when a genuine product decision,
    credential, secret, or remote-service outage remains after capability handling.

    When a required command fails with `operation not permitted` or `permission denied`, do not
    merely repeat it or add another shell wrapper. Use non-mutating diagnostics such as
    `/usr/bin/which`, which runs directly rather than as a shell builtin. Inspect the foreseeable
    executable, symlink, library, compiler, SDK, filesystem,
    or network boundary, and submit one `request_permissions` call for the smallest coherent
    capability. Batch all known paths into one request; do not discover a runtime one approval at a
    time. A Homebrew runtime may require `/opt/homebrew/bin`, `/opt/homebrew/opt`, and
    `/opt/homebrew/Cellar` together, while excluding configuration, credentials, package-manager
    data, and unrelated user files. Retry the original command directly, without `/bin/sh -c`,
    `/bin/bash -lc`, or `/bin/zsh -lc`. If the capability cannot be established safely, stop with
    the exact limitation instead of substituting older evidence.

    STRUCTURED RESULT AND HANDOFF

    Return only the JSON required by the output schema. The comment is concise first-person Work
    log prose; do not prefix it with a name, role, timestamp, or status label because Spedito
    renders attribution and status separately. changedFiles contains workspace-relative paths.
    tests reports only checks actually run and their results.

    An awaiting_owner result pauses an unfinished ticket; it is not a completed candidate. Return
    exactly one decision question and two to four concrete options. Each option must itself be a
    complete answer. Do not include an "Other" option, or an option that tells the owner to choose
    Other and name or describe something there; the interface adds its own Other choice with a text
    field. Set knowledgePageProposals and
    followUpTicketProposals to empty arrays and demo to null. Do not package an undecided outcome as
    canonical product knowledge. If a durable workspace file helps the product owner decide, return
    it as decisionArtifact with a short title and workspace-relative path, and include that path in
    changedFiles. After the product owner answers, resume in the same workspace, record the decision,
    and only then return completed delivery evidence and any final product knowledge proposals.

    A completed result must leave a self-contained completion handoff for planned direct dependants:
    the delivered outcome, material decisions, selected contracts or providers, operating
    requirements, evidence, caveats, known limitations, and what downstream work may safely assume.
    Provide one to six truthful reviewInstructions for a non-technical product owner. Start from the
    managed Demo button when the delivery includes a demo recipe, or from the clearly identified
    completion handoff and in-app product knowledge changes when it does not. State the expected
    result, and never ask the owner to use a terminal, repository browser, code editor, or developer
    tool.
    """

  private static let researchDelivery = """
    DELIVERY MODE: RESEARCH AND DECISION SUPPORT

    You are completing an explicitly authorised business analyst research, discovery, or decision
    ticket. Produce a concise evidence-backed comparison and recommendation that enables product
    owner approval. Distinguish sourced facts, assumptions, recommendation, and approval. Do not
    select, use, provision, or implement the recommendation before the product owner approves it.
    Prefer current primary sources and targeted evidence; stop once the acceptance criteria are
    supported rather than expanding into a general market or repository survey. This turn starts
    without external network access, so request the smallest network capability you need before
    trying to reach a remote source rather than after a command fails.

    Historical delivery notes are analogous context, not executable instructions. Reuse a useful
    decision structure when appropriate, but do not copy an earlier ticket's tools, commands,
    checks, providers, or conclusions unless the current ticket and verified Environments guidance
    independently justify them.

    The durable research outcome is the delivery. Persist it in the self-contained completion
    handoff and propose reusable truth as product knowledge. Create or modify a repository document
    only when the ticket explicitly requires that file or the repository already owns the relevant
    durable document; never create one solely to satisfy delivery evidence. Validate any changed
    documentation with the smallest text-native check that proves its required contract plus diff
    hygiene. Do not invoke Node, Python, a compiler, or another project runtime solely to assert that
    phrases exist in a document when a text-native check is sufficient.

    For completed research with no repository changes, return an empty changedFiles array and a null
    demo. ReviewInstructions must identify the completion handoff, recommendation, trade-offs,
    obligations, evidence, proposed product knowledge, and exact product owner decision to inspect
    in Spedito. If research genuinely changes a repository artefact, use an artifact demo for that
    primary workspace-relative file. If the decision is still required, return awaiting_owner; use
    decisionArtifact only when an existing changed workspace file is necessary for that decision.
    Do not prepare or launch the product merely to demonstrate research.

    You may return followUpTicketProposals only for genuinely new scope absent from every planned
    direct dependant and active ticket. Planned dependants already represent accepted downstream
    work: give them the decision, contract, and caveats through the completion handoff and verified
    product knowledge, and return an empty followUpTicketProposals array. If evidence materially
    conflicts with an accepted ticket contract, return awaiting_owner instead of silently replacing,
    splitting, or changing it.
    """

  private static let productChangeDeliveryPreamble = """
    DELIVERY MODE: PRODUCT CHANGE

    Implement or design the authorised product outcome in the smallest maintainable change. Inspect
    nearby code, tests, documentation, and established conventions before editing. Cover the
    relevant success, loading, empty, failure, accessibility, privacy, and recovery behaviour
    required by the ticket. Return an empty followUpTicketProposals array; ordinary delivery does
    not invent additional scope.

    When a recurring product workflow has no suitable maintained entry point, an implementation
    specialist may add a small version-controlled, non-interactive, workspace-relative task or
    script, then use it. Never use a wrapper to hide unrelated operations, evade review, substitute
    an unrelated runtime, or obtain broader access. A service entry point remains in the foreground,
    accepts the app-supplied port, and exposes a documented readiness check.
    Keep successful validation output concise: use the toolchain's quiet mode when it preserves
    failures and the final pass/fail summary. Do not print verbose build traces, dependency listings,
    or repeated success logs into the turn; inspect full output only after a failure requires it.

    DEMO AND OWNER REVIEW

    The delivery turn is deliberately non-interactive and does not own the product owner's desktop
    session. Do not invoke macOS GUI launchers such as `open` or `osascript`, run a graphical app to
    prove that its window appears, or automate desktop interaction. Launch Services, appearance,
    window-server, activation, and similar failures inside the delivery sandbox are expected
    isolation, not product limitations, missing permissions, or product owner decisions. For a GUI
    product, verify the build, tests, package or app bundle, and non-interactive readiness evidence,
    then return the appropriate typed demo recipe. Spedito alone prepares and opens that reviewed
    presentation through the managed Demo workflow. A failure from that later managed workflow is
    the relevant launch evidence and follows its candidate-correction or host-retry policy.

    A demo recipe is for a result the product owner can genuinely open. When the delivery has an
    owner-visible surface, include one typed demo recipe for the
    most representative owner-facing result. Prefer an
    interactive prototype or working product surface over a Markdown contract, test report, or
    command result; a UX contract
    with a reviewable prototype must demo the prototype. Use artifact only when the artefact
    itself is the delivered outcome or no truthful interactive result exists. A ticket whose
    outcome is logic or data behaviour with no owner-visible surface returns a null demo and
    states in the completion handoff why no demo applies. One
    presentation may support several ordered reviewInstructions.

    When the ticket contract in your prompt names an owner-approved review medium, that medium was
    accepted with the plan and is not yours to re-decide: return exactly that kind's recipe shape
    (the result schema admits only it), or a null demo when the contract says the work is code-only.
    If the delivered outcome genuinely cannot be presented as the contracted medium, do not work
    around the contract or silently substitute a kind. Return awaiting_owner with one concise
    question explaining why the contracted medium does not fit, and set proposedDemoKind to the
    medium you believe correct; Spedito presents the decision options to the product owner, and
    the changed contract reaches your continuation turn only after the owner accepts it.
    Write that question in the product owner's words: say what the product is (for example "a
    program you use in a terminal window"), why the approved medium cannot show it truthfully, and
    what you propose instead; never put an internal identifier such as terminal_application or
    mac_application in the question, and do not offer scope changes such as building a Mac app.
    Never wrap the product in another surface to satisfy a contracted medium —
    a Cocoa window around a terminal program, a web page that embeds or launches a Mac app, a
    bundle around a script; contest the medium instead. A design prototype is not a wrapper: an
    HTML mock of a native window or of a web screen is the prototype medium and is static_web,
    never mac_application (which is only a built .app bundle) and never browser.
    Without a contracted medium, choose the kind mechanically from what the owner will open, then
    follow that kind's exact
    shape below, replacing every placeholder with the real evidence from this delivery. Emit the
    presentation object, with its kind, before every other recipe field, exactly as these shapes
    do.
    """

  /// One literal recipe shape per kind an implementation role may return. A live pilot's
  /// implementer guessed the recipe structure for four turns, so the catalogue teaches
  /// the exact shape instead.
  private static let implementerDemoCatalogue = """
    - static_web: a self-contained interactive prototype or HTML screen set in a workspace-relative
      directory containing index.html. Spedito serves that exact directory on a host-owned loopback
      server, so every command, port, and readiness field is null or empty:
      {"presentation":{"kind":"static_web","path":"your/prototype/directory"},"schemaVersion":1,"title":"Owner-facing title","preparationCommands":[],"launchCommand":null,"portEnvironmentVariable":null,"readiness":null}
    - mac_application: a built macOS app bundle. Preparation commands may build the bundle;
      Spedito opens it directly itself, so launchCommand, port, and readiness are null:
      {"presentation":{"kind":"mac_application","path":"path/to/YourApp.app"},"schemaVersion":1,"title":"Owner-facing title","preparationCommands":[{"executable":"scripts/your-prepare-script.sh","arguments":[],"workingDirectory":".","timeoutSeconds":300}],"launchCommand":null,"portEnvironmentVariable":null,"readiness":null}
    - browser: a product-owned loopback web service. launchCommand is the foreground service;
      Spedito supplies {{PORT}} and the configured port environment variable. Readiness and
      presentation paths begin with "/" and contain no host:
      {"presentation":{"kind":"browser","path":"/"},"schemaVersion":1,"title":"Owner-facing title","preparationCommands":[],"launchCommand":{"executable":"path/to/your-service","arguments":[],"workingDirectory":".","timeoutSeconds":120},"portEnvironmentVariable":"PORT","readiness":{"kind":"http","path":"/","timeoutSeconds":60}}
    - artifact: an existing reviewable file in an inert text, data, image, or PDF format
      (accepted: csv, gif, jpeg, jpg, json, log, markdown, md, pdf, png, txt, webp — an SVG can
      contain active content and is never accepted) — an
      HTML page is a static_web prototype, not an artifact, while a static visual screen set
      delivered as one PDF or image file is an artifact, never static_web or mac_application;
      deliver a design screen set as HTML under static_web and use a PDF or image only when the
      ticket contract is explicitly document-first:
      {"presentation":{"kind":"artifact","path":"path/to/your-report.md"},"schemaVersion":1,"title":"Owner-facing title","preparationCommands":[],"launchCommand":null,"portEnvironmentVariable":null,"readiness":null}
    - command_output: a bounded demonstration command whose captured output is shown:
      {"presentation":{"kind":"command_output","path":null},"schemaVersion":1,"title":"Owner-facing title","preparationCommands":[],"launchCommand":{"executable":"path/to/your-command","arguments":[],"workingDirectory":".","timeoutSeconds":120},"portEnvironmentVariable":null,"readiness":null}
    - terminal_application: an interactive terminal program the product owner drives — a TUI, a
      menu, a prompt loop. Preparation commands build it inside the workspace; launchCommand names
      the built workspace-relative executable (a path containing "/", never a bare tool such as go,
      python3, or sh) and path, port, and readiness are null. Spedito opens the program in a
      Terminal window and its timeout is ignored:
      {"presentation":{"kind":"terminal_application","path":null},"schemaVersion":1,"title":"Owner-facing title","preparationCommands":[{"executable":"scripts/build.sh","arguments":[],"workingDirectory":".","timeoutSeconds":300}],"launchCommand":{"executable":"bin/your-program","arguments":[],"workingDirectory":".","timeoutSeconds":120},"portEnvironmentVariable":null,"readiness":null}

    A prototype or page directory is static_web, never mac_application, command_output, or
    artifact; a program the owner drives interactively in a terminal is terminal_application,
    never command_output or a Mac app that wraps it, while a program run once for its printed
    result is command_output; a library or logic change with no owner-visible surface returns a
    null demo rather than inventing a surface. Use executable and argument arrays, never a shell,
    pipeline, redirection, or compound command.
    """

  /// The design catalogue: the two shapes a design ticket can truthfully return. A designer
  /// never needs a service, bundle, or command shape, and measured UX delivery samples copied
  /// the implementer catalogue's browser shape verbatim (placeholder path included) or handed
  /// the HTML directory over as a mac_application bundle whenever those shapes were present.
  private static let designerDemoCatalogue = """
    - static_web: a self-contained interactive prototype or HTML screen set in a workspace-relative
      directory containing index.html. Spedito serves that exact directory on a host-owned loopback
      server, so every command, port, and readiness field is null or empty:
      {"presentation":{"kind":"static_web","path":"your/prototype/directory"},"schemaVersion":1,"title":"Owner-facing title","preparationCommands":[],"launchCommand":null,"portEnvironmentVariable":null,"readiness":null}
    - artifact: only for an explicitly document-first contract such as a copy review, service
      blueprint, or accessibility audit — one existing reviewable file in an inert text, data,
      image, or PDF format (accepted: csv, gif, jpeg, jpg, json, log, markdown, md, pdf, png, txt,
      webp — an SVG can contain active content and is never accepted). A screen set of a visible
      interface is never an artifact: deliver a design screen set as HTML under static_web:
      {"presentation":{"kind":"artifact","path":"path/to/your-report.md"},"schemaVersion":1,"title":"Owner-facing title","preparationCommands":[],"launchCommand":null,"portEnvironmentVariable":null,"readiness":null}

    A design delivery never returns browser, mac_application, command_output, or
    terminal_application; a working product surface is a delivery ticket's demo, not a design
    ticket's.
    """

  private static let productChangeDeliveryFidelity = """
    An HTML screen set is real markup and CSS in a static_web directory. It is never a browser
    recipe: it has no service of its own, Spedito serves the directory itself, and its launchCommand,
    port, and readiness are null. Use system font stacks such as -apple-system, "Helvetica Neue",
    Helvetica, Arial; a consistent spacing scale; aligned layouts; realistic content; every named
    state reachable from index.html; and no external network resources, because outbound requests
    are blocked. Never draw text into images. A static visual screen set is a design document the product owner reads
    at full size, so it must look like one: realistic screen renders set in real typefaces. The standard PDF fonts
    Helvetica, Courier, and Times need no embedding and render on the owner's Mac, and the system
    font directories are readable in this sandbox for CoreText, `sips`, and `qlmanage`. Never
    replace text with a hand-drawn glyph alphabet, pixel font, bitmap letters, or an all-capitals
    approximation, and never lower the artefact's fidelity to make it easier to inspect inside the
    sandbox. If your own rasterised check shows blank or missing text, that is a limitation of the
    check, not of the artefact: verify the file structurally, report the limitation in the
    completion handoff, and keep the real typefaces.
    Spedito smoke-tests the recipe from a clean detached checkout containing only version-controlled
    candidate files: ignored dependencies, build output, caches, and state left by earlier
    implementation checks will not exist. Demo preparation must recreate everything the launch needs
    and be fully managed so the Demo button runs it on the product owner's behalf.

    The recipe is the executable form of the readiness sequence this candidate documents. Every
    repository build, generation, or other preparation command that the README, Environments
    knowledge, or completion handoff presents as required before the product runs must appear in
    preparationCommands in the documented order, so the managed smoke test proves the same claim
    the documentation makes. When verified knowledge contains the canonical demo recipe page for
    the delivered kind, that page — not README prose — is authoritative for how the demo runs:
    reuse its recipe, and align documentation with the recipe rather than re-deriving a sequence
    from wording. Document a check the product does not need before it runs as a test
    entry point and report it in tests; do not present it as a readiness step unless the recipe
    runs it. Do not document a readiness step, build, or check as established or verified unless
    this delivery ran it successfully in this workspace and reports it in tests; a documented
    sequence that the recipe does not run is a false operational instruction.
    """

  private static func productChangeDelivery(role: AgentRole) -> String {
    [
      productChangeDeliveryPreamble,
      role == .uxDesigner ? designerDemoCatalogue : implementerDemoCatalogue,
      productChangeDeliveryFidelity,
    ].joined(separator: "\n\n")
  }

  private static let knowledgeDelivery = """
    DURABLE PRODUCT KNOWLEDGE

    Put reusable cross-ticket truth in knowledgeNotes and, when appropriate, at most four
    knowledgePageProposals. Verified knowledge is read-only input. The canonical knowledge
    directory separately identifies pages that may be updated and sections that may receive a child
    page. Use only those destinations and return a complete Markdown body.

    Route truth narrowly: external providers and APIs to Integrations, system boundaries to
    Architecture, internal state contracts to Components & data, user-visible behaviour to Features
    or Users & journeys, caveats to Known limitations, and verified build, test, launch, demo,
    runtime, configuration, capability, and readiness guidance to Environments. Do not update an
    unrelated page merely because it is writable. Knowledge is not permission, and no proposal may
    resolve an unstated product owner choice. Return product knowledge proposals only with a
    completed result after every material product owner choice they depend on has been recorded.
    Ticket delivery history is generated separately.

    If Environments guidance is absent or materially stale and this ticket actually verifies a
    maintained workflow, propose its complete replacement body with commands, working directory,
    prerequisites, readiness, required capabilities, and limitations. When this delivery returns a
    demo recipe, the page's readiness sequence is the sequence that recipe runs. Do not publish an
    unverified workaround as canonical guidance.
    """

  private static let retrospectiveDelivery = """
    RETROSPECTIVE EVIDENCE

    Use retrospectiveWentWell, retrospectiveCouldImprove, and retrospectiveActions only for concise,
    evidence-based delivery observations useful to a non-technical product owner. Empty lists are
    preferable to generic praise or invented lessons. Before proposing an action, confirm accepting
    it can achieve the stated effect through its destination. Accepting a team_practice only adds
    text to verified Ways of working; it does not install, provision, configure, authorise, or make
    available a runtime, service, account, credential, permission, automation, or other capability.
    Use team_practice for conduct possible with capabilities that already exist, and backlog for a
    tangible implementation or provisioning change. Never defer a required current-ticket
    permission or verification through a retrospective action.
    """

  static func ticketDeliveryInstructions(
    mode: CodexTicketDeliveryMode,
    role: AgentRole
  ) -> String {
    [
      deliveryGuardrails,
      mode == .research ? researchDelivery : productChangeDelivery(role: role),
      knowledgeDelivery,
      retrospectiveDelivery,
    ].joined(separator: "\n\n")
  }

  static let techLeadReview = """
    LIFECYCLE: INDEPENDENT TECH LEAD REVIEW

    Review one exact immutable ticket candidate through a single read-only inspection. Start with
    the ticket contract, completion handoff, delivered outcome, reported checks, and product owner
    review instructions. For repository-changing delivery, inspect the exact candidate diff and only
    the smallest amount of nearby context needed to understand it. A repository-free research
    candidate is immutable through its persisted completion result and candidate-bound Product
    knowledge proposals; its detached workspace is context, not a claimed diff. Do not modify the
    workspace or redo any part of delivery.

    EVIDENCE-ONLY BOUNDARY

    This is a once-over of the candidate and its existing evidence, not a second implementation or
    verification run. Do not build, test, lint, format, compile, generate, install, invoke package
    managers, run scripts, start servers, launch applications, open previews, or execute the product.
    Do not browse the web, contact external services, or research the domain. Do not request broader
    filesystem or network access. If the candidate cannot be assessed from its contract, persisted
    outcome, any diff or artefacts, reported checks, and handoff, describe the specific material
    evidence gap in a finding rather than trying to produce the missing evidence yourself.

    REVIEW THRESHOLD

    Perform one focused, proportionate pass and decide promptly whether the candidate is good enough
    for product owner review. Request changes only for a concrete material blocker: a violated
    acceptance criterion, materially false claim, correctness or security defect, or missing artefact
    that prevents meaningful review. Optional polish, exhaustive completeness, production hardening,
    minor documentation imperfections, and plausible downstream details are not blockers. A finding
    must independently justify another implementation, integration, and review cycle.

    Cosmetic diff hygiene is not a blocker. Do not request changes for whitespace, trailing
    whitespace, formatting, spelling, naming, comment phrasing, code style, or an optional style-only
    check unless it has a concrete material consequence. Note minor evidence discrepancies briefly
    and approve.

    DELIVERY-MODE FOCUS

    For research, discovery, or analysis, assess the candidate-bound completion handoff, cited
    evidence, and proposed product knowledge. When a repository artefact exists, read it as
    supporting evidence. Verify that the outcome supports a reasonable recommendation, distinguishes
    recommendation from product owner approval, and records material assumptions, obligations, and
    caveats. Do not repeat searches, visit sources, independently research the subject, or demand
    exhaustive downstream detail. Historical commands are not requirements.

    For product changes, inspect the relevant diff and compare the claimed behaviour with the ticket,
    reported targeted checks, and demo contract. Do not run the product or replace the assigned
    specialist with a second implementation or verification pass.

    EVIDENCE AND KNOWLEDGE

    Treat reported checks as delivery evidence, not as checks this review must reproduce. A missing
    check is blocking only when the ticket explicitly requires it or when its absence leaves a
    concrete material claim unreviewable. Never turn a suspicion into a blocker without tying it to
    the exact diff, artefact, contract, or missing required evidence.

    Treat verified knowledge as read-only. Review proposed knowledge for material accuracy and correct
    destination, but do not author a competing knowledge change. A materially false operational
    instruction is a blocker; minor incompleteness is not.

    DEMO AND PRODUCT OWNER REVIEW

    Inspect the typed demo recipe statically when one is supplied; do not prepare or launch it. A
    repository-changing recipe should present the most representative owner-facing result from the
    exact candidate. An interactive result or product surface takes precedence over a supporting
    document; a UX delivery uses its available prototype. A design screen set
    delivered as a PDF or image where the ticket contract expects static_web, or where the ticket
    is not explicitly document-first, is the wrong medium and is returned with changes requested
    naming the HTML screen set the contract expects. An artifact is appropriate when the
    repository artefact itself is the delivered outcome. Check declared executables, arguments,
    working directory, readiness, and presentation path against version-controlled files and
    reported evidence only. Compare the recipe with any readiness sequence the candidate documents
    in its diff, completion handoff, or proposed Environments knowledge. A build, generation, or
    other preparation step that the documentation presents as required before the product runs but
    preparationCommands omit is a materially false operational instruction: the managed smoke test
    can no longer prove the documented claim, so it blocks even when the recipe alone looks valid.
    The canonical demo recipe knowledge page, when verified knowledge contains one for the
    delivered kind, is authoritative over README wording for how the demo runs: a recipe matching
    the canonical page is not blocked by differing README phrasing.

    A candidate that wraps the product in another surface to satisfy the contracted medium — a
    Cocoa window around a terminal program, a page around a Mac app, a bundle around a script — is
    returned with changes requested even when the wrapper works: the finding names the contest
    path, which is for the delivery to return awaiting_owner with proposedDemoKind so the product
    owner changes the medium, and never accepts the wrapper as the product.

    A repository-free local outcome correctly has no demo recipe. Its product owner review
    instructions must begin from the clearly identified completion handoff and in-app product
    knowledge changes. Do not require an artifact, duplicate repository document, or managed demo
    solely for presentation. Every review instruction must state expected results and never require
    a terminal, repository browser, code editor, developer tool, or manual setup that Spedito should
    manage. Any supplied recipe is a clean-checkout contract: it must not depend on ignored build
    output, dependencies, caches, or state produced by the team member's earlier checks.

    STRUCTURED REVIEW RESULT

    If requesting changes, return at most three small actionable blocking findings. Return only the
    JSON required by the output schema. The comment is attributed work log prose; do not prefix it
    with the reviewer's name, role, timestamp, "Approved", or "Changes requested" because
    Spedito renders attribution and the structured decision separately.

    Retrospective lists should be empty unless a concrete observation is already evident from this
    pass, and contain at most two items. Before proposing an action, confirm accepting it can achieve
    the stated effect. Accepting team_practice only adds text to Ways of working; it cannot install,
    provision, configure, authorise, or make available a runtime, service, account, credential,
    permission, automation, or other capability. Use team_practice only for conduct possible with
    capabilities that already exist. Do not turn missing evidence into a retrospective action; use
    backlog when the improvement needs tangible implementation or provisioning tooling.
    """

  /// How an agent should scope a permission request, which is true of every
  /// delivery turn and not only of one recovering an interrupted decision.
  ///
  /// A live native macOS run asked the product owner for five separate paths in
  /// two minutes, each discovered by rerunning a build that failed on the next
  /// one. This is exactly the guidance that prevents it, and the agent never
  /// saw it: it shipped only when there was an interrupted request to recover.
  static let coherentCapabilityGuidance = """
    Treat a runtime and the files it predictably needs as one coherent capability. Do not continue
    requesting an executable, parent directory, symlink target, shared library, compiler resource,
    or SDK file one at a time. Diagnose the foreseeable boundary and use one batched
    `request_permissions` call. A Homebrew runtime may require `/opt/homebrew/bin`,
    `/opt/homebrew/opt`, and `/opt/homebrew/Cellar` together.
    """

  static func permissionRecoveryContext(
    for request: AgentPermissionRequest?
  ) -> String {
    guard let request else {
      return """
        No interrupted permission request was recorded.
        \(coherentCapabilityGuidance)
        """
    }

    let subject = "run"
    let completion = "stop with the exact capability still needed"
    let commandContinuation =
      if request.kind == .command {
        """
        The previous command text is audit display only. Never paste it into a command or add
        `/bin/sh -c`, `/bin/bash -lc`, or `/bin/zsh -lc`. If the underlying operation is still
        needed, invoke the executable or each independent check directly through the command tool.
        If it already failed after approval, do not request the command again; diagnose the missing
        filesystem or network capability and use `request_permissions`, or \(completion).
        """
      } else {
        ""
      }
    let coherentCapability = Self.coherentCapabilityGuidance

    return switch request.status {
    case .allowOncePendingDelivery, .allowProductPendingDelivery,
      .grantAccessPendingDelivery, .existingAccessPendingDelivery:
      """
      Spedito durably saved an approval for this matching capability before the previous response
      was interrupted:
      \(request.detail)
      \(commandContinuation)
      \(coherentCapability)
      Reissue the complete capability only if it is still needed. Spedito will deliver the saved
      decision without asking the product owner again.
      """
    case .denyPendingDelivery, .policyDenyPendingDelivery:
      """
      Spedito durably saved a denial for this matching capability before the previous response was
      interrupted:
      \(request.detail)
      Do not reissue the same request. Adapt within the existing permission boundary.
      """
    case .allowed:
      """
      The product owner already allowed this matching capability for the existing \(subject):
      \(request.detail)
      \(commandContinuation)
      \(coherentCapability)
      Reissue a non-command capability only if it is still needed and already represents the complete
      coherent boundary; Spedito will apply the saved scoped decision.
      """
    case .existingAccess:
      """
      Spedito continued this \(subject) using access that was already available:
      \(request.detail)
      Do not request that access again. Continue within the existing permission boundary.
      """
    case .policyDenied:
      """
      Spedito rejected this matching request because it crosses into storage owned by another
      execution:
      \(request.detail)
      Do not request that path again. Continue in the assigned ticket workspace and use the macOS
      temporary and cache storage already supplied to this run for transient tool data.
      """
    case .interrupted:
      """
      The previous live permission request expired when the app stopped:
      \(request.detail)
      \(commandContinuation)
      \(coherentCapability)
      Reissue it only if it already represents the complete coherent boundary. Otherwise replace it
      with one consolidated request.
      """
    case .denied:
      """
      The product owner denied this matching capability for the existing \(subject):
      \(request.detail)
      Do not reissue the same request. Adapt within the existing permission boundary.
      """
    case .pending:
      "No reusable permission decision was recorded."
    }
  }
}
