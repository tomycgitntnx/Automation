# Generate-NutanixAlertsAndIndex.ps1 v2.4 - Nov 26, 2025
#
# This script performs two main functions in one run:
# 1. Gathers active alerts from all clusters and generates an advanced, consolidated HTML
#    report with a summary, collapsible/nested sections, color-coding, and navigation links.
# 2. Scans for all report directories and generates or updates a master HTML index page.
#
# v2.4 Updates:
# - Corrected the logic for the time-based color-coding of the "Created On" date.
#   The script now correctly categorizes alerts less than 24 hours, between 1-7 days,
#   and older than 30 days.
#
# This is not a Nutanix Supported script. Do not use for any config change or disruptive commands.
# Usage: .\Generate-NutanixAlertsAndIndex.ps1

# --- Configuration ---
$clusterFile      = ".\clusters.txt"
$plinkPath        = "plink.exe"  # Or the full path: "C:\Program Files\PuTTY\plink.exe"
$sshUser          = "nutanix"    # Change as needed
$reportsBaseDir   = $PSScriptRoot
$reportDirPattern = "Alert_Reports_*"
$masterIndexFile  = Join-Path -Path $reportsBaseDir -ChildPath "Alert_Master_Index.html"
$reportFileName   = "Consolidated_Alert_Report.html"

# Define the remote command to be executed
$AOS_command   = "ncli alerts list max-alerts=500"
$env           = "PS1=x source /etc/profile; unset PS1"
$remoteCommand = "$env;$AOS_command"

# =================================================================================
# PART 1: GATHER ALERTS AND CREATE CONSOLIDATED REPORT
# =================================================================================
Write-Host "--- Starting Part 1: Generating Consolidated Alert Report ---" -ForegroundColor Cyan

# --- Directory and File Setup ---
$dateStamp = Get-Date -Format "yyyy_MM_dd__HH_mm_ss"
$outputDir = Join-Path -Path $reportsBaseDir -ChildPath "Alert_Reports_$dateStamp"
New-Item -ItemType Directory -Path $outputDir -ErrorAction SilentlyContinue | Out-Null
$outputFile = Join-Path -Path $outputDir -ChildPath $reportFileName

if (-not (Test-Path $clusterFile)) {
    Write-Host "File '$clusterFile' not found! Please create it." -ForegroundColor Red
    exit 1
}
$clusters = Get-Content $clusterFile | Where-Object { $_.Trim() -ne "" }

