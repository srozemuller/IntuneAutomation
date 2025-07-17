 # SYNOPSIS
# This PowerShell script compares two Microsoft Intune security baseline policies and generates a detailed report 
# highlighting their differences, similarities, and unique settings. It supports output in Console, CSV, or HTML formats.
#
# More information about this script can be found at: https://rozemuller.com/automated-intune-security-baseline-comparisons-with-powershell/
#
# DESCRIPTION
# The script connects to the Microsoft Graph API to retrieve the full details of the specified Intune security baseline 
# policies, including their settings and metadata. It parses the settings, compares them, and generates a structured 
# report in the desired format. This tool is ideal for administrators managing Intune security baselines, enabling 
# efficient comparison and informed decision-making.
#
# PARAMETERS
# -PolicyName [string] (Mandatory)
#   The name of the first Intune security baseline policy to compare.
#
# -ComparePolicyName [string] (Mandatory)
#   The name of the second Intune security baseline policy to compare.
#
# -OutputType [string] (Optional, Default: "Console")
#   Specifies the format of the output report. Valid values are:
#     - "Console": Displays the report in the terminal.
#     - "Csv": Exports the report to a CSV file.
#     - "Html": Generates an interactive HTML report.
#
# -OutputPath [string] (Optional, Default: ".\BaselineComparisonReport")
#   The file path where the report will be saved (for CSV or HTML output).
#
# EXAMPLES
# Example 1: Compare two policies and display the report in the console.
#   ```powershell
#   .\compare-baselines.ps1 -PolicyName "Baseline1" -ComparePolicyName "Baseline2" -OutputType "Console"
#   ```
#
# Example 2: Compare two policies and export the report to a CSV file.
#   ```powershell
#   .\compare-baselines.ps1 -PolicyName "Baseline1" -ComparePolicyName "Baseline2" -OutputType "Csv" -OutputPath "C:\Reports\BaselineComparison"
#   ```
#
# Example 3: Compare two policies and generate an HTML report.
#   ```powershell
#   .\compare-baselines.ps1 -PolicyName "Baseline1" -ComparePolicyName "Baseline2" -OutputType "Html" -OutputPath "C:\Reports\BaselineComparison"
#   ```
#
# NOTES
# - The script requires the Microsoft.Graph PowerShell module. If it is not installed, the script will attempt to install it.
# - Ensure you have the necessary permissions to access Intune policies via the Microsoft Graph API.
# - The script uses the "DeviceManagementConfiguration.Read.All" scope for authentication.
param (
  [Parameter()]
  [string]$PolicyName,

  [Parameter()]
  [string]$ComparePolicyName,

  [ValidateSet("Console", "Csv", "Html")]
  [string]$OutputType = "Console",

  [string]$OutputPath = ".\BaselineComparisonReport"
)
# Make sure Microsoft.Graph is installed and imported

try {
  Import-Module Microsoft.Graph
} catch {
  Write-Host "Microsoft.Graph module not found. Installing..." -ForegroundColor Yellow
  Install-Module Microsoft.Graph -Scope CurrentUser -Force -AllowClobber
  Import-Module Microsoft.Graph
}

