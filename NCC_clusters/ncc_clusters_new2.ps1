# NCC_clusters.ps1 v1.1  Sept 19, 2025
# This script runs full NCC checks on all clusters in clusters.txt
# v1.1 - Modified to filter output and show only the lines after the final separator.
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

# Generate a timestamped output file
$dateStamp = Get-Date -Format "yyyy_MM_dd__HH_mm_ss"
$outputFile = ".\Nutanix_NCC_Clusters_$dateStamp.txt"
# Setup output file
Set-Content -Path $outputFile -Value "________________________ Date: $dateStamp ___________________________ `n"

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

    $plinkArgs = @(
        "-batch"
        "-t"
       # "-ssh"
        "-load", "$namecluster"
        "-l", "nutanix"
        "$remoteCommand"
    )

    $result = & $plinkPath @plinkArgs 2>&1

    # --- MODIFICATION START ---
    # The following block filters the output to show only lines after the final separator.

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

    # If the separator was found, get all lines that come after it
    if ($lastSeparatorIndex -ne -1) {
        # Check if there are any lines after the separator
        if ($lastSeparatorIndex + 1 -lt $lines.Count) {
             $filteredLines = $lines[($lastSeparatorIndex + 1)..($lines.Count - 1)]
        }
        # If there are no lines after, $filteredLines remains an empty array.
    } else {
        # If the separator is not found, use the full output and display a warning
        Write-Host "Separator not found for $namecluster. Displaying full output." -ForegroundColor Magenta
        $filteredLines = $lines
    }
    # --- MODIFICATION END ---

    # Display filtered output on screen:
    $filteredLines | ForEach-Object {Write-Host $_ -ForegroundColor Cyan}

    # Save filtered output with host header
    Add-Content -Path $outputFile -Value "===== $namecluster ====="
    if ($filteredLines.Count -gt 0) {
        Add-Content -Path $outputFile -Value $filteredLines
    }
    Add-Content -Path $outputFile -Value "`n"
}

Write-Host "All done. Output saved to $outputFile" -ForegroundColor Green
