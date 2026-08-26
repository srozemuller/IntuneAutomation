<#
.SYNOPSIS
    Explains why an Intune-managed Windows device does or does not have a
    compliance policy assigned - an RSOP-style, evidence-based analysis,
    not a Graph data dump.

.DESCRIPTION
    Reconstructs the expected compliance policy assignment for a device:
    which policies could apply, which assignments were evaluated, whether
    the device or its associated user matched, whether an exclusion or
    assignment filter matched, and why the policy ultimately does or does
    not apply.

    This script is strictly read-only. Every Graph call it makes is a GET,
    or a POST that only reads (checkMemberGroups, the compliance-report
    export job). It never creates, updates, or deletes any Intune policy,
    Entra group, assignment, filter, or device.

    Version 1 supports Windows managed devices only. Non-Windows devices
    are reported as unsupported rather than silently skipped.

.PARAMETER ManagedDeviceId
    Analyze one device by its Intune managedDevice id.

.PARAMETER DeviceName
    Analyze one device by name. If more than one device shares the name,
    the script reports an explicit ambiguity error and stops rather than
    guessing which one you meant.

.PARAMETER AllDevicesWithoutCompliancePolicy
    Pull the Intune "devices without a compliance policy" report and
    analyze every device it returns.

.PARAMETER ReportJsonPath
    Use with -AllDevicesWithoutCompliancePolicy to analyze a
    DevicesWithoutCompliancePolicyV3 export you already have on disk
    (e.g. downloaded and unzipped outside this script, or saved from a
    prior run) instead of starting a new export job. This only replaces
    the "which devices lack a policy" input - the actual per-device
    analysis (policies, assignments, group membership, filters) still
    requires live Graph calls, since the report itself doesn't carry that
    information. Accepts the same shapes ConvertFrom-IntuneReportPayload
    understands: a bare array of row objects, a Schema/Values matrix, or a
    columns/values envelope.

.PARAMETER Connect
    If no active Microsoft Graph session is found, call Connect-MgGraph
    with the scopes this script needs. Without this switch, the script
    stops with a clear message instead of starting interactive sign-in.

.PARAMETER AccessToken
    Use an already-acquired Graph bearer token instead of an interactive
    Connect-MgGraph session - for unattended automation (a scheduled task,
    Azure Automation runbook, or Function) where the caller acquired a
    token itself (app-only/client-credentials, managed identity, or a
    delegated token obtained out-of-band). Pass it as a SecureString, e.g.:

        $token = ConvertTo-SecureString $rawToken -AsPlainText -Force
        .\Test-IntuneCompliancePolicyCoverage.ps1 -AccessToken $token -AllDevicesWithoutCompliancePolicy -ExportHtml

    The token must already carry the scopes/app roles this script needs
    (see .NOTES) - this script does not request consent or acquire tokens
    itself.

.PARAMETER OutputPath
    Directory to write -ExportJson/-ExportCsv/-ExportHtml output to.
    Defaults to the current directory.

.PARAMETER ExportJson
    Additionally write the full structured results to a timestamped JSON file.

.PARAMETER ExportCsv
    Additionally write the per-policy results to a timestamped CSV file.

.PARAMETER ExportHtml
    Additionally write a single self-contained HTML report (summary counts,
    a non-Windows platform breakdown in bulk mode, and one collapsible
    section per device) to a timestamped .html file.

.EXAMPLE
    .\Test-IntuneCompliancePolicyCoverage.ps1 -ManagedDeviceId "1b2c3d4e-..."

.EXAMPLE
    .\Test-IntuneCompliancePolicyCoverage.ps1 -DeviceName "WIN11-001"

.EXAMPLE
    .\Test-IntuneCompliancePolicyCoverage.ps1 -AllDevicesWithoutCompliancePolicy -ExportJson -ExportCsv -ExportHtml

.EXAMPLE
    # Unattended automation with an app-only token acquired by the caller
    $secureToken = ConvertTo-SecureString $env:GRAPH_TOKEN -AsPlainText -Force
    .\Test-IntuneCompliancePolicyCoverage.ps1 -AccessToken $secureToken -AllDevicesWithoutCompliancePolicy -ExportHtml -OutputPath 'C:\Reports'

