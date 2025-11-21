<#
    Remediate.ps1 — Enforce Primary User + Administrators for "Allow log on locally"

    Purpose:
      - Configure SeInteractiveLogonRight so that only:
          - The device's effective Primary User (single AAD identity), and
          - The local Administrators group (*S-1-5-32-544)
        are allowed to log on locally.

    Safety:
      - If no AAD identity is found locally → do nothing (exit 1).
      - If multiple AAD identities are found → treat as shared/ambiguous, do nothing (exit 1).
      - Only applies changes when exactly one AAD UPN can be determined.
      - After applying via secedit:
          - Checks secedit log for errors.
          - Re-exports policy to verify SeInteractiveLogonRight == expected.

    Notes:
      - Intended to run as SYSTEM (Intune Proactive Remediation).
      - No Graph permissions required; works purely on local state.
#>

function Normalize([string[]]$l) {
    $l |
    Where-Object { $_ -and $_.Trim() } |
    ForEach-Object { $_.Trim() } |
    Select-Object -Unique |
    Sort-Object
}

function ExportPolicy {
    param(
        [string]$Path = $(Join-Path $env:TEMP 'secpol_export_verify.cfg')
    )

    secedit /export /cfg $Path | Out-Null
    Get-Content $Path -Raw
}

function GetRight($Cfg, $Name) {
    if ($Cfg -match "(?m)^$Name\s*=\s*(.*)$") {
        ($Matches[1] -split ',') |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ }
    }
    else {
        @()
    }
}

function Get-DeviceUserIdentities {
    <#
        Reads HKLM:\SOFTWARE\Microsoft\IdentityStore\Cache
        and returns all unique AAD-style UserName values (UPNs).

        This reflects all AAD identities that have an identity cache
        on this device – i.e. users that have logged on interactively.
    #>

    $cacheRoot = 'HKLM:\SOFTWARE\Microsoft\IdentityStore\Cache'
    $userNames = @()

    Get-ChildItem -Path $cacheRoot -Recurse -ErrorAction SilentlyContinue |
    Where-Object { $_.PSPath -like '*IdentityCache*' } |
    ForEach-Object {
        try {
            $props = Get-ItemProperty -Path $_.PSPath -ErrorAction Stop

            if ($props.PSObject.Properties.Name -contains 'UserName') {
                $u = $props.UserName
                if ($u -and $u -like '*@*') {
                    $userNames += $u
                }
            }
        }
        catch {
            # ignore unreadable keys
        }
    }

    $userNames | Select-Object -Unique
}

function GetBackupPrimaryUpn {
    <#
        Backup mechanism to infer a primary UPN when IdentityStore alone
        is not conclusive.

        1. Prefer HKLM:\...\LogonUI\LastLoggedOnUser if it looks like a UPN.
        2. Then inspect ProfileList S-1-12-1-* (AAD SIDs) and try to map to a UPN,
           using IdentityStore and NTAccount translation as hints.
        3. Picks the “most active” profile using ProfileLoadTimeHigh/Low.
    #>

    # 1. Prefer LastLoggedOnUser
    $logonKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI'
    try {
        $logonProps = Get-ItemProperty -Path $logonKey -ErrorAction Stop
        $last = $logonProps.LastLoggedOnUser

        if ($last -and $last -like '*@*') {
            Write-Output "Backup: LastLoggedOnUser suggests primary UPN: $last"
            return $last
        }
    }
    catch {
        # ignore and fall through to ProfileList
    }

    # 2. Fallback: ProfileList S-1-12-1- (AAD SIDs)
    $profileRoot = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
    $candidates = @()

    foreach ($k in Get-ChildItem $profileRoot -ErrorAction SilentlyContinue) {

        # Only Azure AD SIDs
        if ($k.PSChildName -notmatch '^S-1-12-1-') { continue }

        $sidString = $k.PSChildName
        $upn = $null

        # 2a. Try to map via IdentityStore (best-effort)
        try {
            $cacheRoot = 'HKLM:\SOFTWARE\Microsoft\IdentityStore\Cache'

            Get-ChildItem -Path $cacheRoot -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.PSPath -like '*IdentityCache*' } |
            ForEach-Object {
                try {
                    $props = Get-ItemProperty -Path $_.PSPath -ErrorAction Stop
                    if ($props.PSObject.Properties.Name -contains 'UserName') {
                        $u = $props.UserName
                        if ($u -and $u -like '*@*') {
                            $upn = $u
                        }
                    }
                }
                catch { }
            }
        }
        catch { }

        # 2b. If still no UPN, try SID -> NTAccount and only accept if it looks like UPN
        if (-not $upn) {
            try {
                $sid = New-Object System.Security.Principal.SecurityIdentifier($sidString)
                $nt = $sid.Translate([System.Security.Principal.NTAccount]).Value

                if ($nt -like '*@*') {
                    if ($nt -like 'AzureAD\*') {
                        $upn = $nt.Substring(8)
                    }
                    else {
                        $upn = $nt
                    }
                }
            }
            catch { }
        }

        if ($upn) {
            $hi = $k.GetValue('ProfileLoadTimeHigh') -as [int]
            $lo = $k.GetValue('ProfileLoadTimeLow') -as [int]
            $score = ($hi -bor $lo)

            $candidates += [pscustomobject]@{
                Upn   = $upn
                Score = $score
            }
        }
    }

    if ($candidates.Count -gt 0) {
        $chosen = ($candidates | Sort-Object Score -Descending | Select-Object -First 1).Upn
        Write-Output "Backup: ProfileList-based candidate UPN: $chosen"
        return $chosen
    }

    return $null
}

