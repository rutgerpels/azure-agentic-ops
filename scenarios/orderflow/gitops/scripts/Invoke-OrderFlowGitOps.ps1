#Requires -Version 7.2
<#
.SYNOPSIS
Presenter lifecycle for OrderFlow option 2 (GitOps): shared/prod/test stages, CI/CD, fault PRs and SRE triage.
.DESCRIPTION
Up provisions owned resource groups and deploys the same templates and parameters as the
workflows; setup stops healthy. Only Fault introduces the demo fault, as a pull request to main
that a human merges. Reset opens a PR restoring the baseline. Nothing here pushes to main,
merges PRs or grants the SRE Agent Azure write rights. Unknown outcomes are observed by Status,
never replayed.
.PARAMETER Action
Up, ConfigureGitHub, ConfigureSre, Ready, Fault, Status, Reset or Down.
.PARAMETER EnvironmentName
Lowercase 3-12 character environment name; owns .azure\orderflow-gitops\<name>\.
.PARAMETER SubscriptionId
Explicit target subscription; every Azure CLI call is scoped to it.
.PARAMETER PresenterCidr
Narrow IPv4 CIDR (/24-/32) allowed to reach the portal (Up only).
.PARAMETER AdminObjectId
Entra object ID granted SRE Agent administration (Up only).
.PARAMETER GitHubRepository
owner/repo; defaults to the github.com origin remote (Up only).
.PARAMETER SreIssueTools
Exact GitHub issue tool names exposed by the SRE Agent's GitHub connector (ConfigureSre).
.PARAMETER SreAssignTool
Exact Copilot-assign tool name exposed by the SRE Agent's GitHub connector (ConfigureSre).
.EXAMPLE
./Invoke-OrderFlowGitOps.ps1 -Action Up -EnvironmentName demo1 -SubscriptionId <guid> -PresenterCidr 203.0.113.10/32 -AdminObjectId <guid>
.EXAMPLE
./Invoke-OrderFlowGitOps.ps1 -Action Fault -EnvironmentName demo1 -SubscriptionId <guid>
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Up', 'ConfigureGitHub', 'ConfigureSre', 'Ready', 'Fault', 'Status', 'Reset', 'Down')]
    [string]$Action,

    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z][a-z0-9]{2,11}$')]
    [string]$EnvironmentName,

    [Parameter(Mandatory)]
    [guid]$SubscriptionId,

    [ValidatePattern('^[a-z0-9]{3,30}$')]
    [string]$Location = 'eastus2',

    [ValidatePattern('^[a-z0-9]{3,30}$')]
    [string]$SreLocation,

    [string]$PresenterCidr,

    [guid]$AdminObjectId,

    [ValidateSet('User', 'ServicePrincipal')]
    [string]$AdminPrincipalType = 'User',

    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9._-]{1,100}$')]
    [string]$GitHubRepository,

    [ValidateCount(1, 10)]
    [string[]]$SreIssueTools,

    [string]$SreAssignTool,

    [ValidateRange(60, 1800)]
    [int]$SmokeTimeoutSeconds = 420
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'OrderFlowGitOps.psm1') -Force
. (Join-Path $PSScriptRoot 'OrderFlowGitOps.Sre.ps1')

$stateDirectory = Get-OrderFlowGitOpsStateDirectory $EnvironmentName
$statePath = Join-Path $stateDirectory 'ownership.json'

function Write-Step {
    param([string]$Message)
    Write-Information "[orderflow-gitops/$EnvironmentName] $Message" -InformationAction Continue
}

function Assert-AccountSubscription {
    $account = Invoke-RetailAzure -SubscriptionId $SubscriptionId -Arguments @('account', 'show')
    if (-not $account -or $account.id -ine $SubscriptionId.ToString()) {
        throw 'Azure CLI cannot resolve the requested subscription. Run az login and retry.'
    }
}

function Assert-LocalBaseline {
    $root = Get-OrderFlowGitOpsPath 'Root'
    $current = Get-Content -LiteralPath (Join-Path $root (Get-OrderFlowGitOpsPath 'Rules')) -Raw
    $baseline = Get-Content -LiteralPath (Join-Path $root (Get-OrderFlowGitOpsPath 'Baseline')) -Raw
    if (-not (Test-OrderFlowGitOpsRuleSetEqual $current $baseline)) {
        throw 'Local deploy/network-rules.json differs from the baseline. Setup must stop healthy; restore the baseline first.'
    }
}

