#Requires -RunAsAdministrator
#Requires -Version 5.1

<#
.SYNOPSIS
Version-safe Business Central container backup, recreation, and database restore.

.DESCRIPTION
Backs up an existing Business Central container, recreates it on a target artifact,
and restores the databases. ArtifactVersion is optional: when omitted, the latest
available artifact for ArtifactType and Country is selected. Supply ArtifactVersion
as Major.Minor to select the latest available build in that release, or as a full
four-part version when an exact target build is required.

BcContainerHelper reuses its local artifact cache and downloads only files missing
from that cache. The resolved artifact is validated before the existing container
is removed. Container creation always pulls the current generic base image.

Container setup uses explicit file copies with bounded retries instead of
waiting indefinitely for missing files. Copy failures abort setup with an error.
After an interrupted update, stop the old script and use SelectBackup or
RestoreFromBakFile to recreate the container from a protected backup. Do not back
up the partially installed container over your recovery source.

The restored application database is technically converted before starting BC.
After a completed restore, verified recovery state allows an interrupted run to
resume automatically without recreating the container or restoring again.
State must match the backup hash, container ID, target version, and database identity.
Older, untracked restores are not automatically resumed.
When application versions differ, a temporary container on the latest available
source Major.Minor release prepares the database before target conversion. Installed
apps are inventoried and uninstalled without deleting data, then unpublished.
The target apps are published, synchronized (non-destructively), and data-upgraded
in dependency order. A protected prepared backup and package plan are retained.
Only Microsoft apps are reinstalled and data-upgraded on the target. Non-Microsoft
apps are uninstalled without deleting saved data and recorded in source-apps.json;
their packages and upgrade code are not required or executed on the target.
Missing Microsoft apps are also searched in sandbox artifacts for the target
release, then in cached and downloadable source-release artifacts for source-containing legacy packages
that can be republished (recompiled) on the target. These keep their original app
version and saved data; no artificial version bump is performed.
UpgradeAppFolder can supply supplementary Microsoft packages. Missing or
incompatible Microsoft packages stop before source apps are removed.
Runtime-only packages are not automatically recompiled.
Run the saved script file (.\update.ps1), not selected/pasted script text: paths
for supplementary apps and the license are resolved relative to the script file.
Only single-tenant databases and upgrades within the same or next major release
are automated. Encrypted data must be prepared with the appropriate keys first.

.EXAMPLE
.\update.ps1 -ArtifactVersion 29.0 -SelectBackup
Recreates the container using the latest available 29.0 build and a selected backup.

.EXAMPLE
.\update.ps1 -ArtifactVersion 29.0 -RestoreFromBakFile "D:\Backups\database.bak"
Retries an interrupted update using an existing backup without backing up the failed
container. The source backup is retained even if container creation fails.

.EXAMPLE
.\update.ps1 -ArtifactVersion 29.0 -UpgradeAppFolder "D:\BC29\PartnerApps"
Uses supplementary Microsoft packages when upgrading an older backup.
#>

[CmdletBinding()]
param(
    [string] $ContainerName = "bcserver",
    [string] $Hostname = "",
    [string] $ArtifactType = "onprem",
    [string] $Country = "ch",
    [string] $ArtifactVersion = "",
    [string] $Isolation = "process",
    [string] $MemoryLimit = "8G",
    [string] $Dns = "8.8.8.8",
    [string] $ServerInstance = "BC",
    [string] $PermissionSetId = "SUPER",
    [string] $RestoreFromBakFile = "C:\ProgramData\BcContainerUpgradeBackups\bcserver\20261028-103536\database.bak",
    [string] $BackupRoot = "$env:ProgramData\BcContainerUpgradeBackups",
    [string] $UpgradeAppFolder = "",
    [bool] $UpdateBcContainerHelper = $false,
    [switch] $SelectBackup,
    [switch] $UseHyperV,
    [switch] $KeepTemporaryFolders,
    [int] $SqlTimeout = 1800,
    [int] $ServiceStartTimeoutSeconds = 180
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    throw "Run the saved script file with & 'C:\Temp\update.ps1', not selected or pasted script text. The script directory is required to locate UpgradeApps and latest.bclicense."
}
if ([string]::IsNullOrWhiteSpace($UpgradeAppFolder)) {
    $UpgradeAppFolder = Join-Path $PSScriptRoot "UpgradeApps"
}
$UpgradeAppFolder = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($UpgradeAppFolder)

function Write-Step {
    param([Parameter(Mandatory = $true)][string] $Message)

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host $Message -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
}

function Assert-Command {
    param([Parameter(Mandatory = $true)][string] $Name)

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command '$Name' was not found."
    }
}

function Test-ContainerExists {
    param([Parameter(Mandatory = $true)][string] $Name)

    $ContainerNames = @(docker ps -a --format "{{.Names}}")
    if ($LASTEXITCODE -ne 0) {
        throw "Docker could not list containers."
    }

    return $ContainerNames -contains $Name
}

function New-ProtectedDirectory {
    param([Parameter(Mandatory = $true)][string] $Path)

    if (Test-Path -LiteralPath $Path) {
        throw "Refusing to reuse an existing protected directory: $Path"
    }

    $Parent = Split-Path -Path $Path -Parent
    if (-not (Test-Path -LiteralPath $Parent -PathType Container)) {
        New-Item -ItemType Directory -Path $Parent -Force | Out-Null
    }

    New-Item -ItemType Directory -Path $Path | Out-Null
}

function Get-ValidBakFiles {
    param([Parameter(Mandatory = $true)][string] $Folder)

    return @(
        Get-ChildItem `
            -LiteralPath $Folder `
            -Filter "*.bak" `
            -File `
            -ErrorAction SilentlyContinue |
        Where-Object { $_.Length -gt 0 }
    )
}

function Assert-BakFilesExist {
    param(
        [Parameter(Mandatory = $true)][string] $Folder,
        [Parameter(Mandatory = $true)][string] $Message
    )

    $Files = @(Get-ValidBakFiles -Folder $Folder)
    if ($Files.Count -eq 0) {
        throw $Message
    }

    return $Files
}

function Copy-FileNoOverwrite {
    param(
        [Parameter(Mandatory = $true)][string] $SourceFile,
        [Parameter(Mandatory = $true)][string] $DestinationFolder,
        [string] $DestinationName = ""
    )

    if (-not (Test-Path -LiteralPath $SourceFile -PathType Leaf)) {
        throw "Source file does not exist: $SourceFile"
    }

    if (-not (Test-Path -LiteralPath $DestinationFolder -PathType Container)) {
        throw "Destination folder does not exist: $DestinationFolder"
    }

    if ([string]::IsNullOrWhiteSpace($DestinationName)) {
        $DestinationName = [IO.Path]::GetFileName($SourceFile)
    }
    $DestinationFile = Join-Path $DestinationFolder $DestinationName

    if (Test-Path -LiteralPath $DestinationFile) {
        throw "Refusing to overwrite existing file: $DestinationFile"
    }

    Copy-Item -LiteralPath $SourceFile -Destination $DestinationFile
    Write-Host "Copied: $SourceFile"
    Write-Host "    To: $DestinationFile"
}

function Copy-BakFilesNoOverwrite {
    param(
        [Parameter(Mandatory = $true)][string] $SourceFolder,
        [Parameter(Mandatory = $true)][string] $DestinationFolder
    )

    $Files = Assert-BakFilesExist `
        -Folder $SourceFolder `
        -Message "No non-empty .bak files were found in '$SourceFolder'."

    foreach ($File in $Files) {
        Copy-FileNoOverwrite `
            -SourceFile $File.FullName `
            -DestinationFolder $DestinationFolder
    }
}

function Select-BackupFile {
    param(
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][string] $PreferredContainerName
    )

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        throw "Backup root does not exist: $Root"
    }

    $SearchRoot = $Root
    $ContainerRoot = Join-Path $Root $PreferredContainerName
    if (Test-Path -LiteralPath $ContainerRoot -PathType Container) {
        $SearchRoot = $ContainerRoot
    }

    $Backups = @(
        Get-ChildItem `
            -LiteralPath $SearchRoot `
            -Filter "*.bak" `
            -File `
            -Recurse `
            -ErrorAction SilentlyContinue |
        Where-Object { $_.Length -gt 0 } |
        Sort-Object LastWriteTime -Descending
    )

    if ($Backups.Count -eq 0) {
        throw "No non-empty .bak files were found below '$SearchRoot'."
    }

    Write-Step "Select a protected database backup"
    Write-Host "Search root: $SearchRoot" -ForegroundColor Yellow
    Write-Host "Press Enter for the newest backup, enter a number, or Q to abort."

    $DisplayedCount = [Math]::Min($Backups.Count, 25)
    for ($Index = 0; $Index -lt $DisplayedCount; $Index++) {
        $Backup = $Backups[$Index]
        $SizeGB = [Math]::Round($Backup.Length / 1GB, 2)
        Write-Host ("[{0}] {1:yyyy-MM-dd HH:mm:ss}  {2,7} GB  {3}" -f `
            ($Index + 1),
            $Backup.LastWriteTime,
            $SizeGB,
            $Backup.FullName)
    }

    while ($true) {
        $Answer = Read-Host "Backup number [default: 1]"

        if ([string]::IsNullOrWhiteSpace($Answer)) {
            $Selection = 1
        }
        elseif ($Answer -match '^[Qq]$') {
            throw "Backup selection was aborted."
        }
        elseif ($Answer -match '^\d+$') {
            $Selection = [int]$Answer
        }
        else {
            Write-Warning "Enter a number from 1 to $DisplayedCount, Enter, or Q."
            continue
        }

        if ($Selection -ge 1 -and $Selection -le $DisplayedCount) {
            return $Backups[$Selection - 1].FullName
        }

        Write-Warning "Selection must be between 1 and $DisplayedCount."
    }
}

