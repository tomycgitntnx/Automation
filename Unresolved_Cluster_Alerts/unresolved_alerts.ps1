<#
.SYNOPSIS
    Retrieves all unresolved alerts from multiple Nutanix Prism Central instances.

.DESCRIPTION
    This script connects to a list of Prism Central (PC) instances specified in a text file,
    authenticates using the Nutanix REST API v4.0.b1, and fetches all unresolved alerts.

    It handles secure credential storage and is compatible with PowerShell 5.1.

.REQUIREMENTS
    - PowerShell 5.1 or later.
    - A 'clusters.txt' file in the same directory as the script, containing one
      Prism Central IP/FQDN per line.

.NOTES
    Author: Tomy Carrasco (alvaro.carrasc@nutanix.com)
    Date:   2025-Nov-19
#>

# --- Script Configuration ---
$credentialFile = "credential.xml"
$clusterFile = "clusters.txt"

# --- Main Script Body ---

#region Functions
function Get-Credentials {
    param (
        [string]$Path
    )

    try {
        if (Test-Path -Path $Path) {
            Write-Verbose "Credential file found. Importing credentials."
            $credential = Import-CliXml -Path $Path
            return $credential
        } else {
            Write-Host "Credential file not found. Please enter your Prism Central credentials."
            $credential = Get-Credential
            $credential | Export-CliXml -Path $Path
            Write-Host "Credentials saved securely to '$Path' for future use."
            return $credential
        }
    }
    catch {
        Write-Error "Failed to get or save credentials. Error: $($_.Exception.Message)"
        return $null
    }
}

function Get-UnresolvedNutanixAlerts {
    param (
        [string]$PrismCentral,
        [System.Management.Automation.PSCredential]$Credential
    )

    $username = $Credential.UserName
    $password = $Credential.GetNetworkCredential().Password

    $base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${username}:${password}"))

    $headers = @{
        "Authorization" = "Basic $base64AuthInfo"
        "Content-Type"  = "application/json"
    }

    # The Nutanix v4 API uses OData filtering. To get unresolved alerts, we filter where 'isResolved' is false.
    # API Endpoint: GET /api/monitoring/v4.0.b1/serviceability/alerts?$filter=isResolved eq false
    $uri = "https://{0}:9440/api/monitoring/v4.0.b1/serviceability/alerts?`$filter=isResolved eq false" -f $PrismCentral

    Write-Host "Querying unresolved alerts from '$PrismCentral'..."

    try {
        # For PowerShell 5.1 compatibility, we handle certificate validation manually.
        # This will accept self-signed certificates, which are common in lab/internal environments.
        $response = Invoke-RestMethod -Method Get -Uri $uri -Headers $headers -SkipCertificateCheck:$true
        return $response.data
    }
    catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        $statusDescription = $_.Exception.Response.StatusDescription
        Write-Error "API call to '$PrismCentral' failed with status $statusCode ($statusDescription)."
        Write-Error "Error details: $($_.Exception.Message)"
        return $null
    }
}
#endregion Functions

#region Script Execution

# For PowerShell 5.1, explicitly enable TLS 1.2 for secure connections.
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

# Check for the existence of the clusters file
if (-not (Test-Path -Path $clusterFile)) {
    Write-Error "The required file '$clusterFile' was not found in the script directory."
    Write-Error "Please create this file and add your Prism Central addresses (one per line)."
    exit
}

# Get credentials, prompting if the secure file doesn't exist
$creds = Get-Credentials -Path $credentialFile
if ($null -eq $creds) {
    Write-Error "Could not obtain credentials. Exiting script."
    exit
}

# Read Prism Central addresses from the file
$pcList = Get-Content -Path $clusterFile | Where-Object { $_ -notlike '#*' -and $_.Trim() -ne '' }

if ($pcList.Count -eq 0) {
    Write-Warning "The '$clusterFile' is empty or contains no valid entries. No hosts to process."
    exit
}

# Process each Prism Central
foreach ($pc in $pcList) {
    Write-Host "--- Processing Prism Central: $pc ---" -ForegroundColor Green

    $alerts = Get-UnresolvedNutanixAlerts -PrismCentral $pc -Credential $creds

    if ($null -ne $alerts) {
        if ($alerts.Count -gt 0) {
            Write-Host "Found $($alerts.Count) unresolved alerts on '$pc'." -ForegroundColor Yellow
            # Output the alerts as objects for further processing (e.g., export to CSV)
            $alerts | ForEach-Object {
                [PSCustomObject]@{
                    PrismCentral    = $pc
                    Title           = $_.title
                    Severity        = $_.severity
                    CreatedTime     = $_.creationTime
                    Cluster         = $_.sourceCluster.name
                    SourceEntity    = $_.sourceEntity.name
                    EntityType      = $_.sourceEntity.entityType
                    Message         = $_.message
                    Resolution      = $_.probableCause
                }
            }
        } else {
            Write-Host "No unresolved alerts found on '$pc'."
        }
    }
    else {
        Write-Warning "Skipping '$pc' due to a previous error."
    }
    Write-Host "--------------------------------------`n" -ForegroundColor Green
}

#endregion Script Execution
