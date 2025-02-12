<#
.SYNOPSIS
Creates (or updates if exist) device health scripts in Intune.
.DESCRIPTION
This script searches in a provided folder for subfolders where the scripts are in. 
The script name is the name of the folder where the script set is in. In the script set folder there must be a detection_xx.ps1 and remediate_xx.ps1
.PARAMETER GraphToken
Enter the Graph Bearer token
.PARAMETER ScriptsFolder
Provide the path where the scripts folders are.
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
        [string]$ScriptsFolder
    )
try {
    $folders = Get-ChildItem -Path $ScriptsFolder -Directory
    $headers = @{
        "Content-Type" = "application/json"
        Authorization = "Bearer {0}" -f $GraphToken
    }
    $apiUrl = "https://graph.microsoft.com/beta/deviceManagement/deviceHealthScripts"
    $method = "POST"
    foreach ($folder in $folders) {
        try {
            $folder.FullName
            ls
            ls $folder.FullName

            $scripts = Invoke-webrequest -Uri $apiUrl -Method GET -Headers $headers
            $existingScript = ($scripts.content | Convertfrom-json).value | Where-Object {$_.displayName -eq $folder.Name}
            if ($existingScript) {
                $apiUrl = "{0}/{1}" -f $apiUrl, $existingScript.id
                $method = "PATCH"
            }

            $detectScript = Get-ChildItem -Path $folder.FullName -File -Filter "detect_*" | Select-Object -First 1
            if ($detectScript) {
                Write-Host "File found: $($file.FullName)"
                $command = get-content $file
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($command)
                $detectionScriptBinary = [Convert]::ToBase64String($bytes)
            } else {
                Write-Error "No detection file found. File should start with detect_"
            }

            $remediateScript = Get-ChildItem -Path $folder.FullName -File -Filter "remediate_*" | Select-Object -First 1
            if ($remediateScript) {
                Write-Host "File found: $($file.FullName)"
                $command = get-content $file
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($command)
                $remediationScriptBinary = [Convert]::ToBase64String($bytes)
            } else {
                Write-Error "No remediation file found. File should start with remediate_"
            }

            $body = @{
                displayName = $folder.Name
                description = ""
                publisher = "Sander Rozemuller"
                runAs32Bit = $true
                runAsAccount = "system"
                enforceSignatureCheck = $false
                detectionScriptContent = $detectionScriptBinary
                remediationScriptContent = $remediationScriptBinary
                roleScopeTagIds = @(
                    "0"
                )
            } | ConvertTo-Json

            Invoke-webrequest -Uri $apiUrl -Method $Method -Headers $headers -Body $body
        }
        catch {
            Write-Error "Not able to create script with name $($folder.name), $_"
        }
    }
}
catch {
    Write-Error "Not able to run succesfully, $_"
}

