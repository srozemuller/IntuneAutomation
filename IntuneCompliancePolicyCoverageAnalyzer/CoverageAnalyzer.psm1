#requires -Modules Microsoft.Graph.Authentication
<#
    CoverageAnalyzer.psm1

    Read-only decision-logic and Graph helper functions used by
    Test-IntuneCompliancePolicyCoverage.ps1.

    Design:
      - Every Graph call is GET, or a read-only POST (checkMemberGroups, the
        "devices without compliance policy" report). Nothing in this module
        ever creates, updates, or deletes an Intune/Entra object.
      - Every Graph call in this module uses /beta, by explicit tenant-owner
        decision (not a default recommendation - see README.md's "v1.0 vs
        beta" section for the tradeoff this overrides: Microsoft documents
        /beta as unsupported for production use, and every endpoint here
        was verified to exist and behave equivalently on v1.0 first). If
        this ever needs to move back to v1.0-by-default, every Uri string
        in this file uses a literal "/beta/" prefix, so swap those back
        (Get-IntuneComplianceAssignments, Get-IntuneAssignmentFilters, and
        Get-DevicesWithoutCompliancePolicy must stay on beta regardless -
        see their comment-based help for why those three have no v1.0
        equivalent).
      - Functions below the "Pure decision logic" region take fully
        resolved data as parameters and never call Graph, so Pester can
        exercise them directly without mocking anything.
#>

# ---------------------------------------------------------------------------
# Graph transport (GET/POST only, paging, throttling retry)
# ---------------------------------------------------------------------------

function Invoke-GraphRequest {
    <#
    .SYNOPSIS
        Thin wrapper around Invoke-MgGraphRequest with bounded retry for
        transient errors (429/503/504), honoring Retry-After when the SDK
        surfaces it. GET and POST only - this module never issues
        PATCH/PUT/DELETE.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Uri,

        [ValidateSet('GET', 'POST')]
        [string]$Method = 'GET',

        [object]$Body,

        [ValidateRange(1, 10)]
        [int]$MaxRetryCount = 5
    )

    if ($Uri -notmatch '^https?://') {
        $normalized = if ($Uri.StartsWith('/')) { $Uri } else { "/$Uri" }
        $Uri = "https://graph.microsoft.com$normalized"
    }

    $attempt = 0
    while ($true) {
        $attempt++
        try {
            $params = @{ Method = $Method; Uri = $Uri; OutputType = 'PSObject' }
            if ($PSBoundParameters.ContainsKey('Body')) {
                $params.Body = $Body
                $params.ContentType = 'application/json'
            }
            return Invoke-MgGraphRequest @params
        }
        catch {
            $statusCode = $null

            if ($_.Exception.PSObject.Properties.Name -contains 'ResponseStatusCode' -and $_.Exception.ResponseStatusCode) {
                $statusCode = [int]$_.Exception.ResponseStatusCode
            }
            elseif ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }
            elseif ($_.Exception.Message -match '\b(429|503|504)\b') {
                $statusCode = [int]$Matches[1]
            }

            $isTransient = $statusCode -in 429, 503, 504

            if (-not $isTransient -or $attempt -ge $MaxRetryCount) {
                throw
            }

            $retryAfterSeconds = $null
            try {
                if ($_.Exception.Response -and $_.Exception.Response.Headers -and $_.Exception.Response.Headers.RetryAfter) {
                    $retryAfterSeconds = $_.Exception.Response.Headers.RetryAfter.Delta.TotalSeconds
                }
            }
            catch {
                # Best-effort only: not every SDK version surfaces response headers on the
                # exception. Falling through to the exponential backoff below is expected.
                Write-Debug "Could not read Retry-After header: $($_.Exception.Message)"
            }

            if (-not $retryAfterSeconds -or $retryAfterSeconds -le 0) {
                $retryAfterSeconds = [Math]::Min(30, [Math]::Pow(2, $attempt))
            }

            Write-Verbose "Graph request returned HTTP $statusCode on attempt $attempt/$MaxRetryCount for $Uri. Retrying in $retryAfterSeconds second(s)."
            Start-Sleep -Seconds $retryAfterSeconds
        }
    }
}

function Invoke-GraphPagedRequest {
    <#
    .SYNOPSIS
        Follows @odata.nextLink until exhausted and returns the concatenated
        .value collection.
    .DESCRIPTION
        Thin pagination wrapper over Invoke-GraphRequest for any v1.0/beta
        Graph collection endpoint that returns @odata.nextLink.
    .PARAMETER Uri
        The initial Graph request URI (relative or absolute).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Uri
    )

    $results = [System.Collections.Generic.List[object]]::new()
    $next = $Uri
    $page = 0
    while ($next) {
        $page++
        $response = Invoke-GraphRequest -Method GET -Uri $next
        if ($response.value) {
            $results.AddRange(@($response.value))
        }
        Write-Verbose "Page $page for '$Uri': $($results.Count) item(s) so far."
        $next = $response.'@odata.nextLink'
    }
    return $results
}

# ---------------------------------------------------------------------------
# Device / policy / filter retrieval (all /beta - see module header)
# ---------------------------------------------------------------------------

function Get-IntuneManagedDeviceContext {
    <#
    .SYNOPSIS
        Resolves a managed device by id or by name. Name resolution refuses
        to silently pick a device when the name is ambiguous.
    .OUTPUTS
        PSCustomObject with Status = Resolved | NotFound | Ambiguous.
    #>
    [CmdletBinding(DefaultParameterSetName = 'ById')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'ById')]
        [string]$ManagedDeviceId,

        [Parameter(Mandatory, ParameterSetName = 'ByName')]
        [string]$DeviceName
    )

    $select = 'id,deviceName,operatingSystem,osVersion,azureADDeviceId,userId,userPrincipalName,' +
              'managedDeviceOwnerType,manufacturer,model,deviceEnrollmentType,enrollmentProfileName,' +
              'deviceCategoryDisplayName,managementAgent,lastSyncDateTime,complianceState'

    if ($PSCmdlet.ParameterSetName -eq 'ById') {
        try {
            $device = Invoke-GraphRequest -Method GET -Uri "/beta/deviceManagement/managedDevices/$ManagedDeviceId`?`$select=$select"
        }
        catch {
            return [PSCustomObject]@{
                Status = 'NotFound'
                Reason = "Managed device '$ManagedDeviceId' could not be retrieved: $($_.Exception.Message)"
            }
        }
    }
    else {
        $escapedName = $DeviceName.Replace("'", "''")
        $devices = Invoke-GraphPagedRequest -Uri "/beta/deviceManagement/managedDevices?`$filter=deviceName eq '$escapedName'&`$select=$select"

        if ($devices.Count -eq 0) {
            return [PSCustomObject]@{
                Status = 'NotFound'
                Reason = "No managed device named '$DeviceName' was found."
            }
        }
        if ($devices.Count -gt 1) {
            return [PSCustomObject]@{
                Status     = 'Ambiguous'
                Reason     = "$($devices.Count) managed devices are named '$DeviceName'. Re-run with -ManagedDeviceId using one of the candidate ids below."
                Candidates = @($devices | ForEach-Object {
                        [PSCustomObject]@{
                            Id                = $_.id
                            UserPrincipalName = $_.userPrincipalName
                            OperatingSystem   = $_.operatingSystem
                            LastSyncDateTime  = $_.lastSyncDateTime
                        }
                    })
            }
        }
        $device = $devices[0]
    }

    $ownerType = switch ($device.managedDeviceOwnerType) {
        'company' { 'Corporate' }
        'personal' { 'Personal' }
        default { 'Unknown' }
    }

    # Intune uses the all-zero GUID as a placeholder for "no user" on
    # managedDevice.userId, rather than leaving it null/empty - a non-empty
    # placeholder string is truthy in PowerShell, so this has to be checked
    # explicitly or a userless (shared/kiosk) device gets misread as having
    # a real associated user, and every downstream user-side group check
    # then fails against a user id that doesn't exist.
    $hasRealUser = $device.userId -and $device.userId -ne '00000000-0000-0000-0000-000000000000'

    [PSCustomObject]@{
        Status                     = 'Resolved'
        IntuneManagedDeviceId      = $device.id
        DeviceName                 = $device.deviceName
        OperatingSystem            = $device.operatingSystem
        OsVersion                  = $device.osVersion
        AzureADDeviceId            = $device.azureADDeviceId
        UserId                     = if ($hasRealUser) { $device.userId } else { $null }
        UserPrincipalName          = if ($hasRealUser) { $device.userPrincipalName } else { $null }
        UserContext                = if ($hasRealUser) { 'User' } else { 'None' }
        ManagedDeviceOwnerType     = $device.managedDeviceOwnerType
        DeviceOwnershipFilterValue = $ownerType
        Manufacturer               = $device.manufacturer
        Model                      = $device.model
        DeviceEnrollmentType       = $device.deviceEnrollmentType
        EnrollmentProfileName      = $device.enrollmentProfileName
        DeviceCategoryDisplayName  = $device.deviceCategoryDisplayName
        ManagementAgent            = $device.managementAgent
        LastSyncDateTime           = $device.lastSyncDateTime
        ComplianceState            = $device.complianceState
        Platform                   = if ($device.operatingSystem -eq 'Windows') { 'Windows' } else { 'Unsupported' }
    }
}

