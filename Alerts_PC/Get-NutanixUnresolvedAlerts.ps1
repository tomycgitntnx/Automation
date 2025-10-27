<#
.SYNOPSIS
    Gathers unresolved alerts from multiple Nutanix Prism Central instances and generates an HTML report.

.DESCRIPTION
    This script connects to a list of Prism Central instances defined in 'clusters.txt',
    fetches all unresolved alerts for Prism Element clusters using the Nutanix v4 REST API,
    and creates a detailed HTML report. It also maintains a master index HTML page of all generated reports.

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
    Version: 1.1 - Corrected for PowerShell 5 compatibility.
    PowerShell Version: 5.1+
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
    $pcAddresses = Get-Content $pcListFile

    # 3. Initialize HTML Report Body
    $htmlBody = ""
    $summaryData = @()

    # 4. Process each Prism Central
    foreach ($pcAddress in $pcAddresses) {
        Write-Host "Connecting to PC: $pcAddress"

        # A. Get PE Clusters managed by this PC
        $peClusters = Get-NutanixPEClusters -PCAddress $pcAddress -Credential $credential
        if (-not $peClusters) {
            Write-Warning "Could not retrieve PE clusters from $pcAddress. Skipping."
            continue
        }

        # B. For each PE Cluster, get unresolved alerts
        foreach ($peCluster in $peClusters) {
            $clusterName = $peCluster.name
            $clusterUuid = $peCluster.extId
            Write-Host "  -> Fetching alerts for cluster: $clusterName ($clusterUuid)"

            $alerts = Get-NutanixUnresolvedAlerts -PCAddress $pcAddress -Credential $credential -ClusterUuid $clusterUuid

            # C. Generate Summary
            $criticalCount = ($alerts | Where-Object { $_.severity -eq 'CRITICAL' }).Count
            $warningCount = ($alerts | Where-Object { $_.severity -eq 'WARNING' }).Count
            $infoCount = ($alerts | Where-Object { $_.severity -eq 'INFO' }).Count

            $summaryData += [PSCustomObject]@{
                ClusterName   = $clusterName
                CriticalCount = $criticalCount
                WarningCount  = $warningCount
                InfoCount     = $infoCount
            }

            # D. Build HTML for this cluster's alerts
            $htmlBody += Build-ClusterAlertsHtml -ClusterName $clusterName -Alerts $alerts
        }
    }

    # 5. Build the complete HTML report
    $timestamp = Get-Date -Format "MM_dd_yyyy__HH_mm_ss"
    $reportFileName = "Nutanix_Unresolved_Alerts_$timestamp.html"
    $reportFilePath = Join-Path $reportsDir $reportFileName

    $finalHtml = Build-FullHtmlReport -SummaryData $summaryData -HtmlBody $htmlBody
    $finalHtml | Out-File -FilePath $reportFilePath -Encoding UTF8

    Write-Host "Successfully generated report: $reportFilePath"

    # 6. Update the master index page
    Update-MasterIndexHtml -ReportsDir $reportsDir

    Write-Host "Master index page updated."
}

# --- Helper Functions ---

function Get-Credentials {
    param(
        [string]$Username,
        [string]$CredentialFile
    )
    if (Test-Path $CredentialFile) {
        # Credential file exists, import it
        Write-Host "Loading credentials from $CredentialFile..."
        return Import-Clixml -Path $CredentialFile
    }
    else {
        # No credential file, prompt user and export
        Write-Host "Credential file not found. Please enter credentials for user '$Username'."
        $cred = Get-Credential -UserName $Username -Message "Enter password for Nutanix API access"
        $cred | Export-Clixml -Path $CredentialFile
        return $cred
    }
}

function Get-NutanixPEClusters {
    param(
        [string]$PCAddress,
        [System.Management.Automation.PSCredential]$Credential
    )
    $uri = "https://$($PCAddress):9440/api/prism/v4.0.b2/clusters?`$filter=type eq 'PRISM_ELEMENT'"
    try {
        $response = Invoke-RestMethod -Method GET -Uri $uri -Credential $Credential -ContentType "application/json"
        return $response.data
    }
    catch {
        Write-Warning "Failed to get PE Clusters from $PCAddress. Error: $($_.Exception.Message)"
        return $null
    }
}

