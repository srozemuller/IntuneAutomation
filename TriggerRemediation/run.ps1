using namespace System.Net

# Input bindings are passed in via param block.
param($Timer)

# Write to the Azure Functions log stream.
Write-Host "PowerShell HTTP trigger function processed a request."

$env:graphApiUrl = "https://graph.microsoft.com/.default"
try {
    if ($env:MSI_SECRET) {
        $azureAccount = Connect-AzAccount -Identity
        Write-Host "Is Managed Identity"
    }
    else {
        Write-Host "Function app is not a managed identity. Using app registration"
        exit
    }
    $accessToken = Get-AzAccessToken -ResourceUrl $env:graphApiUrl -DefaultProfile $azureAccount
    $accessToken.Token
}
catch {
    Write-error "Azure login failed with error: $($_.Exception.Message)"
} 

$authHeader = @{
    "Content-Type" = "application/json"
    Authorization  = 'Bearer {0}' -f $accessToken.Token
}

$InformationPreference = "Continue" # Needed for showing info messages

$scriptId = "54d697b8-12e8-42ca-ad61-07b965ba8207"

function GetAutoPilotStatus(){
    Write-Verbose "Searching for autopilot status."
    $url = "https://graph.microsoft.com/beta/deviceManagement/autopilotEvents?`$filter=deviceSetupStatus eq 'InProgress'"    
    $runningEnrollment = Invoke-WebRequest -Method GET -URI $url -Headers $authHeader
    Write-Verbose "Found $($runningEnrollment.value.count) machines with enrollment status InProgress"
    return $($runningEnrollment.content | ConvertFrom-Json).value
}
function GetRemediationState($deviceId){
    Write-Verbose "Searching for remediation state at device $($deviceId)"
    $url = "https://graph.microsoft.com/beta/deviceManagement/manageddevices('{0}')?`$select=deviceactionresults,managementstate,lostModeState,deviceRegistrationState,ownertype" -f $deviceId
    $remediationStatus = Invoke-WebRequest -Method GET -URI $url -Headers $authHeader
    return $($remediationStatus.content | ConvertFrom-Json).value
}

function RunRemediation($deviceId,$scriptId){
    Write-Verbose "Start to run remediation for device $($deviceId)"
    $url = "https://graph.microsoft.com/beta/deviceManagement/managedDevices('{0}')/initiateOnDemandProactiveRemediation" -f $deviceId
    $body = 
        @{
            "ScriptPolicyId" = $scriptId 
        }| ConvertTo-Json
    $response = Invoke-WebRequest -Method POST -URI $url -Body $body -Headers $authHeader
    return $($response)
}

$rollingDevices = GetAutoPilotStatus
Write-Host "Got $($rollingDevices.count) rolling devices"
foreach ($device in $rollingDevices[0]){
    # Fetch all devices for the platform
    try {
        Write-Information "Fetching info for device $($device.deviceSerialNumber)"
        $remediationState = GetRemediationState -deviceId $device.DeviceId
        #region resources

        # Run remediation
        if ($remediationState.deviceActionResults.count -eq 0)
        {
            Write-Information "No planned tasks for device $($device.deviceSerialNumber)"
            $run = RunRemediation -deviceId $device.DeviceId -scriptId $scriptId
            if ($run.StatusCode -ne 204){
                Write-Error "Not run succesfull, $($run.StatusDescription)"
            }
            else {
                Write-Information "Succesfully scheduled"
            }
           
        } else
        {
            Write-Information "Planned tasks for device $($device.deviceSerialNumber), $($remediationState.deviceActionResults.count ) "
        }
        #endregion
        Start-Sleep 5
        $newRemediationState = GetRemediationState -deviceId $device.DeviceId
        if ($null -ne $newRemediationState){
            Write-Information "Remediation planned succesfully"
        }
        else {
            Write-Error  "Remediation NOT planned succesfully"
        }
    }
    catch {
        Write-Error "Not to run the remedation tasks, $_"
    }
}
