<#
.SYNOPSIS
    Generates an interactive HTML dashboard of unresolved Nutanix alerts across multiple endpoints.
.DESCRIPTION
    Reads Nutanix Prism Central and cluster endpoints from a cluster list file, securely loads stored
    credentials (prompting the user on first run), retrieves unresolved alerts via the Nutanix REST API,
    and renders an HTML dashboard with per-endpoint summaries and drill-down details.

    Requirements:
        * PowerShell 5.1
        * Access to the Nutanix endpoints listed in the cluster file
        * Nutanix credentials with permission to read alerts

    Usage example:
        .\NutanixAlertDashboard.ps1 -ClusterListPath .\cluster.txt -OutputDirectory .\dashboard
#>

[CmdletBinding()]
param (
    [Parameter()]
    [string]$ClusterListPath = (Join-Path -Path (if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }) -ChildPath 'cluster.txt'),

    [Parameter()]
    [string]$OutputDirectory = (Join-Path -Path (if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }) -ChildPath 'NutanixAlertDashboard_Output'),

    [Parameter()]
    [switch]$ForceCredentialReset,

    [Parameter()]
    [ValidateSet('Strict', 'Skip')]
    [string]$TlsValidation = 'Skip',

    [Parameter()]
    [switch]$OpenDashboard
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Log {
    param (
        [Parameter(Mandatory)]
        [string]$Message,

        [Parameter()]
        [ValidateSet('INFO', 'WARN', 'ERROR', 'DEBUG')]
        [string]$Level = 'INFO'
    )

    $timestamp = (Get-Date).ToString('s')
    Write-Host "[$timestamp][$Level] $Message"
}

function Initialize-TlsConfiguration {
    param (
        [Parameter(Mandatory)]
        [ValidateSet('Strict', 'Skip')]
        [string]$Mode
    )

    # Ensure the script can negotiate modern TLS versions.
    $supportedProtocols = [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]::Tls11 -bor [System.Net.SecurityProtocolType]::Tls

    [System.Net.ServicePointManager]::SecurityProtocol = $supportedProtocols

    if (-not $script:OriginalCertValidationCallback) {
        $script:OriginalCertValidationCallback = [System.Net.ServicePointManager]::ServerCertificateValidationCallback
    }

    if ($Mode -eq 'Skip') {
        if (-not $script:SkipCertValidationCallback) {
            $script:SkipCertValidationCallback = {
                param($targetHost, $cert, $chain, $errors)
                return $true
            }
        }

        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $script:SkipCertValidationCallback
        Write-Log -Level 'WARN' -Message 'TLS certificate validation disabled. Use trusted certificates in production environments.'
    }
    else {
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $script:OriginalCertValidationCallback
    }
}

function Get-CredentialStorePath {
    $credentialDirectory = Join-Path -Path $env:APPDATA -ChildPath 'NutanixAlertDashboard'
    if (-not (Test-Path -LiteralPath $credentialDirectory)) {
        New-Item -ItemType Directory -Path $credentialDirectory -Force | Out-Null
    }

    return Join-Path -Path $credentialDirectory -ChildPath 'credentials.xml'
}

function Get-NutanixCredential {
    param (
        [switch]$ForceReset
    )

    $credentialPath = Get-CredentialStorePath
    if ($ForceReset.IsPresent -and (Test-Path -LiteralPath $credentialPath)) {
        Remove-Item -Path $credentialPath -Force
    }

    if (Test-Path -LiteralPath $credentialPath) {
        try {
            $credential = Import-Clixml -Path $credentialPath
            if ($credential -isnot [System.Management.Automation.PSCredential]) {
                throw "Stored credential file at '$credentialPath' is invalid."
            }
            Write-Log -Level 'INFO' -Message "Using stored credentials from '$credentialPath'."
            return $credential
        }
        catch {
            Write-Log -Level 'WARN' -Message "Failed to import stored credentials: $($_.Exception.Message)."
            Remove-Item -Path $credentialPath -Force -ErrorAction SilentlyContinue
        }
    }

    $credential = Get-Credential -Message 'Enter Nutanix credentials (will be stored securely for reuse)'
    $credential | Export-Clixml -Path $credentialPath
    Write-Log -Level 'INFO' -Message "Credentials stored at '$credentialPath'."
    return $credential
}