function Get-EntraDeviceContext {
    <#
    .SYNOPSIS
        Resolves the Entra directory object id for a device, anchored on the
        Intune managedDevice: given its azureADDeviceId (the Entra device's
        deviceId, NOT its directory object id - checkMemberGroups needs the
        directory object id, so this resolution step is mandatory and kept
        separate from the Intune managed device id on purpose) and its
        primary userId, so the managedDevice stays the source of truth even
        when Entra itself is ambiguous.
    .DESCRIPTION
        Multiple Entra device objects sharing one deviceId is a real,
        fairly common data-hygiene issue (stale objects left behind by
        re-imaging/re-enrollment, especially for hybrid Azure AD join). When
        that happens, this function tries one further, still-evidence-based
        disambiguation before giving up: it checks which of the candidates
        is in the managed device's primary user's registeredDevices - the
        directory's own record of which device object that user actually
        registered. If exactly one candidate matches, that one is used, and
        the mismatch is still reported (never silently swallowed) so the
        caller can warn about the stale duplicates. If it doesn't narrow to
        exactly one - no primary user, the cross-check itself fails, or more
        than one candidate matches - this still returns Ambiguous with the
        full candidate list, exactly as before.

        Note: GET /users/{id}/registeredDevices is delegated-only per
        Microsoft Graph documentation (Application permissions are not
        supported for it). Under an app-only/managed-identity -AccessToken
        session this cross-check will fail and is caught gracefully, falling
        back to Ambiguous - it never blocks or breaks the rest of the run.
    #>
    [CmdletBinding()]
    param(
        [string]$AzureADDeviceId,
        [string]$PrimaryUserId
    )

    if ([string]::IsNullOrWhiteSpace($AzureADDeviceId)) {
        return [PSCustomObject]@{
            Status = 'NotAvailable'
            Reason = 'Managed device has no azureADDeviceId (not Entra-registered, or not yet synced).'
        }
    }

    $escaped = $AzureADDeviceId.Replace("'", "''")
    $select = 'id,deviceId,displayName,accountEnabled,trustType,registrationDateTime,approximateLastSignInDateTime,operatingSystem,operatingSystemVersion'
    $results = Invoke-GraphPagedRequest -Uri "/beta/devices?`$filter=deviceId eq '$escaped'&`$select=$select"

    if ($results.Count -eq 0) {
        return [PSCustomObject]@{
            Status = 'NotFound'
            Reason = "No Entra device object found with deviceId '$AzureADDeviceId'."
        }
    }

    if ($results.Count -gt 1) {
        $candidates = @($results | ForEach-Object {
                [PSCustomObject]@{
                    EntraDeviceObjectId            = $_.id
                    DisplayName                    = $_.displayName
                    AccountEnabled                  = $_.accountEnabled
                    TrustType                       = $_.trustType
                    RegistrationDateTime            = $_.registrationDateTime
                    ApproximateLastSignInDateTime   = $_.approximateLastSignInDateTime
                }
            })

        $hasUsablePrimaryUser = $PrimaryUserId -and $PrimaryUserId -ne '00000000-0000-0000-0000-000000000000'
        if ($hasUsablePrimaryUser) {
            try {
                $registered = Invoke-GraphPagedRequest -Uri "/beta/users/$PrimaryUserId/registeredDevices?`$select=id,deviceId"
                $registeredIds = @($registered | Where-Object { $_.deviceId -eq $AzureADDeviceId } | ForEach-Object { $_.id })
                $matched = @($candidates | Where-Object { $registeredIds -contains $_.EntraDeviceObjectId })

                if ($matched.Count -eq 1) {
                    $staleIds = @($candidates | Where-Object { $_.EntraDeviceObjectId -ne $matched[0].EntraDeviceObjectId } | ForEach-Object { $_.EntraDeviceObjectId })
                    return [PSCustomObject]@{
                        Status              = 'Resolved'
                        EntraDeviceObjectId = $matched[0].EntraDeviceObjectId
                        EntraDeviceId       = $AzureADDeviceId
                        DisplayName         = $matched[0].DisplayName
                        ResolvedVia         = 'RegisteredDevicesCrossCheck'
                        Reason              = "$($results.Count) Entra device objects share deviceId '$AzureADDeviceId'; resolved to $($matched[0].EntraDeviceObjectId) via the primary user's registeredDevices. Other candidates (likely stale, not used): $($staleIds -join ', ')."
                        Candidates          = $candidates
                    }
                }
                Write-Verbose "registeredDevices cross-check for user '$PrimaryUserId' matched $($matched.Count) of $($candidates.Count) candidates for deviceId '$AzureADDeviceId' - not narrowed to exactly one, staying Ambiguous."
            }
            catch {
                Write-Verbose "registeredDevices cross-check failed for user '$PrimaryUserId' (falling back to Ambiguous): $($_.Exception.Message)"
            }
        }

        return [PSCustomObject]@{
            Status     = 'Ambiguous'
            Reason     = "$($results.Count) Entra device objects share deviceId '$AzureADDeviceId'. Device group membership cannot be reliably evaluated. Candidates: $(($candidates | ForEach-Object { "$($_.EntraDeviceObjectId) (enabled=$($_.AccountEnabled), lastSignIn=$($_.ApproximateLastSignInDateTime))" }) -join '; ')"
            Candidates = $candidates
        }
    }

    [PSCustomObject]@{
        Status              = 'Resolved'
        EntraDeviceObjectId = $results[0].id
        EntraDeviceId       = $results[0].deviceId
        DisplayName         = $results[0].displayName
    }
}

function Start-IntuneReportExportJob {
    <#
    .SYNOPSIS
        BETA (private helper). Starts an async Intune report export job.
        Export jobs are transient report artifacts, not Intune objects, so
        creating one does not violate the "read-only" requirement.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ReportName
    )

    $body = @{
        reportName       = $ReportName
        localizationType = 'LocalizedValuesAsAdditionalColumn'
        format           = 'json'
    } | ConvertTo-Json

    Invoke-GraphRequest -Method POST -Uri '/beta/deviceManagement/reports/exportJobs' -Body $body
}

function Wait-IntuneReportExportJob {
    <#
    .SYNOPSIS
        BETA (private helper). Polls an export job until it completes,
        fails, or a bounded timeout elapses - never an unbounded loop.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$JobId,

        [int]$PollIntervalSeconds = 3,
        [int]$MaxWaitSeconds = 180
    )

    $elapsed = 0
    $lastStatus = $null
    while ($true) {
        $job = Invoke-GraphRequest -Method GET -Uri "/beta/deviceManagement/reports/exportJobs('$JobId')"
        Write-Verbose "Export job '$JobId' status: $($job.status)"
        if ($job.status -ne $lastStatus) {
            Write-Host "  Report status: $($job.status) (elapsed ${elapsed}s)" -ForegroundColor DarkCyan
            $lastStatus = $job.status
        }
        else {
            Write-Host "  Report status: $($job.status), still waiting (elapsed ${elapsed}s)" -ForegroundColor DarkGray
        }

        if ($job.status -eq 'completed') { return $job }
        if ($job.status -eq 'failed') { throw "Intune report export job '$JobId' failed." }
        if ($elapsed -ge $MaxWaitSeconds) { throw "Timed out waiting for Intune report export job '$JobId' to complete after $MaxWaitSeconds second(s)." }

        Start-Sleep -Seconds $PollIntervalSeconds
        $elapsed += $PollIntervalSeconds
    }
}

function ConvertFrom-IntuneReportPayload {
    <#
    .SYNOPSIS
        Normalizes a parsed Intune report export payload into a flat array
        of row objects, regardless of which shape Graph used for this
        report - validated rather than assumed, since more than one shape
        has been observed in practice for these report exports:
          - a bare array of already-flat row objects
          - a {"Schema": [{"Column": ...}], "Values": [[...], ...]} matrix
          - a {"columns": [...], "values": [{...}, ...]} envelope, where
            "columns" is just metadata and "values" is already an array of
            flat row objects (this is the shape a real
            DevicesWithoutCompliancePolicyV3 export was observed to use -
            note "values" is NOT column-ordered arrays here, unlike the
            Schema/Values matrix case above)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Payload
    )

    if ($Payload -is [array]) {
        return @($Payload)
    }

    $propertyNames = @($Payload.PSObject.Properties.Name)

    if ($propertyNames -contains 'Schema' -and $propertyNames -contains 'Values') {
        $columns = @($Payload.Schema | ForEach-Object { $_.Column })
        return @($Payload.Values | ForEach-Object {
                $row = $_
                $entry = [ordered]@{}
                for ($i = 0; $i -lt $columns.Count; $i++) { $entry[$columns[$i]] = $row[$i] }
                [PSCustomObject]$entry
            })
    }

    if ($propertyNames -contains 'columns' -and $propertyNames -contains 'values') {
        $firstValue = $Payload.values | Select-Object -First 1
        if ($firstValue -is [array]) {
            # values is column-ordered arrays after all - zip against columns.
            $columns = @($Payload.columns)
            return @($Payload.values | ForEach-Object {
                    $row = $_
                    $entry = [ordered]@{}
                    for ($i = 0; $i -lt $columns.Count; $i++) { $entry[$columns[$i]] = $row[$i] }
                    [PSCustomObject]$entry
                })
        }
        return @($Payload.values)
    }

    throw 'Unrecognized Intune report export payload shape (expected an array, a Schema/Values matrix, or a columns/values envelope).'
}

