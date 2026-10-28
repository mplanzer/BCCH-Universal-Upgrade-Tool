#Requires -Version 5.1

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

$Tokens = $null
$ParseErrors = $null
$ScriptPath = Join-Path $PSScriptRoot "update.ps1"
$Ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $ScriptPath, [ref]$Tokens, [ref]$ParseErrors)
if ($ParseErrors.Count) {
    throw ($ParseErrors | Out-String)
}

foreach ($Name in @("Assert-Command", "Assert-ArtifactVersion", "Get-UpgradePackagePlan")) {
    $Definition = $Ast.Find({
        param($Node)
        $Node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $Node.Name -eq $Name
    }, $true)
    if ($null -eq $Definition) { throw "Required function not found: $Name" }
    . ([scriptblock]::Create($Definition.Extent.Text))
}

$script:Checks = 0
function Assert-Test {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
    $script:Checks++
}

function Assert-TestError {
    param([scriptblock] $Action, [string] $Pattern)
    $Caught = $false
    try { & $Action | Out-Null }
    catch {
        if ($_.Exception.Message -notlike $Pattern) { throw }
        $Caught = $true
    }
    Assert-Test $Caught "Expected error matching: $Pattern"
}

# All external artifact/package operations below are fixtures, not live operations.
function Write-Step { param($Message) }
function Get-AppJsonFromAppFile {
    param($appFile)
    Get-Content -LiteralPath $appFile -Raw | ConvertFrom-Json
}
function Sort-AppFilesByDependencies {
    param($appFiles, [switch] $excludeRuntimePackages, [ref] $unknownDependencies)
    $unknownDependencies.Value = @()
    $appFiles | Sort-Object
}
function Get-BcArtifactUrl {
    param($type, $country, $version, $select)
    Assert-Test ($type -in @("onprem", "sandbox")) "Unexpected artifact type"
    $script:Lookups++
    if (-not $script:Available) { return }
    if ($select -eq "Closest" -and -not $script:ExactAvailable) { return }
    if ($version -eq "28.1") {
        return "https://example.invalid/$type/28.1.1.0/ch"
    }
    "https://example.invalid/sandbox/29.0.1.0/ch"
}
function Download-Artifacts {
    param($artifactUrl, [switch] $includePlatform)
    Assert-Test $includePlatform.IsPresent "Platform packages must be included"
    if ($artifactUrl -like "*/onprem/28.1.*") { return $LegacyOnpremFolder }
    if ($artifactUrl -like "*/28.1.*") { return $LegacyFolder }
    $CloudFolder
}
function Write-TestPackage {
    param($Folder, $Id, $Name, $Publisher, $Version,
        $Application = "29.0.0.0", $Platform = "29.0.0.0")
    @{
        id = $Id; name = $Name; publisher = $Publisher; version = $Version
        dependencies = @(); application = $Application; platform = $Platform
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Folder "$Id.app")
}
function Get-TestPlan {
    @(Get-UpgradePackagePlan -InstalledApps $InstalledApps -ArtifactPaths @($OnpremFolder) `
        -PartnerFolder $ExtraFolder -TargetVersion "29.0.1.0" -PlatformVersion "29.0.5.0")
}

$Root = Join-Path ([IO.Path]::GetTempPath()) ("update-tests-" + [guid]::NewGuid().ToString("N"))
$OnpremFolder = Join-Path $Root "onprem\29.0.1.0\ch"
$CloudFolder = Join-Path $Root "sandbox"
$ExtraFolder = Join-Path $Root "extra"
$LegacyFolder = Join-Path $Root "legacy"
$LegacyOnpremFolder = Join-Path $Root "legacy-onprem"
foreach ($Folder in @($OnpremFolder, $CloudFolder, $ExtraFolder, $LegacyFolder, $LegacyOnpremFolder)) {
    [IO.Directory]::CreateDirectory($Folder) | Out-Null
}
$BaseId = "00000000-0000-0000-0000-000000000001"
$CloudId = "00000000-0000-0000-0000-000000000002"
$PartnerId = "00000000-0000-0000-0000-000000000003"
$InstalledApps = @(
    [pscustomobject]@{ Id = $BaseId; Name = "Base Application"; Publisher = "Microsoft"; Version = "28.1.0.0" },
    [pscustomobject]@{ Id = $CloudId; Name = "Cloud App"; Publisher = "Microsoft"; Version = "28.1.0.0" },
    [pscustomobject]@{ Id = $PartnerId; Name = "Partner"; Publisher = "Partner"; Version = "99.0.0.0" }
)
$Country = "ch"
$script:Lookups = 0
$script:Available = $true
$script:ExactAvailable = $true

try {
    Assert-Test ((Assert-ArtifactVersion "https://example.invalid/29.0.1.0/ch" "29.0") -eq "29.0.1.0") "Major.Minor resolution failed"
    Assert-TestError { Assert-ArtifactVersion "https://example.invalid/29.1.1.0/ch" "29.0" } "*does not match*"
    Assert-TestError { Assert-ArtifactVersion "https://example.invalid/no-version" "" } "*Cannot determine*"

    Write-TestPackage $OnpremFolder $BaseId "Base Application" "Microsoft" "29.0.1.0"
    Write-TestPackage $CloudFolder $BaseId "Base Application" "Microsoft" "29.0.9.0"
    Write-TestPackage $CloudFolder $CloudId "Cloud App" "Microsoft" "29.0.1.0"
    Write-TestPackage $ExtraFolder $PartnerId "Partner" "Partner" "100.0.0.0" "100.0.0.0" "100.0.0.0"
    $Plan = Get-TestPlan
    Assert-Test ($Plan.Count -eq 2) "Unexpected target package count"
    Assert-Test (@($Plan | Where-Object Publisher -ne "Microsoft").Count -eq 0) "Partner package included"
    Assert-Test (($Plan | Where-Object Id -eq $BaseId).Version -eq "29.0.1.0") "Sandbox replaced the on-premises core app"
    Assert-Test ($script:Lookups -eq 1) "Exact sandbox lookup not used"
    Assert-Test (($Plan | Where-Object Id -eq $CloudId).SourceVersion -eq "28.1.0.0") "Source version not preserved"

    $script:ExactAvailable = $false
    $script:Lookups = 0
    $Plan = Get-TestPlan
    Assert-Test ($script:Lookups -eq 2) "Release fallback not used"
    Write-TestPackage $CloudFolder $CloudId "Cloud App" "Microsoft" "29.0.1.0" "30.0.0.0"
    Assert-TestError { Get-TestPlan } "*requires application*"
    Write-TestPackage $CloudFolder $CloudId "Cloud App" "Microsoft" "29.0.1.0" "29.0.0.0" "29.0.6.0"
    Assert-TestError { Get-TestPlan } "*requires platform*"
    Remove-Item -LiteralPath (Join-Path $CloudFolder "$CloudId.app")
    $script:Lookups = 0
    Assert-TestError { Get-TestPlan } "*still missing after searching target and source*"
    Assert-Test ($script:Lookups -eq 4) "Unbounded artifact fallback"
    Write-TestPackage $LegacyOnpremFolder $CloudId "Cloud App" "Microsoft" "28.0.0.0" "28.0.0.0" "28.0.0.0"
    Write-TestPackage $LegacyFolder $CloudId "Cloud App" "Microsoft" "28.1.0.0" "28.1.0.0" "28.1.0.0"
    $Plan = Get-TestPlan
    $LegacyApp = $Plan | Where-Object Id -eq $CloudId
    Assert-Test ($LegacyApp.Version -eq "28.1.0.0") "Legacy app version was changed"
    Assert-Test ($LegacyApp.SourceVersion -eq "28.1.0.0") "Saved legacy data version was lost"
    Assert-Test (($Plan | Where-Object Id -eq $BaseId).Version -eq "29.0.1.0") "Legacy artifacts replaced target core"
    Write-TestPackage $LegacyOnpremFolder $CloudId "Cloud App" "Microsoft" "28.1.0.0" "28.1.0.0" "28.1.0.0"
    Write-TestPackage $LegacyFolder $CloudId "Cloud App" "Microsoft" "28.1.2.0" "28.1.0.0" "28.1.0.0"
    $Plan = Get-TestPlan
    Assert-Test (($Plan | Where-Object Id -eq $CloudId).Version -eq "28.1.2.0") "First fallback blocked a newer source package"
    Write-TestPackage $CloudFolder $CloudId "Cloud App" "Microsoft" "28.0.0.0" "28.0.0.0" "28.0.0.0"
    $Plan = Get-TestPlan
    Assert-Test (($Plan | Where-Object Id -eq $CloudId).Version -eq "28.1.2.0") "Older target fallback blocked source lookup"
    Write-TestPackage $CloudFolder $CloudId "Cloud App" "Microsoft" "29.0.1.0"
    $Plan = Get-TestPlan
    Assert-Test (($Plan | Where-Object Id -eq $CloudId).Version -eq "29.0.1.0") "Legacy package took precedence over target package"
    Remove-Item -LiteralPath (Join-Path $CloudFolder "$CloudId.app")
    Write-TestPackage $LegacyOnpremFolder $CloudId "Cloud App" "Microsoft" "28.0.0.0" "28.0.0.0" "28.0.0.0"
    Write-TestPackage $LegacyFolder $CloudId "Cloud App" "Microsoft" "28.0.0.0" "28.0.0.0" "28.0.0.0"
    Assert-TestError { Get-TestPlan } "*still missing after searching target and source*"
    $CachedFolder = Join-Path $Root "sandbox\28.1.0.0\platform"
    [IO.Directory]::CreateDirectory($CachedFolder) | Out-Null
    Write-TestPackage $CachedFolder $CloudId "Cloud App" "Microsoft" "28.1.0.0" "28.1.0.0" "28.1.0.0"
    $Plan = Get-TestPlan
    Assert-Test (($Plan | Where-Object Id -eq $CloudId).File -eq (Join-Path $CachedFolder "$CloudId.app")) "Exact cached source package not selected"
    $script:Available = $false
    $Plan = @(Get-UpgradePackagePlan -InstalledApps $InstalledApps -ArtifactPaths @($OnpremFolder) `
        -PartnerFolder $ExtraFolder -TargetVersion "29.0.1.0" -PlatformVersion "29.0.5.0" -CloudArtifactsIncluded)
    Assert-Test (($Plan | Where-Object Id -eq $CloudId).Version -eq "28.1.0.0") "Cache-only source resolution failed"
    Write-TestPackage $CachedFolder $CloudId "Wrong identity" "Microsoft" "28.1.0.0" "28.1.0.0" "28.1.0.0"
    Assert-TestError {
        Get-UpgradePackagePlan -InstalledApps $InstalledApps -ArtifactPaths @($OnpremFolder) `
            -PartnerFolder $ExtraFolder -TargetVersion "29.0.1.0" -CloudArtifactsIncluded
    } "*identity differs*"
    $script:Available = $false
    Assert-TestError { Get-TestPlan } "*No sandbox artifacts*"
    Write-TestPackage $OnpremFolder $CloudId "Cloud App" "Microsoft" "29.0.1.0"
    $script:Lookups = 0
    $Plan = Get-TestPlan
    Assert-Test ($script:Lookups -eq 0) "Unnecessary sandbox lookup"
    Assert-Test ($Ast.ParamBlock.Parameters.Name.VariablePath.UserPath -notcontains "ResumeAfterRestore") "Manual resume parameter returned"
    "PASS: $script:Checks checks under PowerShell $($PSVersionTable.PSVersion). No live upgrade operations executed."
}
finally {
    Remove-Item -LiteralPath $Root -Recurse -Force
}
