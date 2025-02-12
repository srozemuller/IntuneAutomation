$datetime   = Get-Date -f 'yyyyMMddHHmmss'
$filename   = "Transcript-remediate-deployArchiveShares-${datetime}.txt"
$Transcript = (Join-Path -Path . -ChildPath $filename).ToString()
Start-Transcript

function GetFreeDriveLetter {
    # Get all currently used drive letters
    $usedDriveLetters = Get-PSDrive -PSProvider FileSystem | Select-Object -ExpandProperty Name

    # Get all possible drive letters [E..Z] // Skipping A..D because often used
    $allDriveLetters = [char[]](69..90) | ForEach-Object { $_ }

    # Find the first drive letter not in use
    $freeDriveLetter = $allDriveLetters | Where-Object { $_ -notin $usedDriveLetters } | Select-Object -First 1
    return $freeDriveLetter
}

$logName = "IntuneRemediation"
$applicationSource = "AchiveShares"
$logTypeExists = Get-EventLog -List | Where-Object { $_.LogDisplayName -eq $applicationSource }

if (-not $logTypeExists) {
	New-EventLog -LogName $logName -Source $applicationSource
}

$upn =  whoami /upn
$url = "https://vwb-modernwork.azurewebsites.net/api/GetGroupMemberShip?code=UCRb_A0f2YlroHomER7xXeWYorf8nanSR3uDJReLsYgmAzFumNdypw%3D%3D&upn={0}" -f $upn
$request = Invoke-WebRequest -uri $url -Method GET


if ($request.StatusCode -eq 200) { 
    Write-EventLog -LogName $logName -Source $applicationSource -EventID 5001 -EntryType Information -Message "Request for groups executed with status $($request.StatusCode)"
    $shares = $request.content | ConvertFrom-Json | Select-Object Shares
    if ($shares.Shares.Count -gt 0){
        foreach ($share in $shares.Shares) {
            Write-EventLog -LogName $logName -Source $applicationSource -EventID 5002 -EntryType Information -Message "Share $($share) will be mounted"
            $shareUrl = $share.Split('\')[-3]
            $shareName = $share.Split('\')[-2]
            $shareFolder = $share.Split('\')[-1]
            
            try {
                $connectTestResult = Test-NetConnection -ComputerName $shareUrl -Port 445
                if ($connectTestResult.TcpTestSucceeded) {
                    $freeDriveLetter = GetFreeDriveLetter
                    # Mount the drive
                    New-PSDrive -Name $freeDriveLetter -Description "This is an archive share" -PSProvider FileSystem -Root $("\\{0}\{1}" -f $shareUrl,$shareName) -Persist
                    Write-EventLog -LogName $logName -Source $applicationSource -EventID 5006 -EntryType Information -Message "Share $($share) is mounted"
                } else {
                    Write-Error -Message "Unable to reach the Azure storage account via port 445. Check to make sure your organization or ISP is not blocking port 445, or use Azure P2S VPN, Azure S2S VPN, or Express Route to tunnel SMB traffic over a different port."
                    Write-EventLog -LogName $logName -Source $applicationSource -EventID 5010 -EntryType Error -Message "Share $($share) not mounted"
                }
            }
            catch {
                
            }
        }
    }
}

