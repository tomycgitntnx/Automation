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
# Corrected the endpoint based on internal API mapping documents.
$uri = "https://$($pc_ip):9440/api/monitoring/v4.0.b1/serviceability/alerts" 

# Invoke the REST method with the headers
try {
    Write-Host "Querying API endpoint: $uri"
    # Added -SkipCertificateCheck for environments with self-signed certificates
    # Note: For PowerShell 5.1, if -SkipCertificateCheck is not available or doesn't work,
    # you may need to add the following line before the Invoke-RestMethod call:
    # [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
    $response = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers -SkipCertificateCheck

    # Display the response formatted as JSON
    Write-Host "Successfully retrieved alerts:"
    $response | ConvertTo-Json -Depth 10 # Increased depth to ensure full object visibility
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
