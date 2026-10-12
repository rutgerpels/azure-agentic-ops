#Requires -Version 7.2
<#
.SYNOPSIS
Repeat the supervised native SRE VM-start integration gate against an existing fixture.
.DESCRIPTION
Stops the owned fixture, requests a native SRE proposal and explicitly approves
only the exact command through Invoke-SreProof. The independent fault job must
observe recovery without intervening. Evidence remains in ignored .azure files.
This is automated authorization, not a human/customer rehearsal. Inspect the
saved hybrid evidence and Azure Activity Log identity separately before accepting
the wider demo gate. Leaves the fixture running; invoke Down to remove it.
.PARAMETER SubscriptionId
Authorized Azure subscription containing the existing native-action fixture.
.PARAMETER EnvironmentName
Existing fixture environment.
.PARAMETER Cycles
Number of consecutive attempts. A failed attempt stops the test.
.PARAMETER AutomatedApproval
Explicit acknowledgement that this test programmatically approves native actions.
.EXAMPLE
.\tests\Test-SreProof.Live.ps1 -SubscriptionId <guid> -AutomatedApproval
.OUTPUTS
Per-attempt thread ID, UTC times and measured recovery duration.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][guid]$SubscriptionId,
    [string]$EnvironmentName = 'demo02',
    [ValidateRange(1, 3)][int]$Cycles = 3,
    [switch]$AutomatedApproval
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $AutomatedApproval) { throw 'This live test requires explicit -AutomatedApproval.' }
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'scripts\Azure.Common.psm1') -Force
Assert-RetailEnvironmentName $EnvironmentName
$lifecycle = Join-Path $root 'scripts\Invoke-NativeAction.ps1'
$proof = Join-Path $root 'scripts\Invoke-SreProof.ps1'
$directory = Join-Path $root ".azure\$EnvironmentName"
$statePath = Join-Path $directory 'native-action-state.json'
$parameters = @{ SubscriptionId = $SubscriptionId; EnvironmentName = $EnvironmentName }
$runId = [DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
$results = @()
function Assert-ManualNativeRecovery {
    param([hashtable]$State, $Observed, $Status)
    if ($State.faultLifetime -cne 'Manual' -or $State.operatorRecovery -eq $true -or
        @($Observed.startExecutions | Where-Object status -CEQ 'Completed').Count -ne 1) {
        throw 'Operator fallback is not successful SRE recovery.'
    }
    if ($Status.powerState -cne 'PowerState/running') { throw 'Independent VM recovery check failed.' }
}
for ($cycle = 1; $cycle -le $Cycles; $cycle++) {
    $started = [DateTimeOffset]::UtcNow
    $null = & $lifecycle Fault @parameters
    $threadId = $null
    $approved = $false
    $verificationSent = $false
    try {
        $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
        if ($state.phase -cne 'fault-active' -or [DateTimeOffset]$state.faultStartedAt -lt $started) {
            throw 'Exact current manual fault was not observed.'
        }
        $proposed = & $proof Propose @parameters
        $threadId = $proposed.threadId
        do {
            if ([DateTimeOffset]::UtcNow -ge $started.AddMinutes(30)) {
                throw 'Bounded observation ended; manual fault still needs explicit Reset/Down.'
            }
            Start-Sleep -Seconds 10
            $observed = & $proof Read @parameters -ThreadId $threadId
            $pending = @($observed.executions | Where-Object status -In @('Pending', 'PendingAuthorization'))
            if (-not $approved -and $pending.Count -gt 0) {
                $null = & $proof Approve @parameters -ThreadId $threadId -AutomatedApproval
                $approved = $true
            }
            if (@($observed.startExecutions | Where-Object status -In @('Failed', 'Cancelled')).Count -gt 0) {
                throw 'Native execution failed or was cancelled.'
            }
            if ($approved -and -not $verificationSent -and $observed.state -ceq 'Idle' -and
                @($observed.startExecutions | Where-Object status -CEQ 'Completed').Count -eq 1) {
                $observed = & $proof Verify @parameters -ThreadId $threadId
                $verificationSent = $true
            }
        } until ($verificationSent -and $observed.state -ceq 'Idle' -and $observed.lastAgentMessageAt -and
            [DateTimeOffset]$observed.lastAgentMessageAt -gt [DateTimeOffset]$observed.verificationRequestedAt)
        $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
        $status = & $lifecycle Status @parameters
        Assert-ManualNativeRecovery -State $state -Observed $observed -Status $status
        $recoveryObservedAt = [DateTimeOffset]::UtcNow.ToString('o')
        $result = @{
            cycle = $cycle; threadId = $threadId; authorization = 'automated-not-human'
            faultStartedAt = $state.faultStartedAt; recoveryObservedAt = $recoveryObservedAt
            completedAt = [DateTimeOffset]::UtcNow.ToString('o')
            observedRecoverySeconds = ([DateTimeOffset]$recoveryObservedAt - [DateTimeOffset]$state.faultStartedAt).TotalSeconds
            totalSeconds = ([DateTimeOffset]::UtcNow - [DateTimeOffset]$state.faultStartedAt).TotalSeconds
            operatorRecovery = $false
        }
        if ($result.totalSeconds -gt 720) { throw 'Recovery and incident note exceeded the 12-minute target.' }
        $results += $result
        Save-RetailState @{ runId = $runId; results = $results } (Join-Path $directory "sre-rehearsal-$runId.json")
        [pscustomobject]$result
    } finally {
        $null = & $lifecycle Reset @parameters
    }
}
