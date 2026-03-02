<#
.SYNOPSIS
    Increases a specific Nutanix VM vDisk size using API v4 and expands the Windows partition.
    Compatible with PowerShell 5.1 and 7+.

.DESCRIPTION
    1. Connects to Prism Central using API v4.
    2. Finds the VM by name and locates the disk at scsi.X.
    3. Increases the vDisk size by the specified amount (GiB).
    4. Waits for the update task to complete.
    5. Connects to the VM via WinRM to expand the partition.

.PARAMETER PCServer
    IP or FQDN of the Prism Central server.
.PARAMETER VmName
    Name of the target Virtual Machine.
.PARAMETER DiskIndex
    The SCSI index of the disk to resize (e.g., 0 for scsi.0, 1 for scsi.1).
.PARAMETER IncreaseSizeGiB
    The amount of storage in GiB to ADD to the existing disk.
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$PCServer,

    [Parameter(Mandatory=$true)]
    [string]$VmName,

    [Parameter(Mandatory=$true)]
    [int]$DiskIndex,

    [Parameter(Mandatory=$true)]
    [int]$IncreaseSizeGiB
)

# ---------------------------------------------------------------------------
# 1. Environment Setup & Version Compatibility
# ---------------------------------------------------------------------------
$ErrorActionPreference = "Stop"

# Handle SSL Certificate Validation (PS 5 vs PS 7)
if ($PSVersionTable.PSVersion.Major -ge 6) {
    # PowerShell Core/7+ method handled in Invoke-RestMethod parameters later
    $SkipCertCheck = $true
} else {
    # PowerShell 5.1 method
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = {$true}
    $SkipCertCheck = $false
}

# ---------------------------------------------------------------------------
# 2. Authentication
# ---------------------------------------------------------------------------
Write-Host "Enter Prism Central Credentials:" -ForegroundColor Cyan
$PCCreds = Get-Credential

Write-Host "Enter Guest OS (Windows VM) Credentials:" -ForegroundColor Cyan
$GuestCreds = Get-Credential

$AuthHeader = @{
    Authorization = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(($PCCreds.UserName + ":" + $PCCreds.GetNetworkCredential().Password)))
}

# Base URL for VMM (Virtual Machine Management) API v4
# Note: Adjust 'v4.0.b1' if your specific PC version uses 'v4.0' GA or a different release
$BaseUrl = "https://$PCServer:9440/api/vmm/v4.0.b1/ahv/config"

# Helper wrapper for REST calls to handle PS version differences
function Invoke-NutanixRest {
    param($Uri, $Method, $Headers, $Body=$null)

    $Params = @{
        Uri         = $Uri
        Method      = $Method
        Headers     = $Headers
        ContentType = "application/json"
    }
    if ($Body) { $Params.Body = $Body }
    if ($SkipCertCheck) { $Params.SkipCertificateCheck = $true }
    # PS 7 requires SkipHeaderValidation for Etags, PS 5 ignores it
    if ($PSVersionTable.PSVersion.Major -ge 7) { $Params.SkipHeaderValidation = $true }

    try {
        if ($Method -eq "GET" -or $Method -eq "PUT") {
            # We need ResponseHeaders for ETag
            Invoke-RestMethod @Params -ResponseHeadersVariable "ResponseHeaders"
            return @{ Data = $null; Headers = $ResponseHeaders } # Logic handled below
        } else {
            return Invoke-RestMethod @Params
        }
    } catch {
        # Capture Invoke-RestMethod output even on 404/errors if possible, or throw
        throw $_
    }
}

# ---------------------------------------------------------------------------
# 3. Find VM and Get ETag
# ---------------------------------------------------------------------------
Write-Host "Searching for VM '$VmName'..." -NoNewline
$ListUri = "$BaseUrl/vms?`$filter=name eq '$VmName'"

# Standard GET to list VMs
$ListParams = @{
    Uri = $ListUri
    Method = "GET"
    Headers = $AuthHeader
    ContentType = "application/json"
}
if ($SkipCertCheck) { $ListParams.SkipCertificateCheck = $true }

$ListResponse = Invoke-RestMethod @ListParams

if ($ListResponse.data.totalAvailableResults -eq 0) {
    Write-Error "VM '$VmName' not found."
}
$VmExtId = $ListResponse.data[0].extId
Write-Host " Found (ExtId: $VmExtId)" -ForegroundColor Green

# GET specific VM to retrieve ETag and current config
Write-Host "Retrieving VM details and ETag..."
$GetVmUri = "$BaseUrl/vms/$VmExtId"
$GetVmParams = @{
    Uri = $GetVmUri
    Method = "GET"
    Headers = $AuthHeader
    ContentType = "application/json"
}
if ($SkipCertCheck) { $GetVmParams.SkipCertificateCheck = $true }
# We use response headers variable to capture ETag
$VmDetails = Invoke-RestMethod @GetVmParams -ResponseHeadersVariable "ResponseHead"

# Extract ETag (Critical for v4 Updates)
$ETag = $ResponseHead["ETag"]
if (-not $ETag) { $ETag = $ResponseHead["Etag"] } # Case sensitivity check
Write-Host " ETag acquired: $ETag" -ForegroundColor Green

# ---------------------------------------------------------------------------
# 4. Locate and Resize Disk Object
# ---------------------------------------------------------------------------
$VmConfig = $VmDetails.data
$Disks = $VmConfig.disks
$TargetDisk = $null

foreach ($Disk in $Disks) {
    # Check for SCSI adapter and matching Index
    # Structure varies slightly by version, assuming standard v4 model:
    # diskAddress = { adapterType = "SCSI", deviceIndex = X }
    if ($Disk.diskAddress.adapterType -eq "SCSI" -and $Disk.diskAddress.deviceIndex -eq $DiskIndex) {
        $TargetDisk = $Disk
        break
    }
}

