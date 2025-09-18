# NCC_clusters.ps1 v2.3  Sept 18, 2025
# One cleaned file per cluster, keeps last "----+" line for reference
# ANSI escape codes removed, no trailing blank lines
# Fixed: removed use of ForEach-Object -Index which caused error on older PS versions

# Define paths and variables 
$clusterFile = ".\clusters.txt" 
$plinkPath   = "plink.exe" 
$sshUser     = "nutanix"    

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

$clusters = Get-Content $clusterFile | Where-Object { $_.Trim() -ne "" } 

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

    # --- Strip ANSI escape sequences ---
    # using the ASCII ESC char so this works reliably
    $esc = [char]27
    $cleanResult = $result -replace "$esc\[[0-9;]*[A-Za-z]", ''

    # Split into lines (handles both CRLF and LF)
    $lines = [regex]::Split($cleanResult, "\r?\n")

    # --- Find last separator line index (backwards search for compatibility) ---
    $lastSepIndex = -1
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        if ($lines[$i] -match '^-{5,}\+$') {
            $lastSepIndex = $i
            break
        }
    }

    if ($lastSepIndex -ge 0) {
        # Keep the last separator and everything after it
        $lines = $lines[$lastSepIndex..($lines.Count - 1)]
    } else {
        # No separator found: keep entire output (fallback)
        # $lines stays as-is
    }

    # Trim trailing whitespace from each line and remove trailing blank lines
    $lines = $lines | ForEach-Object { $_.TrimEnd() }
    while ($lines.Count -gt 0 -and [string]::IsNullOrWhiteSpace($lines[-1])) {
        if ($lines.Count -eq 1) {
            $lines = @() ; break
        }
        $lines = $lines[0..($lines.Count - 2)]
    }

    # Output file per cluster
    $outputFile = ".\$($namecluster)_NCC_$dateStamp.txt"

    # Write header + cluster marker + cleaned output
    Set-Content -Path $outputFile -Value "________________________ Date: $dateStamp ___________________________ `n"
    Add-Content -Path $outputFile -Value "===== $namecluster ====="

    if ($lines.Count -gt 0) {
        Add-Content -Path $outputFile -Value ($lines -join "`r`n")
    }

    Write-Host "Saved $outputFile" -ForegroundColor Green
} 

Write-Host "All done. Cleaned per-cluster files created." -ForegroundColor Cyan