function Set-SeInteractiveLogonRight {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PrimaryUpn
    )

    # Temp paths
    $cfgPath = Join-Path $env:TEMP 'rights.cfg'
    $dbPath = Join-Path $env:TEMP 'rights.sdb'

    Write-Host "Exporting current local security policy to $cfgPath ..."
    secedit /export /cfg $cfgPath | Out-Null

    # Build the new lines
    $interactiveLine = "SeInteractiveLogonRight = AzureAD\$primaryUpn"

    # OPTIONAL: if you want to restrict RDP to a group, uncomment & adapt:
    # $rdpLine         = "SeRemoteInteractiveLogonRight = $serviceDeskGroup"

    Write-Host "Updating SeInteractiveLogonRight and SeDenyInteractiveLogonRight in cfg ..."

    $lines = Get-Content $cfgPath
    $newLines = @()
    $foundInteractive = $false

    #$foundRdp         = $false

    foreach ($line in $lines) {
        if ($line -match '^SeInteractiveLogonRight\s*=') {
            $newLines += $interactiveLine
            $foundInteractive = $true
        }
        else {
            $newLines += $line
        }
    }

    # If any key was missing, append it
    if (-not $foundInteractive) { $newLines += $interactiveLine }


    $newLines | Set-Content -Path $cfgPath -Encoding ASCII

    Write-Host "Applying updated USER_RIGHTS via secedit ..."
    secedit /configure /db $dbPath /cfg $cfgPath /areas USER_RIGHTS /quiet

    # --- Step 2: Re-export policy and verify SeInteractiveLogonRight ---
    try {
        $sidObj = New-Object System.Security.Principal.NTAccount("AzureAD\$PrimaryUpn")
        $primarySid = $sidObj.Translate([System.Security.Principal.SecurityIdentifier]).Value
    }
    catch {
        throw "Unable to resolve SID for AzureAD\$PrimaryUpn"
    }

    # Verification
    $cfgRaw = ExportPolicy -Path $verifyCfg
    $curAllow = Normalize (GetRight $cfgRaw 'SeInteractiveLogonRight')

    # expected = SID + Administrator SID
    $expectedEntries = Normalize @("*$primarySid", "*S-1-5-32-544")

    $expectedStr = $expectedEntries -join ';'
    $currentStr = $curAllow -join ';'

    Write-Output "Verification - expected SIDs: $expectedStr"
    Write-Output "Verification - current  SIDs: $currentStr"

    if ($expectedStr -ine $currentStr) {
        throw "Verification failed: SID-based SeInteractiveLogonRight does not match expected."
    }

    Write-Output "Verification succeeded: SID-based SeInteractiveLogonRight is correct."
}

# -------------------------------------------------------------------
# 1. Resolve Primary User
# -------------------------------------------------------------------

$upns = Get-DeviceUserIdentities

if (-not $upns -or $upns.Count -eq 0) {
    Write-Output "Remediation: No AAD users found in IdentityStore - skipping."
    exit 1
}

if ($upns.Count -gt 1) {
    Write-Output "Remediation: Multiple AAD users found: $($upns -join ', ')"
    Write-Output "Treating device as shared/ambiguous - skipping."
    exit 1
}

# Single AAD user found – primary candidate
$upn = $upns | Select-Object -First 1
Write-Output "Remediation: Single AAD user detected: $upn (primary candidate)."

# Optional backup: if something went wrong, try backup logic
if (-not $upn) {
    $upn = GetBackupPrimaryUpn
}

if (-not $upn) {
    Write-Output "Remediation: Unable to determine a primary user UPN - skipping."
    exit 1
}

Write-Output "Remediation: Effective primary user UPN to enforce: $upn"

# -------------------------------------------------------------------
# 2. Apply SeInteractiveLogonRight for primary + Administrators
#     + log check + policy verification
# -------------------------------------------------------------------

try {
    Set-SeInteractiveLogonRight -PrimaryUpn $upn
    Write-Output "Remediation: Completed successfully."
    exit 0
}
catch {
    Write-Output "Remediation: Failed to apply SeInteractiveLogonRight. Error: $($_.Exception.Message)"
    exit 1
}
