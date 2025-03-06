# Input bindings are passed in via param block.
param($Timer)

# Get the current West Europe time in the default string format.
$currentTime = [System.TimeZoneInfo]::ConvertTimeBySystemTimeZoneId( (Get-Date), 'W. Europe Standard Time').ToString('yyyy-MM-dd HH:mm:ss')
$informationPreference = 'Continue'
$checkHours = (Get-Date).AddHours($env:backInHours)

# The 'IsPastDue' property is 'true' when the current function invocation is later than scheduled.
if ($Timer.IsPastDue) {
    Write-Host "PowerShell timer is running late!"
}

# Write an information log with the current time.
Write-Host "PowerShell timer trigger function ran! TIME: $currentTime"

try {
    if ($env:MSI_SECRET) {
        $azureAccount = Connect-AzAccount -Identity 
        Get-AzAccessToken -ResourceUrl "api://0ff1ecb4-363e-4cd5-8dba-36c9c9f7ae5a"
        Write-Host "Is Managed Identity"
    }
    else {
        Write-Host "Function app is not a managed identity. Using app registration"
        $passwd = ConvertTo-SecureString $env:AppSecret -AsPlainText -Force
        $pscredential = New-Object System.Management.Automation.PSCredential($env:AppId, $passwd)
        $azureAccount = Connect-AzAccount -ServicePrincipal -Credential $pscredential
    }
}
catch {
    Write-error "Azure login failed with error: $($_.Exception.Message)"
} 

try {
    Write-Information "Searching for printers in Universal Print"
    $getUrl = "https://graph.microsoft.com/beta/print/printers?`$expand=shares"
    $results = Invoke-MgGraphRequest -Method GET $getUrl
}
catch {
    Write-Error "Unable to request for security baselines, $_"
}
if ($results.value.length -gt 0) {
    try {
        $results.value | ForEach-Object {
            $printer = $_
            # Path to the JSON file
            $jsonFilePath = ".\printpolicytemplate.json"

            # Read the JSON file content as text
            $jsonContent = Get-Content -Path $jsonFilePath -Raw

            # Define the tokens you want to replace and the replacement value
            $policyToken = "<!--policyName-->"
            $policyName = "BL-WIN-UNIVERSAL-PRINT-{0}" -f $printer.displayName

            $descriptionToken = "<!--description-->"
            $description = "Printer configruation policy that assignes printer {0} to Entra ID group {1}. Printer information: - Model: {2};Location: {3}" -f $printer.displayName, $printer.shares[0].id, $printer.model, $printer.location.building

            $printerToken = "<!--printerId-->"
            $printerId = $printer.id

            $printerNameToken = "<!--printShareName-->"
            $printerName = $printer.shares[0].name

            $printerShareIdToken = "<!--printShareId-->"
            $printerShareId = $printer.shares[0].id

            # Replace the token with the replacement value
            $updatedJsonContent = $jsonContent -replace [regex]::Escape($policyToken), $policyName
            $updatedJsonContent = $updatedJsonContent -replace [regex]::Escape($descriptionToken), $description
            $updatedJsonContent = $updatedJsonContent -replace [regex]::Escape($printerToken), $printerId
            $updatedJsonContent = $updatedJsonContent -replace [regex]::Escape($printerNameToken), $printerName
            $updatedJsonContent = $updatedJsonContent -replace [regex]::Escape($printerShareIdToken), $printerShareId

            $createPolicyUrl = "https://graph.microsoft.com/beta/deviceManagement/deviceConfigurations"
            Invoke-RestMethod -Uri $createPolicyUrl -Method POST -Headers $authHeader -Body $updatedJsonContent
        }
    }
    catch {
        Write-Error "Got results, but not able to check autopilot events. $_"
    }
}
else {
    Write-Warning "No autopilot events!"
}