function Get-SettingsFromJson {
  param (
    [Parameter(Mandatory)]
    [object]$pathObject
  )

  $json = if ($pathObject -is [string]) {
    Get-Content -Path $pathObject -Raw | ConvertFrom-Json
  }
  else {
    $pathObject
  }

  $script:results = @()

  function Parse-SettingInstance {
    param (
      [object]$setting,
      [object[]]$definitions,
      [string]$parent = ""
    )

    $instance = $setting.settingInstance
    $type = $instance.'@odata.type'
    $definition = $definitions | Where-Object { $_.id -eq $instance.settingDefinitionId }

    switch ($type) {
      # Choice Setting
      "#microsoft.graph.deviceManagementConfigurationChoiceSettingInstance" {
        $selectedValue = $instance.choiceSettingValue.value
        $selectedLabel = ($definition.options | Where-Object { $_.itemId -eq $selectedValue }).displayName
        $defaultOption = $definition.defaultOptionId
        $isDefault = ($selectedValue -eq $defaultOption)
        $defaultLabel = ($definition.options | Where-Object { $_.itemId -eq $defaultOption }).displayName

        $script:results += [PSCustomObject]@{
          Id                  = $setting.id
          SettingId           = $instance.settingDefinitionId
          DisplayName         = $definition.displayName
          HelpText            = $definition.helpText
          Description         = $definition.description
          SettingType         = "Choice"
          SelectedOption      = $selectedValue
          SelectedOptionLabel = $selectedLabel
          DefaultOption       = $defaultOption
          DefaultOptionLabel  = $defaultLabel
          IsDefault           = $isDefault
          Parent              = $parent
        }

        # Recurse into children if present
        foreach ($child in $instance.choiceSettingValue.children) {
          Parse-SettingInstance -setting @{ settingInstance = $child } -definitions $definitions -parent $instance.settingDefinitionId
        }
      }

      # Simple Setting Collection
      "#microsoft.graph.deviceManagementConfigurationSimpleSettingCollectionInstance" {
        $values = $instance.simpleSettingCollectionValue | ForEach-Object { $_.value }
        $valueLabel = ($values -join ', ')

        $script:results += [PSCustomObject]@{
          Id                  = $setting.id
          SettingId           = $instance.settingDefinitionId
          DisplayName         = $definition.displayName
          HelpText            = $definition.helpText
          Description         = $definition.description
          SettingType         = "SimpleCollection"
          SelectedOption      = $valueLabel
          SelectedOptionLabel = $valueLabel
          DefaultOption       = "-"
          DefaultOptionLabel  = "-"
          IsDefault           = $false
          Parent              = $parent
        }
      }

      # Simple Setting
      "#microsoft.graph.deviceManagementConfigurationSimpleSettingInstance" {
        $value = $instance.simpleSettingValue.value

        $script:results += [PSCustomObject]@{
          Id                  = $setting.id
          SettingId           = $instance.settingDefinitionId
          DisplayName         = $definition.displayName
          HelpText            = $definition.helpText
          Description         = $definition.description
          SettingType         = "Simple"
          SelectedOption      = $value
          SelectedOptionLabel = $value
          DefaultOption       = "-"
          DefaultOptionLabel  = "-"
          IsDefault           = $false
          Parent              = $parent
        }
      }

      # Group Collection
      "#microsoft.graph.deviceManagementConfigurationGroupSettingCollectionInstance" {
        foreach ($entry in $instance.groupSettingCollectionValue) {
          foreach ($child in $entry.children) {
            Parse-SettingInstance -setting @{ settingInstance = $child } -definitions $definitions -parent $instance.settingDefinitionId
          }
        }
      }
      # Choice Setting Collection
        "#microsoft.graph.deviceManagementConfigurationChoiceSettingCollectionInstance" {
            foreach ($entry in $instance.choiceSettingCollectionValue) {
                $selectedValue = $entry.value
                $selectedLabel = ($definition.options | Where-Object { $_.itemId -eq $selectedValue }).displayName
                $defaultOption = $definition.defaultOptionId
                $isDefault = ($selectedValue -eq $defaultOption)
                $defaultLabel = ($definition.options | Where-Object { $_.itemId -eq $defaultOption }).displayName

                $script:results += [PSCustomObject]@{
                    Id                  = $setting.id
                    SettingId           = $instance.settingDefinitionId
                    DisplayName         = $definition.displayName
                    HelpText            = $definition.helpText
                    Description         = $definition.description
                    SettingType         = "ChoiceCollection"
                    SelectedOption      = $selectedValue
                    SelectedOptionLabel = $selectedLabel
                    DefaultOption       = $defaultOption
                    DefaultOptionLabel  = $defaultLabel
                    IsDefault           = $isDefault
                    Parent              = $parent
                }

                foreach ($child in $entry.children) {
                    Parse-SettingInstance -setting @{ settingInstance = $child } -definitions $definitions -parent $instance.settingDefinitionId
                }
            }
        }
      # Choice Setting Collection
      "#microsoft.graph.deviceManagementConfigurationChoiceSettingCollectionInstance" {
        foreach ($entry in $instance.choiceSettingCollectionValue) {
          $selectedValue = $entry.value
          $selectedLabel = ($definition.options | Where-Object { $_.itemId -eq $selectedValue }).displayName
          $defaultOption = $definition.defaultOptionId
          $isDefault = ($selectedValue -eq $defaultOption)
          $defaultLabel = ($definition.options | Where-Object { $_.itemId -eq $defaultOption }).displayName

          $script:results += [PSCustomObject]@{
            Id                  = $setting.id
            SettingId           = $instance.settingDefinitionId
            DisplayName         = $definition.displayName
            HelpText            = $definition.helpText
            Description         = $definition.description
            SettingType         = "ChoiceCollection"
            SelectedOption      = $selectedValue
            SelectedOptionLabel = $selectedLabel
            DefaultOption       = $defaultOption
            DefaultOptionLabel  = $defaultLabel
            IsDefault           = $isDefault
            Parent              = $parent
          }

          # Process children if available
          if ($entry.children) {
            foreach ($child in $entry.children) {
              Parse-SettingInstance -setting @{ settingInstance = $child } -definitions $definitions -parent $instance.settingDefinitionId
            }
          }
        }
      }
      default {
        Write-Warning "⚠ Unsupported setting type: $type"
      }
    }
  }

  foreach ($setting in $json.settings) {
    Parse-SettingInstance -setting $setting -definitions $setting.settingDefinitions
  }

  return $results
}



