# LACP_configs.ps1 v1.0  August 2025
# This script runs AOS commands to check the LACP configs of every host in every cluster in the cluster file. 
# This is not a Nutanix Supported script. Do not use to run any config change or disruptive commnads.
# Usage: .\LACP_configs.ps1 


# Define paths and variables 
$clusterFile = "C:\Users\xxacarrasco\Documents\Scripts\clusters.txt" 
$plinkPath = "plink.exe"  # Or the full path: "C:\Program Files\PuTTY\plink.exe" 
$sshUser = "nutanix"       # Change as needed 

#Remote Command setup. Change AOS_command only
$AOS_command="ipmiips"

$env="PS1=x source /etc/profile; unset PS1"
$remoteCommand =  $env + ";" + $AOS_command 

# Generate a timestamped output file 
$dateStamp = Get-Date -Format "yyyy_MM_dd__HH_mm_ss" 
# $outputFile = "C:\Users\xxacarrasco\Documents\Scripts\Nutanix_IPMI_IPs_$dateStamp.txt" 
$outputFile = "C:\Users\xxacarrasco\Documents\Scripts\Nutanix_IPMI_IPs.txt"

# Setup output file 
Set-Content -Path $outputFile -Value "________________________ Date: $datestamp ___________________________ `n"
# Check if clusters file exists 
if (-not (Test-Path $clusterFile)) {
    Write-Host "File '$clusterFile' not found!" 
    exit 1 
} 

# Read host entries 
$clusters = Get-Content $clusterFile | Where-Object { $_.Trim() -ne "" } 
 
# Loop through clusters and execute plink 
foreach ($namecluster in $clusters) { 
    Write-Host "Connecting to $namecluster..." 

    $plinkArgs = @( 
        "-batch"
       # "-ssh" 
        "-load", "$namecluster" 
        "-l", "nutanix" 
        "$remoteCommand" 
    ) 

    $result = & $plinkPath @plinkArgs 2>&1 
    $IPs = $result -split "` "

    # Save output with host header
    Add-Content -Path $outputFile -Value "===== $namecluster =====" 
    Add-Content -Path $outputFile -Value $IPs 
    Add-Content -Path $outputFile -Value "`n" 
} 

Write-Host "All done. Output saved to $outputFile" 