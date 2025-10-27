<#
.SYNOPSIS
Generates an HTML report of unresolved Nutanix alerts per cluster.
Compatible with PowerShell 5.1.
#>

param (
    [Parameter(Mandatory=$true)]
    [string]$InputFilePath, # Text file containing cluster name and credentials
    [Parameter(Mandatory=$true)]
    [string]$OutputHtmlPath
)

function Get-ClusterAlerts {
    param (
        [string]$ClusterName,
        [string]$Username,
        [string]$Password
    )

    try {
        $url = "https://$ClusterName:9440/api/nutanix/v4.0.a1/monitoring/alerts"
        $creds = ("{0}:{1}" -f $Username, $Password)
        $encodedCreds = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes($creds))
        $headers = @{ Authorization = "Basic $encodedCreds" }

        $response = Invoke-RestMethod -Uri $url -Headers $headers -SkipCertificateCheck -TimeoutSec 30 -ErrorAction Stop
        if ($null -ne $response && $response.data) {
            return $response.data
        }
        else {
            return @()
        }
    }
    catch {
        Write-Warning "Failed to retrieve alerts from $ClusterName: $($_.Exception.Message)"
        return @()
    }
}

function Build-ClusterAlertsHtml {
    param (
        [string]$ClusterName,
        [array]$Alerts
    )

    # Normalize severity casing and sort
    $normalizedAlerts = $Alerts | ForEach-Object {
        $_.severity = $_.severity.ToUpper()
        $_
    }

    $sortedAlerts = $normalizedAlerts | Sort-Object @{Expression={@('CRITICAL','WARNING','INFO').IndexOf($_.severity)}}

    $tableRows = ""
    foreach ($alert in $sortedAlerts) {
        $color = switch ($alert.severity.ToUpper()) {
            'CRITICAL' { 'red' }
            'WARNING'  { '#f0ad4e' }
            'INFO'     { 'blue' }
            default    { 'black' }
        }

        $title = [System.Web.HttpUtility]::HtmlEncode($alert.title)
        $message = [System.Web.HttpUtility]::HtmlEncode($alert.message)
        $impact = [System.Web.HttpUtility]::HtmlEncode($alert.impact)
        $createdTime = (Get-Date $alert.created_time_usecs / 1e6 -UFormat "%Y-%m-%d %H:%M:%S")

        $tableRows += @"
        <tr>
            <td style="color:$color; font-weight:bold;">$($alert.severity)</td>
            <td>$title</td>
            <td>$message</td>
            <td>$createdTime</td>
            <td>$impact</td>
        </tr>
"@
    }

    return @"
    <details open>
    <summary><h2>Cluster: $ClusterName <a href="#index" class="back-link">[Back to Index]</a></h2></summary>
    <div id="$($ClusterName -replace '[^a-zA-Z0-9]', '').ToLower()" class="cluster-content">
    <table>
        <tr>
            <th>Severity</th>
            <th>Title</th>
            <th>Message</th>
            <th>Created Time</th>
            <th>Impact</th>
        </tr>
        $tableRows
    </table>
    </div>
    </details>
"@
}