function Compare-Baselines($baseline1, $baseline2) {
  $report = @()

  foreach ($setting1 in $baseline1) {
    $setting2 = $baseline2 | Where-Object { $_.SettingId -eq $setting1.SettingId }

    if ($null -eq $setting2) {
      $report += [PSCustomObject]@{
        SettingId       = $setting1.SettingId
        DisplayName     = $setting1.DisplayName
        HelpText        = $setting1.HelpText
        Description     = $setting1.Description
        Status          = "Only in Baseline1"
        Baseline1_Value     = $setting1.SelectedOptionLabel
        Baseline2_Value     = "-"
        Baseline1_IsDefault = $setting1.IsDefault
        Baseline2_IsDefault = "-"
        Explanation     = "Setting only exists in Baseline 1"
      }
    }
    elseif ($setting1.SelectedOption -ne $setting2.SelectedOption) {
      $report += [PSCustomObject]@{
        SettingId       = $setting1.SettingId
        DisplayName     = $setting1.DisplayName
        HelpText        = $setting1.HelpText
        Description     = $setting1.Description
        Status          = "Different"
        Baseline1_Value     = $setting1.SelectedOptionLabel
        Baseline2_Value     = $setting2.SelectedOptionLabel
        Baseline1_IsDefault = $setting1.IsDefault
        Baseline2_IsDefault = $setting2.IsDefault
        Explanation     = "Selected options differ"
      }
    }
    else {
      $report += [PSCustomObject]@{
        SettingId       = $setting1.SettingId
        DisplayName     = $setting1.DisplayName
        HelpText        = $setting1.HelpText
        Description     = $setting1.Description
        Status          = "Same"
        Baseline1_Value     = $setting1.SelectedOptionLabel
        Baseline2_Value     = $setting2.SelectedOptionLabel
        Baseline1_IsDefault = $setting1.IsDefault
        Baseline2_IsDefault = $setting2.IsDefault
        Explanation     = "Values match"
      }
    }
  }

  foreach ($setting2 in $baseline2) {
    if (-not ($baseline1 | Where-Object { $_.SettingId -eq $setting2.SettingId })) {
      $report += [PSCustomObject]@{
        SettingId       = $setting2.SettingId
        DisplayName     = $setting2.DisplayName
        HelpText        = $setting2.HelpText
        Description     = $setting2.Description
        Status          = "Only in Baseline2"
        Baseline1_Value     = "-"
        Baseline2_Value     = $setting2.SelectedOptionLabel
        Baseline1_IsDefault = "-"
        Baseline2_IsDefault = $setting2.IsDefault
        Explanation     = "Setting only exists in Baseline 2"
      }
    }
  }

  return $report
}

