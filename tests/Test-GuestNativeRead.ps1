#Requires -Version 7.2
# Native ARM response/reconciliation contracts; no network or guest execution.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'scripts\Azure.Common.psm1') -Force
. (Join-Path $root 'scripts\guest\GuestNativeRead.ps1')
$subscription = [guid]::NewGuid().ToString()
$location = 'swedencentral'
$vmId = "/subscriptions/$subscription/resourceGroups/test/providers/Microsoft.Compute/virtualMachines/test"
$directory = Join-Path $root ".azure\native-read-tests-$([guid]::NewGuid().ToString('N'))"
$null = New-Item -ItemType Directory -Path $directory
$statePath = Join-Path $directory 'state.json'
$scriptPath = Join-Path $directory 'probe.sh'
Set-Content $scriptPath 'printf fixed-probe' -Encoding utf8NoBOM
$operationId = [guid]::NewGuid().ToString()
$url = "https://management.azure.com/subscriptions/$subscription/providers/Microsoft.Compute/locations/$location/operations/$operationId`?api-version=2025-04-01"
$resultUrl = "$url&monitor=true"
$script:checks = 0
function Assert-Rejected {
    param([scriptblock]$Action, [string]$Pattern = '.')
    $rejected = $false
    try { & $Action | Out-Null } catch {
        if ($_.Exception.Message -notmatch $Pattern) { throw }
        $rejected = $true
    }
    if (-not $rejected) { throw 'Unsafe or success-shaped native read outcome accepted.' }
    $script:checks++
}
function New-TestState {
    $script:state = @{ ownerToken = [guid]::NewGuid().ToString(); pendingCommand = $null }
    $script:state.nativeRead = @{
        ownerToken = $script:state.ownerToken; vmId = $vmId; commandId = [guid]::NewGuid().ToString()
        kind = 'Probe'; scriptSha256 = (Get-FileHash $scriptPath -Algorithm SHA256).Hash.ToLowerInvariant()
        phase = 'SubmissionUnknown'; statusUrl = $null; resultUrl = $null
    }
    $script:requests = @()
    $script:responses = [Collections.Generic.Queue[object]]::new()
}
function New-TestResponse {
    param([int]$Status = 200, [hashtable]$Body = @{}, [hashtable]$Headers = @{})
    return @{ StatusCode = $Status; Content = ($Body | ConvertTo-Json -Depth 12 -Compress); Headers = $Headers }
}
$requestFunction = ${function:Invoke-GuestNativeReadRequest}
function Invoke-GuestNativeReadRequest {
    param([string]$Method, [string]$Url, [hashtable]$Body)
    $script:requests += @{ method = $Method; url = $Url }
    if (-not $script:responses.Count) { throw 'No mocked response available.' }
    return $script:responses.Dequeue()
}
try {
    Assert-GuestNativeReadOutput @{ value = @(@{ code = 'ComponentStatus/StdOut/succeeded'; message = 'fixed' }) }
    Assert-Rejected { Assert-GuestNativeReadOutput @{ value = @(@{ code = 'ComponentStatus/StdOut/failed'; message = 'failed' }) } } 'guest failure'
    Assert-Rejected { Assert-GuestNativeReadOutput @{ value = @(@{ message = 'missing status' }) } } 'guest failure'
    Assert-GuestNativeReadOutput @{ value = @(@{ code = 'ProvisioningState/succeeded'; message = "Enable succeeded: `n[stdout]`nfixed`n[stderr]`n" }) }
    Assert-GuestNativeReadUrl $url
    Assert-GuestNativeReadUrl $resultUrl
    $signedUrl = "$url&p=$([guid]::NewGuid())&t=639273174744568656&c=$('A' * 5000)&s=synthetic-signature&h=synthetic-hash"
    Assert-GuestNativeReadUrl $signedUrl
    foreach ($bad in @($signedUrl.Replace('&p=', '&q='), "$signedUrl&p=$([guid]::NewGuid())",
        $signedUrl.Replace('synthetic-signature', 'invalid!signature'),
        $signedUrl.Replace('639273174744568656', 'not-ticks'),
        $signedUrl.Replace('&h=synthetic-hash', ''))) { Assert-Rejected { Assert-GuestNativeReadUrl $bad } }
    foreach ($bad in @(
        $url.Replace('https:', 'http:'), $url.Replace('management.azure.com', 'example.invalid'),
        $url.Replace('management.azure.com', 'management.azure.com:444'),
        $url.Replace('management.azure.com', 'user@management.azure.com'),
        "$url#fragment", "$url&secret=forbidden", "$url&api-version=2025-04-01",
        $url.Replace($subscription, [guid]::NewGuid().ToString()),
        $url.Replace($location, 'westeurope'), $url.Replace('2025-04-01', '2024-01-01'),
        $url.Replace('/operations/', '/virtualMachines/'), $url.Replace('/operations/', '/operations/../operations/'),
        $url.Replace('/operations/', '/%6fperations/'), "$url&monitor=false"
    )) { Assert-Rejected { Assert-GuestNativeReadUrl $bad } }

    New-TestState
    $script:state.nativeRead.resultUrl = $signedUrl
    $summary = Get-GuestNativeReadSummary
    if (($summary | ConvertTo-Json -Compress) -match 'synthetic-signature|statusUrl|resultUrl' -or
        -not $summary.hasTrackingHandle -or $script:state.nativeRead.resultUrl -cne $signedUrl) {
        throw 'Opaque tracking query exposed in public summary or altered for polling.'
    }
    New-TestState
    Assert-Rejected { Wait-GuestNativeRead -WaitSeconds 1 } 'unknown'
    if ($script:requests.Count) { throw 'Missing handle caused a request.' }
    $script:state.nativeRead.ownerToken = [guid]::NewGuid().ToString()
    Assert-Rejected { Assert-GuestNativeReadRecord } 'foreign'
    New-TestState
    $script:state.nativeRead.vmId += '-foreign'
    Assert-Rejected { Assert-GuestNativeReadRecord } 'foreign'
    New-TestState
    $script:state.nativeRead.statusUrl = $url
    $script:state.nativeRead.resultUrl = $resultUrl.Replace($operationId, [guid]::NewGuid().ToString())
    Assert-Rejected { Assert-GuestNativeReadRecord } 'different operations'

    New-TestState
    $accepted = New-TestResponse -Status 202 -Headers @{ Location = @($resultUrl); 'Retry-After' = @('5') }
    $null = Complete-GuestNativeReadResponse $accepted -Submission
    Assert-Rejected { Wait-GuestNativeRead -WaitSeconds 1 } 'deadline'
    if ($script:requests.Count) { throw 'Retry-After was ignored.' }
    $script:state.nativeRead.observedAtUtc = [DateTimeOffset]::UtcNow.AddMinutes(-1).ToString('o')
    $script:responses.Enqueue((New-TestResponse -Body @{ status = 'InProgress' }))
    Assert-Rejected { Wait-GuestNativeRead -WaitSeconds 1 } 'deadline'
    if ($script:requests.Count -ne 1 -or $script:requests[0].method -cne 'GET') { throw 'Poll did not use exact GET-only tracking.' }
    $script:state.nativeRead.observedAtUtc = [DateTimeOffset]::UtcNow.AddMinutes(-1).ToString('o')
    $output = @{ value = @(@{ code = 'ComponentStatus/StdOut/succeeded'; message = 'fixed probe output' }) }
    $script:responses.Enqueue((New-TestResponse -Body $output))
    $result = Wait-GuestNativeRead -WaitSeconds 1
    if ($result.value[0].message -cne 'fixed probe output' -or $script:state.nativeRead.phase -cne 'ResultReceived' -or
        @($script:requests | Where-Object method -CEQ 'POST').Count) { throw 'Resumption lost output or replayed POST.' }
    $null = Wait-GuestNativeRead
    if ($script:requests.Count -ne 2) { throw 'Reading saved output submitted another request.' }
    Set-Content (Join-Path $directory "guest-native-read-$($script:state.nativeRead.commandId).json") '{}' -Encoding utf8NoBOM
    Assert-Rejected { Wait-GuestNativeRead } 'changed'

    New-TestState
    $null = Complete-GuestNativeReadResponse (New-TestResponse -Status 202 -Headers @{
        'Azure-AsyncOperation' = @($url); Location = @($resultUrl); 'Retry-After' = @('0')
    }) -Submission
    $script:state.nativeRead.observedAtUtc = [DateTimeOffset]::UtcNow.AddMinutes(-1).ToString('o')
    $script:responses.Enqueue((New-TestResponse -Body @{ status = 'Succeeded' }))
    Assert-Rejected { Wait-GuestNativeRead -WaitSeconds 1 } 'deadline'
    $script:state.nativeRead.observedAtUtc = [DateTimeOffset]::UtcNow.AddMinutes(-1).ToString('o')
    $script:responses.Enqueue((New-TestResponse -Body $output))
    $null = Wait-GuestNativeRead -WaitSeconds 1
    if ($script:requests[0].url -cne $url -or $script:requests[1].url -cne $resultUrl) { throw 'Wrong status/output URL ordering.' }

    foreach ($terminal in @('Failed', 'Canceled')) {
        New-TestState
        Assert-Rejected { Complete-GuestNativeReadResponse (New-TestResponse -Body @{
            status = $terminal; error = @{ code = 'GuestExecutionFailed'; message = 'do-not-persist-raw-error' }
        }) } $terminal
        if ($script:state.nativeRead.phase -ceq 'ResultReceived') { throw 'Provider failure accepted as output.' }
    }
    foreach ($value in @(@(), @(@{ message = '' }), @(@{ message = 42 }), @('not-an-object'))) {
        New-TestState
        Assert-Rejected { Complete-GuestNativeReadResponse (New-TestResponse -Body @{ value = $value }) } 'without command output'
    }
    New-TestState
    $null = Complete-GuestNativeReadResponse (New-TestResponse -Body @{ status = 'Succeeded' })
    Assert-Rejected { Assert-GuestNativeReadSettled } 'unresolved'
    New-TestState
    Assert-Rejected { Complete-GuestNativeReadResponse (New-TestResponse -Body @{ status = 'do-not-persist-raw-status' }) } 'unsupported operation status'
    if ((Get-Content $statePath -Raw) -match 'do-not-persist-raw-status') { throw 'Unrestricted status persisted.' }
    $script:state.nativeRead.phase = 'SubmissionUnknown'
    Assert-Rejected { Invoke-GuestNativeRead -Kind Telemetry -ScriptPath $scriptPath } 'Different'
    New-TestState
    Assert-Rejected { Complete-GuestNativeReadResponse (New-TestResponse -Status 202) -Submission } 'no tracking URL'
    Assert-Rejected { Invoke-GuestNativeRead -Kind Probe -ScriptPath $scriptPath } 'unknown'
    if ($script:requests.Count) { throw 'Lost acceptance response was replayed.' }
    New-TestState
    $malformed = New-TestResponse -Status 202 -Headers @{ Location = @($resultUrl) }
    $malformed.Content = 'not-json-do-not-persist'
    Assert-Rejected { Complete-GuestNativeReadResponse $malformed -Submission } 'invalid JSON'
    $saved = Get-Content $statePath -Raw | ConvertFrom-Json -AsHashtable
    if ($saved.nativeRead.resultUrl -cne $resultUrl -or $saved.nativeRead.httpStatus -ne 202 -or
        (Get-Content $statePath -Raw) -match 'not-json-do-not-persist') { throw 'Malformed response lost safe tracking metadata.' }
    New-TestState
    $script:state.Remove('nativeRead')
    Assert-Rejected { Invoke-GuestNativeRead -Kind Probe -ScriptPath $scriptPath } 'No mocked response'
    Assert-Rejected { Invoke-GuestNativeRead -Kind Probe -ScriptPath $scriptPath } 'unknown'
    if ($script:requests.Count -ne 1 -or $script:state.nativeRead.phase -cne 'SubmissionUnknown') {
        throw 'Lost initial response was resubmitted.'
    }
    New-TestState
    Assert-Rejected { Complete-GuestNativeReadResponse (New-TestResponse -Status 409 -Body @{
        error = @{ code = 'Conflict'; message = 'do-not-persist-raw-error'; details = @('forbidden-detail') }
    }) } '409, code Conflict'
    if ((Get-Content $statePath -Raw) -match 'do-not-persist|forbidden-detail') { throw 'Raw service error persisted.' }
    New-TestState
    $script:state.nativeRead.resultUrl = $resultUrl
    $script:responses.Enqueue((New-TestResponse -Status 429 -Headers @{ 'Retry-After' = @('60') }))
    Assert-Rejected { Wait-GuestNativeRead -WaitSeconds 1 } 'deadline'
    if ($script:requests.Count -ne 1 -or $script:state.nativeRead.retryAfterSeconds -ne 60) { throw 'Throttle was not retained.' }
    New-TestState
    $script:state.pendingCommand = @{ action = 'configure' }
    Assert-Rejected { Invoke-GuestNativeRead -Kind Probe -ScriptPath $scriptPath } 'outstanding guest write'
    New-TestState
    $script:state.Remove('nativeRead')
    $script:responses.Enqueue((New-TestResponse -Body $output))
    $null = Invoke-GuestNativeRead -Kind Probe -ScriptPath $scriptPath
    if ($script:requests.Count -ne 1 -or $script:requests[0].method -cne 'POST') { throw 'Initial read not submitted exactly once.' }
    if (-not (Test-Path (Join-Path $directory "guest-native-read-$($script:state.nativeRead.commandId)-operation.json"))) {
        throw 'Operation metadata not archived.'
    }

    # Exercise the real request wrapper with only credentials/HTTP mocked.
    function Invoke-Azure { return @{ accessToken = 'unit-test-placeholder' } }
    function Invoke-WebRequest {
        param($Uri, $Method, $Authentication, $Token, $MaximumRedirection, $TimeoutSec,
            $SkipHttpErrorCheck, $Headers, $ContentType, $Body)
        if ($MaximumRedirection -ne 0 -or $TimeoutSec -ne 30 -or $Authentication -cne 'Bearer' -or
            $Token -isnot [securestring]) { throw 'Unsafe authenticated HTTP options.' }
        return New-TestResponse -Body $output
    }
    $null = & $requestFunction -Method GET -Url $resultUrl
    function Invoke-WebRequest { throw 'do-not-echo-token-or-service-error' }
    Assert-Rejected { & $requestFunction -Method GET -Url $resultUrl } 'GET transport failed'
    if ((Get-Content $statePath -Raw) -match 'do-not-echo|unit-test-placeholder') { throw 'Credential or raw transport error persisted.' }
    "Native read contracts passed ($($script:checks) rejection checks)."
} finally {
    Remove-Item -LiteralPath $directory -Recurse -Force
}
