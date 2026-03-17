<#
.SYNOPSIS
    Searches for a specific VM by name across a list of Prism Central instances.
    Finds and deletes all associated Recovery Points for that VM across ALL PCs.
    Finally, deletes the VM from its hosting PC.

    v3.3 Changes: Added rate limit handling (429 retries) and delays between API calls.

.DESCRIPTION
    1. Reads a list of Prism Central IP/FQDNs from a text file: .\pcs.txt
    2. Phase 1: Iterates through PCs to find the VM and capture its ExtId and Hosting PC.
    3. Phase 2: Iterates through ALL PCs to find and delete Recovery Points associated with that ExtId.
    4. Phase 3: Deletes the VM from the Hosting PC.

.PARAMETER VmName
    The exact name of the VM to find and delete.

.PARAMETER Credentials
    Nutanix Prism Central credentials (username/password).

Version 4.2 - 03/17/26 (working)
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
$PcListPath = ".\pcs.txt"
$DefaultDelayMs = 2000  # Delay between standard requests to avoid rate limits
$RetryWaitSec = 5      # Seconds to wait if we hit a 429 Rate Limit error

# ---------------------------------------------------------------------------
# SSL/TLS Configuration
# ---------------------------------------------------------------------------
if ($PSVersionTable.PSVersion.Major -lt 6) {
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

    if ($PSVersionTable.PSVersion.Major -ge 6) {
        $params['SkipCertificateCheck'] = $true
    }

    if ($Body) { $params['Body'] = $Body }

    try {
        if ($ReturnHeaders) {
            $response = Invoke-WebRequest @params -UseBasicParsing
            return $response
        }
        else {
            $response = Invoke-RestMethod @params
            return $response
        }
    }
    catch {
        Write-Warning "API Call Failed to $Uri. $_"
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

# -----------------------------------------------------------------------
# Phase 1: Find the VM and its ExtId
# -----------------------------------------------------------------------
Write-Host "`n=== Phase 1: Searching for VM '$VmName' ===" -ForegroundColor Cyan
$targetVmExtId = $null
$hostingPc = $null

foreach ($pc in $pcList) {
    Write-Host "Checking $pc..."

    # v4.1 VM Endpoint
    $searchUri = "https://$pc`:9440/api/vmm/v4.1/ahv/config/vms`?`$filter`=name%20eq%20`'$VmName`'"
    $searchResult = Invoke-NutanixApi -Uri $searchUri -Headers $baseHeaders

    if ($null-ne $searchResult -and $searchResult.data.Count -gt 0) {
        $targetVm = $searchResult.data[0]
        $targetVmExtId = $targetVm.extId
        $hostingPc = $pc
        Write-Host "  [FOUND] VM '$VmName' found on $pc." -ForegroundColor Green
        Write-Host "  VM ExtId: $targetVmExtId" -ForegroundColor Green
        break # Stop searching once found
    }
}

if ([string]::IsNullOrEmpty($targetVmExtId)) {
Write-Error "VM '$VmName' not found on any Prism Central in the list. Exiting."
    exit
}

# -----------------------------------------------------------------------
# Phase 2: Delete Recovery Points Globally (All PCs)
# -----------------------------------------------------------------------
Write-Host "`n=== Phase 2: Scanning ALL Prism Centrals for Recovery Points ===" -ForegroundColor Cyan

foreach ($pc in $pcList) {
    Write-Host "Checking for Recovery Points on $pc..." 

    # Loop until all RPs on this PC are deleted (handling pagination/batching)
    do {
        # Filter by the captured VM ExtId
        $rpFilter = "vmRecoveryPoints/any(x:x/vmExtId eq '$targetVmExtId')"
        $rpUri = "https://$pc`:9440/api/dataprotection/v4.0/config/recovery-points?`$limit=50&`$filter=$rpFilter"

        $rpResponse = Invoke-NutanixApi -Uri $rpUri -Headers $baseHeaders
        $rpList = $rpResponse.data

        if ($null -ne $rpList -and $rpList.Count -gt 0) {
            Write-Host "  Found $($rpList.Count) Recovery Points on $pc. Deleting..." -ForegroundColor Yellow

            foreach ($rp in $rpList) {
                $rpId = $rp.extId
                $rpName = $rp.name
                $delRpUri = "https://$pc`:9440/api/dataprotection/v4.0/config/recovery-points/$rpId"

                $UpdateHeaders = $baseHeaders.Clone()
                $UpdateHeaders.Add("NTNX-Request-Id", [Guid]::NewGuid().ToString()) # Idempotency key

                # Retry Loop for 429 Rate Limits
                $retryCount = 0
                $maxRetries = 3
                $success = $false

                do {
                    try {
                        Write-Host "    Deleting RP: $rpName ($rpId)"

                        $rpDeleteParams = @{
                            Uri     = $delRpUri
                            Method  = "DELETE"
                            Headers = $UpdateHeaders
                        }
                        if ($PSVersionTable.PSVersion.Major -ge 6) { $rpDeleteParams['SkipCertificateCheck'] = $true }

                        $rpDeleteresult = Invoke-RestMethod @rpDeleteParams
                        Write-Host "    Response: $rpDeleteresult" -ForegroundColor DarkGray

                        # Add a small delay between successful calls to be nice to the API
                        Start-Sleep -Milliseconds $DefaultDelayMs 
                        $success = $true
                    }
                    catch {
                        # Check for 429 Rate Limit Error
                        if ($_.Exception.Response.StatusCode -eq [System.Net.HttpStatusCode]::TooManyRequests -or $_.Exception.Message -match "rate limit") {
                            $retryCount++
                            if ($retryCount -le $maxRetries) {
                                Write-Warning "    Rate limit exceeded (429). Waiting $RetryWaitSec seconds before retry ($retryCount/$maxRetries)..."
                                Start-Sleep-Seconds $RetryWaitSec
                            } else {
                                Write-Error "    Failed to delete RP $rpId after $maxRetries retries due to rate limiting."
                                $success = $true # Force exit loop to move to next item
                            }
                        }
                        else {
                            Write-Warning "    Failed to delete RP $rpId. $_"
                            $success = $true # Force exit loop for non-retryable errors
                        }
                    }
                } while (-not $success)
            }
        }
        else {
            Write-Host "  No Recovery Points found on $pc." -ForegroundColor Gray
        }

    } while ($null -ne $rpList -and $rpList.Count -gt 0)
}

# -----------------------------------------------------------------------
# Phase 3: Delete the VM
# -----------------------------------------------------------------------
Write-Host "`n=== Phase 3: Deleting VM from Hosting PC ($hostingPc) ===" -ForegroundColor Cyan

$deleteUri = "https://$hostingPc`:9440/api/nutanix/v3/vms//$targetVmExtId"

try {
    Write-Host "  Sending Delete request for VM '$VmName' ($targetVmExtId)..."
    $deleteParams = @{
        Uri     = $deleteUri
        Method  = "DELETE"
        Headers = $baseHeaders
    }
    if ($PSVersionTable.PSVersion.Major -ge 6) { $deleteParams['SkipCertificateCheck'] = $true }

    Invoke-RestMethod @deleteParams
    Write-Host "  [SUCCESS] VM Delete task initiated successfully." -ForegroundColor Green
}
catch {
    Write-Error "  Failed to delete VM. Error: $_"
}

Write-Host "`nJob Complete."
