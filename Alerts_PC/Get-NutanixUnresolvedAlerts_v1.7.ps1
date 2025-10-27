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
    Version: 1.8 - Final fix for alert summary counting logic.
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

    # 3. Initialize a collection for all alerts.
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
                # ** THE FIX IS HERE **
                # Force the response data to be an array, even if only one item is returned.
                $retrievedAlerts = @($response.data)

                Write-Host "Successfully retrieved $($retrievedAlerts.Count) unresolved alerts from $pcAddress."
                # Add the guaranteed array of alerts to our main collection.
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

    # If no alerts were found across all PCs, generate an empty report and exit.
    if ($null -eq $alertsByCluster) {
        Write-Warning "No unresolved alerts found on any specified Prism Central. Generating an empty report."
    }

    # 6. Initialize collections for the HTML report
    $htmlBody = ""
    $summaryData = @()

    # 7. Process each cluster's group of alerts to build both summary and body
    # Sort the groups by cluster name to ensure consistent report order
    foreach ($clusterGroup in ($alertsByCluster | Sort-Object Name)) {
        $clusterName = $clusterGroup.Name
        $clusterAlerts = $clusterGroup.Group
        Write-Host "  -> Processing alerts for cluster: $clusterName"

        # A. Generate Summary for the index table
        $criticalCount = ($clusterAlerts | Where-Object { $_.severity -eq 'CRITICAL' }).Count
        $warningCount = ($clusterAlerts | Where-Object { $_.severity -eq 'WARNING' }).Count
        $infoCount = ($clusterAlerts | Where-Object { $_.severity -eq 'INFO' }).Count

        $summaryData += [PSCustomObject]@{
            ClusterName   = $clusterName
            CriticalCount = $criticalCount
            WarningCount  = $warningCount
            InfoCount     = $infoCount
        }

        # B. Build the HTML table for this cluster's alerts
        $htmlBody += Build-ClusterAlertsHtml -ClusterName $clusterName -Alerts $clusterAlerts
    }

    # 8. Build the complete HTML report
    $timestamp = Get-Date -Format "MM_dd_yyyy__HH_mm_ss"
    $reportFileName = "Nutanix_Unresolved_Alerts_$timestamp.html"
    $reportFilePath = Join-Path $reportsDir $reportFileName

    $finalHtml = Build-FullHtmlReport -SummaryData $summaryData -HtmlBody $htmlBody
    $finalHtml | Out-File -FilePath $reportFilePath -Encoding UTF8

    Write-Host "Successfully generated report: $reportFilePath"

    # 9. Update the master index page
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
        Write-Host "Loading credentials from $CredentialFile..."
        return Import-Clixml -Path $CredentialFile
    }
    else {
        Write-Host "Credential file not found. Please enter credentials for user '$Username'."
        $cred = Get-Credential -UserName $Username -Message "Enter password for Nutanix API access"
        $cred | Export-Clixml -Path $CredentialFile
        return $cred
    }
}

function Build-ClusterAlertsHtml {
    param(
        [string]$ClusterName,
        [array]$Alerts
    )
    $clusterAnchor = ($ClusterName -replace '[^a-zA-Z0-9]','').ToLower()
    $clusterHtml = @"
<details open>
    <summary><h2>Cluster: $ClusterName <a href="#index" class="back-link">[Back to Index]</a></h2></summary>
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
                'WARNING'  { '#f0ad4e' } # Yellow-ish for better readability
                'INFO'     { 'blue' }
                default    { 'black' }
            }

            # Convert ISO 8601 string to local time for display
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

    $clusterHtml += "    </div></details>"
    return $clusterHtml
}

