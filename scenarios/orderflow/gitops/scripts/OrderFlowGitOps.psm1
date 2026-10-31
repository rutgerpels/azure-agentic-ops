#Requires -Version 7.2
<#
.SYNOPSIS
Helpers for the OrderFlow option-2 (GitOps) presenter lifecycle.
.DESCRIPTION
External boundaries (az, gh, git, python, REST) are wrapped by small functions so
offline tests can replace them inside this module scope. Mutations persist a
pending operation before they start; unknown outcomes are observed, never replayed.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:gitOpsRoot = Split-Path -Parent $PSScriptRoot
$script:repositoryRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $script:gitOpsRoot))
Import-Module (Join-Path $script:repositoryRoot 'scripts\Azure.Common.psm1') -Force

$script:rulesPath = 'scenarios/orderflow/gitops/deploy/network-rules.json'
$script:baselinePath = 'scenarios/orderflow/gitops/deploy/baseline/network-rules.json'
$script:labels = [ordered]@{
    'orderflow-fault' = @{ color = 'B60205'; description = 'Predefined OrderFlow demo fault PR (presenter merges)' }
    'orderflow-incident' = @{ color = 'D93F0B'; description = 'OrderFlow incident analysed by Azure SRE Agent' }
    'orderflow-test-deploy' = @{ color = '0E8A16'; description = 'Allow OrderFlow test-environment deployment for this PR' }
    'orderflow-reset' = @{ color = '1D76DB'; description = 'Restore the OrderFlow baseline network rules' }
}

#region Paths, names and validation

function Get-OrderFlowGitOpsPath {
    <#
    .SYNOPSIS
    Return well-known paths for the GitOps scenario.
    #>
    param([Parameter(Mandatory)][ValidateSet('Root', 'GitOps', 'Rules', 'Baseline', 'Runbook', 'Infra', 'Deploy', 'Tools', 'Fault')][string]$Name)
    switch ($Name) {
        'Root' { $script:repositoryRoot }
        'GitOps' { $script:gitOpsRoot }
        'Rules' { $script:rulesPath }
        'Baseline' { $script:baselinePath }
        'Runbook' { Join-Path $script:gitOpsRoot 'docs\runbook.md' }
        'Infra' { Join-Path $script:gitOpsRoot 'infra' }
        'Deploy' { Join-Path $script:gitOpsRoot 'deploy' }
        'Tools' { Join-Path $script:gitOpsRoot 'tools' }
        'Fault' { Join-Path $script:gitOpsRoot 'faults\egress-lockdown.json' }
    }
}

function Get-OrderFlowGitOpsGroupName {
    <#
    .SYNOPSIS
    Return the deterministic resource group names for one environment.
    #>
    param([Parameter(Mandatory)][string]$EnvironmentName)
    Assert-RetailEnvironmentName $EnvironmentName
    [ordered]@{
        shared = "rg-ofgitops-$EnvironmentName-shared"
        prod = "rg-ofgitops-$EnvironmentName-prod"
        test = "rg-ofgitops-$EnvironmentName-test"
    }
}

function Assert-OrderFlowGitOpsCidr {
    <#
    .SYNOPSIS
    Accept only a narrow presenter IPv4 CIDR (/24 through /32).
    #>
    param([string]$Cidr)
    if ($Cidr -notmatch '^(\d{1,3}\.){3}\d{1,3}/(\d{1,2})$') { throw 'PresenterCidr must be an IPv4 CIDR.' }
    $parts = $Cidr.Split('/')
    $address = $null
    if (-not [Net.IPAddress]::TryParse($parts[0], [ref]$address) -or
        $address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or
        $address.ToString() -cne $parts[0] -or [int]$parts[1] -lt 24 -or [int]$parts[1] -gt 32) {
        throw 'PresenterCidr must be a narrow IPv4 range (/24 through /32); prefer /32. Never 0.0.0.0/0.'
    }
}

function Assert-OrderFlowGitOpsRepository {
    <#
    .SYNOPSIS
    Validate an owner/repo GitHub repository identifier.
    #>
    param([string]$Repository)
    if ($Repository -cnotmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9._-]{1,100}$' -or $Repository.EndsWith('.git')) {
        throw 'GitHubRepository must be owner/repo.'
    }
}

function ConvertTo-OrderFlowGitOpsRepository {
    <#
    .SYNOPSIS
    Derive owner/repo from a github.com remote URL; credentials in URLs are refused.
    #>
    param([Parameter(Mandatory)][string]$RemoteUrl)
    if ($RemoteUrl -match '^https://github\.com/([^/@\s]+/[^/@\s]+?)(?:\.git)?/?$' -or
        $RemoteUrl -match '^git@github\.com:([^/\s]+/[^/\s]+?)(?:\.git)?$' -or
        $RemoteUrl -match '^ssh://git@github\.com/([^/\s]+/[^/\s]+?)(?:\.git)?$') {
        $repository = $Matches[1]
        Assert-OrderFlowGitOpsRepository $repository
        return $repository
    }
    throw 'origin is not a credential-free github.com remote; pass -GitHubRepository and use a github.com origin.'
}

function New-OrderFlowGitOpsToken {
    <#
    .SYNOPSIS
    Return an 8-character lowercase hex token for short-lived branch names.
    #>
    [guid]::NewGuid().ToString('N').Substring(0, 8)
}

#endregion

#region Process boundaries

function Invoke-OrderFlowGitOpsProcess {
    <#
    .SYNOPSIS
    Run a native executable with an argument array, optional stdin and a deadline.
    .DESCRIPTION
    Returns trimmed stdout. Fails on nonzero exit with the operation name and a
    credential-redacted stderr excerpt; never echoes arguments.
    #>
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [string]$InputText,
        [hashtable]$Environment,
        [string]$WorkingDirectory = $script:repositoryRoot,
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 120
    )
    $executable = (Get-Command $FilePath -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $startInfo = [Diagnostics.ProcessStartInfo]::new($executable)
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    foreach ($argument in $Arguments) { $startInfo.ArgumentList.Add($argument) }
    if ($Environment) { foreach ($key in $Environment.Keys) { $startInfo.Environment[$key] = [string]$Environment[$key] } }
    $startInfo.Environment['GH_PROMPT_DISABLED'] = '1'
    $startInfo.Environment['GIT_TERMINAL_PROMPT'] = '0'
    $operation = "$([IO.Path]::GetFileNameWithoutExtension($executable)) $($Arguments[0..([Math]::Min(1, $Arguments.Count - 1))] -join ' ')"
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        $null = $process.Start()
        if ($InputText) {
            $writer = [IO.StreamWriter]::new($process.StandardInput.BaseStream, [Text.UTF8Encoding]::new($false))
            $writer.Write($InputText)
            $writer.Flush()
        }
        $process.StandardInput.Close()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            throw [TimeoutException]::new("$operation timed out after $TimeoutSeconds seconds; its outcome is unknown.")
        }
        $process.WaitForExit()
        $output = $stdout.GetAwaiter().GetResult()
        $errorText = $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            $excerpt = ($errorText -replace '(?i)(https?://)[^@\s/]+@', '$1***@' -replace '(gh[pousr]_|github_pat_)[A-Za-z0-9_]+', '***').Trim()
            if ($excerpt.Length -gt 400) { $excerpt = $excerpt.Substring(0, 400) }
            throw "$operation failed with exit code $($process.ExitCode). $excerpt"
        }
        return $output.TrimEnd()
    } finally { $process.Dispose() }
}

function Invoke-OrderFlowGitOpsAzure {
    <#
    .SYNOPSIS
    Run Azure CLI for the manifest's explicit subscription and return parsed JSON.
    .PARAMETER Environment
    Optional process environment variables (bicepparam readEnvironmentVariable inputs).
    #>
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][string[]]$Arguments,
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 120, [hashtable]$Environment)
    $saved = @{}
    if ($Environment) {
        foreach ($key in $Environment.Keys) {
            $saved[$key] = [Environment]::GetEnvironmentVariable($key)
            [Environment]::SetEnvironmentVariable($key, [string]$Environment[$key])
        }
    }
    try {
        Invoke-RetailAzure -SubscriptionId $State.subscriptionId -Arguments $Arguments -TimeoutSeconds $TimeoutSeconds
    } finally {
        foreach ($key in $saved.Keys) { [Environment]::SetEnvironmentVariable($key, $saved[$key]) }
    }
}

function Invoke-OrderFlowGitOpsGh {
    <#
    .SYNOPSIS
    Run GitHub CLI with an argument array; optionally parse JSON output.
    #>
    param([Parameter(Mandatory)][string[]]$Arguments, [switch]$Json, [string]$InputText,
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 60)
    $output = Invoke-OrderFlowGitOpsProcess -FilePath 'gh' -Arguments $Arguments -InputText $InputText -TimeoutSeconds $TimeoutSeconds
    if ($Json) {
        if (-not $output) { return $null }
        return ($output | ConvertFrom-Json -AsHashtable -NoEnumerate)
    }
    $output
}