.NOTES
    Required Graph permissions (delegated or application, least-privileged):
      DeviceManagementManagedDevices.Read.All
      DeviceManagementConfiguration.Read.All
      Device.Read.All
      User.ReadBasic.All
      GroupMember.Read.All
    See README.md for why each is needed and what breaks without it.
#>

[CmdletBinding(DefaultParameterSetName = 'SingleDeviceById')]
param(
    [Parameter(Mandatory, ParameterSetName = 'SingleDeviceById')]
    [string]$ManagedDeviceId,

    [Parameter(Mandatory, ParameterSetName = 'SingleDeviceByName')]
    [string]$DeviceName,

    [Parameter(Mandatory, ParameterSetName = 'Bulk')]
    [switch]$AllDevicesWithoutCompliancePolicy,

    [Parameter(ParameterSetName = 'Bulk')]
    [string]$ReportJsonPath,

    [switch]$Connect,

    [securestring]$AccessToken,

    [string]$OutputPath = '.',

    [switch]$ExportJson,

    [switch]$ExportCsv,

    [switch]$ExportHtml
)

Import-Module (Join-Path $PSScriptRoot 'CoverageAnalyzer.psm1') -Force

# ── Authenticate ──────────────────────────────────────────────────────────
# Three paths: an access token supplied for automation, an already-active
# interactive session, or (with -Connect) a fresh interactive sign-in. The
# script never starts sign-in on its own without -Connect/-AccessToken.
$script:RequiredScopes = @(
    'DeviceManagementManagedDevices.Read.All',
    'DeviceManagementConfiguration.Read.All',
    'Device.Read.All',
    'User.ReadBasic.All',
    'GroupMember.Read.All'
)

if ($AccessToken) {
    Write-Verbose 'Connecting to Microsoft Graph using the supplied access token.'
    Connect-MgGraph -AccessToken $AccessToken -NoWelcome
    $context = Get-MgContext
    if (-not $context) {
        Write-Error 'Connect-MgGraph -AccessToken did not produce a usable session. Verify the token is valid, unexpired, and issued for https://graph.microsoft.com.'
        return
    }
    # Token-based sessions (app-only, managed identity, or a pre-acquired
    # delegated token) don't always surface a Scopes/app-role list the same
    # way an interactive session does, so the scope-check below is skipped
    # here - a 403 on the first real call is the reliable signal instead.
}
else {
    $context = Get-MgContext
    if (-not $context) {
        if ($Connect) {
            Write-Verbose "No active Microsoft Graph session. Connecting with scopes: $($script:RequiredScopes -join ', ')"
            Connect-MgGraph -Scopes $script:RequiredScopes -NoWelcome
            $context = Get-MgContext
        }
        else {
            Write-Error "No active Microsoft Graph session. Run:`n`n  Connect-MgGraph -Scopes $($script:RequiredScopes -join ', ')`n`nor re-run this script with -Connect (interactive) or -AccessToken (automation). This script never starts interactive sign-in on its own."
            return
        }
    }

    $missingScopes = @($script:RequiredScopes | Where-Object { $context.Scopes -notcontains $_ })
    if ($missingScopes.Count -gt 0) {
        Write-Warning "The current Microsoft Graph session may be missing scopes: $($missingScopes -join ', '). If Graph calls fail with 403, reconnect with: Connect-MgGraph -Scopes $($script:RequiredScopes -join ', ')"
    }
}

# ── Helper functions used by every mode below ───────────────────────────

function Resolve-ReportRowToManagedDevice {
    <#
    .SYNOPSIS
        Correlates one "devices without compliance policy" report row back
        to a managedDevice. Does not assume the report's id column is a
        managedDevice id - tries it, and falls back to a name lookup
        (with the same ambiguity guard as -DeviceName) if that fails.
    #>
    [CmdletBinding()]
    param($ReportRow)

    $propertyNames = $ReportRow.PSObject.Properties.Name
    $idColumn = $propertyNames | Where-Object { $_ -match '^(IntuneDeviceId|DeviceId)$' } | Select-Object -First 1
    if (-not $idColumn) {
        $idColumn = $propertyNames | Where-Object { $_ -match 'DeviceId$' -and $_ -notmatch '^AAD' } | Select-Object -First 1
    }
    $nameColumn = $propertyNames | Where-Object { $_ -match '^DeviceName$' } | Select-Object -First 1

    if ($idColumn) {
        $id = $ReportRow.$idColumn
        if ($id) {
            $resolved = Get-IntuneManagedDeviceContext -ManagedDeviceId $id
            if ($resolved.Status -eq 'Resolved') { return $resolved }
            Write-Verbose "Report row id '$id' (column '$idColumn') did not resolve to a managedDevice ($($resolved.Reason)); falling back to name lookup."
        }
    }

    if ($nameColumn -and $ReportRow.$nameColumn) {
        return Get-IntuneManagedDeviceContext -DeviceName $ReportRow.$nameColumn
    }

    return [PSCustomObject]@{
        Status = 'NotFound'
        Reason = 'Report row did not contain a recognizable device id or device name column; add its column name to Resolve-ReportRowToManagedDevice.'
    }
}

