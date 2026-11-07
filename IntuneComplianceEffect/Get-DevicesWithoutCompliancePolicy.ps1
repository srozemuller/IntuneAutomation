<#
.SYNOPSIS
    Checks the Intune "secureByDefault" setting and exports the DevicesWithoutCompliancePolicyV3 report.

.DESCRIPTION
    1. Reads secureByDefault from /beta/deviceManagement/settings.
       secureByDefault = $false -> devices without a compliance policy are marked COMPLIANT.
       secureByDefault = $true  -> devices without a compliance policy are marked NOT COMPLIANT.
    2. Starts an export job for the DevicesWithoutCompliancePolicyV3 report.
    3. Polls the job until status = completed (or failed / timeout).
    4. Downloads the zip from the returned url, unzips it and parses the JSON.
    5. Flags devices that are only compliant because of the default.
    6. Reads all Conditional Access policies and lists the ones that use device compliance
       (grant control "compliantDevice" or a device filter on device.isCompliant), with
       their effect on a non-compliant device.
    7. Evaluates per device (user, groups, roles, platform) which policies would block it.
    8. Writes an HTML report with the effect per device and the CA policy overview.

.PARAMETER PolicyOutputPath
    Optional path to a .csv file for the Conditional Access overview.

.PARAMETER HtmlReportPath
    Path for the HTML report. Default: .\ComplianceImpactReport_<yyyyMMdd_HHmm>.html

.PARAMETER NoHtmlReport
    Do not generate the HTML report.

.PARAMETER SkipDeviceEvaluation
    Skip the per-device CA evaluation (saves one transitiveMemberOf call per user).

.PARAMETER TenantId
    Tenant to sign in to interactively (tenant ID or domain, e.g. contoso.onmicrosoft.com).
    If omitted you get the account picker and sign in to the home tenant of the account you choose.

.PARAMETER AccessToken
    Optional bearer token. When given, no interactive sign-in is done.

.PARAMETER UseExistingSession
    Reuse the current Connect-MgGraph session instead of signing in again.
    By default the script disconnects first, so you never run against the wrong tenant by accident.

.PARAMETER PollIntervalSeconds
    Seconds between status checks. Default 5.

.PARAMETER TimeoutMinutes
    Give up after this many minutes. Default 10.

.PARAMETER OutputPath
    Optional path to a .csv file to export the results to.

.PARAMETER KeepDownload
    Keep the downloaded zip and extracted JSON instead of cleaning them up.

.NOTES
    Required Graph permissions (delegated or application):
      DeviceManagementServiceConfig.Read.All   (deviceManagement/settings)
      DeviceManagementManagedDevices.Read.All  (reports/exportJobs)
      DeviceManagementConfiguration.Read.All   (reports/exportJobs)
      Policy.Read.All                          (identity/conditionalAccess/policies)
      Directory.Read.All                       (users/{id}/transitiveMemberOf: groups + roles)

.EXAMPLE
    .\Get-DevicesWithoutCompliancePolicy.ps1 -TenantId contoso.onmicrosoft.com -OutputPath .\no-compliance.csv

.EXAMPLE
    .\Get-DevicesWithoutCompliancePolicy.ps1 -AccessToken $token | Format-Table DeviceName, UPN, ComplianceState_loc, CompliantByDefault
#>
[CmdletBinding()]
param(
    [string]$TenantId,
    [string]$AccessToken,
    [switch]$UseExistingSession,
    [ValidateRange(1, 300)]
    [int]$PollIntervalSeconds = 5,
    [ValidateRange(1, 120)]
    [int]$TimeoutMinutes = 10,
    [string]$OutputPath,
    [string]$PolicyOutputPath,
    [switch]$SkipDeviceEvaluation,
    [string]$HtmlReportPath,
    [switch]$NoHtmlReport,
    [switch]$KeepDownload
)

$ErrorActionPreference = 'Stop'
$graphBase = 'https://graph.microsoft.com/beta'

#region Graph helper / sign-in
$requiredScopes = @(
    'DeviceManagementServiceConfig.Read.All',
    'DeviceManagementManagedDevices.Read.All',
    'DeviceManagementConfiguration.Read.All',
    'Policy.Read.All',
    'Directory.Read.All'
)