function Assert-SreForFault {
    param([hashtable]$State)
    if ($State.sre.attempted) {
        Assert-OrderFlowGitOpsSre $State
        Write-Step 'SRE Agent configuration verified (Review mode, issue/assign tools Ask, Azure writes denied).'
    } else {
        Write-Warning ('ConfigureSre has not been run: continuing as a CI/CD-only rehearsal. ' +
            'No SRE Agent will investigate or file an issue for this fault.')
    }
}

function Invoke-Up {
    if (-not $PresenterCidr) { throw 'Up requires -PresenterCidr (prefer your public IP /32).' }
    if (-not $AdminObjectId -or $AdminObjectId -eq [guid]::Empty) { throw 'Up requires -AdminObjectId.' }
    Assert-OrderFlowGitOpsCidr $PresenterCidr
    $repository = if ($GitHubRepository) { $GitHubRepository } else {
        ConvertTo-OrderFlowGitOpsRepository (Invoke-OrderFlowGitOpsGit @('remote', 'get-url', 'origin')).Trim()
    }
    Assert-OrderFlowGitOpsRepository $repository
    Assert-LocalBaseline
    Assert-AccountSubscription
    $effectiveSreLocation = if ($SreLocation) { $SreLocation } else { $Location }

    if (Test-Path -LiteralPath $statePath) {
        $state = Read-OrderFlowGitOpsState $statePath $SubscriptionId $EnvironmentName
        Assert-OrderFlowGitOpsAction $state 'Up'
        if ($state.location -cne $Location -or $state.presenterCidr -cne $PresenterCidr -or
            $state.gitHubRepository -cne $repository -or $state.adminObjectId -ine $AdminObjectId.ToString()) {
            throw 'Up parameters differ from the owned manifest. Use the original values or a new EnvironmentName.'
        }
        Write-Step "Resuming owned environment (phase $($state.phase))."
    } else {
        $state = New-OrderFlowGitOpsState -SubscriptionId $SubscriptionId -EnvironmentName $EnvironmentName -Location $Location `
            -SreLocation $effectiveSreLocation -PresenterCidr $PresenterCidr -AdminObjectId $AdminObjectId `
            -AdminPrincipalType $AdminPrincipalType -GitHubRepository $repository
        Assert-OrderFlowGitOpsGroupAbsent $state
        if (-not $PSCmdlet.ShouldProcess("$($state.resourceGroups.Values -join ', ')", 'Create OrderFlow GitOps environment')) { return }
        Save-OrderFlowGitOpsState $state $statePath 'manifest created'
        Write-Step "Ownership manifest written: $statePath"
    }
    if ($state.phase -ceq 'provisioned') { Write-Step 'Already provisioned; re-running smoke checks.' }
    elseif (-not $PSCmdlet.ShouldProcess("$($state.resourceGroups.Values -join ', ')", 'Provision OrderFlow GitOps environment')) { return }

    foreach ($stage in @('shared', 'prod', 'test')) { New-OrderFlowGitOpsGroup $state $statePath $stage }
    if (-not $state.stages['deploy-shared']) {
        Write-Step 'Deploying shared stage (registry, Cosmos DB, identities, SRE Agent).'
        Invoke-OrderFlowGitOpsDeployment $state $statePath 'shared'
    }
    $sharedTemplate = Get-Content -LiteralPath (Join-Path (Get-OrderFlowGitOpsPath 'Infra') 'shared.bicep') -Raw
    if ($sharedTemplate -notmatch "module\s+\w+\s+'sre\.bicep'" -and -not $state.stages['deploy-sre']) {
        Invoke-OrderFlowGitOpsDeployment $state $statePath 'sre'
    }
    if (-not $state.imageTag -or -not $state.stages['image']) {
        $state.imageTag = Get-OrderFlowGitOpsImageTag
        $state.deploySha = (Invoke-OrderFlowGitOpsGit @('rev-parse', 'HEAD')).Trim()
        Save-OrderFlowGitOpsState $state $statePath 'image tag computed'
        Write-Step "Building image orderflow:$($state.imageTag) with ACR Tasks."
        Invoke-OrderFlowGitOpsImageBuild $state $statePath
    }
    foreach ($stage in @('test', 'prod')) {
        if (-not $state.stages["deploy-$stage"]) {
            Write-Step "Deploying $stage stage from deploy/$stage.bicepparam."
            Invoke-OrderFlowGitOpsDeployment $state $statePath $stage
        }
    }
    foreach ($stage in @('test', 'prod')) {
        $result = Start-OrderFlowGitOpsSmoke $state $stage -TimeoutSeconds $SmokeTimeoutSeconds
        $state.smoke[$stage] = $result
        Save-OrderFlowGitOpsState $state $statePath "smoke $stage $($result.status)"
        if (-not $result.succeeded) { throw "$stage smoke job is $($result.status); setup did not stop healthy. Inspect, then run Up again." }
    }
    $state.phase = 'provisioned'
    Save-OrderFlowGitOpsState $state $statePath 'provisioned'
    Write-Step "Healthy. Portal: $(Get-OrderFlowGitOpsOutput $state 'prod' 'portalUrl' -Optional)"
    Write-Step 'Next: ConfigureGitHub, then (optionally) ConfigureSre, then Ready.'
    Get-OrderFlowGitOpsGitHubVariable $state
}