# --- HTML & CSS Styling for the Report ---
$reportHtmlStyle = @"
<style>
    body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif; background-color: #f4f7f9; color: #333; margin: 20px; scroll-behavior: smooth; }
    h1, h2 { color: #003a70; border-bottom: 2px solid #00b1e7; padding-bottom: 10px; }
    h1 a { font-size: 0.6em; text-decoration: none; color: #007bff; font-weight: normal; vertical-align: middle; margin-left: 20px;}
    h1 a:hover { text-decoration: underline; }

    details.cluster-section { background-color: #fff; border: 1px solid #ddd; border-radius: 8px; margin-bottom: 20px; }
    details.cluster-section > summary { display: flex; justify-content: space-between; align-items: center; font-weight: bold; font-size: 1.3em; cursor: pointer; padding: 15px; background-color: #f0f5f9; border-radius: 8px 8px 0 0; }
    .cluster-title .launch-link { font-size: 0.8em; text-decoration: none; }
    .back-to-summary { font-size: 0.7em; font-weight: normal; }

    details.alert-group { background: #fafafa; border: 1px solid #e0e0e0; border-radius: 5px; margin: 10px 0; }
    details.alert-group > summary { font-weight: bold; font-size: 1.0em; cursor: pointer; padding: 10px; }

    .content { padding: 5px 20px 20px 20px; }
    table { border-collapse: collapse; width: 100%; }
    th, td { border: 1px solid #dddddd; text-align: left; padding: 8px; }
    th { background-color: #e9ecef; }

    /* Summary Count Colors */
    .count-zero     { color: #28a745; font-weight: bold; }
    .count-info     { color: #0dcaf0; font-weight: bold; }
    .count-warning  { color: #ffc107; font-weight: bold; }
    .count-critical { color: #dc3545; font-weight: bold; }

    /* Alert Age Colors for 'Created On' date */
    .age-new   { color: #0dcaf0; } /* < 24 hours */
    .age-week  { color: #ffc107; } /* 1-7 days */
    .age-old   { color: #dc3545; } /* > 30 days */
</style>
"@

$allClustersSummaryData = @()
$allClustersHtmlBody = ""
$reportTime = Get-Date # Get the current time once for consistent age calculation

# --- Main Loop through clusters ---
foreach ($namecluster in $clusters) {
    Write-Host "Connecting to $namecluster to gather alerts..." -ForegroundColor Yellow
    $plinkArgs = @("-batch", "-t", "-load", $namecluster, "-l", $sshUser, $remoteCommand)
    $rawOutput = & $plinkPath @plinkArgs 2>&1
    $cleanOutput = $rawOutput -replace '\x1B\[[0-9;]*m', ''

    # --- Parse ncli alert output ---
    $alerts = @()
    $alertBlocks = $cleanOutput -join "`n" -split '(?m)(^\s*$) | (ID\s+:)' | Where-Object { $_.Trim() -ne '' }
    foreach ($block in $alertBlocks) {
        if ($block -match 'Severity' -and $block -match 'Title' -and $block -match 'Created On') {
            $createdOnStr = ($block | Select-String 'Created On\s*:\s*(.*)').Matches.Groups[1].Value.Trim()
            $alertObject = [PSCustomObject]@{
                Severity   = ($block | Select-String 'Severity\s*:\s*k?(.*)').Matches.Groups[1].Value.Trim()
                Title      = ($block | Select-String 'Title\s*:\s*(.*)').Matches.Groups[1].Value.Trim()
                Message    = ($block | Select-String 'Message\s*:\s*(.*)').Matches.Groups[1].Value.Trim()
                'CreatedOnStr' = $createdOnStr
            }
            $alerts += $alertObject
        }
    }

    Write-Host "Found $($alerts.Count) alerts on $namecluster." -ForegroundColor Green

    # Calculate alert counts for the summary table
    $severityCounts = $alerts | Group-Object -Property Severity
    $summaryData = [PSCustomObject]@{
        ClusterName = $namecluster
        Critical    = ($severityCounts | Where-Object { $_.Name -eq 'Critical' }).Count
        Warning     = ($severityCounts | Where-Object { $_.Name -eq 'Warning' }).Count
        Info        = ($severityCounts | Where-Object { $_.Name -eq 'Info' }).Count
    }
    $allClustersSummaryData += $summaryData

    # --- Generate HTML for this specific cluster ---
    $clusterAnchor = "cluster-$namecluster"
    $allClustersHtmlBody += "<details id='$clusterAnchor' class='cluster-section' open>"
    $allClustersHtmlBody += "<summary><span class='cluster-title'>$namecluster <a class='launch-link' href='https://s1-nx-vm:9440' target='_blank'>&#x2197;</a></span><a class='back-to-summary' href='#summary'>Back to Summary</a></summary>"
    $allClustersHtmlBody += "<div class='content'>"

    if ($alerts.Count -gt 0) {
        $groupedAlerts = $alerts | Group-Object -Property Title
        foreach ($group in $groupedAlerts) {
            $allClustersHtmlBody += "<details class='alert-group' open><summary>$($group.Name) ($($group.Count) instances)</summary>"
            $groupTable = "<table><tr><th>Severity</th><th>Message</th><th>Created On</th></tr>"

            foreach($alert in $group.Group){
                # --- FIX v2.4: Corrected the logic to assign date color class ---
                $ageClass = ""
                try {
                    $createdOnDate = [datetime]::Parse($alert.CreatedOnStr)
                    $alertAge = $reportTime - $createdOnDate

                    if ($alertAge.TotalDays -gt 30) {
                        $ageClass = "age-old"
                    } 
                    elseif ($alertAge.TotalDays -ge 1) { # More than or equal to 1 day but less than 7 (handled by next condition)
                        $ageClass = "age-week"
                    } 
                    elseif ($alertAge.TotalHours -lt 24) { # Less than 24 hours
                        $ageClass = "age-new"
                    }
                } catch {} # Silently ignore parsing errors

                $severityClass = "count-$($alert.Severity)".ToLower()
                $groupTable += "<tr><td class='$severityClass'>$($alert.Severity)</td><td>$($alert.Message)</td><td class='$ageClass'>$($alert.CreatedOnStr)</td></tr>"
            }
            $groupTable += "</table></details>"
            $allClustersHtmlBody += $groupTable
        }
    } else {
        $allClustersHtmlBody += "<p>No alerts found on this cluster.</p>"
    }
    $allClustersHtmlBody += "</div></details>"
}

# --- Build the Summary Table HTML ---
$summaryHtml = "<h2 id='summary'>Alerts Summary</h2>"
if($allClustersSummaryData.Count -gt 0){
    $summaryHtml += "<table><tr><th>Cluster Name</th><th>Critical</th><th>Warning</th><th>Info</th></tr>"
    foreach($summary in $allClustersSummaryData){
        $clusterLink = "<a href='#cluster-$($summary.ClusterName)'>$($summary.ClusterName)</a> <a class='launch-link' href='https://s1-nx-vm:9440' target='_blank'>&#x2197;</a>"

        $criticalCell = if ($summary.Critical -gt 0) { "<td class='count-critical'>$($summary.Critical)</td>" } else { "<td class='count-zero'>$($summary.Critical)</td>" }
        $warningCell  = if ($summary.Warning -gt 0)  { "<td class='count-warning'>$($summary.Warning)</td>" }   else { "<td class='count-zero'>$($summary.Warning)</td>" }
        $infoCell     = if ($summary.Info -gt 0)     { "<td class='count-info'>$($summary.Info)</td>" }         else { "<td class='count-zero'>$($summary.Info)</td>" }

        $summaryHtml += "<tr><td>$clusterLink</td>$criticalCell$warningCell$infoCell</tr>"
    }
    $summaryHtml += "</table>"
} else {
    $summaryHtml += "<p>No cluster data was gathered.</p>"
}

# --- Final HTML Assembly for Consolidated Report ---
$reportDateFormatted = $reportTime.ToString('dddd, MMMM dd, yyyy HH:mm')
$reportHtmlHead = @"
<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8"><title>Consolidated Nutanix Alert Report</title>$reportHtmlStyle</head>
<body><h1>Consolidated Nutanix Alert Report <a href='../$masterIndexFile'>(Back to Master Index)</a></h1><p>Report generated on: $reportDateFormatted</p>
"@
$reportHtmlFoot = @"
<footer>Script: Generate-NutanixAlertsAndIndex.ps1 v2.4</footer></body></html>
"@
$finalReportHtml = $reportHtmlHead + $summaryHtml + $allClustersHtmlBody + $reportHtmlFoot
Set-Content -Path $outputFile -Value $finalReportHtml
Write-Host "`nConsolidated report saved to '$outputFile'" -ForegroundColor Green

# =================================================================================
# PART 2: GENERATE OR UPDATE THE MASTER INDEX PAGE
# =================================================================================
Write-Host "`n--- Starting Part 2: Generating Master Index Page ---" -ForegroundColor Cyan

$reportData = Get-ChildItem -Path $reportsBaseDir -Directory -Filter $reportDirPattern | ForEach-Object {
    if ($_.Name -match '(\d{4}_\d{2}_\d{2}__\d{2}_\d{2}_\d{2})') {
        $dateString = $Matches[1]
        try {
            $reportDate = [datetime]::ParseExact($dateString, "yyyy_MM_dd__HH_mm_ss", $null)
            [PSCustomObject]@{ Date = $reportDate; MonthYear = $reportDate.ToString("MMMM yyyy"); RelativePath = $_.Name }
        } catch { Write-Warning "Could not parse date from directory: '$($_.Name)'. Skipping." }
    }
}

if (-not $reportData) {
    Set-Content -Path $masterIndexFile -Value "<h1>No Alert Reports Found</h1><p>No directories matching '$reportDirPattern' were found.</p>"
    Start-Process $masterIndexFile
    Write-Host "No valid Alert report directories found. Created a placeholder index page." -ForegroundColor Red
    exit
}

# --- HTML Generation for Master Index ---
Write-Host "Found $($reportData.Count) total reports. Generating master HTML index..."
$indexHtmlHead = @"
<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8"><title>Nutanix Alerts - Master Index</title>
<style>
    body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif; background-color: #f4f7f9; color: #333; margin: 0; padding: 20px; }
    h1 { color: #003a70; border-bottom: 2px solid #00b1e7; padding-bottom: 10px; }
    ul { list-style-type: none; padding-left: 0; }
    li { background-color: #fff; margin: 8px 0; padding: 12px 20px; border-radius: 5px; box-shadow: 0 1px 3px rgba(0,0,0,0.08); display: flex; align-items: center; justify-content: space-between; }
    li .date { font-weight: bold; }
    li .links a { text-decoration: none; font-weight: bold; color: #007bff; }
    li .links a:hover { text-decoration: underline; }
    details { background-color: #eef5f9; border: 1px solid #cce0ee; border-radius: 8px; margin-bottom: 20px; }
    summary { font-weight: bold; font-size: 1.2em; cursor: pointer; padding: 15px 20px; background-color: #dceefc; }
    .details-content { padding: 10px 20px 20px 20px; }
    footer { text-align: center; margin-top: 40px; font-size: 0.9em; color: #888; }
</style></head>
<body><h1>Nutanix Alerts - Master Index</h1><p>Last updated on: $(Get-Date -Format 'dddd, MMMM dd, yyyy HH:mm')</p>
"@

$indexHtmlBody = ""
$groupedByMonth = $reportData | Sort-Object Date -Descending | Group-Object -Property MonthYear
foreach ($monthGroup in $groupedByMonth) {
    $indexHtmlBody += "<details open><summary>$($monthGroup.Name)</summary><div class='details-content'><ul>"
    foreach ($report in $monthGroup.Group) {
        $reportFilePath = Join-Path -Path $report.RelativePath -ChildPath $reportFileName
        $reportDateFormatted = $report.Date.ToString("dddd, MMMM dd, yyyy 'at' HH:mm:ss")
        $indexHtmlBody += "<li><span class='date'>$reportDateFormatted</span><span class='links'><a href='$reportFilePath'>View Report</a></span></li>"
    }
    $indexHtmlBody += "</ul></div></details>"
}
$indexHtmlFoot = @"
<footer>Index generated by Generate-NutanixAlertsAndIndex.ps1 v2.4</footer></body></html>
"@

$finalIndexHtml = $indexHtmlHead + $indexHtmlBody + $indexHtmlFoot
Set-Content -Path $masterIndexFile -Value $finalIndexHtml
Write-Host "Success! Master index page '$masterIndexFile' has been created/updated." -ForegroundColor Green

# --- Final Action: Open the Master Index ---
Write-Host "Opening the master index page..."
Start-Process $masterIndexFile