function Invoke-OrderFlowGitOpsGit {
    <#
    .SYNOPSIS
    Run git in the repository root without touching the user's working tree.
    #>
    param([Parameter(Mandatory)][string[]]$Arguments, [string]$InputText, [hashtable]$Environment,
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 120)
    Invoke-OrderFlowGitOpsProcess -FilePath 'git' -Arguments (@('--no-pager') + $Arguments) -InputText $InputText `
        -Environment $Environment -TimeoutSeconds $TimeoutSeconds
}

function Invoke-OrderFlowGitOpsPython {
    <#
    .SYNOPSIS
    Run an offline scenario tool with Python.
    #>
    param([Parameter(Mandatory)][string[]]$Arguments)
    $python = if (Get-Command python -CommandType Application -ErrorAction SilentlyContinue) { 'python' } else { 'python3' }
    Invoke-OrderFlowGitOpsProcess -FilePath $python -Arguments $Arguments -TimeoutSeconds 60
}

function Invoke-OrderFlowGitOpsRequest {
    <#
    .SYNOPSIS
    Authenticated ARM or SRE data-plane request against validated endpoints only.
    #>
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][string]$Uri,
        [ValidateSet('https://management.azure.com/', 'https://azuresre.dev')][string]$Audience = 'https://management.azure.com/',
        [ValidateSet('GET', 'PUT', 'DELETE')][string]$Method = 'GET',
        [hashtable]$Body, [switch]$AllowMissing, [switch]$Raw, [string]$IfMatch)
    $target = [uri]$Uri
    if ($target.Scheme -cne 'https' -or $target.UserInfo -or -not $target.IsDefaultPort -or
        ($Audience -ceq 'https://management.azure.com/' -and $target.Host -cne 'management.azure.com') -or
        ($Audience -ceq 'https://azuresre.dev' -and -not $target.Host.EndsWith('.azuresre.ai'))) {
        throw 'Unexpected authenticated endpoint.'
    }
    $credential = Invoke-OrderFlowGitOpsAzure $State @('account', 'get-access-token', '--resource', $Audience)
    $request = @{
        Uri = $Uri; Method = $Method; Authentication = 'Bearer'
        Token = ConvertTo-SecureString $credential.accessToken -AsPlainText -Force
        MaximumRedirection = 0; TimeoutSec = 60; SkipHttpErrorCheck = $true
    }
    $credential = $null
    if ($Body) { $request.Body = $Body | ConvertTo-Json -Depth 30 -Compress; $request.ContentType = 'application/json' }
    if ($IfMatch) { $request.Headers = @{ 'If-Match' = $IfMatch } }
    try { $response = Invoke-WebRequest @request } finally { $request.Token = $null }
    if ($AllowMissing -and $response.StatusCode -eq 404) { return $null }
    if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 300) {
        throw "$Method request failed with HTTP $($response.StatusCode). No mutation was retried."
    }
    if ($Raw) { return $response }
    if ($response.Content) { return $response.Content | ConvertFrom-Json -AsHashtable }
}

#endregion

#region Ownership manifest, lock and journal

function Enter-OrderFlowGitOpsLock {
    <#
    .SYNOPSIS
    Acquire an exclusive per-environment lock; the caller disposes the handle.
    #>
    param([Parameter(Mandatory)][string]$Directory)
    $null = New-Item -ItemType Directory -Force -Path $Directory
    try {
        return [IO.File]::Open((Join-Path $Directory 'operation.lock'), [IO.FileMode]::OpenOrCreate,
            [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    } catch [IO.IOException] {
        throw 'Another OrderFlow GitOps lifecycle process holds this environment lock. Wait; do not remove its lock file.'
    }
}

function Get-OrderFlowGitOpsStateDirectory {
    <#
    .SYNOPSIS
    Return repository-root .azure\orderflow-gitops\<env>.
    #>
    param([Parameter(Mandatory)][string]$EnvironmentName)
    Assert-RetailEnvironmentName $EnvironmentName
    Join-Path $script:repositoryRoot ".azure\orderflow-gitops\$EnvironmentName"
}

function New-OrderFlowGitOpsState {
    <#
    .SYNOPSIS
    Build a new non-secret ownership manifest (not yet persisted).
    #>
    param([Parameter(Mandatory)][guid]$SubscriptionId, [Parameter(Mandatory)][string]$EnvironmentName,
        [Parameter(Mandatory)][string]$Location, [string]$SreLocation, [Parameter(Mandatory)][string]$PresenterCidr,
        [Parameter(Mandatory)][guid]$AdminObjectId, [string]$AdminPrincipalType = 'User',
        [Parameter(Mandatory)][string]$GitHubRepository)
    Assert-OrderFlowGitOpsCidr $PresenterCidr
    Assert-OrderFlowGitOpsRepository $GitHubRepository
    if ($AdminObjectId -eq [guid]::Empty) { throw 'AdminObjectId is required.' }
    @{
        schemaVersion = 1; scenario = 'orderflow-gitops'; managedBy = 'invoke-orderflow-gitops'
        subscriptionId = $SubscriptionId.ToString(); environmentName = $EnvironmentName
        ownerToken = [guid]::NewGuid().ToString(); location = $Location; sreLocation = $SreLocation
        presenterCidr = $PresenterCidr; adminObjectId = $AdminObjectId.ToString(); adminPrincipalType = $AdminPrincipalType
        gitHubRepository = $GitHubRepository; resourceGroups = (Get-OrderFlowGitOpsGroupName $EnvironmentName)
        createdGroups = @(); stages = @{}; outputs = @{ shared = @{}; sre = @{}; prod = @{}; test = @{} }
        createdAtUtc = [DateTimeOffset]::UtcNow.ToString('o'); phase = 'creating'
        pendingOperation = $null; smoke = @{}; sre = @{ attempted = $false; configured = $false }
        ready = $null; faults = @(); resets = @(); imageTag = $null; deploySha = $null
    }
}

function Save-OrderFlowGitOpsState {
    <#
    .SYNOPSIS
    Atomically persist the manifest and append a non-secret journal event.
    #>
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][string]$Path, [string]$JournalEvent = 'save')
    $directory = Split-Path -Parent $Path
    $null = New-Item -ItemType Directory -Force -Path $directory
    Save-RetailState -State $State -Path $Path
    $entry = [ordered]@{
        atUtc = [DateTimeOffset]::UtcNow.ToString('o'); phase = $State.phase
        pending = $(if ($State.pendingOperation) { $State.pendingOperation.name } else { $null })
        event = $JournalEvent
    }
    Add-Content -LiteralPath (Join-Path $directory 'journal.jsonl') -Value ($entry | ConvertTo-Json -Compress) -Encoding utf8NoBOM
}

function Read-OrderFlowGitOpsState {
    <#
    .SYNOPSIS
    Load and validate an ownership manifest for the exact subscription and environment.
    #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][guid]$SubscriptionId,
        [Parameter(Mandatory)][string]$EnvironmentName)
    if (-not (Test-Path -LiteralPath $Path)) { throw 'No owned OrderFlow GitOps environment. Run Up first.' }
    $state = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
    Assert-OrderFlowGitOpsState $state $SubscriptionId $EnvironmentName
    $state
}

function Assert-OrderFlowGitOpsState {
    <#
    .SYNOPSIS
    Refuse a manifest that does not belong to this subscription/environment or points outside owned groups.
    #>
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][guid]$SubscriptionId,
        [Parameter(Mandatory)][string]$EnvironmentName)
    $groups = Get-OrderFlowGitOpsGroupName $EnvironmentName
    if ($State.schemaVersion -ne 1 -or $State.scenario -cne 'orderflow-gitops' -or
        $State.subscriptionId -ine $SubscriptionId.ToString() -or $State.environmentName -cne $EnvironmentName -or
        -not ($State.ownerToken -as [guid]) -or -not $State.resourceGroups -or
        $State.resourceGroups.shared -cne $groups.shared -or $State.resourceGroups.prod -cne $groups.prod -or
        $State.resourceGroups.test -cne $groups.test) {
        throw 'Invalid or mismatched OrderFlow GitOps ownership manifest.'
    }
    foreach ($group in @($State.createdGroups)) {
        if ($group -cnotin @($groups.Values)) { throw 'Manifest lists a resource group outside this environment.' }
    }
    $prefixes = @($groups.Values | ForEach-Object { "/subscriptions/$SubscriptionId/resourceGroups/$_/" })
    foreach ($stage in @($State.outputs.Keys)) {
        foreach ($entry in @($State.outputs[$stage].GetEnumerator())) {
            $value = [string]$entry.Value
            if ($value.StartsWith('/subscriptions/', [StringComparison]::OrdinalIgnoreCase) -and
                -not @($prefixes | Where-Object { $value.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) }).Count) {
                throw "Output $stage.$($entry.Key) is outside the owned resource groups."
            }
        }
    }
}

function Assert-OrderFlowGitOpsAction {
    <#
    .SYNOPSIS
    Gate actions on phase and on unresolved (unknown-outcome) operations.
    #>
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][string]$Action)
    if ($State.phase -ceq 'removed') { throw 'This environment generation is removed. Use a new EnvironmentName.' }
    if ($State.pendingOperation) {
        if ($Action -ceq 'Status') { return }
        if ($Action -ceq 'Down' -and $State.pendingOperation.name -clike 'delete-*') { return }
        throw "Pending/unknown operation '$($State.pendingOperation.name)'. Run Status to observe it; no automatic replay."
    }
    if ($State.phase -ceq 'deployment-failed' -and $Action -cnotin @('Status', 'Down')) {
        throw 'Terminal deployment failure: Status and Down only. Provisioning is never replayed.'
    }
    if ($Action -cin @('ConfigureGitHub', 'ConfigureSre', 'Ready', 'Fault', 'Reset') -and $State.phase -cne 'provisioned') {
        throw "Action $Action requires a provisioned environment (phase is '$($State.phase)'). Run Up to completion."
    }
}

function Set-OrderFlowGitOpsPending {
    <#
    .SYNOPSIS
    Durably record intent before a mutation starts.
    #>
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name, [hashtable]$Detail = @{})
    if ($State.pendingOperation) { throw "Operation '$($State.pendingOperation.name)' is still pending." }
    $State.pendingOperation = @{ name = $Name; detail = $Detail; startedAtUtc = [DateTimeOffset]::UtcNow.ToString('o') }
    Save-OrderFlowGitOpsState $State $Path "start $Name"
}

function Clear-OrderFlowGitOpsPending {
    <#
    .SYNOPSIS
    Mark the recorded operation as observed/settled.
    #>
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][string]$Path, [string]$Outcome = 'observed')
    $name = if ($State.pendingOperation) { $State.pendingOperation.name } else { 'none' }
    $State.pendingOperation = $null
    Save-OrderFlowGitOpsState $State $Path "settle $name $Outcome"
}

function Get-OrderFlowGitOpsTag {
    <#
    .SYNOPSIS
    Return the ownership tags for one stage.
    #>
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][ValidateSet('shared', 'prod', 'test')][string]$Stage)
    [ordered]@{
        scenario = 'orderflow-gitops'; managedBy = 'invoke-orderflow-gitops'
        ownerToken = $State.ownerToken; environment = $State.environmentName; stage = $Stage
    }
}

function Assert-OrderFlowGitOpsGroupOwner {
    <#
    .SYNOPSIS
    Verify a live resource group carries this manifest's exact ownership tags.
    #>
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][ValidateSet('shared', 'prod', 'test')][string]$Stage,
        [hashtable]$Group)
    $name = $State.resourceGroups[$Stage]
    if (-not $Group) { $Group = Invoke-OrderFlowGitOpsAzure $State @('group', 'show', '--name', $name) }
    if (-not $Group -or $Group['name'] -and $Group.name -ine $name) { throw "Resource group $name could not be verified." }
    $expected = Get-OrderFlowGitOpsTag $State $Stage
    $tags = if ($Group['tags']) { $Group.tags } else { @{} }
    foreach ($key in $expected.Keys) {
        if ([string]$tags[$key] -cne [string]$expected[$key]) {
            throw "Resource group $name ownership tag '$key' mismatch; refusing adoption or deletion of untagged/foreign groups."
        }
    }
}

function Assert-OrderFlowGitOpsGroupAbsent {
    <#
    .SYNOPSIS
    Refuse to adopt any pre-existing resource group before the manifest is written.
    #>
    param([Parameter(Mandatory)][hashtable]$State)
    foreach ($stage in @('shared', 'prod', 'test')) {
        $name = $State.resourceGroups[$stage]
        if (Invoke-OrderFlowGitOpsAzure $State @('group', 'exists', '--name', $name)) {
            throw "Resource group $name already exists; refusing adoption of untagged or foreign groups."
        }
    }
}

function New-OrderFlowGitOpsGroup {
    <#
    .SYNOPSIS
    Create one tagged resource group after durable intent, refusing adoption.
    #>
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateSet('shared', 'prod', 'test')][string]$Stage)
    $name = $State.resourceGroups[$Stage]
    if ($name -cin @($State.createdGroups)) { Assert-OrderFlowGitOpsGroupOwner $State $Stage; return }
    if (Invoke-OrderFlowGitOpsAzure $State @('group', 'exists', '--name', $name)) {
        throw "Resource group $name exists but this manifest did not create it; refusing adoption."
    }
    Set-OrderFlowGitOpsPending $State $Path 'group-create' @{ stage = $Stage; group = $name }
    $tags = Get-OrderFlowGitOpsTag $State $Stage
    $group = Invoke-OrderFlowGitOpsAzure $State (@('group', 'create', '--name', $name, '--location', $State.location, '--tags') +
        @($tags.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }))
    Assert-OrderFlowGitOpsGroupOwner $State $Stage $group
    $State.createdGroups = @(@($State.createdGroups) + $name)
    Clear-OrderFlowGitOpsPending $State $Path 'created'
}

#endregion

#region Deployment outputs and parameters

function Get-OrderFlowGitOpsOutputAlias {
    <#
    .SYNOPSIS
    Single mapping from logical names to Bicep output names (first match wins).
    .NOTES
    Adjust here if the Bicep templates rename outputs. Implemented names first.
    #>
    @{
        acrName = @('acrName', 'registryName')
        acrLoginServer = @('acrLoginServer', 'registryLoginServer')
        suffix = @('suffix')
        tenantId = @('tenantId')
        prodDeployClientId = @('deployClientIdProd', 'prodDeployClientId')
        testDeployClientId = @('deployClientIdTest', 'testDeployClientId')
        agentId = @('sreAgentId', 'agentId')
        sreIdentityId = @('sreIdentityId', 'identityId')
        srePrincipalId = @('srePrincipalId', 'principalId')
        portalUrl = @('portalUrl')
        portalFqdn = @('portalFqdn')
        smokeJobName = @('smokeJobName')
        nsgName = @('nsgName')
        appInsightsName = @('appInsightsName')
        alertId = @('alertId')
    }
}

function Get-OrderFlowGitOpsOutput {
    <#
    .SYNOPSIS
    Resolve one logical output from recorded deployment outputs.
    #>
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][ValidateSet('shared', 'sre', 'prod', 'test')][string]$Stage,
        [Parameter(Mandatory)][string]$Name, [switch]$Optional)
    $aliases = (Get-OrderFlowGitOpsOutputAlias)[$Name]
    if (-not $aliases) { throw "Unknown logical output $Name." }
    $sources = @($State.outputs[$Stage])
    if ($Stage -ceq 'sre') { $sources += $State.outputs['shared'] }
    foreach ($source in $sources) {
        if (-not $source) { continue }
        foreach ($alias in $aliases) { if ($source.Contains($alias) -and $source[$alias]) { return [string]$source[$alias] } }
    }
    if ($Name -ceq 'smokeJobName') { return 'orderflow-smoke' }
    if ($Optional) { return $null }
    throw "Deployment output for $Stage.$Name not found (accepted names: $($aliases -join ', '))."
}

function Get-OrderFlowGitOpsTemplateParameter {
    <#
    .SYNOPSIS
    Parse declared Bicep parameters; required = no default value.
    #>
    param([Parameter(Mandatory)][string]$TemplatePath)
    $result = [ordered]@{}
    foreach ($line in (Get-Content -LiteralPath $TemplatePath)) {
        if ($line -match '^\s*param\s+([A-Za-z_][A-Za-z0-9_]*)\s+([A-Za-z0-9_.\[\]]+)(\s*=.*)?$') {
            $result[$Matches[1]] = @{ type = $Matches[2]; required = -not $Matches[3] }
        }
    }
    $result
}

function Select-OrderFlowGitOpsParameter {
    <#
    .SYNOPSIS
    Pass only declared parameters; fail when a required one has no value.
    #>
    param([Parameter(Mandatory)][string]$TemplatePath, [Parameter(Mandatory)][hashtable]$Candidate)
    $declared = Get-OrderFlowGitOpsTemplateParameter $TemplatePath
    $selected = [ordered]@{}
    foreach ($name in $declared.Keys) {
        if ($Candidate.Contains($name) -and "$($Candidate[$name])" -ne '') { $selected[$name] = $Candidate[$name] }
        elseif ($declared[$name].required) {
            throw "Template $([IO.Path]::GetFileName($TemplatePath)) requires '$name', which the lifecycle cannot supply. Update Get-OrderFlowGitOpsParameterCandidate."
        }
    }
    $selected
}

function Get-OrderFlowGitOpsParameterCandidate {
    <#
    .SYNOPSIS
    Values the lifecycle can supply to shared/sre templates, keyed by parameter name.
    #>
    param([Parameter(Mandatory)][hashtable]$State)
    $candidate = @{
        location = $State.location; environmentName = $State.environmentName; ownerToken = $State.ownerToken
        adminObjectId = $State.adminObjectId; adminPrincipalType = $State.adminPrincipalType
        githubRepository = $State.gitHubRepository
        sharedResourceGroup = $State.resourceGroups.shared
        prodResourceGroup = $State.resourceGroups.prod; testResourceGroup = $State.resourceGroups.test
        tags = (Get-OrderFlowGitOpsTag $State 'shared')
        suffix = (Get-OrderFlowGitOpsOutput $State 'shared' 'suffix' -Optional)
    }
    if ($State['sreLocation']) { $candidate.sreLocation = $State.sreLocation }
    $candidate
}

function Get-OrderFlowGitOpsEnvVariable {
    <#
    .SYNOPSIS
    Process environment consumed by deploy/<stage>.bicepparam, identical to the workflows.
    #>
    param([Parameter(Mandatory)][hashtable]$State)
    $values = [ordered]@{
        ORDERFLOW_SHARED_RG = $State.resourceGroups.shared
        ORDERFLOW_SUFFIX = (Get-OrderFlowGitOpsOutput $State 'shared' 'suffix')
        ORDERFLOW_PRESENTER_CIDR = $State.presenterCidr
        ORDERFLOW_IMAGE_TAG = $State.imageTag
        ORDERFLOW_DEPLOY_SHA = $State.deploySha
        ORDERFLOW_OWNER_TOKEN = $State.ownerToken
        ORDERFLOW_ENVIRONMENT_NAME = $State.environmentName
    }
    foreach ($entry in $values.GetEnumerator()) { if (-not $entry.Value) { throw "Deployment input $($entry.Key) is empty." } }
    Assert-OrderFlowGitOpsCidr $values.ORDERFLOW_PRESENTER_CIDR
    $values
}

function ConvertTo-OrderFlowGitOpsOutputValue {
    <#
    .SYNOPSIS
    Flatten ARM deployment outputs to name/value pairs.
    #>
    param($Outputs)
    $result = @{}
    if ($Outputs) { foreach ($key in $Outputs.Keys) { $result[$key] = $Outputs[$key].value } }
    $result
}

function Invoke-OrderFlowGitOpsDeployment {
    <#
    .SYNOPSIS
    Deploy one template to an owned group with durable intent; record outputs.
    .DESCRIPTION
    prod/test use deploy/<stage>.bicepparam with the same ORDERFLOW_* environment
    variables the workflows set. A lost response stays pending for Status to observe.
    #>
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateSet('shared', 'sre', 'prod', 'test')][string]$Stage)
    $groupStage = if ($Stage -ceq 'sre') { 'shared' } else { $Stage }
    $group = $State.resourceGroups[$groupStage]
    Assert-OrderFlowGitOpsGroupOwner $State $groupStage
    $deploymentName = "ofgitops-$Stage-$([DateTimeOffset]::UtcNow.ToString('yyyyMMddHHmmss'))"
    $arguments = @('deployment', 'group', 'create', '--resource-group', $group, '--name', $deploymentName)
    $environment = $null
    if ($Stage -cin @('prod', 'test')) {
        $environment = Get-OrderFlowGitOpsEnvVariable $State
        $arguments += @('--parameters', (Join-Path (Get-OrderFlowGitOpsPath 'Deploy') "$Stage.bicepparam"))
    } else {
        $template = Join-Path (Get-OrderFlowGitOpsPath 'Infra') "$Stage.bicep"
        $selected = Select-OrderFlowGitOpsParameter $template (Get-OrderFlowGitOpsParameterCandidate $State)
        $parameterPath = Join-Path (Split-Path -Parent $Path) "parameters-$Stage.json"
        $document = [ordered]@{
            '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
            contentVersion = '1.0.0.0'; parameters = [ordered]@{}
        }
        foreach ($entry in $selected.GetEnumerator()) { $document.parameters[$entry.Key] = @{ value = $entry.Value } }
        $document | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $parameterPath -Encoding utf8NoBOM
        $arguments += @('--template-file', $template, '--parameters', "@$parameterPath")
    }
    Set-OrderFlowGitOpsPending $State $Path 'deployment' @{ stage = $Stage; resourceGroup = $group; deploymentName = $deploymentName }
    $result = Invoke-OrderFlowGitOpsAzure $State $arguments -TimeoutSeconds 2700 -Environment $environment
    if (-not $result -or $result.properties.provisioningState -cne 'Succeeded') {
        throw "Deployment $deploymentName did not report Succeeded. Run Status to observe; it is not replayed."
    }
    $State.outputs[$Stage] = ConvertTo-OrderFlowGitOpsOutputValue $result.properties.outputs
    Assert-OrderFlowGitOpsState $State $State.subscriptionId $State.environmentName
    $State.stages["deploy-$Stage"] = $true
    Clear-OrderFlowGitOpsPending $State $Path 'Succeeded'
}

function Get-OrderFlowGitOpsImageTag {
    <#
    .SYNOPSIS
    Compute the deterministic image tag with tools/image_tag.py.
    #>
    $tag = (Invoke-OrderFlowGitOpsPython @((Join-Path (Get-OrderFlowGitOpsPath 'Tools') 'image_tag.py'))).Trim()
    if ($tag -cnotmatch '^sha-[0-9a-f]{16}$') { throw 'tools/image_tag.py returned an unexpected tag.' }
    $tag
}

function Test-OrderFlowGitOpsImage {
    <#
    .SYNOPSIS
    Return $true when orderflow:<tag> already exists in the owned registry.
    #>
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][string]$Tag)
    $registry = Get-OrderFlowGitOpsOutput $State 'shared' 'acrName'
    $repositories = @(Invoke-OrderFlowGitOpsAzure $State @('acr', 'repository', 'list', '--name', $registry))
    if ('orderflow' -cnotin $repositories) { return $false }
    $tags = @(Invoke-OrderFlowGitOpsAzure $State @('acr', 'repository', 'show-tags', '--name', $registry, '--repository', 'orderflow'))
    $Tag -cin $tags
}

function New-OrderFlowGitOpsBuildContext {
    <#
    .SYNOPSIS
    Stage exactly the image inputs (never .venv or caches) plus the Dockerfile under TEMP.
    #>
    $appRoot = Join-Path $script:repositoryRoot 'scenarios\orderflow\app'
    $context = Join-Path ([IO.Path]::GetTempPath()) "ofgitops-build-$([guid]::NewGuid().ToString('N'))"
    $null = New-Item -ItemType Directory -Path (Join-Path $context 'static') -Force
    foreach ($file in @('backend.py', 'common.py', 'portal.py', 'smoke.py', 'requirements.txt')) {
        Copy-Item -LiteralPath (Join-Path $appRoot $file) -Destination $context
    }
    Get-ChildItem -LiteralPath (Join-Path $appRoot 'static') -File | Copy-Item -Destination (Join-Path $context 'static')
    Copy-Item -LiteralPath (Join-Path $script:gitOpsRoot 'container\Dockerfile') -Destination (Join-Path $context 'Dockerfile')
    $context
}

function Invoke-OrderFlowGitOpsImageBuild {
    <#
    .SYNOPSIS
    Build the image once with ACR Tasks (az acr build) and wait for a terminal run state.
    #>
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][string]$Path,
        [ValidateRange(60, 3600)][int]$TimeoutSeconds = 1500)
    $registry = Get-OrderFlowGitOpsOutput $State 'shared' 'acrName'
    if (Test-OrderFlowGitOpsImage $State $State.imageTag) {
        $State.stages['image'] = $true
        Save-OrderFlowGitOpsState $State $Path 'image present'
        return
    }
    $context = New-OrderFlowGitOpsBuildContext
    try {
        Set-OrderFlowGitOpsPending $State $Path 'image-build' @{ registry = $registry; tag = $State.imageTag; runId = $null }
        $run = Invoke-OrderFlowGitOpsAzure $State @('acr', 'build', '--registry', $registry, '--image', "orderflow:$($State.imageTag)",
            '--file', (Join-Path $context 'Dockerfile'), '--no-logs', '--timeout', '1800', $context) -TimeoutSeconds 600
    } finally { Remove-Item -LiteralPath $context -Recurse -Force -ErrorAction SilentlyContinue }
    $runId = if ($run -is [System.Collections.IDictionary] -and $run['runId']) { [string]$run.runId } else { $null }
    if ($runId) { $State.pendingOperation.detail.runId = $runId; Save-OrderFlowGitOpsState $State $Path 'image run queued' }
    $status = Wait-OrderFlowGitOpsImageBuild $State -TimeoutSeconds $TimeoutSeconds
    if ($status -cne 'Succeeded') { throw "Image build is $status. Run Status to observe; the build is not replayed automatically." }
    $State.stages['image'] = $true
    Clear-OrderFlowGitOpsPending $State $Path 'Succeeded'
}

function Wait-OrderFlowGitOpsImageBuild {
    <#
    .SYNOPSIS
    Bounded wait for the recorded ACR run, or tag presence when no run ID was observed.
    #>
    param([Parameter(Mandatory)][hashtable]$State, [int]$TimeoutSeconds = 1500, [int]$PollSeconds = 15)
    $detail = $State.pendingOperation.detail
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        if ($detail['runId']) {
            $run = Invoke-OrderFlowGitOpsAzure $State @('acr', 'task', 'show-run', '--registry', $detail.registry, '--run-id', $detail.runId)
            if ($run.status -cin @('Succeeded', 'Failed', 'Canceled', 'Error', 'Timeout')) { return [string]$run.status }
        } elseif (Test-OrderFlowGitOpsImage $State $detail.tag) { return 'Succeeded' }
        if ($watch.Elapsed.TotalSeconds -ge $TimeoutSeconds) { return 'TimedOut' }
        Start-Sleep -Seconds $PollSeconds
    }
}

#endregion

#region Smoke job

function Start-OrderFlowGitOpsSmoke {
    <#
    .SYNOPSIS
    Start the stage's in-network smoke job and wait boundedly for a terminal status.
    .OUTPUTS
    Hashtable with stage, executionName, status, succeeded, observedAtUtc.
    #>
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][ValidateSet('prod', 'test')][string]$Stage,
        [ValidateRange(1, 1800)][int]$TimeoutSeconds = 420, [ValidateRange(0, 60)][int]$PollSeconds = 10)
    $group = $State.resourceGroups[$Stage]
    $job = Get-OrderFlowGitOpsOutput $State $Stage 'smokeJobName'
    $execution = Invoke-OrderFlowGitOpsAzure $State @('containerapp', 'job', 'start', '--name', $job, '--resource-group', $group)
    $name = if ($execution -is [System.Collections.IDictionary] -and $execution['name']) { [string]$execution.name } else { $null }
    if (-not $name -or $name -cnotmatch '^[A-Za-z0-9-]{1,100}$') { throw 'Smoke job start returned no recognizable execution name.' }
    Wait-OrderFlowGitOpsSmoke $State $Stage $name -TimeoutSeconds $TimeoutSeconds -PollSeconds $PollSeconds
}

function Wait-OrderFlowGitOpsSmoke {
    <#
    .SYNOPSIS
    Poll one smoke job execution until terminal or the deadline; a timeout is never success.
    #>
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][ValidateSet('prod', 'test')][string]$Stage,
        [Parameter(Mandatory)][string]$ExecutionName,
        [ValidateRange(1, 1800)][int]$TimeoutSeconds = 420, [ValidateRange(0, 60)][int]$PollSeconds = 10)
    $group = $State.resourceGroups[$Stage]
    $job = Get-OrderFlowGitOpsOutput $State $Stage 'smokeJobName'
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        $result = Invoke-OrderFlowGitOpsAzure $State @('containerapp', 'job', 'execution', 'show', '--name', $job,
            '--resource-group', $group, '--job-execution-name', $ExecutionName)
        $status = 'Unknown'
        if ($result -is [System.Collections.IDictionary] -and $result['properties'] -and $result.properties['status']) {
            $status = [string]$result.properties.status
        }
        if ($status -cin @('Succeeded', 'Failed', 'Stopped', 'Degraded')) { break }
        if ($watch.Elapsed.TotalSeconds -ge $TimeoutSeconds) { $status = 'TimedOut'; break }
        Start-Sleep -Seconds $PollSeconds
    }
    @{
        stage = $Stage; executionName = $ExecutionName; status = $status; succeeded = ($status -ceq 'Succeeded')
        observedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    }
}

function Get-OrderFlowGitOpsLatestSmoke {
    <#
    .SYNOPSIS
    Read the most recent smoke execution without starting a new one.
    #>
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][ValidateSet('prod', 'test')][string]$Stage)
    $job = Get-OrderFlowGitOpsOutput $State $Stage 'smokeJobName'
    $executions = @(Invoke-OrderFlowGitOpsAzure $State @('containerapp', 'job', 'execution', 'list', '--name', $job,
        '--resource-group', $State.resourceGroups[$Stage]))
    $latest = $executions | Where-Object { $_ } | Sort-Object { [string]$_.properties.startTime } -Descending | Select-Object -First 1
    if (-not $latest) { return @{ stage = $Stage; status = 'None' } }
    @{ stage = $Stage; executionName = $latest.name; status = [string]$latest.properties.status; startTime = [string]$latest.properties.startTime }
}

#endregion

#region Network rules (semantic compare and fault application)

function ConvertTo-OrderFlowGitOpsCanonical {
    <#
    .SYNOPSIS
    Canonical form for semantic comparison: keys sorted, scalar arrays sorted.
    #>
    param($Value)
    if ($Value -is [System.Collections.IDictionary]) {
        $sorted = [ordered]@{}
        foreach ($key in ($Value.Keys | Sort-Object -CaseSensitive)) { $sorted[$key] = ConvertTo-OrderFlowGitOpsCanonical $Value[$key] }
        return $sorted
    }
    if ($Value -is [System.Collections.IList]) {
        $items = @(foreach ($item in $Value) { , (ConvertTo-OrderFlowGitOpsCanonical $item) })
        if (-not @($items | Where-Object { $_ -is [System.Collections.IDictionary] -or $_ -is [System.Collections.IList] }).Count) {
            $items = @($items | Sort-Object -CaseSensitive)
        }
        return , $items
    }
    $Value
}

function Get-OrderFlowGitOpsRuleMap {
    <#
    .SYNOPSIS
    Validate a rules document and index canonical rule properties by unique name.
    #>
    param([Parameter(Mandatory)]$Document)
    if ($Document -is [string]) { $Document = $Document | ConvertFrom-Json -AsHashtable }
    if ($Document -isnot [System.Collections.IDictionary] -or -not $Document.Contains('rules') -or
        $Document.rules -isnot [System.Collections.IList]) { throw 'Network rules document must contain a rules array.' }
    $map = [ordered]@{}
    foreach ($rule in $Document.rules) {
        if ($rule -isnot [System.Collections.IDictionary] -or -not $rule['name'] -or $rule['properties'] -isnot [System.Collections.IDictionary]) {
            throw 'Each rule needs a name and a properties object.'
        }
        if ($map.Contains([string]$rule.name)) { throw "Duplicate rule name $($rule.name)." }
        $map[[string]$rule.name] = (ConvertTo-OrderFlowGitOpsCanonical $rule.properties) | ConvertTo-Json -Depth 20 -Compress
    }
    $map
}

function Test-OrderFlowGitOpsRuleSetEqual {
    <#
    .SYNOPSIS
    Semantic, order-insensitive (by rule name) comparison of two rule documents.
    #>
    param([Parameter(Mandatory)]$Left, [Parameter(Mandatory)]$Right)
    $a = Get-OrderFlowGitOpsRuleMap $Left
    $b = Get-OrderFlowGitOpsRuleMap $Right
    if ($a.Count -ne $b.Count) { return $false }
    foreach ($name in $a.Keys) {
        if (-not $b.Contains($name) -or $a[$name] -cne $b[$name]) { return $false }
    }
    $true
}

function Get-OrderFlowGitOpsFault {
    <#
    .SYNOPSIS
    Normalize the predefined fault file: rules to add plus PR title/body/label.
    #>
    param([Parameter(Mandatory)]$Document)
    if ($Document -is [string]) { $Document = $Document | ConvertFrom-Json -AsHashtable }
    $rules = @()
    if ($Document.Contains('rule')) { $rules += , $Document.rule }
    if ($Document.Contains('rules')) { $rules += @($Document.rules) }
    $title = [string]$Document['title']
    $body = [string]$Document['body']
    $label = if ($Document['label']) { [string]$Document.label } else { 'orderflow-fault' }
    if (-not $rules.Count -or -not $title -or -not $body) { throw 'Fault file must define a rule, a PR title and a PR body.' }
    if ($label -cne 'orderflow-fault') { throw 'Fault PR label must be orderflow-fault.' }
    if ($Document['targetFile'] -and $Document.targetFile -cne $script:rulesPath) { throw 'Fault may only target deploy/network-rules.json.' }
    $null = Get-OrderFlowGitOpsRuleMap @{ rules = $rules }
    @{ rules = $rules; title = $title; body = $body; label = $label }
}

function Add-OrderFlowGitOpsFaultRule {
    <#
    .SYNOPSIS
    Apply the fault to a rules document. Idempotent when already applied; refuses non-baseline input.
    .OUTPUTS
    Hashtable: changed (bool), document (rules document).
    #>
    param([Parameter(Mandatory)]$Current, [Parameter(Mandatory)]$Baseline, [Parameter(Mandatory)][hashtable]$Fault)
    if ($Current -is [string]) { $Current = $Current | ConvertFrom-Json -AsHashtable }
    if ($Baseline -is [string]) { $Baseline = $Baseline | ConvertFrom-Json -AsHashtable }
    $faulted = @{ rules = @(@($Baseline.rules) + @($Fault.rules)) }
    $null = Get-OrderFlowGitOpsRuleMap $faulted
    if (Test-OrderFlowGitOpsRuleSetEqual $Current $faulted) { return @{ changed = $false; document = $Current } }
    if (-not (Test-OrderFlowGitOpsRuleSetEqual $Current $Baseline)) {
        throw 'network-rules.json does not equal the baseline; refusing to stack a fault on an unknown rule set. Reset first.'
    }
    $document = [ordered]@{}
    foreach ($key in $Current.Keys) { if ($key -cne 'rules') { $document[$key] = $Current[$key] } }
    $document.rules = @(@($Current.rules) + @($Fault.rules))
    @{ changed = $true; document = $document }
}

function ConvertTo-OrderFlowGitOpsJsonText {
    <#
    .SYNOPSIS
    Serialize a rules document with 2-space indentation, LF line endings and a trailing newline.
    #>
    param([Parameter(Mandatory)]$Document)
    (($Document | ConvertTo-Json -Depth 20) -replace "`r`n", "`n") + "`n"
}

#endregion

#region Git plumbing (no working tree changes) and GitHub

function Get-OrderFlowGitOpsMain {
    <#
    .SYNOPSIS
    Fetch origin/main and return its commit SHA.
    #>
    $null = Invoke-OrderFlowGitOpsGit @('fetch', '--quiet', '--no-tags', 'origin', '+refs/heads/main:refs/remotes/origin/main')
    $sha = (Invoke-OrderFlowGitOpsGit @('rev-parse', '--verify', 'refs/remotes/origin/main^{commit}')).Trim()
    if ($sha -cnotmatch '^[0-9a-f]{40}$') { throw 'Could not resolve origin/main.' }
    $sha
}

function Get-OrderFlowGitOpsFileAtCommit {
    <#
    .SYNOPSIS
    Read one repository file from a commit without checkout.
    #>
    param([Parameter(Mandatory)][string]$Commit, [Parameter(Mandatory)][string]$RelativePath)
    Invoke-OrderFlowGitOpsGit @('show', "${Commit}:$RelativePath")
}

function Assert-OrderFlowGitOpsOrigin {
    <#
    .SYNOPSIS
    The push remote must be the recorded GitHub repository.
    #>
    param([Parameter(Mandatory)][hashtable]$State)
    $url = (Invoke-OrderFlowGitOpsGit @('remote', 'get-url', '--push', 'origin')).Trim()
    if ((ConvertTo-OrderFlowGitOpsRepository $url) -ine $State.gitHubRepository) {
        throw 'origin does not point at the recorded GitHub repository; refusing to push.'
    }
}

function New-OrderFlowGitOpsCommit {
    <#
    .SYNOPSIS
    Create a single-file commit on top of a parent using a temporary index (no checkout, no branch switch).
    #>
    param([Parameter(Mandatory)][string]$Parent, [Parameter(Mandatory)][string]$Content, [Parameter(Mandatory)][string]$Message)
    $index = Join-Path ([IO.Path]::GetTempPath()) "ofgitops-index-$([guid]::NewGuid().ToString('N'))"
    $environment = @{ GIT_INDEX_FILE = $index }
    try {
        $blob = (Invoke-OrderFlowGitOpsGit @('hash-object', '-w', '--no-filters', '--stdin') -InputText $Content).Trim()
        $null = Invoke-OrderFlowGitOpsGit @('read-tree', $Parent) -Environment $environment
        $null = Invoke-OrderFlowGitOpsGit @('update-index', '--cacheinfo', "100644,$blob,$script:rulesPath") -Environment $environment
        $tree = (Invoke-OrderFlowGitOpsGit @('write-tree') -Environment $environment).Trim()
        $commit = (Invoke-OrderFlowGitOpsGit @('commit-tree', $tree, '-p', $Parent, '-F', '-') -InputText $Message).Trim()
    } finally { Remove-Item -LiteralPath $index -Force -ErrorAction SilentlyContinue }
    $changed = @((Invoke-OrderFlowGitOpsGit @('diff-tree', '--no-commit-id', '--name-only', '-r', $Parent, $commit)) -split "`n" |
        Where-Object { $_ })
    if ($changed.Count -ne 1 -or $changed[0] -cne $script:rulesPath) { throw 'Generated commit changes unexpected files; not pushing.' }
    $commit
}

