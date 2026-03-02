# ==============================
# Nutanix VM Disk Resize Script
# ==============================
 
# --- CONFIGURATION ---
$PrismElement = "https://<cluster-ip>:9440"   # Prism Element URL
$Username     = "admin"                       # Prism username
$Password     = "yourpassword"                # Prism password
$VM_UUID      = "<vm-uuid>"                   # UUID of the VM
$Disk_UUID    = "<disk-uuid>"                 # UUID of the disk to resize
$NewSizeGB    = 100                           # New size in GB
 
# --- AUTHENTICATION ---
$AuthHeader = @{
    Authorization = "Basic " + [Convert]::ToBase64String(
        [Text.Encoding]::ASCII.GetBytes("$Username`:$Password")
    )
    "Content-Type" = "application/json"
}
 
# --- API URL ---
$ApiUrl = "$PrismElement/api/nutanix/v3/vms/$VM_UUID/disks/$Disk_UUID"
 
# --- PAYLOAD ---
# Size is in bytes
$NewSizeBytes = $NewSizeGB * 1GB
$Payload = @{
    spec = @{
        resources = @{
            disk_size_bytes = $NewSizeBytes
        }
    }
} | ConvertTo-Json -Depth 5
 
# --- EXECUTE PATCH REQUEST ---
try {
    $Response = Invoke-RestMethod -Uri $ApiUrl -Method PATCH -Headers $AuthHeader -Body $Payload -SkipCertificateCheck
    Write-Host "Disk resize request submitted successfully."
    Write-Host "Task UUID: $($Response.status.execution_context.task_uuid)"
}
catch {
    Write-Host "Error resizing disk: $($_.Exception.Message)"
}
