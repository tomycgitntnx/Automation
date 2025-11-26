# Generate-NutanixAlertsAndIndex.ps1 v2.0 - Nov 26, 2025
#
# This script performs two main functions in one run:
# 1. Gathers active alerts from all clusters and generates an advanced, consolidated HTML
#    report with a summary, collapsible/nested sections, color-coding, and navigation links.
# 2. Scans for all report directories and generates or updates a master HTML index page.
#
# v2.0 Updates:
# - Added a top-level summary table of alert counts per cluster and severity.
# - Color-coded severity cells (Critical=Red, Warning=Yellow, Info=Blue).
# - Removed leading 'k' from severity values.
# - Grouped alerts with the same title into nested collapsible sections.
# - Added a "launch" link to each cluster's Prism Element (:9440).
# - Added internal navigation links (to summary, from summary to index).
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

    /* Main cluster collapsible sections */
    details.cluster-section { background-color: #fff; border: 1px solid #ddd; border-radius: 8px; margin-bottom: 20px; }
    details.cluster-section > summary { font-weight: bold; font-size: 1.3em; cursor: pointer; padding: 15px; background-color: #f0f5f9; border-radius: 8px 8px 0 0; }
    details.cluster-section > summary .launch-link { font-size: 0.7em; font-weight: normal; margin-left: 10px; }

    /* Nested alert title collapsible sections */
    details.alert-group { background: #fafafa; border: 1px solid #e0e0e0; border-radius: 5px; margin: 10px 0; }
    details.alert-group > summary { font-weight: bold; font-size: 1.0em; cursor: pointer; padding: 10px; }

    .content { padding: 5px 20px 20px 20px; }
    .back-to-summary { display: block; margin-top: 15px; font-size: 0.9em; }
    table { border-collapse: collapse; width: 100%; }
    th, td { border: 1px solid #dddddd; text-align: left; padding: 8px; }
    th { background-color: #e9ecef; }

    /* Severity Color-Coding */
    .severity-Critical { background-color: #ffcccc; color: #a60000; font-weight: bold; }
    .severity-Warning  { background-color: #fff5cc; color: #8a6d00; }
    .severity-Info     { background-color: #cce5ff; color: #004085; }

    footer { text-align: center; margin-top: 40px; font-size: 0.9em; color: #888; }
</style>
"@

$allClustersSummaryData = @() # To store summary data for all clusters
$allClustersHtmlBody = ""    # To store detailed HTML for each cluster

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
        if ($block -match 'Severity' -and $block -match 'Title') {
            # --- Change 1 & 2: Remove 'k' and prepare for color-coding ---
            $severity = ($block | Select-String 'Severity\s*:\s*k?(.*)').Matches.Groups[1].Value.Trim()

            $alertObject = [PSCustomObject]@{
                Severity   = $severity
                Title      = ($block | Select-String 'Title\s*:\s*(.*)').Matches.Groups[1].Value.Trim()
                Message    = ($block | Select-String 'Message\s*:\s*(.*)').Matches.Groups[1].Value.Trim()
                'Created On' = ($block | Select-String 'Created On\s*:\s*(.*)').Matches.Groups[1].Value.Trim()
            }
            $alerts += $alertObject
        }
    }

    Write-Host "Found $($alerts.Count) alerts on $namecluster." -ForegroundColor Green

    # --- Change 4: Calculate alert counts for the summary table ---
    $severityCounts = $alerts | Group-Object -Property Severity
    $summaryData = [PSCustomObject]@{
        ClusterName = $namecluster
        Critical    = ($severityCounts | Where-Object { $_.Name -eq 'Critical' }).Count
        Warning     = ($severityCounts | Where-Object { $_.Name -eq 'Warning' }).Count
        Info        = ($severityCounts | Where-Object { $_.Name -eq 'Info' }).Count
    }
    $allClustersSummaryData += $summaryData

    # --- Generate HTML for this specific cluster ---
    # --- Change 6 & 5: Add cluster anchor, launch link, and "back to summary" link ---
    $clusterAnchor = "cluster-$namecluster"
    $allClustersHtmlBody += "<details id='$clusterAnchor' class='cluster-section' open>"
    $allClustersHtmlBody += "<summary>$namecluster <a class='launch-link' href='https://s1-nx-vm:9440' target='_blank'>launch</a></summary>"
    $allClustersHtmlBody += "<div class='content'>"

    if ($alerts.Count -gt 0) {
        # --- Change 3: Group alerts by Title ---
        $groupedAlerts = $alerts | Group-Object -Property Title
        foreach ($group in $groupedAlerts) {
            $allClustersHtmlBody += "<details class='alert-group' open>"
            $allClustersHtmlBody += "<summary>$($group.Name) ($($group.Count) instances)</summary>"

            # Create the table for this group of alerts
            $groupTable = "<table><tr><th>Severity</th><th>Message</th><th>Created On</th></tr>"
            foreach($alert in $group.Group){
                # --- Change 2: Add CSS class for severity color-coding ---
                $groupTable += "<tr><td class='severity-$($alert.Severity)'>$($alert.Severity)</td><td>$($alert.Message)</td><td>$($alert.'Created On')</td></tr>"
            }
            $groupTable += "</table>"
            $allClustersHtmlBody += $groupTable + "</details>"
        }
    } else {
        $allClustersHtmlBody += "<p>No alerts found on this cluster.</p>"
    }

    $allClustersHtmlBody += "<a class='back-to-summary' href='#summary'>Back to Summary</a>"
    $allClustersHtmlBody += "</div></details>"
}

# --- Build the Summary Table HTML (Change 4) ---
$summaryHtml = "<h2 id='summary'>Alerts Summary</h2>"
if($allClustersSummaryData.Count -gt 0){
    $summaryHtml += "<table><tr><th>Cluster Name</th><th>Critical</th><th>Warning</th><th>Info</th></tr>"
    foreach($summary in $allClustersSummaryData){
        $summaryHtml += "<tr><td><a href='#cluster-$($summary.ClusterName)'>$($summary.ClusterName)</a></td>"
        $summaryHtml += "<td class='severity-Critical'>$($summary.Critical)</td>"
        $summaryHtml += "<td class='severity-Warning'>$($summary.Warning)</td>"
        $summaryHtml += "<td class='severity-Info'>$($summary.Info)</td></tr>"
    }
    $summaryHtml += "</table>"
} else {
    $summaryHtml += "<p>No cluster data was gathered.</p>"
}

# --- Final HTML Assembly for Consolidated Report ---
$reportDate = Get-Date -Format 'dddd, MMMM dd, yyyy HH:mm'
# --- Change 5: Add link back to master index ---
$reportHtmlHead = @"
<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8"><title>Consolidated Nutanix Alert Report</title>$reportHtmlStyle</head>
<body><h1>Consolidated Nutanix Alert Report <a href='../$masterIndexFile'>(Back to Master Index)</a></h1><p>Report generated on: $reportDate</p>
"@
$reportHtmlFoot = @"
<footer>Script: Generate-NutanixAlertsAndIndex.ps1 v2.0</footer></body></html>
"@
# Assemble the final report with the summary first, then the details
$finalReportHtml = $reportHtmlHead + $summaryHtml + $allClustersHtmlBody + $reportHtmlFoot
Set-Content -Path $outputFile -Value $finalReportHtml
Write-Host "`nConsolidated report saved to '$outputFile'" -ForegroundColor Green

# =================================================================================
# PART 2: GENERATE OR UPDATE THE MASTER INDEX PAGE
# =================================================================================
Write-Host "`n--- Starting Part 2: Generating Master Index Page ---" -ForegroundColor Cyan

# Find all report directories
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
<footer>Index generated by Generate-NutanixAlertsAndIndex.ps1 v2.0</footer></body></html>
"@

$finalIndexHtml = $indexHtmlHead + $indexHtmlBody + $indexHtmlFoot
Set-Content -Path $masterIndexFile -Value $finalIndexHtml
Write-Host "Success! Master index page '$masterIndexFile' has been created/updated." -ForegroundColor Green

# --- Final Action: Open the Master Index ---
Write-Host "Opening the master index page..."
Start-Process $masterIndexFile