function Assert-OrderFlowGitOpsBranch {
    <#
    .SYNOPSIS
    Only short-lived lifecycle branches may be pushed; never main.
    #>
    param([Parameter(Mandatory)][string]$Branch)
    if ($Branch -cnotmatch '^orderflow-(fault|reset)/[0-9a-f]{8}$') { throw 'Refusing to push to a non-lifecycle branch.' }
}

function Publish-OrderFlowGitOpsChange {
    <#
    .SYNOPSIS
    Push one lifecycle commit to a new branch and open a PR against main (never merges).
    .DESCRIPTION
    Journals each remote mutation; on an unknown outcome Status observes the remote
    branch and PR instead of pushing or creating again.
    #>
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateSet('fault', 'reset')][string]$Kind,
        [Parameter(Mandatory)][string]$Commit, [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Body, [Parameter(Mandatory)][string]$Label)
    $token = New-OrderFlowGitOpsToken
    $branch = "orderflow-$Kind/$token"
    Assert-OrderFlowGitOpsBranch $branch
    Assert-OrderFlowGitOpsOrigin $State
    $record = @{ branch = $branch; commit = $Commit; requestedAtUtc = [DateTimeOffset]::UtcNow.ToString('o'); prUrl = $null }
    Set-OrderFlowGitOpsPending $State $Path "$Kind-push" $record
    $null = Invoke-OrderFlowGitOpsGit @('push', '--quiet', '--no-verify', 'origin', "${Commit}:refs/heads/$branch")
    $State.pendingOperation.name = "$Kind-pr"
    Save-OrderFlowGitOpsState $State $Path "pushed $branch"
    $bodyPath = Join-Path ([IO.Path]::GetTempPath()) "ofgitops-pr-$token.md"
    try {
        Set-Content -LiteralPath $bodyPath -Value $Body -Encoding utf8NoBOM
        $url = (Invoke-OrderFlowGitOpsGh @('pr', 'create', '--repo', $State.gitHubRepository, '--base', 'main', '--head', $branch,
            '--title', $Title, '--body-file', $bodyPath, '--label', $Label)).Trim()
    } finally { Remove-Item -LiteralPath $bodyPath -Force -ErrorAction SilentlyContinue }
    $record.prUrl = @($url -split "`n")[-1]
    $collection = if ($Kind -ceq 'fault') { 'faults' } else { 'resets' }
    $State[$collection] = @(@($State[$collection]) + $record)
    Clear-OrderFlowGitOpsPending $State $Path 'pr-opened'
    $record
}

