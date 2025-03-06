## Description
$datetime   = Get-Date -f 'yyyyMMddHHmmss'
$filename   = "Transcript-detect-checkArchiveShares-${datetime}.txt"
$Transcript = (Join-Path -Path . -ChildPath $filename).ToString()
Start-Transcript

$RegPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\Kerberos\Parameters"
$RegValueName = "CloudKerberosTicketRetrievalEnabled"

try {
    # Check if the registry key exists; if not, create it
    if (-Not (Test-Path $RegPath)) {
        Write-Host "Registry key does not exist. Creating..."
        New-Item -Path $RegPath -Force | Out-Null
    }

    # Check if the registry value exists and has the correct setting
    $RegValue = Get-ItemProperty -Path $RegPath -Name $RegValueName -ErrorAction SilentlyContinue

    if ($RegValue -eq $null -or $RegValue.$RegValueName -ne 1) {
        Write-Host "Registry value does not exist or is not set to 1. Setting value..."
        New-ItemProperty -Path $RegPath -Name $RegValueName -Value 1 -PropertyType DWord
    } else {
        Write-Host "Registry key and value exist with the correct setting."
    }
}
catch {
    Write-Error "Not able to create key, $_"
}