function Receive-IntuneReportExportJob {
    <#
    .SYNOPSIS
        Downloads and unpacks a completed export job's result. The download
        url is a pre-signed Azure Storage blob url, not a Graph endpoint, so
        this uses a plain web request rather than Invoke-MgGraphRequest.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Job
    )

    if (-not $Job.url) { throw 'Export job completed but returned no download url.' }

    $workDir = Join-Path ([System.IO.Path]::GetTempPath()) "IntuneCoverageReport-$([Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $workDir -Force | Out-Null
    $zipPath = Join-Path $workDir 'export.zip'

    try {
        Write-Host '  Downloading report archive...' -ForegroundColor DarkCyan
        Invoke-WebRequest -Uri $Job.url -OutFile $zipPath -UseBasicParsing
        Write-Host '  Unpacking report archive...' -ForegroundColor DarkCyan
        Expand-Archive -Path $zipPath -DestinationPath $workDir -Force

        $dataFile = Get-ChildItem -Path $workDir -File | Where-Object { $_.Extension -in '.json', '.csv' } | Select-Object -First 1
        if (-not $dataFile) { throw 'Downloaded export archive did not contain a .json or .csv file.' }

        if ($dataFile.Extension -eq '.json') {
            $parsed = Get-Content -Path $dataFile.FullName -Raw | ConvertFrom-Json
            return ConvertFrom-IntuneReportPayload -Payload $parsed
        }
        else {
            return @(Import-Csv -Path $dataFile.FullName)
        }
    }
    finally {
        Remove-Item -Path $workDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Get-DevicesWithoutCompliancePolicy {
    <#
    .SYNOPSIS
        BETA. Retrieves the Intune "devices without a compliance policy"
        report (report definition DevicesWithoutCompliancePolicyV3) via the
        reports/exportJobs pattern. This is a raw report row list, NOT
        managedDevice objects - callers must correlate rows back to
        managedDevice separately rather than assuming any row id equals a
        managedDevice id.

    .DESCRIPTION
        The inline v1.0 action getDevicesWithoutCompliancePolicyReport does
        not carry the current V3 report definition; exportJobs is the
        supported path for it, which is why this one function needs beta.
        Flow: POST reports/exportJobs to start an async export -> poll GET
        until status=completed (bounded) -> download the returned SAS blob
        url (not a Graph call) -> unzip -> parse, validating the response
        shape rather than assuming report row ids line up with managedDevice
        ids.
    #>
    [CmdletBinding()]
    param(
        [int]$PollIntervalSeconds = 3,
        [int]$MaxWaitSeconds = 180
    )

    Write-Host 'Requesting Intune report export: DevicesWithoutCompliancePolicyV3...' -ForegroundColor Cyan
    $job = Start-IntuneReportExportJob -ReportName 'DevicesWithoutCompliancePolicyV3'
    Write-Host "  Report job scheduled: $($job.id)" -ForegroundColor DarkCyan
    $completedJob = Wait-IntuneReportExportJob -JobId $job.id -PollIntervalSeconds $PollIntervalSeconds -MaxWaitSeconds $MaxWaitSeconds
    $rows = Receive-IntuneReportExportJob -Job $completedJob
    Write-Host "Report ready: $($rows.Count) row(s)." -ForegroundColor Green
    return $rows
}

function Get-CompliancePolicyPlatform {
    <#
    .SYNOPSIS
        Maps a deviceCompliancePolicy @odata.type to a platform name.
        Central point for adding platforms beyond Windows later.
    #>
    [CmdletBinding()]
    param(
        [string]$ODataType
    )

    $map = @{
        '#microsoft.graph.windows10CompliancePolicy' = 'Windows'
        '#microsoft.graph.windows81CompliancePolicy' = 'Windows'
    }

    if ($map.ContainsKey($ODataType)) { return $map[$ODataType] }
    return 'Unsupported'
}

function Get-ReportRowPlatform {
    <#
    .SYNOPSIS
        Reads the coarse platform straight off a "devices without compliance
        policy" report row (its OS/OSDescription/OS_loc columns), so bulk
        mode can triage non-Windows rows without spending a Graph call on
        each one first. Pure function - callers still resolve the real
        managedDevice.operatingSystem before making any final decision.
    #>
    [CmdletBinding()]
    param($ReportRow)

    $raw = $ReportRow.OSDescription
    if (-not $raw) { $raw = $ReportRow.OS }
    if (-not $raw) { $raw = $ReportRow.OS_loc }
    if (-not $raw) { return 'Unknown' }

    switch -Regex ($raw) {
        'windows' { return 'Windows' }
        'ios|ipados' { return 'iOS/iPadOS' }
        'mac ?os' { return 'macOS' }
        'android' { return 'Android' }
        default { return $raw }
    }
}

function Get-IntuneCompliancePolicies {
    <#
    .SYNOPSIS
        Lists device compliance policies (has a v1.0 equivalent, but this
        module uses /beta throughout by explicit tenant-owner decision -
        see the module header) filtered to the requested platform.
        Assignments are NOT included here - see Get-IntuneComplianceAssignments,
        which needs beta for a different reason (no v1.0 equivalent at all
        for assignment filter metadata, unlike this call).
    #>
    [CmdletBinding()]
    param(
        [string]$Platform = 'Windows'
    )

    Write-Verbose 'Retrieving Intune device compliance policies (beta)'
    $raw = Invoke-GraphPagedRequest -Uri "/beta/deviceManagement/deviceCompliancePolicies?`$select=id,displayName"

    $policies = foreach ($p in $raw) {
        [PSCustomObject]@{
            Id          = $p.id
            DisplayName = $p.displayName
            ODataType   = $p.'@odata.type'
            Platform    = Get-CompliancePolicyPlatform -ODataType $p.'@odata.type'
        }
    }

    $filtered = @($policies | Where-Object { $_.Platform -eq $Platform })
    Write-Verbose "Retrieved $($policies.Count) compliance policies total; $($filtered.Count) match platform '$Platform'."
    return $filtered
}

function Get-IntuneComplianceAssignments {
    <#
    .SYNOPSIS
        BETA. Retrieves compliance policy assignments including assignment
        filter id/mode.

    .DESCRIPTION
        Unlike every other endpoint in this module, this one has NO v1.0
        equivalent at all for what it needs: the v1.0 documentation for
        groupAssignmentTarget (and its base type
        deviceAndAppManagementAssignmentTarget) does not list
        deviceAndAppManagementAssignmentFilterId / ...FilterType - those
        properties are documented only on the beta resource. So while the
        rest of this module's beta usage is a deliberate tenant-owner
        choice (a v1.0 call exists and was verified first), this one is
        beta because there is no alternative.

        One expand call for all policies, rather than one call per policy,
        to keep Graph call volume flat regardless of tenant size.
    #>
    [CmdletBinding()]
    param()

    Write-Verbose 'Retrieving compliance policy assignments (beta - required for assignment filter id/mode)'
    $raw = Invoke-GraphPagedRequest -Uri "/beta/deviceManagement/deviceCompliancePolicies?`$select=id,assignments&`$expand=assignments"

    $map = @{}
    foreach ($p in $raw) {
        $map[$p.id] = @($p.assignments)
    }
    return $map
}

function Get-IntuneAssignmentFilters {
    <#
    .SYNOPSIS
        BETA. deviceManagement/assignmentFilters has no v1.0 surface, so
        this is the isolated function that requires beta for filter
        definitions (name + rule text).
    #>
    [CmdletBinding()]
    param()

    Write-Verbose 'Retrieving Intune assignment filters (beta)'
    $raw = Invoke-GraphPagedRequest -Uri "/beta/deviceManagement/assignmentFilters?`$select=id,displayName,rule,platform"

    $map = @{}
    foreach ($f in $raw) {
        $map[$f.id] = [PSCustomObject]@{
            Id          = $f.id
            DisplayName = $f.displayName
            Rule        = $f.rule
            Platform    = $f.platform
        }
    }
    return $map
}

function Get-GroupDisplayNames {
    <#
    .SYNOPSIS
        Resolves display names for a set of group ids, so evidence text can
        show a readable "DisplayName (id)" instead of a bare GUID.
        Resolution is purely cosmetic - it never blocks or affects the
        underlying membership evaluation. A group that can't be resolved
        (deleted, no access, chunk failure) is simply absent from the
        returned map; callers fall back to showing the raw id for it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$GroupIds
    )

    $map = @{}
    $uniqueIds = @($GroupIds | Where-Object { $_ } | Select-Object -Unique)
    if ($uniqueIds.Count -eq 0) { return $map }

    Write-Verbose "Resolving display names for $($uniqueIds.Count) unique assignment group(s)."

    # Keep $filter=id in (...) chunks conservative (well under checkMemberGroups'
    # documented 20-id limit) since this is a URL-length-bound OData filter,
    # not a POST body with its own documented cap.
    for ($i = 0; $i -lt $uniqueIds.Count; $i += 15) {
        $end = [Math]::Min($i + 14, $uniqueIds.Count - 1)
        $chunk = @($uniqueIds[$i..$end])
        $filterIds = ($chunk | ForEach-Object { "'$($_.Replace("'", "''"))'" }) -join ','
        try {
            $results = Invoke-GraphPagedRequest -Uri "/beta/groups?`$filter=id in ($filterIds)&`$select=id,displayName"
            foreach ($g in $results) { $map[$g.id] = $g.displayName }
        }
        catch {
            Write-Verbose "Could not resolve display names for a group id chunk starting at index $i (falling back to raw ids for these): $($_.Exception.Message)"
        }
    }

    return $map
}

function Get-DirectoryObjectGroupMembership {
    <#
    .SYNOPSIS
        Evaluates transitive membership of one directory object (device or
        user) against a set of group ids using checkMemberGroups, chunked
        to the API's 20-group-per-request limit.

    .DESCRIPTION
        Microsoft Graph documents checkMemberGroups as evaluating its whole
        groupIds list as a single request: if any one id in that list is
        invalid (e.g. deleted or malformed), the ENTIRE request fails - even
        for the other, perfectly valid ids batched alongside it. To avoid
        that poisoning every group in a chunk into a false Unknown, a failed
        chunk is retried one id at a time so only the id(s) that are
        genuinely unresolvable end up Unknown; everything else in that
        chunk still gets a confident answer. This only adds extra requests
        on the (expected to be rare) failure path - the normal, all-valid
        case is still one request per 20 ids.
    .OUTPUTS
        PSCustomObject with:
          Matched    - HashSet[string] of group ids confirmed as a match.
          Unresolved - HashSet[string] of group ids that could not be
                       checked at all. Callers must treat these, and only
                       these, as Unknown - any id in neither set was
                       successfully checked and confirmed NOT a match.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ObjectId,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$GroupIds,

        [Parameter(Mandatory)]
        [ValidateSet('Device', 'User')]
        [string]$ObjectType
    )

    $uniqueIds = @($GroupIds | Select-Object -Unique)
    $matched = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $unresolved = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    if ($uniqueIds.Count -eq 0) {
        return [PSCustomObject]@{ Matched = $matched; Unresolved = $unresolved }
    }

    $uri = if ($ObjectType -eq 'Device') { "/beta/devices/$ObjectId/checkMemberGroups" } else { "/beta/users/$ObjectId/checkMemberGroups" }

    for ($i = 0; $i -lt $uniqueIds.Count; $i += 20) {
        $end = [Math]::Min($i + 19, $uniqueIds.Count - 1)
        $chunk = @($uniqueIds[$i..$end])
        try {
            $body = @{ groupIds = $chunk } | ConvertTo-Json
            $response = Invoke-GraphRequest -Method POST -Uri $uri -Body $body
            foreach ($id in @($response.value)) { [void]$matched.Add($id) }
        }
        catch {
            Write-Verbose "checkMemberGroups failed for $ObjectType '$ObjectId' (chunk starting at index $i, $($chunk.Count) id(s)): $($_.Exception.Message). Retrying individually to isolate which id(s) are the actual problem."
            foreach ($singleId in $chunk) {
                try {
                    $body = @{ groupIds = @($singleId) } | ConvertTo-Json
                    $response = Invoke-GraphRequest -Method POST -Uri $uri -Body $body
                    foreach ($id in @($response.value)) { [void]$matched.Add($id) }
                }
                catch {
                    Write-Verbose "checkMemberGroups failed for $ObjectType '$ObjectId' on group '$singleId' individually: $($_.Exception.Message)"
                    [void]$unresolved.Add($singleId)
                }
            }
        }
    }

    return [PSCustomObject]@{ Matched = $matched; Unresolved = $unresolved }
}

# ---------------------------------------------------------------------------
# Pure decision logic - no Graph calls below this line. Safe to unit test.
# ---------------------------------------------------------------------------

$script:FilterOperatorAliases = @{
    'eq'          = 'Equals'
    'ne'          = 'NotEquals'
    'contains'    = 'Contains'
    'notcontains' = 'NotContains'
    'startswith'  = 'StartsWith'
    'in'          = 'In'
    'notin'       = 'NotIn'
}
$script:FilterLogicalOperators = @('and', 'or')

$script:FilterPropertyMap = @{
    'device.deviceownership'       = 'DeviceOwnership'
    'device.manufacturer'          = 'Manufacturer'
    'device.model'                 = 'Model'
    'device.osversion'             = 'OsVersion'
    'device.enrollmentprofilename' = 'EnrollmentProfileName'
    'device.devicename'            = 'DeviceName'
    'device.devicecategory'        = 'DeviceCategory'
}

function ConvertTo-FilterTokens {
    <#
    .SYNOPSIS
        Tokenizes an Intune assignment filter rule. Throws if any
        non-whitespace character could not be classified, so callers can
        surface Unknown instead of silently mis-parsing.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Rule
    )

    $pattern = '"(?:[^"\\]|\\.)*"|\[|\]|\(|\)|,|\$?null|-?[A-Za-z_][\w\.]*|\d+(?:\.\d+)*'
    $found = [regex]::Matches($Rule, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

    # Walk the gaps *between* matched tokens (not the inside of a quoted
    # token, which may legitimately contain spaces, e.g. "Dell Inc.") and
    # confirm each gap is whitespace-only. Anything else means a character
    # the tokenizer could not classify.
    $cursor = 0
    foreach ($m in $found) {
        $gap = $Rule.Substring($cursor, $m.Index - $cursor)
        if ($gap -match '\S') {
            throw "Filter rule contains characters that could not be tokenized near position ${cursor}: '$Rule'"
        }
        $cursor = $m.Index + $m.Length
    }
    if ($Rule.Substring($cursor) -match '\S') {
        throw "Filter rule contains characters that could not be tokenized near position ${cursor}: '$Rule'"
    }

    return @($found | ForEach-Object { $_.Value })
}

function ConvertFrom-FilterLiteral {
    param([string]$Token)
    if ($Token -match '^\$?[Nn][Uu][Ll][Ll]$') { return $null }
    if ($Token -match '^"(.*)"$') { return ($Matches[1] -replace '\\"', '"') }
    return $Token
}

function Read-FilterComparison {
    param([string[]]$Tokens, [ref]$Position)

    if ($Position.Value -ge $Tokens.Count) { throw 'Unexpected end of filter rule while reading a comparison.' }
    $property = $Tokens[$Position.Value]; $Position.Value++
    if ($property -notmatch '^[A-Za-z_]\w*\.[A-Za-z_]\w*$') {
        throw "Expected a property token (e.g. device.manufacturer), found '$property'."
    }

    if ($Position.Value -ge $Tokens.Count) { throw "Expected an operator after '$property'." }
    $opToken = $Tokens[$Position.Value]; $Position.Value++
    $opKey = $opToken.TrimStart('-').ToLowerInvariant()
    if (-not $script:FilterOperatorAliases.ContainsKey($opKey)) {
        throw "Unsupported operator '$opToken'."
    }
    $operator = $script:FilterOperatorAliases[$opKey]

    $value = $null
    if ($Position.Value -lt $Tokens.Count -and $Tokens[$Position.Value] -eq '[') {
        $Position.Value++
        $items = [System.Collections.Generic.List[string]]::new()
        while ($Position.Value -lt $Tokens.Count -and $Tokens[$Position.Value] -ne ']') {
            $t = $Tokens[$Position.Value]; $Position.Value++
            if ($t -eq ',') { continue }
            $items.Add((ConvertFrom-FilterLiteral $t))
        }
        if ($Position.Value -ge $Tokens.Count -or $Tokens[$Position.Value] -ne ']') { throw "Expected closing ']'." }
        $Position.Value++
        $value = $items.ToArray()
    }
    else {
        if ($Position.Value -ge $Tokens.Count) { throw "Expected a value after operator '$opToken'." }
        $raw = $Tokens[$Position.Value]; $Position.Value++
        $value = ConvertFrom-FilterLiteral $raw
    }

    if ($operator -in @('In', 'NotIn') -and -not ($value -is [array])) {
        throw "Operator '$operator' requires an array value, e.g. [`"a`",`"b`"]."
    }

    return [PSCustomObject]@{ Type = 'Comparison'; Property = $property.ToLowerInvariant(); Operator = $operator; Value = $value }
}

