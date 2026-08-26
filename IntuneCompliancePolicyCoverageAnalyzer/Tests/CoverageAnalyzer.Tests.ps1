#requires -Modules Pester

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'CoverageAnalyzer.psm1'
    Import-Module $modulePath -Force

    function New-TestDeviceContext {
        param(
            [string]$UserContext = 'User',
            [string]$DeviceOwnershipFilterValue = 'Corporate',
            [string]$Manufacturer = 'Microsoft',
            [string]$Model = 'Surface Laptop 5',
            [string]$OsVersion = '10.0.22631.3235',
            [string]$EnrollmentProfileName = 'Autopilot Profile',
            [string]$DeviceName = 'WIN11-001',
            [string]$DeviceCategoryDisplayName = 'Corporate'
        )
        [PSCustomObject]@{
            IntuneManagedDeviceId      = 'device-guid-1'
            DeviceName                 = $DeviceName
            AzureADDeviceId            = 'aad-device-guid-1'
            UserId                     = if ($UserContext -eq 'User') { 'user-guid-1' } else { $null }
            UserPrincipalName          = if ($UserContext -eq 'User') { 'user@contoso.com' } else { $null }
            UserContext                = $UserContext
            DeviceOwnershipFilterValue = $DeviceOwnershipFilterValue
            Manufacturer                = $Manufacturer
            Model                       = $Model
            OsVersion                   = $OsVersion
            EnrollmentProfileName       = $EnrollmentProfileName
            DeviceCategoryDisplayName   = $DeviceCategoryDisplayName
            Platform                    = 'Windows'
        }
    }

    function New-TestAssignment {
        param(
            [string]$AssignmentId = 'assignment-1',
            [string]$TargetType = '#microsoft.graph.allDevicesAssignmentTarget',
            [string]$TargetGroupId = $null,
            [bool]$IsExclusion = $false,
            [string]$FilterId = $null,
            [string]$FilterMode = 'none',
            [string]$FilterName = $null,
            [string]$FilterRule = $null
        )
        [PSCustomObject]@{
            AssignmentId  = $AssignmentId
            TargetType    = $TargetType
            TargetGroupId = $TargetGroupId
            IsExclusion   = $IsExclusion
            FilterId      = $FilterId
            FilterMode    = $FilterMode
            FilterName    = $FilterName
            FilterRule    = $FilterRule
        }
    }

    function New-TestPolicy {
        param([string]$Id = 'policy-1', [string]$DisplayName = 'Windows Standard Compliance')
        [PSCustomObject]@{ Id = $Id; DisplayName = $DisplayName; Platform = 'Windows' }
    }

    function New-TestGroupMembership {
        # Mirrors Get-DirectoryObjectGroupMembership's {Matched;Unresolved} contract.
        param(
            [string[]]$Matched = @(),
            [string[]]$Unresolved = @()
        )
        $matchedSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($id in $Matched) { [void]$matchedSet.Add($id) }
        $unresolvedSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($id in $Unresolved) { [void]$unresolvedSet.Add($id) }
        [PSCustomObject]@{ Matched = $matchedSet; Unresolved = $unresolvedSet }
    }
}

