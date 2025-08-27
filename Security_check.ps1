# Security_checks.ps1 v1.0  July 2025
# This will run ncli commands to check the AHV and CVM security-configs rom all hosts in the host.txt file 
# This is not a Nutanix Supported script. Do not use to run any config change or disruptive commnads.
# Usage: .\Security_checks.ps1


# Define paths and variables 
$hostsFile = "C:\Users\xxacarrasco\Documents\Scripts\hosts.txt" 
$plinkPath = "plink.exe"  # Or the full path: "C:\Program Files\PuTTY\plink.exe" 
$sshUser = "nutanix"       # Change as needed 

#Remote Command: To collect security-configs, ncli commands are used
$remoteCommand =  "PS1=x source /etc/profile; unset PS1; ~/prism/cli/ncli cluster info | grep 'Cluster Name';echo -e '\nAHV Config' ;~/prism/cli/ncli cluster get-hypervisor-security-config; echo -e '\nCVM Config' ; ~/prism/cli/ncli cluster get-cvm-security-config"

# Generate a timestamped output file 
$dateStamp = Get-Date -Format "yyyyMMdd_HHmmss" 
$outputFile = "C:\Users\xxacarrasco\Documents\Scripts\Nutanix_Hardening_$dateStamp.txt" 

# Check if hosts file exists 
if (-not (Test-Path $hostsFile)) {
    Write-Host "File '$hostsFile' not found!" 
    exit 1 
} 

# Read host entries 
$hosts = Get-Content $hostsFile | Where-Object { $_.Trim() -ne "" } 
 
# Loop through hosts and execute plink 
foreach ($namehost in $hosts) { 
    Write-Host "Connecting to $namehost..." 

    $plinkArgs = @( 
        "-batch"
       # "-ssh" 
        "-load", "$namehost" 
        "-l", "nutanix" 
        "$remoteCommand" 
    ) 

    $result = & $plinkPath @plinkArgs 2>&1 

    # Save output with host header
    Add-Content -Path $outputFile -Value "===== $namehost =====" 
    Add-Content -Path $outputFile -Value $result 
    Add-Content -Path $outputFile -Value "`n" 
} 

Write-Host "All done. Output saved to $outputFile" 