function Invoke-DeviceCoverageAnalysis {
    <#
    .SYNOPSIS
        Runs the full coverage analysis for one already-resolved device and
        prints the RSOP-style result. Returns the per-policy result objects
        (or $null if the device was skipped as unsupported).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $DeviceContext,
        [Parameter(Mandatory)] [object[]]$Policies,
        [Parameter(Mandatory)] [hashtable]$AssignmentsByPolicyId,
        [Parameter(Mandatory)] [hashtable]$AssignmentFilters,
        [hashtable]$GroupDisplayNames = @{},
        [switch]$FromWithoutCompliancePolicyReport
    )

    if ($DeviceContext.Platform -ne 'Windows') {
        Write-Warning "Skipping '$($DeviceContext.DeviceName)': platform '$($DeviceContext.OperatingSystem)' is not supported in this version (Windows only)."
        return $null
    }

    $entraDeviceContext = Get-EntraDeviceContext -AzureADDeviceId $DeviceContext.AzureADDeviceId -PrimaryUserId $DeviceContext.UserId
    if ($entraDeviceContext.Status -eq 'Resolved' -and $entraDeviceContext.ResolvedVia -eq 'RegisteredDevicesCrossCheck') {
        # Duplicates existed but were resolved with confidence via the
        # managed device's own primary user - proceed using that object,
        # but still surface the duplicates as an actionable Entra ID cleanup
        # item, same visibility as the fully-ambiguous case below.
        Write-Warning "'$($DeviceContext.DeviceName)': $($entraDeviceContext.Reason)"
        $entraDeviceContext.Candidates | Format-Table -AutoSize | Out-String | Write-Host
    }
    elseif ($entraDeviceContext.Status -eq 'Ambiguous') {
        # A real, actionable finding (usually stale duplicate device objects
        # from re-imaging/re-enrollment) - surface it even without -Verbose,
        # with enough detail to go clean it up in Entra ID.
        Write-Warning "'$($DeviceContext.DeviceName)': $($entraDeviceContext.Reason)"
        $entraDeviceContext.Candidates | Format-Table -AutoSize | Out-String | Write-Host
        $script:AmbiguousEntraDevices.Add($DeviceContext.DeviceName)
    }
    elseif ($entraDeviceContext.Status -ne 'Resolved') {
        Write-Verbose "Entra device object could not be resolved for '$($DeviceContext.DeviceName)': $($entraDeviceContext.Reason). Device-side group membership will be Unknown."
    }

    $policyResults = Get-CompliancePolicyCoverageForDevice -DeviceContext $DeviceContext -EntraDeviceContext $entraDeviceContext `
        -Policies $Policies -AssignmentsByPolicyId $AssignmentsByPolicyId -AssignmentFilters $AssignmentFilters `
        -GroupDisplayNames $GroupDisplayNames -FromWithoutCompliancePolicyReport:$FromWithoutCompliancePolicyReport

    Format-ComplianceCoverageResult -DeviceContext $DeviceContext -PolicyResults $policyResults
    return $policyResults
}

# ── Fetch tenant-wide data once for the whole run ───────────────────────
# Policies, assignments, filters, and every referenced group's display name
# are the same regardless of which device(s) get analyzed below, so they're
# retrieved exactly once here rather than being re-fetched per device.
Write-Verbose 'Retrieving Windows compliance policies, assignments, and assignment filters (retrieved once for this run)'
$policies = Get-IntuneCompliancePolicies -Platform 'Windows'
if ($policies.Count -eq 0) {
    Write-Warning 'No Windows compliance policies were found in this tenant. Every device will evaluate to NotTargeted.'
}
$assignmentsByPolicyId = Get-IntuneComplianceAssignments
$assignmentFilters = Get-IntuneAssignmentFilters

