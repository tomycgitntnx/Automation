# --- Script Configuration ---

# Recommendation: Use Get-Credential for secure password handling
# $creds = Get-Credential -UserName "admin"
# $username = $creds.UserName
# $password = $creds.GetNetworkCredential().Password

# For testing purposes, you can define credentials here, but it's not recommended for production
$username = "admin"
$password = "your_password" # <-- Replace with your actual password
$pc_ip = "s1-nx-prism"    # <-- Your Prism Central IP or FQDN

# --- End of Configuration ---

# Base64 encode the credentials for the Authorization header
$base64AuthInfo = [Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes(("{0}:{1}" -f $username, $password)))

# Construct the required headers for the API call
$headers = @{
    "Authorization" = "Basic $base64AuthInfo"
    "Content-Type"  = "application/json"
}

# Define the URI of the v4 API endpoint for alerts
# This is the correct endpoint to list alerts.
# We add a filter to get only unresolved alerts.
$filter = "status ne 'RESOLVED'"
$uri = "https://{0}:9440/api/monitoring/v4.0.b1/alerts?`$filter={1}" -f $pc_ip, $filter

# Invoke the REST method with the headers
try {
    Write-Host "Querying API endpoint: $uri"

    # --- FIX FOR "Underlying connection was closed" ERROR ---
    # This line forces the current PowerShell session to use TLS 1.2.
    # Older versions of PowerShell default to outdated protocols (TLS 1.0/1.1) which are rejected by modern servers.
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

    # --- CHANGE FOR POWERSHELL 5.1 ---
    # The line below bypasses SSL certificate validation in older PowerShell versions.
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }

    # The '-SkipCertificateCheck' parameter has been removed from the call below.
    $response = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers

    # Check if any alerts were returned
    if ($response.data) {
        # Display the response formatted as JSON
        Write-Host "Successfully retrieved unresolved alerts:"
        $response.data | ConvertTo-Json -Depth 10 # Increased depth to ensure full object visibility
    }
    else {
        Write-Host "No unresolved alerts found."
    }
}
catch {
    # Provide more detailed error information
    Write-Error "Error invoking REST method: $($_.Exception.Message)"
    if ($_.Exception.Response) {
        $errorResponse = $_.Exception.Response.GetResponseStream()
        $streamReader = New-Object System.IO.StreamReader($errorResponse)
        $errorBody = $streamReader.ReadToEnd()
        Write-Error "API Response Body: $errorBody"
    }
}
