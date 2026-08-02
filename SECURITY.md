# Security policy

Spedito coordinates coding agents, local repositories, filesystem access,
processes, and permission requests. A flaw can therefore have a larger impact
than an ordinary desktop-app bug. Please report suspected vulnerabilities
privately.

## Supported versions

Spedito is currently an early preview with no stable or commercially
supported release line. Security fixes are made on the latest development
version and may be included in a replacement prerelease. Older builds should be
considered unsupported.

The project has not received an independent security audit. Do not use it as the
sole safety boundary for production-critical, regulated, or highly sensitive
work.

## Reporting a vulnerability

Do not open a public issue for a suspected vulnerability.

Use [GitHub private vulnerability reporting](https://github.com/cristianrgreco/spedito/security/advisories/new)
when it is available. If that channel is unavailable, email
[cristianrgreco@gmail.com](mailto:cristianrgreco@gmail.com) with the subject
`Spedito security report`.

Include, where possible:

- the affected commit or release;
- the expected and observed behaviour;
- a minimal reproduction or proof of concept;
- the potential impact and affected data or capability;
- relevant logs with credentials and private data removed; and
- whether you believe active exploitation is occurring.

Do not access other people's data, degrade third-party services, or retain
credentials while investigating. Please allow time for a best-effort
acknowledgement and remediation before publishing details. There is currently no
bug-bounty programme or guaranteed response-time SLA.

## Particularly important reports

Reports are especially useful when they concern:

- escape from an assigned Ticket workspace or permission profile;
- access to another product, worktree, credential store, or local secret;
- unauthorized network access or command execution;
- Product Owner approval being bypassed, replayed, or broadened;
- untrusted agent output mutating authoritative workflow state;
- Git history, candidate, review, or demo substitution;
- database corruption, cross-product data leakage, or unsafe recovery;
- release artifact tampering or update-channel compromise; or
- credentials or private product context appearing in logs or diagnostics.

Issues in Codex, OpenAI services, macOS, Git, or another third-party component
may ultimately need to be reported to that project's security team. Please still
report a Spedito integration flaw when its handling or assumptions make
the third-party issue exploitable through Spedito.
