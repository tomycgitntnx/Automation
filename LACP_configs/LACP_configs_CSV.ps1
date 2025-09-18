# LACP_configs.ps1 v2.0  Sept 18, 2025
# This script runs a command to check LACP configs on all clusters in clusters.txt 
# This is not a Nutanix Supported script. Do not use to run any config changes or disruptive commnads.
# Usage: .\LACP_configs.ps1

# Define paths and variables 
$clusterFile = ".\clusters.txt" 
$plinkPath = "plink.exe"  # Or the full path: "C:\Program Files\PuTTY\plink.exe" 
$sshUser = "nutanix"       # Change as needed 

# Remote Command setup. Change AOS_command only
$AOS_command = "__allssh 'manage_ovs show_uplinks'"

$env="PS1=x source /etc/profile; unset PS1"
$remoteCommand =  $env + ";" + $AOS_command 

# Generate timestamped CSV output file 
$dateStamp = Get-Date -Format "yyyy_MM_dd__HH_mm_ss" 
$outputFile = ".\LACP_configs_$datestamp.csv"

# Check if clusters file exists 
if (-not (Test-Path $clusterFile)) {
    Write-Host "File '$clusterFile' not found!" -ForegroundColor Red
    exit 1 
} 

# Read host entries 
$clusters = Get-Content $clusterFile | Where-Object { $_.Trim() -ne "" } 

# Storage for all parsed objects
$allResults = @()

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

    # Parse the result into objects
    $currentIP = $null
    $bridge = $null
    $bond = $null
    $record = @{}

    foreach ($line in $result -split "`n") {
        $trimmed = $line.Trim()
        if ($trimmed -match "^=+\s+([\d\.]+)\s+=+") {
            # Flush old record before starting new
            if ($record.Count -gt 0) {
                $allResults += New-Object PSObject -Property $record
                $record = @{}
            }
            $currentIP = $matches[1]
            $record["Cluster"] = $namecluster
            $record["IP"]      = $currentIP
        }
        elseif ($trimmed -match "^Bridge:\s+(.+)$") {
            $record["Bridge"] = $matches[1]
        }
        elseif ($trimmed -match "^Bond:\s+(.+)$") {
            $record["Bond"] = $matches[1]
        }
        elseif ($trimmed -match "^bond_mode:\s+(.+)$") {
            $record["Bond_Mode"] = $matches[1]
        }
        elseif ($trimmed -match "^interfaces:\s+(.+)$") {
            $record["Interfaces"] = $matches[1]
        }
        elseif ($trimmed -match "^lacp:\s+(.+)$") {
            $record["LACP"] = $matches[1]
        }
        elseif ($trimmed -match "^lacp-fallback:\s+(.+)$") {
            $record["LACP_Fallback"] = $matches[1]
        }
        elseif ($trimmed -match "^lacp_speed:\s+(.+)$") {
            $record["LACP_Speed"] = $matches[1]
        }
        elseif ($trimmed -match "^lacp_status:\s+(.+)$") {
            $record["LACP_Status"] = $matches[1]
        }
    }

    # Capture last record for cluster
    if ($record.Count -gt 0) {
        $allResults += New-Object PSObject -Property $record
    }
} 

# Export all results to CSV
$allResults | Export-Csv -Path $outputFile -NoTypeInformation

Write-Host "All done. CSV saved to $outputFile" -ForegroundColor Green
