# Contributing

Thank you for helping improve the BCCH Universal Upgrade Tool.

## Before making changes

- Read the [README](./README.md), especially the supported upgrade scope,
  Microsoft-only app policy, and backup/recovery behavior.
- Discuss changes to destructive operations, recovery state, version selection,
  or supported upgrade paths in an issue before implementing them.
- Keep changes focused. Do not include license files, app packages, database
  backups, credentials, customer data, or unsanitized logs.
- This repository has no license selected yet. Clarify licensing with the owner
  before contributing code whose reuse or ownership is uncertain.

## Local checks

On Windows, run the offline regression harness in both supported test shells:

```powershell
powershell.exe -NoProfile -File .\Test-Update.ps1
pwsh.exe -NoProfile -File .\Test-Update.ps1
```

If unsigned scripts are blocked, follow your organization's signing policy.
Where permitted, add `-ExecutionPolicy Bypass` before `-File` for that process
only; do not weaken the machine-wide policy.

The harness uses fixtures and does not execute the live upgrade script. Add
regression checks for changes to the functions it covers. Keep the harness
independent of Docker, BcContainerHelper, network access, and administrator rights.

For changes outside that coverage, include a focused regression test where
practical and describe any manual verification required. Live upgrade testing
must use Windows PowerShell 5.1 in a disposable, isolated environment with
independent backups. Never use a production database to validate a pull request.

## Style and compatibility

- Preserve Windows PowerShell 5.1 compatibility for the live script.
- Follow existing PowerShell naming, formatting, strict-mode, and error-handling
  conventions. Use four spaces for indentation and UTF-8 text.
- Preserve explicit confirmations, backup retention, and recovery-state checks.
- Update built-in help and the README when changing parameters or behavior.
- Avoid introducing dependencies unless they are necessary and documented.

## Reporting bugs

Use the bug report template. Include the PowerShell, Windows, Docker, and
BcContainerHelper versions; source and target BC versions; artifact country;
reproduction steps; and sanitized error output. State whether a run was fresh,
a restore, or a resumed restore.

Do not post credentials, license contents, customer databases, or raw diagnostic
archives. For a suspected security issue, avoid publishing exploit details or
sensitive data in a public issue; contact the repository owner privately.

## Pull requests

Explain the problem and solution, link the related issue, and record the checks
you ran. Explicitly identify changes to container removal, app handling, database
operations, and recovery behavior. Passing CI is not evidence that a live upgrade
has been validated; report offline and live validation separately.
