# NCC_clusters.ps1 v1.14  Sep 23, 2025
# This script runs full NCC checks on all clusters in clusters.txt
#
# v1.13 - Corrected a typo in the string match for 'Detailed information for'.
# v1.14 - Modified summary to display all status counters, even if zero.
#       - Set specific display order for counters: Fail, Warning, Info, Error, Pass.
#       - Zero-count statuses are now colored gray for better readability.
#
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

# Add System.Web assembly for PS 5.1 compatibility
Add-Type -AssemblyName System.Web

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
        .status-info { color: #0dcaf0; font-weight: bold; }
        .status-warn { color: #ffc107; font-weight: bold; }
        .status-fail { color: #dc3545; font-weight: bold; }
        .status-error { color: #d63384; font-weight: bold; }
        .status-detail-header { color: #87CEFA; }
        .status-info-blue { color: #0d6efd; font-weight: bold; }
        .status-zero { color: #6c757d; font-weight: normal; } /* --- MODIFICATION: New class for zero counts --- */
        .summary-table { width: 100%; border-collapse: collapse; margin-top: 20px; margin-bottom: 40px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        .summary-table th, .summary-table td { border: 1px solid #ddd; padding: 12px; text-align: left; }
        .summary-table th { background-color: #e9ecef; color: #333; }
        .summary-table tr:nth-child(even) { background-color: #f8f9fa; }
        .summary-table td { vertical-align: top; font-family: 'Consolas', 'Monaco', monospace; font-size: 14px; }
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
    $fileContentLines = Get-Content -Path $reportFile.FullName
    $fileContentRaw = $fileContentLines -join "`n"

    $statusPriority = 4
    if ($fileContentRaw -match 'FAIL|Error') {
        $statusPriority = 1
    } elseif ($fileContentRaw -match 'Warning') {
        $statusPriority = 2
    } elseif ($fileContentRaw -match 'PASS') {
        $statusPriority = 3
    }

    # --- MODIFICATION: Set the specific display order for statuses ---
    $statusCounts = [ordered]@{ 'Fail' = 0; 'Warning' = 0; 'Info' = 0; 'Error' = 0; 'Pass' = 0 }

    $headerIndex = -1
    for ($i = 0; $i -lt $fileContentLines.Count; $i++) {
        if ($fileContentLines[$i] -like '*State*' -and $fileContentLines[$i] -like '*Count*') {
            $headerIndex = $i
            break
        }
    }

    if ($headerIndex -ne -1) {
        for ($i = $headerIndex + 2; $i -lt $fileContentLines.Count; $i++) {
            $line = $fileContentLines[$i]
            if ($line.Trim().StartsWith('+--')) { break }
            $parts = $line.Split('|', [System.StringSplitOptions]::RemoveEmptyEntries)
            if ($parts.Count -ge 2) {
                $statusName = $parts[0].Trim()
                if ($statusCounts.Contains($statusName)) {
                    $countString = $parts[1].Trim()
                    if ($countString -match '^\d+$') {
                        $statusCounts[$statusName] = [int]$countString
                    }
                }
            }
        }
    }

    # --- MODIFICATION: Build HTML string, showing all statuses including zero counts ---
    $htmlParts = @()
    foreach ($statusName in $statusCounts.Keys) {
        $count = $statusCounts[$statusName]
        $className = ''

        if ($count -gt 0) {
            # Apply color only if the count is greater than zero
            switch ($statusName) {
                'Fail'    { $className = 'status-fail'; break }
                'Warning' { $className = 'status-warn'; break }
                'Info'    { $className = 'status-info'; break }
                'Error'   { $className = 'status-error'; break }
                'Pass'    { $className = 'status-pass'; break }
            }
        } else {
            # Use the neutral 'status-zero' class for zero counts
            $className = 'status-zero'
        }
        $htmlParts += " <span class='$className'>$statusName $count</span> "
    }
    $detailedStatusHtml = if ($htmlParts.Count -gt 0) {
        '|' + ($htmlParts -join '|') + '|'
    } else {
        "Summary table could not be parsed."
    }

    $summaryData += [PSCustomObject]@{
        ClusterName    = $clusterName
        ReportFile     = $reportFile
        StatusPriority = $statusPriority
        DetailedStatus = $detailedStatusHtml
    }
}

$summaryData = $summaryData | Sort-Object StatusPriority, ClusterName

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

foreach ($item in $summaryData) {
    $summaryTableHtml += "<tr>"
    $summaryTableHtml += "<td><a href='#cluster-$($item.ClusterName)'>$($item.ClusterName)</a></td>"
    $summaryTableHtml += "<td>$($item.DetailedStatus)</td>"
    $summaryTableHtml += "</tr>`n"
}
$summaryTableHtml += "</tbody></table>"

$htmlBody = ""
foreach ($item in $summaryData) {
    $htmlBody += "<h2 id='cluster-$($item.ClusterName)'>Cluster: $($item.ClusterName)</h2>"

    $fileContent = Get-Content -Path $item.ReportFile.FullName
    $formattedContent = ""
    foreach ($line in $fileContent) {
        $encodedLine = [System.Web.HttpUtility]::HtmlEncode($line)
        if ($line -match 'FAIL:') {
            $formattedContent += "<span class='status-fail'>$encodedLine</span>`n"
        } elseif ($line -match 'ERR :') {
            $formattedContent += "<span class='status-error'>$encodedLine</span>`n"
        } elseif ($line -match 'WARN:') {
            $formattedContent += "<span class='status-warn'>$encodedLine</span>`n"
        } elseif ($line -match 'INFO:') {
            $formattedContent += "<span class='status-info-blue'>$encodedLine</span>`n"
        } elseif ($line -match 'Detailed information for') {
            $formattedContent += "<span class='status-detail-header'>$encodedLine</span>`n"
        } elseif ($line -match 'PASS') {
            $formattedContent += "<span class='status-pass'>$encodedLine</span>`n"
        } else {
            $formattedContent += "$encodedLine`n"
        }
    }
    $htmlBody += "<pre>$formattedContent</pre>"
}

$htmlFoot = @"
    <footer>Report generated by NCC_clusters.ps1 v1.14</footer>
</body>
</html>
"@

# Combine and save the HTML file
$htmlContent = $htmlHead + $summaryTableHtml + $htmlBody + $htmlFoot
Set-Content -Path $htmlReportPath -Value $htmlContent

Start-Process $htmlReportPath

Write-Host "All done. A consolidated HTML report has been generated and opened." -ForegroundColor Green
Write-Host "Individual logs and the report are saved in '$outputDir'." -ForegroundColor Green
