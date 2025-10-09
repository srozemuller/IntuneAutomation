<#
.SYNOPSIS
    Monitor disk space across all Intune-managed devices and generate an HTML report.

.DESCRIPTION
    This script retrieves storage information from all Intune-managed devices using Microsoft Graph API,
    calculates storage metrics, and generates a comprehensive HTML report with visual indicators for
    storage health status.

.PARAMETER OutputPath
    The path where the HTML report will be saved. Default is "./IntuneStorageReport.html"

.PARAMETER CriticalThreshold
    Percentage of free space below which a device is marked as Critical. Default is 10%

.PARAMETER WarningThreshold
    Percentage of free space below which a device is marked as Warning. Default is 20%

.PARAMETER UseParallelProcessing
    Enable parallel processing for faster data collection in large environments

.EXAMPLE
    .\Monitor-IntuneDiskSpace.ps1
    
.EXAMPLE
    .\Monitor-IntuneDiskSpace.ps1 -OutputPath "C:\Reports\Storage.html" -CriticalThreshold 5 -WarningThreshold 15

.EXAMPLE
    .\Monitor-IntuneDiskSpace.ps1 -UseParallelProcessing

.NOTES
    Author: Based on rozemuller.com automation style
    Requires: Microsoft.Graph PowerShell module
    Required Permissions: DeviceManagementManagedDevices.Read.All
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$OutputPath = "./IntuneStorageReport.html",
    
    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 50)]
    [int]$CriticalThreshold = 10,
    
    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 50)]
    [int]$WarningThreshold = 20,
    
    [Parameter(Mandatory = $false)]
    [switch]$UseParallelProcessing
)

#Requires -Modules Microsoft.Graph.Authentication

# Function to get all managed devices with pagination support
function Get-ManagedDevices {
    <#
    .SYNOPSIS
        Retrieves all managed devices from Intune with automatic pagination handling.
    #>
    
    Write-Host "Retrieving managed devices from Intune..." -ForegroundColor Cyan
    
    $uri = "https://graph.microsoft.com/beta/deviceManagement/managedDevices"
    $devices = @()
    
    do {
        try {
            $response = Invoke-MgGraphRequest -Method GET -Uri $uri
            $devices += $response.value
            $uri = $response.'@odata.nextLink'
            
            if ($uri) {
                Write-Verbose "Retrieved $($devices.Count) devices so far, fetching next page..."
            }
        }
        catch {
            Write-Error "Failed to retrieve managed devices: $_"
            throw
        }
    } while ($uri)
    
    Write-Host "Found $($devices.Count) managed devices" -ForegroundColor Green
    return $devices
}

# Function to get detailed hardware information for a specific device
function Get-DeviceHardwareInfo {
    <#
    .SYNOPSIS
        Retrieves detailed hardware information including storage metrics for a specific device.
    #>
    
    param (
        [Parameter(Mandatory = $true)]
        [string]$DeviceId
    )
    
    # Select only the properties we need to optimize API calls
    $selectProperties = @(
        "id",
        "deviceName",
        "managedDeviceName",
        "operatingSystem",
        "osVersion",
        "lastSyncDateTime",
        "hardwareInformation",
        "ethernetMacAddress",
        "processorArchitecture",
        "physicalMemoryInBytes"
    ) -join ","
    
    $uri = "https://graph.microsoft.com/beta/deviceManagement/managedDevices('$DeviceId')?`$select=$selectProperties"
    
    try {
        $response = Invoke-MgGraphRequest -Method GET -Uri $uri
        return $response
    }
    catch {
        Write-Warning "Failed to retrieve hardware info for device $DeviceId : $_"
        return $null
    }
}

