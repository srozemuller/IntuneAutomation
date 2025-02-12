## Description
$datetime   = Get-Date -f 'yyyyMMddHHmmss'
$filename   = "Transcript-detect-checkArchiveShares-${datetime}.txt"
$Transcript = (Join-Path -Path . -ChildPath $filename).ToString()
Start-Transcript

$logName = "IntuneRemediation"
$applicationSource = "AchiveShares"
$logTypeExists = Get-EventLog -List | Where-Object { $_.LogDisplayName -eq $applicationSource }

if (-not $logTypeExists) {
	New-EventLog -LogName $logName -Source $applicationSource
}

$upn =  whoami /upn
$url = "https://vwb-modernwork.azurewebsites.net/api/GetGroupMemberShip?code=UCRb_A0f2YlroHomER7xXeWYorf8nanSR3uDJReLsYgmAzFumNdypw%3D%3D&upn={0}" -f $upn
$request = Invoke-WebRequest -uri $url -Method GET

try {
    if ($request.StatusCode -eq 200) { 
        Write-EventLog -LogName $logName -Source $applicationSource -EventID 5001 -EntryType Information -Message "Request for groups executed with status $($request.StatusCode)"
        $shares = $request.content | ConvertFrom-Json | Select-Object Shares
        if ($shares.Shares.Count -gt 0){
            foreach ($share in $shares.Shares) {
                Write-EventLog -LogName $logName -Source $applicationSource -EventID 5003 -EntryType Information -Message "Share $($share) will be checked"          
                $currentlyMapped = Get-PSDrive | Select-Object Root
                if ($currentlyMapped.Root -in $share) {
                    Write-Output "Share is mapped already"
                    Write-EventLog -LogName $logName -Source $applicationSource -EventID 5004 -EntryType Information -Message "Share $($share) allready mapped" 
                    exit 0
                }
                else {
                    Write-Output "Share is not mapped"
                    Write-EventLog -LogName $logName -Source $applicationSource -EventID 5005 -EntryType Information -Message "Share $($share) not mapped, starting remediation" 
                    exit 1
                }
            }
        }
    }
    else {
        Write-EventLog -LogName $logName -Source $applicationSource -EventID 5003 -EntryType Error -Message "Requesting GetGroupMemberShip function not succesfull $($request.StatusCode), $($request.Content)" 
        exit 1
    }
}



