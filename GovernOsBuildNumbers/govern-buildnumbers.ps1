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
        [string]$GraphToken,

        [parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [array]$Platforms = @("Windows10","Windows11")
    )


function GetCompliancePolicies($platform){
    if ($platform -like "Windows*")
    {
        $platform = "Windows10" ## Add 10 to make Windows 10
    }
    $url = "https://graph.microsoft.com/beta/deviceManagement/deviceCompliancePolicies?`$filter=(isof('microsoft.graph.$platform`CompliancePolicy'))&`$expand=assignments,scheduledActionsForRule(`$expand=scheduledActionConfigurations)"    
    $compliancePolicies = Invoke-MgGraphRequest -Method GET -URI $url -OutputType PSObject
    return $compliancePolicies
}

function GetFilters($platform){
    switch ($platform){
        "Windows10" { $rule = '(device.osVersion -startsWith "10.0.19")'; $platform = "Windows10AndLater"}
        "Windows11" { $rule = '(device.osVersion -startsWith "10.0.2")'; $platform = "Windows10AndLater"}
        default { }
    }
    $url = "https://graph.microsoft.com/beta/deviceManagement/assignmentFilters?`$filter=platform eq '$platform'"    
    $filters = Invoke-MgGraphRequest -Method GET -URI $url -OutputType PSObject
    return $($filters.value | Where-Object {$_.rule -eq $rule})
}

function GetRestrictionPolicies($platform){
    if ($platform -like "Windows*")
    {
        $platform = "Windows"
    }
    $url = "https://graph.microsoft.com/beta/deviceManagement/deviceEnrollmentConfigurations?`$filter=deviceEnrollmentConfigurationType eq 'singlePlatformRestriction'"
    $restrictionPolicies = Invoke-MgGraphRequest -Method GET -URI $url -OutputType PSObject
    return $restrictionPolicies.value | Where-Object {(($_.platformType -like $platform) -and ($null -ne $_.platformRestriction.osMinimumVersion))-or ($null -eq $_.platformType)} | Select-Object displayName, platformType,  @{Name="osMinimumVersion"; Expression={$_.platformRestriction.osMinimumVersion}},  @{Name="osMaximumVersion"; Expression={$_.platformRestriction.osMaximumVersion}}
}

function GetDevices($platform){
    switch ($platform){
        "Windows10" { $osBuild = "10.19"; $platform = "Windows"}
        "Windows11" { $osBuild = "10.2"; $platform = "Windows"}
        default { $osBuild = "0" }
    }

    
    $devices = [System.Collections.ArrayList]::new()
    $url = "beta/deviceManagement/managedDevices?`$filter=operatingSystem eq '{0}' and startswith(osVersion, '$osBuild')&`$select=id,operatingSystem,deviceType,osVersion" -f $platform
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

try {
    foreach ($platform in $Platforms){
        # Fetch all devices for the platform
        try {
            #region resources

            # Find the devices
            $devices = GetDevices -platform $platform
            
            # Finding OS Build numbers second highest
            $secondHighest = ($devices.value.osVersion | Sort-Object -Descending | Select-Object -Unique)[1]
            $thirdHighest = ($devices.value.osVersion | Sort-Object -Descending | Select-Object -Unique)[2]

            # Find the specific filter
            $platformFilter = GetFilters -platform $platform

            # Find device compliance policy by platform
            $compliancePolicies = GetCompliancePolicies -platform $platform

            # Find platform restriction policy by platform
            $restrictionPolicies = GetRestrictionPolicies -platform $platform

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
            if ($n1Policy.Count -gt 1) {
                Throw "There are multiple $platform compliance policies that are holding an OS build number, have a grace period and is assigned to the same filter, $($n1Policy.displayName). Consider using just one policy for OS build handling"
            }
            $body = @{
                '@odata.type' = $n1Policy.'@odata.type'
                osMinimumVersion = $secondHighest
            } | ConvertTo-Json
            $url = "https://graph.microsoft.com/beta/deviceManagement/deviceCompliancePolicies/{0}" -f $n1Policy.id
            Invoke-MgGraphRequest -Method PATCH -URI $url -Body $body

            ##### N -2 policy handling with grace period
            # This is the policy that DONT allows very old machines
            $n2Policy = $compliancePolicies.value.Where({ 
                ($null -ne $_.osMinimumVersion) `
                -and ($_.assignments.Count -gt 0) `
                -and (($_.scheduledActionsForRule.scheduledActionConfigurations.gracePeriodHours -eq 0) `
                -and $_.scheduledActionsForRule.scheduledActionConfigurations.notificationTemplateId -eq "00000000-0000-0000-0000-000000000000") `
                -and $_.assignments.target.deviceAndAppManagementAssignmentFilterId -eq $platformFilter.id
            })
            if ($n2Policy.Count -gt 1) {
                Throw "There are multiple $platform compliance policies that are holding an OS build number, have no grace period and is assigned to the same filter, $($n1Policy.displayName). Consider using just one policy for OS build handling"
            }

            $body = @{
                '@odata.type' = $n2Policy.'@odata.type'
                osMinimumVersion = $thirdHighest
            } | ConvertTo-Json
            $url = "https://graph.microsoft.com/beta/deviceManagement/deviceCompliancePolicies/{0}" -f $n2Policy.id
            Invoke-MgGraphRequest -Method PATCH -URI $url -Body $body

            #endregion

            #region Device restriction policies
            $restrictionPolicies | Foreach({
                Write-Warning "Check restriction policy $($_.displayName) because it has a build number configured"
            })
            #endregion
        }
        catch {
            Write-Error "Not able to update buildnumbers for $platform, $_"
        }
    }
}