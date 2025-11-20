<#
.SYNOPSIS
    Retrieves all unresolved alerts from multiple Nutanix Prism Central instances and generates HTML reports.

.DESCRIPTION
    This script connects to a list of Prism Central (PC) instances specified in a text file,
    authenticates using the Nutanix REST API v4.0.b1, and fetches all unresolved alerts.
    It then generates two HTML reports: a main index page listing all daily reports, and a
    detailed report for the current day's alerts.

.REQUIREMENTS
    - PowerShell 5.1 or later.
    - A 'clusters.txt' file in the same directory as the script, containing one
      Prism Central IP/FQDN per line.
    - An 'alert_reports' subdirectory will be created in the script's location to store the HTML files.

.NOTES
    Author: Tomy Carrasco (alvaro.carrasc@nutanix.com)
    Date:   2025-Nov-20
    Version: 2.1
#>

# --- Script Configuration ---
$credentialFile = ".\credential.xml"
$clusterFile = ".\clusters.txt"
$reportsDir = ".\alert_reports" # Directory to store HTML reports

# --- Main Script Body ---

#region Functions
function Get-Credentials {
    param ([string]$Path)
    try {
        if (Test-Path -Path $Path) {
            Write-Verbose "Credential file found. Importing credentials."
            return Import-CliXml -Path $Path
        } else {
            Write-Host "Credential file not found. Please enter your Prism Central credentials."
            $credential = Get-Credential
            $credential | Export-CliXml -Path $Path
            Write-Host "Credentials saved securely to '$Path' for future use."
            return $credential
        }
    } catch {
        Write-Error "Failed to get or save credentials. Error: $($_.Exception.Message)"
        return $null
    }
}

function Get-UnresolvedNutanixAlerts {
    param (
        [string]$PrismCentral,
        [System.Management.Automation.PSCredential]$Credential
    )
    $username = $Credential.UserName
    $password = $Credential.GetNetworkCredential().Password
    $base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${username}:${password}"))
    $headers = @{"Authorization" = "Basic $base64AuthInfo"; "Content-Type" = "application/json"}
    $uri = "https://{0}:9440/api/monitoring/v4.0.b1/serviceability/alerts?`$filter=isResolved eq false" -f $PrismCentral
    Write-Host "Querying unresolved alerts from '$PrismCentral'..."
    try {
        # The Invoke-RestMethod call assumes trusted certificates. 
        # Add -SkipCertificateCheck if you are in a lab environment with self-signed certs.
        $response = Invoke-RestMethod -Method Get -Uri $uri -Headers $headers
        return $response.data
    } catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        $statusDescription = $_.Exception.Response.StatusDescription
        Write-Error "API call to '$PrismCentral' failed with status $statusCode ($statusDescription)."
        Write-Error "Error details: $($_.Exception.Message)"
        return $null
    }
}