function Read-FilterPrimary {
    param([string[]]$Tokens, [ref]$Position)

    if ($Position.Value -ge $Tokens.Count) { throw 'Unexpected end of filter rule.' }
    if ($Tokens[$Position.Value] -eq '(') {
        $Position.Value++
        $node = Read-FilterExpression -Tokens $Tokens -Position $Position
        if ($Position.Value -ge $Tokens.Count -or $Tokens[$Position.Value] -ne ')') { throw "Expected closing ')'." }
        $Position.Value++
        return $node
    }
    return Read-FilterComparison -Tokens $Tokens -Position $Position
}

function Read-FilterExpression {
    param([string[]]$Tokens, [ref]$Position)

    $left = Read-FilterPrimary -Tokens $Tokens -Position $Position
    while ($Position.Value -lt $Tokens.Count) {
        $tok = $Tokens[$Position.Value]
        $key = $tok.TrimStart('-').ToLowerInvariant()
        if ($script:FilterLogicalOperators -contains $key) {
            $Position.Value++
            $right = Read-FilterPrimary -Tokens $Tokens -Position $Position
            $left = [PSCustomObject]@{ Type = 'Logical'; Operator = $key; Left = $left; Right = $right }
        }
        else {
            break
        }
    }
    return $left
}

function ConvertTo-IntuneFilterAst {
    <#
    .SYNOPSIS
        Parses an Intune assignment filter rule string into a small AST of
        Comparison/Logical nodes. Throws on anything outside the supported
        grammar (grammar verified against Microsoft Learn's assignment
        filter reference, not guessed).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Rule
    )

    $tokens = ConvertTo-FilterTokens -Rule $Rule
    if ($tokens.Count -eq 0) { throw 'Filter rule is empty.' }

    $position = [ref]0
    $tree = Read-FilterExpression -Tokens $tokens -Position $position
    if ($position.Value -ne $tokens.Count) {
        throw "Unexpected trailing content in filter rule after token $($position.Value) of $($tokens.Count)."
    }
    return $tree
}

function Test-FilterComparisonNode {
    param($Node, [hashtable]$DeviceProperties)

    if (-not $script:FilterPropertyMap.ContainsKey($Node.Property)) {
        return [PSCustomObject]@{
            Value  = $null
            Reason = "Property '$($Node.Property)' is not supported in this version of the analyzer."
        }
    }

    $mappedKey = $script:FilterPropertyMap[$Node.Property]
    if (-not $DeviceProperties.ContainsKey($mappedKey)) {
        return [PSCustomObject]@{
            Value  = $null
            Reason = "Device property '$mappedKey' is not available for this device."
        }
    }

    $deviceValue = $DeviceProperties[$mappedKey]
    $deviceValueLower = if ($null -ne $deviceValue) { $deviceValue.ToString().ToLowerInvariant() } else { $null }

    switch ($Node.Operator) {
        'Equals' {
            $result = if ($null -eq $Node.Value) { [string]::IsNullOrEmpty($deviceValue) }
            else { [bool]($deviceValueLower -and $deviceValueLower -eq $Node.Value.ToString().ToLowerInvariant()) }
        }
        'NotEquals' {
            $result = if ($null -eq $Node.Value) { -not [string]::IsNullOrEmpty($deviceValue) }
            else { -not [bool]($deviceValueLower -and $deviceValueLower -eq $Node.Value.ToString().ToLowerInvariant()) }
        }
        'Contains' {
            $result = [bool]($deviceValueLower -and $deviceValueLower.Contains($Node.Value.ToString().ToLowerInvariant()))
        }
        'NotContains' {
            $result = -not [bool]($deviceValueLower -and $deviceValueLower.Contains($Node.Value.ToString().ToLowerInvariant()))
        }
        'StartsWith' {
            $result = [bool]($deviceValueLower -and $deviceValueLower.StartsWith($Node.Value.ToString().ToLowerInvariant()))
        }
        'In' {
            $result = [bool]($deviceValueLower -and ($Node.Value | Where-Object { $_.ToString().ToLowerInvariant() -eq $deviceValueLower }))
        }
        'NotIn' {
            $result = -not [bool]($deviceValueLower -and ($Node.Value | Where-Object { $_.ToString().ToLowerInvariant() -eq $deviceValueLower }))
        }
        default { throw "Unhandled operator '$($Node.Operator)'." }
    }

    $displayValue = if ($Node.Value -is [array]) { '[' + ($Node.Value -join ', ') + ']' } else { $Node.Value }
    $reason = "$($Node.Property) $($Node.Operator) '$displayValue': device value is '$deviceValue' -> $(if ($result) { 'Matched' } else { 'NotMatched' })"
    return [PSCustomObject]@{ Value = $result; Reason = $reason }
}