function ConvertTo-BasicAuthorizationHeader {
    param (
        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$Credential
    )

    $plainText = '{0}:{1}' -f $Credential.UserName, $Credential.GetNetworkCredential().Password
    $bytes = [Text.Encoding]::UTF8.GetBytes($plainText)
    $encoded = [Convert]::ToBase64String($bytes)
    return "Basic $encoded"
}

function Invoke-NutanixRestMethod {
    param (
        [Parameter(Mandatory)]
        [string]$Uri,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$Credential,

        [Parameter()]
        [ValidateSet('Get', 'Post')]
        [string]$Method = 'Post',

        [Parameter()]
        [hashtable]$Body,

        [Parameter()]
        [int]$TimeoutSeconds = 90
    )

    $headers = @{
        Authorization = ConvertTo-BasicAuthorizationHeader -Credential $Credential
        Accept        = 'application/json'
    }

    $invocationParameters = @{
        Uri         = $Uri
        Method      = $Method
        Headers     = $headers
        TimeoutSec  = $TimeoutSeconds
        ErrorAction = 'Stop'
    }

    if ($Body) {
        $jsonBody = $Body | ConvertTo-Json -Depth 10
        $invocationParameters['Body'] = $jsonBody
        $invocationParameters['ContentType'] = 'application/json; charset=utf-8'
    }

    return Invoke-RestMethod @invocationParameters
}

function Get-ClusterTargetsFromFile {
    param (
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Cluster list file not found at '$Path'."
    }

    $entries = Get-Content -Path $Path | ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and -not $_.StartsWith('#') }

    if (-not $entries -or $entries.Count -eq 0) {
        throw "Cluster list '$Path' is empty. Add at least one endpoint (one per line)."
    }

    return $entries
}