Describe 'Test-IntuneAssignmentFilter' {

    It 'matches a simple eq comparison' {
        $props = @{ Manufacturer = 'Microsoft' }
        $result = Test-IntuneAssignmentFilter -Rule '(device.manufacturer -eq "Microsoft")' -DeviceProperties $props
        $result.Result | Should -Be 'Matched'
    }

    It 'does not match when the eq comparison fails' {
        $props = @{ DeviceOwnership = 'Personal' }
        $result = Test-IntuneAssignmentFilter -Rule '(device.deviceOwnership -eq "Corporate")' -DeviceProperties $props
        $result.Result | Should -Be 'NotMatched'
    }

    It 'evaluates and/or with parentheses' {
        $props = @{ Manufacturer = 'Microsoft'; Model = 'Surface Book 3' }
        $result = Test-IntuneAssignmentFilter -Rule '(device.manufacturer -eq "Microsoft") and (device.model -contains "Surface")' -DeviceProperties $props
        $result.Result | Should -Be 'Matched'
    }

    It 'supports notContains, startsWith, in, notIn' {
        $props = @{ Manufacturer = 'Dell Inc.' }
        (Test-IntuneAssignmentFilter -Rule '(device.manufacturer -notContains "Microsoft")' -DeviceProperties $props).Result | Should -Be 'Matched'
        (Test-IntuneAssignmentFilter -Rule '(device.manufacturer -startsWith "Dell")' -DeviceProperties $props).Result | Should -Be 'Matched'
        (Test-IntuneAssignmentFilter -Rule '(device.manufacturer -in ["Dell Inc.","HP"])' -DeviceProperties $props).Result | Should -Be 'Matched'
        (Test-IntuneAssignmentFilter -Rule '(device.manufacturer -notIn ["Dell Inc.","HP"])' -DeviceProperties $props).Result | Should -Be 'NotMatched'
    }

    It 'returns Unknown for an unsupported operator rather than guessing (Test 7)' {
        $props = @{ OsVersion = '10.0.22631.3235' }
        $result = Test-IntuneAssignmentFilter -Rule '(device.operatingSystemVersion -gt 10.0.22000.1000)' -DeviceProperties $props
        $result.Result | Should -Be 'Unknown'
        $result.Reason | Should -Match 'unsupported'
    }

    It 'returns Unknown for an unsupported property rather than guessing' {
        $props = @{ Manufacturer = 'Microsoft' }
        $result = Test-IntuneAssignmentFilter -Rule '(device.cpuArchitecture -eq "arm64")' -DeviceProperties $props
        $result.Result | Should -Be 'Unknown'
    }

    It 'returns Unknown for malformed syntax instead of throwing' {
        $props = @{ Manufacturer = 'Microsoft' }
        { Test-IntuneAssignmentFilter -Rule '(device.manufacturer -eq )' -DeviceProperties $props } | Should -Not -Throw
        (Test-IntuneAssignmentFilter -Rule '(device.manufacturer -eq )' -DeviceProperties $props).Result | Should -Be 'Unknown'
    }
}