function Get-OrderFlowGitOpsPullRequest {
    <#
    .SYNOPSIS
    List PRs in the recorded repository by label or head branch.
    #>
    param([Parameter(Mandatory)][hashtable]$State, [string]$Label, [string]$Head,
        [ValidateSet('open', 'closed', 'merged', 'all')][string]$Status = 'open')
    $arguments = @('pr', 'list', '--repo', $State.gitHubRepository, '--state', $Status, '--limit', '50',
        '--json', 'number,title,url,state,headRefName,isDraft')
    if ($Label) { $arguments += @('--label', $Label) }
    if ($Head) { $arguments += @('--head', $Head) }
    $result = Invoke-OrderFlowGitOpsGh $arguments -Json
    if ($null -eq $result) { return , @() }
    , @($result)
}

function Get-OrderFlowGitOpsFaultSource {
    <#
    .SYNOPSIS
    Build the fault commit content from origin/main (requires baseline).
    .OUTPUTS
    Hashtable: changed, content, fault.
    #>
    param([Parameter(Mandatory)][string]$Commit)
    $fault = Get-OrderFlowGitOpsFault (Get-OrderFlowGitOpsFileAtCommit $Commit 'scenarios/orderflow/gitops/faults/egress-lockdown.json')
    $current = Get-OrderFlowGitOpsFileAtCommit $Commit $script:rulesPath
    $baseline = Get-OrderFlowGitOpsFileAtCommit $Commit $script:baselinePath
    $applied = Add-OrderFlowGitOpsFaultRule $current $baseline $fault
    @{ changed = $applied.changed; content = (ConvertTo-OrderFlowGitOpsJsonText $applied.document); fault = $fault }
}