function Invoke-ConfigureGitHub {
    param([hashtable]$State)
    $variables = Get-OrderFlowGitOpsGitHubVariable $State
    if (-not $PSCmdlet.ShouldProcess($State.gitHubRepository, 'Create/update GitHub environments orderflow-prod and orderflow-test, variables, branch policies and labels')) {
        return $variables
    }
    Set-OrderFlowGitOpsGitHub $State
    $State.stages['github'] = $true
    Save-OrderFlowGitOpsState $State $statePath 'github configured'
    Write-Step 'GitHub environments, variables, branch policies and labels configured. Leave orderflow-prod without required reviewers; PR review is the production gate.'
    $variables
}

function Invoke-ConfigureSre {
    param([hashtable]$State)
    if (-not $SreIssueTools -or -not $SreAssignTool) {
        throw 'ConfigureSre requires -SreIssueTools and -SreAssignTool (exact tool names from the SRE Agent GitHub connector).'
    }
    Assert-OrderFlowGitOpsSreTool $SreIssueTools $SreAssignTool
    if (-not $PSCmdlet.ShouldProcess((Get-OrderFlowGitOpsOutput $State 'sre' 'agentId'), 'Configure OrderFlow GitOps SRE investigator, approval policy and response plan')) { return }
    Set-OrderFlowGitOpsSre $State $statePath $SreIssueTools $SreAssignTool
    Write-Step 'SRE Agent configured and verified.'
}

function Invoke-Ready {
    param([hashtable]$State)
    if ($State.sre.attempted) { Assert-OrderFlowGitOpsSre $State }
    else { Write-Warning 'ConfigureSre not run: Ready covers the CI/CD path only.' }
    $result = Test-OrderFlowGitOpsReady $State -SmokeTimeoutSeconds $SmokeTimeoutSeconds
    $State.ready = @{
        ready = $result.ready; reasons = @($result.reasons); mainCommit = $result.mainCommit
        sreVerified = [bool]$State.sre.attempted; observedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    }
    $State.smoke = $result.smoke
    Save-OrderFlowGitOpsState $State $statePath "ready $($result.ready)"
    if (-not $result.ready) { throw "Not ready: $($result.reasons -join '; ')" }
    Write-Step "Ready at origin/main $($result.mainCommit.Substring(0, 12)). Fault may be opened."
    $State.ready
}

function Invoke-Fault {
    param([hashtable]$State)
    if (-not $State['ready'] -or -not $State.ready.ready) { throw 'Run Ready successfully before Fault.' }
    Assert-SreForFault $State
    $ready = Test-OrderFlowGitOpsReady $State -SmokeTimeoutSeconds $SmokeTimeoutSeconds
    if (-not $ready.ready) { throw "Not ready for fault: $($ready.reasons -join '; ')" }
    $source = Get-OrderFlowGitOpsFaultSource $ready.mainCommit
    if (-not $source.changed) { throw 'origin/main already contains the fault; refusing to open another fault PR.' }
    if (-not $PSCmdlet.ShouldProcess($State.gitHubRepository, "Open fault PR '$($source.fault.title)' against main (never merged by this script)")) { return }
    $subject = $source.fault.title.Substring(0, 1).ToLowerInvariant() + $source.fault.title.Substring(1)
    $message = "chore(orderflow-gitops): $subject`n`nPredefined OrderFlow GitOps demo fault opened by the presenter lifecycle."
    $commit = New-OrderFlowGitOpsCommit $ready.mainCommit $source.content $message
    $record = Publish-OrderFlowGitOpsChange $State $statePath 'fault' $commit $source.fault.title $source.fault.body $source.fault.label
    $State.ready = $null
    Save-OrderFlowGitOpsState $State $statePath 'fault opened'
    Write-Step "Fault PR opened: $($record.prUrl). Review and merge it yourself to start the demo."
    $record
}

