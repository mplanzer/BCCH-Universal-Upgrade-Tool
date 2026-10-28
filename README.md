# BCCH Universal Upgrade Tool

[![CI](https://github.com/mplanzer/BCCH-Universal-Upgrade-Tool/actions/workflows/ci.yml/badge.svg)](https://github.com/mplanzer/BCCH-Universal-Upgrade-Tool/actions/workflows/ci.yml)

PowerShell tooling for backing up, recreating, and upgrading Microsoft Dynamics
365 Business Central containers with
[BcContainerHelper](https://github.com/microsoft/navcontainerhelper).

The tool retains protected database backups, validates the selected artifact, and
prepares Microsoft application packages for a version-aware restore and upgrade.

> [!WARNING]
> This is an administrative, destructive workflow, not an unattended production
> deployment tool. It can remove and recreate the selected container, modify the
> restored database, and uninstall extensions. Test on a disposable environment
> first and keep an independently verified backup outside the container.

## Capabilities and limits

- Select the latest available artifact, the latest build of a `Major.Minor`
  release, or an exact four-part version.
- Back up an existing container or restore a selected `.bak` file.
- Prepare and upgrade single-tenant databases within the same or next major
  release; larger jumps require supported intermediate releases.
- Resolve Microsoft packages from target artifacts, supplementary packages, and
  source-release artifacts when compatible legacy packages are needed.
- Publish, synchronize non-destructively, and data-upgrade Microsoft apps in
  dependency order.
- Resume a completed restore only when saved state matches the backup hash,
  container identity, target version, and database identity.

**Non-Microsoft apps are not reinstalled or data-upgraded.** Their saved data is
retained and their inventory is recorded in `source-apps.json`. Plan their
reinstallation and upgrade separately. Runtime-only packages are not automatically
recompiled. Prepare encrypted data with the appropriate keys before upgrading.

## Prerequisites

For a **live upgrade**:

- A Windows host running Docker in Windows-container mode, with an OS and
  isolation mode compatible with the Business Central image.
- **Windows PowerShell 5.1**, run as Administrator. The live script explicitly
  rejects PowerShell 7; only the offline tests run on both editions.
- Sufficient disk space for artifact downloads, container images, database
  backups, and a temporary source-version container when preparation is needed.
- Access to Business Central artifact/image downloads and the PowerShell Gallery.
  The script installs BcContainerHelper for the current user if it is missing.
- A valid Business Central license named `latest.bclicense` beside
  [update.ps1](./update.ps1).
- Credentials to assign to the recreated container and restored BC user; the
  script prompts for these interactively.

License files, app packages, backups, and logs are ignored by Git. Never commit
customer data, credentials, or proprietary packages.

> [!IMPORTANT]
> The script accepts the container EULA, updates the host's hosts file, defaults
> the restored user's permission set to `SUPER`, and sets
> `NavHttpClientAntiSSRFEnabled` to `false`. Review these settings before use and
> restrict access to the resulting environment.

## Quick start

Clone the repository and open an **elevated Windows PowerShell 5.1** session:

```powershell
git clone https://github.com/mplanzer/BCCH-Universal-Upgrade-Tool.git
Set-Location .\BCCH-Universal-Upgrade-Tool
```

Place your license at `.\latest.bclicense`, then choose an explicit backup source.
Replace the example versions, container name, country, and paths as appropriate.

### Restore an existing backup

```powershell
.\update.ps1 `
    -ContainerName "bcserver" `
    -Country "ch" `
    -ArtifactVersion "29.0" `
    -RestoreFromBakFile "D:\Backups\database.bak"
```

### Select a protected backup interactively

```powershell
.\update.ps1 -ArtifactVersion "29.0" -SelectBackup
```

### Back up and upgrade an existing container

Pass an empty restore path explicitly to request a fresh backup of the existing
container:

```powershell
.\update.ps1 `
    -ContainerName "bcserver" `
    -ArtifactVersion "29.0" `
    -RestoreFromBakFile ""
```

> [!IMPORTANT]
> The current script has a machine-specific default for `RestoreFromBakFile`.
> Do not rely on that default: always supply a backup path, use `-SelectBackup`,
> or pass `-RestoreFromBakFile ""` for the fresh-backup workflow.

Run the saved script, not pasted or selected script text. If a container already
exists, removal requires typing `RECREATE`. Credentials and optional cleanup also
require interaction; there is no dry-run mode.

## Configuration

| Parameter | Default | Purpose |
| --- | --- | --- |
| `ContainerName` | `bcserver` | Container to recreate or restore. |
| `Hostname` | Container name | Hostname for the recreated container. |
| `ArtifactType` | `onprem` | Business Central artifact type. |
| `Country` | `ch` | Artifact localization. |
| `ArtifactVersion` | Empty | Latest available when omitted; `Major.Minor` selects a release; four parts select an exact build. Pin this for predictable upgrades. |
| `RestoreFromBakFile` | Machine-specific path | Existing backup; explicitly pass an empty string for a fresh backup. |
| `SelectBackup` | Off | Interactively select a backup under `BackupRoot`. |
| `BackupRoot` | `$env:ProgramData\BcContainerUpgradeBackups` | Protected backups and recovery state. |
| `UpgradeAppFolder` | `.\UpgradeApps` beside the script | Supplementary **Microsoft** `.app` packages, not partner-app upgrades. |
| `Isolation` / `UseHyperV` | `process` / Off | Use `-UseHyperV` to override isolation with `hyperv`. |
| `MemoryLimit` | `8G` | Target container memory limit. |
| `Dns` | `8.8.8.8` | Container DNS server; override for your network. |
| `ServerInstance` | `BC` | Business Central server instance. |
| `PermissionSetId` | `SUPER` | Permission set assigned to the restored user. |
| `UpdateBcContainerHelper` | `$false` | Use `-UpdateBcContainerHelper $true` to update an installed helper module. |
| `KeepTemporaryFolders` | Off | Skip the optional temporary-folder cleanup prompt. |
| `SqlTimeout` | `1800` | SQL operation timeout in seconds. |
| `ServiceStartTimeoutSeconds` | `180` | Service and administration endpoint wait timeout in seconds. |

Read the script's built-in help without running an upgrade:

```powershell
Get-Help .\update.ps1 -Detailed
```

## Recovery and troubleshooting

1. Stop the previous script before retrying. Do not run simultaneous upgrades
   against the same container.
2. Keep the original protected backup and any prepared backup, `upgrade-plan.json`,
   `source-apps.json`, and `restore-state.json`. Do not edit recovery metadata.
3. Retry with the **same backup**, container name, backup root, and target version.
   Verified saved restore state may allow the run to resume without recreating
   or restoring again. Otherwise, a fresh restore is required.
4. Never create a new backup of a partially upgraded container over your recovery
   source. Use `-RestoreFromBakFile` or `-SelectBackup`.

Protected backups are not automatically deleted. After success, temporary helper
folders are removed only if you type `DELETE-TEMP` at the cleanup prompt.

Common failures:

| Failure | Check |
| --- | --- |
| Restore backup not found | Supply an explicit existing `.bak` path or choose another backup mode. |
| License file not found | Put `latest.bclicense` beside the script. |
| Docker unavailable | Start Docker, select Windows containers, and verify `docker info`. |
| No matching artifact | Check the version, country, artifact type, and network access. |
| Missing or incompatible Microsoft packages | Supply source-containing, target-compatible Microsoft packages with `-UpgradeAppFolder`. |
| Service startup timeout | Review the script's startup diagnostics and container logs before retrying; increase timeouts only after investigating. |

Sanitize diagnostics before sharing them: logs and inventory can contain customer
names, environment details, and other sensitive information.

## Development and CI

The repository includes a dependency-free offline regression harness:

```powershell
powershell.exe -NoProfile -File .\Test-Update.ps1
pwsh.exe -NoProfile -File .\Test-Update.ps1
```

If local execution policy blocks the unsigned test harness, follow your
organization's signing policy. Where permitted, add `-ExecutionPolicy Bypass`
before `-File` for a process-only override; no machine-wide policy change is needed.

[Test-Update.ps1](./Test-Update.ps1) parses the upgrade script and extracts selected
functions rather than executing the live entry point. Artifact lookups and package
operations use local fixtures, cleaned up after the run. No Docker,
BcContainerHelper, license, elevated session, or live upgrade is needed.

[GitHub Actions](./.github/workflows/ci.yml) checks PowerShell syntax and runs the
harness on Windows PowerShell 5.1 and PowerShell 7 for pushes, pull requests, and
manual dispatches. CI does **not** validate a real database restore, Docker
compatibility, or an end-to-end upgrade. Those require a separate disposable test
environment. Action dependencies are checked monthly by Dependabot.

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md) for development checks and reporting
guidelines. Use the repository's issue and pull request templates to include the
environment, expected behavior, and validation evidence.

## License

No license has been selected for this repository yet. Do not assume permission
to redistribute or reuse the code beyond applicable law; contact the repository
owner for licensing terms. Microsoft artifacts and third-party packages remain
subject to their respective terms.