# Resolve display names once for the whole run - the assignment group
# universe is tenant-wide (from policies/assignments already fetched once
# above), not per-device, so this must not be recomputed inside the
# per-device loop.
$allAssignmentGroupIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($policyAssignments in $assignmentsByPolicyId.Values) {
    foreach ($assignment in $policyAssignments) {
        if ($assignment.target.groupId) { [void]$allAssignmentGroupIds.Add($assignment.target.groupId) }
    }
}
$groupDisplayNames = Get-GroupDisplayNames -GroupIds @($allAssignmentGroupIds)

$allResults = [System.Collections.Generic.List[object]]::new()
$rollups = [System.Collections.Generic.List[object]]::new()
$unresolved = [System.Collections.Generic.List[object]]::new()
$script:AmbiguousEntraDevices = [System.Collections.Generic.List[string]]::new()

# ── Dispatch by mode ─────────────────────────────────────────────────────
# SingleDeviceById / SingleDeviceByName resolve exactly one device and run
# the analysis once. Bulk resolves the "devices without a compliance
# policy" report (freshly, or from -ReportJsonPath) into a device list,
# then runs the same per-device analysis in a loop, tallying non-Windows
# rows and Entra-ambiguous devices along the way for the end-of-run summary.
switch ($PSCmdlet.ParameterSetName) {

    'SingleDeviceById' {
        $deviceContext = Get-IntuneManagedDeviceContext -ManagedDeviceId $ManagedDeviceId
        if ($deviceContext.Status -ne 'Resolved') {
            Write-Error $deviceContext.Reason
            return
        }
        $results = Invoke-DeviceCoverageAnalysis -DeviceContext $deviceContext -Policies $policies -AssignmentsByPolicyId $assignmentsByPolicyId -AssignmentFilters $assignmentFilters -GroupDisplayNames $groupDisplayNames
        if ($results) { $allResults.AddRange($results) }
    }

    'SingleDeviceByName' {
        $deviceContext = Get-IntuneManagedDeviceContext -DeviceName $DeviceName
        if ($deviceContext.Status -eq 'Ambiguous') {
            Write-Error $deviceContext.Reason
            $deviceContext.Candidates | Format-Table -AutoSize | Out-String | Write-Host
            return
        }
        if ($deviceContext.Status -ne 'Resolved') {
            Write-Error $deviceContext.Reason
            return
        }
        $results = Invoke-DeviceCoverageAnalysis -DeviceContext $deviceContext -Policies $policies -AssignmentsByPolicyId $assignmentsByPolicyId -AssignmentFilters $assignmentFilters -GroupDisplayNames $groupDisplayNames
        if ($results) { $allResults.AddRange($results) }
    }

    'Bulk' {
        # Phase 1: get the device list (a fresh export job, or a file already on disk).
        if ($ReportJsonPath) {
            Write-Verbose "Loading devices-without-compliance-policy report from '$ReportJsonPath' (skipping a new export job)"
            if (-not (Test-Path -Path $ReportJsonPath -PathType Leaf)) {
                Write-Error "ReportJsonPath '$ReportJsonPath' was not found."
                return
            }
            $payload = Get-Content -Path $ReportJsonPath -Raw | ConvertFrom-Json
            $reportRows = ConvertFrom-IntuneReportPayload -Payload $payload
        }
        else {
            Write-Verbose 'Retrieving the devices-without-compliance-policy report'
            $reportRows = Get-DevicesWithoutCompliancePolicy
        }
        Write-Host "Devices reported without a compliance policy: $($reportRows.Count)" -ForegroundColor Cyan

        # Phase 2: platform triage - decide per row whether it's worth a Graph call at all.
        # Triage on the report row's own OS column first, before spending a
        # Graph call resolving each device - this report spans every
        # platform (Windows, iOS/iPadOS, Android, macOS...), and v1 of this
        # analyzer only evaluates Windows. Every row is still accounted for
        # in $script:UnsupportedPlatformCounts even when skipped, so bulk
        # runs give full visibility across platforms rather than silently
        # dropping non-Windows devices.
        $script:UnsupportedPlatformCounts = @{}

        foreach ($row in $reportRows) {
            $rowPlatform = Get-ReportRowPlatform -ReportRow $row
            if ($rowPlatform -ne 'Windows') {
                if (-not $script:UnsupportedPlatformCounts.ContainsKey($rowPlatform)) { $script:UnsupportedPlatformCounts[$rowPlatform] = 0 }
                $script:UnsupportedPlatformCounts[$rowPlatform]++
                Write-Verbose "Skipping '$($row.DeviceName)': platform '$rowPlatform' is not supported in this version (Windows only)."
                continue
            }

            # Phase 3: resolve the row to a real managedDevice, then run the full analysis on it.
            $deviceContext = Resolve-ReportRowToManagedDevice -ReportRow $row
            if ($deviceContext.Status -ne 'Resolved') {
                Write-Warning "Could not correlate a report row to a managed device: $($deviceContext.Reason)"
                $unresolved.Add($row)
                continue
            }

            $results = Invoke-DeviceCoverageAnalysis -DeviceContext $deviceContext -Policies $policies `
                -AssignmentsByPolicyId $assignmentsByPolicyId -AssignmentFilters $assignmentFilters `
                -GroupDisplayNames $groupDisplayNames -FromWithoutCompliancePolicyReport

            if ($results) {
                $allResults.AddRange($results)
                $rollups.Add((Get-DeviceCoverageRollup -DeviceContext $deviceContext -PolicyResults $results))
            }
        }

        # Phase 4: end-of-run summaries - per-device rollup, non-Windows breakdown, ambiguity count.
        if ($rollups.Count -gt 0) {
            Format-ComplianceCoverageSummary -DeviceRollupResults $rollups
        }
        if ($script:UnsupportedPlatformCounts.Count -gt 0) {
            Write-Host ''
            Write-Host 'Other platforms in this report (not evaluated - Windows only in this version):' -ForegroundColor DarkYellow
            $script:UnsupportedPlatformCounts.GetEnumerator() | Sort-Object -Property Value -Descending | ForEach-Object {
                Write-Host ("{0,4}  {1}" -f $_.Value, $_.Key)
            }
        }
        if ($script:AmbiguousEntraDevices.Count -gt 0) {
            Write-Host ''
            Write-Warning "$($script:AmbiguousEntraDevices.Count) of $($rollups.Count) evaluated device(s) have duplicate Entra device objects (same deviceId, multiple directory objects) - device-side group membership was Unknown for these. This usually means stale objects left behind by re-imaging/re-enrollment; re-run a single device with -Verbose to see the candidate object ids for cleanup: $($script:AmbiguousEntraDevices -join ', ')"
        }
        if ($unresolved.Count -gt 0) {
            Write-Warning "$($unresolved.Count) report row(s) could not be correlated to a managed device and were skipped."
        }
    }
}

