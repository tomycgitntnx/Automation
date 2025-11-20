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
    Version: 2.3
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
        # Use -SkipCertificateCheck in lab environments with self-signed certs if needed.
        $response = Invoke-RestMethod -Method Get -Uri $uri -Headers $headers

        # Check for the specific "no alerts" response from the API.
        # This response has no 'data' property, which is what we want.
        if ($null -eq $response.data) {
            return @() # Return an empty array to signify no alerts
        }

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

    # --- HTML and CSS Style (White background with colored text for severities) ---
    $htmlStyle = @"
<style>
    body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif; background-color: #f4f7f9; color: #333; margin: 0; padding: 20px; }
    h1 { color: #003a70; border-bottom: 2px solid #00b1e7; padding-bottom: 10px; }
    h2 { font-size: 1.5em; color: #003a70; margin-top: 30px; }
    a { color: #007bff; text-decoration: none; }
    a:hover { text-decoration: underline; }
    ul { list-style-type: none; padding-left: 0; }
    li { background-color: #fff; margin: 8px 0; padding: 12px; border-radius: 5px; box-shadow: 0 1px 3px rgba(0,0,0,0.08); display: flex; align-items: center; justify-content: space-between; }
    li a { font-weight: bold; color: #007bff; }
    details { background-color: #fff; border: 1px solid #ddd; border-radius: 8px; margin-bottom: 10px; box-shadow: 0 1px 3px rgba(0,0,0,0.08); }
    summary { font-weight: bold; font-size: 1.2em; cursor: pointer; padding: 15px 20px; color: #003a70; }
    details > div { padding: 0 20px 20px 20px; }
    footer { text-align: center; margin-top: 40px; font-size: 0.9em; color: #888; }
    .summary-table, .alerts-table { border-collapse: collapse; width: 100%; margin-top: 20px; box-shadow: 0 2px 5px rgba(0,0,0,0.1); border-radius: 5px; overflow: hidden; }
    .summary-table th, .alerts-table th { background-color: #003a70; color: white; padding: 12px 15px; text-align: left; }
    .summary-table td, .alerts-table td { padding: 10px 15px; border: 1px solid #ddd; background-color: #fff; }
    .summary-table tr:nth-child(even) td, .alerts-table tr:nth-child(even) td { background-color: #f8f9fa; }

    /* Colored text for severities */
    .critical td { color: red; font-weight: bold; }
    .warning td { color: #c87600; font-weight: bold; }
    .info td { color: #0056a4; }

    /* Summary count colors */
    .summary-critical { color: red; font-weight: bold; }
    .summary-warning { color: #c87600; font-weight: bold; }
    .summary-info { color: #0056a4; font-weight: bold; }
    .back-link { display: inline-block; margin: 20px 0 10px 0; font-size: 16px; font-weight: bold; }
    .report-container { background-color: #fff; padding: 25px; border-radius: 8px; box-shadow: 0 4px 8px rgba(0,0,0,0.1); }
</style>
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
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Nutanix Daily Alerts Report - $today</title>
    $htmlStyle
</head>
<body id='top'>
    <div class='report-container'>
        <h1>Nutanix Daily Alerts Report ($today)</h1>
        <a href='index.html' class='back-link'>&larr; Back to Main Index</a>
        $summaryHtml
        $detailsHtml
    </div>
    <footer>Report generated on $((Get-Date).ToString("yyyy-MM-dd HH:mm:ss"))</footer>
</body>
</html>
"@
    $dailyReportContent | Out-File -FilePath $dailyReportPath -Encoding utf8
    Write-Host "Daily report generated at '$dailyReportPath'" -ForegroundColor Cyan

    # --- Main Index Page Update ---
    $indexPath = Join-Path -Path $ReportsDirectory -ChildPath "index.html"
    $allReports = Get-ChildItem -Path $ReportsDirectory -Filter "*-Alerts.html" | Sort-Object Name -Descending
    $groupedReports = $allReports | Group-Object { (Get-Date $_.BaseName.Substring(0, 7)).ToString("MMMM yyyy") }

    $indexBody = ""
    foreach ($monthGroup in $groupedReports) {
        $indexBody += "<details open><summary>$($monthGroup.Name)</summary><div><ul>"
        foreach ($report in $monthGroup.Group) {
            $reportDate = $report.BaseName.Substring(0, 10)
            $indexBody += "<li><a href='$($report.Name)'>Alert Report for $reportDate</a></li>"
        }
        $indexBody += "</ul></div></details>"
    }

    $indexContent = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Nutanix Alerts Report Index</title>
    $htmlStyle
</head>
<body>
    <div class='report-container'>
        <h1>Nutanix Alerts Report Index</h1>
        $indexBody
    </div>
    <footer>Index updated on $((Get-Date).ToString("yyyy-MM-dd HH:mm:ss"))</footer>
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

# Always generate/update the reports, even if there are no new alerts to add for the day
Generate-HtmlReports -AllAlerts $allAlerts -ReportsDirectory $reportsDir

Write-Host "Script execution complete." -ForegroundColor Green

#endregion Script Execution
