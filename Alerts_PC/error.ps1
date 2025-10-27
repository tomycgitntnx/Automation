       Write-Host "Connecting to Prism Central: $pc"
        $apiUrl = "https://{0}:9440/api/monitoring/v4.0/serviceability/alerts" -f $pc
        $authHeader = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(("{0}:{1}" -f $credential.UserName, $credential.GetNetworkCredential().Password)))
        $headers = @{ "Authorization" = $authHeader; "Content-Type"  = "application/json" }
        $filter = "?`$filter=isResolved eq false and sourceEntity/type eq 'cluster'&`$expand=sourceEntity"
        $fullUrl = $apiUrl + $filter

        try {
            $response = Invoke-RestMethod -Uri $fullUrl -Method Get -Headers $headers -ErrorAction Stop
            if ($null -ne $response.data) {
                Write-Host "Successfully retrieved $($response.data.Count) unresolved alerts from $pc."
                $response.data | ForEach-Object {
                    $_ | Add-Member -MemberType NoteProperty -Name "PrismCentral" -Value $pc
                    $allAlerts += $_
                }
            } else { Write-Host "No unresolved alerts from Prism Element clusters found on $pc." }
        } catch { Write-Warning "Failed to retrieve alerts from $pc. Error: $($_.Exception.Message)" }