function Get-NutanixUnresolvedAlerts {
    param(
        [string]$PCAddress,
        [System.Management.Automation.PSCredential]$Credential,
        [string]$ClusterUuid
    )
    # API endpoint to get unresolved alerts for a specific cluster
    $filter = "resolved eq false and sourceClusterExtId eq '$($ClusterUuid)'"
    $encodedFilter = [System.Web.HttpUtility]::UrlEncode($filter)
    $uri = "https://$($PCAddress):9440/api/prism/v4.0.b2/alerts?`$filter=$($encodedFilter)"

    try {
        $response = Invoke-RestMethod -Method GET -Uri $uri -Credential $Credential -ContentType "application/json"
        return $response.data
    }
    catch {
        Write-Warning "Failed to get unresolved alerts for cluster $ClusterUuid from $PCAddress. Error: $($_.Exception.Message)"
        return @() # Return empty array on failure
    }
}

function Build-ClusterAlertsHtml {
    param(
        [string]$ClusterName,
        [array]$Alerts
    )
    $clusterAnchor = ($ClusterName -replace '\s','').ToLower()
    $clusterHtml = @"
<details open>
    <summary class="cluster-header"><h2>Cluster: $ClusterName <a href="#index" class="back-link">[Back to Index]</a></h2></summary>
    <div id="$clusterAnchor" class="cluster-content">
"@
    if ($Alerts.Count -eq 0) {
        $clusterHtml += "<p>No unresolved alerts found.</p>"
    }
    else {
        $clusterHtml += @"
    <table>
        <tr>
            <th>Severity</th>
            <th>Title</th>
            <th>Message</th>
            <th>Created Time</th>
            <th>Impact</th>
        </tr>
"@
        # Sort alerts by severity
        $sortedAlerts = $Alerts | Sort-Object @{Expression={@('CRITICAL','WARNING','INFO').IndexOf($_.severity)}}

        foreach ($alert in $sortedAlerts) {
            $severityColor = switch ($alert.severity) {
                'CRITICAL' { 'red' }
                'WARNING' { '#f0ad4e' } # Yellow-ish for better readability
                'INFO'    { 'blue' }
                default   { 'black' }
            }

            # The API returns creationTime as a string in ISO 8601 format (e.g., '2025-10-27T15:30:00Z')
            # Convert it to a local DateTime object for display
            $createdTime = ([datetime]$alert.creationTime).ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss")
            $impact = $alert.impact.type

            $clusterHtml += @"
        <tr>
            <td style="color:$severityColor; font-weight:bold;">$($alert.severity)</td>
            <td>$($alert.title)</td>
            <td>$($alert.detail)</td>
            <td>$createdTime</td>
            <td>$impact</td>
        </tr>
"@
        }
        $clusterHtml += "    </table>"
    }

    $clusterHtml += "    </div></details><hr>"
    return $clusterHtml
}

function Build-FullHtmlReport {
    param(
        [array]$SummaryData,
        [string]$HtmlBody
    )
    # Get the same style as NCC_clusters.ps1
    $htmlStyle = Get-HtmlStyle

    # Build Summary Table
    $summaryTable = @"
<a id="index"></a>
<h2>Alerts Summary</h2>
<table>
    <tr>
        <th>Cluster Name</th>
        <th>Alerts</th>
    </tr>
"@
    foreach ($summary in $SummaryData) {
        $clusterAnchor = ($summary.ClusterName -replace '\s','').ToLower()
        $alertSummary = ""
        if ($summary.CriticalCount -gt 0) {$alertSummary += "<span style='color:red; font-weight:bold;'>Critical: $($summary.CriticalCount)</span> | "}
        else {$alertSummary += "Critical: 0 | "}

        if ($summary.WarningCount -gt 0) {$alertSummary += "<span style='color:#f0ad4e; font-weight:bold;'>Warning: $($summary.WarningCount)</span> | "}
        else {$alertSummary += "Warning: 0 | "}

        if ($summary.InfoCount -gt 0) {$alertSummary += "<span style='color:blue; font-weight:bold;'>Info: $($summary.InfoCount)</span>"}
        else {$alertSummary += "Info: 0"}

        $summaryTable += @"
    <tr>
        <td><a href="#$clusterAnchor">$($summary.ClusterName)</a></td>
        <td>$alertSummary</td>
    </tr>
"@
    }
    $summaryTable += "</table></div><hr>"

    # Combine all parts into a final HTML document
    $html = @"
<!DOCTYPE html>
<html>
<head>
    <title>Nutanix Unresolved Alerts Report</title>
    $htmlStyle
</head>
<body>
    <h1>Nutanix Unresolved Alerts Report</h1>
    <p>Generated on: $(Get-Date)</p>
    $summaryTable
    $HtmlBody
</body>
</html>
"@
    return $html
}