function Test-FilterNode {
    param($Node, [hashtable]$DeviceProperties, [System.Collections.Generic.List[string]]$Reasons)

    if ($Node.Type -eq 'Comparison') {
        $evaluated = Test-FilterComparisonNode -Node $Node -DeviceProperties $DeviceProperties
        $Reasons.Add($evaluated.Reason)
        return $evaluated.Value
    }

    $leftValue = Test-FilterNode -Node $Node.Left -DeviceProperties $DeviceProperties -Reasons $Reasons
    $rightValue = Test-FilterNode -Node $Node.Right -DeviceProperties $DeviceProperties -Reasons $Reasons

    if ($Node.Operator -eq 'and') {
        if ($leftValue -eq $false -or $rightValue -eq $false) { return $false }
        if ($null -eq $leftValue -or $null -eq $rightValue) { return $null }
        return $true
    }
    else {
        if ($leftValue -eq $true -or $rightValue -eq $true) { return $true }
        if ($null -eq $leftValue -or $null -eq $rightValue) { return $null }
        return $false
    }
}

function Test-IntuneAssignmentFilter {
    <#
    .SYNOPSIS
        Evaluates an Intune assignment filter rule against a device's
        properties. Never fabricates a match/no-match for syntax or
        properties it cannot prove - returns Unknown instead.
    .OUTPUTS
        PSCustomObject: Result (Matched|NotMatched|Unknown), Reason, Evidence[]
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Rule,

        [Parameter(Mandatory)]
        [hashtable]$DeviceProperties
    )

    if ([string]::IsNullOrWhiteSpace($Rule)) {
        return [PSCustomObject]@{ Result = 'Matched'; Reason = 'Filter rule is empty.'; Evidence = @() }
    }

    try {
        $ast = ConvertTo-IntuneFilterAst -Rule $Rule
        $reasons = [System.Collections.Generic.List[string]]::new()
        $value = Test-FilterNode -Node $ast -DeviceProperties $DeviceProperties -Reasons $reasons
        $result = if ($null -eq $value) { 'Unknown' } elseif ($value) { 'Matched' } else { 'NotMatched' }
        return [PSCustomObject]@{ Result = $result; Reason = ($reasons | Select-Object -Last 1); Evidence = $reasons.ToArray() }
    }
    catch {
        return [PSCustomObject]@{
            Result   = 'Unknown'
            Reason   = "Filter rule contains unsupported syntax, property, or operator: $($_.Exception.Message)"
            Evidence = @("Rule: $Rule")
        }
    }
}

function Get-FilterPropertiesFromDeviceContext {
    <#
    .SYNOPSIS
        Projects a DeviceContext (from Get-IntuneManagedDeviceContext) into
        the flat property bag Test-IntuneAssignmentFilter expects.
    #>
    [CmdletBinding()]
    param($DeviceContext)

    @{
        DeviceOwnership       = $DeviceContext.DeviceOwnershipFilterValue
        Manufacturer          = $DeviceContext.Manufacturer
        Model                 = $DeviceContext.Model
        OsVersion              = $DeviceContext.OsVersion
        EnrollmentProfileName = $DeviceContext.EnrollmentProfileName
        DeviceName             = $DeviceContext.DeviceName
        DeviceCategory         = $DeviceContext.DeviceCategoryDisplayName
    }
}

function ConvertTo-NormalizedAssignment {
    <#
    .SYNOPSIS
        Normalizes one raw deviceCompliancePolicyAssignment (from beta,
        expanded) into the flat shape Test-CompliancePolicyAssignment
        consumes, resolving its filter id against the assignment filter map.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $RawAssignment,

        [Parameter(Mandatory)]
        [hashtable]$AssignmentFilters
    )

    $target = $RawAssignment.target
    $targetType = $target.'@odata.type'
    $isExclusion = $targetType -eq '#microsoft.graph.exclusionGroupAssignmentTarget'

    $filterId = $target.deviceAndAppManagementAssignmentFilterId
    if ([string]::IsNullOrEmpty($filterId) -or $filterId -eq '00000000-0000-0000-0000-000000000000') { $filterId = $null }

    $filterModeRaw = $target.deviceAndAppManagementAssignmentFilterType
    $filterMode = if ([string]::IsNullOrEmpty($filterModeRaw)) { 'none' } else { $filterModeRaw.ToLowerInvariant() }

    $filterInfo = if ($filterId -and $AssignmentFilters.ContainsKey($filterId)) { $AssignmentFilters[$filterId] } else { $null }

    [PSCustomObject]@{
        AssignmentId  = $RawAssignment.id
        TargetType    = $targetType
        TargetGroupId = $target.groupId
        IsExclusion   = $isExclusion
        FilterId      = $filterId
        FilterMode    = $filterMode
        FilterName    = if ($filterInfo) { $filterInfo.DisplayName } elseif ($filterId) { $filterId } else { $null }
        FilterRule    = if ($filterInfo) { $filterInfo.Rule } else { $null }
    }
}

function Test-CompliancePolicyAssignment {
    <#
    .SYNOPSIS
        Evaluates a single normalized assignment against a device/user
        context and pre-resolved group memberships. Pure function - all
        Graph-derived facts are passed in.
    .OUTPUTS
        PSCustomObject describing target match, filter evaluation, and the
        assignment-level Result (Matched|NotTargeted|NotMatched|FilteredOut|Unknown).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Assignment,
        [Parameter(Mandatory)] $DeviceContext,
        $DeviceGroupMemberships,
        $UserGroupMemberships,
        [Parameter(Mandatory)] [hashtable]$FilterProperties,
        [hashtable]$GroupDisplayNames
    )

    $evidence = [System.Collections.Generic.List[string]]::new()
    $targetMatch = 'NoMatch'
    $matchedVia = 'None'
    $groupLabel = $Assignment.TargetGroupId
    if ($Assignment.TargetGroupId -and $GroupDisplayNames -and $GroupDisplayNames.ContainsKey($Assignment.TargetGroupId) -and $GroupDisplayNames[$Assignment.TargetGroupId]) {
        $groupLabel = "$($GroupDisplayNames[$Assignment.TargetGroupId]) ($($Assignment.TargetGroupId))"
    }

    switch ($Assignment.TargetType) {
        '#microsoft.graph.allDevicesAssignmentTarget' {
            $targetMatch = 'Match'; $matchedVia = 'AllDevices'
            $evidence.Add('Target: All Devices - always matches.')
        }
        '#microsoft.graph.allLicensedUsersAssignmentTarget' {
            if ($DeviceContext.UserContext -eq 'None') {
                $targetMatch = 'NoMatch'; $matchedVia = 'None'
                $evidence.Add('Target: All Users - device has no associated user, so a user-targeted assignment cannot match.')
            }
            else {
                $targetMatch = 'Match'; $matchedVia = 'User'
                $evidence.Add("Target: All Users - device has associated user $($DeviceContext.UserPrincipalName).")
            }
        }
        { $_ -in '#microsoft.graph.groupAssignmentTarget', '#microsoft.graph.exclusionGroupAssignmentTarget' } {
            $groupId = $Assignment.TargetGroupId
            $deviceMatch =
                if ($null -eq $DeviceGroupMemberships) { $null }
                elseif ($DeviceGroupMemberships.Unresolved.Contains($groupId)) { $null }
                else { $DeviceGroupMemberships.Matched.Contains($groupId) }
            $userMatch =
                if ($DeviceContext.UserContext -eq 'None') { $false }
                elseif ($null -eq $UserGroupMemberships) { $null }
                elseif ($UserGroupMemberships.Unresolved.Contains($groupId)) { $null }
                else { $UserGroupMemberships.Matched.Contains($groupId) }

            if ($deviceMatch -eq $true) {
                $targetMatch = 'Match'; $matchedVia = 'Device'
                $evidence.Add("Group $groupLabel - device is a member.")
            }
            elseif ($userMatch -eq $true) {
                $targetMatch = 'Match'; $matchedVia = 'User'
                $evidence.Add("Group $groupLabel - associated user is a member.")
            }
            elseif ($null -eq $deviceMatch -or $null -eq $userMatch) {
                $targetMatch = 'Unknown'; $matchedVia = 'Unknown'
                if ($null -eq $deviceMatch) { $evidence.Add("Group $groupLabel - device group membership could not be verified.") }
                if ($null -eq $userMatch) { $evidence.Add("Group $groupLabel - user group membership could not be verified.") }
            }
            else {
                $targetMatch = 'NoMatch'; $matchedVia = 'None'
                $evidence.Add("Group $groupLabel - neither device nor associated user is a member.")
                if ($DeviceContext.UserContext -eq 'None') { $evidence.Add('Device has no associated user; only device membership was evaluated.') }
            }
        }
        default {
            $targetMatch = 'Unknown'; $matchedVia = 'Unknown'
            $evidence.Add("Unsupported assignment target type: $($Assignment.TargetType)")
        }
    }

    $filterEvaluation = 'NotApplicable'
    if ($targetMatch -eq 'Match' -and $Assignment.FilterId -and $Assignment.FilterMode -ne 'none') {
        if (-not $Assignment.FilterRule) {
            $filterEvaluation = 'Unknown'
            $evidence.Add("Filter '$($Assignment.FilterName)' ($($Assignment.FilterId)) is referenced but its rule text could not be retrieved.")
        }
        else {
            $filterTest = Test-IntuneAssignmentFilter -Rule $Assignment.FilterRule -DeviceProperties $FilterProperties
            $filterEvaluation = $filterTest.Result
            $evidence.Add("Filter '$($Assignment.FilterName)' ($($Assignment.FilterMode)): $($filterTest.Reason)")
        }
    }

    if ($targetMatch -eq 'Unknown') {
        $result = 'Unknown'
    }
    elseif ($targetMatch -eq 'NoMatch') {
        $result = if ($Assignment.IsExclusion) { 'NotMatched' } else { 'NotTargeted' }
    }
    elseif ($filterEvaluation -eq 'Unknown') {
        $result = 'Unknown'
    }
    else {
        $blockedByFilter =
            ($Assignment.FilterMode -eq 'include' -and $filterEvaluation -eq 'NotMatched') -or
            ($Assignment.FilterMode -eq 'exclude' -and $filterEvaluation -eq 'Matched')

        if ($blockedByFilter) {
            $result = if ($Assignment.IsExclusion) { 'NotMatched' } else { 'FilteredOut' }
        }
        else {
            $result = 'Matched'
        }
    }

    return [PSCustomObject]@{
        AssignmentId     = $Assignment.AssignmentId
        IsExclusion      = $Assignment.IsExclusion
        TargetType       = $Assignment.TargetType
        TargetGroupId    = $Assignment.TargetGroupId
        GroupDisplayName = if ($GroupDisplayNames -and $Assignment.TargetGroupId) { $GroupDisplayNames[$Assignment.TargetGroupId] } else { $null }
        TargetMatch      = $targetMatch
        MatchedVia       = $matchedVia
        FilterId         = $Assignment.FilterId
        FilterName       = $Assignment.FilterName
        FilterMode       = $Assignment.FilterMode
        FilterRule       = $Assignment.FilterRule
        FilterEvaluation = $filterEvaluation
        Result           = $result
        Reason           = ($evidence -join ' ')
        Evidence         = $evidence.ToArray()
    }
}