function Build-FullHtmlReport {
    param(
        [array]$SummaryData,
        [string]$HtmlBody
    )
    $htmlStyle = Get-HtmlStyle

    # Build Summary Table
    $summaryTable = @"
<div id="index">
<h2>Alerts Summary</h2>
<table>
    <tr>
        <th>Cluster Name</th>
        <th>Alerts</th>
    </tr>
"@
    if ($SummaryData.Count -eq 0) {
        $summaryTable += "<tr><td colspan='2' style='text-align:center;'>No unresolved alerts to summarize.</td></tr>"
    }
    else {
        # Sort summary data by cluster name for consistent order
        foreach ($summary in ($SummaryData | Sort-Object ClusterName)) {
            $clusterAnchor = ($summary.ClusterName -replace '[^a-zA-Z0-9]','').ToLower()
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
    }
    $summaryTable += "</table></div>"

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
    <footer>
        <p>Report generated by the Nutanix Unresolved Alerts Script</p>
    </footer>
</body>
</html>
"@
    return $html
}

function Update-MasterIndexHtml {
    param(
        [string]$ReportsDir
    )
    $indexFilePath = Join-Path $reportsDir "index.html"
    $htmlStyle = Get-HtmlStyle

    $reports = Get-ChildItem -Path $ReportsDir -Filter "*.html" | Where-Object { $_.Name -ne 'index.html' } |
               Sort-Object CreationTime -Descending |
               Group-Object { $_.CreationTime.ToString("MMMM yyyy") }

    $indexBody = "<h1>Nutanix Alert Reports Index</h1>"

    foreach ($monthGroup in $reports) {
        $monthName = $monthGroup.Name
        $indexBody += @"
<details open>
    <summary><h2>$monthName</h2></summary>
    <div class="cluster-content">
        <ul>
"@
        foreach ($report in $monthGroup.Group) {
            $reportName = $report.Name
            $reportDate = $report.CreationTime.ToString("yyyy-MM-dd HH:mm:ss")
            $indexBody += "            <li><span class='date'>$reportDate</span><span class='links'><a href='$reportName'>$reportName</a></span></li>`n"
        }
        $indexBody += "        </ul></div></details>"
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
    <footer>
        <p>Index page generated by the Nutanix Unresolved Alerts Script</p>
    </footer>
</body>
</html>
"@
    $html | Out-File -FilePath $indexFilePath -Encoding UTF8
}

function Get-HtmlStyle {
    # This style is based on the user-provided CSS for a modern look.
    return @"
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif; background-color: #f4f7f9; color: #333; margin: 0; padding: 20px; }
        h1 { color: #003a70; border-bottom: 2px solid #00b1e7; padding-bottom: 10px; }
        h2 { font-size: 1.5em; color: #003a70; }
        ul { list-style-type: none; padding-left: 0; }
        li { background-color: #fff; margin: 8px 0; padding: 12px; border-radius: 5px; box-shadow: 0 1px 3px rgba(0,0,0,0.08); display: flex; align-items: center; justify-content: space-between; }
        li .date { font-weight: bold; }
        li .links a { margin-left: 15px; text-decoration: none; font-weight: bold; color: #007bff; }
        li .links a:hover { text-decoration: underline; }
        details { background-color: #fff; border: 1px solid #ddd; border-radius: 8px; margin-bottom: 20px; }
        summary { font-weight: bold; font-size: 1.2em; cursor: pointer; padding: 10px 20px; position: relative; }
        .cluster-content { padding: 0 20px 20px 20px; }
        .back-link { font-size: 0.7em; font-weight: normal; margin-left: 20px; }
        a { color: #007bff; text-decoration: none; }
        a:hover { text-decoration: underline; }
        table { border-collapse: collapse; width: 100%; margin: 20px 0; background-color: white; border-radius: 5px; box-shadow: 0 1px 3px rgba(0,0,0,0.08); overflow: hidden; }
        th, td { border: 1px solid #dddddd; text-align: left; padding: 12px; }
        th { background-color: #003a70; color: white; font-weight: bold; }
        tr:nth-child(even) { background-color: #f9f9f9; }
        tr:hover { background-color: #eaf2fa; }
        footer { text-align: center; margin-top: 40px; font-size: 0.9em; color: #888; }
    </style>
"@
}

# --- Disable Certificate Validation for PowerShell 5 ---
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
