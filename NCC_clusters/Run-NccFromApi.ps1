
<#
.SYNOPSIS
    This script runs Nutanix Cluster Checks (NCC) on multiple clusters via the Prism Central REST API v4.
.DESCRIPTION
    The script reads a list of Prism Central/Element IPs or FQDNs from a 'clusters.txt' file.
    For each cluster, it authenticates, triggers a full NCC health check, and monitors the task to completion.
    It generates individual JSON reports for each cluster and a consolidated HTML summary report for all clusters.
    This script is designed for PowerShell 5.1 and uses the monitoring/v4.0 API.
.NOTES
    Version: 1.1
    Author: Tomy Carrasco
    Date: 2025-Oct-30
    Requirements: PowerShell 5.1 or later. A 'clusters.txt' file in the same directory.
    Change Log:
    v1.1 - Corrected a variable parsing error in the catch block for IP addresses.
#>

#region Script Configuration
$ClustersFile = "clusters.txt"
$ReportsDir = "NCC_Reports"
$HtmlReportFile = "NCC_Summary_Report.html"
$AllClusterResults = @() # Array to hold results for the HTML report
#endregion

#region Main Execution
# --- Create Reports Directory if it doesn't exist ---
if (-not (Test-Path -Path $ReportsDir)) {
    Write-Host "Creating reports directory: $ReportsDir"
    New-Item -ItemType Directory -Path $ReportsDir | Out-Null
}