Describe 'Test-CompliancePolicyAssignment' {

    It 'Test 1: All Devices, no filter, no exclusion => Matched' {
        $device = New-TestDeviceContext
        $assignment = New-TestAssignment -TargetType '#microsoft.graph.allDevicesAssignmentTarget'
        $result = Test-CompliancePolicyAssignment -Assignment $assignment -DeviceContext $device `
            -DeviceGroupMemberships $null -UserGroupMemberships $null -FilterProperties (Get-FilterPropertiesFromDeviceContext -DeviceContext $device)
        $result.Result | Should -Be 'Matched'
        $result.MatchedVia | Should -Be 'AllDevices'
    }

    It 'Test 2: All Devices + include filter mismatch => FilteredOut' {
        $device = New-TestDeviceContext -DeviceOwnershipFilterValue 'Personal'
        $assignment = New-TestAssignment -TargetType '#microsoft.graph.allDevicesAssignmentTarget' `
            -FilterId 'filter-1' -FilterMode 'include' -FilterName 'Corporate Windows' -FilterRule '(device.deviceOwnership -eq "Corporate")'
        $result = Test-CompliancePolicyAssignment -Assignment $assignment -DeviceContext $device `
            -DeviceGroupMemberships $null -UserGroupMemberships $null -FilterProperties (Get-FilterPropertiesFromDeviceContext -DeviceContext $device)
        $result.Result | Should -Be 'FilteredOut'
    }

    It 'Test 3: device group assignment, device is member => Matched via Device' {
        $device = New-TestDeviceContext
        $assignment = New-TestAssignment -TargetType '#microsoft.graph.groupAssignmentTarget' -TargetGroupId 'group-1'
        $deviceMemberships = New-TestGroupMembership -Matched 'group-1'
        $result = Test-CompliancePolicyAssignment -Assignment $assignment -DeviceContext $device `
            -DeviceGroupMemberships $deviceMemberships -UserGroupMemberships $null -FilterProperties (Get-FilterPropertiesFromDeviceContext -DeviceContext $device)
        $result.Result | Should -Be 'Matched'
        $result.MatchedVia | Should -Be 'Device'
    }

    It 'Test 4: group assignment, user is member but device is not => Matched via User' {
        $device = New-TestDeviceContext
        $assignment = New-TestAssignment -TargetType '#microsoft.graph.groupAssignmentTarget' -TargetGroupId 'group-1'
        $deviceMemberships = New-TestGroupMembership
        $userMemberships = New-TestGroupMembership -Matched 'group-1'
        $result = Test-CompliancePolicyAssignment -Assignment $assignment -DeviceContext $device `
            -DeviceGroupMemberships $deviceMemberships -UserGroupMemberships $userMemberships -FilterProperties (Get-FilterPropertiesFromDeviceContext -DeviceContext $device)
        $result.Result | Should -Be 'Matched'
        $result.MatchedVia | Should -Be 'User'
    }

    It 'Test 5: exclusion group assignment, device is a member => exclusion Matched' {
        $device = New-TestDeviceContext
        $assignment = New-TestAssignment -TargetType '#microsoft.graph.exclusionGroupAssignmentTarget' -TargetGroupId 'excl-group' -IsExclusion $true
        $deviceMemberships = New-TestGroupMembership -Matched 'excl-group'
        $result = Test-CompliancePolicyAssignment -Assignment $assignment -DeviceContext $device `
            -DeviceGroupMemberships $deviceMemberships -UserGroupMemberships $null -FilterProperties (Get-FilterPropertiesFromDeviceContext -DeviceContext $device)
        $result.Result | Should -Be 'Matched'
    }

    It 'Test 6: no include assignment matches => NotTargeted' {
        $device = New-TestDeviceContext
        $assignment = New-TestAssignment -TargetType '#microsoft.graph.groupAssignmentTarget' -TargetGroupId 'group-1'
        $deviceMemberships = New-TestGroupMembership
        $userMemberships = New-TestGroupMembership
        $result = Test-CompliancePolicyAssignment -Assignment $assignment -DeviceContext $device `
            -DeviceGroupMemberships $deviceMemberships -UserGroupMemberships $userMemberships -FilterProperties (Get-FilterPropertiesFromDeviceContext -DeviceContext $device)
        $result.Result | Should -Be 'NotTargeted'
    }

    It 'a group id in Unresolved (not the whole membership object being null) => Unknown, never NotTargeted' {
        $device = New-TestDeviceContext
        $assignment = New-TestAssignment -TargetType '#microsoft.graph.groupAssignmentTarget' -TargetGroupId 'bad-group'
        $deviceMemberships = New-TestGroupMembership -Matched 'good-group' -Unresolved 'bad-group'
        $userMemberships = New-TestGroupMembership -Matched 'good-group'
        $result = Test-CompliancePolicyAssignment -Assignment $assignment -DeviceContext $device `
            -DeviceGroupMemberships $deviceMemberships -UserGroupMemberships $userMemberships -FilterProperties (Get-FilterPropertiesFromDeviceContext -DeviceContext $device)
        $result.Result | Should -Be 'Unknown'
    }

    It 'Test 7: unsupported assignment filter operator => Unknown' {
        $device = New-TestDeviceContext
        $assignment = New-TestAssignment -TargetType '#microsoft.graph.allDevicesAssignmentTarget' `
            -FilterId 'filter-1' -FilterMode 'include' -FilterName 'Bad Filter' -FilterRule '(device.operatingSystemVersion -gt 10.0.22000.1000)'
        $result = Test-CompliancePolicyAssignment -Assignment $assignment -DeviceContext $device `
            -DeviceGroupMemberships $null -UserGroupMemberships $null -FilterProperties (Get-FilterPropertiesFromDeviceContext -DeviceContext $device)
        $result.Result | Should -Be 'Unknown'
    }

    It 'Test 9: user-only targeting, device has no associated user => NotTargeted (proven fact, not an error)' {
        $device = New-TestDeviceContext -UserContext 'None'
        $assignment = New-TestAssignment -TargetType '#microsoft.graph.allLicensedUsersAssignmentTarget'
        $result = Test-CompliancePolicyAssignment -Assignment $assignment -DeviceContext $device `
            -DeviceGroupMemberships $null -UserGroupMemberships $null -FilterProperties (Get-FilterPropertiesFromDeviceContext -DeviceContext $device)
        $result.Result | Should -Be 'NotTargeted'
    }

    It 'Test 9b: group targeting, device has no user AND device membership is unresolved => Unknown, never NotTargeted' {
        $device = New-TestDeviceContext -UserContext 'None'
        $assignment = New-TestAssignment -TargetType '#microsoft.graph.groupAssignmentTarget' -TargetGroupId 'group-1'
        $result = Test-CompliancePolicyAssignment -Assignment $assignment -DeviceContext $device `
            -DeviceGroupMemberships $null -UserGroupMemberships $null -FilterProperties (Get-FilterPropertiesFromDeviceContext -DeviceContext $device)
        $result.Result | Should -Be 'Unknown'
    }

    It 'Test 10: Graph membership check fails (null) => Unknown, never NotTargeted' {
        $device = New-TestDeviceContext
        $assignment = New-TestAssignment -TargetType '#microsoft.graph.groupAssignmentTarget' -TargetGroupId 'group-1'
        $result = Test-CompliancePolicyAssignment -Assignment $assignment -DeviceContext $device `
            -DeviceGroupMemberships $null -UserGroupMemberships $null -FilterProperties (Get-FilterPropertiesFromDeviceContext -DeviceContext $device)
        $result.Result | Should -Be 'Unknown'
        $result.Result | Should -Not -Be 'NotTargeted'
    }

    It 'reports Unknown for an unrecognized assignment target type instead of ignoring it' {
        $device = New-TestDeviceContext
        $assignment = New-TestAssignment -TargetType '#microsoft.graph.someFutureAssignmentTarget'
        $result = Test-CompliancePolicyAssignment -Assignment $assignment -DeviceContext $device `
            -DeviceGroupMemberships $null -UserGroupMemberships $null -FilterProperties (Get-FilterPropertiesFromDeviceContext -DeviceContext $device)
        $result.Result | Should -Be 'Unknown'
        $result.Reason | Should -Match 'Unsupported assignment target type'
    }
}