function Test-CompliancePolicyCoverage {
    <#
    .SYNOPSIS
        Rolls up per-assignment evaluations for one policy into a single
        policy-level result. Pure function.
    .OUTPUTS
        PSCustomObject matching the documented result schema, including
        Result in {ShouldApply, ShouldApplyButMissing, NotTargeted,
        Excluded, FilteredOut, Unknown}.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Policy,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$AssignmentEvaluations,
        [Parameter(Mandatory)] $DeviceContext,
        [switch]$FromWithoutCompliancePolicyReport
    )

    $includeEvals = @($AssignmentEvaluations | Where-Object { -not $_.IsExclusion })
    $exclusionEvals = @($AssignmentEvaluations | Where-Object { $_.IsExclusion })

    $matchedIncludes = @($includeEvals | Where-Object { $_.Result -eq 'Matched' })
    $unknownIncludes = @($includeEvals | Where-Object { $_.Result -eq 'Unknown' })
    $filteredIncludes = @($includeEvals | Where-Object { $_.Result -eq 'FilteredOut' })

    $matchedExclusions = @($exclusionEvals | Where-Object { $_.Result -eq 'Matched' })
    $unknownExclusions = @($exclusionEvals | Where-Object { $_.Result -eq 'Unknown' })

    if ($matchedIncludes.Count -gt 0) {
        if ($matchedExclusions.Count -gt 0) {
            $result = 'Excluded'
            $excludedGroupLabels = $matchedExclusions | ForEach-Object { if ($_.GroupDisplayName) { "$($_.GroupDisplayName) ($($_.TargetGroupId))" } else { $_.TargetGroupId } }
            $reason = "Device matched an assignment but is excluded via group(s): $($excludedGroupLabels -join ', ')."
        }
        elseif ($unknownExclusions.Count -gt 0) {
            $result = 'Unknown'
            $reason = 'Device matches an include assignment, but exclusion group membership could not be fully verified, so exclusion cannot be ruled out.'
        }
        else {
            $result = if ($FromWithoutCompliancePolicyReport) { 'ShouldApplyButMissing' } else { 'ShouldApply' }
            $reason = 'Device matches a valid assignment. No exclusion applies. Any assignment filter permits the device.'
            if ($result -eq 'ShouldApplyButMissing') {
                $reason += ' Intune currently reports this device as having no compliance policy assigned, despite the assignment architecture appearing correct - continue troubleshooting device check-in, enrollment/identity state, or recent assignment changes rather than groups or filters.'
            }
        }
    }
    elseif ($unknownIncludes.Count -gt 0) {
        $result = 'Unknown'
        $reason = 'At least one assignment could not be fully evaluated (unresolved group membership, an unsupported target type, or an unsupported filter), and no other assignment definitively matched.'
    }
    elseif ($includeEvals.Count -eq 0) {
        $result = 'NotTargeted'
        $reason = 'This policy has no include assignments for this platform.'
    }
    elseif ($filteredIncludes.Count -gt 0) {
        $result = 'FilteredOut'
        $reason = 'Device is targeted by an assignment but does not satisfy the assignment filter.'
    }
    else {
        $result = 'NotTargeted'
        $reason = 'Neither the device nor its associated user is a member of any assigned group, and no All Devices/All Users assignment applies.'
    }

    [PSCustomObject]@{
        DeviceName          = $DeviceContext.DeviceName
        ManagedDeviceId     = $DeviceContext.IntuneManagedDeviceId
        EntraDeviceId       = $DeviceContext.AzureADDeviceId
        UserPrincipalName   = $DeviceContext.UserPrincipalName
        UserContext         = $DeviceContext.UserContext
        Manufacturer        = $DeviceContext.Manufacturer
        Model               = $DeviceContext.Model
        OsVersion           = $DeviceContext.OsVersion
        Ownership           = $DeviceContext.DeviceOwnershipFilterValue
        ComplianceState     = $DeviceContext.ComplianceState
        ManagementAgent     = $DeviceContext.ManagementAgent
        EnrollmentProfileName = $DeviceContext.EnrollmentProfileName
        LastSyncDateTime    = $DeviceContext.LastSyncDateTime
        PolicyId            = $Policy.Id
        PolicyName          = $Policy.DisplayName
        Platform            = $Policy.Platform
        Result              = $result
        Reason              = $reason
        MatchedAssignments  = @($includeEvals | Where-Object { $_.Result -eq 'Matched' })
        FailedAssignments   = @($includeEvals | Where-Object { $_.Result -in 'NotTargeted', 'FilteredOut', 'Unknown' })
        Exclusions          = $exclusionEvals
        Evidence            = @($AssignmentEvaluations | ForEach-Object { $_.Reason } | Where-Object { $_ })
    }
}

# ---------------------------------------------------------------------------
# Per-device orchestration (calls Graph for group membership only - policies,
# assignments, and filters are resolved once per run by the caller and
# passed in, per the "cache tenant-wide data once" requirement).
# ---------------------------------------------------------------------------

function Get-CompliancePolicyCoverageForDevice {
    <#
    .SYNOPSIS
        Evaluates every given Windows compliance policy against one device,
        collecting unique assignment groups once and checking membership in
        (at most) two batched checkMemberGroups calls per 20 groups.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $DeviceContext,
        [Parameter(Mandatory)] $EntraDeviceContext,
        [Parameter(Mandatory)] [object[]]$Policies,
        [Parameter(Mandatory)] [hashtable]$AssignmentsByPolicyId,
        [Parameter(Mandatory)] [hashtable]$AssignmentFilters,
        [hashtable]$GroupDisplayNames = @{},
        [switch]$FromWithoutCompliancePolicyReport
    )

    $normalizedByPolicy = @{}
    $allGroupIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($policy in $Policies) {
        $rawAssignments = @($AssignmentsByPolicyId[$policy.Id])
        $normalized = @($rawAssignments | Where-Object { $_ } | ForEach-Object { ConvertTo-NormalizedAssignment -RawAssignment $_ -AssignmentFilters $AssignmentFilters })
        $normalizedByPolicy[$policy.Id] = $normalized
        foreach ($a in $normalized) {
            if ($a.TargetGroupId) { [void]$allGroupIds.Add($a.TargetGroupId) }
        }
    }

    Write-Verbose "Found $($allGroupIds.Count) unique assignment group(s) across $($Policies.Count) Windows compliance policies."

    $deviceGroupMemberships = $null
    if ($allGroupIds.Count -gt 0) {
        if ($EntraDeviceContext.Status -eq 'Resolved') {
            Write-Verbose "Checking device membership in $($allGroupIds.Count) group(s)."
            $deviceGroupMemberships = Get-DirectoryObjectGroupMembership -ObjectId $EntraDeviceContext.EntraDeviceObjectId -GroupIds @($allGroupIds) -ObjectType Device
        }
        else {
            Write-Verbose "Skipping device group membership check: Entra device object could not be resolved ($($EntraDeviceContext.Reason))"
        }
    }

    $userGroupMemberships = $null
    if ($allGroupIds.Count -gt 0 -and $DeviceContext.UserContext -eq 'User') {
        Write-Verbose "Checking user membership in $($allGroupIds.Count) group(s)."
        $userGroupMemberships = Get-DirectoryObjectGroupMembership -ObjectId $DeviceContext.UserId -GroupIds @($allGroupIds) -ObjectType User
    }

    $filterProperties = Get-FilterPropertiesFromDeviceContext -DeviceContext $DeviceContext

    $results = foreach ($policy in $Policies) {
        Write-Verbose "Evaluating policy '$($policy.DisplayName)'"
        $assignmentEvals = @($normalizedByPolicy[$policy.Id] | ForEach-Object {
                Test-CompliancePolicyAssignment -Assignment $_ -DeviceContext $DeviceContext `
                    -DeviceGroupMemberships $deviceGroupMemberships -UserGroupMemberships $userGroupMemberships `
                    -FilterProperties $filterProperties -GroupDisplayNames $GroupDisplayNames
            })
        $policyResult = Test-CompliancePolicyCoverage -Policy $policy -AssignmentEvaluations $assignmentEvals -DeviceContext $DeviceContext -FromWithoutCompliancePolicyReport:$FromWithoutCompliancePolicyReport

        # Annotate the one diagnosable Unknown cause we can actually name
        # with evidence (a still-ambiguous Entra device object) so the
        # badge/headline can say why instead of a generic "Unknown" -
        # Result itself stays Unknown; this is presentation-layer detail,
        # not a new confident answer.
        $unknownCategory = if ($policyResult.Result -eq 'Unknown' -and $EntraDeviceContext.Status -eq 'Ambiguous') { 'AmbiguousEntraDevice' } else { $null }
        $policyResult | Add-Member -NotePropertyName UnknownCategory -NotePropertyValue $unknownCategory -Force
        $policyResult
    }

    return @($results)
}