function Invoke-OrderFlowGitOpsReset {
    <#
    .SYNOPSIS
    Open a PR restoring the baseline when origin/main differs; no-op when already baseline.
    #>
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][string]$Path, [switch]$Preview)
    $main = Get-OrderFlowGitOpsMain
    $comparison = Test-OrderFlowGitOpsMainBaseline $main
    if ($comparison.equal) { return @{ result = 'NoOp'; message = 'origin/main already equals the baseline; no reset PR opened.' } }
    $open = Get-OrderFlowGitOpsPullRequest $State -Label 'orderflow-reset'
    if ($open.Count) { return @{ result = 'Exists'; message = "Reset PR already open: $($open[0].url)" } }
    if ($Preview) { return @{ result = 'Preview'; message = 'Would open a reset PR restoring the baseline.' } }
    $content = ($comparison.baseline -replace "`r`n", "`n").TrimEnd("`n") + "`n"
    $commit = New-OrderFlowGitOpsCommit $main $content "fix(orderflow-gitops): restore baseline network rules`n`nPresenter reset after an OrderFlow GitOps demo."
    $body = "Restores ``$($script:rulesPath)`` to ``deploy/baseline/network-rules.json`` after an OrderFlow GitOps demo.`n`n" +
        'Created by the presenter lifecycle (Reset). Review and merge to roll production back to the baseline through CD.'
    $record = Publish-OrderFlowGitOpsChange $State $Path 'reset' $commit 'Reset OrderFlow network rules to baseline' $body 'orderflow-reset'
    @{ result = 'Opened'; message = "Reset PR opened: $($record.prUrl)"; record = $record }
}

