# LACP_configs.ps1 v1.2  Sept 18, 2025
# This script runs a command to check LACP configs on all clusters in clusters.txt 
# This is not a Nutanix Supported script. Do not use to run any config changes or disruptive commnads.
# Usage: .\LACP_configs.ps1

# Define paths and variables 
$clusterFile = ".\clusters.txt" 
$plinkPath = "plink.exe"  # Or the full path: "C:\Program Files\PuTTY\plink.exe" 
$sshUser = "nutanix"       # Change as needed 

#Remote Command setup. Change AOS_command only
$AOS_command = "__allssh 'manage_ovs show_uplinks'"

$env="PS1=x source /etc/profile; unset PS1"
$remoteCommand =  $env + ";" + $AOS_command 

# Generate a timestamped output file 
$dateStamp = Get-Date -Format "yyyy_MM_dd__HH_mm_ss" 
$outputFile = ".\LACP_configs.txt"
# Setup output file 
Set-Content -Path $outputFile -Value "________________________ Date: $datestamp ___________________________ `n"

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
        "-l", "$sshUser" 
        "$remoteCommand" 
    ) 

    $result = & $plinkPath @plinkArgs 2>&1 

    # create a separate output file for each cluster !!!!!

    #write-host -Value "$result" -ForegroundColor Yellow
    $result -split "`n" | ForEach-Object {Write-Host $_ -ForegroundColor Blue}

    # Save output with host header
    Add-Content -Path $outputFile -Value "===== $namecluster =====" 
    Add-Content -Path $outputFile -Value $result 
    Add-Content -Path $outputFile -Value "`n" 
} 

Write-Host "All done. Output saved to $outputFile" -ForegroundColor Green