function Export-HtmlReport {
  param (
    [Parameter(Mandatory)]
    $report,
    [string]$path = "./BaselineComparisonReport",
    [Parameter(Mandatory)]
    [object]$Policy1Meta,
    [Parameter(Mandatory)]
    [object]$Policy2Meta
  )
  $groups = $report | Group-Object Status
  $modals = ""
  $groupTables = ""
  $modalCounter = 0

  # Count totals
  $counts = $report | Group-Object -Property Status
  $total = $report.Count
  $diffCount = ($counts | Where-Object { $_.Name -eq 'Different' }).Count
  $Baseline1Count = ($counts | Where-Object { $_.Name -eq 'Only in Baseline1' }).Count
  $Baseline2Count = ($counts | Where-Object { $_.Name -eq 'Only in Baseline2' }).Count
  $sameCount = ($counts | Where-Object { $_.Name -eq 'Same' }).Count

  $summaryBadge = @"
<div class='mt-2 mb-6 text-sm font-medium text-green-700 bg-green-100 border border-green-300 rounded px-4 py-2'>
  Compared $total settings |
  $diffCount different |
  $Baseline1Count only in Baseline1 |
  $Baseline2Count only in Baseline2 |
  $sameCount same
</div>
"@
  foreach ($group in $groups) {
    $groupName = $group.Name
    $rows = ""

    foreach ($entry in $group.Group) {
      $modalId = "modal$modalCounter"
      $rows += @"
<tr>
  <td class='border px-3 py-2 text-blue-600 underline cursor-pointer' onclick="openModal('$modalId')">$($entry.DisplayName)</td>
  <td class='border px-3 py-2'>$($entry.Baseline1_Value)</td>
  <td class='border px-3 py-2'>$($entry.Baseline2_Value)</td>
  <td class='border px-3 py-2'>$($entry.Baseline1_IsDefault)</td>
  <td class='border px-3 py-2'>$($entry.Baseline2_IsDefault)</td>
  <td class='border px-3 py-2'>$($entry.Explanation)</td>
</tr>
"@

      $modals += @"
<div id='$modalId' class='modal'>
  <div class='modal-content'>
    <span class='close' onclick="closeModal('$modalId')">&times;</span>
    <h2>$($entry.DisplayName)</h2>
    <p><strong>SettingId:</strong> $($entry.SettingId)</p>
    <p><strong>Description:</strong> $($entry.Description)</p>
    <p><strong>HelpText:</strong> $($entry.HelpText)</p>
    <p><strong>Baseline1 Value:</strong> $($entry.Baseline1_Value) (Default: $($entry.Baseline1_IsDefault))</p>
    <p><strong>Baseline2 Value:</strong> $($entry.Baseline2_Value) (Default: $($entry.Baseline2_IsDefault))</p>
    <p><strong>Status:</strong> $($entry.Status)</p>
    <p><strong>Explanation:</strong> $($entry.Explanation)</p>
  </div>
</div>
"@
      $modalCounter++
    }

    $summaryBadge

    $groupTables += @"
<h2 class='text-xl font-semibold mt-8 mb-2'>$groupName</h2>
<div class='overflow-x-auto rounded-md border border-border bg-card'>
<table class='w-full text-sm text-left'>
  <thead class='bg-muted text-muted-foreground'>
    <tr>
      <th class='border px-3 py-2'>DisplayName</th>
      <th class='border px-3 py-2'>Baseline1 Value</th>
      <th class='border px-3 py-2'>Baseline2 Value</th>
      <th class='border px-3 py-2'>Baseline1 Is Default</th>
      <th class='border px-3 py-2'>Baseline2 Is Default</th>
      <th class='border px-3 py-2'>Explanation</th>
    </tr>
  </thead>
  <tbody>
    $rows
  </tbody>
</table>
</div>
"@
  }

  $html = @"
<!DOCTYPE html>
<html lang='en' data-theme='light'>
<head>
  <meta charset='UTF-8'>
  <title>Baseline Comparison Report</title>
  <style>
    :root {
      --bg: #f9fafb;
      --text: #111827;
      --card: #ffffff;
      --border: #e5e7eb;
      --muted: #f3f4f6;
      --muted-foreground: #6b7280;
    }

    [data-theme='dark'] {
      --bg: #0f172a;
      --text: #f1f5f9;
      --card: #1e293b;
      --border: #334155;
      --muted: #1e293b;
      --muted-foreground: #cbd5e1;
    }

    body {
      font-family: 'Segoe UI', sans-serif;
      background-color: var(--bg);
      color: var(--text);
      margin: 0;
      padding: 2rem;
    }

    h1 {
      font-size: 1.75rem;
      font-weight: 600;
      margin-bottom: 2rem;
      text-align: center;
    }

    table {
      width: 100%;
      border-collapse: collapse;
      table-layout: auto;
      background-color: var(--card);
    }

    th, td {
      padding: 0.75rem;
      border: 1px solid var(--border);
      text-align: left;
      vertical-align: top;
    }

    th {
      background-color: var(--muted);
      color: var(--muted-foreground);
    }

    tr:hover {
      background-color: rgba(255, 255, 0, 0.1);
    }

    .modal {
      display: none;
      position: fixed;
      z-index: 1000;
      padding-top: 60px;
      left: 0;
      top: 0;
      width: 100%;
      height: 100%;
      overflow: auto;
      background-color: rgba(0,0,0,0.6);
    }

    .modal-content {
      background-color: var(--card);
      color: var(--text);
      margin: auto;
      padding: 20px;
      border: 1px solid var(--border);
      width: 60%;
      border-radius: 12px;
    }

    .close {
      color: var(--muted-foreground);
      float: right;
      font-size: 28px;
      font-weight: bold;
    }

    .close:hover {
      color: red;
      cursor: pointer;
    }

    .toggle-darkmode {
      position: fixed;
      top: 1rem;
      right: 1rem;
      background: var(--card);
      color: var(--text);
      border: 1px solid var(--border);
      padding: 0.5rem 1rem;
      border-radius: 0.5rem;
      cursor: pointer;
    }
  </style>
</head>
<body>
  <button class='toggle-darkmode' onclick="toggleTheme()">Toggle Dark Mode</button>
  <h1>Intune Baseline Comparison Report</h1>

  <div class="rounded-md border p-4 bg-card mb-6">
  <p class="text-sm text-muted-foreground mb-2">Comparing the following Intune security baseline policies:</p>
  <div style="display: flex; gap: 2rem; flex-wrap: wrap;">
    <div style="flex: 1;">
      <h3 class="text-base font-semibold mb-1">Baseline 1: $($Policy1Meta.name)</h3>
      <ul class="text-sm text-muted-foreground list-disc pl-4">
        <li><strong>Platform:</strong> $($Policy1Meta.platforms)</li>
        <li><strong>Settings:</strong> $($Policy1Meta.settingCount)</li>
        <li><strong>Created:</strong> $([datetime]$Policy1Meta.createdDateTime)</li>
        <li><strong>Modified:</strong> $([datetime]$Policy1Meta.lastModifiedDateTime)</li>
        <li><strong>Description:</strong> $($Policy1Meta.description)</li>
      </ul>
    </div>
    <div style="flex: 1;">
      <h3 class="text-base font-semibold mb-1">Baseline 2: $($Policy2Meta.name)</h3>
      <ul class="text-sm text-muted-foreground list-disc pl-4">
        <li><strong>Platform:</strong> $($Policy2Meta.platforms)</li>
        <li><strong>Settings:</strong> $($Policy2Meta.settingCount)</li>
        <li><strong>Created:</strong> $([datetime]$Policy2Meta.createdDateTime)</li>
        <li><strong>Modified:</strong> $([datetime]$Policy2Meta.lastModifiedDateTime)</li>
        <li><strong>Description:</strong> $($Policy2Meta.description)</li>
      </ul>
    </div>
  </div>
</div>


  $groupTables

  $modals

  <script>
    function openModal(id) {
      document.getElementById(id).style.display = 'block';
    }

    function closeModal(id) {
      document.getElementById(id).style.display = 'none';
    }

    function toggleTheme() {
      const root = document.documentElement;
      const current = root.getAttribute('data-theme');
      root.setAttribute('data-theme', current === 'light' ? 'dark' : 'light');
    }

    // Auto-detect dark mode
    if (window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches) {
      document.documentElement.setAttribute('data-theme', 'dark');
    }
  </script>
</body>
</html>
"@

  $file = "$path.html"
  Set-Content -Path $file -Value $html -Encoding UTF8
  Write-Host " HTML report created: $file"
}


