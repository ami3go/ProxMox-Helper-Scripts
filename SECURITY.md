# Security Policy

## Supported versions

Security fixes are applied to the latest repository release and to the latest version of each included helper.

| Version | Supported |
|---|---|
| 2.x | Yes |
| 1.x | Best effort |

## Reporting a vulnerability

Do not open a public issue for a vulnerability that could expose credentials, compromise a Proxmox host, weaken VM or LXC isolation, enable unintended network access, or execute untrusted commands.

Use GitHub private vulnerability reporting when enabled. Otherwise, contact the repository owner privately and include:

- repository and helper version
- affected helper ID
- reproduction steps
- expected and observed behavior
- potential impact
- suggested mitigation, when known

Do not include real passwords, API keys, SSH private keys, tokens, customer data, or unredacted infrastructure details.

## Repository security model

Helper manifests are constrained to double-quoted literal metadata. Validation rejects dynamic shell expressions and unsupported statements before release. Helper entrypoints are still privileged executable code and must be reviewed before use.

Every helper is expected to:

- validate its target environment
- use conservative defaults
- require confirmation before destructive operations
- protect credentials and state
- avoid logging secrets
- document network exposure and package sources
- support predictable rerun, repair, or rollback behavior

An unprivileged LXC reduces risk but does not provide the same isolation boundary as a full virtual machine. Use a VM for untrusted workloads, custom kernels, or stronger tenant separation.

Some helpers may download upstream packages or installers. Review upstream URLs, signatures, checksums, and version-pinning behavior before use in controlled environments.