if ($AccessToken) {
    $AccessToken = $AccessToken -replace '^\s*Bearer\s+', ''
}
else {
    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
        throw "Interactive sign-in needs the Microsoft.Graph.Authentication module. Run: Install-Module Microsoft.Graph.Authentication -Scope CurrentUser"
    }
    Import-Module Microsoft.Graph.Authentication

    $ctx = Get-MgContext
    $reuse = $UseExistingSession -and $ctx -and (-not $TenantId -or $ctx.TenantId -eq $TenantId)
    if (-not $reuse) {
        if ($ctx) { Disconnect-MgGraph | Out-Null }
        $connect = @{ Scopes = $requiredScopes; NoWelcome = $true; ContextScope = 'Process' }
        if ($TenantId) { $connect.TenantId = $TenantId }
        Connect-MgGraph @connect
        $ctx = Get-MgContext
    }

    $missing = $requiredScopes | Where-Object { $_ -notin $ctx.Scopes }
    if ($missing) { Write-Warning "Signed in, but these scopes were not granted: $($missing -join ', ')" }
    Write-Host "Signed in as $($ctx.Account) to tenant $($ctx.TenantId)" -ForegroundColor Cyan
}

function Invoke-Graph {
    param(
        [Parameter(Mandatory)][ValidateSet('GET', 'POST')][string]$Method,
        [Parameter(Mandatory)][string]$Uri,
        [object]$Body
    )

    $params = @{ Method = $Method; Uri = $Uri }
    if ($Body) {
        $params.Body        = ($Body | ConvertTo-Json -Depth 10)
        $params.ContentType = 'application/json'
    }

    if ($AccessToken) {
        $params.Headers = @{ Authorization = "Bearer $AccessToken" }
        return Invoke-RestMethod @params
    }
    return Invoke-MgGraphRequest @params -OutputType PSObject
}

function Invoke-GraphPaged {
    param([Parameter(Mandatory)][string]$Uri)
    $items = [System.Collections.Generic.List[object]]::new()
    $next = $Uri
    while ($next) {
        $resp = Invoke-Graph -Method GET -Uri $next
        if ($resp.value) { $items.AddRange([object[]]$resp.value) }
        $next = $resp.'@odata.nextLink'
    }
    return $items
}
#endregion

#region 1. secureByDefault
Write-Verbose "Reading deviceManagement settings..."
$settings = Invoke-Graph -Method GET -Uri "$graphBase/deviceManagement/settings"

# Depending on the endpoint shape the property can be on the root or under 'value'
$secureByDefault = if ($null -ne $settings.secureByDefault) { $settings.secureByDefault }
                   elseif ($null -ne $settings.value.secureByDefault) { $settings.value.secureByDefault }
                   else { $null }

if ($null -eq $secureByDefault) {
    # Fallback: read it via the deviceManagement root
    $dm = Invoke-Graph -Method GET -Uri "$graphBase/deviceManagement?`$select=settings"
    $secureByDefault = $dm.settings.secureByDefault
}

if ($null -eq $secureByDefault) {
    throw "Could not read secureByDefault from deviceManagement/settings."
}

$secureByDefault = [bool]$secureByDefault

if ($secureByDefault) {
    Write-Host "secureByDefault = True  -> devices without a compliance policy are marked NOT compliant." -ForegroundColor Green
}
else {
    Write-Warning "secureByDefault = False -> devices without a compliance policy are marked COMPLIANT by default."
}
#endregion

#region 2. Start export job
$jobBody = @{
    reportName       = 'DevicesWithoutCompliancePolicyV3'
    localizationType = 'LocalizedValuesAsAdditionalColumn'
    format           = 'json'
}

Write-Verbose "Creating export job..."
$job = Invoke-Graph -Method POST -Uri "$graphBase/deviceManagement/reports/exportJobs" -Body $jobBody
$jobId = $job.id
Write-Host "Export job created: $jobId (status: $($job.status))"
#endregion

#region 3. Poll until completed
$deadline = (Get-Date).AddMinutes($TimeoutMinutes)

while ($job.status -ne 'completed') {
    if ($job.status -eq 'failed') {
        throw "Export job $jobId failed."
    }
    if ((Get-Date) -gt $deadline) {
        throw "Export job $jobId did not complete within $TimeoutMinutes minutes (last status: $($job.status))."
    }

    Start-Sleep -Seconds $PollIntervalSeconds
    $job = Invoke-Graph -Method GET -Uri "$graphBase/deviceManagement/reports/exportJobs('$jobId')"
    Write-Verbose "Status: $($job.status)"
}