# PROCESS


function Get-PolicyAndConvertToJson {
  param (
    [Parameter(Mandatory)]
    [string]$Name
  )

  # TemplateId filter for Baseline family
  $filter = @"
(templateReference/TemplateId eq '66df8dce-0166-4b82-92f7-1f74e3ca17a3_1' or 
 templateReference/TemplateId eq '66df8dce-0166-4b82-92f7-1f74e3ca17a3_3' or 
 templateReference/TemplateId eq '66df8dce-0166-4b82-92f7-1f74e3ca17a3_4') 
 and templateReference/TemplateFamily eq 'Baseline'
"@ -replace "`r`n", ""

  $encodedFilter = [System.Web.HttpUtility]::UrlEncode($filter)
  $uri = "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies?`$filter=$encodedFilter"
  $response = Invoke-MgGraphRequest -Method GET -Uri $uri

  # Find policy by name (case-insensitive)
  $policy = $response.value | Where-Object { $_.name -ieq $Name }

  if (-not $policy) {
    throw "Policy with name '$Name' not found in baseline search."
  }

  Write-Host "Found policy '$($policy.name)' with id $($policy.id)" -ForegroundColor Green

  # Fetch full policy with expanded fields
  $fullUri = "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies/$($policy.id)" +
  "?`$expand=assignments,settings(`$expand=settingDefinitions)"

  $fullResponse = Invoke-MgGraphRequest -Method GET -Uri $fullUri
  return $fullResponse
}


# Connect & setup profile (if not already done)
Connect-MgGraph -Scopes "DeviceManagementConfiguration.Read.All"

# Fetch full policies
$baseline1 = Get-PolicyAndConvertToJson -Name $PolicyName
$baseline2 = Get-PolicyAndConvertToJson -Name $ComparePolicyName

# Continue with:
$parsed1 = Get-SettingsFromJson -pathObject $baseline1
$parsed2 = Get-SettingsFromJson -pathObject $baseline2

$diffReport = Compare-Baselines -baseline1 $parsed1 -baseline2 $parsed2

switch ($OutputType) {
  "Console" { $diffReport | Format-Table -AutoSize }
  "Csv" { $diffReport | Export-Csv -Path "$OutputPath.csv" -NoTypeInformation; Write-Host "CSV report saved to $OutputPath.csv" }
  "Html" {
    Export-HtmlReport -report $diffReport -path "./Report" `
      -Policy1Meta $baseline1 -Policy2Meta $baseline2 
  }
}