#endregion

#region Readiness

function Test-OrderFlowGitOpsMainBaseline {
    <#
    .SYNOPSIS
    Compare deploy/network-rules.json with the baseline at a commit (default: fetched origin/main).
    #>
    param([string]$Commit)
    if (-not $Commit) { $Commit = Get-OrderFlowGitOpsMain }
    $current = Get-OrderFlowGitOpsFileAtCommit $Commit $script:rulesPath
    $baseline = Get-OrderFlowGitOpsFileAtCommit $Commit $script:baselinePath
    @{ commit = $Commit; equal = (Test-OrderFlowGitOpsRuleSetEqual $current $baseline); current = $current; baseline = $baseline }
}

function Get-OrderFlowGitOpsActiveAlert {
    <#
    .SYNOPSIS
    Return fired, unresolved instances of the owned prod alert rule.
    #>
    param([Parameter(Mandatory)][hashtable]$State)
    $alertId = Get-OrderFlowGitOpsOutput $State 'prod' 'alertId'
    $group = [uri]::EscapeDataString("/subscriptions/$($State.subscriptionId)/resourceGroups/$($State.resourceGroups.prod)")
    $uri = "https://management.azure.com/subscriptions/$($State.subscriptionId)/providers/Microsoft.AlertsManagement/alerts" +
        "?api-version=2019-03-01&targetResourceGroup=$group&timeRange=1d&pageCount=250"
    $alerts = Invoke-OrderFlowGitOpsRequest $State $uri
    if (-not $alerts -or -not $alerts.ContainsKey('value') -or $alerts['nextLink']) { throw 'Alert discovery incomplete; treat as not ready.' }
    , @($alerts.value | Where-Object {
            $_.properties.essentials.alertRule -ieq $alertId -and $_.properties.essentials.monitorCondition -cne 'Resolved'
        })
}

