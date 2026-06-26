#Requires -Modules Microsoft.Graph.Authentication

<#
.SYNOPSIS
    Checks your Intune environment for automation that will break when Multi Admin Approval is enforced.

.DESCRIPTION
    This script:
    - Reads Intune Audit Logs for changes made by non-user actors (service principals)
    - Reads Entra Sign-In Logs for app-only sign-ins to Microsoft Graph
    - Outputs an HTML report so you know what to review and what to exclude from MAA

.NOTES
    Required permissions (delegated or application):
    - AuditLog.Read.All

    The script uses read-only Graph calls. It does not make any changes.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [int]$AuditLogDays = 30,

    [Parameter()]
    [string]$OutputPath = ".\MAA-Check-Report.html"
)

Write-Host "Connecting to Microsoft Graph..." -ForegroundColor Cyan
Connect-MgGraph -Scopes "AuditLog.Read.All" -NoWelcome

$graphVersion = 'beta'
$auditResults = [System.Collections.Generic.List[PSCustomObject]]::new()
$signInResults = [System.Collections.Generic.List[PSCustomObject]]::new()

$since = (Get-Date).AddDays(-$AuditLogDays).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

# ---------------------------------------------------------
# Step 1: Check Intune Audit Logs for non-user changes
# ---------------------------------------------------------
Write-Host "Reading Intune Audit Logs for the last $AuditLogDays days..." -ForegroundColor Cyan

$auditUri = "https://graph.microsoft.com/$graphVersion/deviceManagement/auditEvents?`$filter=activityDateTime ge $since&`$orderby=activityDateTime desc"

$allAuditEvents = @()
do {
    $response = Invoke-MgGraphRequest -Method GET -Uri $auditUri
    $allAuditEvents += $response.value
    $auditUri = $response.'@odata.nextLink'
} while ($auditUri)

Write-Host "Retrieved $($allAuditEvents.Count) audit events. Filtering for non-user actors..." -ForegroundColor Gray

foreach ($event in $allAuditEvents) {
    $actor = $event.actor
    # When a service principal makes the call, userPrincipalName is empty and applicationId is set
    if ($actor.applicationId -and (-not $actor.userPrincipalName -or $actor.userPrincipalName -eq "")) {
        $auditResults.Add([PSCustomObject]@{
            Date     = $event.activityDateTime
            Activity = $event.activityDisplayName
            Resource = $event.resources | Select-Object -First 1 -ExpandProperty displayName
            AppName  = $actor.applicationDisplayName
            AppId    = $actor.applicationId
            Result   = $event.activityResult
        })
    }
}

Write-Host "Found $($auditResults.Count) audit event(s) made by service principals." -ForegroundColor Yellow

# ---------------------------------------------------------
# Step 2: Check Entra Sign-In Logs for app-only sign-ins
# ---------------------------------------------------------
Write-Host "Reading Entra Sign-In Logs for app-only sign-ins (last $AuditLogDays days)..." -ForegroundColor Cyan

$signInUri = "https://graph.microsoft.com/$graphVersion/auditLogs/signIns?`$filter=(signInEventTypes/any(t: t eq 'servicePrincipal' OR t eq 'managedIdentity') and (createdDateTime ge $since))&`$select=id,createdDateTime,appDisplayName,appId,resourceDisplayName,status,signInEventTypes"
$allSignIns = @()
do {
    $response = Invoke-MgGraphRequest -Method GET -Uri $signInUri
    $allSignIns += $response.value
    $signInUri = $response.'@odata.nextLink'
} while ($signInUri)

# Filter on Intune or Graph resource access
$intuneSignIns = $allSignIns | Where-Object {
    $_.resourceDisplayName -like "*Intune*" -or
    $_.resourceDisplayName -like "*Microsoft Graph*"
}

# Group by app to avoid noise — one row per app, showing last sign-in
$grouped = $intuneSignIns | Group-Object -Property appId

foreach ($group in $grouped) {
    $latest = $group.Group | Sort-Object createdDateTime -Descending | Select-Object -First 1
    $signInResults.Add([PSCustomObject]@{
        AppName    = $latest.appDisplayName
        AppId      = $latest.appId
        Resource   = $latest.resourceDisplayName
        LastSignIn = $latest.createdDateTime
        SignIns    = $group.Count
    })
}