# Function to calculate storage metrics from device data
function Get-StorageMetrics {
    <#
    .SYNOPSIS
        Processes device hardware information and calculates storage metrics.
    #>
    
    param (
        [Parameter(Mandatory = $true)]
        [object]$Device,
        
        [Parameter(Mandatory = $true)]
        [int]$CriticalThreshold,
        
        [Parameter(Mandatory = $true)]
        [int]$WarningThreshold
    )
    
    $hardwareInfo = $Device.hardwareInformation
    
    # Check if storage information is available
    if ($null -eq $hardwareInfo.totalStorageSpace -or $hardwareInfo.totalStorageSpace -eq 0) {
        return [PSCustomObject]@{
            DeviceId          = $Device.id
            DeviceName        = $Device.deviceName
            ManagedDeviceName = $Device.managedDeviceName
            OperatingSystem   = $Device.operatingSystem
            OSVersion         = $Device.osVersion
            Manufacturer      = $hardwareInfo.manufacturer
            Model             = $hardwareInfo.model
            SerialNumber      = $hardwareInfo.serialNumber
            TotalStorageGB    = "N/A"
            FreeStorageGB     = "N/A"
            UsedStorageGB     = "N/A"
            FreePercentage    = "N/A"
            UsedPercentage    = "N/A"
            StorageStatus     = "Unknown"
            LastSync          = $Device.lastSyncDateTime
        }
    }
    
    # Convert bytes to GB (divide by 1024^3)
    $totalGB = [math]::Round($hardwareInfo.totalStorageSpace / 1GB, 2)
    $freeGB = [math]::Round($hardwareInfo.freeStorageSpace / 1GB, 2)
    $usedGB = [math]::Round(($hardwareInfo.totalStorageSpace - $hardwareInfo.freeStorageSpace) / 1GB, 2)
    
    # Calculate percentages
    $freePercent = [math]::Round(($hardwareInfo.freeStorageSpace / $hardwareInfo.totalStorageSpace) * 100, 2)
    $usedPercent = [math]::Round(100 - $freePercent, 2)
    
    # Determine storage status based on thresholds
    $status = switch ($freePercent) {
        { $_ -lt $CriticalThreshold } { "Critical" }
        { $_ -lt $WarningThreshold } { "Warning" }
        default { "Healthy" }
    }
    
    return [PSCustomObject]@{
        DeviceId          = $Device.id
        DeviceName        = $Device.deviceName
        ManagedDeviceName = $Device.managedDeviceName
        OperatingSystem   = $Device.operatingSystem
        OSVersion         = $Device.osVersion
        Manufacturer      = $hardwareInfo.manufacturer
        Model             = $hardwareInfo.model
        SerialNumber      = $hardwareInfo.serialNumber
        TotalStorageGB    = $totalGB
        FreeStorageGB     = $freeGB
        UsedStorageGB     = $usedGB
        FreePercentage    = $freePercent
        UsedPercentage    = $usedPercent
        StorageStatus     = $status
        LastSync          = $Device.lastSyncDateTime
    }
}