if (-not $TargetDisk) {
    Write-Error "Disk at scsi.$DiskIndex not found on VM '$VmName'."
}

$CurrentSizeBytes = $TargetDisk.backingInfo.dataSource.spec.sizeBytes
$CurrentSizeGiB = $CurrentSizeBytes / 1GB
$IncreaseBytes = $IncreaseSizeGiB * 1GB
$NewSizeBytes = $CurrentSizeBytes + $IncreaseBytes

Write-Host "Found disk at scsi.$DiskIndex."
Write-Host "Current Size: $([math]::Round($CurrentSizeGiB, 2)) GiB"
Write-Host "New Size:     $([math]::Round($NewSizeBytes / 1GB, 2)) GiB" -ForegroundColor Yellow

# Update the local object
$TargetDisk.backingInfo.dataSource.spec.sizeBytes = $NewSizeBytes

# ---------------------------------------------------------------------------
# 5. Send Update (PUT)
# ---------------------------------------------------------------------------
Write-Host "Updating VM configuration via API v4..."

# Add If-Match header for concurrency control
$UpdateHeaders = $AuthHeader.Clone()
$UpdateHeaders.Add("If-Match", $ETag)
$UpdateHeaders.Add("NTNX-Request-Id", [Guid]::NewGuid().ToString()) # Idempotency key

$JsonBody = $VmConfig | ConvertTo-Json -Depth 10

$UpdateParams = @{
    Uri = "$BaseUrl/vms/$VmExtId"
    Method = "PUT"
    Headers = $UpdateHeaders
    Body = $JsonBody
    ContentType = "application/json"
}
if ($SkipCertCheck) { $UpdateParams.SkipCertificateCheck = $true }
# PS 7 workaround for ETag validation
if ($PSVersionTable.PSVersion.Major -ge 7) { $UpdateParams.SkipHeaderValidation = $true }

try {
    $UpdateResponse = Invoke-RestMethod @UpdateParams
    $TaskExtId = $UpdateResponse.data.extId # In v4, async operations return a task reference
    Write-Host "Update request submitted. Task ID: $TaskExtId" -ForegroundColor Green
} catch {
    Write-Error "Failed to update VM. Details: $($_.Exception.Message)"
}

# ---------------------------------------------------------------------------
# 6. Monitor Task Completion
# ---------------------------------------------------------------------------
Write-Host "Waiting for resize task to complete..."
$TaskUri = "https://$PCServer:9440/api/prism/v4.0.b1/config/tasks/$TaskExtId"

do {
    Start-Sleep -Seconds 5
    $TaskParams = @{ Uri = $TaskUri; Method = "GET"; Headers = $AuthHeader }
    if ($SkipCertCheck) { $TaskParams.SkipCertificateCheck = $true }
    $TaskStatus = Invoke-RestMethod @TaskParams
    $Status = $TaskStatus.data.status
    Write-Host "Task Status: $Status"
} while ($Status -ne "SUCCEEDED" -and $Status -ne "FAILED")

if ($Status -eq "FAILED") {
    Write-Error "VM Disk resize task failed."
}

# ---------------------------------------------------------------------------
# 7. Guest OS Partition Expansion (WinRM)
# ---------------------------------------------------------------------------
Write-Host "Connecting to Guest OS ($VmName) to expand partition..." -ForegroundColor Cyan

# Attempt to get IP from VM config if possible, otherwise rely on DNS resolution of VMName
# Note: For this to work, $VmName must be resolvable, or you can extract IP from $VmConfig.nics
$TargetHost = $VmName

Invoke-Command -ComputerName $TargetHost -Credential $GuestCreds -ScriptBlock {
    param($TargetIndex)

    Write-Host "Rescanning disks..."
    Update-HostStorageCache
    Start-Sleep -Seconds 2

    # Find the disk that matches the SCSI location (Bus 0, Target Id $TargetIndex)
    # Note: Mapping Nutanix scsi.x to Windows Disk Number isn't always 1:1, 
    # but usually Nutanix scsi.x appears as a disk with Location Path involving Target Id X.
    # A safer generic approach for single-partition data disks is matching the max available free space.

    $DiskToExpand = Get-Disk | Where-Object { $_.Location -like "*Target $TargetIndex*" }

    if (-not $DiskToExpand) {
        Write-Warning "Could not strictly map scsi.$TargetIndex via Location path. Attempting to find disk with unallocated space..."
        $DiskToExpand = Get-Disk | Where-Object { $_.LargestFreeExtent -gt 1GB } | Select-Object -First 1
    }

    if ($DiskToExpand) {
        $DiskNum = $DiskToExpand.Number
        Write-Host "Targeting Windows Disk Number: $DiskNum"

        # Get the largest partition on this disk (assuming standard data disk layout)
        $Part = Get-Partition -DiskNumber $DiskNum | Sort-Object Size -Descending | Select-Object -First 1

        if ($Part) {
            Write-Host "Expanding Partition $($Part.PartitionNumber) (Drive: $($Part.DriveLetter))..."

            # Resize to maximum supported size
            $Size = (Get-PartitionSupportedSize -DriveLetter $Part.DriveLetter).SizeMax
            Resize-Partition -DriveLetter $Part.DriveLetter -Size $Size

            Write-Host "Partition expanded successfully."
        } else {
            Write-Error "No scalable partition found on Disk $DiskNum."
        }
    } else {
        Write-Error "Could not identify the disk inside Windows."
    }
} -ArgumentList $DiskIndex

Write-Host "Operation Complete." -ForegroundColor Green