function Assert-ArtifactVersion {
    param(
        [Parameter(Mandatory = $true)][string] $Url,
        [string] $RequiredVersion
    )

    $VersionMatch = [Regex]::Match($Url, '/(?<Version>\d+\.\d+\.\d+\.\d+)/')
    if (-not $VersionMatch.Success) {
        throw "Cannot determine the Business Central version from resolved artifact URL: $Url"
    }

    $ResolvedVersion = $VersionMatch.Groups['Version'].Value
    if (-not [string]::IsNullOrWhiteSpace($RequiredVersion)) {
        $Requested = [version]$RequiredVersion
        $Resolved = [version]$ResolvedVersion
        $VersionMatches = if ($Requested.Build -lt 0) {
            $Resolved.Major -eq $Requested.Major -and $Resolved.Minor -eq $Requested.Minor
        }
        else {
            $Resolved -eq $Requested
        }

        if (-not $VersionMatches) {
            throw "Resolved artifact does not match requested version '$RequiredVersion'. Resolved URL: $Url"
        }
    }

    return $ResolvedVersion
}

function Get-ContainerSetupScripts {
    return @{
        "HelperFunctions.ps1" = {
            # Keep the image's helpers, replacing only its unbounded copy/wait loop.
            . 'C:\Run\HelperFunctions.ps1'

            function RoboCopyFiles {
                param(
                    [string] $source,
                    [string] $destination,
                    [string] $files = "*",
                    [switch] $e
                )

                if (-not (Test-Path -LiteralPath $source -PathType Container)) {
                    throw "Copy source directory does not exist: $source"
                }

                $SourceRoot = [IO.Path]::GetFullPath($source).TrimEnd('\') + '\'
                $SourceItems = @(Get-ChildItem -LiteralPath $source -Filter $files `
                    -Recurse:$e.IsPresent -Force -ErrorAction Stop)
                [IO.Directory]::CreateDirectory($destination) | Out-Null
                foreach ($Item in $SourceItems) {
                    $RelativePath = $Item.FullName.Substring($SourceRoot.Length)
                    $DestinationPath = Join-Path $destination $RelativePath
                    if ($Item.PSIsContainer) {
                        [IO.Directory]::CreateDirectory($DestinationPath) | Out-Null
                        if (-not (Test-Path -LiteralPath $DestinationPath -PathType Container)) {
                            throw "Copy verification failed: destination directory is missing: $DestinationPath"
                        }
                    }
                    else {
                        [IO.Directory]::CreateDirectory(
                            [IO.Path]::GetDirectoryName($DestinationPath)
                        ) | Out-Null
                        for ($Attempt = 0; $Attempt -le 3; $Attempt++) {
                            try {
                                Copy-Item -LiteralPath $Item.FullName -Destination $DestinationPath `
                                    -Force -ErrorAction Stop
                                break
                            }
                            catch [IO.IOException] {
                                if ($Attempt -eq 3) {
                                    throw "Copy failed after 4 attempts: '$($Item.FullName)' -> '$DestinationPath'. $($_.Exception.Message)"
                                }
                                Write-Warning "Copy attempt $($Attempt + 1) failed for '$DestinationPath': $($_.Exception.Message). Retrying in 2 seconds."
                                Start-Sleep -Seconds 2
                            }
                        }

                        if (-not (Test-Path -LiteralPath $DestinationPath -PathType Leaf)) {
                            throw "Copy verification failed: destination file is missing: $DestinationPath"
                        }
                        $CopiedFile = Get-Item -LiteralPath $DestinationPath -Force -ErrorAction Stop
                        if ($CopiedFile.Length -ne $Item.Length) {
                            throw "Copy verification failed: file length differs: $DestinationPath"
                        }
                    }
                }
            }
        }
    }
}

function Get-BcDatabaseTarget {
    param(
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][string] $Instance
    )

    Invoke-ScriptInBcContainer -containerName $Name -useSession:$false -scriptblock {
        param($Instance)
        $ErrorActionPreference = "Stop"
        $Settings = @{}
        # Some BC releases return one XPathNodeList instead of individual elements.
        foreach ($Result in @(Get-NAVServerConfiguration -ServerInstance $Instance -ErrorAction Stop)) {
            $Entries = if ($Result.PSObject.Properties["key"]) { @($Result) } else { $Result }
            foreach ($Entry in $Entries) {
                if ($Entry.PSObject.Properties["key"]) { $Settings[[string]$Entry.key] = [string]$Entry.value }
            }
        }
        if ($Settings["Multitenant"] -ieq "true") {
            throw "Automatic restore/conversion supports single-tenant containers only."
        }
        if ([string]::IsNullOrWhiteSpace($Settings["DatabaseServer"]) -or
            [string]::IsNullOrWhiteSpace($Settings["DatabaseName"])) {
            throw "Database server or database name is missing for instance '$Instance'."
        }
        [pscustomobject]@{
            Server = $Settings["DatabaseServer"]
            Instance = $Settings["DatabaseInstance"]
            Name = $Settings["DatabaseName"]
        }
    } -argumentList $Instance
}

function Get-RestoreDatabaseIdentity {
    param(
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)] $Database
    )

    Invoke-ScriptInBcContainer -containerName $Name -useSession:$false -usePwsh:$false -scriptblock {
        param($Server, $Instance, $DatabaseName)
        $ErrorActionPreference = "Stop"
        if ($Instance) { $Server = "$Server\$Instance" }
        $Builder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
        $Builder["Data Source"] = $Server
        $Builder["Initial Catalog"] = "master"
        $Builder["Integrated Security"] = $true
        $Connection = New-Object System.Data.SqlClient.SqlConnection $Builder.ConnectionString
        try {
            $Connection.Open()
            $Command = $Connection.CreateCommand()
            $Command.CommandText = "SELECT CONVERT(nvarchar(36), database_guid) + ':' + CONVERT(nvarchar(36), recovery_fork_guid) FROM sys.database_recovery_status WHERE database_id = DB_ID(@name)"
            $null = $Command.Parameters.Add("@name", [System.Data.SqlDbType]::NVarChar, 128)
            $Command.Parameters["@name"].Value = $DatabaseName
            $Identity = $Command.ExecuteScalar()
            if ($null -eq $Identity -or $Identity -is [DBNull] -or -not $Identity) {
                throw "Cannot identify restored database '$DatabaseName'."
            }
            [string]$Identity
        }
        finally {
            $Connection.Dispose()
        }
    } -argumentList @($Database.Server, $Database.Instance, $Database.Name)
}

function Get-ContainerIdentity {
    param([Parameter(Mandatory = $true)][string] $Name)
    $Id = docker inspect --format "{{.Id}}" $Name
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]$Id)) {
        throw "Cannot identify container '$Name'."
    }
    return [string]$Id
}

function Test-RestoreStateMatch {
    param($State, $Current)
    foreach ($Key in @("Schema", "BackupHash", "ContainerId", "Version", "ServerInstance",
        "DatabaseServer", "DatabaseInstance", "DatabaseName", "DatabaseIdentity")) {
        $Property = $State.PSObject.Properties[$Key]
        if ($null -eq $Property -or [string]$Property.Value -cne [string]$Current[$Key]) {
            return $false
        }
    }
    return $true
}

function Save-BcRestoreState {
    param($State, [string] $Path)
    $Directory = Split-Path -Path $Path -Parent
    New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    $Pending = Join-Path $Directory ("restore-state-" + [guid]::NewGuid().ToString("N") + ".tmp")
    try {
        $State | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Pending -Encoding UTF8
        Move-Item -LiteralPath $Pending -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $Pending) { Remove-Item -LiteralPath $Pending -Force }
    }
}

function Get-RestoredBcApps {
    param([string] $Name, $Database)

    Invoke-ScriptInBcContainer -containerName $Name -useSession:$false -usePwsh:$false -scriptblock {
        param($Server, $Instance, $DatabaseName)
        $ErrorActionPreference = "Stop"
        $Builder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
        $Builder["Data Source"] = if ($Instance) { "$Server\$Instance" } else { $Server }
        $Builder["Initial Catalog"] = $DatabaseName
        $Builder["Integrated Security"] = $true
        $Connection = New-Object System.Data.SqlClient.SqlConnection $Builder.ConnectionString
        try {
            $Connection.Open()
            $Command = $Connection.CreateCommand()
            $Command.CommandText = "SELECT [App ID], [Name], [Publisher], [Version Major], [Version Minor], [Version Build], [Version Revision] FROM [dbo].[NAV App Installed App]"
            $Reader = $Command.ExecuteReader()
            try {
                while ($Reader.Read()) {
                    [pscustomobject]@{
                        Id = $Reader.GetGuid(0).ToString()
                        Name = $Reader.GetString(1)
                        Publisher = $Reader.GetString(2)
                        Version = "{0}.{1}.{2}.{3}" -f $Reader.GetInt32(3),
                            $Reader.GetInt32(4), $Reader.GetInt32(5), $Reader.GetInt32(6)
                    }
                }
            }
            finally { $Reader.Dispose() }
        }
        finally { $Connection.Dispose() }
    } -argumentList @($Database.Server, $Database.Instance, $Database.Name)
}