# ── Export (optional) ────────────────────────────────────────────────────
# Console output above is already complete on its own; these just write the
# same $allResults (plus $rollups/$UnsupportedPlatformCounts for HTML) to disk.
if ($ExportJson -or $ExportCsv -or $ExportHtml) {
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    if ($ExportJson) {
        $jsonPath = Join-Path $OutputPath "IntuneCompliancePolicyCoverage_$timestamp.json"
        $allResults | ConvertTo-Json -Depth 8 | Set-Content -Path $jsonPath -Encoding UTF8
        Write-Host "Exported JSON: $jsonPath" -ForegroundColor Green
    }
    if ($ExportCsv) {
        $csvPath = Join-Path $OutputPath "IntuneCompliancePolicyCoverage_$timestamp.csv"
        $allResults | Select-Object DeviceName, ManagedDeviceId, EntraDeviceId, UserPrincipalName, PolicyId, PolicyName, Platform, Result, Reason |
            Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
        Write-Host "Exported CSV: $csvPath" -ForegroundColor Green
    }
    if ($ExportHtml) {
        $htmlPath = Join-Path $OutputPath "IntuneCompliancePolicyCoverage_$timestamp.html"
        $html = Export-ComplianceCoverageHtml -Results $allResults -DeviceRollups $rollups -UnsupportedPlatformCounts $script:UnsupportedPlatformCounts
        $html | Set-Content -Path $htmlPath -Encoding UTF8
        Write-Host "Exported HTML: $htmlPath" -ForegroundColor Green
    }
}

return $allResults