function Update-MasterIndexHtml {
    param(
        [string]$ReportsDir
    )
    $indexFilePath = Join-Path $ReportsDir "index.html"
    $htmlStyle = Get-HtmlStyle

    # Get all report files and group by month
    $reports = Get-ChildItem -Path $ReportsDir -Filter "*.html" | Where-Object { $_.Name -ne 'index.html' } |
               Sort-Object CreationTime -Descending |
               Group-Object { $_.CreationTime.ToString("MMMM yyyy") }

    $indexBody = "<h1>Nutanix Alert Reports Index</h1>"

    foreach ($monthGroup in $reports) {
        $monthName = $monthGroup.Name
        $indexBody += @"
<details open>
    <summary class="cluster-header"><h2>$monthName</h2></summary>
    <div class="cluster-content">
        <ul>
"@
        foreach ($report in $monthGroup.Group) {
            $reportName = $report.Name
            $reportDate = $report.CreationTime.ToString("yyyy-MM-dd HH:mm:ss")
            $indexBody += "            <li><a href='$reportName'>$reportName</a> (Created: $reportDate)</li>`n"
        }
        $indexBody += "        </ul></div></details><hr>"
    }

    $html = @"
<!DOCTYPE html>
<html>
<head>
    <title>Nutanix Reports Index</title>
    $htmlStyle
</head>
<body>
    $indexBody
</body>
</html>
"@
    $html | Out-File -FilePath $indexFilePath -Encoding UTF8
}

function Get-HtmlStyle {
    # This style is based on common Nutanix report styles for a clean, professional look.
    return @"
<style>
    body { font-family: Arial, sans-serif; margin: 20px; background-color: #f4f4f4; color: #333; }
    h1, h2 { color: #003a70; }
    table { border-collapse: collapse; width: 100%; margin-bottom: 20px; background-color: white; }
    th, td { border: 1px solid #dddddd; text-align: left; padding: 8px; }
    th { background-color: #003a70; color: white; }
    tr:nth-child(even) { background-color: #f9f9f9; }
    tr:hover { background-color: #eaf2fa; }
    hr { border: 0; border-top: 1px solid #ccc; }
    details > summary { padding: 10px; background-color: #e8e8e8; border: 1px solid #ccc; cursor: pointer; font-weight: bold; }
    .cluster-header { font-size: 1.2em; }
    .cluster-content { padding: 15px; border: 1px solid #ccc; border-top: none; }
    .back-link { font-size: 0.7em; font-weight: normal; margin-left: 20px; }
    a { color: #007bff; text-decoration: none; }
    a:hover { text-decoration: underline; }
</style>
"@
}

# --- Disable Certificate Validation for PowerShell 5 (for non-production environments) ---
# This approach defines a custom policy to trust all certificates, which is necessary
# when Invoke-RestMethod does not have the -SkipCertificateCheck parameter.
if ($PSVersionTable.PSVersion.Major -le 5) {
    if (-not ([System.Net.ServicePointManager]::CertificatePolicy.GetType().Name -eq 'TrustAllCertsPolicy')) {
        Add-Type -TypeDefinition @"
        using System.Net;
        using System.Security.Cryptography.X509Certificates;
        public class TrustAllCertsPolicy : ICertificatePolicy {
            public bool CheckValidationResult(
                ServicePoint srvPoint, X509Certificate certificate,
                WebRequest request, int certificateProblem) {
                return true;
            }
        }
"@ -ErrorAction SilentlyContinue
        [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
    }
    # Enforce TLS 1.2 for modern security standards
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
}

# --- Start the script ---
Main