function Get-UpgradePackagePlan {
    param(
        [object[]] $InstalledApps,
        [string[]] $ArtifactPaths,
        [string] $PartnerFolder,
        [string] $TargetVersion,
        [string] $PlatformVersion = $TargetVersion,
        [string[]] $FallbackArtifactPaths = @(),
        [switch] $CloudArtifactsIncluded,
        [switch] $SourceArtifactsIncluded
    )

    Assert-Command "Get-AppJsonFromAppFile"
    Assert-Command "Sort-AppFilesByDependencies"
    $Candidates = @{}
    $InstalledById = @{}
    foreach ($App in $InstalledApps) {
        $InstalledById[([guid]$App.Id).ToString()] = $App
    }
    $SupplementaryFolderExists = Test-Path -LiteralPath $PartnerFolder -PathType Container
    Write-Host "Supplementary upgrade packages: $PartnerFolder (folder exists: $SupplementaryFolderExists)"
    foreach ($Folder in @($ArtifactPaths) + @($PartnerFolder) + @($FallbackArtifactPaths)) {
        if (-not (Test-Path -LiteralPath $Folder -PathType Container)) {
            if ($Folder -eq $PartnerFolder) { continue }
            throw "Target artifact folder is missing: $Folder"
        }
        foreach ($File in Get-ChildItem -LiteralPath $Folder -Filter "*.app" -File -Recurse) {
            $Manifest = Get-AppJsonFromAppFile -appFile $File.FullName
            if ($Manifest.publisher -ne "Microsoft") { continue }
            $Id = ([guid]$Manifest.id).ToString()
            $IsFallback = $Folder -in $FallbackArtifactPaths
            if ($IsFallback -and $Candidates.ContainsKey($Id) -and -not $Candidates[$Id].IsFallback) {
                continue
            }
            $Version = [version]$Manifest.version
            if ($InstalledById.ContainsKey($Id)) {
                $Installed = $InstalledById[$Id]
                if ($Manifest.name -ne $Installed.Name -or $Manifest.publisher -ne $Installed.Publisher) {
                    throw "Invalid replacement for '$($Installed.Name)': package identity differs: $($File.FullName)."
                }
                if ($Version -lt [version]$Installed.Version) {
                    Write-Warning "Ignoring package older than installed $($Installed.Version): $($File.FullName) ($Version)"
                    continue
                }
            }
            if ($Manifest.name -in @("Base Application", "System Application") -and
                $Version -ne [version]$TargetVersion) {
                continue
            }
            if (-not $Candidates.ContainsKey($Id) -or $Version -gt [version]$Candidates[$Id].Version) {
                $Candidates[$Id] = [pscustomobject]@{
                    Id = $Id
                    Name = [string]$Manifest.name
                    Publisher = [string]$Manifest.publisher
                    Version = $Version.ToString()
                    Dependencies = @($Manifest.dependencies)
                    File = $File.FullName
                    SourceVersion = ""
                    IsFallback = $IsFallback
                    ApplicationRequirement = if ($Manifest.PSObject.Properties["application"]) {
                        [string]$Manifest.application
                    } else { "" }
                    PlatformRequirement = if ($Manifest.PSObject.Properties["platform"]) {
                        [string]$Manifest.platform
                    } else { "" }
                }
            }
        }
    }

    $Missing = @()
    $MissingApps = @()
    $Pending = New-Object 'System.Collections.Generic.Queue[string]'
    foreach ($App in $InstalledApps) {
        if ($App.Publisher -ne "Microsoft") {
            Write-Warning "Leaving non-Microsoft app uninstalled on target (saved data retained): $($App.Publisher) / $($App.Name) $($App.Version)"
            continue
        }
        $Id = ([guid]$App.Id).ToString()
        if (-not $Candidates.ContainsKey($Id)) {
            $Missing += "$($App.Publisher) / $($App.Name) ($($App.Id)), installed $($App.Version)"
            $MissingApps += $App
            continue
        }
        $Candidate = $Candidates[$Id]
        if ($App.Publisher -eq "Microsoft" -and $App.Name -in @("Base Application", "System Application") -and
            (([version]$Candidate.Version).Major -ne ([version]$TargetVersion).Major -or
             ([version]$Candidate.Version).Minor -ne ([version]$TargetVersion).Minor)) {
            throw "Core package '$($App.Name)' $($Candidate.Version) does not match target release $TargetVersion."
        }
        if ($Candidate.Name -ne $App.Name -or $Candidate.Publisher -ne $App.Publisher -or
            [version]$Candidate.Version -lt [version]$App.Version) {
            throw "Invalid replacement for '$($App.Name)': package identity differs or version $($Candidate.Version) is older than $($App.Version)."
        }
        $Candidate.SourceVersion = [string]$App.Version
        $Pending.Enqueue($Id)
    }
    if ($Missing.Count) {
        if (-not $CloudArtifactsIncluded) {
            Write-Step "Resolving sandbox artifacts for missing Microsoft extensions"
            $CloudUrl = Get-BcArtifactUrl -type sandbox -country $Country -version $TargetVersion -select Closest
            $CloudVersion = if ($CloudUrl) {
                Assert-ArtifactVersion -Url ([string]$CloudUrl)
            }
            else { "" }
            if (-not $CloudVersion -or [version]$CloudVersion -ne [version]$TargetVersion) {
                $Release = "{0}.{1}" -f ([version]$TargetVersion).Major, ([version]$TargetVersion).Minor
                Write-Warning "Exact sandbox build $TargetVersion is unavailable; checking the latest $Release sandbox packages for compatibility."
                $CloudUrl = Get-BcArtifactUrl -type sandbox -country $Country -version $Release -select Latest
                if ($CloudUrl) {
                    $null = Assert-ArtifactVersion -Url ([string]$CloudUrl) -RequiredVersion $Release
                }
            }
            if (-not $CloudUrl) {
                throw "No sandbox artifacts are available for target $TargetVersion/$Country. Missing Microsoft apps:`n$($Missing -join "`n")`nSupply compatible Microsoft packages in '$PartnerFolder'. No source apps have been removed."
            }
            $CloudPaths = @(Download-Artifacts -artifactUrl $CloudUrl -includePlatform)
            if (-not $CloudPaths.Count) { throw "Sandbox artifact download returned no package directories." }
            return Get-UpgradePackagePlan -InstalledApps $InstalledApps `
                -ArtifactPaths $ArtifactPaths -FallbackArtifactPaths $CloudPaths -PartnerFolder $PartnerFolder `
                -TargetVersion $TargetVersion -PlatformVersion $PlatformVersion -CloudArtifactsIncluded `
                -SourceArtifactsIncluded:$SourceArtifactsIncluded
        }
        if (-not $SourceArtifactsIncluded) {
            Write-Step "Resolving source packages for legacy Microsoft extensions"
            $LegacyPaths = @($FallbackArtifactPaths)
            $SourceReleases = @($MissingApps | ForEach-Object {
                "{0}.{1}" -f ([version]$_.Version).Major, ([version]$_.Version).Minor
            } | Sort-Object -Unique)
            # Download-Artifacts uses <cache>\<type>\<version>\<country|platform>.
            $CacheRoots = @($ArtifactPaths | ForEach-Object {
                $VersionFolder = Split-Path -Parent $_
                $TypeFolder = Split-Path -Parent $VersionFolder
                if ((Split-Path -Leaf $VersionFolder) -match '^\d+\.\d+\.\d+\.\d+$' -and
                    (Split-Path -Leaf $TypeFolder) -in @("onprem", "sandbox")) {
                    Split-Path -Parent $TypeFolder
                }
            } | Select-Object -Unique)
            foreach ($CacheRoot in $CacheRoots) {
                foreach ($Type in @("onprem", "sandbox")) {
                    $TypeFolder = Join-Path $CacheRoot $Type
                    if (-not (Test-Path -LiteralPath $TypeFolder -PathType Container)) { continue }
                    foreach ($CachedVersion in Get-ChildItem -LiteralPath $TypeFolder -Directory) {
                        if ($CachedVersion.Name -notmatch '^\d+\.\d+\.\d+\.\d+$') { continue }
                        $Release = "{0}.{1}" -f ([version]$CachedVersion.Name).Major, ([version]$CachedVersion.Name).Minor
                        if ($Release -notin $SourceReleases) { continue }
                        foreach ($Part in @($Country, "platform")) {
                            $CachedPath = Join-Path $CachedVersion.FullName $Part
                            if (Test-Path -LiteralPath $CachedPath -PathType Container) {
                                Write-Host "Checking cached source packages: $CachedPath"
                                $LegacyPaths += $CachedPath
                            }
                        }
                    }
                }
            }
            foreach ($Release in $SourceReleases) {
                foreach ($Type in @("onprem", "sandbox")) {
                    $SourceUrl = Get-BcArtifactUrl -type $Type -country $Country -version $Release -select Latest
                    if (-not $SourceUrl) {
                        Write-Warning "No $Type source artifact available for $Release/$Country."
                        continue
                    }
                    $null = Assert-ArtifactVersion -Url ([string]$SourceUrl) -RequiredVersion $Release
                    $Paths = @(Download-Artifacts -artifactUrl $SourceUrl -includePlatform)
                    if (-not $Paths.Count) { throw "Source artifact download returned no package directories: $SourceUrl" }
                    $LegacyPaths += $Paths
                }
            }
            Write-Warning "Legacy Microsoft packages must pass dependency, source-package, and target publish/compile checks. They retain their original version and are reinstalled with saved data."
            return Get-UpgradePackagePlan -InstalledApps $InstalledApps `
                -ArtifactPaths $ArtifactPaths -FallbackArtifactPaths @($LegacyPaths | Select-Object -Unique) `
                -PartnerFolder $PartnerFolder -TargetVersion $TargetVersion -PlatformVersion $PlatformVersion `
                -CloudArtifactsIncluded -SourceArtifactsIncluded
        }
        $FolderStatus = if ($SupplementaryFolderExists) {
            "The supplementary folder was searched, but it does not supply all required app IDs."
        }
        else {
            "The supplementary folder does not exist. Create it and supply the required packages."
        }
        throw "Compatible Microsoft packages are still missing after searching target and source on-premises/sandbox artifacts:`n$($Missing -join "`n")`n$FolderStatus`nSupplementary folder: '$PartnerFolder'. Microsoft apps cannot be assumed obsolete. No source apps have been removed."
    }

    $Selected = @{}
    while ($Pending.Count) {
        $Id = $Pending.Dequeue()
        if ($Selected.ContainsKey($Id)) { continue }
        $App = $Candidates[$Id]
        if ($App.ApplicationRequirement -and [version]$App.ApplicationRequirement -gt [version]$TargetVersion) {
            throw "Microsoft package '$($App.Name)' requires application $($App.ApplicationRequirement), newer than target $TargetVersion. Supply a compatible package in '$PartnerFolder'."
        }
        if ($App.PlatformRequirement -and [version]$App.PlatformRequirement -gt [version]$PlatformVersion) {
            throw "Microsoft package '$($App.Name)' requires platform $($App.PlatformRequirement), newer than installed target platform $PlatformVersion. Supply a compatible package in '$PartnerFolder'."
        }
        $Selected[$Id] = $App
        foreach ($Dependency in $App.Dependencies) {
            $DependencyId = ([guid]$Dependency.id).ToString()
            if (-not $Candidates.ContainsKey($DependencyId) -or
                [version]$Candidates[$DependencyId].Version -lt [version]$Dependency.version) {
                throw "Missing or too-old dependency '$($Dependency.name)' $($Dependency.version) required by '$($App.Name)'."
            }
            $Pending.Enqueue($DependencyId)
        }
    }

    # Validate cycles before calling the helper's recursive dependency sorter.
    $Remaining = @{} + $Selected
    $Visited = @{}
    while ($Remaining.Count) {
        $Ready = @($Remaining.Values | Where-Object {
            $Blocked = $false
            foreach ($Dependency in $_.Dependencies) {
                if (-not $Visited.ContainsKey(([guid]$Dependency.id).ToString())) { $Blocked = $true }
            }
            -not $Blocked
        })
        if (-not $Ready.Count) { throw "Cyclic app dependencies prevent a safe upgrade." }
        foreach ($App in $Ready) { $Visited[$App.Id] = $true; $Remaining.Remove($App.Id) }
    }

    $Unknown = @()
    $Sorted = @(Sort-AppFilesByDependencies -appFiles @($Selected.Values.File) `
        -excludeRuntimePackages -unknownDependencies ([ref]$Unknown))
    if ($Unknown.Count -or $Sorted.Count -ne $Selected.Count) {
        throw "The upgrade package set has unresolved dependencies or runtime-only packages. Supply source-containing, target-compatible packages."
    }
    foreach ($File in $Sorted) {
        $Selected.Values | Where-Object { $_.File -eq $File }
    }
}