# --- Ignore Self-Signed SSL Certificates ---
# This is common in lab environments. For production, consider importing the CA certificate.
try {
    add-type @"
    using System.Net;
    using System.Security.Cryptography.X509Certificates;
    public class TrustAllCertsPolicy : ICertificatePolicy {
        public bool CheckValidationResult(ServicePoint srvPoint, X509Certificate certificate, WebRequest request, int certificateProblem) {
            return true;
        }
    }
"@
    [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
    Write-Host "SSL certificate validation is temporarily bypassed for this session." -ForegroundColor Yellow
}
catch {
    Write-Warning "Could not set custom SSL certificate policy. The script may fail if clusters use self-signed certificates."
}

# --- Check for clusters.txt file ---
if (-not (Test-Path -Path $ClustersFile)) {
    Write-Error "The required file '$ClustersFile' was not found in the current directory."
    exit
}

# --- Get Credentials ---
$Creds = Get-Credential -Message "Enter Prism Central Admin Credentials"
$Username = $Creds.UserName
$Password = $Creds.GetNetworkCredential().Password

# --- Process each cluster ---
$Clusters = Get-Content -Path $ClustersFile | Where-Object { $_.Trim() -ne "" }

foreach ($ClusterAddress in $Clusters) {
    Write-Host "`n" + ("-"*60)
    Write-Host "Processing Cluster: $ClusterAddress" -ForegroundColor Cyan

    try {
        # --- Get Cluster External ID ---
        Write-Host "Step 1: Retrieving Cluster UUID for $ClusterAddress..."
        $clusterUuidEndpoint = "https://_CLUSTER_ADDRESS_:9440/api/nutanix/v3/clusters/list"
        $clusterDetailsUrl = $clusterUuidEndpoint.Replace("_CLUSTER_ADDRESS_", $ClusterAddress)
        $headers = @{
            "Authorization" = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${Username}:${Password}"))
        }

        $clusterListResponse = Invoke-RestMethod -Method Post -Uri $clusterDetailsUrl -Headers $headers -Body "{}" -ContentType "application/json"

        # In a single PE cluster, it might return one object. In PC, it's an array.
        $clusterInfo = if ($clusterListResponse.entities.Count -eq 1) { 
            $clusterListResponse.entities[0] 
        } else {
            # In a PC with multiple clusters, find the one matching the address. This logic assumes name matches address.
            $clusterListResponse.entities | Where-Object { $_.spec.name -eq $ClusterAddress -or $_.status.resources.network.external_ip -eq $ClusterAddress } | Select-Object -First 1
        }

        if (-not $clusterInfo) {
            throw "Could not find a matching cluster for '$ClusterAddress'. Please check the name/IP in clusters.txt."
        }

        $clusterExtId = $clusterInfo.metadata.uuid
        $clusterName = $clusterInfo.spec.name
        Write-Host "  -> Found Cluster Name: $clusterName"
        Write-Host "  -> Found Cluster UUID: $clusterExtId"

        # --- Run Health Checks ---
        Write-Host "Step 2: Initiating NCC Health Checks..."
        $runChecksEndpoint = "https://_CLUSTER_ADDRESS_:9440/api/monitoring/v4.0/serviceability/clusters/$clusterExtId/`$actions/run-health-checks"
        $runChecksUrl = $runChecksEndpoint.Replace("_CLUSTER_ADDRESS_", $ClusterAddress)

        $runChecksResponse = Invoke-RestMethod -Method Post -Uri $runChecksUrl -Headers $headers -Body "{}" -ContentType "application/json"
        $taskExtId = $runChecksResponse.taskExtId
        Write-Host "  -> Health check task started with ID: $taskExtId"

        # --- Monitor Task Progress ---
        Write-Host "Step 3: Monitoring task progress (this can take several minutes)..."
        $taskStatusEndpoint = "https://_CLUSTER_ADDRESS_:9440/api/monitoring/v4.0/serviceability/tasks/$taskExtId"
        $taskStatusUrl = $taskStatusEndpoint.Replace("_CLUSTER_ADDRESS_", $ClusterAddress)
        $currentProgress = 0

        do {
            Start-Sleep -Seconds 20
            $taskStatusResponse = Invoke-RestMethod -Method Get -Uri $taskStatusUrl -Headers $headers
            $currentProgress = $taskStatusResponse.percentageComplete
            $currentStatus = $taskStatusResponse.status
            Write-Host "  -> Task Status: $currentStatus | Progress: $currentProgress%"
        } while ($currentProgress -lt 100 -and $currentStatus -ne 'SUCCEEDED' -and $currentStatus -ne 'FAILED')

        if ($currentStatus -ne 'SUCCEEDED') {
            throw "Health check task failed or did not complete successfully. Status: $currentStatus"
        }
        Write-Host "  -> Health check task completed successfully."

        # --- Get and Save Results ---
        Write-Host "Step 4: Fetching and saving results..."
        $resultsEndpoint = "https://_CLUSTER_ADDRESS_:9440/api/monitoring/v4.0/serviceability/tasks/$taskExtId/`$actions/get-results"
        $resultsUrl = $resultsEndpoint.Replace("_CLUSTER_ADDRESS_", $ClusterAddress)

        $resultsResponse = Invoke-RestMethod -Method Post -Uri $resultsUrl -Headers $headers -Body "{}" -ContentType "application/json"

        $jsonReportPath = Join-Path -Path $ReportsDir -ChildPath "${clusterName}_ncc_report.json"
        $resultsResponse | ConvertTo-Json -Depth 10 | Out-File -FilePath $jsonReportPath
        Write-Host "  -> Detailed report saved to: $jsonReportPath" -ForegroundColor Green

        # --- Collect data for HTML Report ---
        $summary = $resultsResponse.clusterResults[0].checkSummary
        $resultForHtml = [PSCustomObject]@{
            ClusterName     = $clusterName
            CheckTime       = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            NccVersion      = $resultsResponse.clusterResults[0].nccVersion
            PassCount       = $summary.PASS
            FailCount       = $summary.FAIL
            WarnCount       = $summary.WARNING
            InfoCount       = $summary.INFO
            ErrCount        = $summary.ERR
            ReportFile      = $jsonReportPath
        }
        $AllClusterResults += $resultForHtml
    }
    catch {
        # --- CORRECTED LINE ---
        Write-Error "An error occurred while processing ${ClusterAddress}: $_"
        # Add a failure entry to the report
        $AllClusterResults += [PSCustomObject]@{
            ClusterName     = $ClusterAddress
            CheckTime       = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            NccVersion      = "N/A"
            PassCount       = "N/A"
            FailCount       = "ERROR"
            WarnCount       = "N/A"
            InfoCount       = "N/A"
            ErrCount        = "N/A"
            ReportFile      = "Failed to generate report. Check console for errors."
        }
    }
}
#endregion

#region HTML Report Generation
Write-Host "`n" + ("-"*60)
Write-Host "Generating HTML summary report..." -ForegroundColor Cyan

$Header = @"
<!DOCTYPE html>
<html>
<head>
    <title>Nutanix NCC Health Check Summary</title>
    <style>
        body { font-family: Calibri, sans-serif; margin: 20px; }
        h1 { color: #003a70; }
        table { border-collapse: collapse; width: 100%; box-shadow: 0 2px 5px rgba(0,0,0,0.1); }
        th, td { border: 1px solid #ddd; padding: 12px; text-align: left; }
        th { background-color: #003a70; color: white; }
        tr:nth-child(even) { background-color: #f2f2f2; }
        tr:hover { background-color: #ddd; }
        .status-fail { background-color: #ffcccc; font-weight: bold; }
        .status-warn { background-color: #fff8cc; }
    </style>
</head>
<body>
    <h1>Nutanix NCC Health Check Summary</h1>
    <p>Generated on: $(Get-Date)</p>
<table>
<tr>
    <th>Cluster Name</th>
    <th>Check Time</th>
    <th>NCC Version</th>
    <th>PASS</th>
    <th>FAIL</th>
    <th>WARN</th>
    <th>INFO</th>
    <th>ERROR</th>
    <th>Detailed Report</th>
</tr>
"@

$Body = ""
foreach ($result in $AllClusterResults) {
    $failClass = if ($result.FailCount -gt 0 -or $result.FailCount -eq 'ERROR') { 'class="status-fail"' } else { '' }
    $warnClass = if ($result.WarnCount -gt 0) { 'class="status-warn"' } else { '' }

    $Body += "<tr>"
    $Body += "<td>$($result.ClusterName)</td>"
    $Body += "<td>$($result.CheckTime)</td>"
    $Body += "<td>$($result.NccVersion)</td>"
    $Body += "<td>$($result.PassCount)</td>"
    $Body += "<td $failClass>$($result.FailCount)</td>"
    $Body += "<td $warnClass>$($result.WarnCount)</td>"
    $Body += "<td>$($result.InfoCount)</td>"
    $Body += "<td>$($result.ErrCount)</td>"
    $Body += "<td>$($result.ReportFile)</td>"
    $Body += "</tr>"
}

$Footer = @"
</table>
</body>
</html>
"@

$htmlContent = $Header + $Body + $Footer
$htmlContent | Out-File -FilePath $HtmlReportFile

Write-Host "HTML report generated successfully: $HtmlReportFile" -ForegroundColor Green
Write-Host "Script execution finished."
#endregion
