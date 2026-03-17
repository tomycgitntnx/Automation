<#
.SYNOPSIS
    Searches for and deletes a specific VM by name across a list of Prism Central instances.
    Also,  deletes all associated Recovery Points for that VM before deletion.
    Compatible with PowerShell 5.1 and 7+.

.DESCRIPTION
    1. Reads a list of Prism Central IP/FQDNs from a text file: .\pcs.txt
    2. Authenticates against each PC using Basic Auth.
    3. Searches for the VM using v4.1 API ($filter=name eq '...').
    4. Searches for and deletes all Recovery Points for that VM using v4.0 Data Protection API.
    5. Deletes the VM using v4 API.
    6. Searches and deletes for Recovery points in the local cluster where the VM lives using v4 API. 
       NOTE: it does not remove Recovery points from DR sites 

.PARAMETER VmName
    The exact name of the VM to find and delete.

.PARAMETER Credentials
    Nutanix Prism Central credentials (username/password).

Version 3.1 Jan 2026
#>

# Param 
[CmdletBinding()]
param (
    [Parameter(Mandatory=$true, Position=0)]
    [string]$VmName,

    [Parameter(Mandatory=$true)]
    [System.Management.Automation.PSCredential]$Credentials
)

# Initial Variables
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
    if ($PSVersionTable.PSVersion.Major-ge 6) {
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

    # 1. Search for the VM (v4.1 API List with Filter)
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

    # -----------------------------------------------------------------------
    # 2. Delete Recovery Points (Loop until all are gone)
    # -----------------------------------------------------------------------
    Write-Host "  Checking for Recovery Points..."

    # We use a do-while loop to handle pagination implicitly: 
    # we fetch a batch, delete them, and repeat until no RPs are left for this VM.
    do {
        # Construct Filter: vmRecoveryPoints/any(x:x/vmExtId eq 'VM_UUID')
        # Note: Using v4.0 Data Protection API
        $rpFilter = "vmRecoveryPoints/any(x:x/vmExtId eq '$vmExtId')"
        $rpUri = "https://$pc`:9440/api/dataprotection/v4.0/config/recovery-points?`$limit=50&`$filter=$rpFilter"

        $rpResponse = Invoke-NutanixApi -Uri $rpUri -Headers $baseHeaders
        $rpList = $rpResponse.data

        if ($null -ne $rpList -and $rpList.Count -gt 0) {
            Write-Host "  Found $($rpList.Count) Recovery Points. Deleting batch..." -ForegroundColor Yellow

            foreach ($rp in $rpList) {
                $rpId = $rp.extId
                $rpName = $rp.name
                $delRpUri = "https://$pc`:9440/api/dataprotection/v4.0/config/recovery-points/$rpId"
                $UpdateHeaders = $baseHeaders.Clone()
                $UpdateHeaders.Add("NTNX-Request-Id", [Guid]::NewGuid().ToString()) # Idempotency key

                try {
                    Write-Host "    Deleting RP: $rpName ($rpId)"
                    $rpDeleteParams = @{
                        Uri     = $delRpUri
                        Method  = "DELETE"
                        Headers = $UpdateHeaders ## add NTNX-Request-ID
                    }
                    if ($PSVersionTable.PSVersion.Major -ge 6) { $rpDeleteParams['SkipCertificateCheck'] = $true }

                    $rpDeleteresult = Invoke-RestMethod @rpDeleteParams
                    Write-Host "Deleted message: $rpDeleteresult" -ForegroundColor Green
                }
                catch {
                    Write-Warning "    Failed to delete RP $rpId. $_"
                }
            }
        }
        else {
            Write-Host "  No more Recovery Points found."
        }

    } while ($null -ne $rpList -and $rpList.Count -gt 0)

    # -----------------------------------------------------------------------
    # 3. Delete the VM
    # -----------------------------------------------------------------------
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