function Restore-BcDatabaseWithoutStart {
    param([string] $Name, [string] $Instance, [string] $BakFile, $Database, [int] $Timeout)
    Invoke-ScriptInBcContainer -containerName $Name -useSession:$false -scriptblock {
        param($Instance)
        $ErrorActionPreference = "Stop"
        $Service = Get-Service -Name ('MicrosoftDynamicsNavServer$' + $Instance) -ErrorAction Stop
        if ($Service.Status -ne "Stopped") { Stop-Service -InputObject $Service -ErrorAction Stop }
        $Service.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Stopped,
            [TimeSpan]::FromSeconds(60))
    } -argumentList $Instance | Out-Host
    Restore-DatabasesInBcContainer -containerName $Name -bakFile $BakFile `
        -databaseName $Database.Name -sqlTimeout $Timeout
}

function New-PreparedBcUpgrade {
    param(
        [object[]] $InstalledApps,
        [string] $SourceVersion,
        [string] $TargetVersion,
        [string[]] $ArtifactPaths,
        [string] $BackupFile,
        [string] $ExpectedBackupHash,
        [pscredential] $Credential
    )

    $SourceRelease = "{0}.{1}" -f ([version]$SourceVersion).Major, ([version]$SourceVersion).Minor
    $Target = [version]$TargetVersion
    $Source = [version]$SourceVersion
    if ($Source -gt $Target -or $Target.Major -gt ($Source.Major + 1)) {
        throw "Automatic application upgrade supports forward upgrades within the same or next major release only. Source: $SourceVersion; target: $TargetVersion. Use a supported intermediate release."
    }
    Write-Step "Checking target packages before source application preparation"
    $SourceLicenseFile = Join-Path $PSScriptRoot "latest.bclicense"
    if (-not (Test-Path -LiteralPath $SourceLicenseFile -PathType Leaf)) {
        throw "License file was not found: $SourceLicenseFile"
    }
    $Packages = @(Get-UpgradePackagePlan -InstalledApps $InstalledApps -ArtifactPaths $ArtifactPaths `
        -PartnerFolder $UpgradeAppFolder -TargetVersion $TargetVersion `
        -PlatformVersion ([string](Get-BcContainerPlatformVersion -containerOrImageName $ContainerName)))
    $SourceUrl = Get-BcArtifactUrl -type $ArtifactType -country $Country -version $SourceRelease -select Latest
    if (-not $SourceUrl) { throw "No source runtime is available for $SourceRelease/$Country. The database has not been prepared or stripped of apps." }
    $null = Assert-ArtifactVersion -Url ([string]$SourceUrl) -RequiredVersion $SourceRelease
    $null = Download-Artifacts -artifactUrl $SourceUrl -includePlatform
    $UpgradeFolder = Join-Path $BackupRoot "$ContainerName\upgrade-$([guid]::NewGuid().ToString('N'))"
    New-ProtectedDirectory -Path $UpgradeFolder
    $PackageFolder = Join-Path $UpgradeFolder "packages"
    New-ProtectedDirectory -Path $PackageFolder
    $PlanPackages = @(
        foreach ($Package in $Packages) {
            $PackageFile = Join-Path $PackageFolder "$($Package.Id).app"
            Copy-Item -LiteralPath $Package.File -Destination $PackageFile -ErrorAction Stop
            [pscustomobject]@{
                Id = $Package.Id
                Name = $Package.Name
                Publisher = $Package.Publisher
                Version = $Package.Version
                SourceVersion = $Package.SourceVersion
                File = $PackageFile
                Hash = (Get-FileHash -LiteralPath $PackageFile -Algorithm SHA256).Hash
            }
        }
    )
    $InstalledApps | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $UpgradeFolder "source-apps.json") -Encoding UTF8
    $SourceName = $ContainerName.Substring(0, [Math]::Min(25, $ContainerName.Length)) + "-source-" + [guid]::NewGuid().ToString("N").Substring(0, 8)
    $SourceBackupFolder = Join-Path $env:ProgramData "BcContainerHelper\Extensions\$SourceName\prepared"
    $SourceRestoreFolder = Join-Path $env:ProgramData "BcContainerHelper\Extensions\$SourceName\restore"

    Write-Step "Preparing restored apps under source runtime $SourceRelease (container $SourceName)"
    New-BcContainer -accept_eula -containerName $SourceName -hostname $SourceName `
        -artifactUrl $SourceUrl -credential $Credential -auth UserPassword -useBestContainerOS -alwaysPull `
        -memoryLimit $MemoryLimit -isolation $Isolation -dns $Dns -licenseFile $SourceLicenseFile `
        -myScripts @((Get-ContainerSetupScripts)) | Out-Host
    # Keep the source container on failure for diagnostics; remove it only after a protected backup exists.
    New-ProtectedDirectory -Path $SourceRestoreFolder
    Copy-FileNoOverwrite -SourceFile $BackupFile -DestinationFolder $SourceRestoreFolder -DestinationName "database.bak"
    if ((Get-FileHash -LiteralPath (Join-Path $SourceRestoreFolder "database.bak") -Algorithm SHA256).Hash -cne $ExpectedBackupHash) {
        throw "Source-runtime restore copy does not match the original verified backup."
    }
    $SourceDatabase = Get-BcDatabaseTarget -Name $SourceName -Instance $ServerInstance
    Restore-BcDatabaseWithoutStart -Name $SourceName -Instance $ServerInstance `
        -BakFile (Join-Path $SourceRestoreFolder "database.bak") -Database $SourceDatabase -Timeout $SqlTimeout
    Set-BcContainerServerConfiguration -containerName $SourceName -keyName EnableTaskScheduler -keyValue false | Out-Host
    Convert-RestoredBcDatabase -Name $SourceName -Instance $ServerInstance -Database $SourceDatabase
    Wait-ForBcService -Name $SourceName -Instance $ServerInstance -TimeoutSeconds $ServiceStartTimeoutSeconds
    Wait-ForBcAdminEndpoint -Name $SourceName -Instance $ServerInstance -TimeoutSeconds $ServiceStartTimeoutSeconds

    Invoke-ScriptInBcContainer -containerName $SourceName -useSession:$false -scriptblock {
        param($Instance, $ExpectedApps)
        $ErrorActionPreference = "Stop"
        $Installed = @(Get-NAVAppInfo -ServerInstance $Instance -Tenant default -ErrorAction Stop)
        if ($Installed.Count -ne @($ExpectedApps).Count) {
            throw "Source app inventory changed; refusing to remove apps."
        }
        foreach ($Expected in $ExpectedApps) {
            if (-not ($Installed | Where-Object { [string]$_.AppId -eq $Expected.Id -and [string]$_.Version -eq $Expected.Version })) {
                throw "Source app inventory changed: $($Expected.Name) $($Expected.Version)."
            }
        }
        $Published = @(Get-NAVAppInfo -ServerInstance $Instance -ErrorAction Stop)
        $Remaining = @($Published)
        while ($Remaining.Count) {
            $Leaves = @($Remaining | Where-Object {
                $CandidateId = [string]$_.AppId
                -not ($Remaining | Where-Object {
                    @($_.Dependencies | Where-Object { [string]$_.AppId -eq $CandidateId }).Count -gt 0
                })
            })
            if (-not $Leaves.Count) { throw "Cannot order source apps for uninstall: cyclic dependencies." }
            foreach ($App in $Leaves) {
                if ($Installed | Where-Object { $_.AppId -eq $App.AppId -and $_.Version -eq $App.Version }) {
                    Uninstall-NAVApp -ServerInstance $Instance -Tenant default -AppId $App.AppId `
                        -Version $App.Version -Force -ErrorAction Stop
                }
                Unpublish-NAVApp -ServerInstance $Instance -AppId $App.AppId -Version $App.Version -ErrorAction Stop
                $Remaining = @($Remaining | Where-Object { $_.AppId -ne $App.AppId -or $_.Version -ne $App.Version })
            }
        }
        Get-NAVAppInfo -ServerInstance $Instance -SymbolsOnly -ErrorAction Stop |
            ForEach-Object { Unpublish-NAVApp -ServerInstance $Instance -AppId $_.AppId -Version $_.Version -ErrorAction Stop }
        if (@(Get-NAVAppInfo -ServerInstance $Instance -Tenant default -ErrorAction Stop).Count) {
            throw "Source apps remain installed; refusing to create a prepared upgrade backup."
        }
    } -argumentList @($ServerInstance, $InstalledApps) | Out-Host
    New-ProtectedDirectory -Path $SourceBackupFolder
    Backup-BcContainerDatabases -containerName $SourceName -bakFolder $SourceBackupFolder | Out-Host
    Copy-FileNoOverwrite -SourceFile (Join-Path $SourceBackupFolder "database.bak") -DestinationFolder $UpgradeFolder
    $PreparedBackup = Join-Path $UpgradeFolder "database.bak"
    if ((Get-Item -LiteralPath $PreparedBackup).Length -le 0) { throw "Prepared backup is empty; source container retained: $SourceName" }
    $Plan = [pscustomobject]@{
        Policy = "MicrosoftOnly"
        SourceVersion = $SourceVersion
        TargetVersion = $TargetVersion
        BackupFile = $PreparedBackup
        BackupHash = (Get-FileHash -LiteralPath $PreparedBackup -Algorithm SHA256).Hash
        TaskSchedulerEnabled = Invoke-ScriptInBcContainer -containerName $ContainerName -useSession:$false -scriptblock {
            param($Instance)
            (Get-NAVServerConfiguration -ServerInstance $Instance -ErrorAction Stop |
                Where-Object { $_.key -eq "EnableTaskScheduler" }).value
        } -argumentList $ServerInstance
        Packages = $PlanPackages
    }
    $PlanPath = Join-Path $UpgradeFolder "upgrade-plan.json"
    $Plan | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $PlanPath -Encoding UTF8
    Remove-BcContainer -containerName $SourceName | Out-Host
    Write-Host "Protected prepared backup and package plan: $UpgradeFolder" -ForegroundColor Green
    return $PlanPath
}