Describe 'Test-CompliancePolicyCoverage' {

    It 'Test 1: single All Devices match, no exclusion => ShouldApply' {
        $device = New-TestDeviceContext
        $policy = New-TestPolicy
        $evals = @([PSCustomObject]@{ IsExclusion = $false; Result = 'Matched'; TargetGroupId = $null; Reason = 'r' })
        $result = Test-CompliancePolicyCoverage -Policy $policy -AssignmentEvaluations $evals -DeviceContext $device
        $result.Result | Should -Be 'ShouldApply'
    }

    It 'Test 5: include matched + exclusion matched => Excluded' {
        $device = New-TestDeviceContext
        $policy = New-TestPolicy
        $evals = @(
            [PSCustomObject]@{ IsExclusion = $false; Result = 'Matched'; TargetGroupId = $null; Reason = 'included' },
            [PSCustomObject]@{ IsExclusion = $true; Result = 'Matched'; TargetGroupId = 'excl-group'; Reason = 'excluded' }
        )
        $result = Test-CompliancePolicyCoverage -Policy $policy -AssignmentEvaluations $evals -DeviceContext $device
        $result.Result | Should -Be 'Excluded'
    }

    It 'Test 6: no include assignment matches => NotTargeted' {
        $device = New-TestDeviceContext
        $policy = New-TestPolicy
        $evals = @([PSCustomObject]@{ IsExclusion = $false; Result = 'NotTargeted'; TargetGroupId = 'group-1'; Reason = 'r' })
        $result = Test-CompliancePolicyCoverage -Policy $policy -AssignmentEvaluations $evals -DeviceContext $device
        $result.Result | Should -Be 'NotTargeted'
    }

    It 'Test 8: ShouldApply + device came from the without-compliance-policy report => ShouldApplyButMissing' {
        $device = New-TestDeviceContext
        $policy = New-TestPolicy
        $evals = @([PSCustomObject]@{ IsExclusion = $false; Result = 'Matched'; TargetGroupId = $null; Reason = 'r' })
        $result = Test-CompliancePolicyCoverage -Policy $policy -AssignmentEvaluations $evals -DeviceContext $device -FromWithoutCompliancePolicyReport
        $result.Result | Should -Be 'ShouldApplyButMissing'
    }

    It 'Test 12: assignment A filtered out, assignment B matches => policy ShouldApply (one failure must not override a real match)' {
        $device = New-TestDeviceContext
        $policy = New-TestPolicy
        $evals = @(
            [PSCustomObject]@{ IsExclusion = $false; Result = 'FilteredOut'; TargetGroupId = 'group-a'; Reason = 'A filtered' },
            [PSCustomObject]@{ IsExclusion = $false; Result = 'Matched'; TargetGroupId = 'group-b'; Reason = 'B matched' }
        )
        $result = Test-CompliancePolicyCoverage -Policy $policy -AssignmentEvaluations $evals -DeviceContext $device
        $result.Result | Should -Be 'ShouldApply'
    }

    It 'an unknown assignment does not override a proven match from another assignment' {
        $device = New-TestDeviceContext
        $policy = New-TestPolicy
        $evals = @(
            [PSCustomObject]@{ IsExclusion = $false; Result = 'Unknown'; TargetGroupId = 'group-a'; Reason = 'A unknown' },
            [PSCustomObject]@{ IsExclusion = $false; Result = 'Matched'; TargetGroupId = 'group-b'; Reason = 'B matched' }
        )
        $result = Test-CompliancePolicyCoverage -Policy $policy -AssignmentEvaluations $evals -DeviceContext $device
        $result.Result | Should -Be 'ShouldApply'
    }

    It 'include matched but exclusion membership unresolved => Unknown, never Excluded or ShouldApply' {
        $device = New-TestDeviceContext
        $policy = New-TestPolicy
        $evals = @(
            [PSCustomObject]@{ IsExclusion = $false; Result = 'Matched'; TargetGroupId = $null; Reason = 'included' },
            [PSCustomObject]@{ IsExclusion = $true; Result = 'Unknown'; TargetGroupId = 'excl-group'; Reason = 'unresolved' }
        )
        $result = Test-CompliancePolicyCoverage -Policy $policy -AssignmentEvaluations $evals -DeviceContext $device
        $result.Result | Should -Be 'Unknown'
    }

    It 'no assignments at all => NotTargeted' {
        $device = New-TestDeviceContext
        $policy = New-TestPolicy
        $result = Test-CompliancePolicyCoverage -Policy $policy -AssignmentEvaluations @() -DeviceContext $device
        $result.Result | Should -Be 'NotTargeted'
    }
}

