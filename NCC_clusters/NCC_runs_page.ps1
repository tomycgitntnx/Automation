# NCC_clusters.ps1 v1.6  Sept 19, 2025
# This script runs full NCC checks on all clusters in clusters.txt
# v1.1 - Modified to filter output and show only the lines after the final separator.
# v1.2 - Creates a separate output file per cluster in a timestamped directory.
#      - Removes the final "Plugin output written to..." line from the summary.
# v1.3 - Added logic to remove ANSI control/color codes from the output.
# v1.4 - Added HTML report generation to consolidate all cluster outputs into a single webpage.
# v1.5 - Added a summary table to the HTML report with overall status for each cluster.
# v1.6 - Sorts the summary table and details by status (FAIL > WARN > PASS).
# This is not a Nutanix Supported script. Do not use to run any config change or disruptive commnads.
# Usage: .\NCC_clusters.ps1

# Define paths and variables
$clusterFile = ".\clusters.txt"
$plinkPath = "plink.exe"  # Or the full path: "C:\Program Files\PuTTY\plink.exe"
$sshUser = "nutanix"       # Change as needed

#Remote Command setup. Change AOS_command only
$AOS_command="ncc health_checks run_all"

$env="PS1=x source /etc/profile; unset PS1"
$remoteCommand =  $env + ";" + $AOS_command

# Create a timestamped directory for the reports
$dateStamp = Get-Date -Format "yyyy_MM_dd__HH_mm_ss"
$outputDir = ".\NCC_Reports_$dateStamp"
New-Item -ItemType Directory -Path $outputDir -ErrorAction SilentlyContinue | Out-Null

# Check if clusters file exists
if (-not (Test-Path $clusterFile)) {
    Write-Host "File '$clusterFile' not found!" -ForegroundColor Red
    exit 1
}

# Read host entries
$clusters = Get-Content $clusterFile | Where-Object { $_.Trim() -ne "" }

# Loop through clusters and execute plink
foreach ($namecluster in $clusters) {
    Write-Host "Connecting to $namecluster..." -ForegroundColor Yellow

    $outputFile = Join-Path -Path $outputDir -ChildPath "$namecluster-NCC_Report.txt"

    $plinkArgs = @(
        "-batch",
        "-t",
        "-load", "$namecluster",
        "-l", "nutanix",
        "$remoteCommand"
    )

    $result = & $plinkPath @plinkArgs 2>&1
    $result = $result -replace '\x1B\[[0-9;]*m', ''

    $separator = "-------------------------------------------------------------------------------+"
    $lines = $result -split "`r?`n"

    $lastSeparatorIndex = -1
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        if ($lines[$i].Contains($separator)) {
            $lastSeparatorIndex = $i
            break
        }
    }

    $filteredLines = @()
    if ($lastSeparatorIndex -ne -1 -and ($lastSeparatorIndex + 1 -lt $lines.Count)) {
        $filteredLines = $lines[($lastSeparatorIndex + 1)..($lines.Count - 1)]
    } else {
        Write-Host "Separator not found for $namecluster. Using full output." -ForegroundColor Magenta
        $filteredLines = $lines
    }

    if ($filteredLines.Count -gt 0 -and $filteredLines[-1].TrimStart().StartsWith("Plugin output written to ")) {
        $filteredLines = $filteredLines[0..($filteredLines.Count - 2)]
    }

    Write-Host "===== Summary for $namecluster =====" -ForegroundColor Green
    $filteredLines | ForEach-Object {Write-Host $_ -ForegroundColor Cyan}
    Write-Host ""

    if ($filteredLines.Count -gt 0) {
        Set-Content -Path $outputFile -Value $filteredLines
    } else {
        Set-Content -Path $outputFile -Value "No summary output was found after the separator."
    }
}

Write-Host "All checks complete. Generating HTML report..." -ForegroundColor Yellow

# --- HTML Report Generation ---
$htmlReportPath = Join-Path -Path $outputDir -ChildPath "NCC_Summary_Report.html"