function Invoke-TargetBcAppUpgrade {
    param([string] $Name, [string] $Instance, $Plan)

    Assert-Command "Copy-FileToBcContainer"
    if (@($Plan.Packages | Where-Object { $_.Publisher -ne "Microsoft" }).Count) {
        throw "Saved upgrade plan includes non-Microsoft apps. A new prepared upgrade is required for the Microsoft-only policy; no target apps were published."
    }
    $ContainerPackages = @(
        foreach ($Package in $Plan.Packages) {
            if (-not (Test-Path -LiteralPath $Package.File -PathType Leaf) -or
                (Get-FileHash -LiteralPath $Package.File -Algorithm SHA256).Hash -cne $Package.Hash) {
                throw "Upgrade package is missing or changed: $($Package.File)"
            }
            $ContainerFile = "C:\Run\$($Package.Id).app"
            Copy-FileToBcContainer -containerName $Name -localPath $Package.File -containerPath $ContainerFile | Out-Host
            [pscustomobject]@{
                Id = $Package.Id; Name = $Package.Name; Publisher = $Package.Publisher
                Version = $Package.Version; SourceVersion = $Package.SourceVersion; File = $ContainerFile
            }
        }
    )
    Invoke-ScriptInBcContainer -containerName $Name -useSession:$false -scriptblock {
        param($Instance, $Packages)
        $ErrorActionPreference = "Stop"
        Import-NAVServerLicense -ServerInstance $Instance -LicenseFile "C:\Run\my\license.bclicense" `
            -Database NavDatabase -Force -ErrorAction Stop
        Restart-NAVServerInstance -ServerInstance $Instance -ErrorAction Stop
        Sync-NAVTenant -ServerInstance $Instance -Tenant default -Mode Sync -Force -ErrorAction Stop
        foreach ($Package in $Packages) {
            $Published = @(Get-NAVAppInfo -ServerInstance $Instance -Id $Package.Id -ErrorAction Stop |
                Where-Object { [string]$_.Version -eq $Package.Version })
            if (-not $Published.Count) {
                Publish-NAVApp -ServerInstance $Instance -Path $Package.File -ErrorAction Stop
            }
        }
        foreach ($Package in $Packages) {
            $AppArguments = @{
                ServerInstance = $Instance; Tenant = "default"; AppId = $Package.Id
                Version = $Package.Version; ErrorAction = "Stop"
            }
            Sync-NAVApp @AppArguments -Mode Add
            $Installed = @(Get-NAVAppInfo -ServerInstance $Instance -Tenant default -ErrorAction Stop |
                Where-Object { [string]$_.AppId -eq $Package.Id -and [string]$_.Version -eq $Package.Version })
            if (-not $Installed.Count) {
                if ($Package.SourceVersion -and [version]$Package.Version -gt [version]$Package.SourceVersion) {
                    Start-NAVAppDataUpgrade @AppArguments -Force
                }
                else {
                    Install-NAVApp @AppArguments
                }
            }
            $Verified = @(Get-NAVAppInfo -ServerInstance $Instance -Tenant default -TenantSpecificProperties `
                -Id $Package.Id -ErrorAction Stop |
                Where-Object { [string]$_.Version -eq $Package.Version -and $_.IsInstalled })
            if ($Verified.Count -ne 1 -or
                ($Verified[0].PSObject.Properties["NeedsUpgrade"] -and $Verified[0].NeedsUpgrade)) {
                throw "App upgrade verification failed: $($Package.Name) $($Package.Version)."
            }
        }
    } -argumentList @($Instance, $ContainerPackages) | Out-Host
}

function Convert-RestoredBcDatabase {
    param(
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][string] $Instance,
        [Parameter(Mandatory = $true)] $Database
    )

    Invoke-ScriptInBcContainer -containerName $Name -useSession:$false -scriptblock {
        param($Instance, $DatabaseServer, $DatabaseInstance, $DatabaseName)
        $ErrorActionPreference = "Stop"
        $Service = Get-Service -Name ('MicrosoftDynamicsNavServer$' + $Instance) -ErrorAction Stop
        if ($Service.Status -ne "Stopped") {
            Stop-Service -InputObject $Service -ErrorAction Stop
            $Service.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Stopped,
                [TimeSpan]::FromSeconds(60))
        }
        if (-not [string]::IsNullOrWhiteSpace($DatabaseInstance)) {
            $DatabaseServer = "$DatabaseServer\$DatabaseInstance"
        }
        Write-Host "Technically converting '$DatabaseName' on '$DatabaseServer' using the installed target binaries."
        Invoke-NAVApplicationDatabaseConversion -DatabaseServer $DatabaseServer `
            -DatabaseName $DatabaseName -Force -ErrorAction Stop
    } -argumentList @($Instance, $Database.Server, $Database.Instance, $Database.Name) | Out-Host
}

function Wait-ForBcService {
    param(
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][string] $Instance,
        [Parameter(Mandatory = $true)][int] $TimeoutSeconds
    )

    Invoke-ScriptInBcContainer `
        -containerName $Name `
        -argumentList @($Instance, $TimeoutSeconds) `
        -scriptblock {
            param($Instance, $Timeout)

            $ErrorActionPreference = "Stop"
            $Service = Get-Service -Name ('MicrosoftDynamicsNavServer$' + $Instance) -ErrorAction Stop

            if ($null -eq $Service) {
                throw "No Business Central service was found."
            }

            if ($Service.Status -ne "Running") {
                Start-Service -Name $Service.Name -ErrorAction Stop
            }

            $Deadline = (Get-Date).AddSeconds($Timeout)
            do {
                Start-Sleep -Seconds 2
                $Service = Get-Service -Name $Service.Name -ErrorAction Stop

                if ($Service.Status -eq "Running") {
                    Write-Output "Business Central service is running."
                    return
                }
            } while ((Get-Date) -lt $Deadline)

            throw "Business Central service did not reach Running within $Timeout seconds. Current state: $($Service.Status)"
        } | Out-Host
}

