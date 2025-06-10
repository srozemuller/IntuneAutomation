## Description
$datetime   = Get-Date -f 'yyyyMMddHHmmss'
$filename   = "Transcript-detect-setInitialStartMenu-${datetime}.txt"
$Transcript = (Join-Path -Path . -ChildPath $filename).ToString()
Start-Transcript

try {
    # Start menu start2.bin in base64 format
    $startMenuBase64 = "4nrhSwH8TRucAIEL3m5RhU5aX0... "

    # Decode and write the file
    $bytes = [Convert]::FromBase64String($startMenuBase64)

    # Define your destination path—adjust as needed per your environment:
    $dest = Join-Path $ENV:LOCALAPPDATA '\Packages\Microsoft.Windows.StartMenuExperienceHost_cw5n1h2txyewy\LocalState\start2.bin'

    # Ensure the directory exists
    New-Item -ItemType Directory -Path (Split-Path $dest) -Force | Out-Null

    # Write the bytes
    [IO.File]::WriteAllBytes($dest, $bytes)

    #Restart Start Menu Experince
    Stop-Process -Name StartMenuExperienceHost -Force

    Write-Host "start2.bin deployed to $dest"
    exit 0
}
catch {
    Write-Output "Configuring initial Start-menu  not succesfull $($_)" 
    exit 1
}