# ---------------------------------------------------------------------------
# Presentation layer
# ---------------------------------------------------------------------------

function Format-ComplianceCoverageResult {
    <#
    .SYNOPSIS
        Renders one device's policy evaluations as RSOP-style console text.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $DeviceContext,
        [Parameter(Mandatory)] [object[]]$PolicyResults
    )

    $resultColor = @{
        ShouldApply           = 'Green'
        ShouldApplyButMissing = 'Red'
        Excluded              = 'Yellow'
        FilteredOut           = 'Yellow'
        NotTargeted           = 'DarkGray'
        Unknown               = 'Magenta'
    }

    Write-Host ''
    Write-Host "Device: $($DeviceContext.DeviceName)" -ForegroundColor Cyan
    Write-Host "Platform: $($DeviceContext.Platform)"
    Write-Host "Primary user: $(if ($DeviceContext.UserContext -eq 'User') { $DeviceContext.UserPrincipalName } else { '(none - UserContext = None)' })"
    Write-Host "Hardware: $($DeviceContext.Manufacturer) $($DeviceContext.Model), OS $($DeviceContext.OsVersion), Ownership: $($DeviceContext.DeviceOwnershipFilterValue), Compliance: $($DeviceContext.ComplianceState), Management agent: $($DeviceContext.ManagementAgent)"
    Write-Host "Last check-in: $($DeviceContext.LastSyncDateTime)"
    Write-Host "Checked $($PolicyResults.Count) Windows compliance policies"

    $hasCoverageGap = @($PolicyResults | Where-Object { $_.Result -ne 'ShouldApply' }).Count -gt 0
    if ($DeviceContext.UserContext -eq 'None' -and $hasCoverageGap) {
        Write-Host ''
        Write-Host 'ADVICE: this device has no primary user (userless/shared/kiosk pattern) and does not have a compliance policy applying.' -ForegroundColor Cyan
        Write-Host '  A user-group-based assignment can never match a device with no associated user, no matter how the group is configured.'
        Write-Host '  If this is intentionally a shared device, assign compliance policies via a group containing the DEVICE itself (or "All Devices"),'
        Write-Host '  not a user group - and if it is not meant to be userless, check the device''s Entra/Intune primary-user assignment instead.'
    }

    foreach ($p in $PolicyResults) {
        Write-Host ''
        Write-Host ('-' * 62) -ForegroundColor DarkGray
        Write-Host ''
        Write-Host "Policy: $($p.PolicyName)" -ForegroundColor White

        foreach ($a in $p.MatchedAssignments) {
            Write-Host "  Assignment: matched via $($a.MatchedVia)" -ForegroundColor Green
            if ($a.Reason) { Write-Host "    $($a.Reason)" -ForegroundColor DarkGray }
        }
        foreach ($a in $p.FailedAssignments) {
            Write-Host "  Assignment: $($a.Result) ($($a.TargetType))" -ForegroundColor DarkYellow
            if ($a.Reason) { Write-Host "    $($a.Reason)" -ForegroundColor DarkGray }
        }
        foreach ($e in $p.Exclusions) {
            $tag = if ($e.Result -eq 'Matched') { 'MATCH' } else { $e.Result }
            Write-Host "  Exclusion: $tag via $($e.MatchedVia)" -ForegroundColor DarkYellow
            if ($e.Reason) { Write-Host "    $($e.Reason)" -ForegroundColor DarkGray }
        }

        $resultLabel = if ($p.UnknownCategory -eq 'AmbiguousEntraDevice') { 'Unknown - Ambiguous Entra Device Object' } else { $p.Result }

        Write-Host ''
        Write-Host "RESULT: $resultLabel" -ForegroundColor $resultColor[$p.Result]
        Write-Host ''
        Write-Host 'WHY:'
        Write-Host "  $($p.Reason)"
        if ($p.UnknownCategory -eq 'AmbiguousEntraDevice') {
            Write-Host '  This device has multiple Entra device objects sharing one deviceId, so group membership could not be checked at all - see the Ambiguous device warning above for the candidate objects.' -ForegroundColor DarkGray
        }
    }
    Write-Host ''
    Write-Host ('-' * 62) -ForegroundColor DarkGray
}

function Get-DeviceCoverageRollup {
    <#
    .SYNOPSIS
        Collapses one device's per-policy results into a single "most
        explanatory" bucket for the bulk-mode summary table. Pure function.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $DeviceContext,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$PolicyResults
    )

    $precedence = @('ShouldApplyButMissing', 'Unknown', 'Excluded', 'FilteredOut', 'NotTargeted', 'ShouldApply')
    $best = $precedence | Where-Object { $r = $_; $PolicyResults | Where-Object { $_.Result -eq $r } } | Select-Object -First 1
    if (-not $best) { $best = 'Unknown' }

    # Same enrichment as the per-policy badges: if every Unknown policy on
    # this device traces back to the same diagnosable cause (an unresolved
    # ambiguous Entra device object), the device-level summary badge should
    # say so too, not just the per-policy ones.
    $unknownCategory = $null
    if ($best -eq 'Unknown') {
        $unknownResults = @($PolicyResults | Where-Object { $_.Result -eq 'Unknown' })
        if ($unknownResults.Count -gt 0 -and -not ($unknownResults | Where-Object { $_.UnknownCategory -ne 'AmbiguousEntraDevice' })) {
            $unknownCategory = 'AmbiguousEntraDevice'
        }
    }

    [PSCustomObject]@{
        DeviceName      = $DeviceContext.DeviceName
        ManagedDeviceId = $DeviceContext.IntuneManagedDeviceId
        Result          = $best
        UnknownCategory = $unknownCategory
    }
}

function Format-ComplianceCoverageSummary {
    <#
    .SYNOPSIS
        Prints the bulk-mode per-device summary (one row per device, using
        each device's most notable policy result).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]]$DeviceRollupResults
    )

    Write-Host ''
    Write-Host "Devices without compliance policy: $($DeviceRollupResults.Count)" -ForegroundColor Cyan
    Write-Host ''
    $DeviceRollupResults |
        ForEach-Object { if ($_.UnknownCategory -eq 'AmbiguousEntraDevice') { 'Unknown - Ambiguous Entra Device' } else { $_.Result } } |
        Group-Object | Sort-Object Count -Descending | ForEach-Object {
            Write-Host ("{0,4}  {1}" -f $_.Count, $_.Name)
        }
}