function Wait-ForBcAdminEndpoint {
    param(
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][string] $Instance,
        [Parameter(Mandatory = $true)][int] $TimeoutSeconds
    )

    Invoke-ScriptInBcContainer `
        -containerName $Name `
        -argumentList @($Instance, $TimeoutSeconds) `
        -scriptblock {
            param($ServerInstance, $Timeout)

            $ErrorActionPreference = "Stop"
            $AdminTool = Get-ChildItem `
                    -Path "C:\Program Files\Microsoft Dynamics NAV" `
                    -Filter "NavAdminTool.ps1" `
                    -File `
                    -Recurse `
                    -ErrorAction Stop |
                    Sort-Object FullName -Descending |
                    Select-Object -First 1 `
                    -ExpandProperty FullName

            Import-Module $AdminTool -DisableNameChecking -ErrorAction Stop | Out-Null

            $Deadline = (Get-Date).AddSeconds($Timeout)
            $LastMessage = $null

            do {
                try {
                    $null = Get-NAVServerUser `
                        -ServerInstance $ServerInstance `
                        -ErrorAction Stop

                    Write-Output "Business Central administration endpoint is ready."
                    return
                }
                catch {
                    $LastMessage = $_.Exception.Message
                    Start-Sleep -Seconds 3
                }
            } while ((Get-Date) -lt $Deadline)

            throw "Administration endpoint was not ready within $Timeout seconds. Last error: $LastMessage"
        } | Out-Host
}

function Set-And-VerifyBcUser {
    param(
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][string] $Instance,
        [Parameter(Mandatory = $true)][string] $TargetUserName,
        [Parameter(Mandatory = $true)][string] $PlainPassword,
        [Parameter(Mandatory = $true)][string] $PermissionSet
    )

    Invoke-ScriptInBcContainer `
        -containerName $Name `
        -argumentList @(
            $Instance,
            $TargetUserName,
            $PlainPassword,
            $PermissionSet
        ) `
        -scriptblock {
            param(
                $ServerInstance,
                $UserName,
                $PasswordText,
                $PermissionSetId
            )

            $ErrorActionPreference = "Stop"
            Set-StrictMode -Version 2.0

            $AdminTool = Get-ChildItem `
                -Path "C:\Program Files\Microsoft Dynamics NAV" `
                -Filter "NavAdminTool.ps1" `
                -File `
                -Recurse `
                -ErrorAction Stop |
                Sort-Object FullName -Descending |
                Select-Object -First 1 `
                -ExpandProperty FullName

            Import-Module $AdminTool -DisableNameChecking -ErrorAction Stop | Out-Null
            $SecurePassword = ConvertTo-SecureString `
                -String $PasswordText `
                -AsPlainText `
                -Force

            $ExistingUser = Get-NAVServerUser `
                -ServerInstance $ServerInstance `
                -ErrorAction Stop |
                Where-Object { $_.UserName -ieq $UserName } |
                Select-Object -First 1

            if ($null -eq $ExistingUser) {
                New-NAVServerUser `
                    -ServerInstance $ServerInstance `
                    -UserName $UserName `
                    -Password $SecurePassword `
                    -State Enabled `
                    -LicenseType FullUser `
                    -ErrorAction Stop
            }
            else {
                Set-NAVServerUser `
                    -ServerInstance $ServerInstance `
                    -UserName $UserName `
                    -Password $SecurePassword `
                    -State Enabled `
                    -ChangePasswordAtNextLogOn:$false `
                    -Force `
                    -ErrorAction Stop
            }

            $ExistingPermission = Get-NAVServerUserPermissionSet `
                -ServerInstance $ServerInstance `
                -UserName $UserName `
                -ErrorAction Stop |
                Where-Object { $_.PermissionSetId -ieq $PermissionSetId } |
                Select-Object -First 1

            if ($null -eq $ExistingPermission) {
                New-NAVServerUserPermissionSet `
                    -ServerInstance $ServerInstance `
                    -UserName $UserName `
                    -PermissionSetId $PermissionSetId `
                    -ErrorAction Stop
            }

            $VerifiedUser = Get-NAVServerUser `
                -ServerInstance $ServerInstance `
                -ErrorAction Stop |
                Where-Object { $_.UserName -ieq $UserName } |
                Select-Object -First 1

            $VerifiedPermission = Get-NAVServerUserPermissionSet `
                -ServerInstance $ServerInstance `
                -UserName $UserName `
                -ErrorAction Stop |
                Where-Object { $_.PermissionSetId -ieq $PermissionSetId } |
                Select-Object -First 1

            if ($null -eq $VerifiedUser) {
                throw "User verification failed for '$UserName'."
            }

            if ([string]$VerifiedUser.State -ne "Enabled") {
                throw "User '$UserName' is not enabled."
            }

            if ($null -eq $VerifiedPermission) {
                throw "Permission verification failed for '$PermissionSetId'."
            }

            Write-Output "Verified user '$UserName': Enabled."
            Write-Output "Verified permission set '$PermissionSetId'."
        } | Out-Host
}

