<#
.SYNOPSIS
    Searches for and deletes a specific VM by name across a list of Prism Central instances using the Nutanix v4.1 API.
    Compatible with PowerShell 5.1 and 7+.

.DESCRIPTION
    1. Reads a list of Prism Central IP/FQDNs from a text file.
    2. Authenticates against each PC using Basic Auth.
    3. Searches for the VM using OData filtering ($filter=name eq '...').
    4. If found, retrieves the specific VM's ETag (required for optimistic concurrency in v4 API).
    5. Sends a DELETE request with the required 'If-Match' and 'NTNX-Request-Id' headers.

.PARAMETER VmName
    The exact name of the VM to find and delete.

.PARAMETER PcListPath
    Path to a text file containing one Prism Central IP/FQDN per line.

.PARAMETER Credentials
    Nutanix Prism Central credentials (username/password).
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory=$true, Position=0)]
    [string]$VmName,

    [Parameter(Mandatory=$true, Position=1)]
    [string]$PcListPath,

    [Parameter(Mandatory=$true)]
    [System.Management.Automation.PSCredential]$Credentials
)

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

# 1. Validate Input
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

foreach ($pc in $pcList) {
    Write-Host "`n---------------------------------------------------"
    Write-Host "Connecting to Prism Central: $pc" -ForegroundColor Cyan

    # 2. Search for the VM (v4.1 API List with Filter)
    # v4.1 VM Endpoint: /api/vmm/v4.1/ahv/config/vms
    $searchUri = "https://$pc` :9440/api/vmm/v4.1/ahv/config/vms?`$filter=name eq '$VmName'"

    Write-Host "  Searching for VM '$VmName'..."
    $searchResult = Invoke-NutanixApi -Uri $searchUri -Headers $baseHeaders

    if ($null -eq $searchResult -or $searchResult.data.Count -eq 0) {
        Write-Warning "  VM '$VmName' not found on $pc."
        continue
    }

    # Handle multiple VMs with same name (unlikely if unique, but possible in v4 view)
    $targetVm = $searchResult.data[0]
    $vmExtId = $targetVm.extId
    Write-Host "  Found VM. ExtId: $vmExtId" -ForegroundColor Green

    # 3. Retrieve ETag (Required for v4 Delete)
    # We must GET the specific entity to ensure we have the latest ETag header
    $getVmUri = "https://$pc` :9440/api/vmm/v4.1/ahv/config/vms/$vmExtId"
    $vmDetails = Invoke-NutanixApi -Uri $getVmUri -Headers $baseHeaders -ReturnHeaders

    if ($null -eq $vmDetails) {
        Write-Error "  Failed to retrieve VM details for ETag."
        continue
    }

    # Extract ETag (PS 5.1 returns 'Headers' property, PS 7 might differ slightly but Invoke-WebRequest normalizes this)
    $eTag = $vmDetails.Headers['ETag']

    if ([string]::IsNullOrEmpty($eTag)) {
        Write-Warning "  Could not retrieve ETag. Attempting delete without it (may fail)."
    } else {
        Write-Host "  Retrieved ETag: $eTag" -ForegroundColor Gray
    }

    # 4. Delete the VM
    # DELETE requires 'If-Match' (ETag) and 'NTNX-Request-Id' (Idempotency)
    $deleteUri = "https://$pc` :9440/api/vmm/v4.1/ahv/config/vms/$vmExtId"

    $deleteHeaders = $baseHeaders.Clone()
    if ($eTag) { $deleteHeaders.Add("If-Match", $eTag) }
    $deleteHeaders.Add("NTNX-Request-Id", [Guid]::NewGuid().ToString())

    Write-Host "  Deleting VM..."
    # Using Invoke-RestMethod for the delete action to handle the 202/204 response cleanly
    try {
        $deleteParams = @{
            Uri     = $deleteUri
            Method  = "DELETE"
            Headers = $deleteHeaders
        }
        if ($PSVersionTable.PSVersion.Major -ge 6) { $deleteParams['SkipCertificateCheck'] = $true }

        Invoke-RestMethod @deleteParams
        Write-Host "  Delete request sent successfully (Async Task Started)." -ForegroundColor Green
    }
    catch {
        Write-Error "  Failed to delete VM. Error: $_"
    }
}
