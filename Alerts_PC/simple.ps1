# Define your username and password
$username = "admin"
$password = "passowed"

# Base64 encode the credentials
$base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(("{0}:{1}" -f $username,$password)))

# Construct the Authorization header
$headers = @{
    Authorization = "Basic $base64AuthInfo"
}

# Define the URI of the API endpoint
$uri = "https://s1-nx-prism:9440/api/monitoring/v4.0.b1/serviceability/alerts"

# Invoke the REST method with the headers
try {
    $response = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers
    $response | ConvertTo-Json -Depth 5 # Display the response (adjust depth as needed)
}
catch {
    Write-Error "Error invoking REST method: $($_.Exception.Message)"
}