function Show-StartupDiagnostics {
    param([Parameter(Mandatory = $true)][string] $Name)

    try {
        Get-BcContainerEventLog `
            -containerName $Name `
            -doNotOpen `
            -ErrorAction SilentlyContinue | Out-Host
    }
    catch {
        Write-Warning "Could not retrieve the BC container event log: $($_.Exception.Message)"
    }

    try {
        Invoke-ScriptInBcContainer -containerName $Name -useSession:$false -usePwsh:$false -scriptblock {
            $ErrorActionPreference = "Stop"
            Get-WinEvent -FilterHashtable @{
                LogName = "Application"
                ProviderName = 'MicrosoftDynamicsNavServer*'
                Level = 1, 2
                StartTime = (Get-Date).AddHours(-1)
            } -MaxEvents 3 -ErrorAction Stop |
                ForEach-Object {
                    Write-Host "$($_.TimeCreated) $($_.ProviderName) event $($_.Id)"
                    Write-Host $_.Message.Substring(0, [Math]::Min(3000, $_.Message.Length))
                }
        } | Out-Host
    }
    catch {
        Write-Warning "Could not read service-tier startup errors: $($_.Exception.Message)"
    }

    docker logs $Name --tail 300 2>&1 | Out-Host
}

if ([string]::IsNullOrWhiteSpace($Hostname)) {
    $Hostname = $ContainerName
}

if ($UseHyperV.IsPresent) {
    $Isolation = "hyperv"
}

Write-Step "Pre-flight checks"
Assert-Command "docker"

if ($PSVersionTable.PSEdition -ne "Desktop") {
    throw "Run this script in Windows PowerShell 5.1."
}

if (-not [string]::IsNullOrWhiteSpace($ArtifactVersion) -and
    $ArtifactVersion -notmatch '^\d+\.\d+(\.\d+\.\d+)?$') {
    throw "ArtifactVersion must be Major.Minor (for example 29.0) or a full four-part version. Supplied value: '$ArtifactVersion'"
}

docker info 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Docker is not running or accessible."
}

$ContainerExists = Test-ContainerExists -Name $ContainerName

$ResumeAfterRestore = $false
if ($SelectBackup.IsPresent -or
    (-not $ContainerExists -and [string]::IsNullOrWhiteSpace($RestoreFromBakFile))) {

    $RestoreFromBakFile = Select-BackupFile `
        -Root $BackupRoot `
        -PreferredContainerName $ContainerName
}

$RestoreOnlyMode = -not [string]::IsNullOrWhiteSpace($RestoreFromBakFile)

if (-not $RestoreOnlyMode -and -not $ContainerExists) {
    throw "Container '$ContainerName' is missing and no backup was selected."
}

if ($RestoreOnlyMode -and -not $ResumeAfterRestore) {
    if (-not (Test-Path -LiteralPath $RestoreFromBakFile -PathType Leaf)) {
        throw "Restore backup was not found: $RestoreFromBakFile"
    }

    $RestoreFromBakFile = (Resolve-Path -LiteralPath $RestoreFromBakFile).Path
    $RestoreInformation = Get-Item -LiteralPath $RestoreFromBakFile

    if ($RestoreInformation.Extension -ine ".bak" -or
        $RestoreInformation.Length -le 0) {
        throw "Restore source must be a non-empty .bak file."
    }
}

Write-Step "Loading BCContainerHelper"

$InstalledModule = Get-Module -ListAvailable -Name BcContainerHelper |
    Sort-Object Version -Descending |
    Select-Object -First 1

if (-not $InstalledModule) {
    Install-Module BcContainerHelper -Scope CurrentUser -AllowClobber
}
elseif ($UpdateBcContainerHelper) {
    Update-Module BcContainerHelper
}

Import-Module BcContainerHelper -Force

@(
    "Get-BcArtifactUrl",
    "Download-Artifacts",
    "New-BcContainer",
    "Restore-DatabasesInBcContainer",
    "Remove-BcContainer",
    "Restart-BcContainer",
    "Set-BcContainerServerConfiguration",
    "Invoke-ScriptInBcContainer",
    "Backup-BcContainerDatabases"
) | ForEach-Object { Assert-Command $_ }

if (-not $RestoreOnlyMode -and -not $ResumeAfterRestore) {
    Assert-Command "Backup-BcContainerDatabases"
}

$RestoreStatePath = Join-Path $BackupRoot "$ContainerName\restore-state.json"
$UpgradePlan = $null
$UpgradePlanPath = ""
$UpgradePlanHash = ""
$BackupHash = ""
if ($RestoreOnlyMode) {
    $BackupHash = (Get-FileHash -LiteralPath $RestoreFromBakFile -Algorithm SHA256).Hash
}
if ($RestoreOnlyMode -and $ContainerExists -and (Test-Path -LiteralPath $RestoreStatePath -PathType Leaf)) {
    Assert-Command "Get-BcContainerArtifactUrl"
    $ExistingArtifactUrl = Get-BcContainerArtifactUrl -containerName $ContainerName
    $ResolvedArtifactVersion = Assert-ArtifactVersion -Url ([string]$ExistingArtifactUrl)
    $DatabaseTarget = Get-BcDatabaseTarget -Name $ContainerName -Instance $ServerInstance
    $CurrentRestoreState = @{
        Schema = "1"
        BackupHash = $BackupHash
        ContainerId = Get-ContainerIdentity -Name $ContainerName
        Version = $ResolvedArtifactVersion
        ServerInstance = $ServerInstance
        DatabaseServer = $DatabaseTarget.Server
        DatabaseInstance = $DatabaseTarget.Instance
        DatabaseName = $DatabaseTarget.Name
        DatabaseIdentity = Get-RestoreDatabaseIdentity -Name $ContainerName -Database $DatabaseTarget
    }
    $SavedRestoreState = Get-Content -LiteralPath $RestoreStatePath -Raw | ConvertFrom-Json
    $ResumeAfterRestore = Test-RestoreStateMatch -State $SavedRestoreState -Current $CurrentRestoreState
    if ($ResumeAfterRestore -and $ArtifactVersion) {
        $null = Assert-ArtifactVersion -Url "/$ResolvedArtifactVersion/" -RequiredVersion $ArtifactVersion
    }
    if ($ResumeAfterRestore -and $SavedRestoreState.PSObject.Properties["UpgradePlanPath"] -and
        $SavedRestoreState.UpgradePlanPath) {
        $UpgradePlanPath = [string]$SavedRestoreState.UpgradePlanPath
        if (-not (Test-Path -LiteralPath $UpgradePlanPath -PathType Leaf) -or
            -not $SavedRestoreState.PSObject.Properties["UpgradePlanHash"] -or
            (Get-FileHash -LiteralPath $UpgradePlanPath -Algorithm SHA256).Hash -cne $SavedRestoreState.UpgradePlanHash) {
            throw "Saved upgrade plan is missing or changed; refusing to resume a partially upgraded database."
        }
        $UpgradePlanHash = [string]$SavedRestoreState.UpgradePlanHash
        $UpgradePlan = Get-Content -LiteralPath $UpgradePlanPath -Raw | ConvertFrom-Json
        if (-not $UpgradePlan.PSObject.Properties["Policy"] -or $UpgradePlan.Policy -ne "MicrosoftOnly") {
            throw "Saved prepared upgrade uses the previous app policy. Preserve its backups and rerun with a fresh container restore before using the Microsoft-only workflow."
        }
        if ($UpgradePlan.TargetVersion -ne $ResolvedArtifactVersion) {
            throw "Saved upgrade plan targets a different container version."
        }
    }
    if (-not $ResumeAfterRestore) {
        Write-Warning "Saved restore state does not match the selected backup/container/database. A fresh restore is required."
    }
}
if ($ResumeAfterRestore) {
    Write-Host "Verified completed restore; resuming existing container version: $ResolvedArtifactVersion" -ForegroundColor Yellow
}
else {
    $LicenseCandidate = Join-Path $PSScriptRoot "latest.bclicense"
    if (-not (Test-Path -LiteralPath $LicenseCandidate -PathType Leaf)) {
        throw "License file was not found: $LicenseCandidate"
    }
    $LicenseFile = (Resolve-Path -LiteralPath $LicenseCandidate).Path
    Write-Step "Resolving target Business Central artifact"

    if ([string]::IsNullOrWhiteSpace($ArtifactVersion)) {
        Write-Host "ArtifactVersion not supplied; selecting the latest artifact for '$Country'." -ForegroundColor Yellow
        $ArtifactUrl = Get-BcArtifactUrl `
            -type $ArtifactType `
            -country $Country `
            -select Latest
    }
    elseif ($ArtifactVersion -match '^\d+\.\d+$') {
        $ArtifactUrl = Get-BcArtifactUrl `
            -type $ArtifactType `
            -country $Country `
            -version $ArtifactVersion `
            -select Latest
    }
    else {
        $ArtifactUrl = Get-BcArtifactUrl `
            -type $ArtifactType `
            -country $Country `
            -version $ArtifactVersion `
            -select Closest
    }

    if (-not $ArtifactUrl) {
        $RequestedTarget = if ([string]::IsNullOrWhiteSpace($ArtifactVersion)) { "latest" } else { $ArtifactVersion }
        throw "No '$ArtifactType' artifact was resolved for target '$RequestedTarget' and country '$Country'."
    }

    $ResolvedArtifactVersion = Assert-ArtifactVersion `
        -Url ([string]$ArtifactUrl) `
        -RequiredVersion $ArtifactVersion

    Write-Host "Target artifact: $ArtifactUrl" -ForegroundColor Green
    Write-Host "Target version: $ResolvedArtifactVersion" -ForegroundColor Green

    Write-Step "Preparing artifact (reusing the local cache where available)"

    $ArtifactCachePath = @(Download-Artifacts `
        -artifactUrl $ArtifactUrl `
        -includePlatform)

    if ($ArtifactCachePath.Count -lt 2 -or
        @($ArtifactCachePath | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Container) }).Count) {
        throw "Artifact preparation failed for '$ArtifactUrl'."
    }

    Write-Host "Artifact cache: $ArtifactCachePath" -ForegroundColor Green
}

Write-Step "Container and restored-user credentials"

