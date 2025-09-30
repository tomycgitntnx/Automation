<#
.SYNOPSIS
    Retrieves all unresolved alerts from a Nutanix Prism Central (PC) instance
    using the REST API v4.1 and exports them to a CSV file.

.DESCRIPTION
    This script authenticates to Prism Central, sends a GET request to the
    /api/monitoring/v4.1/alerts endpoint with an OData filter to fetch only
    unresolved alerts, handles API pagination using $skip and $top parameters, 
    and then exports the relevant details into a CSV file.

.NOTES
    Author: Tomy Carrasco, Nutanix
    Date: 2025-09-30
    Version: 4.0
    PowerShell Version: 5.1+

.REQUIREMENTS
    - PowerShell 5.1
    - Network connectivity to the Prism Central instance on port 9440.
    - A user account with at least viewer permissions on Prism Central.
#>

#region USER-CONFIGURABLE VARIABLES
# --- UPDATE THESE VALUES FOR YOUR ENVIRONMENT ---
$pcIp = "192.168.1.10" # IP address or FQDN of your Prism Central
$username = "admin" # Your Prism Central username
$password = "YourSecurePassword" # Your Prism Central password
$outputFile = "C:\temp\Nutanix_Unresolved_Alerts.csv" # Full path for the output CSV file
#endregion

#region SCRIPT BODY (No modifications should be needed below this line)

# --- Initial Setup and SSL/TLS Handling ---
Write-Host "Starting script..." -ForegroundColor Cyan

# For environments with self-signed certificates, this will bypass SSL certificate validation.
# This is the correct method for PowerShell 5.1.
try {
    Add-Type @"
    using System.Net;
    using System.Security.Cryptography.X509Certificates;
    public class TrustAllCertsPolicy : ICertificatePolicy {
        public bool CheckValidationResult(ServicePoint srvPoint, X509Certificate certificate, WebRequest request, int certificateProblem) {
            return true;
        }
    }
"@ -ErrorAction Stop
    [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
    Write-Host "SSL certificate validation is being bypassed." -ForegroundColor Yellow
}
catch {
    Write-Error "Could not load the custom SSL certificate policy. The script may fail on systems with self-signed certificates."
    return
}

# Enforce TLS 1.2 for modern security standards
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

# --- Authentication ---
# Create the Basic Authentication header required by the API.
$encodedAuth = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("${username}:${password}"))
$headers = @{
    "Authorization" = "Basic $encodedAuth"
    "Content-Type"  = "application/json"
}

# --- Data Retrieval with Pagination Handling ---
$allAlerts = [System.Collections.Generic.List[PSObject]]::new()
$skip = 0
$top = 100 # Page size. Can be up to 500.
$totalCount = -1 # Using -1 to indicate it has not been set yet.
$page = 1

Write-Host "Connecting to $pcIp and fetching unresolved alerts..." -ForegroundColor Cyan

do {
    # The v4.1 monitoring API uses GET with OData filters and $skip/$top for pagination.
    # Note: OData parameter names ($filter, $top, $skip) need a backtick ` to be escaped in the string.
    $apiUrl = "https://{0}:9440/api/monitoring/v4.1/alerts?`$filter=isResolved eq false&`$top={1}&`$skip={2}" -f $pcIp, $top, $skip

    try {
        Write-Host "Fetching page $page (alerts $($skip + 1) - $($skip + $top))..."
        # The -SkipCertificateCheck parameter has been removed as it is not supported in PowerShell 5.1.
        # The ServicePointManager policy set earlier handles certificate validation.
        $response = Invoke-RestMethod -Uri $apiUrl -Method Get -Headers $headers -ErrorAction Stop

        if ($null -ne $response.data -and $response.data.Count -gt 0) {
            $allAlerts.AddRange($response.data)
            Write-Host "  - Found $($response.data.Count) alerts on this page."
        } else {
             Write-Host "  - No more alerts found. Stopping retrieval."
             break
        }

        # On the first call, get the total number of results from the metadata.
        if ($totalCount -eq -1) {
            $totalCount = $response.metadata.totalCount
            if ($totalCount -eq 0) {
                # Exit loop if there are no alerts to fetch at all.
                break
            }
            Write-Host "Total unresolved alerts to fetch: $totalCount"
        }

        $skip += $top
        $page++

    } catch {
        Write-Error "An error occurred while calling the Nutanix API."
        Write-Error "URL: $apiUrl"
        # Robust error handling: Check if a response object exists before trying to access its properties.
        if ($_.Exception.Response) {
            Write-Error "Status Code: $($_.Exception.Response.StatusCode.value__)"
            $errorResponse = $_.Exception.Response.GetResponseStream() | New-Object System.IO.StreamReader | ForEach-Object { $_.ReadToEnd() }
            Write-Error "Response: $errorResponse"
        } else {
            Write-Error "No response received from the server. This could be a network, DNS, or TLS/SSL issue."
            Write-Error "Underlying Exception: $($_.Exception.Message)"
        }
        # Stop the script on API failure
        return
    }

# Continue looping as long as we have collected fewer alerts than the total reported by the API.
} while ($totalCount -ne -1 -and $allAlerts.Count -lt $totalCount)

# --- Data Processing and Export ---
if ($allAlerts.Count -gt 0) {
    Write-Host "Finished fetching. Total unresolved alerts found: $($allAlerts.Count)." -ForegroundColor Green
    Write-Host "Processing and exporting data to CSV..."

    # Select and flatten properties for a clean CSV output, matching the v4.1 /alerts endpoint structure.
    $exportData = $allAlerts | Select-Object @{N = 'Id'; E = { $_.extId } },
        @{N = 'Title'; E = { $_.title } },
        @{N = 'Severity'; E = { $_.severity } },
        @{N = 'CreatedTime'; E = { $_.creationTime } },
        @{N = 'LastOccurred'; E = { $_.lastOccurrenceTime } },
        @{N = 'ImpactType'; E = { $_.impactType } },
        @{N = 'SourceEntityName'; E = { $_.context.originEntity.name } },
        @{N = 'SourceEntityType'; E = { $_.context.originEntity.type } },
        @{N = 'ClusterName'; E = { $_.context.cluster.name } },
        @{N = 'ClusterUuid'; E = { $_.context.cluster.uuid } },
        @{N = 'IsAcknowledged'; E = { $_.isAcknowledged } },
        @{N = 'IsResolved'; E = { $_.isResolved } }

    # Export the processed data to a CSV file.
    try {
        $exportData | Export-Csv -Path $outputFile -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
        Write-Host "Successfully exported unresolved alerts to: $outputFile" -ForegroundColor Green
    } catch {
        Write-Error "Failed to write to output file: $outputFile. Please check permissions and path."
        Write-Error $_.Exception.Message
    }

} else {
    Write-Host "No unresolved alerts were found on the cluster." -ForegroundColor Green
}

Write-Host "Script finished." -ForegroundColor Cyan
#endregion