function Invoke-Reset {
    param([hashtable]$State)
    $preview = Invoke-OrderFlowGitOpsReset $State $statePath -Preview
    if ($preview.result -cne 'Preview') { Write-Step $preview.message; return $preview }
    if (-not $PSCmdlet.ShouldProcess($State.gitHubRepository, 'Open reset PR restoring baseline network rules (never merged by this script)')) { return $preview }
    $result = Invoke-OrderFlowGitOpsReset $State $statePath
    Write-Step $result.message
    $result
}

function Invoke-Status {
    if (-not (Test-Path -LiteralPath $statePath)) { Write-Step 'No owned environment.'; return }
    $state = Read-OrderFlowGitOpsState $statePath $SubscriptionId $EnvironmentName
    $report = [ordered]@{ environment = $EnvironmentName; phase = $state.phase; resourceGroups = $state.resourceGroups }
    if ($state.pendingOperation) {
        $report.pending = $state.pendingOperation.name
        $report.observation = if ($state.pendingOperation.name -ceq 'sre-config') {
            Complete-OrderFlowGitOpsSreObservation $state $statePath
            'SRE configuration stage observed. Run ConfigureSre to finish verification.'
        } else { Resolve-OrderFlowGitOpsPending $state $statePath }
    }
    if ($state.phase -cin @('provisioned', 'creating')) {
        foreach ($stage in @('test', 'prod')) {
            try { $report["smoke-$stage"] = Get-OrderFlowGitOpsLatestSmoke $state $stage } catch { $report["smoke-$stage"] = "unavailable: $($_.Exception.Message)" }
        }
    }
    $repository = $state.gitHubRepository
    try {
        $report.cdRuns = Invoke-OrderFlowGitOpsGh @('run', 'list', '--repo', $repository, '--workflow', 'orderflow-gitops-cd.yml',
            '--limit', '5', '--json', 'databaseId,status,conclusion,headSha,event,createdAt,url') -Json
        $report.faultPrs = Get-OrderFlowGitOpsPullRequest $state -Label 'orderflow-fault'
        $report.resetPrs = Get-OrderFlowGitOpsPullRequest $state -Label 'orderflow-reset'
        $report.copilotPrs = @((Get-OrderFlowGitOpsPullRequest $state) | Where-Object { $_.headRefName -clike 'copilot/*' })
        $report.incidents = Invoke-OrderFlowGitOpsGh @('issue', 'list', '--repo', $repository, '--label', 'orderflow-incident',
            '--state', 'open', '--json', 'number,title,url,assignees,createdAt') -Json
    } catch { $report.github = "unavailable: $($_.Exception.Message)" }
    $report.sre = @{ attempted = [bool]$state.sre.attempted; configured = [bool]$state.sre.configured }
    $report.ready = $state.ready
    [pscustomobject]$report
}

function Invoke-Down {
    if (-not (Test-Path -LiteralPath $statePath)) { throw 'No ownership manifest; refusing to delete anything not provably owned.' }
    $state = Read-OrderFlowGitOpsState $statePath $SubscriptionId $EnvironmentName
    Assert-OrderFlowGitOpsAction $state 'Down'
    if (-not $PSCmdlet.ShouldProcess("$($state.resourceGroups.Values -join ', ')", 'Delete owned OrderFlow GitOps resource groups (prod/test, then shared)')) { return }
    Invoke-OrderFlowGitOpsDown $state $statePath
    Write-Step 'All owned resource groups observed absent. GitHub environments, variables and labels are left for manual removal.'
}

$lock = Enter-OrderFlowGitOpsLock $stateDirectory
try {
    if ($Action -cne 'Status') { Assert-AccountSubscription }
    switch ($Action) {
        'Up' { Invoke-Up }
        'Status' { Invoke-Status }
        'Down' { Invoke-Down }
        default {
            $state = Read-OrderFlowGitOpsState $statePath $SubscriptionId $EnvironmentName
            Assert-OrderFlowGitOpsAction $state $Action
            switch ($Action) {
                'ConfigureGitHub' { Invoke-ConfigureGitHub $state }
                'ConfigureSre' { Invoke-ConfigureSre $state }
                'Ready' { Invoke-Ready $state }
                'Fault' { Invoke-Fault $state }
                'Reset' { Invoke-Reset $state }
            }
        }
    }
} finally {
    $lock.Dispose()
}
