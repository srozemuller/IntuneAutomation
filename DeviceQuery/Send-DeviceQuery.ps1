Connect-mggraph

$body = @{
        query = "Device"
} | ConvertTo-Json
Invoke-MgGraphRequest -Uri "/beta/devicemanagement/deviceInventoryQueryRequests/initiateQuery" -Method POST -Body $body