if (-not $job.url) {
    throw "Export job $jobId is completed but returned no download url."
}
Write-Host "Export job completed."
#endregion

#region 4. Download and unzip
$workDir = Join-Path ([System.IO.Path]::GetTempPath()) "IntuneReport_$([guid]::NewGuid())"
New-Item -ItemType Directory -Path $workDir -Force | Out-Null
$zipPath     = Join-Path $workDir "$jobId.zip"
$extractPath = Join-Path $workDir 'extracted'

try {
    # The url is a pre-signed blob url: no Graph Authorization header needed (or wanted)
    Invoke-WebRequest -Uri $job.url -OutFile $zipPath -UseBasicParsing
    Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force

    $jsonFile = Get-ChildItem -Path $extractPath -Filter '*.json' -Recurse | Select-Object -First 1
    if (-not $jsonFile) {
        throw "No JSON file found in the downloaded zip."
    }

    $report = Get-Content -Path $jsonFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
}
finally {
    if (-not $KeepDownload) {
        Remove-Item -Path $workDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    else {
        Write-Host "Download kept in: $workDir"
    }
}
#endregion

#region 5. Build output
$devices = foreach ($row in $report.values) {
    # A device in this report has no compliance policy. If it shows as Compliant
    # while secureByDefault is false, it is only compliant because of the tenant default.
    $compliantByDefault = (-not $secureByDefault) -and ($row.ComplianceState -eq '1')

    $row | Add-Member -NotePropertyName 'SecureByDefault'    -NotePropertyValue $secureByDefault    -PassThru |
           Add-Member -NotePropertyName 'CompliantByDefault' -NotePropertyValue $compliantByDefault -PassThru
}

$total     = @($devices).Count
$byDefault = @($devices | Where-Object CompliantByDefault).Count

Write-Host ""
Write-Host "Devices without a compliance policy : $total"
Write-Host "  of which compliant only by default: $byDefault"
$devices | Group-Object ComplianceState_loc | ForEach-Object {
    Write-Host ("  {0,-34}: {1}" -f $_.Name, $_.Count)
}

#endregion

#region 6. Conditional Access policies that depend on compliance
Write-Verbose "Reading Conditional Access policies..."
$allPolicies = Invoke-GraphPaged -Uri "$graphBase/identity/conditionalAccess/policies"

function Get-ScopeText {
    param($Include, $Exclude, [string]$Label)
    $inc = @($Include | Where-Object { $_ })
    $exc = @($Exclude | Where-Object { $_ })
    if (-not $inc.Count -and -not $exc.Count) { return $null }
    $txt = if ($inc -contains 'All') { "All $Label" } elseif ($inc.Count) { "$($inc.Count) $Label" } else { $null }
    if ($exc.Count) { $txt = "$txt (excl. $($exc.Count))".Trim() }
    return $txt
}

$caPolicies = foreach ($p in $allPolicies) {
    $grant      = $p.grantControls
    $controls   = @($grant.builtInControls | Where-Object { $_ })
    $filterRule = $p.conditions.devices.deviceFilter.rule
    $filterMode = $p.conditions.devices.deviceFilter.mode

    $platforms    = $p.conditions.platforms
    $devCond      = $p.conditions.devices
    $isBlock      = $controls -contains 'block'

    # Why is this policy device/compliance related?
    $relation = @()
    $requiresCompliance   = $controls -contains 'compliantDevice'
    $usesComplianceFilter = [bool]($filterRule -match 'device\.isCompliant')
    if ($requiresCompliance)                         { $relation += 'Grant: compliant device' }
    if ($controls -contains 'domainJoinedDevice')    { $relation += 'Grant: hybrid joined device' }
    if ($controls -contains 'approvedApplication')   { $relation += 'Grant: approved client app' }
    if ($controls -contains 'compliantApplication')  { $relation += 'Grant: app protection policy' }
    if ($filterRule)                                 { $relation += "Device filter ($filterMode)" }
    if (@($devCond.includeDeviceStates).Count -or @($devCond.excludeDeviceStates).Count) { $relation += 'Device state (legacy)' }
    if ($platforms -and (@($platforms.includePlatforms).Count -or @($platforms.excludePlatforms).Count)) { $relation += 'Device platforms' }
    if (-not $relation.Count) { continue }

    # Other controls that can be used instead of / next to compliance
    $alternatives = @($controls | Where-Object { $_ -notin 'compliantDevice', 'block' })
    if ($grant.authenticationStrength) { $alternatives += "authStrength: $($grant.authenticationStrength.displayName)" }
    if (@($grant.termsOfUse).Count)    { $alternatives += 'termsOfUse' }

    $platformText = if ($platforms) {
        (@($platforms.includePlatforms) -join ', ') + $(if (@($platforms.excludePlatforms).Count) { " (excl. $(@($platforms.excludePlatforms) -join ', '))" })
    } else { 'all platforms' }

    $blocksNonCompliant = $null   # $true / $false / $null (= not compliance related or review manually)
    if ($requiresCompliance) {
        if ($grant.operator -eq 'OR' -and $alternatives.Count) {
            $blocksNonCompliant = $false
            $effect = "Not blocked: the user can satisfy the policy with $($alternatives -join ', ') instead of a compliant device"
        }
        else {
            $blocksNonCompliant = $true
            $effect = 'Access denied from a non-compliant device'
            if ($alternatives.Count) { $effect += " (and $($alternatives -join ', ') is also required)" }
        }
    }
    elseif ($usesComplianceFilter) {
        # Device filter on isCompliant. Only the common patterns are evaluated automatically.
        $targetsNonCompliant =
            ($filterMode -eq 'include' -and $filterRule -match 'device\.isCompliant\s+-(eq\s+False|ne\s+True)') -or
            ($filterMode -eq 'exclude' -and $filterRule -match 'device\.isCompliant\s+-(eq\s+True|ne\s+False)')
        if ($isBlock -and $targetsNonCompliant) {
            $blocksNonCompliant = $true
            $effect = "Access blocked via device filter (${filterMode}: $filterRule)"
        }
        else {
            $effect = "Device filter on compliance (${filterMode}: $filterRule), grant: $($controls -join ', '). Review manually"
        }
    }
    else {
        # Device related, but compliance state itself does not decide the outcome
        $effect = if ($isBlock) {
            "No compliance effect. Blocks access on $platformText" + $(if ($filterRule) { " for devices matching filter (${filterMode}: $filterRule)" })
        }
        elseif ($controls -contains 'domainJoinedDevice' -and ($grant.operator -ne 'OR' -or $controls.Count -eq 1)) {
            'No compliance effect. Requires a hybrid Entra joined device; a compliant but non-joined device is blocked'
        }
        elseif ($controls.Count) {
            "No compliance effect. Requires $($controls -join " $($grant.operator) ") on $platformText"
        }
        else {
            "No compliance effect. Session controls only on $platformText"
        }
    }

    $enforcement = switch ($p.state) {
        'enabled'                           { 'Enforced' }
        'enabledForReportingButNotEnforced' { 'Report-only' }
        default                             { 'Disabled' }
    }
    if ($enforcement -eq 'Report-only') { $effect = "[Report-only, nothing is blocked] $effect" }
    if ($enforcement -eq 'Disabled')    { $effect = "[Disabled, no effect] $effect" }

    $u = $p.conditions.users
    [pscustomobject]@{
        PolicyName         = $p.displayName
        PolicyId           = $p.id
        State              = $enforcement
        Relation           = ($relation -join '; ')
        GrantControls      = ($controls -join ', ')
        Operator           = $grant.operator
        Alternatives       = ($alternatives -join ', ')
        DeviceFilter       = if ($filterRule) { "${filterMode}: $filterRule" } else { $null }
        Users              = (@(
                                Get-ScopeText $u.includeUsers  $u.excludeUsers  'users'
                                Get-ScopeText $u.includeGroups $u.excludeGroups 'groups'
                                Get-ScopeText $u.includeRoles  $u.excludeRoles  'roles'
                             ) | Where-Object { $_ }) -join '; '
        Applications       = Get-ScopeText $p.conditions.applications.includeApplications $p.conditions.applications.excludeApplications 'apps'
        Platforms          = if ($platforms) { $platformText } else { 'All' }
        ClientAppTypes     = (@($p.conditions.clientAppTypes) -join ', ')
        BlocksNonCompliant = $blocksNonCompliant
        Effect             = $effect
        Raw                = $p
    }
}

Write-Host ""
Write-Host "Conditional Access policies related to devices or compliance: $(@($caPolicies).Count) of $(@($allPolicies).Count)"
if ($caPolicies) {
    $caPolicies | Sort-Object State, PolicyName |
        Format-Table PolicyName, State, Relation, GrantControls, Operator, Users, Platforms, Effect -Wrap -AutoSize |
        Out-String -Width 250 | Write-Host
}
else {
    Write-Warning "No Conditional Access policy is related to devices or compliance."
}

if ($PolicyOutputPath) {
    $caPolicies | Select-Object * -ExcludeProperty Raw | Export-Csv -Path $PolicyOutputPath -NoTypeInformation -Encoding UTF8
    Write-Host "CA overview exported to $PolicyOutputPath"
}
#endregion

#region 7. Effect per device
$platformMap = @{ 'Windows' = 'windows'; 'iOS' = 'iOS'; 'iPadOS' = 'iOS'; 'Android' = 'android'; 'macOS' = 'macOS'; 'Linux' = 'linux' }
$memberCache = @{}

function Get-UserMembership {
    param([string]$UserId)
    if (-not $memberCache.ContainsKey($UserId)) {
        $objs = Invoke-GraphPaged -Uri "$graphBase/users/$UserId/transitiveMemberOf?`$select=id,roleTemplateId"
        $memberCache[$UserId] = [pscustomobject]@{
            Groups = @($objs | Where-Object { $_.'@odata.type' -eq '#microsoft.graph.group' } | ForEach-Object id)
            Roles  = @($objs | Where-Object { $_.roleTemplateId } | ForEach-Object roleTemplateId)
        }
    }
    return $memberCache[$UserId]
}

function Test-PolicyApplies {
    param($Policy, [string]$UserId, $Membership, [string]$Platform)
    $u = $Policy.Raw.conditions.users
    $hit = { param($a, $b) [bool](@($a) | Where-Object { $_ -in @($b) }) }

    $included = (@($u.includeUsers) -contains 'All') -or (@($u.includeUsers) -contains $UserId) -or
                (& $hit $u.includeGroups $Membership.Groups) -or (& $hit $u.includeRoles $Membership.Roles)
    $excluded = (@($u.excludeUsers) -contains $UserId) -or
                (& $hit $u.excludeGroups $Membership.Groups) -or (& $hit $u.excludeRoles $Membership.Roles)
    if (-not $included -or $excluded) { return $false }

    $pl = $Policy.Raw.conditions.platforms
    if ($pl -and $Platform) {
        $inc = @($pl.includePlatforms)
        if (-not ($inc -contains 'all' -or $inc -contains $Platform)) { return $false }
        if (@($pl.excludePlatforms) -contains $Platform) { return $false }
    }
    return $true
}

$blockingPolicies = @($caPolicies | Where-Object { $_.BlocksNonCompliant -and $_.State -ne 'Disabled' })

if (-not $SkipDeviceEvaluation) {
    Write-Verbose "Evaluating CA impact per device..."
    foreach ($d in $devices) {
        $enforced = @(); $reportOnly = @()
        if ($d.UserId -and $blockingPolicies.Count) {
            $membership = Get-UserMembership -UserId $d.UserId
            $platform   = $platformMap[$d.OS]
            foreach ($bp in $blockingPolicies) {
                if (Test-PolicyApplies -Policy $bp -UserId $d.UserId -Membership $membership -Platform $platform) {
                    if ($bp.State -eq 'Enforced') { $enforced += $bp.PolicyName } else { $reportOnly += $bp.PolicyName }
                }
            }
        }

        $isCompliant = $d.ComplianceState -eq '1'
        if (-not $d.UserId) {
            $category = 'NoUser'
            $outcome  = 'No user on device: check user-targeted policies manually'
        }
        elseif ($isCompliant -and $d.CompliantByDefault) {
            if ($enforced) {
                $category = 'AtRisk'
                $outcome  = "Has access ONLY because secureByDefault = false. With secureByDefault = true it is blocked by: $($enforced -join '; ')"
            }
            else {
                $category = 'CompliantByDefault'
                $outcome  = 'Compliant by default; no enforced policy would block it anyway'
            }
        }
        elseif ($isCompliant) {
            $category = 'Compliant'
            $outcome  = 'Compliant: passes the compliance requirement'
        }
        elseif ($enforced) {
            $category = 'Blocked'
            $outcome  = "BLOCKED by: $($enforced -join '; ')"
        }
        elseif ($reportOnly) {
            $category = 'ReportOnly'
            $outcome  = "Not compliant; would be blocked by report-only policy: $($reportOnly -join '; ')"
        }
        else {
            $category = 'Unprotected'
            $outcome  = 'Not compliant, but no enforced policy blocks this user/platform'
        }

        $d | Add-Member -NotePropertyName 'BlockingCAPolicies'   -NotePropertyValue ($enforced -join '; ')   -Force
        $d | Add-Member -NotePropertyName 'ReportOnlyCAPolicies' -NotePropertyValue ($reportOnly -join '; ') -Force
        $d | Add-Member -NotePropertyName 'CAOutcomeCategory'    -NotePropertyValue $category                -Force
        $d | Add-Member -NotePropertyName 'CAOutcome'            -NotePropertyValue $outcome                 -Force
    }

    Write-Host "Effect per device:"
    $devices | Format-Table DeviceName, UPN, OS, ComplianceState_loc, CompliantByDefault, CAOutcome -Wrap -AutoSize |
        Out-String -Width 250 | Write-Host
    Write-Host "Note: this evaluates users, groups, roles and platforms only. App, location, risk and client-app conditions are not evaluated; check them in the Effect column of the policy overview." -ForegroundColor DarkGray
}

if ($OutputPath) {
    $devices | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
    Write-Host "Results exported to $OutputPath"
}
#endregion

#region 8. HTML report
if (-not $NoHtmlReport) {
    function Enc([object]$v) { [System.Net.WebUtility]::HtmlEncode([string]$v) }

    $tenantName = $null
    try {
        $org = Invoke-Graph -Method GET -Uri "$graphBase/organization?`$select=displayName,id"
        $tenantName = "$($org.value[0].displayName) ($($org.value[0].id))"
    } catch { $tenantName = 'Unknown tenant' }

    $catInfo = [ordered]@{
        Blocked            = @{ Label = 'Blocked';                       Class = 'red'    }
        AtRisk             = @{ Label = 'Compliant only by default';     Class = 'orange' }
        Unprotected        = @{ Label = 'Not compliant, not blocked';    Class = 'purple' }
        ReportOnly         = @{ Label = 'Report-only would block';       Class = 'yellow' }
        CompliantByDefault = @{ Label = 'Compliant by default, no impact'; Class = 'grey' }
        Compliant          = @{ Label = 'Compliant';                     Class = 'green'  }
        NoUser             = @{ Label = 'No user';                       Class = 'grey'   }
    }

    $counts = @{}
    foreach ($k in $catInfo.Keys) { $counts[$k] = @($devices | Where-Object CAOutcomeCategory -eq $k).Count }

    $tiles = foreach ($k in $catInfo.Keys) {
        if ($counts[$k] -eq 0 -and $k -in 'NoUser', 'ReportOnly') { continue }
        "<div class='tile $($catInfo[$k].Class)' data-cat='$k'><div class='num'>$($counts[$k])</div><div class='lbl'>$(Enc $catInfo[$k].Label)</div></div>"
    }

    $deviceRows = foreach ($d in ($devices | Sort-Object @{ e = { @($catInfo.Keys).IndexOf($_.CAOutcomeCategory) } }, DeviceName)) {
        $c = if ($d.CAOutcomeCategory) { $catInfo[$d.CAOutcomeCategory] } else { @{ Label = 'Not evaluated'; Class = 'grey' } }
        @"
<tr data-cat='$($d.CAOutcomeCategory)'>
  <td><b>$(Enc $d.DeviceName)</b><div class='sub'>$(Enc $d.DeviceModel)</div></td>
  <td>$(Enc $d.UserName)<div class='sub'>$(Enc $d.UPN)</div></td>
  <td>$(Enc $d.OS) <span class='sub'>$(Enc $d.OSVersion)</span></td>
  <td>$(Enc $d.OwnerType_loc)</td>
  <td>$(Enc $d.ComplianceState_loc)</td>
  <td>$(Enc $d.LastContact)</td>
  <td><span class='badge $($c.Class)'>$(Enc $c.Label)</span><div class='outcome'>$(Enc $d.CAOutcome)</div></td>
  <td>$(Enc $d.BlockingCAPolicies)$(if ($d.ReportOnlyCAPolicies) { "<div class='sub'>Report-only: $(Enc $d.ReportOnlyCAPolicies)</div>" })</td>
</tr>
"@
    }

    $policyRows = foreach ($p in ($caPolicies | Sort-Object State, PolicyName)) {
        $impact = if ($p.State -eq 'Disabled') { 'grey' } elseif ($p.BlocksNonCompliant -eq $true) { 'red' } elseif ($p.BlocksNonCompliant -eq $false) { 'orange' } elseif ($p.Effect -match 'Review manually') { 'yellow' } else { 'blue' }
        $stateClass = switch ($p.State) { 'Enforced' { 'green' } 'Report-only' { 'yellow' } default { 'grey' } }
        @"
<tr>
  <td><b>$(Enc $p.PolicyName)</b></td>
  <td><span class='badge $stateClass'>$(Enc $p.State)</span></td>
  <td>$(($p.Relation -split '; ' | ForEach-Object { "<span class='tag'>$(Enc $_)</span>" }) -join ' ')</td>
  <td>$(Enc $p.GrantControls)$(if ($p.Operator) { " <span class='sub'>($(Enc $p.Operator))</span>" })$(if ($p.DeviceFilter) { "<div class='sub'>Filter: $(Enc $p.DeviceFilter)</div>" })</td>
  <td>$(Enc $p.Users)</td>
  <td>$(Enc $p.Applications)</td>
  <td>$(Enc $p.Platforms)</td>
  <td><span class='dot $impact'></span>$(Enc $p.Effect)</td>
</tr>
"@
    }

    $sbdHtml = if ($secureByDefault) {
        "<div class='banner green'><b>secureByDefault = True.</b> Devices without a compliance policy are marked <b>not compliant</b>.</div>"
    } else {
        "<div class='banner orange'><b>secureByDefault = False.</b> Devices without a compliance policy are marked <b>compliant</b> and pass every Conditional Access policy that requires a compliant device.</div>"
    }

    $html = @"
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<title>Compliance impact report: $(Enc $tenantName)</title>
<style>
  :root { --bg:#f6f7f9; --card:#fff; --text:#1d2330; --muted:#6b7385; --line:#e3e6ec;
          --red:#c62828; --orange:#e67700; --yellow:#b59a00; --green:#2e7d32; --purple:#6a1b9a; --grey:#78808f; }
  * { box-sizing:border-box }
  body { font-family:'Segoe UI',system-ui,sans-serif; background:var(--bg); color:var(--text); margin:0; padding:32px; font-size:14px }
  h1 { margin:0 0 4px; font-size:24px } h2 { font-size:18px; margin:32px 0 12px }
  .meta { color:var(--muted); margin-bottom:20px }
  .banner { padding:12px 16px; border-radius:8px; border-left:5px solid; background:var(--card); margin-bottom:20px }
  .banner.green { border-color:var(--green) } .banner.orange { border-color:var(--orange) }
  .tiles { display:flex; gap:12px; flex-wrap:wrap }
  .tile { background:var(--card); border-radius:8px; padding:14px 18px; min-width:160px; border-top:4px solid; cursor:pointer; box-shadow:0 1px 2px rgba(0,0,0,.05) }
  .tile.active { outline:2px solid var(--text) }
  .tile .num { font-size:28px; font-weight:600 } .tile .lbl { color:var(--muted) }
  .tile.red{border-color:var(--red)} .tile.orange{border-color:var(--orange)} .tile.yellow{border-color:var(--yellow)}
  .tile.green{border-color:var(--green)} .tile.purple{border-color:var(--purple)} .tile.grey{border-color:var(--grey)}
  .toolbar { margin:16px 0 8px; display:flex; gap:8px }
  .toolbar input { padding:8px 10px; border:1px solid var(--line); border-radius:6px; width:320px; font:inherit }
  .toolbar button { padding:8px 12px; border:1px solid var(--line); border-radius:6px; background:var(--card); cursor:pointer; font:inherit }
  table { width:100%; border-collapse:collapse; background:var(--card); border-radius:8px; overflow:hidden; box-shadow:0 1px 2px rgba(0,0,0,.05) }
  th { text-align:left; background:#eef0f4; padding:10px; font-weight:600; position:sticky; top:0 }
  td { padding:10px; border-top:1px solid var(--line); vertical-align:top }
  .sub { color:var(--muted); font-size:12px } .outcome { font-size:12px; margin-top:4px }
  .badge { display:inline-block; padding:2px 8px; border-radius:10px; color:#fff; font-size:12px; white-space:nowrap }
  .badge.red{background:var(--red)} .badge.orange{background:var(--orange)} .badge.yellow{background:var(--yellow)}
  .badge.green{background:var(--green)} .badge.purple{background:var(--purple)} .badge.grey{background:var(--grey)}
  .dot { display:inline-block; width:10px; height:10px; border-radius:50%; margin-right:6px }
  .dot.red{background:var(--red)} .dot.orange{background:var(--orange)} .dot.yellow{background:var(--yellow)} .dot.grey{background:var(--grey)} .dot.blue{background:#1565c0}
  .tag { display:inline-block; padding:1px 6px; margin:1px 0; border:1px solid var(--line); border-radius:4px; font-size:12px; background:#f3f5f8; white-space:nowrap }
  .note { color:var(--muted); font-size:12px; margin-top:8px }
  @media print { body{padding:0;background:#fff} .toolbar{display:none} th{position:static} }
</style></head>
<body>
<h1>Devices without a compliance policy: Conditional Access impact</h1>
<div class="meta">$(Enc $tenantName) | Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm') | Report: DevicesWithoutCompliancePolicyV3</div>
$sbdHtml
<div class="tiles">$($tiles -join "`n")</div>

<h2>Effect per device ($total)</h2>
<div class="toolbar">
  <input id="q" placeholder="Search device, user, policy..." oninput="filter()">
  <button onclick="setCat(null)">Show all</button>
</div>
<table id="dev">
<thead><tr><th>Device</th><th>User</th><th>OS</th><th>Ownership</th><th>Compliance state</th><th>Last contact</th><th>Effect</th><th>Blocking CA policies</th></tr></thead>
<tbody>
$($deviceRows -join "`n")
</tbody></table>
<div class="note">Evaluated per device: users, groups, roles and platform. App, location, sign-in risk and client-app conditions are not evaluated.</div>

<h2>Conditional Access policies related to devices or compliance ($(@($caPolicies).Count) of $(@($allPolicies).Count))</h2>
<table>
<thead><tr><th>Policy</th><th>State</th><th>Why included</th><th>Grant</th><th>Users</th><th>Apps</th><th>Platforms</th><th>Effect on a non-compliant device</th></tr></thead>
<tbody>
$(if ($policyRows) { $policyRows -join "`n" } else { "<tr><td colspan='8'>No Conditional Access policy is related to devices or compliance.</td></tr>" })
</tbody></table>
<div class="note"><span class="dot red"></span>blocks non-compliant devices <span class="dot orange"></span>can be bypassed via another grant control (OR) <span class="dot yellow"></span>review manually <span class="dot blue"></span>device related, no compliance effect <span class="dot grey"></span>disabled</div>

<script>
  let cat = null;
  function setCat(c) {
    cat = (cat === c) ? null : c;
    document.querySelectorAll('.tile').forEach(t => t.classList.toggle('active', t.dataset.cat === cat));
    filter();
  }
  function filter() {
    const q = document.getElementById('q').value.toLowerCase();
    document.querySelectorAll('#dev tbody tr').forEach(r => {
      const okCat = !cat || r.dataset.cat === cat;
      const okQ = !q || r.textContent.toLowerCase().includes(q);
      r.style.display = (okCat && okQ) ? '' : 'none';
    });
  }
  document.querySelectorAll('.tile').forEach(t => t.addEventListener('click', () => setCat(t.dataset.cat)));
</script>
</body></html>
"@

    if (-not $HtmlReportPath) {
        $HtmlReportPath = Join-Path (Get-Location) "ComplianceImpactReport_$(Get-Date -Format 'yyyyMMdd_HHmm').html"
    }
    Set-Content -Path $HtmlReportPath -Value $html -Encoding UTF8
    Write-Host "HTML report written to $HtmlReportPath" -ForegroundColor Cyan
}
#endregion

$devices