function Generate-HtmlReports {
    param (
        [array]$AllAlerts,
        [string]$ReportsDirectory
    )

    # --- HTML and CSS Style ---
    $htmlStyle = @"
<style>
    body { font-family: 'Segoe UI', Arial, sans-serif; margin: 20px; background-color: #f4f4f4; color: #333; }
    h1, h2, h3 { color: #003a70; border-bottom: 2px solid #0056a4; padding-bottom: 5px; }
    h1 { font-size: 28px; }
    h2 { font-size: 24px; margin-top: 30px; }
    h3 { font-size: 20px; border-bottom: 1px solid #ccc; }
    a { color: #0078d4; text-decoration: none; }
    a:hover { text-decoration: underline; }
    .summary-table, .alerts-table { border-collapse: collapse; width: 100%; margin-top: 20px; box-shadow: 0 2px 5px rgba(0,0,0,0.1); }
    .summary-table th, .alerts-table th { background-color: #0056a4; color: white; padding: 12px 15px; text-align: left; }
    .summary-table td, .alerts-table td { padding: 10px 15px; border: 1px solid #ddd; }
    .summary-table tr:nth-child(even), .alerts-table tr:nth-child(even) { background-color: #f2f2f2; }
    .critical { background-color: #ff8080 !important; color: black; }
    .warning { background-color: #ffff99 !important; color: black; }
    .info { background-color: #add8e6 !important; color: black; }
    .summary-critical { color: red; font-weight: bold; }
    .summary-warning { color: #f0ad4e; font-weight: bold; }
    .summary-info { color: #5bc0de; font-weight: bold; }
    .collapsible { background-color: #003a70; color: white; cursor: pointer; padding: 15px; width: 100%; border: none; text-align: left; outline: none; font-size: 18px; margin-top: 10px; }
    .active, .collapsible:hover { background-color: #0056a4; }
    .collapsible:after { content: '\002B'; color: white; font-weight: bold; float: right; margin-left: 5px; }
    .active:after { content: "\2212"; }
    .content { padding: 0 18px; max-height: 0; overflow: hidden; transition: max-height 0.2s ease-out; background-color: white; }
    .content ul { list-style-type: none; padding-left: 0; }
    .content li { margin: 5px 0; }
    .report-container { background-color: white; padding: 25px; border-radius: 8px; box-shadow: 0 4px 8px rgba(0,0,0,0.1); }
    .back-link { display: inline-block; margin: 20px 0; font-size: 16px; }
</style>
<script>
    document.addEventListener('DOMContentLoaded', function() {
        var coll = document.getElementsByClassName("collapsible");
        for (var i = 0; i < coll.length; i++) {
            coll[i].addEventListener("click", function() {
                this.classList.toggle("active");
                var content = this.nextElementSibling;
                if (content.style.maxHeight){
                    content.style.maxHeight = null;
                } else {
                    content.style.maxHeight = content.scrollHeight + "px";
                } 
            });
        }
    });
</script>
"@

    # --- Daily Report Generation ---
    $today = (Get-Date).ToString("yyyy-MM-dd")
    $dailyReportFileName = "$($today)-Alerts.html"
    $dailyReportPath = Join-Path -Path $ReportsDirectory -ChildPath $dailyReportFileName
    $groupedAlerts = $AllAlerts | Group-Object -Property PrismCentral

    # Build Summary Section
    $summaryHtml = "<h2>Alerts Summary</h2><table class='summary-table'><tr><th>Prism Central</th><th>Critical</th><th>Warning</th><th>Info</th><th>Total</th></tr>"
    foreach ($group in $groupedAlerts) {
        $pcName = $group.Name
        $counts = $group.Group | Group-Object -Property Severity -NoElement
        $criticalCount = ($counts | Where-Object { $_.Name -eq 'CRITICAL' }).Count | ForEach-Object { if ($_) { $_ } else { 0 } }
        $warningCount = ($counts | Where-Object { $_.Name -eq 'WARNING' }).Count | ForEach-Object { if ($_) { $_ } else { 0 } }
        $infoCount = ($counts | Where-Object { $_.Name -eq 'INFO' }).Count | ForEach-Object { if ($_) { $_ } else { 0 } }
        $total = $group.Count
        $summaryHtml += "<tr><td><a href='#$pcName'>$pcName</a></td><td class='summary-critical'>$criticalCount</td><td class='summary-warning'>$warningCount</td><td class='summary-info'>$infoCount</td><td>$total</td></tr>"
    }
    $summaryHtml += "</table>"

    # Build Detailed Alerts Section
    $detailsHtml = ""
    foreach ($group in $groupedAlerts) {
        $pcName = $group.Name
        $detailsHtml += "<h2 id='$pcName'>Alerts for $pcName</h2>"
        $detailsHtml += "<table class='alerts-table'><tr><th>Severity</th><th>Title</th><th>Created Time</th><th>Cluster</th><th>Entity</th><th>Message</th><th>Resolution</th><th>Root Cause Analysis</th></tr>"
        foreach ($alert in $group.Group) {
            $severityClass = switch ($alert.Severity) {
                'CRITICAL' { 'critical' }
                'WARNING' { 'warning' }
                'INFO' { 'info' }
                default { '' }
            }
            # Make HTTP links clickable
            $message = $alert.Message -replace '(https?://[^\s]+)', '<a href="$1" target="_blank">$1</a>'
            # Make Cluster name clickable
            $clusterLink = if ($alert.Cluster) { "<a href='https://$( $alert.Cluster ):9440/' target='_blank'>$($alert.Cluster)</a>" } else { "N/A" }
            $detailsHtml += "<tr class='$severityClass'><td>$($alert.Severity)</td><td>$($alert.Title)</td><td>$($alert.CreatedTime)</td><td>$clusterLink</td><td>$($alert.SourceEntity)</td><td>$message</td><td>$($alert.Resolution)</td><td>$($alert.RootCauseAnalysis)</td></tr>"
        }
        $detailsHtml += "</table><a href='#top' class='back-link'>Back to Top</a>"
    }

    $dailyReportContent = @"
<!DOCTYPE html>
<html>
<head>
    <title>Nutanix Daily Alerts Report - $today</title>
    $htmlStyle
</head>
<body id='top'>
    <div class='report-container'>
        <h1>Nutanix Daily Alerts Report - $today</h1>
        <a href='index.html' class='back-link'>&larr; Back to Main Index</a>
        $summaryHtml
        $detailsHtml
    </div>
</body>
</html>
"@
    $dailyReportContent | Out-File -FilePath $dailyReportPath -Encoding utf8
    Write-Host "Daily report generated at '$dailyReportPath'" -ForegroundColor Cyan

    # --- Main Index Page Update ---
    $indexPath = Join-Path -Path $ReportsDirectory -ChildPath "index.html"
    $allReports = Get-ChildItem -Path $ReportsDirectory -Filter "*-Alerts.html" | Sort-Object Name -Descending
    $groupedReports = $allReports | Group-Object { (Get-Date $_.BaseName.Substring(0, 10)).ToString("MMMM yyyy") }

    $indexBody = ""
    foreach ($monthGroup in $groupedReports) {
        $indexBody += "<button class='collapsible'>$($monthGroup.Name)</button><div class='content'><ul>"
        foreach ($report in $monthGroup.Group) {
            $reportDate = $report.BaseName.Substring(0, 10)
            $indexBody += "<li><a href='$($report.Name)'>Alert Report for $reportDate</a></li>"
        }
        $indexBody += "</ul></div>"
    }

    $indexContent = @"
<!DOCTYPE html>
<html>
<head>
    <title>Nutanix Alerts Report Index</title>
    $htmlStyle
</head>
<body>
    <div class='report-container'>
        <h1>Nutanix Alerts Report Index</h1>
        $indexBody
    </div>
</body>
</html>
"@
    $indexContent | Out-File -FilePath $indexPath -Encoding utf8
    Write-Host "Index page updated at '$indexPath'" -ForegroundColor Cyan
}

#endregion Functions

#region Script Execution

[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

if (-not (Test-Path -Path $clusterFile)) {
    Write-Error "The required file '$clusterFile' was not found. Please create it and add Prism Central addresses."
    exit
}

if (-not (Test-Path -Path $reportsDir)) {
    Write-Host "Creating reports directory at '$reportsDir'..."
    New-Item -Path $reportsDir -ItemType Directory | Out-Null
}

$creds = Get-Credentials -Path $credentialFile
if ($null -eq $creds) {
    Write-Error "Could not obtain credentials. Exiting script."
    exit
}

$pcList = Get-Content -Path $clusterFile | Where-Object { $_ -notlike '#*' -and $_.Trim() -ne '' }
if ($pcList.Count -eq 0) {
    Write-Warning "The '$clusterFile' is empty or contains no valid entries."
    exit
}

$allAlerts = @()
foreach ($pc in $pcList) {
    Write-Host "--- Processing Prism Central: $pc ---" -ForegroundColor Green
    $alerts = Get-UnresolvedNutanixAlerts -PrismCentral $pc -Credential $creds
    if ($null -ne $alerts) {
        if ($alerts.Count -gt 0) {
            Write-Host "Found $($alerts.Count) unresolved alerts on '$pc'." -ForegroundColor Yellow
            $alerts.ForEach({
                $allAlerts += [PSCustomObject]@{
                    PrismCentral      = $pc
                    Title             = $_.title
                    Severity          = $_.severity
                    CreatedTime       = $_.creationTime
                    Cluster           = $_.sourceCluster.name
                    SourceEntity      = $_.sourceEntity.name
                    EntityType        = $_.sourceEntity.entityType
                    Message           = $_.message
                    Resolution        = $_.probableCause
                    RootCauseAnalysis = $_.rootCauseAnalysis
                    LastUpdateTime    = $_.lastUpdateTime
                }
            })
        } else {
            Write-Host "No unresolved alerts found on '$pc'."
        }
    } else {
        Write-Warning "Skipping '$pc' due to a previous error."
    }
    Write-Host "--------------------------------------`n" -ForegroundColor Green
}

if ($allAlerts.Count -gt 0) {
    Generate-HtmlReports -AllAlerts $allAlerts -ReportsDirectory $reportsDir
} else {
    Write-Host "No unresolved alerts found across all Prism Central instances. HTML reports were not generated."
}

Write-Host "Script execution complete." -ForegroundColor Green

#endregion Script Execution