Describe 'Get-DirectoryObjectGroupMembership chunking' {

    It 'Test 11: 21 group ids => exactly two checkMemberGroups requests, chunked 20 + 1' {
        InModuleScope CoverageAnalyzer {
            $calls = [System.Collections.Generic.List[object]]::new()
            Mock Invoke-GraphRequest {
                $calls.Add(($Body | ConvertFrom-Json).groupIds)
                [PSCustomObject]@{ value = @() }
            }

            $groupIds = 1..21 | ForEach-Object { "group-$_" }
            $null = Get-DirectoryObjectGroupMembership -ObjectId 'device-1' -GroupIds $groupIds -ObjectType Device

            $calls.Count | Should -Be 2
            $calls[0].Count | Should -Be 20
            $calls[1].Count | Should -Be 1
        }
    }

    It 'a group that never succeeds ends up Unresolved (Unknown), never silently matched/unmatched' {
        InModuleScope CoverageAnalyzer {
            Mock Invoke-GraphRequest { throw 'simulated 403' }
            $result = Get-DirectoryObjectGroupMembership -ObjectId 'device-1' -GroupIds @('group-1') -ObjectType Device
            $result.Matched.Count | Should -Be 0
            $result.Unresolved.Contains('group-1') | Should -BeTrue
        }
    }

    It 'one bad group id in a batch does not poison the other valid ids in that same batch' {
        # Regression test for the real bug found in this tenant: Graph fails
        # a whole checkMemberGroups batch if any one id in it is invalid, so
        # a single stale group was making every other group in the same
        # request show Unknown too. A failed batch must retry per-id so only
        # the actually-bad id ends up Unresolved.
        InModuleScope CoverageAnalyzer {
            Mock Invoke-GraphRequest {
                $ids = ($Body | ConvertFrom-Json).groupIds
                if ($ids.Count -gt 1) {
                    throw 'simulated batch failure: one id in this request is invalid'
                }
                elseif ($ids[0] -eq 'bad-group') {
                    throw 'simulated failure: bad-group does not exist'
                }
                else {
                    [PSCustomObject]@{ value = @($ids[0]) }
                }
            }

            $result = Get-DirectoryObjectGroupMembership -ObjectId 'device-1' -GroupIds @('good-1', 'good-2', 'bad-group') -ObjectType Device

            $result.Matched.Contains('good-1') | Should -BeTrue
            $result.Matched.Contains('good-2') | Should -BeTrue
            $result.Unresolved.Contains('bad-group') | Should -BeTrue
            $result.Unresolved.Contains('good-1') | Should -BeFalse
            $result.Unresolved.Contains('good-2') | Should -BeFalse
        }
    }
}

