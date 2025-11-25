# Get-NutanixAlerts.ps1 v1.0 - Sept 19, 2025
# This script gathers active alerts from all clusters in clusters.txt and generates an HTML report.
# Original script by Tomy Carrasco, modified to gather alerts instead of NCC checks.
# This is not a Nutanix Supported script. Do not use to run any config change or disruptive commands.
# Usage: .\Get-NutanixAlerts.ps1

# Define paths and variables
$clusterFile = ".\clusters.txt"
$plinkPath = "plink.exe"  # Or the full path: "C:\Program Files\PuTTY\plink.exe"
$sshUser = "nutanix"       # Change as needed

# --- MODIFICATION: Changed command to get alerts ---
$AOS_command = "ncli alerts list max-alerts=500"

$env = "PS1=x source /etc/profile; unset PS1"
$remoteCommand = $env + ";" + $AOS_command

# Create a timestamped directory for the reports
$dateStamp = Get-Date -Format "yyyy_MM_dd__HH_mm_ss"
$outputDir = ".\Alert_Reports_$dateStamp"
New-Item -ItemType Directory -Path $outputDir -ErrorAction SilentlyContinue | Out-Null

# Check if clusters file exists
if (-not (Test-Path $clusterFile)) {
    Write-Host "File '$clusterFile' not found! Please create it and add your cluster names or IPs." -ForegroundColor Red
    exit 1
}

# Read host entries
$clusters = Get-Content $clusterFile | Where-Object { $_.Trim() -ne "" }

# --- MODIFICATION: Added HTML styling ---
$htmlStyle = @"
<style>
    body { font-family: Calibri, sans-serif; }
    table { border-collapse: collapse; width: 100%; }
    th, td { border: 1px solid #dddddd; text-align: left; padding: 8px; }
    th { background-color: #f2f2f2; }
    tr:nth-child(even) { background-color: #f9f9f9; }
    h1 { color: #003366; }
</style>
"@

# Loop through clusters and execute plink
foreach ($namecluster in $clusters) {
    Write-Host "Connecting to $namecluster to gather alerts..." -ForegroundColor Yellow

    # --- MODIFICATION: Changed output file extension to .html ---
    $outputFile = Join-Path -Path $outputDir -ChildPath "$namecluster-Alert_Report.html"

    $plinkArgs = @(
        "-batch"
        "-t"
        "-load", "$namecluster"
        "-l", $sshUser
        "$remoteCommand"
    )

    $rawOutput = & $plinkPath @plinkArgs 2>&1

    # Remove ANSI escape/color codes from the raw output
    $cleanOutput = $rawOutput -replace '\x1B\[[0-9;]*m', ''

    # --- MODIFICATION: Logic to parse ncli alert output ---
    $alerts = @()
    # Group the output by blank lines to separate each alert
    $alertBlocks = $cleanOutput -join "`n" -split '(?m)(^\s*$) | (ID\s+:)' | Where-Object { $_.Trim() -ne '' }

    foreach ($block in $alertBlocks) {
        # Check if the block contains the required fields
        if ($block -match 'Severity' -and $block -match 'Title' -and $block -match 'Message' -and $block -match 'Created On') {

            # Use RegEx to extract the value for each field
            $alertObject = [PSCustomObject]@{
                Severity   = ($block | Select-String 'Severity\s*:\s*(.*)').Matches.Groups[1].Value.Trim()
                Title      = ($block | Select-String 'Title\s*:\s*(.*)').Matches.Groups[1].Value.Trim()
                Message    = ($block | Select-String 'Message\s*:\s*(.*)').Matches.Groups[1].Value.Trim()
                'Created On' = ($block | Select-String 'Created On\s*:\s*(.*)').Matches.Groups[1].Value.Trim()
            }
            $alerts += $alertObject
        }
    }

    # --- MODIFICATION: Generate HTML content ---
    $htmlBody = "<h1>Alert Report for Cluster: $namecluster</h1>"

    if ($alerts.Count -gt 0) {
        # Convert the array of PowerShell objects directly to an HTML table fragment
        $htmlTable = $alerts | ConvertTo-Html -Fragment -As Table
        $htmlBody += $htmlTable
        Write-Host "Found $($alerts.Count) alerts on $namecluster." -ForegroundColor Green
    } else {
        $htmlBody += "<p>No alerts found on this cluster.</p>"
        Write-Host "No alerts found on $namecluster." -ForegroundColor Cyan
    }

    # Combine all parts into a final HTML document
    $htmlOutput = ConvertTo-Html -Head $htmlStyle -Body $htmlBody

    # Save the HTML report to its file
    Set-Content -Path $outputFile -Value $htmlOutput

    Write-Host "Report saved to '$outputFile'"
    Write-Host "" # Add a blank line for readability
}

Write-Host "All done. Alert reports for each cluster are saved in the '$outputDir' directory." -ForegroundColor Green
