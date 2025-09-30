<#
.SYNOPSIS
    Retrieves all unresolved alerts from a Nutanix Prism Central (PC) instance
    using the REST API v4.1 and exports them to a CSV file.

.DESCRIPTION
    This script authenticates to the Prism Central v4 API, sends a request to the
    monitoring endpoint to fetch all alerts that are not resolved, handles API
    pagination to ensure all records are retrieved, and then exports the relevant
    details into a CSV file for easy analysis in Excel.

.NOTES
    Author: Tomy Carrasco, Nutanix
    Date: 2025-09-30
    Version: 1.0
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
# This code snippet is derived from internal Nutanix automation examples.<cite id="doc_15"/>
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
    Write-Warning "Could not load the custom SSL certificate policy. The script will continue and rely on -SkipCertificateCheck."
}

# Enforce TLS 1.2 for modern security standards
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

# --- Authentication ---
# Create the Basic Authentication header required by the API.<cite id="doc_15"/><cite id="doc_17"/>
$encodedAuth = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("${username}:${password}"))
$headers = @{
    "Authorization" = "Basic $encodedAuth"
    "Content-Type"  = "application/json"
}

# --- API Endpoint and Filter Definition ---
# The v4.1 API uses a POST request to a /list endpoint to allow for complex filtering.<cite id="doc_0"/>
# The filter below targets alerts where the 'isResolved' property is 'false'.
# For more filter options, refer to the official Nutanix Developer Portal for the Monitoring API v4.1.<cite id="doc_0"/>
$apiUrl = "https://{0}:9440/api/monitoring/v4.1/alerts/list" -f $pcIp
$requestBody = @{
    filterCriteria = "is_resolved==false"
    # The page size can be adjusted. 500 is the maximum allowed.
    pageSize       = 500 
}

# --- Data Retrieval with Pagination Handling ---
$allAlerts = [System.Collections.Generic.List[PSObject]]::new()
$page = 1
$nextCursor = $null

Write-Host "Connecting to $pcIp and fetching unresolved alerts..." -ForegroundColor Cyan

do {
    # If there is a cursor from the previous page, add it to the request body
    if ($null -ne $nextCursor) {
        $requestBody.pageReference = @{
            cursor = $nextCursor
        }
    }

    $bodyAsJson = $requestBody | ConvertTo-Json

    try {
        Write-Host "Fetching page $page..."
        $response = Invoke-RestMethod -Uri $apiUrl -Method Post -Headers $headers -Body $bodyAsJson -ErrorAction Stop

        if ($null -ne $response.data -and $response.data.Count -gt 0) {
            $allAlerts.AddRange($response.data)
            Write-Host "  - Found $($response.data.Count) alerts on this page."
        } else {
             Write-Host "  - No alerts found on this page."
        }

        # The v4 API provides a 'nextCursor' for pagination. If it's null, we've reached the last page.
        $nextCursor = $response.metadata.nextCursor
        $page++

    } catch {
        Write-Error "An error occurred while calling the Nutanix API."
        Write-Error "Status Code: $($_.Exception.Response.StatusCode.value__)"
        Write-Error "Response: $($_.Exception.Response.GetResponseStream() | New-Object System.IO.StreamReader | ForEach-Object { $_.ReadToEnd() })"
        # Stop the script on API failure
        return
    }

} while ($null -ne $nextCursor)

# --- Data Processing and Export ---
if ($allAlerts.Count -gt 0) {
    Write-Host "Total unresolved alerts found: $($allAlerts.Count)." -ForegroundColor Green
    Write-Host "Processing and exporting data to CSV..."

    # Select and flatten the desired properties for a clean CSV output.
    # The properties of an alert object can be nested. We use calculated properties to extract them.
    $exportData = $allAlerts | Select-Object @{N = 'Title'; E = { $_.title } },
        @{N = 'Severity'; E = { $_.severity } },
        @{N = 'CreatedTime'; E = { $_.creationTime } },
        @{N = 'LastOccurred'; E = { $_.lastOccurrenceTime } },
        @{N = 'ImpactType'; E = { $_.impactType } },
        @{N = 'SourceEntityName'; E = { $_.context.originEntity.name } },
        @{N = 'SourceEntityType'; E = { $_.context.originEntity.type } },
        @{N = 'ClusterName'; E = { $_.context.cluster.name } },
        @{N = 'ClusterUuid'; E = { $_.context.cluster.uuid } },
        @{N = 'IsAcknowledged'; E = { $_.isAcknowledged } },
        @{N = 'IsResolved'; E = { $_.isResolved } },
        @{N = 'Id'; E = { $_.extId } }

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