function Export-ComplianceCoverageHtml {
    <#
    .SYNOPSIS
        Renders results as a single self-contained HTML report: a summary
        stat grid, an optional non-Windows platform breakdown, and one
        collapsible section per device listing each policy's result and
        supporting evidence. Uses the same CSS design tokens as this repo's
        other HTML reports (see GetManagedDeviceDiskSpace) for consistency.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [object[]]$Results = @(),

        [AllowEmptyCollection()]
        [object[]]$DeviceRollups = @(),

        [hashtable]$UnsupportedPlatformCounts,

        [string]$Title = 'Intune Compliance Policy Coverage Report'
    )

    function ConvertTo-HtmlSafe {
        param([string]$Text)
        if ($null -eq $Text) { return '' }
        [System.Net.WebUtility]::HtmlEncode($Text)
    }

    $badgeClass = @{
        ShouldApply                      = 'badge-healthy'
        ShouldApplyButMissing            = 'badge-critical'
        Excluded                         = 'badge-warning'
        FilteredOut                      = 'badge-warning'
        NotTargeted                      = 'badge-muted'
        Unknown                          = 'badge-uncertain'
        'Unknown - Ambiguous Entra Device' = 'badge-uncertain'
    }
    $textClass = @{
        ShouldApply                      = 'healthy'
        ShouldApplyButMissing            = 'critical'
        Excluded                         = 'warning'
        FilteredOut                      = 'warning'
        NotTargeted                      = 'muted'
        Unknown                          = 'uncertain'
        'Unknown - Ambiguous Entra Device' = 'uncertain'
    }

    $summaryCounts = [ordered]@{}
    foreach ($r in $Results) {
        $key = if ($r.UnknownCategory -eq 'AmbiguousEntraDevice') { 'Unknown - Ambiguous Entra Device' } else { $r.Result }
        if (-not $summaryCounts.Contains($key)) { $summaryCounts[$key] = 0 }
        $summaryCounts[$key]++
    }

    $statCardsHtml = ($summaryCounts.GetEnumerator() | Sort-Object -Property Value -Descending | ForEach-Object {
            $cls = $textClass[$_.Key]
            "<div class=`"stat-card`"><div class=`"stat-label`">$(ConvertTo-HtmlSafe $_.Key)</div><div class=`"stat-value $cls`">$($_.Value)</div></div>"
        }) -join "`n"

    $platformBreakdownHtml = ''
    if ($UnsupportedPlatformCounts -and $UnsupportedPlatformCounts.Count -gt 0) {
        $rows = ($UnsupportedPlatformCounts.GetEnumerator() | Sort-Object -Property Value -Descending | ForEach-Object {
                "<div class=`"stat-card`"><div class=`"stat-label`">$(ConvertTo-HtmlSafe $_.Key)</div><div class=`"stat-value muted`">$($_.Value)</div></div>"
            }) -join "`n"
        $platformBreakdownHtml = "<div class=`"card`"><div class=`"card-title`">Other platforms in this report (not evaluated - Windows only in this version)</div><div class=`"stats-grid`">$rows</div></div>"
    }

    $deviceBlocks = foreach ($group in ($Results | Group-Object -Property ManagedDeviceId)) {
        $first = $group.Group[0]
        $rollup = $DeviceRollups | Where-Object { $_.ManagedDeviceId -eq $first.ManagedDeviceId } | Select-Object -First 1
        $rollupBadgeHtml = if ($rollup) {
            $rollupLabel = if ($rollup.UnknownCategory -eq 'AmbiguousEntraDevice') { 'Unknown - Ambiguous Entra Device' } else { $rollup.Result }
            "<span class=`"badge $($badgeClass[$rollup.Result])`">$(ConvertTo-HtmlSafe $rollupLabel)</span>"
        }
        else { '' }

        $policyBlocks = foreach ($p in $group.Group) {
            $cls = $badgeClass[$p.Result]
            $resultLabel = if ($p.UnknownCategory -eq 'AmbiguousEntraDevice') { 'Unknown - Ambiguous Entra Device' } else { $p.Result }

            $matchedHtml = ($p.MatchedAssignments | ForEach-Object {
                    "<li class=`"assignment-line match`">Matched via $(ConvertTo-HtmlSafe $_.MatchedVia): $(ConvertTo-HtmlSafe $_.Reason)</li>"
                }) -join "`n"
            $failedHtml = ($p.FailedAssignments | ForEach-Object {
                    "<li class=`"assignment-line`">$(ConvertTo-HtmlSafe $_.Result): $(ConvertTo-HtmlSafe $_.Reason)</li>"
                }) -join "`n"
            $exclusionHtml = ($p.Exclusions | ForEach-Object {
                    $tag = if ($_.Result -eq 'Matched') { 'EXCLUDED VIA' } else { $_.Result }
                    "<li class=`"assignment-line`">$(ConvertTo-HtmlSafe $tag): $(ConvertTo-HtmlSafe $_.Reason)</li>"
                }) -join "`n"

            "<div class=`"policy-block`"><div class=`"policy-header`"><span class=`"policy-name`">$(ConvertTo-HtmlSafe $p.PolicyName)</span><span class=`"badge $cls`">$(ConvertTo-HtmlSafe $resultLabel)</span></div><div class=`"policy-reason`">$(ConvertTo-HtmlSafe $p.Reason)</div><ul class=`"assignment-list`">$matchedHtml$failedHtml$exclusionHtml</ul></div>"
        }

        $userLine = if ($first.UserPrincipalName) { ConvertTo-HtmlSafe $first.UserPrincipalName } else { '(no associated user)' }

        $hasCoverageGap = @($group.Group | Where-Object { $_.Result -ne 'ShouldApply' }).Count -gt 0
        $adviceHtml = ''
        if ($first.UserContext -eq 'None' -and $hasCoverageGap) {
            $adviceHtml = '<div class="advice"><strong>ADVICE:</strong> this device has no primary user (userless/shared/kiosk pattern) and does not have a compliance policy applying. A user-group-based assignment can never match a device with no associated user. If this is intentionally a shared device, assign compliance policies via a group containing the DEVICE itself (or "All Devices"), not a user group - and if it is not meant to be userless, check the device''s Entra/Intune primary-user assignment instead.</div>'
        }

        $deviceInfoFields = [ordered]@{
            Manufacturer      = $first.Manufacturer
            Model             = $first.Model
            'OS version'      = $first.OsVersion
            Ownership         = $first.Ownership
            'Compliance state' = $first.ComplianceState
            'Management agent' = $first.ManagementAgent
            'Enrollment profile' = $first.EnrollmentProfileName
            'Last check-in'   = $first.LastSyncDateTime
        }
        $deviceInfoHtml = ($deviceInfoFields.GetEnumerator() | Where-Object { $_.Value } | ForEach-Object {
                "<div class=`"info-item`"><span class=`"info-label`">$(ConvertTo-HtmlSafe $_.Key)</span><span class=`"info-value`">$(ConvertTo-HtmlSafe $_.Value)</span></div>"
            }) -join "`n"
        $deviceInfoBlock = if ($deviceInfoHtml) { "<div class=`"device-info`">$deviceInfoHtml</div>" } else { '' }

        "<details class=`"card device-card`"><summary><span class=`"device-name`">$(ConvertTo-HtmlSafe $first.DeviceName)</span><span class=`"device-id`">$(ConvertTo-HtmlSafe $first.ManagedDeviceId)</span><span class=`"device-user`">$userLine</span>$rollupBadgeHtml</summary><div class=`"device-body`">$deviceInfoBlock$adviceHtml$($policyBlocks -join "`n")</div></details>"
    }

    $generated = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

    @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>$(ConvertTo-HtmlSafe $Title)</title>
<style>
:root {
    --font-sans: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
    --background: #ffffff;
    --foreground: #191919;
    --card: #ffffff;
    --border: #e6e6e6;
    --primary: #0070f3;
    --secondary: #f5f5f5;
    --muted-foreground: #8b8b8b;
    --radius: 0.5rem;
    --critical: #ff4d4f;
    --warning: #faad14;
    --healthy: #52c41a;
    --muted: #aaaaaa;
    --uncertain: #9254de;
}
* { margin: 0; padding: 0; box-sizing: border-box; }
body { font-family: var(--font-sans); background-color: var(--background); color: var(--foreground); padding: 1.5rem; }
.container { max-width: 1100px; margin: 0 auto; }
h1 { font-size: 1.75rem; font-weight: 700; margin-bottom: 0.25rem; }
.header-description { color: var(--muted-foreground); font-size: 0.875rem; margin-bottom: 1.5rem; }
.card { background-color: var(--card); border-radius: var(--radius); border: 1px solid var(--border); padding: 1.5rem; margin-bottom: 1.25rem; box-shadow: 0 1px 3px rgba(0,0,0,0.08); }
.card-title { font-size: 1.1rem; font-weight: 600; margin-bottom: 0.75rem; }
.stats-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(150px, 1fr)); gap: 1rem; }
.stat-card { padding: 1rem; background-color: var(--secondary); border-radius: var(--radius); display: flex; flex-direction: column; }
.stat-label { font-size: 0.8rem; color: var(--muted-foreground); }
.stat-value { font-size: 1.4rem; font-weight: 700; margin-top: 0.4rem; }
.critical { color: var(--critical); }
.warning { color: var(--warning); }
.healthy { color: var(--healthy); }
.muted { color: var(--muted); }
.uncertain { color: var(--uncertain); }
.device-card summary { cursor: pointer; list-style: none; display: flex; align-items: center; gap: 0.75rem; flex-wrap: wrap; }
.device-card summary::-webkit-details-marker { display: none; }
.device-card summary::before { content: '>'; color: var(--muted-foreground); display: inline-block; transition: transform 0.15s; }
.device-card[open] summary::before { transform: rotate(90deg); }
.device-name { font-weight: 600; font-size: 1rem; }
.device-id { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 0.75rem; color: var(--muted-foreground); }
.device-user { font-size: 0.8rem; color: var(--muted-foreground); }
.device-body { margin-top: 1rem; display: flex; flex-direction: column; gap: 0.75rem; }
.policy-block { border: 1px solid var(--border); border-radius: var(--radius); padding: 0.85rem 1rem; }
.policy-header { display: flex; align-items: center; justify-content: space-between; gap: 0.5rem; }
.policy-name { font-weight: 600; }
.policy-reason { color: var(--muted-foreground); font-size: 0.85rem; margin-top: 0.35rem; }
.advice { background-color: rgba(0,112,243,0.08); border: 1px solid var(--primary); border-radius: var(--radius); padding: 0.75rem 1rem; font-size: 0.85rem; margin-bottom: 0.5rem; }
.device-info { display: grid; grid-template-columns: repeat(auto-fill, minmax(140px, 1fr)); gap: 0.5rem; background-color: var(--secondary); border-radius: var(--radius); padding: 0.75rem 1rem; margin-bottom: 0.5rem; }
.info-item { display: flex; flex-direction: column; }
.info-label { font-size: 0.7rem; color: var(--muted-foreground); text-transform: uppercase; letter-spacing: 0.02em; }
.info-value { font-size: 0.85rem; font-weight: 500; }
.assignment-list { list-style: none; margin-top: 0.5rem; display: flex; flex-direction: column; gap: 0.25rem; }
.assignment-line { font-size: 0.8rem; padding-left: 0.75rem; border-left: 2px solid var(--border); }
.assignment-line.match { border-left-color: var(--healthy); }
.badge { display: inline-block; font-size: 0.7rem; font-weight: 700; padding: 0.2rem 0.6rem; border-radius: 9999px; color: #fff; white-space: nowrap; }
.badge-healthy { background-color: var(--healthy); }
.badge-critical { background-color: var(--critical); }
.badge-warning { background-color: var(--warning); color: #4a3200; }
.badge-muted { background-color: var(--muted); }
.badge-uncertain { background-color: var(--uncertain); }
.timestamp { color: var(--muted-foreground); font-size: 0.8rem; margin-top: 2rem; }
</style>
</head>
<body>
<div class="container">
<h1>$(ConvertTo-HtmlSafe $Title)</h1>
<div class="header-description">Evidence-based compliance policy coverage analysis. Every result traces back to a matched/unmatched assignment, exclusion, or filter - never a guess.</div>
<div class="card"><div class="card-title">Summary</div><div class="stats-grid">$statCardsHtml</div></div>
$platformBreakdownHtml
$($deviceBlocks -join "`n")
<div class="timestamp">Generated $generated</div>
</div>
</body>
</html>
"@
}

Export-ModuleMember -Function @(
    'Invoke-GraphRequest',
    'Invoke-GraphPagedRequest',
    'Get-IntuneManagedDeviceContext',
    'Get-EntraDeviceContext',
    'Get-DevicesWithoutCompliancePolicy',
    'ConvertFrom-IntuneReportPayload',
    'Get-CompliancePolicyPlatform',
    'Get-ReportRowPlatform',
    'Get-IntuneCompliancePolicies',
    'Get-IntuneComplianceAssignments',
    'Get-IntuneAssignmentFilters',
    'Get-DirectoryObjectGroupMembership',
    'Get-GroupDisplayNames',
    'Test-IntuneAssignmentFilter',
    'ConvertTo-IntuneFilterAst',
    'Get-FilterPropertiesFromDeviceContext',
    'ConvertTo-NormalizedAssignment',
    'Test-CompliancePolicyAssignment',
    'Test-CompliancePolicyCoverage',
    'Get-CompliancePolicyCoverageForDevice',
    'Get-DeviceCoverageRollup',
    'Format-ComplianceCoverageResult',
    'Format-ComplianceCoverageSummary',
    'Export-ComplianceCoverageHtml'
)
