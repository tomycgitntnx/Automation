
# Check if cluster.txt exists
if (-not (Test-Path "cluster.txt")) {
    Write-Error "File 'cluster.txt' not found in the current directory."
    exit
}

# Read clusters from file
$clusters = Get-Content "cluster.txt" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

if ($clusters.Count -eq 0) {
    Write-Error "No clusters found in 'cluster.txt'."
    exit
}

# Prompt for credentials once
$cred = Get-Credential
$username = $cred.UserName
$password = $cred.GetNetworkCredential().Password
# Create Basic Auth Header
$encodedCreds = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${username}:${password}"))
$headers = @{
    "Authorization" = "Basic $encodedCreds"
    "Content-Type"  = "application/json"
    "Accept"        = "application/json"
}

# Ignore SSL errors (common for internal clusters)
if ([System.Environment]::OSVersion.Platform -eq "Win32NT") {
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
}

$results = @()

foreach ($cluster in $clusters) {
    Write-Host "Processing Cluster: $cluster..." -ForegroundColor Cyan
    
    $uri = "https://${cluster}:9440/PrismGateway/services/rest/v2.0/vms"
    
    try {
        # Fetch VMs from the cluster
        $response = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers -ErrorAction Stop
        
        foreach ($vm in $response.entities) {
            # Initialize NGT fields
            $ngtVersion = "Not Enabled"
            $ngtCertExpiry = "N/A"
            $ngtEnabled = $false
            
            # Check if guest_tools property exists and is populated
            if ($vm.guest_tools -and $vm.guest_tools.nutanix_guest_tools -and $vm.guest_tools.nutanix_guest_tools.state -eq "ENABLED") {
                $ngtEnabled = $true
                $toolsInfo = $vm.guest_tools.nutanix_guest_tools
                
                # Get Version
                if ($toolsInfo.ngt_version) {
                    $ngtVersion = $toolsInfo.ngt_version
                } else {
                    $ngtVersion = "Installed (Unknown Version)"
                }

                # Try to find Cert Expiration
                # Note: This field is not always standard in v2.0 public API responses.
                # We check for common property names found in extended objects.
                if ($toolsInfo.client_cert_expiry_date) {
                    # Handle Epoch time if present
                    try {
                        $origin = [TimeZoneInfo]::ConvertTime([DateTimeOffset]::FromUnixTimeSeconds($toolsInfo.client_cert_expiry_date), [TimeZoneInfo]::Local)
                        $ngtCertExpiry = $origin.ToString("yyyy-MM-dd")
                    } catch {
                        $ngtCertExpiry = $toolsInfo.client_cert_expiry_date
                    }
                } elseif ($toolsInfo.communication_link_active -eq $false) {
                    $ngtCertExpiry = "Link Inactive (Possible Expiry)"
                } else {
                    $ngtCertExpiry = "Active (Date Hidden)"
                }
            }

            # Create Custom Object for CSV
            $obj = [PSCustomObject]@{
                "Cluster"             = $cluster
                "VM Name"             = $vm.name
                "NGT Version"         = $ngtVersion
                "NGT Cert Expiration" = $ngtCertExpiry
            }
            $results += $obj
        }
        Write-Host "  Successfully retrieved $($response.entities.Count) VMs from $cluster." -ForegroundColor Green
    }
    catch {
        Write-Error "  Failed to connect to $cluster. Error: $_"
    }
}

# Export to CSV
$outputFile = "NGT_Report.csv"
$results | Export-Csv -Path $outputFile -NoTypeInformation
Write-Host "`nReport saved to $outputFile" -ForegroundColor Yellow