function Test-OrderFlowGitOpsReady {
    <#
    .SYNOPSIS
    Fresh readiness evidence: smoke in both stages, baseline on main, no open fault PR, no active prod alert.
    .OUTPUTS
    Hashtable with ready (bool), reasons, smoke, mainCommit.
    #>
    param([Parameter(Mandatory)][hashtable]$State, [int]$SmokeTimeoutSeconds = 420)
    $reasons = @()
    $smoke = @{}
    foreach ($stage in @('test', 'prod')) {
        $smoke[$stage] = Start-OrderFlowGitOpsSmoke $State $stage -TimeoutSeconds $SmokeTimeoutSeconds
        if (-not $smoke[$stage].succeeded) { $reasons += "$stage smoke is $($smoke[$stage].status)" }
    }
    $comparison = Test-OrderFlowGitOpsMainBaseline
    if (-not $comparison.equal) { $reasons += 'network-rules.json on origin/main differs from the baseline (run Reset)' }
    $open = Get-OrderFlowGitOpsPullRequest $State -Label 'orderflow-fault'
    if ($open.Count) { $reasons += "open orderflow-fault PR: $($open[0].url)" }
    $alerts = Get-OrderFlowGitOpsActiveAlert $State
    if ($alerts.Count) { $reasons += 'prod dependency alert is not resolved' }
    @{ ready = (-not $reasons.Count); reasons = $reasons; smoke = $smoke; mainCommit = $comparison.commit }
}

#endregion

#region Teardown

function Assert-OrderFlowGitOpsInventory {
    <#
    .SYNOPSIS
    Refuse deletion when a group contains resources claimed by another owner or scenario.
    .DESCRIPTION
    Platform-created children may be untagged; they are returned for reporting.
    #>
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][ValidateSet('shared', 'prod', 'test')][string]$Stage)
    $resources = @(Invoke-OrderFlowGitOpsAzure $State @('resource', 'list', '--resource-group', $State.resourceGroups[$Stage]))
    $untagged = @()
    foreach ($resource in ($resources | Where-Object { $_ })) {
        $tags = if ($resource['tags']) { $resource.tags } else { @{} }
        if ($tags['ownerToken'] -and $tags.ownerToken -cne $State.ownerToken) { throw "Foreign-owned resource ($($resource.type)) in $Stage group; refusing deletion." }
        if ($tags['scenario'] -and $tags.scenario -cne 'orderflow-gitops') { throw "Resource from another scenario ($($resource.type)) in $Stage group; refusing deletion." }
        if (-not $tags['ownerToken']) { $untagged += [string]$resource.type }
    }
    , $untagged
}

function Invoke-OrderFlowGitOpsDown {
    <#
    .SYNOPSIS
    Delete owned groups: env groups first, then shared. Verifies tags first; observes absence; never re-requests.
    #>
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][string]$Path,
        [ValidateRange(1, 7200)][int]$TimeoutSeconds = 2700, [ValidateRange(0, 120)][int]$PollSeconds = 30)
    $waves = @(@{ name = 'delete-env'; stages = @('prod', 'test') }, @{ name = 'delete-shared'; stages = @('shared') })
    if ($State.pendingOperation -and $State.pendingOperation.name -cnotin @($waves.name)) {
        throw "Unexpected pending operation $($State.pendingOperation.name); resolve it with Status first."
    }
    foreach ($wave in $waves) {
        if ($State.pendingOperation -and $State.pendingOperation.name -ceq 'delete-shared' -and $wave.name -ceq 'delete-env') { continue }
        if (-not $State.pendingOperation) {
            $targets = @()
            foreach ($stage in $wave.stages) {
                $name = $State.resourceGroups[$stage]
                if (-not (Invoke-OrderFlowGitOpsAzure $State @('group', 'exists', '--name', $name))) { continue }
                Assert-OrderFlowGitOpsGroupOwner $State $stage
                $untagged = Assert-OrderFlowGitOpsInventory $State $stage
                if ($untagged.Count) { Write-Warning "$name contains untagged platform-created resources: $(@($untagged | Sort-Object -Unique) -join ', ')" }
                $targets += $name
            }
            if (-not $targets.Count) { continue }
            Set-OrderFlowGitOpsPending $State $Path $wave.name @{ groups = $targets }
            foreach ($name in $targets) {
                $null = Invoke-OrderFlowGitOpsAzure $State @('group', 'delete', '--name', $name, '--yes', '--no-wait')
            }
        }
        Wait-OrderFlowGitOpsGroupAbsent $State @($State.pendingOperation.detail.groups) $TimeoutSeconds $PollSeconds
        Clear-OrderFlowGitOpsPending $State $Path 'absent'
    }
    $State.phase = 'removed'
    $State.removedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    Save-OrderFlowGitOpsState $State $Path 'removed'
}

