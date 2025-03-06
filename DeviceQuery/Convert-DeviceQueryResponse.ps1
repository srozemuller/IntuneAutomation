<#
.SYNOPSIS
Creates PowerShell objects from Intune Device Inventory Query
.DESCRIPTION
This script converts the response from the deviceInventoryQueryRequests into PowerShell objects
More info at: https://rozemuller.com/intune-multiple-device-query-from-an-automation-perspective
.PARAMETER JsonString
Provide the JSON string returned from Graph API /deviceManagement/deviceInventoryQueryRequests/{id}/retrieveResults
.EXAMPLE
.\Convert-DeviceQueryResponse.ps1 -JsonString "string"
#>
[CmdletBinding()]
    param
    (
        [parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$JsonString
    )
try {
    # Convert JSON to PowerShell object
    $data = $JsonString | ConvertFrom-Json

    # Extract column definitions
    $columnDefinitions = $data.columns

    # Identify columns dynamically
    $columnNames = @()
    $deviceColumns = @()

    foreach ($column in $columnDefinitions) {
        if ($column.attributeType -eq "device") {
            $columnNames += $column.displayName  # Store device as a whole initially
        } else {
            $columnNames += $column.displayName
        }
    }

    # Initialize array for structured data
    $structuredData = @()

    # Process rows
    foreach ($row in $data.rows) {
        $rowArray = $row | ConvertFrom-Json
        $entry = @{}

        for ($i = 0; $i -lt $columnDefinitions.Count; $i++) {
            $column = $columnDefinitions[$i]
            
            if ($columnDefinitions.Count -eq 1){
                $value = $rowArray
            }
            else {
            $value = $rowArray[$i]
            }

            # Check if column is of type 'device'
            if ($column.attributeType -eq "device") {
                # Convert the stringified JSON object to PowerShell object if it's a device column
                if ($value) {
                    $deviceObject = $value | ConvertFrom-Json

                    # Expand device properties into separate columns
                    foreach ($key in $deviceObject.PSObject.Properties.Name) {
                        $entry[$key] = $deviceObject.$key
                    }
                } else {
                    # Handle empty device data
                    $entry[$column.displayName] = "N/A"
                }
            } else {
                # Directly assign the value for non-device columns (like string)
                $entry[$column.displayName] = $value
            }
        }

        # Store structured entry
        $structuredData += New-Object PSObject -Property $entry
    }

    # Display final structured data
    $structuredData
}
catch {
    Write-Error "Unable to convert device query response. $_"
}
