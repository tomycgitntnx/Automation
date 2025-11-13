# --- Script Configuration ---

# Recommendation: Use Get-Credential for secure password handling
# $creds = Get-Credential -UserName "admin"
# $username = $creds.UserName
# $password = $creds.GetNetworkCredential().Password

# For testing purposes, you can define credentials here, but it's not recommended for production
$username = "admin"
$password = "your_password" # <-- Replace with your actual password

# --- End of Configuration ---

# Base64 encode the credentials for the Authorization header
$base64AuthInfo = [Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes(("{0}:{1}" -f $username, $password)))

# Construct the required headers for the API call
$headers = @{
    "Authorization" = "Basic $base64AuthInfo"
    "Content-Type"  = "application/json"
}

# Define the URI of the v4 API endpoint for alerts
# The original URI was incorrect. This is the correct endpoint for listing alerts in v4.0.b1.
$uri = "https://s1-nx-prism:9440/api/monitoring/v4.0.b1/serviceability/alerts" # <-- Corrected URI

# Invoke the REST method with the headers
try {
    Write-Host "Querying API endpoint: $uri"
    # Added -SkipCertificateCheck for environments with self-signed certificates
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
