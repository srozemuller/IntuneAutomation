## Description
$datetime   = Get-Date -f 'yyyyMMddHHmmss'
$filename   = "Transcript-detect-checkArchiveShares-${datetime}.txt"
$Transcript = (Join-Path -Path . -ChildPath $filename).ToString()
Start-Transcript

$RegPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\Kerberos\Parameters"
$RegValueName = "CloudKerberosTicketRetrievalEnabled"

try {
    if (-Not (Test-Path $RegPath)) {
        Write-Host "Registry key does not exist."
        exit 1
    }

    $RegValue = Get-ItemProperty -Path $RegPath -Name $RegValueName -ErrorAction SilentlyContinue

    if ($RegValue -eq $null -or $RegValue.$RegValueName -ne 1) {
        Write-Host "Registry value does not exist or is not set to 1."
        exit 1
    }
    else {
        exit 0
    }
}
catch {
    Write-Error "Not able to check regkey, $_"
    exit 1
}