function Wait-OrderFlowGitOpsGroupAbsent {
    <#
    .SYNOPSIS
    Observe group deletion; a group that is no longer Deleting means deletion failed (no retry).
    #>
    param([Parameter(Mandatory)][hashtable]$State, [string[]]$Groups, [int]$TimeoutSeconds, [int]$PollSeconds)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        $remaining = @()
        foreach ($name in $Groups) {
            if (-not (Invoke-OrderFlowGitOpsAzure $State @('group', 'exists', '--name', $name))) { continue }
            $group = Invoke-OrderFlowGitOpsAzure $State @('group', 'show', '--name', $name)
            if ($group.properties.provisioningState -cne 'Deleting' -and $watch.Elapsed.TotalSeconds -ge 60) {
                throw "Resource group $name is $($group.properties.provisioningState), not Deleting. Inspect the original deletion; it is not retried."
            }
            $remaining += $name
        }
        if (-not $remaining.Count) { return }
        if ($watch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
            throw "Still deleting: $($remaining -join ', '). Run Down again later to keep observing; deletion is not re-requested."
        }
        Start-Sleep -Seconds $PollSeconds
    }
}

#endregion

#region Pending-operation observation (Status)

function Resolve-OrderFlowGitOpsPending {
    <#
    .SYNOPSIS
    Observe the recorded unknown operation and settle state only on positive evidence.
    .OUTPUTS
    A short observation message.
    #>
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][string]$Path)
    $pending = $State.pendingOperation
    if (-not $pending) { return 'No pending operation.' }
    $detail = $pending.detail
    switch -CaseSensitive ($pending.name) {
        'group-create' {
            if (Invoke-OrderFlowGitOpsAzure $State @('group', 'exists', '--name', $detail.group)) {
                Assert-OrderFlowGitOpsGroupOwner $State $detail.stage
                $State.createdGroups = @(@($State.createdGroups) + $detail.group | Select-Object -Unique)
                Clear-OrderFlowGitOpsPending $State $Path 'created'
                return "Group $($detail.group) exists with our tags; recorded. Run Up to continue."
            }
            Clear-OrderFlowGitOpsPending $State $Path 'absent'
            return "Group $($detail.group) was not created. Run Up to continue."
        }
        'deployment' {
            $deployment = Invoke-OrderFlowGitOpsAzure $State @('deployment', 'group', 'show', '--resource-group', $detail.resourceGroup,
                '--name', $detail.deploymentName)
            $status = [string]$deployment.properties.provisioningState
            if ($status -ceq 'Succeeded') {
                $State.outputs[$detail.stage] = ConvertTo-OrderFlowGitOpsOutputValue $deployment.properties.outputs
                Assert-OrderFlowGitOpsState $State $State.subscriptionId $State.environmentName
                $State.stages["deploy-$($detail.stage)"] = $true
                Clear-OrderFlowGitOpsPending $State $Path 'Succeeded'
                return "Deployment $($detail.deploymentName) succeeded; outputs recorded. Run Up to continue."
            }
            if ($status -cin @('Failed', 'Canceled')) {
                $State.phase = 'deployment-failed'
                $State.failure = @{ deploymentName = $detail.deploymentName; state = $status; observedAtUtc = [DateTimeOffset]::UtcNow.ToString('o') }
                Clear-OrderFlowGitOpsPending $State $Path $status
                return "Deployment $($detail.deploymentName) is $status. Cleanup only (Down)."
            }
            return "Deployment $($detail.deploymentName) is $status; keep observing."
        }
        'image-build' {
            $status = Wait-OrderFlowGitOpsImageBuild $State -TimeoutSeconds 1 -PollSeconds 0
            if ($status -ceq 'Succeeded') {
                $State.stages['image'] = $true
                Clear-OrderFlowGitOpsPending $State $Path 'Succeeded'
                return 'Image present. Run Up to continue.'
            }
            if ($status -cin @('Failed', 'Canceled', 'Error', 'Timeout')) {
                Clear-OrderFlowGitOpsPending $State $Path $status
                return "Image build ended $status; Up may queue a new build after you inspect the run."
            }
            return "Image build is $status; keep observing."
        }
        { $_ -cin @('fault-push', 'reset-push', 'fault-pr', 'reset-pr') } {
            $kind = $pending.name.Split('-')[0]
            $collection = if ($kind -ceq 'fault') { 'faults' } else { 'resets' }
            $prs = Get-OrderFlowGitOpsPullRequest $State -Head $detail.branch -Status 'all'
            if ($prs.Count) {
                $detail.prUrl = $prs[0].url
                $State[$collection] = @(@($State[$collection]) + $detail)
                Clear-OrderFlowGitOpsPending $State $Path 'pr-observed'
                return "PR observed: $($detail.prUrl)"
            }
            $remote = Invoke-OrderFlowGitOpsGit @('ls-remote', 'origin', "refs/heads/$($detail.branch)")
            if (-not $remote) {
                Clear-OrderFlowGitOpsPending $State $Path 'branch-absent'
                return "Branch $($detail.branch) was not pushed and no PR exists; nothing remote changed."
            }
            if ($pending.name -clike '*-push') {
                $State.pendingOperation.name = "$kind-pr"
                Save-OrderFlowGitOpsState $State $Path 'push observed'
            }
            return "Branch $($detail.branch) exists without a PR. Open it yourself (gh pr create --base main --head $($detail.branch) --label orderflow-$kind), then run Status."
        }
        { $_ -clike 'delete-*' } { return 'Deletion pending. Run Down to keep observing absence (no re-request).' }
        default { return "Pending '$($pending.name)' needs its specific observer." }
    }
}

#endregion

#region GitHub configuration

function Get-OrderFlowGitOpsGitHubVariable {
    <#
    .SYNOPSIS
    Non-secret GitHub environment variables for orderflow-prod and orderflow-test.
    #>
    param([Parameter(Mandatory)][hashtable]$State)
    $result = [ordered]@{}
    foreach ($stage in @('prod', 'test')) {
        $result["orderflow-$stage"] = [ordered]@{
            AZURE_CLIENT_ID = (Get-OrderFlowGitOpsOutput $State 'shared' "$($stage)DeployClientId")
            AZURE_TENANT_ID = (Get-OrderFlowGitOpsOutput $State 'shared' 'tenantId')
            AZURE_SUBSCRIPTION_ID = $State.subscriptionId
            ORDERFLOW_RESOURCE_GROUP = $State.resourceGroups[$stage]
            ORDERFLOW_SHARED_RG = $State.resourceGroups.shared
            ORDERFLOW_SUFFIX = (Get-OrderFlowGitOpsOutput $State 'shared' 'suffix')
            ORDERFLOW_PRESENTER_CIDR = $State.presenterCidr
            ORDERFLOW_OWNER_TOKEN = $State.ownerToken
            ORDERFLOW_ENVIRONMENT_NAME = $State.environmentName
        }
    }
    $result
}

function Set-OrderFlowGitOpsGitHub {
    <#
    .SYNOPSIS
    Create/update both GitHub environments, their variables, branch policies and labels. Never stores secrets.
    #>
    param([Parameter(Mandatory)][hashtable]$State)
    $repository = $State.gitHubRepository
    Assert-OrderFlowGitOpsRepository $repository
    $variables = Get-OrderFlowGitOpsGitHubVariable $State
    # Test deployment runs through workflow_run from main; pull request refs must never reach the test identity.
    $policies = @{ 'orderflow-prod' = @('main'); 'orderflow-test' = @('main') }
    foreach ($environment in $variables.Keys) {
        $null = Invoke-OrderFlowGitOpsGh @('api', '--method', 'PUT', "repos/$repository/environments/$environment", '--input', '-') `
            -InputText (@{ deployment_branch_policy = @{ protected_branches = $false; custom_branch_policies = $true } } | ConvertTo-Json -Compress)
        $existing = Invoke-OrderFlowGitOpsGh @('api', "repos/$repository/environments/$environment/deployment-branch-policies") -Json
        $names = @(if ($existing -and $existing['branch_policies']) { $existing.branch_policies | ForEach-Object { $_.name } })
        foreach ($pattern in $policies[$environment]) {
            if ($pattern -cin $names) { continue }
            $null = Invoke-OrderFlowGitOpsGh @('api', '--method', 'POST', "repos/$repository/environments/$environment/deployment-branch-policies",
                '--input', '-') -InputText (@{ name = $pattern; type = 'branch' } | ConvertTo-Json -Compress)
        }
        foreach ($entry in $variables[$environment].GetEnumerator()) {
            $null = Invoke-OrderFlowGitOpsGh @('variable', 'set', $entry.Key, '--repo', $repository, '--env', $environment, '--body', [string]$entry.Value)
        }
    }
    foreach ($label in $script:labels.GetEnumerator()) {
        $null = Invoke-OrderFlowGitOpsGh @('label', 'create', $label.Key, '--repo', $repository, '--color', $label.Value.color,
            '--description', $label.Value.description, '--force')
    }
}

#endregion

Export-ModuleMember -Function *-OrderFlowGitOps*
