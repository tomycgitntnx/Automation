# GGet-NutanixAlerts_ncli_.v1.0.ps1 v1.0 - Nov 26, 2025
#
# This script performs two main functions in one run:
# 1. Gathers active alerts from all clusters in clusters.txt and generates a single,
#    consolidated HTML report with collapsible sections for each cluster.
# 2. Scans for all "Alert_Reports_*" directories and generates or updates a master
#    HTML index page with links to each daily report, grouped by month.
#
# This is not a Nutanix Supported script. Do not use for any config change or disruptive commands.
# Usage: .\Generate-NutanixAlertsAndIndex.ps1

# --- Configuration ---
$clusterFile      = ".\clusters.txt"
$plinkPath        = "plink.exe"  # Or the full path: "C:\Program Files\PuTTY\plink.exe"
$sshUser          = "nutanix"    # Change as needed
$reportsBaseDir   = $PSScriptRoot # Use the script's own directory as the base
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

# --- Directory and File Setup for the new report ---
$dateStamp = Get-Date -Format "yyyy_MM_dd__HH_mm_ss"
$outputDir = Join-Path -Path $reportsBaseDir -ChildPath "Alert_Reports_$dateStamp"
New-Item -ItemType Directory -Path $outputDir -ErrorAction SilentlyContinue | Out-Null
$outputFile = Join-Path -Path $outputDir -ChildPath $reportFileName

# Check if the clusters file exists
if (-not (Test-Path $clusterFile)) {
    Write-Host "File '$clusterFile' not found! Please create it and add your cluster names." -ForegroundColor Red
    exit 1
}
$clusters = Get-Content $clusterFile | Where-Object { $_.Trim() -ne "" }

# --- HTML & CSS Styling for the Consolidated Report ---
$reportHtmlStyle = @"
<style>
    body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif; background-color: #f4f7f9; color: #333; margin: 20px; }
    h1 { color: #003a70; border-bottom: 2px solid #00b1e7; padding-bottom: 10px; }
    details { background-color: #fff; border: 1px solid #ddd; border-radius: 8px; margin-bottom: 15px; }
    summary { font-weight: bold; font-size: 1.2em; cursor: pointer; padding: 15px; background-color: #f7f7f7; border-bottom: 1px solid #ddd; }
    details[open] summary { border-bottom: 1px solid #ddd; }
    .content { padding: 15px; }
    table { border-collapse: collapse; width: 100%; }
    th, td { border: 1px solid #dddddd; text-align: left; padding: 8px; }
    th { background-color: #e9ecef; }
    tr:nth-child(even) { background-color: #f9f9f9; }
    .no-alerts { color: #555; font-style: italic; }
    footer { text-align: center; margin-top: 30px; font-size: 0.9em; color: #888; }
</style>
"@

$htmlBodyContent = "" # Accumulates the HTML for each cluster

# --- Loop through clusters ---
foreach ($namecluster in $clusters) {
    Write-Host "Connecting to $namecluster to gather alerts..." -ForegroundColor Yellow
    $plinkArgs = @("-batch", "-t", "-load", $namecluster, "-l", $sshUser, $remoteCommand)
    $rawOutput = & $plinkPath @plinkArgs 2>&1
    $cleanOutput = $rawOutput -replace '\x1B\[[0-9;]*m', ''

    # --- Parse ncli alert output ---
    $alerts = @()
    $alertBlocks = $cleanOutput -join "`n" -split '(?m)(^\s*$) | (ID\s+:)' | Where-Object { $_.Trim() -ne '' }

    foreach ($block in $alertBlocks) {
        if ($block -match 'Severity' -and $block -match 'Title' -and $block -match 'Message' -and $block -match 'Created On') {
            $alertObject = [PSCustomObject]@{
                Severity   = ($block | Select-String 'Severity\s*:\s*(.*)').Matches.Groups[1].Value.Trim()
                Title      = ($block | Select-String 'Title\s*:\s*(.*)').Matches.Groups[1].Value.Trim()
                Message    = ($block | Select-String 'Message\s*:\s*(.*)').Matches.Groups[1].Value.Trim()
                'Created On' = ($block | Select-String 'Created On\s*:\s*(.*)').Matches.Groups[1].Value.Trim()
            }
            $alerts += $alertObject
        }
    }

    # --- Generate HTML fragment for this cluster ---
    $clusterHtml = "<details open><summary>Cluster: $namecluster ($($alerts.Count) Alerts)</summary><div class='content'>"
    if ($alerts.Count -gt 0) {
        $clusterHtml += $alerts | ConvertTo-Html -Fragment -As Table
        Write-Host "Found $($alerts.Count) alerts on $namecluster." -ForegroundColor Green
    } else {
        $clusterHtml += "<p class='no-alerts'>No alerts found on this cluster.</p>"
        Write-Host "No alerts found on $namecluster." -ForegroundColor Cyan
    }
    $clusterHtml += "</div></details>"
    $htmlBodyContent += $clusterHtml
}

# --- Final HTML Assembly for Consolidated Report ---
$reportDate = Get-Date -Format 'dddd, MMMM dd, yyyy HH:mm'
$reportHtmlHead = @"
<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8"><title>Consolidated Nutanix Alert Report</title>$reportHtmlStyle</head>
<body><h1>Consolidated Nutanix Alert Report</h1><p>Report generated on: $reportDate</p>
"@
$reportHtmlFoot = @"
<footer>Script: Generate-NutanixAlertsAndIndex.ps1 v1.0</footer></body></html>
"@
$finalReportHtml = $reportHtmlHead + $htmlBodyContent + $reportHtmlFoot
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
            [PSCustomObject]@{
                Date         = $reportDate
                MonthYear    = $reportDate.ToString("MMMM yyyy")
                RelativePath = $_.Name
            }
        } catch { Write-Warning "Could not parse date from directory: '$($_.Name)'. Skipping." }
    }
}

if (-not $reportData) {
    $errorMessage = "<h1>No Alert Reports Found</h1><p>No directories matching '$reportDirPattern' were found.</p>"
    Set-Content -Path $masterIndexFile -Value $errorMessage
    Start-Process $masterIndexFile
    Write-Host "No valid Alert report directories found. Created a placeholder index page." -ForegroundColor Red
    exit
}

# --- HTML Generation for Master Index ---
Write-Host "Found $($reportData.Count) total reports. Generating master HTML index..."

# HTML Header and CSS styling for the index page
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
<footer>Index generated by Generate-NutanixAlertsAndIndex.ps1 v1.0</footer></body></html>
"@

# Combine all HTML parts and save the index file
$finalIndexHtml = $indexHtmlHead + $indexHtmlBody + $indexHtmlFoot
Set-Content -Path $masterIndexFile -Value $finalIndexHtml

Write-Host "Success! Master index page '$masterIndexFile' has been created/updated." -ForegroundColor Green

# --- Final Action: Open the Master Index ---
Write-Host "Opening the master index page..."
Start-Process $masterIndexFile
