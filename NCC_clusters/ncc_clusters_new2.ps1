# NCC_clusters.ps1 v1.2  Sept 19, 2025
# This script runs full NCC checks on all clusters in clusters.txt
# v1.1 - Modified to filter output and show only the lines after the final separator.
# v1.2 - Creates a separate output file per cluster in a timestamped directory.
#      - Removes the final "Plugin output written to..." line from the summary.
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

# --- MODIFICATION: Create a timestamped directory for the reports ---
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

    # --- MODIFICATION: Define a unique output file for each cluster ---
    $outputFile = Join-Path -Path $outputDir -ChildPath "$namecluster-NCC_Report.txt"

    $plinkArgs = @(
        "-batch"
        "-t"
       # "-ssh"
        "-load", "$namecluster"
        "-l", "nutanix"
        "$remoteCommand"
    )

    $result = & $plinkPath @plinkArgs 2>&1

    # Filter the output to show only lines after the final separator.
    $separator = "-------------------------------------------------------------------------------+"
    $lines = $result -split "`r?`n" # Split raw output into an array of lines

    # Find the index of the last line containing the separator by searching backwards
    $lastSeparatorIndex = -1
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        if ($lines[$i].Contains($separator)) {
            $lastSeparatorIndex = $i
            break
        }
    }

    # Prepare an array to hold the final, filtered lines
    $filteredLines = @()

    if ($lastSeparatorIndex -ne -1) {
        if ($lastSeparatorIndex + 1 -lt $lines.Count) {
             $filteredLines = $lines[($lastSeparatorIndex + 1)..($lines.Count - 1)]
        }
    } else {
        Write-Host "Separator not found for $namecluster. Using full output." -ForegroundColor Magenta
        $filteredLines = $lines
    }

    # --- MODIFICATION: Remove the last line if it starts with "Plugin output written to " ---
    if ($filteredLines.Count -gt 0 -and $filteredLines[-1].TrimStart().StartsWith("Plugin output written to ")) {
        # Re-create the array, excluding the last element
        $filteredLines = $filteredLines[0..($filteredLines.Count - 2)]
    }

    # Display filtered output on screen:
    Write-Host "===== Summary for $namecluster =====" -ForegroundColor Green
    $filteredLines | ForEach-Object {Write-Host $_ -ForegroundColor Cyan}
    Write-Host "" # Add a blank line for readability

    # Save filtered output to its own file
    if ($filteredLines.Count -gt 0) {
        Set-Content -Path $outputFile -Value $filteredLines
    } else {
        # Create an empty file to signify the check ran but had no summary output
        Set-Content -Path $outputFile -Value "No summary output was found after the separator."
    }
}

Write-Host "All done. Output for each cluster saved in the '$outputDir' directory." -ForegroundColor Green
