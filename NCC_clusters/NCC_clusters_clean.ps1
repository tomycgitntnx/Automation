# NCC_clusters.ps1 v1.2  Sept 18, 2025
# This script runs full NCC checks on all clusters in clusters.txt 
# This is not a Nutanix Supported script. Do not use to run any config changes or disruptive commands.
# Usage: .\NCC_clusters.ps1 

# Define paths and variables 
$clusterFile = ".\clusters.txt" 
$plinkPath   = "plink.exe"  # Or full path: "C:\Program Files\PuTTY\plink.exe" 
$sshUser     = "nutanix"    # Change as needed 

# Remote Command setup
$AOS_command = "ncc health_checks run_all"
$env="PS1=x source /etc/profile; unset PS1"
$remoteCommand =  $env + ";" + $AOS_command 

# Generate timestamp for output files
$dateStamp = Get-Date -Format "yyyy_MM_dd__HH_mm_ss" 

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
        "-load", "$namecluster" 
        "-l", "$sshUser" 
        "$remoteCommand" 
    ) 

    $result = & $plinkPath @plinkArgs 2>&1 

    # Remove ANSI escape sequences (color codes, cursor movements, etc.)
    $cleanResult = $result -replace '\x1B\[[0-9;]*[A-Za-z]', ''

    # Split lines
    $lines = $cleanResult -split "`n"

    # Find last index of the separator line
    $lastSepIndex = ($lines | ForEach-Object -Index ($i=0) {
        if ($_ -match '^-{5,}\+') { $i }
        $i++
    }) | Select-Object -Last 1

    if ($lastSepIndex -is [int]) {
        $lines = $lines[($lastSepIndex + 1)..($lines.Count - 1)]
    }

    # Create per-cluster output file
    $outputFile = ".\${namecluster}_NCC_$dateStamp.txt"

    # Write header
    Set-Content -Path $outputFile -Value "________________________ Date: $datestamp ___________________________ `n"

    # Write cluster marker
    Add-Content -Path $outputFile -Value "===== $namecluster =====" 

    # Write cleaned lines
    if ($lines.Count -gt 0) {
        Add-Content -Path $outputFile -Value ($lines -join "`r`n")
    }
    Add-Content -Path $outputFile -Value "`n" 

    Write-Host "Saved $outputFile" -ForegroundColor Green
} 

Write-Host "All done. Cleaned per-cluster files created." -ForegroundColor Cyan
