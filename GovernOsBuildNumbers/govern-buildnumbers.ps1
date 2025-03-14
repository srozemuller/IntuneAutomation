<#
.SYNOPSIS
Creates (or updates if exist) device health scripts in Intune.
.DESCRIPTION
This script searches in a provided folder for subfolders where the scripts are in. 
The script name is the name of the folder where the script set is in. In the script set folder there must be a detection_xx.ps1 and remediate_xx.ps1
.PARAMETER GraphToken
Enter the Graph Bearer token
.PARAMETER Platforms
This is an array of OS platforms, default @("Windows10","Windows11"). Handles platforms Windows, iOS, Android, macOS. The known Intune platforms.
.EXAMPLE
.\manage-devicehealthscripts.ps1 -GraphToken xxxx -ScriptsFolder .\AllDetectionScripts
#>
[CmdletBinding()]
    param
    (
        [parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [System.Security.SecureString]$GraphToken,

        [parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [ValidateSet("Windows10","Windows11","iOS","AndroidPersonal","AndroidDeviceOwner","macOS")]
        [array]$Platforms = @("Windows10","Windows11")
    )
$InformationPreference = "Continue" # Needed for showing info messages

function GetPlatformInfo($plaform){
    switch -WildCard ($platform){
        "windows10" { $compliancePolicyPlatform = "Windows10"; $restrictionPolicyPlatform = "Windows"; $filterRule = '(device.osVersion -startsWith "10.0.1")'; $filterPlatform = "Windows10AndLater"; $deviceFilter = "operatingSystem eq 'Windows' and startswith(osVersion, '10.1')"}
        "windows11" { $compliancePolicyPlatform = "Windows10"; $restrictionPolicyPlatform = "Windows"; $filterRule = '(device.osVersion -startsWith "10.0.2")'; $filterPlatform = "Windows10AndLater"; $deviceFilter = "operatingSystem eq 'Windows' and startswith(osVersion, '10.2')"}
        "macOS" { $compliancePolicyPlatform = "macOS"; $restrictionPolicyPlatform = "macOS"; $filterRule = '(device.deviceOwnership -eq "corporate")'; $filterPlatform = "macOS"; $deviceFilter = "operatingSystem eq 'macOS'" }
        "ios" { $compliancePolicyPlatform = "ios"; $restrictionPolicyPlatform = "iOS"; $filterRule = '(device.deviceOwnership -eq "corporate")'; $filterPlatform = "iOS"; $deviceFilter = "operatingSystem eq 'iOS'"}
        "androidDeviceOwner" { $compliancePolicyPlatform = "androidDeviceOwner"; $restrictionPolicyPlatform = "Android"; $filterRule = '(device.deviceOwnership -eq "corporate")'; $filterPlatform = "androidForWork"; $deviceFilter = "operatingSystem eq 'android'" }
        "androidWorkProfile" { $compliancePolicyPlatform = "androidWorkProfile"; $restrictionPolicyPlatform = "Android"; $filterRule = '(device.deviceOwnership -eq "corporate")'; $filterPlatform = "androidForWork"; $deviceFilter = "operatingSystem eq 'android'" }
    }
    $platformInfo = @{
        compliancePolicyPlatform = $compliancePolicyPlatform
        restrictionPolicyPlatform = $restrictionPolicyPlatform
        filterPlatform = $filterPlatform
        filterRule = $filterRule
        deviceFilter = $deviceFilter
    }
    return $platformInfo
}    

function GetCompliancePolicies($compliancePolicyPlatform){
    Write-Verbose "Searching for compliance policies with platform $($compliancePolicyPlatform)"
    $url = "https://graph.microsoft.com/beta/deviceManagement/deviceCompliancePolicies?`$filter=(isof('microsoft.graph.$compliancePolicyPlatform`CompliancePolicy'))&`$expand=assignments,scheduledActionsForRule(`$expand=scheduledActionConfigurations)"    
    $compliancePolicies = Invoke-MgGraphRequest -Method GET -URI $url -OutputType PSObject
    Write-Verbose "Found $($compliancePolicies.value.count) compliance policies for $($compliancePolicyPlatform)"
    return $compliancePolicies
}

function GetFilters($platformInfo){
    Write-Verbose "Searching for filter with platform $($platformInfo.filterPlatform)"
    $url = "https://graph.microsoft.com/beta/deviceManagement/assignmentFilters?`$filter=platform eq '{0}'" -f $platformInfo.filterPlatform
    $filters = Invoke-MgGraphRequest -Method GET -URI $url -OutputType PSObject
    Write-Verbose "Found $($filters.value.count) filters for $($platformInfo.filterPlatform)"
    return $($filters.value | Where-Object {$_.rule -eq $platformInfo.filterRule})
}

function GetRestrictionPolicies($restrictionPolicyPlatform){
    Write-Verbose "Searching for restriction policies with platform $($restrictionPolicyPlatform)"
    $url = "https://graph.microsoft.com/beta/deviceManagement/deviceEnrollmentConfigurations?`$filter=deviceEnrollmentConfigurationType eq 'singlePlatformRestriction'"
    $restrictionPolicies = Invoke-MgGraphRequest -Method GET -URI $url -OutputType PSObject
    $returnPolicies = New-Object System.Collections.ArrayList

    ## Adding the default my Microsoft created policy
    $returnPolicies.Add(($restrictionPolicies.value | Where-Object {(($null -eq $_.platformType) -and ($null -ne $_.windowsrestriction))} | Select-Object displayName, platformType,  @{Name="osMinimumVersion"; Expression={$_.windowsrestriction}},  @{Name="osMaximumVersion"; Expression={$_.platformRestriction.osMaximumVersion}})) >> $null
    
    ## Adding platform specific platform policy
    $returnPolicies.Add(($restrictionPolicies.value | Where-Object {(($_.platformType -eq $restrictionPolicyPlatform) -and ($null -ne $_.platformRestriction.osMinimumVersion))} | Select-Object displayName, platformType,  @{Name="osMinimumVersion"; Expression={$_.platformRestriction.osMinimumVersion}},  @{Name="osMaximumVersion"; Expression={$_.platformRestriction.osMaximumVersion}})) >> $null


    Write-Verbose "Found $($returnPolicies.value.count) restriction policies for $($restrictionPolicyPlatform)"
    return $returnPolicies
}

function GetDevices($deviceFilter){  
    Write-Verbose "Start searching for devices"
    $devices = [System.Collections.ArrayList]::new()
    $url = "beta/deviceManagement/managedDevices?`$filter={0}&`$select=id,operatingSystem,deviceType,osVersion" -f $deviceFilter
    $results = Invoke-MgGraphRequest -Method GET -URI $url -OutputType PSObject
    $results.value.Foreach({
        $devices.Add($_) >> $Null
    })
    if ($null -ne $results.'@odata.nextLink'){
        do {
            $url = $results.'@odata.nextLink'
            $results = Invoke-MgGraphRequest -Method GET -URI $url -OutputType PSObject
            $results.value.Foreach({
            $devices.Add($_) >> $Null
        })
        }
        while ($results.'@odata.nextLink')
    }
    Write-Verbose "Found $($results.count) devices"
    return $results
}

try {
    Get-Module Microsoft.Graph.Authentication
}
catch {
    Install-Module Microsoft.Graph.Authentication
}
try {
    if ($null -ne $GraphToken){
        Connect-MGGraph -AccessToken $GraphToken
    }
    else {
        Connect-MGGraph
    }
}
catch{
    Throw "Not able to connect to Graph API, $_"
}


foreach ($platform in $Platforms){
    # Fetch all devices for the platform
    try {
        $platformInfo = GetPlatformInfo -platform $platform
        #region resources

        # Find the devices
        $devices = GetDevices -deviceFilter $platformInfo.deviceFilter
        
        if ($devices.count -gt 0){
        # Finding OS Build numbers second highest
        $secondHighest = ($devices.value.osVersion | Sort-Object -Descending | Select-Object -Unique)[1]
        $thirdHighest = ($devices.value.osVersion | Sort-Object -Descending | Select-Object -Unique)[2]

        # Find the specific filter
        $platformFilter = GetFilters -platformInfo $platformInfo

        # Find device compliance policy by platform
        $compliancePolicies = GetCompliancePolicies -compliancePolicyPlatform $platformInfo.compliancePolicyPlatform

        # Find platform restriction policy by platform
        $restrictionPolicies = GetRestrictionPolicies -restrictionPolicyPlatform $platformInfo.restrictionPolicyPlatform

        #endregion 

        #region compliance policy updates
        ##### N -1 policy handling with grace period
        # This is the policy that allows not that old machine having a grace period
        $n1Policy = $compliancePolicies.value.Where({ 
            ($null -ne $_.osMinimumVersion) `
            -and ($_.assignments.Count -gt 0) `
            -and (($_.scheduledActionsForRule.scheduledActionConfigurations.gracePeriodHours -gt 0) `
            -and $_.scheduledActionsForRule.scheduledActionConfigurations.notificationTemplateId -eq "00000000-0000-0000-0000-000000000000") `
            -and $_.assignments.target.deviceAndAppManagementAssignmentFilterId -eq $platformFilter.id
        })
        Write-Verbose "Found $($n1Policy.count) n-1 policy, $($n1Policy.displayName)"
        if ($n1Policy.Count -gt 1) {
            Throw "There are multiple $platform compliance policies that are holding an OS build number, have a grace period and is assigned to the same filter, $($n1Policy.displayName). Consider using just one policy for OS build handling"
        }
        if ($n1Policy.Count -eq 0){
            Throw "No compliance policy found that is assigned with a filter that get all $platform devices and has a grace period longer than 0 days"
        }
        try {
            $body = @{
                '@odata.type' = $n1Policy.'@odata.type'
                osMinimumVersion = $secondHighest
            } | ConvertTo-Json
            $url = "https://graph.microsoft.com/beta/deviceManagement/deviceCompliancePolicies/{0}" -f $n1Policy.id
            Invoke-MgGraphRequest -Method PATCH -URI $url -Body $body
            Write-Information "Policy $($n1Policy.DisplayName) OS minimum build number updated with $secondHighest"
        }
        catch {
            Throw "Not able to update policy $policy, $_"
        }

        ##### N -2 policy handling with grace period
        # This is the policy that DONT allows very old machines
        $n2Policy = $compliancePolicies.value.Where({ 
            ($null -ne $_.osMinimumVersion) `
            -and ($_.assignments.Count -gt 0) `
            -and (($_.scheduledActionsForRule.scheduledActionConfigurations.gracePeriodHours -eq 0) `
            -and $_.scheduledActionsForRule.scheduledActionConfigurations.notificationTemplateId -eq "00000000-0000-0000-0000-000000000000") `
            -and $_.assignments.target.deviceAndAppManagementAssignmentFilterId -eq $platformFilter.id
        })
        Write-Verbose "Found $($n2Policy.count) n-1 policy, $($n2Policy.displayName)"
        if ($n2Policy.Count -gt 1) {
            Throw "There are multiple $platform compliance policies that are holding an OS build number, have no grace period and is assigned to the same filter, $($n1Policy.displayName). Consider using just one policy for OS build handling"
        }
        if ($n1Policy.Count -eq 0){
            Throw "No compliance policy found that is assigned with a filter that get all $platform devices and has a grace period with 0 days"
        }
        try {
            $body = @{
                '@odata.type' = $n2Policy.'@odata.type'
                osMinimumVersion = $thirdHighest
            } | ConvertTo-Json
            $url = "https://graph.microsoft.com/beta/deviceManagement/deviceCompliancePolicies/{0}" -f $n2Policy.id
            Invoke-MgGraphRequest -Method PATCH -URI $url -Body $body
            Write-Information "Policy $($n2Policy.DisplayName) OS minimum build number updated with $thirdHighest"
        }
        catch {
            Throw "Not able to update policy $policy, $_"
        }

        #endregion

        #region Device restriction policies
        $restrictionPolicies | Foreach({
            Write-Warning "Check restriction policy $($_.displayName) because it has a build number configured"
        })
        #endregion
    }
    else {
        Write-Error "No devices found for platform $platform, no build numbers to update"
    }
    }
    catch {
        Write-Error "Not able to update buildnumbers for $platform, $_"
    }
}
