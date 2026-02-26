<#
.SYNOPSIS
    Searches for and deletes a specific VM by name across a list of Prism Central instances using the Nutanix v4.1 API.
    Compatible with PowerShell 5.1 and 7+.

.DESCRIPTION
    1. Reads a list of Prism Central IP/FQDNs from a text file:  .\pcs.txt
    2. Authenticates against each PC using Basic Auth. Passwords are encoded (no clear text)
    3. Searches for the VM using OData filtering ($filter=name eq '...').
    4. If found, sends a DELETE request.

.PARAMETER VmName
    The exact name of the VM to find and delete.

.PARAMETER Credentials
    Nutanix Prism Central credentials (username/password).

Version 2.1 Jan 2026

#>

# Param 
[CmdletBinding()]

param (
    [Parameter(Mandatory=$true, Position=0)]
    [string]$VmName,

    [Parameter(Mandatory=$true)]
    [System.Management.Automation.PSCredential]$Credentials
)

# Initial Varables
$PcListPath=".\pcs.txt"

# ---------------------------------------------------------------------------
# SSL/TLS Configuration (Compatibility for PS 5.1 and PS 7)
# ---------------------------------------------------------------------------
if ($PSVersionTable.PSVersion.Major -lt 6) {
    # PowerShell 5.1: Trust all certs (for self-signed PC certs)
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
    if (-not ([System.Management.Automation.PSTypeName]'TrustAllCertsPolicy').Type) {
        Add-Type @"
            using System.Net;
            using System.Security.Cryptography.X509Certificates;
            public class TrustAllCertsPolicy : ICertificatePolicy {
                public bool CheckValidationResult(ServicePoint srvPoint, X509Certificate certificate, WebRequest request, int certificateProblem) {
                    return true;
                }
            }
"@
        [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
    }
}

# ---------------------------------------------------------------------------
# Helper Function for API Calls
# ---------------------------------------------------------------------------
function Invoke-NutanixApi {
    param (
        [string]$Uri,
        [string]$Method = 'GET',
        [hashtable]$Headers,
        [string]$Body = $null,
        [switch]$ReturnHeaders
    )

    $params = @{
        Uri         = $Uri
        Method      = $Method
        Headers     = $Headers
        ContentType = "application/json"
    }

    # Handle PS 7 vs PS 5.1 certificate skipping
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        $params['SkipCertificateCheck'] = $true
    }

    if ($Body) { $params['Body'] = $Body }

    try {
        if ($ReturnHeaders) {
            # We need Invoke-WebRequest to get headers in PS 5.1 reliably
            $response = Invoke-WebRequest @params -UseBasicParsing
            return $response
        }
        else {
            $response = Invoke-RestMethod @params
            return $response
        }
    }
    catch {
        Write-Error "API Call Failed to $Uri. $_"
        return $null
    }
}

# ---------------------------------------------------------------------------
# Main Logic
# ---------------------------------------------------------------------------

# Validate Input
if (-not (Test-Path $PcListPath)) {
    Write-Error "PC List file not found at: $PcListPath"
    exit
}

$pcList = Get-Content $PcListPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
$authHeader = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(($Credentials.UserName + ":" + $Credentials.GetNetworkCredential().Password)))
$baseHeaders = @{
    "Authorization" = $authHeader
    "Accept"        = "application/json"
}

# Search all PCs and if found, delete VM
foreach ($pc in $pcList) {
    Write-Host "`n---------------------------------------------------"
    Write-Host "Connecting to Prism Central: $pc" -ForegroundColor Cyan

    # Search for the VM (v4.1 API List with Filter)
    # v4.1 VM Endpoint: /api/vmm/v4.1/ahv/config/vms
    $searchUri = "https://$pc`:9440/api/vmm/v4.1/ahv/config/vms`?`$filter`=name%20eq%20`'$VmName`'"

    Write-Host "  Searching for VM '$VmName'..."
    $searchResult = Invoke-NutanixApi -Uri $searchUri -Headers $baseHeaders

    # If no VM is found in current PC, move on to next cluster
    if ($null -eq $searchResult -or $searchResult.data.Count -eq 0) {
        Write-Warning "  VM '$VmName' not found on $pc."
        continue
    }

    # Handle multiple VMs with same name (unlikely if unique, but possible in v4 view)
    $targetVm = $searchResult.data[0]
    $vmExtId = $targetVm.extId
    Write-Host "  Found VM. ExtId: $vmExtId" -ForegroundColor Green

    # We must GET the specific entity to ensure we have the latest ETag header
    # $getVmUri = "https://$pc`:9440/api/vmm/v4.1/ahv/config/vms/$vmExtId"
    # $vmDetails = Invoke-NutanixApi -Uri $getVmUri -Headers $baseHeaders -ReturnHeaders

    # if ($null -eq $vmDetails) {
    #    Write-Error "  Failed to retrieve VM details for ETag."
    #    continue
    # }

    # Extract ETag (PS 5.1 returns 'Headers' property, PS 7 might differ slightly but Invoke-WebRequest normalizes this)
    # $eTag = $vmDetails.Headers['ETag']

    # if ([string]::IsNullOrEmpty($eTag)) {
    #     Write-Warning "  Could not retrieve ETag. Attempting delete without it (may fail)."
    # } else {
    #     Write-Host "  Retrieved ETag: $eTag" -ForegroundColor Gray
    # }

    # Delete the VM
    # V3 API does not require if-match etag
    $deleteUri = "https://$pc`:9440/api/nutanix/v3/vms//$vmExtId"

        Write-Host "  Deleting VM..."
    # Using Invoke-RestMethod for the delete action to handle the 202/204 response cleanly
    try {
        $deleteParams = @{
            Uri     = $deleteUri
            Method  = "DELETE"
            Headers = $baseHeaders
        }
        if ($PSVersionTable.PSVersion.Major -ge 6) { $deleteParams['SkipCertificateCheck'] = $true }

        Invoke-RestMethod @deleteParams
        Write-Host "  Delete request sent successfully (Async Task Started)." -ForegroundColor Green
    }
    catch {
        Write-Error "  Failed to delete VM. Error: $_"
    }
}