# Function to generate HTML report with shadcn styling
function Export-StorageReport {
    <#
    .SYNOPSIS
        Generates an HTML report with storage information for all devices using shadcn design patterns.
    #>
    
    param (
        [Parameter(Mandatory = $true)]
        [array]$DeviceData,
        
        [Parameter(Mandatory = $true)]
        [string]$OutputPath,
        
        [Parameter(Mandatory = $true)]
        [int]$CriticalThreshold,
        
        [Parameter(Mandatory = $true)]
        [int]$WarningThreshold
    )
    
    Write-Host "Generating HTML report..." -ForegroundColor Cyan
    
    # Calculate summary statistics
    $criticalCount = ($DeviceData | Where-Object { $_.StorageStatus -eq "Critical" }).Count
    $warningCount = ($DeviceData | Where-Object { $_.StorageStatus -eq "Warning" }).Count
    $healthyCount = ($DeviceData | Where-Object { $_.StorageStatus -eq "Healthy" }).Count
    $unknownCount = ($DeviceData | Where-Object { $_.StorageStatus -eq "Unknown" }).Count
    $totalDevices = $DeviceData.Count
    
    # Sort devices: Critical first, then Warning, then Healthy, then Unknown
    $sortedData = $DeviceData | Sort-Object @{
        Expression = {
            switch ($_.StorageStatus) {
                "Critical" { 1 }
                "Warning" { 2 }
                "Healthy" { 3 }
                "Unknown" { 4 }
            }
        }
    }, DeviceName
    
    # Convert device data to JSON with proper escaping for HTML embedding
    $devicesJsonData = $sortedData | ForEach-Object {
        @{
            DeviceId = $_.DeviceId
            DeviceName = $_.DeviceName
            ManagedDeviceName = $_.ManagedDeviceName
            OperatingSystem = $_.OperatingSystem
            OSVersion = $_.OSVersion
            Manufacturer = $_.Manufacturer
            Model = $_.Model
            SerialNumber = $_.SerialNumber
            TotalStorageGB = $_.TotalStorageGB
            FreeStorageGB = $_.FreeStorageGB
            UsedStorageGB = $_.UsedStorageGB
            FreePercentage = $_.FreePercentage
            UsedPercentage = $_.UsedPercentage
            StorageStatus = $_.StorageStatus
            LastSync = $_.LastSync
        }
    }
    
    # Convert to JSON and properly escape for embedding in HTML/JavaScript
    $jsonString = $devicesJsonData | ConvertTo-Json -Depth 10 -Compress
    # Escape backslashes first, then single quotes, then handle newlines
    $jsonString = $jsonString -replace '\\', '\\'
    $jsonString = $jsonString -replace "'", "\'"
    $jsonString = $jsonString -replace "`n", '\n'
    $jsonString = $jsonString -replace "`r", '\r'
    
    # Generate table rows server-side with simple data attributes
    $tableRows = foreach ($device in $sortedData) {
        $badgeClass = switch ($device.StorageStatus) {
            "Critical" { "badge-critical" }
            "Warning" { "badge-warning" }
            "Healthy" { "badge-healthy" }
            default { "badge-unknown" }
        }
        
        $progressClass = switch ($device.StorageStatus) {
            "Critical" { "progress-critical" }
            "Warning" { "progress-warning" }
            default { "progress-healthy" }
        }
        
        $usedPercent = if ($device.UsedPercentage -eq "N/A") { 0 } else { $device.UsedPercentage }
        $freePercentNum = if ($device.FreePercentage -eq "N/A") { 0 } else { [double]$device.FreePercentage }
        
        # Escape data for attributes
        $safeName = ($device.DeviceName -replace '"', '&quot;' -replace "'", '&apos;')
        $safeOS = ($device.OperatingSystem -replace '"', '&quot;' -replace "'", '&apos;')
        $safeStatus = ($device.StorageStatus -replace '"', '&quot;' -replace "'", '&apos;')
        
        # Convert device data to JSON for row attributes
        $deviceJson = $device | ConvertTo-Json -Compress -Depth 3
        $deviceJson = $deviceJson -replace '"', '&quot;' -replace "'", '&apos;'
        
        @"
                        <tr data-name="$safeName" data-os="$safeOS" data-status="$safeStatus" data-freepercent="$freePercentNum" data-device="$deviceJson">
                            <td>$($device.DeviceName)</td>
                            <td>$($device.OperatingSystem)</td>
                            <td>$($device.Manufacturer)</td>
                            <td>$($device.Model)</td>
                            <td>$($device.TotalStorageGB) GB</td>
                            <td>$($device.FreeStorageGB) GB</td>
                            <td>$($device.UsedStorageGB) GB</td>
                            <td>
                                <div>$($device.FreePercentage)%</div>
                                <div class="progress-bar">
                                    <div class="progress-fill $progressClass" style="width: $usedPercent%"></div>
                                </div>
                            </td>
                            <td><span class="badge $badgeClass">$($device.StorageStatus)</span></td>
                            <td>$($device.LastSync)</td>
                        </tr>
"@
    }
    
    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Intune Device Storage Report</title>
    <style>
        :root {
            --background: 0 0% 100%;
            --foreground: 222.2 84% 4.9%;
            --card: 0 0% 100%;
            --card-foreground: 222.2 84% 4.9%;
            --primary: 221.2 83.2% 53.3%;
            --primary-foreground: 210 40% 98%;
            --secondary: 210 40% 96.1%;
            --secondary-foreground: 222.2 47.4% 11.2%;
            --muted: 210 40% 96.1%;
            --muted-foreground: 215.4 16.3% 46.9%;
            --accent: 210 40% 96.1%;
            --accent-foreground: 222.2 47.4% 11.2%;
            --destructive: 0 84.2% 60.2%;
            --destructive-foreground: 210 40% 98%;
            --border: 214.3 31.8% 91.4%;
            --input: 214.3 31.8% 91.4%;
            --ring: 221.2 83.2% 53.3%;
            --radius: 0.5rem;
        }
        
        * {
            box-sizing: border-box;
        }
        
        body {
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
            margin: 0;
            padding: 0;
            background-color: hsl(var(--background));
            color: hsl(var(--foreground));
            line-height: 1.5;
        }
        
        .container {
            max-width: 1800px;
            margin: 0 auto;
            padding: 2rem;
        }
        
        .header {
            margin-bottom: 2rem;
        }
        
        h1 {
            font-size: 2.5rem;
            font-weight: 700;
            margin: 0 0 0.5rem 0;
            color: hsl(var(--foreground));
        }
        
        .subtitle {
            color: hsl(var(--muted-foreground));
            font-size: 1rem;
        }
        
        .card {
            background-color: hsl(var(--card));
            border: 1px solid hsl(var(--border));
            border-radius: var(--radius);
            padding: 1.5rem;
            box-shadow: 0 1px 3px 0 rgb(0 0 0 / 0.1), 0 1px 2px -1px rgb(0 0 0 / 0.1);
        }
        
        .card-header {
            margin-bottom: 1rem;
        }
        
        .card-title {
            font-size: 1.25rem;
            font-weight: 600;
            margin: 0;
        }
        
        .card-description {
            color: hsl(var(--muted-foreground));
            font-size: 0.875rem;
            margin: 0.25rem 0 0 0;
        }
        
        .stats-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
            gap: 1.5rem;
            margin-bottom: 2rem;
        }
        
        .stat-card {
            background-color: hsl(var(--card));
            border: 1px solid hsl(var(--border));
            border-radius: var(--radius);
            padding: 1.5rem;
            box-shadow: 0 1px 3px 0 rgb(0 0 0 / 0.1), 0 1px 2px -1px rgb(0 0 0 / 0.1);
            transition: transform 0.2s, box-shadow 0.2s;
        }
        
        .stat-card:hover {
            transform: translateY(-2px);
            box-shadow: 0 4px 6px -1px rgb(0 0 0 / 0.1), 0 2px 4px -2px rgb(0 0 0 / 0.1);
        }
        
        .stat-header {
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 0.5rem;
        }
        
        .stat-label {
            color: hsl(var(--muted-foreground));
            font-size: 0.875rem;
            font-weight: 500;
        }
        
        .stat-icon {
            width: 1.25rem;
            height: 1.25rem;
            opacity: 0.5;
        }
        
        .stat-value {
            font-size: 2rem;
            font-weight: 700;
            margin: 0;
        }
        
        .stat-total { color: #60a5fa; }
        .stat-healthy { color: #4ade80; }
        .stat-warning { color: #facc15; }
        .stat-critical { color: #f87171; }
        .stat-unknown { color: #94a3b8; }
        
        .filters {
            margin-bottom: 1.5rem;
        }
        
        .filters-content {
            display: flex;
            flex-wrap: wrap;
            gap: 1rem;
            align-items: end;
        }
        
        .filter-group {
            display: flex;
            flex-direction: column;
            gap: 0.5rem;
            flex: 1;
            min-width: 200px;
        }
        
        .filter-label {
            font-size: 0.875rem;
            font-weight: 500;
            color: hsl(var(--foreground));
        }
        
        .input, .select {
            width: 100%;
            padding: 0.5rem 0.75rem;
            border: 1px solid hsl(var(--input));
            border-radius: calc(var(--radius) - 2px);
            background-color: hsl(var(--background));
            font-size: 0.875rem;
            transition: border-color 0.2s, box-shadow 0.2s;
        }
        
        .input:focus, .select:focus {
            outline: none;
            border-color: hsl(var(--ring));
            box-shadow: 0 0 0 3px hsl(var(--ring) / 0.1);
        }
        
        .button {
            padding: 0.5rem 1rem;
            border: none;
            border-radius: calc(var(--radius) - 2px);
            font-size: 0.875rem;
            font-weight: 500;
            cursor: pointer;
            transition: background-color 0.2s, transform 0.1s;
        }
        
        .button:hover {
            transform: translateY(-1px);
        }
        
        .button:active {
            transform: translateY(0);
        }
        
        .button-primary {
            background-color: hsl(var(--primary));
            color: hsl(var(--primary-foreground));
        }
        
        .button-primary:hover {
            background-color: hsl(221.2 83.2% 48%);
        }
        
        .button-secondary {
            background-color: hsl(var(--secondary));
            color: hsl(var(--secondary-foreground));
        }
        
        .button-secondary:hover {
            background-color: hsl(210 40% 92%);
        }
        
        .table-container {
            overflow-x: auto;
            border: 1px solid hsl(var(--border));
            border-radius: var(--radius);
            background-color: hsl(var(--card));
        }
        
        table {
            width: 100%;
            border-collapse: collapse;
            font-size: 0.875rem;
        }
        
        thead {
            background-color: hsl(var(--muted));
            position: sticky;
            top: 0;
            z-index: 10;
        }
        
        th {
            text-align: left;
            padding: 0.75rem 1rem;
            font-weight: 600;
            color: hsl(var(--foreground));
            border-bottom: 1px solid hsl(var(--border));
        }
        
        th:hover {
            background-color: hsl(210 40% 92%);
            cursor: pointer;
        }
        
        td {
            padding: 0.75rem 1rem;
            border-bottom: 1px solid hsl(var(--border));
        }
        
        tbody tr:hover {
            background-color: hsl(var(--muted));
        }
        
        tbody tr:last-child td {
            border-bottom: none;
        }
        
        .badge {
            display: inline-flex;
            align-items: center;
            padding: 0.25rem 0.625rem;
            border-radius: 9999px;
            font-size: 0.75rem;
            font-weight: 600;
            white-space: nowrap;
        }
        
        .badge-critical {
            background-color: #fecaca;
            color: #991b1b;
        }
        
        .badge-warning {
            background-color: #fef3c7;
            color: #92400e;
        }
        
        .badge-healthy {
            background-color: #d1fae5;
            color: #065f46;
        }
        
        .badge-unknown {
            background-color: #e2e8f0;
            color: #475569;
        }
        
        .progress-bar {
            width: 100%;
            height: 0.5rem;
            background-color: hsl(var(--secondary));
            border-radius: 9999px;
            overflow: hidden;
            margin-top: 0.25rem;
        }
        
        .progress-fill {
            height: 100%;
            transition: width 0.3s;
        }
        
        .progress-critical { background-color: #f87171; }
        .progress-warning { background-color: #facc15; }
        .progress-healthy { background-color: #4ade80; }
        
        .footer {
            margin-top: 2rem;
            padding-top: 1.5rem;
            border-top: 1px solid hsl(var(--border));
            text-align: right;
            color: hsl(var(--muted-foreground));
            font-size: 0.875rem;
        }
        
        .hidden {
            display: none;
        }
        
        @media (max-width: 768px) {
            .container {
                padding: 1rem;
            }
            
            h1 {
                font-size: 1.875rem;
            }
            
            .filters-content {
                flex-direction: column;
            }
            
            .filter-group {
                width: 100%;
            }
        }
        
        @media print {
            .filters {
                display: none;
            }
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>Intune Device Storage Report</h1>
            <p class="subtitle">Monitor and manage disk space across all managed devices</p>
        </div>
        
        <div class="stats-grid">
            <div class="stat-card">
                <div class="stat-header">
                    <span class="stat-label">Total Devices</span>
                    <svg class="stat-icon" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9.75 17L9 20l-1 1h8l-1-1-.75-3M3 13h18M5 17h14a2 2 0 002-2V5a2 2 0 00-2-2H5a2 2 0 00-2 2v10a2 2 0 002 2z"/>
                    </svg>
                </div>
                <p class="stat-value stat-total" id="total-count">$totalDevices</p>
            </div>
            
            <div class="stat-card">
                <div class="stat-header">
                    <span class="stat-label">Healthy</span>
                    <svg class="stat-icon" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"/>
                    </svg>
                </div>
                <p class="stat-value stat-healthy" id="healthy-count">$healthyCount</p>
            </div>
            
            <div class="stat-card">
                <div class="stat-header">
                    <span class="stat-label">Warning</span>
                    <svg class="stat-icon" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z"/>
                    </svg>
                </div>
                <p class="stat-value stat-warning" id="warning-count">$warningCount</p>
            </div>
            
            <div class="stat-card">
                <div class="stat-header">
                    <span class="stat-label">Critical</span>
                    <svg class="stat-icon" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 8v4m0 4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"/>
                    </svg>
                </div>
                <p class="stat-value stat-critical" id="critical-count">$criticalCount</p>
            </div>
            
            <div class="stat-card">
                <div class="stat-header">
                    <span class="stat-label">Unknown</span>
                    <svg class="stat-icon" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M8.228 9c.549-1.165 2.03-2 3.772-2 2.21 0 4 1.343 4 3 0 1.4-1.278 2.575-3.006 2.907-.542.104-.994.54-.994 1.093m0 3h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"/>
                    </svg>
                </div>
                <p class="stat-value stat-unknown" id="unknown-count">$unknownCount</p>
            </div>
        </div>
        
        <div class="card filters">
            <div class="card-header">
                <h3 class="card-title">Filters</h3>
                <p class="card-description">Filter devices by status, disk space, or search by name</p>
            </div>
            <div class="filters-content">
                <div class="filter-group">
                    <label class="filter-label" for="search">Search Device</label>
                    <input type="text" id="search" class="input" placeholder="Search by device name...">
                </div>
                <div class="filter-group">
                    <label class="filter-label" for="status-filter">Status</label>
                    <select id="status-filter" class="select">
                        <option value="all">All Statuses</option>
                        <option value="Critical">Critical</option>
                        <option value="Warning">Warning</option>
                        <option value="Healthy">Healthy</option>
                        <option value="Unknown">Unknown</option>
                    </select>
                </div>
                <div class="filter-group">
                    <label class="filter-label" for="os-filter">Operating System</label>
                    <select id="os-filter" class="select">
                        <option value="all">All OS</option>
                        $(
                            # Get unique OS types
                            $uniqueOSTypes = $DeviceData | Select-Object -ExpandProperty OperatingSystem -Unique | Sort-Object
                            foreach ($os in $uniqueOSTypes) {
                                if ($os) {
                                    "<option value=""$($os -replace '"', '&quot;')"">{0}</option>" -f $os
                                }
                            }
                        )
                    </select>
                </div>
                <div class="filter-group">
                    <label class="filter-label" for="free-space-min">Min Free Space (%)</label>
                    <input type="number" id="free-space-min" class="input" placeholder="0" min="0" max="100">
                </div>
                <div class="filter-group">
                    <label class="filter-label" for="free-space-max">Max Free Space (%)</label>
                    <input type="number" id="free-space-max" class="input" placeholder="100" min="0" max="100">
                </div>
                <div class="filter-group">
                    <label class="filter-label">&nbsp;</label>
                    <button id="reset-filters" class="button button-secondary">Reset Filters</button>
                </div>
            </div>
        </div>
        
        <div class="card">
            <div class="card-header">
                <h3 class="card-title">Device Storage Details</h3>
                <p class="card-description">Click column headers to sort. Showing <span id="visible-count">$totalDevices</span> of $totalDevices devices</p>
            </div>
            <div class="table-container">
                <table id="devices-table">
                    <thead>
                        <tr>
                            <th onclick="sortTable(0)">Device Name ↕</th>
                            <th onclick="sortTable(1)">OS ↕</th>
                            <th onclick="sortTable(2)">Manufacturer ↕</th>
                            <th onclick="sortTable(3)">Model ↕</th>
                            <th onclick="sortTable(4)">Total (GB) ↕</th>
                            <th onclick="sortTable(5)">Free (GB) ↕</th>
                            <th onclick="sortTable(6)">Used (GB) ↕</th>
                            <th onclick="sortTable(7)">Free % ↕</th>
                            <th onclick="sortTable(8)">Status ↕</th>
                            <th onclick="sortTable(9)">Last Sync ↕</th>
                        </tr>
                    </thead>
                    <tbody id="devices-tbody">
                        $($tableRows -join "`n")
                    </tbody>
                </table>
            </div>
        </div>
        
        <div class="footer">
            <p>Report generated: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")</p>
            <p>Thresholds: Critical &lt; $CriticalThreshold% free | Warning &lt; $WarningThreshold% free</p>
        </div>
    </div>
    
    <script>
            // Device data embedded from PowerShell - using single quotes to avoid escaping issues
            window.deviceJsonData = '$jsonString';

            document.addEventListener('DOMContentLoaded', function() {
                console.log('DOM loaded - setting up filters');

                let devicesData = [];
                try {
                    devicesData = JSON.parse(window.deviceJsonData || '[]');
                    console.log('✓ Device data loaded successfully:', devicesData.length, 'devices');
                } catch (e) {
                    console.error('✗ Failed to parse device data:', e);
                    devicesData = [];
                }

                const searchInput = document.getElementById('search');
                const statusFilter = document.getElementById('status-filter');
                const osFilter = document.getElementById('os-filter');
                const resetButton = document.getElementById('reset-filters');
                const minFreeSpace = document.getElementById('free-space-min');
                const maxFreeSpace = document.getElementById('free-space-max');

                function filterTable() {
                    const searchTerm = searchInput.value.toLowerCase();
                    const status = statusFilter.value;
                    const os = osFilter.value;
                    const minFree = parseFloat(minFreeSpace.value) || 0;
                    const maxFree = parseFloat(maxFreeSpace.value) || 100;

                    const rows = document.querySelectorAll('#devices-tbody tr');
                    rows.forEach(row => {
                        const name = row.getAttribute('data-name').toLowerCase();
                        const rowStatus = row.getAttribute('data-status');
                        const rowOS = row.getAttribute('data-os');
                        const freePercent = parseFloat(row.getAttribute('data-freepercent'));

                        const matchesSearch = name.includes(searchTerm);
                        const matchesStatus = status === 'all' || rowStatus === status;
                        const matchesOS = os === 'all' || rowOS === os;
                        const matchesFreeSpace = freePercent >= minFree && freePercent <= maxFree;

                        row.style.display = matchesSearch && matchesStatus && matchesOS && matchesFreeSpace ? '' : 'none';
                    });
                }

                function resetFilters() {
                    searchInput.value = '';
                    statusFilter.value = 'all';
                    osFilter.value = 'all';
                    minFreeSpace.value = '';
                    maxFreeSpace.value = '';
                    filterTable();
                }

                function populateOSFilter() {
                    const osSet = new Set();
                    devicesData.forEach(device => {
                        if (device.OperatingSystem) {
                            osSet.add(device.OperatingSystem);
                        }
                    });

                    osFilter.innerHTML = '<option value="all">All OS</option>';
                    Array.from(osSet).sort().forEach(os => {
                        const option = document.createElement('option');
                        option.value = os;
                        option.textContent = os;
                        osFilter.appendChild(option);
                    });
                }

                populateOSFilter();
                searchInput.addEventListener('input', filterTable);
                statusFilter.addEventListener('change', filterTable);
                osFilter.addEventListener('change', filterTable);
                minFreeSpace.addEventListener('input', filterTable);
                maxFreeSpace.addEventListener('input', filterTable);
                resetButton.addEventListener('click', resetFilters);

                filterTable();
            });
        </script>
</body>
</html>
"@
    
    try {
        Set-Content -Path $OutputPath -Value $html -Encoding UTF8
        Write-Host "Report successfully generated: $OutputPath" -ForegroundColor Green
        return $true
    }
    catch {
        Write-Error "Failed to generate report: $_"
        return $false
    }
}

# Main script execution
try {
    # Check if Microsoft.Graph module is installed
    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
        Write-Error "Microsoft.Graph.Authentication module is not installed. Please install it using: Install-Module Microsoft.Graph -Scope CurrentUser"
        exit 1
    }
    
    # Connect to Microsoft Graph
    Write-Host "`nConnecting to Microsoft Graph..." -ForegroundColor Cyan
    try {
        Connect-MgGraph -Scopes "DeviceManagementManagedDevices.Read.All" -NoWelcome -ErrorAction Stop
        Write-Host "Successfully connected to Microsoft Graph" -ForegroundColor Green
    }
    catch {
        Write-Error "Failed to connect to Microsoft Graph: $_"
        exit 1
    }
    
    # Get all managed devices
    $devices = Get-ManagedDevices
    
    if ($devices.Count -eq 0) {
        Write-Warning "No managed devices found in Intune"
        exit 0
    }
    
    # Collect storage information
    $storageData = @()
    
    if ($UseParallelProcessing) {
        Write-Host "`nGathering storage information using parallel processing..." -ForegroundColor Cyan
        
        # Import required variables into parallel scope
        $crit = $CriticalThreshold
        $warn = $WarningThreshold
        
        $storageData = $devices | ForEach-Object -ThrottleLimit 50 -Parallel {
            $selectProperties = @(
                "id",
                "deviceName",
                "managedDeviceName",
                "operatingSystem",
                "osVersion",
                "lastSyncDateTime",
                "hardwareInformation",
                "ethernetMacAddress",
                "processorArchitecture",
                "physicalMemoryInBytes"
            ) -join ","
            
            $uri = "https://graph.microsoft.com/beta/deviceManagement/managedDevices('$($_.id)')?`$select=$selectProperties"
            
            try {
                $deviceDetails = Invoke-MgGraphRequest -Method GET -Uri $uri
                
                $hardwareInfo = $deviceDetails.hardwareInformation
                
                if ($null -eq $hardwareInfo.totalStorageSpace -or $hardwareInfo.totalStorageSpace -eq 0) {
                    [PSCustomObject]@{
                        DeviceId          = $deviceDetails.id
                        DeviceName        = $deviceDetails.deviceName
                        ManagedDeviceName = $deviceDetails.managedDeviceName
                        OperatingSystem   = $deviceDetails.operatingSystem
                        OSVersion         = $deviceDetails.osVersion
                        Manufacturer      = $hardwareInfo.manufacturer
                        Model             = $hardwareInfo.model
                        SerialNumber      = $hardwareInfo.serialNumber
                        TotalStorageGB    = "N/A"
                        FreeStorageGB     = "N/A"
                        UsedStorageGB     = "N/A"
                        FreePercentage    = "N/A"
                        UsedPercentage    = "N/A"
                        StorageStatus     = "Unknown"
                        LastSync          = $deviceDetails.lastSyncDateTime
                    }
                }
                else {
                    $totalGB = [math]::Round($hardwareInfo.totalStorageSpace / 1GB, 2)
                    $freeGB = [math]::Round($hardwareInfo.freeStorageSpace / 1GB, 2)
                    $usedGB = [math]::Round(($hardwareInfo.totalStorageSpace - $hardwareInfo.freeStorageSpace) / 1GB, 2)
                    $freePercent = [math]::Round(($hardwareInfo.freeStorageSpace / $hardwareInfo.totalStorageSpace) * 100, 2)
                    $usedPercent = [math]::Round(100 - $freePercent, 2)
                    
                    $status = switch ($freePercent) {
                        { $_ -lt $using:crit } { "Critical" }
                        { $_ -lt $using:warn } { "Warning" }
                        default { "Healthy" }
                    }
                    
                    [PSCustomObject]@{
                        DeviceId          = $deviceDetails.id
                        DeviceName        = $deviceDetails.deviceName
                        ManagedDeviceName = $deviceDetails.managedDeviceName
                        OperatingSystem   = $deviceDetails.operatingSystem
                        OSVersion         = $deviceDetails.osVersion
                        Manufacturer      = $hardwareInfo.manufacturer
                        Model             = $hardwareInfo.model
                        SerialNumber      = $hardwareInfo.serialNumber
                        TotalStorageGB    = $totalGB
                        FreeStorageGB     = $freeGB
                        UsedStorageGB     = $usedGB
                        FreePercentage    = $freePercent
                        UsedPercentage    = $usedPercent
                        StorageStatus     = $status
                        LastSync          = $deviceDetails.lastSyncDateTime
                    }
                }
            }
            catch {
                Write-Warning "Failed to process device $($_.id): $_"
            }
        }
    }
    else {
        Write-Host "`nGathering storage information..." -ForegroundColor Cyan
        $counter = 0
        
        foreach ($device in $devices) {
            $counter++
            Write-Progress -Activity "Gathering storage information" -Status "Processing device $counter of $($devices.Count): $($device.deviceName)" -PercentComplete (($counter / $devices.Count) * 100)
            
            $deviceDetails = Get-DeviceHardwareInfo -DeviceId $device.id
            
            if ($deviceDetails) {
                $metrics = Get-StorageMetrics -Device $deviceDetails -CriticalThreshold $CriticalThreshold -WarningThreshold $WarningThreshold
                $storageData += $metrics
            }
        }
        
        Write-Progress -Activity "Gathering storage information" -Completed
    }
    
    Write-Host "Successfully retrieved storage information for $($storageData.Count) devices" -ForegroundColor Green
    
    # Generate the report
    $reportGenerated = Export-StorageReport -DeviceData $storageData -OutputPath $OutputPath -CriticalThreshold $CriticalThreshold -WarningThreshold $WarningThreshold
    
    if ($reportGenerated) {
        # Display summary in console
        Write-Host "`n========================================" -ForegroundColor Cyan
        Write-Host "Storage Report Summary" -ForegroundColor Cyan
        Write-Host "========================================" -ForegroundColor Cyan
        Write-Host "Total Devices:    $($storageData.Count)" -ForegroundColor White
        Write-Host "Healthy:          $(($storageData | Where-Object { $_.StorageStatus -eq 'Healthy' }).Count)" -ForegroundColor Green
        Write-Host "Warning:          $(($storageData | Where-Object { $_.StorageStatus -eq 'Warning' }).Count)" -ForegroundColor Yellow
        Write-Host "Critical:         $(($storageData | Where-Object { $_.StorageStatus -eq 'Critical' }).Count)" -ForegroundColor Red
        Write-Host "Unknown:          $(($storageData | Where-Object { $_.StorageStatus -eq 'Unknown' }).Count)" -ForegroundColor Gray
        Write-Host "========================================`n" -ForegroundColor Cyan

    }
}
catch {
    Write-Error "Script execution failed: $_"
    exit 1
}
finally {
    # Disconnect from Microsoft Graph
    Write-Host "`nDisconnecting from Microsoft Graph..." -ForegroundColor Cyan
    Disconnect-MgGraph | Out-Null
    Write-Host "Disconnected successfully" -ForegroundColor Green
}