Write-Host "Found $($signInResults.Count) distinct app(s) with service principal sign-ins to Graph/Intune." -ForegroundColor Yellow

# ---------------------------------------------------------
# Step 3: Build HTML report
# ---------------------------------------------------------
Write-Host "Building HTML report..." -ForegroundColor Cyan

function ConvertTo-HtmlTable {
    param([object[]]$Data, [string]$Title, [string]$Description)

    if (-not $Data -or $Data.Count -eq 0) {
        return "<h2>$Title</h2><p class='empty'>$Description<br><em>Nothing found.</em></p>"
    }

    $headers = ($Data[0].PSObject.Properties.Name | ForEach-Object { "<th>$_</th>" }) -join ""
    $rows = $Data | ForEach-Object {
        $cells = ($_.PSObject.Properties.Value | ForEach-Object { "<td>$_</td>" }) -join ""
        "<tr>$cells</tr>"
    }

    return @"
<h2>$Title</h2>
<p>$Description</p>
<table>
  <thead><tr>$headers</tr></thead>
  <tbody>$($rows -join "`n")</tbody>
</table>
"@
}

$html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>Intune MAA Impact Check</title>
<style>
  body { font-family: Segoe UI, Arial, sans-serif; margin: 40px; background: #f4f6f9; color: #1a1a2e; }
  h1 { color: #0078d4; }
  h2 { color: #005a9e; border-bottom: 2px solid #0078d4; padding-bottom: 4px; margin-top: 40px; }
  p { max-width: 900px; }
  table { border-collapse: collapse; width: 100%; margin-top: 12px; background: #fff; border-radius: 6px; overflow: hidden; box-shadow: 0 1px 4px rgba(0,0,0,0.1); }
  th { background: #0078d4; color: white; padding: 10px 14px; text-align: left; font-size: 13px; }
  td { padding: 9px 14px; font-size: 13px; border-bottom: 1px solid #e8eaf0; }
  tr:last-child td { border-bottom: none; }
  tr:nth-child(even) td { background: #f8f9ff; }
  .empty { color: #666; font-style: italic; }
  .summary { background: #fff3cd; border: 1px solid #ffc107; border-radius: 6px; padding: 16px 20px; margin: 20px 0; max-width: 900px; }
  .footer { margin-top: 60px; font-size: 12px; color: #888; }
</style>
</head>
<body>
<h1>Intune Multi Admin Approval — Impact Check Report</h1>
<p>Generated: $(Get-Date -Format "yyyy-MM-dd HH:mm") | Audit period: last $AuditLogDays days</p>

<div class="summary">
  <strong>What to do with this report:</strong><br>
  Any app that shows up in <em>both</em> tables is actively authenticating to Graph and making changes to Intune through automation.
  Before enabling MAA for a workload, add those apps to the <strong>Exclusions</strong> tab of the relevant MAA access policy — or update the automation to handle the approval header flow.
</div>

$(ConvertTo-HtmlTable -Data $auditResults.ToArray() -Title "Intune Audit Log — Changes by service principals (last $AuditLogDays days)" -Description "These audit events were made by a service principal, not by a user. This is your clearest signal that automation is actively changing Intune resources.")

$(ConvertTo-HtmlTable -Data $signInResults.ToArray() -Title "Entra Sign-In Logs — App-only sign-ins to Graph/Intune (last $AuditLogDays days)" -Description "These apps authenticated to Microsoft Graph using an app-only token (no user). Cross-reference with the audit log above to confirm which ones are writing to Intune.")

<div class="footer">
  Script: rozemuller.com | Intune MAA documentation: https://learn.microsoft.com/en-us/intune/fundamentals/role-based-access-control/multi-admin-approval-graph-api
</div>
</body>
</html>
"@

$html | Out-File -FilePath $OutputPath -Encoding UTF8
Write-Host "Report saved to $OutputPath" -ForegroundColor Green
Write-Host ""
Write-Host "Summary:" -ForegroundColor Cyan
Write-Host "  Audit events by service principals         : $($auditResults.Count)" -ForegroundColor White
Write-Host "  App-only sign-ins to Graph/Intune          : $($signInResults.Count)" -ForegroundColor White
Write-Host ""
Write-Host "Open $OutputPath to review the report." -ForegroundColor Green