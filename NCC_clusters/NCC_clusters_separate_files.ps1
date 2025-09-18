# NCC_clusters.ps1 v1.2  Sept 18, 2025
# This script runs full NCC checks on all clusters in clusters.txt 
# Cleans up banners (#### ... ---> ---+ sections) and creates one output file per cluster.
# Usage: .\NCC_clusters.ps1 

# Define paths and variables 
$clusterFile = ".\clusters.txt" 
$plinkPath   = "plink.exe"   # Or full path: "C:\Program Files\PuTTY\plink.exe" 
$sshUser     = "nutanix"     # Change as needed 

# Remote Command setup. Change AOS_command only
$AOS_command = "ncc health_checks run_all"
$env="PS1=x source /etc/profile; unset PS1"
$remoteCommand =  $env + ";" + $AOS_command 

# Timestamp for filenames
$dateStamp = Get-Date -Format "yyyy_MM_dd__HH_mm_ss" 

# Check if clusters file exists 
if (-not (Test-Path $clusterFile)) {
    Write-Host "File '$clusterFile' not found!" -ForegroundColor Red
    exit 1 
} 

# --- Helper extensions for array search ---
Update-TypeData -TypeName "System.Array" -MemberType ScriptMethod -MemberName FindIndex -Value {
    param([scriptblock]$predicate)
    for ($i = 0; $i -lt $this.Count; $i++) {
        if (& $predicate $this[$i]) { return $i }
    }
    return -1
} -Force

Update-TypeData -TypeName "System.Array" -MemberType ScriptMethod -MemberName FindLastIndex -Value {
    param([scriptblock]$predicate)
    for ($i = $this.Count-1; $i -ge 0; $i--) {
        if (& $predicate $this[$i]) { return $i }
    }
    return -1
} -Force

# Read host entries 
$clusters = Get-Content $clusterFile | Where-Object { $_.Trim() -ne "" } 
 
# Loop through clusters and execute plink 
foreach ($namecluster in $clusters) { 
    Write-Host "Connecting to $namecluster..." -ForegroundColor Yellow

    $plinkArgs = @( 
        "-batch"
        "-t"
        "-load", "$namecluster" 
        "-l", $sshUser 
        "$remoteCommand" 
    ) 

    $result = & $plinkPath @plinkArgs 2>&1 

    # Split into lines
    $lines = $result -split "`n"

    # Remove everything from first "####..." to last "----...+"
    $startIndex = $lines.FindIndex({ $_ -match '^#{5,}' })        # line with #####...
    $endIndex   = $lines.FindLastIndex({ $_ -match '^-{5,}\+' })  # line with ----+ 

    if ($startIndex -ge 0 -and $endIndex -ge $startIndex) {
        $lines = $lines[0..($startIndex-1)] + $lines[($endIndex+1)..($lines.Count-1)]
    }

    # Build cluster-specific output file
    $outputFile = ".\${namecluster}_NCC_${dateStamp}.txt"

    # Add timestamp header
    Set-Content -Path $outputFile -Value "________________________ Date: $datestamp ___________________________ `n"

    # Add cluster header
    Add-Content -Path $outputFile -Value "===== $namecluster ====="

    # Add cleaned result
    Add-Content -Path $outputFile -Value ($lines -join "`r`n")
    Add-Content -Path $outputFile -Value "`n"

    Write-Host "Saved cleaned output to $outputFile" -ForegroundColor Green
} 

Write-Host "All done. One cleaned file created per cluster." -ForegroundColor Cyan
