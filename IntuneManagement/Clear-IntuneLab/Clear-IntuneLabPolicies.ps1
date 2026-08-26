#Requires -Modules Microsoft.Graph.Authentication
<#
.SYNOPSIS
    Bulk-deletes Intune configuration-related policies from a tenant. Built for wiping a messy LAB tenant.

.DESCRIPTION
    Enumerates and deletes policies of the selected types via Microsoft Graph (beta - see note below):
      - SettingsCatalog        deviceManagement/configurationPolicies
      - DeviceConfiguration    deviceManagement/deviceConfigurations       [legacy templates, admin templates, custom OMA-URI, Android/iOS device-owner profiles, ...]
      - GroupPolicyConfiguration  deviceManagement/groupPolicyConfigurations  [Administrative Templates / ADMX-backed profiles]
      - CompliancePolicy       deviceManagement/deviceCompliancePolicies
      - EndpointSecurity       deviceManagement/intents                   [Security Baselines + other Endpoint Security policies]
      - InventoryPolicy        deviceManagement/inventoryPolicies          [Custom Device Inventory policies]
      - DeviceHealthScript     deviceManagement/deviceHealthScripts        [Proactive Remediations]
      - DeviceManagementScript deviceManagement/deviceManagementScripts    [Platform scripts / PowerShell scripts]

    All endpoints are called against the `beta` Graph version on purpose: several deviceConfigurations
    subtypes (e.g. androidDeviceOwnerGeneralDeviceConfiguration) 404 on v1.0 for GET-by-id and are
    silently absent from the v1.0 list response, which means a v1.0-only script would leave them behind
    without ever reporting an error. beta is the superset, so it's used consistently for every type here.

    Always does a dry-run listing first. Nothing is deleted until you either:
      a) type the confirmation phrase DELETE at the prompt, or
      b) pass -Force
    -WhatIf / -Confirm are also fully supported on top of that (standard PowerShell safety net).

.PARAMETER PolicyTypes
    Which policy types to include. Default: all eight.

.PARAMETER NameFilter
    Optional wildcard (e.g. "Test-*") - only policies whose displayName matches are targeted.

.PARAMETER Force
    Skip the typed "DELETE" confirmation prompt. -WhatIf/-Confirm still apply.

.PARAMETER ExportReportPath
    Optional CSV path to write a before/after report of what was found and what was deleted.

.EXAMPLE
    ./Clear-IntuneLabPolicies.ps1
    Dry-run listing of everything, then prompts before deleting.

.EXAMPLE
    ./Clear-IntuneLabPolicies.ps1 -PolicyTypes SettingsCatalog,DeviceConfiguration -NameFilter "Test-*"
    Only targets Settings Catalog + legacy device configuration policies whose name starts with "Test-".

.EXAMPLE
    ./Clear-IntuneLabPolicies.ps1 -WhatIf
    Shows exactly what would be deleted without deleting or even prompting.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [ValidateSet('SettingsCatalog', 'DeviceConfiguration', 'GroupPolicyConfiguration', 'CompliancePolicy', 'EndpointSecurity', 'InventoryPolicy', 'DeviceHealthScript', 'DeviceManagementScript')]
    [string[]]$PolicyTypes = @('SettingsCatalog', 'DeviceConfiguration', 'GroupPolicyConfiguration', 'CompliancePolicy', 'EndpointSecurity', 'InventoryPolicy', 'DeviceHealthScript', 'DeviceManagementScript'),

    [string]$NameFilter,

    [switch]$Force,

    [string]$ExportReportPath
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Connect
# ---------------------------------------------------------------------------
$requiredScopes = @('DeviceManagementConfiguration.ReadWrite.All', 'DeviceManagementServiceConfig.ReadWrite.All','DeviceManagementScripts.ReadWrite.All')

$context = Get-MgContext
if (-not $context) {
    Write-Host "Connecting to Microsoft Graph..." -ForegroundColor Cyan
    Connect-MgGraph -Scopes $requiredScopes -NoWelcome
    $context = Get-MgContext
}
else {
    $missing = $requiredScopes | Where-Object { $_ -notin $context.Scopes }
    if ($missing) {
        Write-Host "Re-connecting to add missing scopes: $($missing -join ', ')" -ForegroundColor Cyan
        Connect-MgGraph -Scopes $requiredScopes -NoWelcome
        $context = Get-MgContext
    }
}

Write-Host "Connected to tenant: $($context.TenantId) as $($context.Account)" -ForegroundColor Green
Write-Host ""
Write-Host "*** DOUBLE-CHECK this is your LAB tenant before continuing. ***" -ForegroundColor Yellow
Write-Host ""