Describe 'Get-CompliancePolicyPlatform' {
    It 'maps windows10CompliancePolicy to Windows' {
        Get-CompliancePolicyPlatform -ODataType '#microsoft.graph.windows10CompliancePolicy' | Should -Be 'Windows'
    }
    It 'maps an unrecognized type to Unsupported rather than guessing' {
        Get-CompliancePolicyPlatform -ODataType '#microsoft.graph.androidCompliancePolicy' | Should -Be 'Unsupported'
    }
}

Describe 'Get-IntuneManagedDeviceContext userless-device handling' {

    It 'treats the all-zero placeholder userId as no user, not a real user (UserContext = None)' {
        InModuleScope CoverageAnalyzer {
            Mock Invoke-GraphRequest {
                [PSCustomObject]@{
                    id                     = 'device-1'
                    deviceName             = 'KIOSK-01'
                    operatingSystem        = 'Windows'
                    userId                 = '00000000-0000-0000-0000-000000000000'
                    userPrincipalName      = $null
                    managedDeviceOwnerType = 'company'
                }
            }
            $result = Get-IntuneManagedDeviceContext -ManagedDeviceId 'device-1'
            $result.UserContext | Should -Be 'None'
            $result.UserId | Should -BeNullOrEmpty
        }
    }

    It 'still treats a real userId as UserContext = User' {
        InModuleScope CoverageAnalyzer {
            Mock Invoke-GraphRequest {
                [PSCustomObject]@{
                    id                     = 'device-1'
                    deviceName             = 'WIN11-001'
                    operatingSystem        = 'Windows'
                    userId                 = 'real-user-guid'
                    userPrincipalName      = 'user@contoso.com'
                    managedDeviceOwnerType = 'company'
                }
            }
            $result = Get-IntuneManagedDeviceContext -ManagedDeviceId 'device-1'
            $result.UserContext | Should -Be 'User'
            $result.UserId | Should -Be 'real-user-guid'
        }
    }
}