function New-Directory {
    param (
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Write-TextFileUtf8 {
    param (
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Content
    )

    $directory = Split-Path -Parent $Path
    New-Directory -Path $directory
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Initialize-HtmlSupport {
    if (-not $script:HtmlEncoderLoaded) {
        Add-Type -AssemblyName System.Web
        $script:HtmlEncoderLoaded = $true
    }
}

function ConvertTo-HtmlEncoded {
    param (
        [Parameter()]
        $InputObject
    )

    Initialize-HtmlSupport
    if ($null -eq $InputObject) {
        return ''
    }

    $stringValue = $InputObject.ToString()
    return [System.Web.HttpUtility]::HtmlEncode($stringValue)
}

function Get-SafeFileName {
    param (
        [Parameter(Mandatory)]
        [string]$BaseName
    )

    $sanitized = $BaseName -replace "[^a-zA-Z0-9-_]", '_'
    if ([string]::IsNullOrWhiteSpace($sanitized)) {
        $sanitized = 'entry'
    }
    return $sanitized
}

function ConvertFrom-MicrosecondTimestamp {
    param (
        [Parameter(Mandatory)]
        [long]$Microseconds
    )

    if (-not $script:UnixEpoch) {
        $script:UnixEpoch = [DateTime]::SpecifyKind((Get-Date '1970-01-01T00:00:00Z'), [DateTimeKind]::Utc)
    }
    $epoch = $script:UnixEpoch
    $seconds = [Math]::Floor($Microseconds / 1000000)
    $remainingMicroseconds = $Microseconds % 1000000
    $dateTime = $epoch.AddSeconds($seconds).AddTicks($remainingMicroseconds * 10)
    return $dateTime.ToLocalTime()
}

function Format-DisplayDateTime {
    param (
        [Parameter()]
        [Nullable[DateTime]]$Value
    )

    if ($null -eq $Value) {
        return ''
    }

    return $Value.Value.ToString('yyyy-MM-dd HH:mm:ss')
}

function Get-AlertPropertyValue {
    param (
        [Parameter(Mandatory)]
        $Alert,

        [Parameter(Mandatory)]
        [string[]]$PropertyNames
    )

    foreach ($name in $PropertyNames) {
        if ($Alert.PSObject.Properties.Match($name)) {
            $value = $Alert.$name
            if ($null -ne $value -and ($value -isnot [string] -or -not [string]::IsNullOrWhiteSpace($value))) {
                return $value
            }
        }
    }

    return $null
}

function Get-AlertSeverity {
    param (
        [Parameter(Mandatory)]
        $Alert
    )

    $rawSeverity = Get-AlertPropertyValue -Alert $Alert -PropertyNames @('severity', 'alert_severity', 'impact', 'alert_level')
    if ($null -eq $rawSeverity) {
        return 'UNKNOWN'
    }

    $severityString = $rawSeverity.ToString().ToUpperInvariant()
    switch ($severityString) {
        'CRITICAL' { return 'CRITICAL' }
        'WARNING' { return 'WARNING' }
        'WARN' { return 'WARNING' }
        'INFO' { return 'INFO' }
        'INFORMATIONAL' { return 'INFO' }
        default { return $severityString }
    }
}

function Get-AlertIdentifier {
    param (
        [Parameter(Mandatory)]
        $Alert
    )

    $identifier = Get-AlertPropertyValue -Alert $Alert -PropertyNames @('id', 'uuid', 'alert_id', 'ext_id', 'guid')
    if ($identifier) {
        return $identifier.ToString()
    }

    return ''
}

function Get-AlertTitle {
    param (
        [Parameter(Mandatory)]
        $Alert
    )

    $title = Get-AlertPropertyValue -Alert $Alert -PropertyNames @('title', 'alert_title', 'summary', 'name')
    if ($title) {
        return $title.ToString()
    }

    $message = Get-AlertMessage -Alert $Alert
    if ($message) {
        return ($message.Split([Environment]::NewLine)[0]).Trim()
    }

    return 'Alert'
}

function Get-AlertMessage {
    param (
        [Parameter(Mandatory)]
        $Alert
    )

    $message = Get-AlertPropertyValue -Alert $Alert -PropertyNames @('message', 'alert_message', 'details', 'long_description', 'description')
    if ($message) {
        return $message.ToString()
    }

    return ''
}

function Get-AlertCategory {
    param (
        [Parameter(Mandatory)]
        $Alert
    )

    $category = Get-AlertPropertyValue -Alert $Alert -PropertyNames @('category', 'alert_type', 'classification', 'type')
    if ($category) {
        return $category.ToString()
    }

    return ''
}

function Get-AlertEntities {
    param (
        [Parameter(Mandatory)]
        $Alert
    )

    $entityCandidates = @('entity_name', 'entity_ids', 'resource_name', 'resource_id', 'cluster_name', 'vm_name')
    foreach ($candidate in $entityCandidates) {
        if ($Alert.PSObject.Properties.Match($candidate)) {
            $value = $Alert.$candidate
            if ($null -ne $value) {
                if ($value -is [System.Collections.IEnumerable] -and -not ($value -is [string])) {
                    return ($value | ForEach-Object { $_.ToString() } | Where-Object { $_ }) -join ', '
                }
                else {
                    return $value.ToString()
                }
            }
        }
    }

    # Fallback for list-based properties
    $listProperties = @('entity_reference_list', 'affected_entity_list', 'impacted_entity_list', 'entity_list')
    foreach ($property in $listProperties) {
        if ($Alert.PSObject.Properties.Match($property)) {
            $list = @($Alert.$property) | Where-Object { $_ }
            if ($list.Count -gt 0) {
                $names = $list | ForEach-Object {
                    if ($_ -is [string]) {
                        $_
                    }
                    elseif ($_.PSObject.Properties.Match('name')) {
                        $_.name
                    }
                    elseif ($_.PSObject.Properties.Match('entity_name')) {
                        $_.entity_name
                    }
                    elseif ($_.PSObject.Properties.Match('display_name')) {
                        $_.display_name
                    }
                } | Where-Object { $_ }

                if ($names.Count -gt 0) {
                    return ($names | Select-Object -Unique) -join ', '
                }
            }
        }
    }

    return ''
}

function Get-AlertTimestamp {
    param (
        [Parameter(Mandatory)]
        $Alert,

        [Parameter(Mandatory)]
        [string[]]$PropertyNames
    )

    foreach ($name in $PropertyNames) {
        if ($Alert.PSObject.Properties.Match($name)) {
            $value = $Alert.$name
            if ($null -eq $value) { continue }

            if ($value -is [long] -or $value -is [int]) {
                try {
                    return ConvertFrom-MicrosecondTimestamp -Microseconds ([long]$value)
                }
                catch {
                    continue
                }
            }
            elseif ($value -is [double]) {
                try {
                    return ConvertFrom-MicrosecondTimestamp -Microseconds ([long]$value)
                }
                catch {
                    continue
                }
            }
            elseif ($value -is [datetime]) {
                return $value
            }
            elseif ($value -is [string]) {
                if ([datetime]::TryParse($value, [ref]([datetime]$parsed))) {
                    return $parsed
                }
            }
        }
    }

    return $null
}

function Get-AlertCreatedTime {
    param (
        [Parameter(Mandatory)]
        $Alert
    )

    return Get-AlertTimestamp -Alert $Alert -PropertyNames @('created_time_stamp_in_usecs', 'created_time_usecs', 'creation_timestamp_in_usecs', 'creation_time', 'created_time')
}

function Get-AlertLastUpdatedTime {
    param (
        [Parameter(Mandatory)]
        $Alert
    )

    return Get-AlertTimestamp -Alert $Alert -PropertyNames @('last_updated_time_stamp_in_usecs', 'last_occurrence_time_usecs', 'last_updated_time', 'update_time')
}

function Invoke-NutanixAlertsQuery {
    param (
        [Parameter(Mandatory)]
        [string]$Endpoint,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$Credential
    )

    $apiVersions = @(
        'v4.1.b1', 'v4.1.a1', 'v4.0.b1', 'v4.0.a2', 'v4.0.a1', 'v4.0', 'v3'
    )
    $filters = @(
        'state=="UNRESOLVED"',
        'resolved_state=="UNRESOLVED"',
        'resolved==false'
    )
    $pageSize = 200

    foreach ($version in $apiVersions) {
        $baseUri = "https://$Endpoint:9440/api/nutanix/$version/alerts/list"
        foreach ($filter in $filters) {
            $collectedAlerts = @()
            $offset = 0
            $attemptSucceeded = $false

            try {
                while ($true) {
                    $body = @{
                        kind   = 'alert'
                        offset = $offset
                        length = $pageSize
                        filter = $filter
                    }

                    $response = Invoke-NutanixRestMethod -Uri $baseUri -Credential $Credential -Method 'Post' -Body $body
                    if ($null -eq $response) {
                        break
                    }

                    $entities = @()
                    if ($response.PSObject.Properties.Match('entities')) {
                        $entities = @($response.entities) | Where-Object { $_ }
                    }

                    $collectedAlerts += $entities
                    $attemptSucceeded = $true

                    $returnedCount = $entities.Count
                    if ($returnedCount -eq 0) {
                        break
                    }

                    $totalMatches = $null
                    if ($response.PSObject.Properties.Match('metadata') -and $response.metadata -and $response.metadata.PSObject.Properties.Match('total_matches')) {
                        $totalMatches = [int]$response.metadata.total_matches
                    }

                    $offset += $returnedCount
                    if ($null -ne $totalMatches -and $offset -ge $totalMatches) {
                        break
                    }
                }
            }
            catch {
                Write-Log -Level 'DEBUG' -Message "Alerts query failed for '$Endpoint' using version '$version' and filter '$filter': $($_.Exception.Message)"
                $attemptSucceeded = $false
            }

            if ($attemptSucceeded) {
                return [PSCustomObject]@{
                    Endpoint   = $Endpoint
                    ApiVersion = $version
                    Filter     = $filter
                    Alerts     = $collectedAlerts
                }
            }
        }
    }

    throw "Unable to retrieve alerts from '$Endpoint' using available API versions."
}

function Get-AlertSeverityCounts {
    param (
        [Parameter(Mandatory)]
        [System.Collections.IEnumerable]$Alerts
    )

    $counts = @{
        CRITICAL = 0
        WARNING  = 0
        INFO     = 0
        OTHER    = 0
    }

    foreach ($alert in $Alerts) {
        $severity = Get-AlertSeverity -Alert $alert
        switch ($severity) {
            'CRITICAL' { $counts.CRITICAL++ }
            'WARNING'  { $counts.WARNING++ }
            'INFO'     { $counts.INFO++ }
            default    { $counts.OTHER++ }
        }
    }

    return $counts
}

function New-DetailPageHtml {
    param (
        [Parameter(Mandatory)]
        [string]$Endpoint,

        [Parameter(Mandatory)]
        $Alerts,

        [Parameter()]
        [string]$ApiVersion,

        [Parameter()]
        [string]$Filter
    )

    Initialize-HtmlSupport

    $rowsBuilder = New-Object System.Text.StringBuilder
    foreach ($alert in $Alerts) {
        $identifier = ConvertTo-HtmlEncoded -InputObject (Get-AlertIdentifier -Alert $alert)
        $severity = Get-AlertSeverity -Alert $alert
        $severityCssClass = 'severity-other'
        switch ($severity) {
            'CRITICAL' { $severityCssClass = 'severity-critical' }
            'WARNING'  { $severityCssClass = 'severity-warning' }
            'INFO'     { $severityCssClass = 'severity-info' }
        }

        $title = ConvertTo-HtmlEncoded -InputObject (Get-AlertTitle -Alert $alert)
        $category = ConvertTo-HtmlEncoded -InputObject (Get-AlertCategory -Alert $alert)
        $entity = ConvertTo-HtmlEncoded -InputObject (Get-AlertEntities -Alert $alert)
        $message = ConvertTo-HtmlEncoded -InputObject (Get-AlertMessage -Alert $alert)
        $created = Format-DisplayDateTime -Value (Get-AlertCreatedTime -Alert $alert)
        $updated = Format-DisplayDateTime -Value (Get-AlertLastUpdatedTime -Alert $alert)
        $rawJson = ConvertTo-HtmlEncoded -InputObject ((ConvertTo-Json -InputObject $alert -Depth 8))

        $rowsBuilder.AppendLine(@"
            <tr>
                <td class="nowrap">$identifier</td>
                <td class="nowrap $severityCssClass">$severity</td>
                <td>$title</td>
                <td class="nowrap">$category</td>
                <td>$entity</td>
                <td class="nowrap">$created</td>
                <td class="nowrap">$updated</td>
                <td>$message</td>
            </tr>
            <tr class="raw-json-row">
                <td colspan="8">
                    <details>
                        <summary>Raw alert payload</summary>
                        <pre>$rawJson</pre>
                    </details>
                </td>
            </tr>
"@) | Out-Null
    }

    if ($rowsBuilder.Length -eq 0) {
        $rowsBuilder.AppendLine('<tr><td colspan="8" class="empty">No unresolved alerts.</td></tr>') | Out-Null
    }

    $header = ConvertTo-HtmlEncoded -InputObject $Endpoint
    $apiVersionHtml = if ($ApiVersion) { "<li><strong>API version:</strong> $ApiVersion</li>" } else { '' }
    $filterHtml = if ($Filter) { "<li><strong>Filter:</strong> $Filter</li>" } else { '' }

    return @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="utf-8" />
    <title>Alerts for $header</title>
    <style>
        body { font-family: Segoe UI, Arial, sans-serif; margin: 24px; }
        h1 { margin-bottom: 0; }
        .meta { list-style: none; padding: 0; margin: 8px 0 24px; }
        .meta li { margin: 4px 0; }
        table { border-collapse: collapse; width: 100%; }
        th, td { border: 1px solid #ccc; padding: 8px 10px; text-align: left; vertical-align: top; }
        th { background-color: #f5f5f5; }
        tr.raw-json-row td { background-color: #fcfcfc; font-size: 0.9em; }
        details { margin-top: 4px; }
        pre { white-space: pre-wrap; word-break: break-word; }
        .severity-critical { color: #c62828; font-weight: 600; }
        .severity-warning { color: #f57c00; font-weight: 600; }
        .severity-info { color: #1565c0; font-weight: 600; }
        .severity-other { color: #6a1b9a; font-weight: 600; }
        .nowrap { white-space: nowrap; }
        .empty { text-align: center; padding: 24px; color: #555; }
        a.back { display: inline-block; margin-top: 16px; }
    </style>
</head>
<body>
    <a href="index.html" class="back">&larr; Back to dashboard</a>
    <h1>Alerts for $header</h1>
    <ul class="meta">
        <li><strong>Unresolved alert count:</strong> $($Alerts.Count)</li>
        $apiVersionHtml
        $filterHtml
    </ul>
    <table>
        <thead>
            <tr>
                <th>ID</th>
                <th>Severity</th>
                <th>Title</th>
                <th>Category</th>
                <th>Entities</th>
                <th>Created</th>
                <th>Last Updated</th>
                <th>Message</th>
            </tr>
        </thead>
        <tbody>
            $($rowsBuilder.ToString())
        </tbody>
    </table>
</body>
</html>
"@
}

function New-DashboardHtml {
    param (
        [Parameter(Mandatory)]
        [System.Collections.IEnumerable]$SummaryRows
    )

    Initialize-HtmlSupport

    $rowsBuilder = New-Object System.Text.StringBuilder
    foreach ($row in $SummaryRows) {
        $endpoint = ConvertTo-HtmlEncoded -InputObject $row.Endpoint
        if ($row.DetailFile) {
            $link = "<a href=""" + $row.DetailFile + """>" + $endpoint + "</a>"
        } else {
            $link = $endpoint
        }
        $criticalClass = if ($row.Critical -gt 0) { 'severity-critical' } else { '' }
        $warningClass = if ($row.Warning -gt 0) { 'severity-warning' } else { '' }
        $infoClass = if ($row.Info -gt 0) { 'severity-info' } else { '' }
        $otherClass = if ($row.Other -gt 0) { 'severity-other' } else { '' }
        $statusBadge = if ($row.ErrorMessage) { '<span class="status status-error">Error</span>' } else { '<span class="status status-ok">OK</span>' }
        $apiVersion = if ($row.ApiVersion) { ConvertTo-HtmlEncoded -InputObject $row.ApiVersion } else { 'n/a' }
        $filter = if ($row.Filter) { ConvertTo-HtmlEncoded -InputObject $row.Filter } else { 'n/a' }
        $errorHtml = if ($row.ErrorMessage) { "<div class='error-message'>$([System.Web.HttpUtility]::HtmlEncode($row.ErrorMessage))</div>" } else { '' }

        $rowsBuilder.AppendLine(@"
            <tr>
                <td>$link $statusBadge $errorHtml</td>
                <td class="$criticalClass">$($row.Critical)</td>
                <td class="$warningClass">$($row.Warning)</td>
                <td class="$infoClass">$($row.Info)</td>
                <td class="$otherClass">$($row.Other)</td>
                <td>$apiVersion</td>
                <td>$filter</td>
            </tr>
"@) | Out-Null
    }

    if ($rowsBuilder.Length -eq 0) {
        $rowsBuilder.AppendLine('<tr><td colspan="7" class="empty">No endpoints were processed.</td></tr>') | Out-Null
    }

    return @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="utf-8" />
    <title>Nutanix Alerts Dashboard</title>
    <style>
        body { font-family: Segoe UI, Arial, sans-serif; margin: 24px; background-color: #fafafa; }
        h1 { margin-bottom: 0.5em; }
        p.subtitle { color: #555; margin-top: 0; }
        table { border-collapse: collapse; width: 100%; background-color: #fff; box-shadow: 0 2px 4px rgba(0,0,0,0.07); }
        th, td { border: 1px solid #e0e0e0; padding: 10px 12px; text-align: left; vertical-align: middle; }
        th { background-color: #f5f5f5; }
        a { color: #1565c0; text-decoration: none; }
        a:hover { text-decoration: underline; }
        .severity-critical { color: #c62828; font-weight: 600; }
        .severity-warning { color: #f57c00; font-weight: 600; }
        .severity-info { color: #1565c0; font-weight: 600; }
        .severity-other { color: #6a1b9a; font-weight: 600; }
        .status { font-size: 0.75em; padding: 2px 6px; border-radius: 4px; margin-left: 8px; }
        .status-ok { background-color: #e8f5e9; color: #2e7d32; }
        .status-error { background-color: #ffebee; color: #c62828; }
        .error-message { color: #c62828; font-size: 0.85em; margin-top: 4px; }
        .empty { text-align: center; padding: 24px; color: #555; }
        footer { margin-top: 32px; font-size: 0.85em; color: #777; }
        code { background: #efefef; padding: 1px 4px; border-radius: 3px; }
    </style>
</head>
<body>
    <h1>Nutanix Alerts Dashboard</h1>
    <p class="subtitle">Unresolved alerts grouped by endpoint. Click an endpoint name for alert details.</p>
    <table>
        <thead>
            <tr>
                <th>Endpoint</th>
                <th>Critical</th>
                <th>Warning</th>
                <th>Info</th>
                <th>Other</th>
                <th>API Version</th>
                <th>Filter</th>
            </tr>
        </thead>
        <tbody>
            $($rowsBuilder.ToString())
        </tbody>
    </table>
    <footer>
        Generated on $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss').
    </footer>
</body>
</html>
"@
}

function Get-AlertsForTargets {
    param (
        [Parameter(Mandatory)]
        [string[]]$Targets,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$Credential
    )

    $results = @()
    foreach ($target in $Targets) {
        Write-Log -Level 'INFO' -Message "Collecting alerts from '$target'..."
        try {
            $queryResult = Invoke-NutanixAlertsQuery -Endpoint $target -Credential $Credential
            $results += [PSCustomObject]@{
                Endpoint    = $target
                ApiVersion  = $queryResult.ApiVersion
                Filter      = $queryResult.Filter
                Alerts      = $queryResult.Alerts
                Success     = $true
                ErrorMessage = $null
            }
            Write-Log -Level 'INFO' -Message "Retrieved $($queryResult.Alerts.Count) unresolved alerts from '$target'."
        }
        catch {
            $message = $_.Exception.Message
                
            $results += [PSCustomObject]@{
                Endpoint     = $target
                ApiVersion   = $null
                Filter       = $null
                Alerts       = @()
                Success      = $false
                ErrorMessage = $message
            }
            Write-Log -Level 'ERROR' -Message "Failed to retrieve alerts from '$target': $message"
        }
    }

    return $results
}

function Publish-AlertsDashboard {
    param (
        [Parameter(Mandatory)]
        [System.Collections.IEnumerable]$Results,

        [Parameter(Mandatory)]
        [string]$OutputDirectory
    )

    New-Directory -Path $OutputDirectory

    $summaryRows = @()
    foreach ($result in $Results) {
        $counts = Get-AlertSeverityCounts -Alerts $result.Alerts

        $detailFileName = $null
        if ($result.Success) {
            $safeFile = Get-SafeFileName -BaseName $result.Endpoint
            $detailFileName = "alerts_$safeFile.html"
            $detailHtml = New-DetailPageHtml -Endpoint $result.Endpoint -Alerts $result.Alerts -ApiVersion $result.ApiVersion -Filter $result.Filter
            $detailPath = Join-Path -Path $OutputDirectory -ChildPath $detailFileName
            Write-TextFileUtf8 -Path $detailPath -Content $detailHtml
        }

        $summaryRows += [PSCustomObject]@{
            Endpoint   = $result.Endpoint
            Critical   = $counts.CRITICAL
            Warning    = $counts.WARNING
            Info       = $counts.INFO
            Other      = $counts.OTHER
            ApiVersion = $result.ApiVersion
            Filter     = $result.Filter
            DetailFile = $detailFileName
            ErrorMessage = $result.ErrorMessage
        }
    }

    $dashboardHtml = New-DashboardHtml -SummaryRows $summaryRows
    $indexPath = Join-Path -Path $OutputDirectory -ChildPath 'index.html'
    Write-TextFileUtf8 -Path $indexPath -Content $dashboardHtml

    return $indexPath
}

try {
    Initialize-TlsConfiguration -Mode $TlsValidation

    $credential = Get-NutanixCredential -ForceReset:$ForceCredentialReset
    $targets = Get-ClusterTargetsFromFile -Path $ClusterListPath
    $results = Get-AlertsForTargets -Targets $targets -Credential $credential

    $indexPath = Publish-AlertsDashboard -Results $results -OutputDirectory $OutputDirectory

    Write-Log -Level 'INFO' -Message "Dashboard generated at '$indexPath'."

    if ($OpenDashboard.IsPresent -and (Test-Path -LiteralPath $indexPath)) {
        Write-Log -Level 'INFO' -Message 'Opening dashboard in default browser.'
        Start-Process -FilePath $indexPath | Out-Null
    }
}
catch {
    Write-Log -Level 'ERROR' -Message $_.Exception.Message
    throw
}
