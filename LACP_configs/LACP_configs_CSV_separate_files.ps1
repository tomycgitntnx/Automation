# LACP_configs.ps1 v2.1  Sept 18, 2025
# One CSV file per cluster

# Define paths and variables 
$clusterFile = ".\clusters.txt" 
$plinkPath   = "plink.exe"  # Or full path: "C:\Program Files\PuTTY\plink.exe" 
$sshUser     = "nutanix"    # Change as needed 

# Remote Command setup
$AOS_command = "__allssh 'manage_ovs show_uplinks'"
$env="PS1=x source /etc/profile; unset PS1"
$remoteCommand =  $env + ";" + $AOS_command 

# Timestamp (to make unique filenames)
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

    # Parse results for this cluster
    $clusterResults = @()
    $record = @{}

    foreach ($line in $result -split "`n") {
        $trimmed = $line.Trim()
        if ($trimmed -match "^=+\s+([\d\.]+)\s+=+") {
            # flush old record before new one
            if ($record.Count -gt 0) {
                $clusterResults += New-Object PSObject -Property $record
                $record = @{}
            }
            $record["Cluster"] = $namecluster
            $record["IP"]      = $matches[1]
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

    # Add last record for this cluster
    if ($record.Count -gt 0) {
        $clusterResults += New-Object PSObject -Property $record
    }

    # Export CSV for this cluster
    $outputFile = ".\${namecluster}_LACP_$dateStamp.csv"
    $clusterResults | Export-Csv -Path $outputFile -NoTypeInformation

    Write-Host "Saved $outputFile" -ForegroundColor Green
}

Write-Host "All done. Each cluster has its own CSV file." -ForegroundColor Cyan
