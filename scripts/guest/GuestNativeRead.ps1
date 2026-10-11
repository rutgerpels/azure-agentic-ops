# Operator-only Action Run Command diagnostics, inside the fixture lifecycle lease.
function Assert-GuestNativeReadUrl {
    param([Parameter(Mandatory)][string]$Url)
    $uri = [uri]$Url
    $prefix = "/subscriptions/$subscription/providers/Microsoft.Compute/locations/$location/"
    if ($Url.Length -gt 16384 -or -not $uri.IsAbsoluteUri -or $uri.Scheme -cne 'https' -or
        $uri.Host -cne 'management.azure.com' -or $uri.Port -ne 443 -or
        $uri.UserInfo -or $uri.Fragment -or $Url.Contains('%') -or $Url.Contains('\') -or
        $Url -match '/\.{1,2}(/|\?)' -or
        $uri.AbsolutePath -notmatch "^$([regex]::Escape($prefix))(operations|operationResults)/([a-fA-F0-9-]{36})$") {
        throw 'Native read operation URL is outside the exact Azure subscription/region.'
    }
    $null = [guid]::Parse(($uri.AbsolutePath -split '/')[-1])
    $keys = @{}
    foreach ($part in $uri.Query.TrimStart('?').Split('&', [StringSplitOptions]::RemoveEmptyEntries)) {
        $pair = $part.Split('=', 2)
        if ($pair.Count -ne 2 -or $keys.ContainsKey($pair[0]) -or
            $pair[0] -cnotin @('api-version', 'monitor', 'p', 't', 'c', 's', 'h')) { throw 'Unexpected native read URL query.' }
        $keys[$pair[0]] = $pair[1]
    }
    if ($keys['api-version'] -cne '2025-04-01' -or
        ($keys.ContainsKey('monitor') -and $keys.monitor -cne 'true')) {
        throw 'Native read operation API version or monitor flag changed.'
    }
    $signedKeys = @('p', 't', 'c', 's', 'h')
    $signedCount = @($signedKeys | Where-Object { $keys.ContainsKey($_) }).Count
    if ($signedCount) {
        if ($signedCount -ne $signedKeys.Count -or
            $keys.p -cnotmatch '^[a-fA-F0-9-]{36}$' -or $keys.t -cnotmatch '^[0-9]{1,19}$' -or
            $keys.c -cnotmatch '^[A-Za-z0-9_-]{1,8192}$' -or
            $keys.s -cnotmatch '^[A-Za-z0-9_-]{1,1024}$' -or $keys.h -cnotmatch '^[A-Za-z0-9_-]{1,1024}$') {
            throw 'Malformed signed native operation query.'
        }
        $null = [guid]::Parse($keys.p)
    }
}
function Invoke-GuestNativeReadRequest {
    param([ValidateSet('GET', 'POST')][string]$Method, [string]$Url, [hashtable]$Body)
    if ($Method -ceq 'GET') { Assert-GuestNativeReadUrl $Url }
    elseif ($Url -cne "https://management.azure.com$vmId/runCommand?api-version=2025-04-01") {
        throw 'Native read submission targets a different VM.'
    }
    $script:state.nativeRead.requestStage = 'operator-token'
    Save-GuestNativeReadRecord
    $credentials = Invoke-Azure @('account', 'get-access-token', '--resource', 'https://management.azure.com/')
    $token = ConvertTo-SecureString $credentials.accessToken -AsPlainText -Force
    $credentials = $null
    $arguments = @{ Uri = $Url; Method = $Method; Authentication = 'Bearer'; Token = $token
        MaximumRedirection = 0; TimeoutSec = 30; SkipHttpErrorCheck = $true
        Headers = @{ 'x-ms-client-request-id' = $script:state.nativeRead.commandId } }
    if ($Body) { $arguments.ContentType = 'application/json'; $arguments.Body = $Body | ConvertTo-Json -Compress }
    $script:state.nativeRead.requestStage = "$Method-request"
    Save-GuestNativeReadRecord
    try { return Invoke-WebRequest @arguments }
    catch {
        $script:state.nativeRead.transportError = $_.Exception.GetType().Name
        Save-GuestNativeReadRecord
        throw "Native read $Method transport failed ($($script:state.nativeRead.transportError)); saved outcome remains unknown. Never replay POST."
    }
    finally { $arguments.Token = $null; $token = $null }
}
function Save-GuestNativeReadRecord {
    Save-RetailState $script:state $statePath
    Save-RetailState $script:state.nativeRead (Join-Path $directory "guest-native-read-$($script:state.nativeRead.commandId)-operation.json")
}
function Get-GuestNativeReadSummary {
    $summary = $script:state.nativeRead.Clone()
    $summary.Remove('statusUrl')
    $summary.Remove('resultUrl')
    $summary.hasTrackingHandle = [bool]($script:state.nativeRead.statusUrl -or $script:state.nativeRead.resultUrl)
    return $summary
}
function Get-GuestNativeReadErrorCode {
    param([hashtable]$Body)
    $code = if ($Body['error'] -is [hashtable]) { $Body.error['code'] } else { $null }
    if ($code -is [string] -and $code -cmatch '^[A-Za-z][A-Za-z0-9_.-]{0,99}$') { return $code }
    return 'UnspecifiedAzureError'
}
function Assert-GuestNativeReadRecord {
    $record = $script:state['nativeRead']
    if (-not $record -or $record.ownerToken -cne $script:state.ownerToken -or $record.vmId -ine $vmId -or
        $record.kind -cnotin @('Probe', 'Telemetry') -or $record.scriptSha256 -cnotmatch '^[a-f0-9]{64}$' -or
        $record.phase -cnotin @('SubmissionUnknown', 'Accepted', 'ResultReceived')) {
        throw 'Native read intent is missing, foreign or malformed.'
    }
    $null = [guid]::Parse($record.commandId)
    foreach ($field in @('statusUrl', 'resultUrl')) {
        if ($record[$field]) { Assert-GuestNativeReadUrl $record[$field] }
    }
    if ($record.statusUrl -and $record.resultUrl -and
        (([uri]$record.statusUrl).AbsolutePath -split '/')[-1] -cne
        (([uri]$record.resultUrl).AbsolutePath -split '/')[-1]) {
        throw 'Native read status and result URLs identify different operations.'
    }
}
function Assert-GuestNativeReadSettled {
    if ($script:state['nativeRead'] -and $script:state.nativeRead.phase -cne 'ResultReceived') {
        throw 'Native diagnostic outcome unresolved; use Command to reconcile or Down. Do not submit another guest command.'
    }
}
function Assert-GuestNativeReadOutput {
    param([hashtable]$Result)
    if (@($Result.value | Where-Object { $_['code'] -isnot [string] -or $_.code -cnotmatch '/succeeded$' }).Count) {
        throw 'Native diagnostic returned guest failure status; output is preserved, readiness not accepted.'
    }
}
function Complete-GuestNativeReadResponse {
    param($Response, [switch]$Submission)
    $record = $script:state.nativeRead
    $record.httpStatus = [int]$Response.StatusCode
    $record.observedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    foreach ($header in @('x-ms-request-id', 'x-ms-correlation-request-id')) {
        $requestId = [string](@($Response.Headers[$header])[0])
        if ($requestId -cmatch '^[A-Za-z0-9_.:-]{1,100}$') { $record[$header] = $requestId }
    }
    $retry = [string](@($Response.Headers['Retry-After'])[0])
    if ($retry -match '^\d{1,5}$') { $record.retryAfterSeconds = [int]$retry }
    if ($Submission -and $record.httpStatus -eq 202) {
        $record.statusUrl = [string](@($Response.Headers['Azure-AsyncOperation'])[0])
        $record.resultUrl = [string](@($Response.Headers['Location'])[0])
        $record.phase = 'Accepted'
        Save-GuestNativeReadRecord
        Assert-GuestNativeReadRecord
        if (-not $record.statusUrl -and -not $record.resultUrl) {
            throw 'Accepted native read has no tracking URL; preserve intent and use Down, never replay.'
        }
    }
    Save-GuestNativeReadRecord
    try {
        $body = if ($Response.Content) { $Response.Content | ConvertFrom-Json -AsHashtable } else { @{} }
    } catch [System.ArgumentException] {
        $record.errorCode = 'InvalidAzureResponse'
        Save-GuestNativeReadRecord
        throw 'Native read returned invalid JSON; safe HTTP metadata was saved, outcome unresolved.'
    }
    if ($body -isnot [hashtable]) {
        throw 'Native read returned a nonobject response; HTTP metadata saved, outcome unresolved.'
    }
    if ($record.httpStatus -notin @(200, 202, 204)) {
        $record.errorCode = Get-GuestNativeReadErrorCode $body
        Save-GuestNativeReadRecord
        throw "Native read HTTP $($record.httpStatus), code $($record.errorCode). Saved intent remains unresolved; no resubmission."
    }
    if ($record.httpStatus -eq 200 -and $body.ContainsKey('value')) {
        if ($body.value -isnot [array] -or @($body.value).Count -eq 0 -or
            @($body.value | Where-Object { $_ -isnot [hashtable] -or $_['message'] -isnot [string] }).Count -or
            -not @($body.value | Where-Object { $_.message }).Count) {
            throw 'Native read completed without command output; no readiness acceptance.'
        }
        $resultPath = Join-Path $directory "guest-native-read-$($record.commandId).json"
        Save-RetailState $body $resultPath
        $record.resultSha256 = (Get-FileHash $resultPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $record.phase = 'ResultReceived'
        Save-GuestNativeReadRecord
        return $body
    }
    if ($body['status']) {
        if ($body.status -isnot [string] -or $body.status -cnotin @('InProgress', 'Running', 'Succeeded', 'Failed', 'Canceled', 'Cancelled')) {
            $record.errorCode = 'InvalidAzureStatus'
            Save-GuestNativeReadRecord
            throw 'Native read returned an unsupported operation status; outcome remains unresolved.'
        }
        $record.azureStatus = [string]$body.status
        if ($body.status -cin @('Failed', 'Canceled', 'Cancelled')) {
            $record.errorCode = Get-GuestNativeReadErrorCode $body
            Save-GuestNativeReadRecord
            throw "Native read operation $($body.status), code $($record.errorCode); inspect the saved diagnostic."
        }
    }
    Save-GuestNativeReadRecord
    return $null
}
function Wait-GuestNativeRead {
    param([ValidateRange(1, 180)][int]$WaitSeconds = 180)
    Assert-GuestNativeReadRecord
    $record = $script:state.nativeRead
    if ($record.phase -ceq 'ResultReceived') {
        $resultPath = Join-Path $directory "guest-native-read-$($record.commandId).json"
        if ((Get-FileHash $resultPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $record.resultSha256) {
            throw 'Saved native read output changed.'
        }
        return Get-Content $resultPath -Raw | ConvertFrom-Json -AsHashtable
    }
    if (-not $record.statusUrl -and -not $record.resultUrl) {
        throw 'Native read submission outcome unknown, no handle available. Use Down; do not replay.'
    }
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($WaitSeconds)
    do {
        if ($record['observedAtUtc']) {
            $delay = if ($record.ContainsKey('retryAfterSeconds')) { [Math]::Max(1, $record.retryAfterSeconds) } else { 5 }
            $due = ([DateTimeOffset]$record.observedAtUtc).AddSeconds($delay)
            $pause = ($due - [DateTimeOffset]::UtcNow).TotalSeconds
            if ($due -ge $deadline) { break }
            if ($pause -gt 0) { Start-Sleep -Milliseconds ([int][Math]::Ceiling($pause * 1000)) }
        }
        $url = if ($record.statusUrl -and $record['azureStatus'] -cne 'Succeeded') {
            $record.statusUrl
        } else { $record.resultUrl }
        if (-not $url) { throw 'Operation succeeded without an output URL; result remains unverified.' }
        $response = Invoke-GuestNativeReadRequest GET $url
        if ([int]$response.StatusCode -in @(429, 502, 503, 504)) {
            $record.httpStatus = [int]$response.StatusCode
            $record.observedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
            $retry = [string](@($response.Headers['Retry-After'])[0])
            if ($retry -match '^\d{1,5}$') { $record.retryAfterSeconds = [int]$retry }
            Save-GuestNativeReadRecord
        } else {
            $result = Complete-GuestNativeReadResponse $response
            if ($result) { return $result }
        }
    } while ([DateTimeOffset]::UtcNow -lt $deadline)
    throw 'Native read observation deadline reached. Command resumes GET-only tracking of this exact operation; no new submission.'
}
function Invoke-GuestNativeRead {
    <#
    .SYNOPSIS
    Submit one operator diagnostic, preserving its native Azure operation handle.
    .DESCRIPTION
    A repeated identical diagnostic resumes GET-only polling; a lost response never replays POST.
    .EXAMPLE
    Invoke-GuestNativeRead -Kind Telemetry -ScriptPath $queryPath
    #>
    param([ValidateSet('Probe', 'Telemetry')][string]$Kind, [string]$ScriptPath)
    if ($script:state['pendingCommand']) { throw 'Native diagnostics require reconciliation of the outstanding guest write first.' }
    $hash = (Get-FileHash $ScriptPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($script:state['nativeRead'] -and $script:state.nativeRead.phase -cne 'ResultReceived') {
        Assert-GuestNativeReadRecord
        if ($script:state.nativeRead.kind -cne $Kind -or $script:state.nativeRead.scriptSha256 -cne $hash) {
            throw 'Different native diagnostic already outstanding; use Command or Down.'
        }
        return Wait-GuestNativeRead
    }
    $record = @{ commandId = [guid]::NewGuid().ToString(); ownerToken = $script:state.ownerToken; vmId = $vmId
        kind = $Kind; scriptSha256 = $hash; phase = 'SubmissionUnknown'; statusUrl = $null; resultUrl = $null
        submittedAtUtc = [DateTimeOffset]::UtcNow.ToString('o') }
    $script:state.nativeRead = $record
    Save-GuestNativeReadRecord
    $response = Invoke-GuestNativeReadRequest POST "https://management.azure.com$vmId/runCommand?api-version=2025-04-01" @{
        commandId = 'RunShellScript'; script = @((Get-Content $ScriptPath -Raw))
    }
    $result = Complete-GuestNativeReadResponse $response -Submission
    if ($result) { return $result }
    return Wait-GuestNativeRead
}
