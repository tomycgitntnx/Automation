<#
.SYNOPSIS
    Retrieves all unresolved alerts from a Nutanix Prism Central (PC) instance
    using the REST API v4.1 and exports them to a CSV file.

.DESCRIPTION
    This script authenticates to Prism Central, sends as a GET request to the
    /api/monitoring/v4.1/serviceability/alerts endpoint with an OData filter
    to fetch only unresolved alerts, handles API pagination using page and limit
    parameters, and then exports the relevant details into a CSV file.

.NOTES
    Author: Tomy Carrasco, Nutanix
    Date: 2025-09-30
    Version: 2.0
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
# Remove or comment out this section if you have a valid CA-signed certificate on Prism Central.
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
    Write-Warning "Could not load the custom SSL certificate policy. The script will continue and rely on the -SkipCertificateCheck parameter."
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
$page = 0
$limit = 50 # API page size limit, 50 is a common and safe value.
$totalAvailable = -1 # Using -1 to indicate it has not been set yet.

Write-Host "Connecting to $pcIp and fetching unresolved alerts..." -ForegroundColor Cyan

do {
    # The v4.1 serviceability API uses GET with OData filters and page/limit for pagination.
    # Note: OData filters are case-sensitive and use 'eq' for equality. The field name is 'isResolved'.
    $apiUrl = "https://{0}:9440/api/monitoring/v4.1/serviceability/alerts?`$filter=isResolved eq false&`$limit={1}&`$page={2}" -f $pcIp, $limit, $page

    try {
        Write-Host "Fetching page $($page + 1)..."
        $response = Invoke-RestMethod -Uri $apiUrl -Method Get -Headers $headers -ErrorAction Stop -SkipCertificateCheck

        if ($null -ne $response.data -and $response.data.Count -gt 0) {
            $allAlerts.AddRange($response.data)
            Write-Host "  - Found $($response.data.Count) alerts on this page."
        } else {
             Write-Host "  - No alerts found on this page. Stopping retrieval."
             # Break the loop if a page comes back with no data for any reason.
             break
        }

        # On the first call (page 0), get the total number of results from the metadata.
        if ($page -eq 0) {
            $totalAvailable = $response.metadata.totalAvailableResults
            # If totalAvailable is 0, the loop condition will fail and we will exit gracefully.
            Write-Host "Total unresolved alerts to fetch: $totalAvailable"
        }

        $page++

    } catch {
        Write-Error "An error occurred while calling the Nutanix API."
        Write-Error "URL: $apiUrl"
        Write-Error "Status Code: $($_.Exception.Response.StatusCode.value__)"
        Write-Error "Response: $($_.Exception.Response.GetResponseStream() | New-Object System.IO.StreamReader | ForEach-Object { $_.ReadToEnd() })"
        # Stop the script on API failure
        return
    }

# Continue looping as long as the number of alerts we have collected is less than the total reported by the API.
} while ($allAlerts.Count -lt $totalAvailable)

# --- Data Processing and Export ---
if ($allAlerts.Count -gt 0) {
    Write-Host "Finished fetching. Total unresolved alerts found: $($allAlerts.Count)." -ForegroundColor Green
    Write-Host "Processing and exporting data to CSV..."

    # Select and flatten the desired properties for a clean CSV output.
    # The property names below are based on the v4.1 serviceability/alerts API response structure.
    $exportData = $allAlerts | Select-Object @{N = 'Id'; E = { $_.extId } },
        @{N = 'Title'; E = { $_.title } },
        @{N = 'Severity'; E = { $_.severity } },
        @{N = 'CreatedTime'; E = { $_.creationTime } },
        @{N = 'LastUpdated'; E = { $_.lastUpdatedTime } },
        @{N = 'ImpactTypes'; E = { $_.impactTypes -join '; ' } },
        @{N = 'SourceEntityName'; E = { $_.sourceEntity.name } },
        @{N = 'SourceEntityType'; E = { $_.sourceEntity.type } },
        @{N = 'ClusterName'; E = { $_.clusterName } },
        @{N = 'ClusterUuid'; E = { $_.clusterUUID } },
        @{N = 'IsAcknowledged'; E = { $_.isAcknowledged } },
        @{N = 'IsResolved'; E = { $_.isResolved } }

    # Export the processed data to a CSV file that can be opened by Excel.
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