# HTML Header and CSS styling
$htmlHead = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Nutanix NCC Summary Report - $dateStamp</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif; background-color: #f4f7f9; color: #333; margin: 0; padding: 20px; }
        h1 { color: #003a70; border-bottom: 2px solid #00b1e7; padding-bottom: 10px; }
        h2 { background-color: #003a70; color: white; padding: 12px; border-radius: 5px; margin-top: 40px; }
        pre { background-color: #fff; border: 1px solid #ddd; border-radius: 5px; padding: 15px; white-space: pre-wrap; word-wrap: break-word; font-family: 'Consolas', 'Monaco', monospace; font-size: 14px; line-height: 1.5; }
        .status-pass { color: #28a745; font-weight: bold; }
        .status-fail { color: #dc3545; font-weight: bold; }
        .status-warn { color: #ffc107; font-weight: bold; }
        .status-info { color: #17a2b8; }
        .summary-table { width: 100%; border-collapse: collapse; margin-top: 20px; margin-bottom: 40px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        .summary-table th, .summary-table td { border: 1px solid #ddd; padding: 12px; text-align: left; }
        .summary-table th { background-color: #e9ecef; color: #333; }
        .summary-table tr:nth-child(even) { background-color: #f8f9fa; }
        .summary-table td a { color: #007bff; text-decoration: none; font-weight: bold; }
        .summary-table td a:hover { text-decoration: underline; }
        footer { text-align: center; margin-top: 40px; font-size: 0.9em; color: #888; }
    </style>
</head>
<body>
    <h1>Nutanix NCC Summary Report</h1>
    <p>Generated on: $dateStamp</p>
"@

# Analyze reports to build summary data first
$summaryData = @()
$reportFiles = Get-ChildItem -Path $outputDir -Filter "*-NCC_Report.txt"

foreach ($reportFile in $reportFiles) {
    $clusterName = ($reportFile.BaseName -split '-NCC_Report')[0]
    $fileContentRaw = Get-Content -Path $reportFile.FullName -Raw
    $status = "INFO"
    $statusClass = "status-info"
    # --- MODIFICATION: Add a numeric priority for sorting ---
    $statusPriority = 4

    # Status is determined by priority: FAIL > WARN > PASS
    if ($fileContentRaw -match 'FAIL') {
        $status = "FAIL"
        $statusClass = "status-fail"
        $statusPriority = 1
    } elseif ($fileContentRaw -match 'WARN') {
        $status = "WARN"
        $statusClass = "status-warn"
        $statusPriority = 2
    } elseif ($fileContentRaw -match 'PASS') {
        $status = "PASS"
        $statusClass = "status-pass"
        $statusPriority = 3
    }

    $summaryData += [PSCustomObject]@{
        ClusterName    = $clusterName
        Status         = $status
        StatusClass    = $statusClass
        ReportFile     = $reportFile
        StatusPriority = $statusPriority # Add the new property to the object
    }
}

# --- MODIFICATION: Sort the data by the new priority property ---
$summaryData = $summaryData | Sort-Object StatusPriority, ClusterName

# Build the HTML summary table
$summaryTableHtml = @"
<h2>Execution Summary</h2>
<table class="summary-table">
    <thead>
        <tr>
            <th>Cluster Name</th>
            <th>Overall Status</th>
        </tr>
    </thead>
    <tbody>
"@

# This loop now processes the pre-sorted data
foreach ($item in $summaryData) {
    $summaryTableHtml += "<tr>"
    $summaryTableHtml += "<td><a href='#cluster-$($item.ClusterName)'>$($item.ClusterName)</a></td>"
    $summaryTableHtml += "<td><span class='$($item.StatusClass)'>$($item.Status)</span></td>"
    $summaryTableHtml += "</tr>`n"
}

$summaryTableHtml += "</tbody></table>"

# Build the detailed HTML body
$htmlBody = ""
# This loop also processes the pre-sorted data, so details match the summary table order
foreach ($item in $summaryData) {
    $htmlBody += "<h2 id='cluster-$($item.ClusterName)'>Cluster: $($item.ClusterName)</h2>"

    $fileContent = Get-Content -Path $item.ReportFile.FullName
    $formattedContent = ""
    foreach ($line in $fileContent) {
        $encodedLine = [System.Web.HttpUtility]::HtmlEncode($line)
        if ($line -match 'FAIL') {
            $formattedContent += "<span class='status-fail'>$encodedLine</span>`n"
        } elseif ($line -match 'WARN') {
            $formattedContent += "<span class='status-warn'>$encodedLine</span>`n"
        } elseif ($line -match 'PASS') {
            $formattedContent += "<span class='status-pass'>$encodedLine</span>`n"
        } elseif ($line -match 'INFO') {
            $formattedContent += "<span class='status-info'>$encodedLine</span>`n"
        } else {
            $formattedContent += "$encodedLine`n"
        }
    }
    $htmlBody += "<pre>$formattedContent</pre>"
}

$htmlFoot = @"
    <footer>Report generated by NCC_clusters.ps1 v1.6</footer>
</body>
</html>
"@

# Combine and save the HTML file
$htmlContent = $htmlHead + $summaryTableHtml + $htmlBody + $htmlFoot
Set-Content -Path $htmlReportPath -Value $htmlContent

# Automatically open the report
Start-Process $htmlReportPath

Write-Host "All done. A consolidated HTML report has been generated and opened." -ForegroundColor Green
Write-Host "Individual logs and the report are saved in '$outputDir'." -ForegroundColor Green
