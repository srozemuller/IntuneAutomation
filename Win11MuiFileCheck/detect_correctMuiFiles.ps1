## Description
$datetime   = Get-Date -f 'yyyyMMddHHmmss'
$filename   = "Transcript-detect-correctMuiFiles-${datetime}.txt"
$Transcript = (Join-Path -Path . -ChildPath $filename).ToString()
Start-Transcript

$consentUxMuiDll = "C:\Windows\System32\en-US\ConsentUX.dll.mui"
$consentExeMui = "C:\Windows\System32\en-US\consent.exe.mui"

$fileUxMuiExist = $true
$fileExeMuiExist = $true
try {
    if (-Not (Test-Path $consentUxMuiDll)) {
       $fileUxMuiExist = $false
    }
    if (-Not (Test-Path $consentExeMui)) {
        $fileExeMuiExist = $false
    }

    $hashOutput = @{
        consentUxMuiDll = $fileUxMuiExist
        consentExeMui = $fileExeMuiExist
    } | ConvertTo-Json -Compress
    return $hashOutput 
}
catch {
    Write-Error "Not able to check files, $_"
}