$Credential = Get-Credential `
    -Message "Credentials for the recreated container and restored BC user"

$CredentialUserName = $Credential.UserName
$PasswordPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR(
    $Credential.Password
)

try {
    $PlainPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR(
        $PasswordPointer
    )
}
finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($PasswordPointer)
}

if ([string]::IsNullOrWhiteSpace($CredentialUserName) -or
    [string]::IsNullOrWhiteSpace($PlainPassword)) {
    throw "A non-empty username and password are required."
}

$Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$SafeBackupFolder = Join-Path `
    $BackupRoot `
    "$ContainerName\$Timestamp"
$BackupTempFolder = Join-Path `
    $env:ProgramData `
    "BcContainerHelper\Extensions\$ContainerName\backup-$Timestamp"
$RestoreTempFolder = Join-Path `
    $env:ProgramData `
    "BcContainerHelper\Extensions\$ContainerName\restore-$Timestamp"

try {
    if (-not $ResumeAfterRestore) {
        if (Test-Path -LiteralPath $RestoreStatePath -PathType Leaf) {
            Remove-Item -LiteralPath $RestoreStatePath -Force
        }
        if (-not $RestoreOnlyMode) {
            Write-Step "Creating protected database backup"

            New-ProtectedDirectory -Path $SafeBackupFolder
            New-ProtectedDirectory -Path $BackupTempFolder

            Backup-BcContainerDatabases `
                -containerName $ContainerName `
                -bakFolder $BackupTempFolder

            Assert-BakFilesExist `
                -Folder $BackupTempFolder `
                -Message "Backup creation produced no non-empty .bak files." | Out-Null

            Copy-BakFilesNoOverwrite `
                -SourceFolder $BackupTempFolder `
                -DestinationFolder $SafeBackupFolder

            Assert-BakFilesExist `
                -Folder $SafeBackupFolder `
                -Message "Protected backup copy failed." | Out-Null

            Write-Host "Protected backup: $SafeBackupFolder" -ForegroundColor Green
        }

        if ($ContainerExists) {
            Write-Step "Removing existing container"

            Write-Host "Target artifact version: $ResolvedArtifactVersion" -ForegroundColor Yellow
            if ($RestoreOnlyMode) {
                Write-Host "Restore source: $RestoreFromBakFile" -ForegroundColor Yellow
            }

            $Confirmation = Read-Host "Type RECREATE to remove '$ContainerName'"
            if ($Confirmation -cne "RECREATE") {
                throw "Container recreation was aborted."
            }

            Remove-BcContainer -containerName $ContainerName
        }

        Write-Step "Creating target-version Business Central container"

        New-BcContainer `
            -accept_eula `
            -containerName $ContainerName `
            -hostname $Hostname `
            -artifactUrl $ArtifactUrl `
            -credential $Credential `
            -auth UserPassword `
            -updateHosts `
            -useBestContainerOS `
            -alwaysPull `
            -memoryLimit $MemoryLimit `
            -isolation $Isolation `
            -dns $Dns `
            -licenseFile $LicenseFile `
            -myScripts @((Get-ContainerSetupScripts))

        Write-Step "Preparing protected restore copy"

        New-ProtectedDirectory -Path $RestoreTempFolder

        if ($RestoreOnlyMode) {
            Copy-FileNoOverwrite `
                -SourceFile $RestoreFromBakFile `
                -DestinationFolder $RestoreTempFolder `
                -DestinationName "database.bak"
        }
        else {
            Copy-BakFilesNoOverwrite `
                -SourceFolder $SafeBackupFolder `
                -DestinationFolder $RestoreTempFolder
        }

        Assert-BakFilesExist `
            -Folder $RestoreTempFolder `
            -Message "No restore backup is available in '$RestoreTempFolder'." | Out-Null

        $RestoreCopyHash = (Get-FileHash -LiteralPath (Join-Path $RestoreTempFolder "database.bak") -Algorithm SHA256).Hash
        if ($RestoreOnlyMode -and $RestoreCopyHash -cne $BackupHash) {
            throw "Restore copy hash does not match the selected source backup."
        }
        Write-Step "Restoring database into target-version container"

        $DatabaseTarget = Get-BcDatabaseTarget -Name $ContainerName -Instance $ServerInstance
        Restore-BcDatabaseWithoutStart -Name $ContainerName -Instance $ServerInstance `
            -BakFile (Join-Path $RestoreTempFolder "database.bak") -Database $DatabaseTarget -Timeout $SqlTimeout

        $RestoreState = @{
            Schema = "1"
            BackupHash = $RestoreCopyHash
            ContainerId = Get-ContainerIdentity -Name $ContainerName
            Version = $ResolvedArtifactVersion
            ServerInstance = $ServerInstance
            DatabaseServer = $DatabaseTarget.Server
            DatabaseInstance = $DatabaseTarget.Instance
            DatabaseName = $DatabaseTarget.Name
            DatabaseIdentity = Get-RestoreDatabaseIdentity -Name $ContainerName -Database $DatabaseTarget
        }
        Save-BcRestoreState -State $RestoreState -Path $RestoreStatePath
    }
    else {
        Write-Step "Resuming the existing restored database (no recreation or restore)"
        $DatabaseTarget = Get-BcDatabaseTarget -Name $ContainerName -Instance $ServerInstance
        $RestoreState = @{}
        foreach ($Property in $SavedRestoreState.PSObject.Properties) {
            $RestoreState[$Property.Name] = $Property.Value
        }
    }

    if ($null -eq $UpgradePlan) {
        $RestoredApps = @(Get-RestoredBcApps -Name $ContainerName -Database $DatabaseTarget)
        $BaseApps = @($RestoredApps | Where-Object { $_.Name -eq "Base Application" -and $_.Publisher -eq "Microsoft" })
        if ($BaseApps.Count -ne 1) {
            throw "Cannot identify one installed Microsoft Base Application in the restored database. A prepared database requires its verified saved upgrade plan."
        }
        if ([version]$BaseApps[0].Version -ne [version]$ResolvedArtifactVersion) {
            if ($ResumeAfterRestore) {
                $PlanArtifactUrl = Get-BcArtifactUrl -type $ArtifactType -country $Country `
                    -version $ResolvedArtifactVersion -select Closest
                $null = Assert-ArtifactVersion -Url ([string]$PlanArtifactUrl) -RequiredVersion $ResolvedArtifactVersion
                $ArtifactCachePath = @(Download-Artifacts -artifactUrl $PlanArtifactUrl -includePlatform)
            }
            $OriginalBackup = if ($RestoreOnlyMode) { $RestoreFromBakFile } else { Join-Path $SafeBackupFolder "database.bak" }
            if ((Get-FileHash -LiteralPath $OriginalBackup -Algorithm SHA256).Hash -cne $RestoreState.BackupHash) {
                throw "Source backup changed since the verified restore; refusing source-runtime preparation."
            }
            $UpgradePlanPath = New-PreparedBcUpgrade -InstalledApps $RestoredApps `
                -SourceVersion $BaseApps[0].Version -TargetVersion $ResolvedArtifactVersion `
                -ArtifactPaths $ArtifactCachePath -BackupFile $OriginalBackup `
                -ExpectedBackupHash $RestoreState.BackupHash -Credential $Credential
            $UpgradePlanHash = (Get-FileHash -LiteralPath $UpgradePlanPath -Algorithm SHA256).Hash
            $UpgradePlan = Get-Content -LiteralPath $UpgradePlanPath -Raw | ConvertFrom-Json
            if ((Get-FileHash -LiteralPath $UpgradePlan.BackupFile -Algorithm SHA256).Hash -cne $UpgradePlan.BackupHash) {
                throw "Prepared backup verification failed."
            }
            $PreparedRestoreFolder = Join-Path $env:ProgramData "BcContainerHelper\Extensions\$ContainerName\prepared-$([guid]::NewGuid().ToString('N'))"
            New-ProtectedDirectory -Path $PreparedRestoreFolder
            Copy-FileNoOverwrite -SourceFile $UpgradePlan.BackupFile -DestinationFolder $PreparedRestoreFolder -DestinationName "database.bak"
            if ((Get-FileHash -LiteralPath (Join-Path $PreparedRestoreFolder "database.bak") -Algorithm SHA256).Hash -cne $UpgradePlan.BackupHash) {
                throw "Prepared target restore copy failed hash verification."
            }
            Restore-BcDatabaseWithoutStart -Name $ContainerName -Instance $ServerInstance `
                -BakFile (Join-Path $PreparedRestoreFolder "database.bak") -Database $DatabaseTarget -Timeout $SqlTimeout
            $RestoreState.DatabaseIdentity = Get-RestoreDatabaseIdentity -Name $ContainerName -Database $DatabaseTarget
            $RestoreState.UpgradePlanPath = $UpgradePlanPath
            $RestoreState.UpgradePlanHash = $UpgradePlanHash
            Save-BcRestoreState -State $RestoreState -Path $RestoreStatePath
        }
    }
    if ($null -ne $UpgradePlan) {
        Set-BcContainerServerConfiguration -containerName $ContainerName -keyName EnableTaskScheduler -keyValue false
    }

    Write-Step "Technically converting restored database before starting Business Central"
    Convert-RestoredBcDatabase -Name $ContainerName -Instance $ServerInstance -Database $DatabaseTarget

    Write-Step "Verifying target-version Business Central service"

    try {
        Wait-ForBcService `
            -Name $ContainerName `
            -Instance $ServerInstance `
            -TimeoutSeconds $ServiceStartTimeoutSeconds
    }
    catch {
        Show-StartupDiagnostics -Name $ContainerName
        throw "The restored database could not start on target artifact version '$ResolvedArtifactVersion'. The database may require application synchronization/data upgrade steps or compatible Microsoft and partner apps. Original error: $($_.Exception.Message)"
    }

    Write-Step "Waiting for Business Central administration endpoint"

    Wait-ForBcAdminEndpoint `
        -Name $ContainerName `
        -Instance $ServerInstance `
        -TimeoutSeconds $ServiceStartTimeoutSeconds

    if ($null -ne $UpgradePlan) {
        Write-Step "Publishing, synchronizing, and upgrading target apps in dependency order"
        Invoke-TargetBcAppUpgrade -Name $ContainerName -Instance $ServerInstance -Plan $UpgradePlan
        Set-BcContainerServerConfiguration -containerName $ContainerName -keyName EnableTaskScheduler `
            -keyValue ([string]$UpgradePlan.TaskSchedulerEnabled)
    }

    Write-Step "Reapplying and verifying restored sign-in user"

    Set-And-VerifyBcUser `
        -Name $ContainerName `
        -Instance $ServerInstance `
        -TargetUserName $CredentialUserName `
        -PlainPassword $PlainPassword `
        -PermissionSet $PermissionSetId

    Write-Step "Applying server configuration"

    Set-BcContainerServerConfiguration `
        -keyName NavHttpClientAntiSSRFEnabled `
        -keyValue false `
        -containerName $ContainerName

    Write-Step "Final restart and verification"

    Restart-BcContainer -containerName $ContainerName

    Wait-ForBcService `
        -Name $ContainerName `
        -Instance $ServerInstance `
        -TimeoutSeconds $ServiceStartTimeoutSeconds

    Wait-ForBcAdminEndpoint `
        -Name $ContainerName `
        -Instance $ServerInstance `
        -TimeoutSeconds $ServiceStartTimeoutSeconds

    if (Test-Path -LiteralPath $RestoreStatePath -PathType Leaf) {
        Remove-Item -LiteralPath $RestoreStatePath -Force
    }

    Write-Host ""
    Write-Host "DONE" -ForegroundColor Green
    Write-Host "Container version: $ResolvedArtifactVersion" -ForegroundColor Green
    Write-Host "Open: http://$Hostname/BC" -ForegroundColor Green
    Write-Host "User: $CredentialUserName" -ForegroundColor Green

    if ($ResumeAfterRestore) {
        Write-Host "Existing database conversion and service verification completed." -ForegroundColor Green
    }
    elseif ($RestoreOnlyMode) {
        Write-Host "Source backup retained: $RestoreFromBakFile" -ForegroundColor Yellow
    }
    else {
        Write-Host "Protected backup retained: $SafeBackupFolder" -ForegroundColor Yellow
    }

    if (-not $ResumeAfterRestore -and -not $KeepTemporaryFolders.IsPresent) {
        Write-Step "Optional temporary-folder cleanup"
        Write-Host "Protected backups are never deleted automatically." -ForegroundColor Yellow
        $CleanupAnswer = Read-Host "Type DELETE-TEMP to remove temporary helper folders"

        if ($CleanupAnswer -ceq "DELETE-TEMP") {
            foreach ($Folder in @($BackupTempFolder, $RestoreTempFolder)) {
                if (Test-Path -LiteralPath $Folder) {
                    Remove-Item -LiteralPath $Folder -Recurse -Force
                    Write-Host "Deleted temporary folder: $Folder"
                }
            }
        }
    }
}
catch {
    Write-Warning "Retry with the same source backup. A verified saved restore state will resume automatically without recreating the container."
    if ($RestoreOnlyMode) {
        Write-Warning "Source backup retained: $RestoreFromBakFile. Retry with -RestoreFromBakFile and -ArtifactVersion Major.Minor."
    }
    elseif (Test-Path -LiteralPath $SafeBackupFolder -PathType Container) {
        Write-Warning "Protected backup folder retained: $SafeBackupFolder. After verifying the backup, retry with -SelectBackup and -ArtifactVersion Major.Minor; do not back up the partially installed container."
    }

    if (Test-ContainerExists -Name $ContainerName) {
        Show-StartupDiagnostics -Name $ContainerName
    }

    throw
}
finally {
    $PlainPassword = $null
    $Credential = $null
}
