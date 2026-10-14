#Requires -Version 7.5
<#
.SYNOPSIS
Run the retained native-VM presenter workflow without deploying or changing agents.
.DESCRIPTION
Uses a verified guidance snapshot and the original protected source manifest.
Bash and PowerShell share this engine. Ready/Status perform Azure reads only.
Fault requires presenter initiation; Reset is exact-run, never SRE approval.
.PARAMETER Operation
Configure a local profile, Ready, Fault, Status, or exact-run Reset.
.PARAMETER Profile
Local ignored profile; defaults to artifacts/presenter/guest-profile.json.
.PARAMETER GuidanceSnapshot
Configure only: the verified content-installation journal, not a new configuration.
.PARAMETER PresenterTriggered
Fault only: records deliberate presenter initiation, not a technical identity boundary.
.PARAMETER RunId
Reset only: exact run printed by Fault. Never inferred from an older incident.
.EXAMPLE
.\scripts\Invoke-GuestPresenter.ps1 Ready
.EXAMPLE
.\scripts\Invoke-GuestPresenter.ps1 Fault -PresenterTriggered
.OUTPUTS
JSON describing readiness, submission or current observed health; submission is not success.
.NOTES
No automatic retry, repair approval, VM start, agent stop, permission change or rebuild.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('Configure', 'Ready', 'Fault', 'Status', 'Reset')][string]$Operation,
    [string]$Profile,
    [string]$GuidanceSnapshot,
    [switch]$PresenterTriggered,
    [guid]$RunId
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $Profile) { $Profile = Join-Path $root 'artifacts\presenter\guest-profile.json' }
$Profile = [IO.Path]::GetFullPath($Profile)
if ($PresenterTriggered -and $Operation -cne 'Fault') { throw 'PresenterTriggered applies only to Fault.' }
if ($PSBoundParameters.ContainsKey('RunId') -and $Operation -cne 'Reset') { throw 'RunId applies only to Reset.' }
if ($GuidanceSnapshot -and $Operation -cne 'Configure') { throw 'GuidanceSnapshot applies only to Configure.' }
Import-Module (Join-Path $PSScriptRoot 'Azure.Common.psm1') -Force
. (Join-Path $PSScriptRoot 'disk\DiskSre.ps1')
. (Join-Path $PSScriptRoot 'guest\GuestMonitor.ps1')
. (Join-Path $PSScriptRoot 'guest\GuestRecoverySkill.ps1')
. (Join-Path $PSScriptRoot 'guest\GuestNativeRead.ps1')
. (Join-Path $PSScriptRoot 'guest\GuestPresenter.ps1')
function Invoke-Azure {
    param([string[]]$Arguments)
    Invoke-RetailAzure -SubscriptionId $script:subscription -Arguments $Arguments -TimeoutSeconds 120
}
if ($Operation -ceq 'Configure') {
    if (-not $GuidanceSnapshot -or (Test-Path -LiteralPath $Profile) -or
        (Test-Path -LiteralPath "$Profile.session.json")) {
        throw 'Configure needs a verified GuidanceSnapshot and a profile path that does not exist.'
    }
    $guidancePath = [IO.Path]::GetFullPath($GuidanceSnapshot)
    $guidance = Get-GuestPresenterJson $guidancePath
    if ($guidance.phase -cne 'InstalledAndReadbackVerified') { throw 'Guidance installation is not verified.' }
    $configuration = @{ schemaVersion = 1; scenario = 'guest-service'; guidancePath = $guidancePath
        guidanceSha256 = (Get-FileHash -LiteralPath $guidancePath).Hash
        journalPath = "$Profile.session.json" }
    Initialize-GuestPresenter $Profile -Configuration $configuration
    if (-not $PSCmdlet.ShouldProcess($Profile, 'Create a local presenter profile; no Azure mutation')) { return }
    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $Profile) -Force
    Save-RetailState $configuration $Profile
    @{ phase = 'ProfileConfiguredNotReady'; next = 'Run Ready before presentation.' } | ConvertTo-Json
    return
}
Initialize-GuestPresenter $Profile
$leasePath = Join-Path (Split-Path -Parent $script:presenterStatePath) 'guest-service.lock'
$lease = [IO.File]::Open($leasePath, 'OpenOrCreate', 'ReadWrite', 'None')
try {
    Initialize-GuestPresenter $Profile
    $common = @{}
    foreach ($key in @('WhatIf', 'Confirm')) {
        if ($PSBoundParameters.ContainsKey($key)) { $common[$key] = $PSBoundParameters[$key] }
    }
    $result = switch ($Operation) {
        Ready { Test-GuestPresenterReady }
        Fault { Invoke-GuestPresenterFault -PresenterTriggered:$PresenterTriggered @common }
        Status {
            $null = Assert-GuestPresenterConfiguration
            $receipt = Update-GuestPresenterStatus
            $incident = Get-GuestMonitorIncident
            @{ phase = 'ObservationNotSreConclusion'; runId = $receipt.marker.runId
                active = $receipt.active; healthy = $receipt.healthy; observedAtUtc = $receipt.observedAtUtc
                markerPhase = $receipt.marker.phase; monitorCondition = $incident.monitorCondition
                threadId = $incident.threadId; pendingPresenterCommand = [bool]$script:state.pendingCommand
                pendingNativeDiagnostic = [bool]($script:state['nativeRead'] -and
                    $script:state.nativeRead.phase -cne 'ResultReceived') }
        }
        Reset {
            if (-not $PSBoundParameters.ContainsKey('RunId')) { throw 'Reset requires -RunId.' }
            Invoke-GuestPresenterReset -RunId $RunId @common
        }
    }
    if ($result) { $result | ConvertTo-Json -Depth 10 }
} finally { $lease.Dispose() }
