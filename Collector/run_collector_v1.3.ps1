# run_collector.ps1 
# Ver 1.3 - March 2026 (updated for powershell ver 7)
# 
# This script will run the collector via cli. It takes the IP/FQDN of either PE or PC
# It also, moves the resulting .xlsx file to a specific location. 
# Encrypt the user Password with the secure_password.ps1 script. run:  > .\secure_password.ps1
# Be aware that 'Send-MailMessage' is obsolete and in may break in future Powershell versions.  
# If a cluster fails with an error like "encode UnicodeEncodeError: 'charmap' codec can't encode character", try restarting genesis cluster wide (no impact).  
# How to run:   
# > powershell.exe -ExecutionPolicy Bypass -NoProfile -File "<path>\run_collector.ps1" -Prism_addr <PE/PC addr> 
#
# WARNING: This script is is not supported by Nutanix. Use carefully. 
 
param(
    [string]$Prism_addr 
)

# Use this to hardcode a PC or PE
# $Prism_addr = "D1-NX-PRISM"

# Variables
$username = "ntx_collector_svc@vrs.state.va.us"
$port = 9440
$pwFile = "D:\Scripts\Nutanix - Run Weekly\Collector\.secretpw.txt"
$smtpFrom = "ntx_collector@varetire.org" 
$PSEmailServer = "smtp.vrs.state.va.us"
$smtpServer = "smtp.vrs.state.va.us" 
$smtpTo = "DL-ITInfrastructureEngineers@varetire.org"
# $smtpTo = "someone@varetire.org"
$smtpPort = 587
$logFile = "D:\Scripts\Nutanix - Run Weekly\Collector\logs\log.txt"


# Function to log output 
function Write-Log { 
    param ([string]$msg) 
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss" 
    "$timestamp  $msg" | Out-File -FilePath $logFile -Append 
} 
   
# Check if password file exists  
if (-Not (Test-Path $pwFile)) {  
    Write-Error "Password file not found."  
    exit 1  
}  
   
# Read and decrypt the password  
try {  
    $SecurePassword = Get-Content $pwFile | ConvertTo-SecureString    
}  
catch {  
    Write-Error "Failed to read or decrypt the password."  
    exit 1  
}  
   
# command + arguments + File info
#$Command = "D:\Program Files\Nutanix Collector\Nutanix-Collector-5.4-win\collector-cli\ntnxcollector_cli.exe"
$Command = "D:\Program Files\Nutanix Collector\Nutanix-Collector-6.1-win\collector-cli\ntnxcollector_cli.exe"
$Arguments = @("prism", "--ipaddress", "$Prism_addr", "--port", "$port", "--username", "$username",  "--password", [System.Net.NetworkCredential]::new("", $SecurePassword).Password)
# Write-Host "Command: $Command $Arguments"


# Run and check if command was succecssful  
try {
    Set-Location "D:\Program Files\Nutanix Collector\Nutanix-Collector-6.1-win\collector-cli" 
    # $process = & "$Command" @Arguments
    $process = Invoke-Command {& "$Command" @Arguments}
    Write-Host "Running: $process"
    # Start-Sleep 120
    # Check if command was successful 
    if ($LASTEXITCODE -eq 0) { 

        # Copy .xslsx file to final destination variables
        $sourceDir = "D:\Program Files\Nutanix Collector\Nutanix-Collector-6.1-win\collector-cli\"
        $latestDir =  Get-childItem -Path $sourceDir -Directory -Filter 20* | Sort-Object CreationTime -Descending | Select-Object -First 1
        $sourceFile = Get-childItem -Path $latestDir.FullName -Filter ntnxcollector_20*.xlsx -File | Sort-Object CreationTime -Descending | Select-Object -First 1
        $destinationDir = "\\vrsfileshare\vrsfileshares\Departments\Technology Services\Infrastructure\NUTANIX\Nutanix Collector Reports"
        $destinationFile = Join-Path $destinationDir ($Prism_addr + " - " + $sourceFile.name)
        Write-Host "Latest Dir: $latestDir"
        Write-Host "Source File: $sourceFile"
        Write-Host "Dest File: $destinationFile"

        # Copy xls file to share drive
        Copy-Item -Path $sourceFile.Fullname -Destination $destinationFile -Force -ErrorAction Stop
        # email
        $smtpSubject = "Nutanix Collector ran on $Prism_addr" 
        $smtpBody = "$Prism_addr : Nutanix Collector v6.1 completed successfully at $(Get-Date). `nReport location: `"$destinationFile`"" 
        Write-Log "$Prism_addr : Command ran successfully: $process. Report location: $destinationFile" 
    } else { 
        $smtpSubject = "Collector failed (ERROR: $process) on $Prism_addr" 
        $smtpBody = "$Prism_addr : The command $Command failed with exit code: $LASTEXITCODE and error $process.  Time stamp: $(Get-Date). `n$($_.Exception.Message)" 
        Write-Log "$Prism_addr : Command failed with exit code $process" 
    } 
} catch { 
    $smtpSubject = "Collector Error on $Prism_addr" 
    $smtpBody = "$Prism_addr : Error running `$Command`: `n$($_.Exception.Message)" 
    Write-Log "$Prism_addr : Exception during execution: $($_.Exception.Message)" 
} 
 
# --- Send email --- 
try { 
    Send-MailMessage -From $smtpFrom `
                     -To $smtpTo `
                     -Subject $smtpSubject `
                     -Body $smtpBody `
                     -SmtpServer $smtpServer `
                     -Port $smtpPort `
                    
    Write-Log "Email sent!." 
} catch { 
    Write-Log "️Failed to send email: $($_.Exception.Message)" 
}