Describe 'Get-EntraDeviceContext duplicate-object disambiguation' {

    It 'a single matching Entra device object => Resolved directly' {
        InModuleScope CoverageAnalyzer {
            Mock Invoke-GraphPagedRequest {
                @([PSCustomObject]@{ id = 'obj-1'; deviceId = 'aad-1'; displayName = 'DEV1' })
            }
            $result = Get-EntraDeviceContext -AzureADDeviceId 'aad-1' -PrimaryUserId 'user-1'
            $result.Status | Should -Be 'Resolved'
            $result.EntraDeviceObjectId | Should -Be 'obj-1'
        }
    }

    It 'duplicates + registeredDevices narrows to exactly one => Resolved via RegisteredDevicesCrossCheck' {
        InModuleScope CoverageAnalyzer {
            Mock Invoke-GraphPagedRequest {
                param($Uri)
                if ($Uri -match '/devices\?') {
                    @(
                        [PSCustomObject]@{ id = 'obj-1'; deviceId = 'aad-1'; displayName = 'DEV1-live'; accountEnabled = $true }
                        [PSCustomObject]@{ id = 'obj-2'; deviceId = 'aad-1'; displayName = 'DEV1-stale'; accountEnabled = $false }
                    )
                }
                elseif ($Uri -match 'registeredDevices') {
                    @([PSCustomObject]@{ id = 'obj-1'; deviceId = 'aad-1' })
                }
                else {
                    @()
                }
            }
            $result = Get-EntraDeviceContext -AzureADDeviceId 'aad-1' -PrimaryUserId 'user-1'
            $result.Status | Should -Be 'Resolved'
            $result.EntraDeviceObjectId | Should -Be 'obj-1'
            $result.ResolvedVia | Should -Be 'RegisteredDevicesCrossCheck'
            $result.Candidates.Count | Should -Be 2
        }
    }

    It 'duplicates + registeredDevices does not narrow to exactly one => stays Ambiguous, never guesses' {
        InModuleScope CoverageAnalyzer {
            Mock Invoke-GraphPagedRequest {
                param($Uri)
                if ($Uri -match '/devices\?') {
                    @(
                        [PSCustomObject]@{ id = 'obj-1'; deviceId = 'aad-1'; displayName = 'DEV1-a' }
                        [PSCustomObject]@{ id = 'obj-2'; deviceId = 'aad-1'; displayName = 'DEV1-b' }
                    )
                }
                elseif ($Uri -match 'registeredDevices') {
                    @()  # neither candidate is registered to this user
                }
                else {
                    @()
                }
            }
            $result = Get-EntraDeviceContext -AzureADDeviceId 'aad-1' -PrimaryUserId 'user-1'
            $result.Status | Should -Be 'Ambiguous'
            $result.Candidates.Count | Should -Be 2
        }
    }

    It 'duplicates + no primary user available => stays Ambiguous without attempting the cross-check' {
        InModuleScope CoverageAnalyzer {
            Mock Invoke-GraphPagedRequest {
                @(
                    [PSCustomObject]@{ id = 'obj-1'; deviceId = 'aad-1'; displayName = 'DEV1-a' }
                    [PSCustomObject]@{ id = 'obj-2'; deviceId = 'aad-1'; displayName = 'DEV1-b' }
                )
            }
            $result = Get-EntraDeviceContext -AzureADDeviceId 'aad-1' -PrimaryUserId '00000000-0000-0000-0000-000000000000'
            $result.Status | Should -Be 'Ambiguous'
        }
    }

    It 'duplicates + the registeredDevices cross-check itself fails => falls back to Ambiguous, never throws' {
        InModuleScope CoverageAnalyzer {
            Mock Invoke-GraphPagedRequest {
                param($Uri)
                if ($Uri -match '/devices\?') {
                    @(
                        [PSCustomObject]@{ id = 'obj-1'; deviceId = 'aad-1'; displayName = 'DEV1-a' }
                        [PSCustomObject]@{ id = 'obj-2'; deviceId = 'aad-1'; displayName = 'DEV1-b' }
                    )
                }
                elseif ($Uri -match 'registeredDevices') {
                    throw 'simulated 403 - Application permissions are not supported for this endpoint'
                }
                else {
                    @()
                }
            }
            $result = Get-EntraDeviceContext -AzureADDeviceId 'aad-1' -PrimaryUserId 'user-1'
            $result.Status | Should -Be 'Ambiguous'
        }
    }
}