# ---------------------------------------------------------------------------
# Policy type -> Graph endpoint map (all beta - see .DESCRIPTION)
# ---------------------------------------------------------------------------
$typeMap = @{
    SettingsCatalog           = @{ Endpoint = 'beta/deviceManagement/configurationPolicies'; NameProp = 'name' }
    DeviceConfiguration       = @{ Endpoint = 'beta/deviceManagement/deviceConfigurations'; NameProp = 'displayName' }
    GroupPolicyConfiguration  = @{ Endpoint = 'beta/deviceManagement/groupPolicyConfigurations'; NameProp = 'displayName' }
    CompliancePolicy          = @{ Endpoint = 'beta/deviceManagement/deviceCompliancePolicies'; NameProp = 'displayName' }
    EndpointSecurity          = @{ Endpoint = 'beta/deviceManagement/intents'; NameProp = 'displayName' }
    InventoryPolicy           = @{ Endpoint = 'beta/deviceManagement/inventoryPolicies'; NameProp = 'name' }
    DeviceHealthScript        = @{ Endpoint = 'beta/deviceManagement/deviceHealthScripts'; NameProp = 'displayName' }
    DeviceManagementScript    = @{ Endpoint = 'beta/deviceManagement/deviceManagementScripts'; NameProp = 'displayName' }
}

# ---------------------------------------------------------------------------
# Helper: page through a Graph collection
# ---------------------------------------------------------------------------
function Get-GraphCollection {
    param([string]$Uri)

    $results = [System.Collections.Generic.List[object]]::new()
    $next = "https://graph.microsoft.com/$Uri"

    while ($next) {
        $response = Invoke-MgGraphRequest -Method GET -Uri $next
        if ($response.value) { $results.AddRange($response.value) }
        $next = $response.'@odata.nextLink'
    }

    return $results
}

# ---------------------------------------------------------------------------
# Enumerate
# ---------------------------------------------------------------------------
$inventory = [System.Collections.Generic.List[object]]::new()

foreach ($type in $PolicyTypes) {
    $map = $typeMap[$type]
    Write-Host "Fetching $type ..." -ForegroundColor Cyan

    try {
        $items = Get-GraphCollection -Uri $map.Endpoint
    }
    catch {
        Write-Warning "Failed to fetch ${type}: $($_.Exception.Message)"
        continue
    }

    foreach ($item in $items) {
        $name = $item.($map.NameProp)
        if ($NameFilter -and $name -notlike $NameFilter) { continue }

        $inventory.Add([PSCustomObject]@{
            Type        = $type
            Id          = $item.id
            DisplayName = $name
            Endpoint    = "$($map.Endpoint)/$($item.id)"
            Status      = 'Pending'
        })
    }
}

if ($inventory.Count -eq 0) {
    Write-Host "Nothing found matching the selected scope. Nothing to do." -ForegroundColor Green
    return
}

# ---------------------------------------------------------------------------
# Dry-run report
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "=== Found $($inventory.Count) polic$(if ($inventory.Count -eq 1) {'y'} else {'ies'}) to delete ===" -ForegroundColor Yellow
$inventory | Group-Object Type | ForEach-Object {
    Write-Host ""
    Write-Host "-- $($_.Name) ($($_.Count)) --" -ForegroundColor Magenta
    $_.Group | ForEach-Object { Write-Host "  $($_.DisplayName)  [$($_.Id)]" }
}
Write-Host ""

if ($ExportReportPath) {
    $inventory | Export-Csv -Path $ExportReportPath -NoTypeInformation
    Write-Host "Inventory exported to $ExportReportPath" -ForegroundColor Green
}

if ($WhatIfPreference) {
    Write-Host "-WhatIf specified: no deletions performed." -ForegroundColor Yellow
    return
}

# ---------------------------------------------------------------------------
# Confirmation gate
# ---------------------------------------------------------------------------
if (-not $Force) {
    Write-Host "Type DELETE (all caps) to permanently delete the $($inventory.Count) polic$(if ($inventory.Count -eq 1) {'y'} else {'ies'}) listed above." -ForegroundColor Red
    $confirmation = Read-Host "Confirm"
    if ($confirmation -ne 'DELETE') {
        Write-Host "Confirmation not received. Aborting - nothing was deleted." -ForegroundColor Yellow
        return
    }
}

# ---------------------------------------------------------------------------
# Delete
# ---------------------------------------------------------------------------
$deleted = 0
$failed = 0

foreach ($policy in $inventory) {
    $target = "$($policy.Type): $($policy.DisplayName) [$($policy.Id)]"

    if ($PSCmdlet.ShouldProcess($target, 'Delete')) {
        try {
            Invoke-MgGraphRequest -Method DELETE -Uri "https://graph.microsoft.com/$($policy.Endpoint)"
            $policy.Status = 'Deleted'
            $deleted++
            Write-Host "Deleted: $target" -ForegroundColor Green
        }
        catch {
            $policy.Status = "Failed: $($_.Exception.Message)"
            $failed++
            Write-Warning "Failed to delete ${target}: $($_.Exception.Message)"
        }
    }
}

Write-Host ""
Write-Host "=== Done: $deleted deleted, $failed failed, $($inventory.Count - $deleted - $failed) skipped ===" -ForegroundColor Cyan

if ($ExportReportPath) {
    $inventory | Export-Csv -Path $ExportReportPath -NoTypeInformation -Force
    Write-Host "Final report written to $ExportReportPath" -ForegroundColor Green
}
