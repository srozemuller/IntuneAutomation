<# 
    Detect.ps1 — Detection script for Primary User local logon restriction

    Purpose:
      - Detect whether "Allow log on locally" (SeInteractiveLogonRight)
        is restricted to:
          - The device's effective "Primary User" (single AAD user)
          - AND the local Administrators group (LAPS/admin fallback)

    Behaviour:
      - If no AAD user identities are found: skip / non-compliant.
      - If multiple AAD user identities are found: treat as shared / ambiguous, skip.
      - If exactly one AAD identity is found: treat as primary candidate.
      - If that fails, fall back to LastLoggedOnUser / ProfileList logic.
      - Compare effective SeInteractiveLogonRight to expected set:
            AzureAD\<PrimaryUpn>, *S-1-5-32-544
      - Exit 0 when compliant, 1 when not.

#>

function Normalize([string[]]$l) {
    $l |
        Where-Object { $_ -and $_.Trim() } |
        ForEach-Object { $_.Trim() } |
        Select-Object -Unique |
        Sort-Object
}

function ExportPolicy {
    $cfg = Join-Path $env:TEMP 'secpol_detect.cfg'
    secedit /export /cfg $cfg | Out-Null
    Get-Content $cfg -Raw
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
            return $last
        }
    }
    catch {
        # ignore and fall through to ProfileList
    }

    # 2. Fallback: ProfileList S-1-12-1- (AAD SIDs)
    $profileRoot = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
    $candidates  = @()

    foreach ($k in Get-ChildItem $profileRoot -ErrorAction SilentlyContinue) {

        # Only Azure AD SIDs
        if ($k.PSChildName -notmatch '^S-1-12-1-') { continue }

        $sidString = $k.PSChildName
        $upn       = $null

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
                                # On a 1:1 device, a single AAD identity is usually enough.
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
                $nt  = $sid.Translate([System.Security.Principal.NTAccount]).Value

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
            $hi   = $k.GetValue('ProfileLoadTimeHigh') -as [int]
            $lo   = $k.GetValue('ProfileLoadTimeLow')  -as [int]
            $score = ($hi -bor $lo)

            $candidates += [pscustomobject]@{
                Upn   = $upn
                Score = $score
            }
        }
    }

    if ($candidates.Count -gt 0) {
        return ($candidates | Sort-Object Score -Descending | Select-Object -First 1).Upn
    }

    return $null
}

# -------------------------------------------------------------------
# Primary user resolution with safety guard
# -------------------------------------------------------------------

$upns = Get-DeviceUserIdentities

if (-not $upns -or $upns.Count -eq 0) {
    Write-Output "No AAD users found in IdentityStore - skip enforcement."
    Write-Output "NoPrimaryUser"
    exit 1
}

if ($upns.Count -gt 1) {
    Write-Output "Multiple AAD users found on this device: $($upns -join ', ')"
    Write-Output "Treating device as shared/ambiguous - skip enforcement."
    Write-Output "NoPrimaryUser"
    exit 1
}

# Exactly one AAD user found → primary candidate
$upn = $upns[0]
Write-Output "Single AAD user detected from IdentityStore: $upn (treating as primary candidate)."

# Optional backup: if something went wrong, try backup logic
if (-not $upn) {
    $upn = GetBackupPrimaryUpn
}

if (-not $upn) {
    Write-Output "Unable to determine a primary user UPN."
    Write-Output "NoPrimaryUser"
    exit 1
}

Write-Output "Effective primary user UPN: $upn"

# -------------------------------------------------------------------
# Policy comparison: SeInteractiveLogonRight
# -------------------------------------------------------------------

# Expected rights:
#   - AzureAD\<PrimaryUpn>
#   - Local Administrators group: *S-1-5-32-544 (LAPS/admin fallback)
$primaryAccount = "AzureAD\$upn"
$adminGroupSid  = '*S-1-5-32-544'

$allowExpected = Normalize @($primaryAccount, $adminGroupSid)

# Export current local security policy and extract SeInteractiveLogonRight
$cfgRaw    = ExportPolicy
$curAllow  = Normalize (GetRight $cfgRaw 'SeInteractiveLogonRight')

Write-Output "Expected SeInteractiveLogonRight: $($allowExpected -join ', ')"
Write-Output "Current  SeInteractiveLogonRight: $($curAllow       -join ', ')"

if ( ($curAllow -join ';') -ieq ($allowExpected -join ';') ) {
    Write-Output "OK"
    exit 0
}

Write-Output "Mismatch"
exit 1