# HTML header
$htmlHeader = @"
<!DOCTYPE html>
<html>
<head>
    <title>Nutanix Unresolved Alerts Report</title>
    <style>
        body { font-family: 'Segoe UI', Roboto, Arial, sans-serif; background-color: #f4f7f9; color: #333; margin: 0; padding: 20px; }
        h1 { color: #003a70; border-bottom: 2px solid #00b1e7; padding-bottom: 10px; }
        h2 { font-size: 1.5em; color: #003a70; }
        ul { list-style-type: none; padding-left: 0; }
        li { background-color: #fff; margin: 8px 0; padding: 12px; border-radius: 5px; box-shadow: 0 1px 3px rgba(0,0,0,0.08); display: flex; align-items: center; justify-content: space-between; }
        li .date { font-weight: bold; }
        li .links a { margin-left: 15px; text-decoration: none; font-weight: bold; color: #007bff; }
        li .links a:hover { text-decoration: underline; }
        details { background-color: #fff; border: 1px solid #ddd; border-radius: 8px; margin-bottom: 20px; }
        summary { font-weight: bold; font-size: 1.2em; cursor: pointer; padding: 10px 20px; position: relative; }
        .cluster-content { padding: 0 20px 20px 20px; }
        .back-link { font-size: 0.7em; font-weight: normal; margin-left: 20px; }
        a { color: #007bff; text-decoration: none; }
        a:hover { text-decoration: underline; }
        table { border-collapse: collapse; width: 100%; margin: 20px 0; background-color: white; border-radius: 5px; box-shadow: 0 1px 3px rgba(0,0,0,0.08); overflow: hidden; }
        th, td { border: 1px solid #dddddd; text-align: left; padding: 12px; }
        th { background-color: #003a70; color: white; font-weight: bold; }
        tr:nth-child(even) { background-color: #f9f9f9; }
        tr:hover { background-color: #eaf2fa; }
        footer { text-align: center; margin-top: 40px; font-size: 0.9em; color: #888; }
    </style>
</head>
<body>
    <h1>Nutanix Unresolved Alerts Report</h1>
    <p>Generated on: $(Get-Date)</p>
"@

$htmlSummary = @"
<div id="index">
<h2>Alerts Summary</h2>
<table>
    <tr>
        <th>Cluster Name</th>
        <th>Alerts</th>
    </tr>
"@

$htmlClusters = ""

# Read cluster credentials
$clusters = Get-Content $InputFilePath | Where-Object { $_ -match '\S' } | ForEach-Object {
    $parts = $_ -split '\s+'
    if ($parts.Count -ge 3) {
        [PSCustomObject]@{ Name = $parts[0]; User = $parts[1]; Password = $parts[2] }
    }
}

foreach ($cluster in $clusters) {
    Write-Host "Processing cluster: $($cluster.Name)" -ForegroundColor Cyan
    $clusterAlerts = Get-ClusterAlerts -ClusterName $cluster.Name -Username $cluster.User -Password $cluster.Password

    if (-not $clusterAlerts) { 
        $clusterAlerts = @()
    }

    # Normalize severities to uppercase for counting
    foreach ($alert in $clusterAlerts) {
        $alert.severity = $alert.severity.ToUpper()
    }

    # Ensure numeric counters
    [int]$criticalCount = ($clusterAlerts | Where-Object { $_.severity -eq 'CRITICAL' }).Count
    [int]$warningCount  = ($clusterAlerts | Where-Object { $_.severity -eq 'WARNING' }).Count
    [int]$infoCount     = ($clusterAlerts | Where-Object { $_.severity -eq 'INFO' }).Count

    $htmlSummary += @"
    <tr>
        <td><a href="#$($cluster.Name -replace '[^a-zA-Z0-9]', '').ToLower()">$($cluster.Name)</a></td>
        <td>
            <span style='color:red; font-weight:bold;'>Critical: $criticalCount</span> |
            <span style='color:#f0ad4e; font-weight:bold;'>Warning: $warningCount</span> |
            <span style='color:blue; font-weight:bold;'>Info: $infoCount</span>
        </td>
    </tr>
"@

    $htmlClusters += Build-ClusterAlertsHtml -ClusterName $cluster.Name -Alerts $clusterAlerts
}

$htmlSummary += "</table></div>"

$htmlFooter = @"
    <footer>
        <p>Report generated by the Nutanix Unresolved Alerts Script</p>
    </footer>
</body>
</html>
"@

# Output HTML
$htmlReport = $htmlHeader + $htmlSummary + $htmlClusters + $htmlFooter
Set-Content -Path $OutputHtmlPath -Value $htmlReport -Encoding UTF8

Write-Host "HTML report generated: $OutputHtmlPath" -ForegroundColor Green
