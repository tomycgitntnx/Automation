<#
.SYNOPSIS
    Gathers unresolved alerts from multiple Nutanix Prism Central instances and generates an HTML report.

.DESCRIPTION
    This script connects to a list of Prism Central instances defined in 'clusters.txt',
    fetches all unresolved alerts for Prism Element clusters using the Nutanix v4 Monitoring API,
    and creates a detailed HTML report organized by cluster. It also maintains a master index HTML page.

    Features:
    - Reads PC addresses from an external file.
    - Securely stores and retrieves credentials.
    - Generates a timestamped HTML report for each run.
    - Color-codes alerts by severity (Critical, Warning, Info).
    - Includes a summary index at the top of the report.
    - Creates collapsible sections for each cluster's alerts.
    - Maintains a master 'index.html' page listing all reports by month.

.NOTES
    Author: Tomy Carrasco
    Date: 2025-Oct-27
    Version: 1.9 - Fixed summary counter logic (case-insensitive), sorting improvements, PowerShell 5.1 optimized.
#>

# --- Script Configuration ---
$username = "admin"
$credentialFile = "credential.xml"
$pcListFile = "clusters.txt"
$reportsDir = ".\Reports" # Directory to store HTML reports

# --- Main Execution Logic ---
function Main {
    # Ensure the reports directory exists
    if (-not (Test-Path $reportsDir)) {
        New-Item -Path $reportsDir -ItemType Directory | Out-Null
    }

    # 1. Get Credentials
    $credential = Get-Credentials -Username $username -CredentialFile $credentialFile

    # 2. Read PC List
    if (-not (Test-Path $pcListFile)) {
        Write-Error "PC list file not found: $pcListFile"
        return
    }
    $pcAddresses = Get-Content $pcListFile | Where-Object { $_.Trim() -ne "" }

    # 3. Initialize a collection for all alerts
    $allAlerts = @()

    # 4. Process each Prism Central to gather all alerts
    foreach ($pcAddress in $pcAddresses) {
        Write-Host "Connecting to Prism Central: $pcAddress"
        $apiUrl = "https://{0}:9440/api/monitoring/v4.0/serviceability/alerts" -f $pcAddress

        # Manually create the Authorization header
        $password = $credential.GetNetworkCredential().Password
        $authHeader = "Basic " + [Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes(("{0}:{1}" -f $credential.UserName, $password)))
        $headers = @{ "Authorization" = $authHeader; "Content-Type" = "application/json" }

        # Use the filter and expand parameter
        $filter = "?`$filter=isResolved eq false and sourceEntity/type eq 'cluster'&`$expand=sourceEntity"
        $fullUrl = $apiUrl + $filter

        try {
            $response = Invoke-RestMethod -Uri $fullUrl -Method Get -Headers $headers -ErrorAction Stop
            if ($null -ne $response.data) {
                # Force response data to be an array even if only one item is returned
                $retrievedAlerts = @($response.data)

                Write-Host "Successfully retrieved $($retrievedAlerts.Count) unresolved alerts from $pcAddress."
                $allAlerts += $retrievedAlerts
            } else {
                Write-Host "No unresolved alerts from Prism Element clusters found on $pcAddress."
            }
        } catch {
            Write-Warning "Failed to retrieve alerts from $pcAddress. Error: $($_.Exception.Message)"
        }
    }

    # 5. Group all collected alerts by their source cluster name
    $alertsByCluster = $allAlerts | Where-Object { $_.sourceEntity.name } | Group-Object { $_.sourceEntity.name }

    if (-not $alertsByCluster) {
        Write-Warning "No unresolved alerts found on any specified Prism Central. Generating an empty report."
    }

    # 6. Initialize collections for the HTML report
    $htmlBody = ""
    $summaryData = @()

    # 7. Process each cluster’s group of alerts
    foreach ($clusterGroup in ($alertsByCluster | Sort-Object Name)) {
        $clusterN
