#Requires -Version 7.2
<#
.SYNOPSIS
Baseline and reset the demo/checkout branch that the Copilot code loop changes.
.DESCRIPTION
The code loop (SRE issue, Copilot pull request, gated route deploy) never touches main. It targets
demo/checkout, which starts at an immutable baseline tag created from main.
Configure creates the checkout-demo label and the reviewer-gated checkout-demo-reset environment, and
verifies its DEMO_RESET_TOKEN secret. Baseline creates the next demo-baseline/checkout-vN tag on main and
creates demo/checkout from it. Reset closes open demo pull requests and issues, deletes copilot/* head
branches of open or closed pull requests into demo/checkout (unless an open pull request into another base
still uses them), force-moves demo/checkout to the baseline tag and can
redeploy the declared routes. Check reports whether the branch matches the tag and no demo items are open.
.PARAMETER Action
Configure, Baseline, Reset or Check.
.PARAMETER Repository
GitHub repository in owner/name form.
.PARAMETER BaselineTag
Baseline tag for Reset and Check, demo-baseline/checkout-vN.
.PARAMETER Redeploy
Reset: dispatch Checkout Routes Deploy on demo/checkout afterwards. The deploy still waits for its reviewer.
.PARAMETER Reviewer
Configure: GitHub login that must approve each reset. Defaults to the authenticated gh user.
.EXAMPLE
./scripts/Invoke-CheckoutDemoRepo.ps1 Reset -BaselineTag demo-baseline/checkout-v1 -Redeploy
.OUTPUTS
PSCustomObject summary for Baseline, Reset and Check.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory, Position = 0)][ValidateSet('Configure', 'Baseline', 'Reset', 'Check')][string]$Action,
    [ValidatePattern('^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$')][string]$Repository = 'rutgerpels/retailtx-agentic-ops-demo',
    [string]$BaselineTag = 'demo-baseline/checkout-v1',
    [switch]$Redeploy,
    [ValidatePattern('^[A-Za-z0-9-]{1,39}$')][string]$Reviewer
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$demoBranch = 'demo/checkout'
$demoLabel = 'checkout-demo'
$tagPrefix = 'demo-baseline/checkout-v'
$resetEnvironment = 'checkout-demo-reset'
$resetSecret = 'DEMO_RESET_TOKEN'
$deployWorkflow = 'checkout-deploy.yml'

function Invoke-GitHub {
    param([Parameter(Mandatory)][string[]]$Arguments, [string]$InputText, [switch]$AllowMissing)
    if ($PSBoundParameters.ContainsKey('InputText')) { $output = $InputText | & gh @Arguments 2>&1 }
    else { $output = & gh @Arguments 2>&1 }
    if ($LASTEXITCODE -ne 0) {
        if ($AllowMissing -and ($output -join "`n") -match 'HTTP 404|Not Found|HTTP 422|Reference does not exist') { return $null }
        throw "GitHub CLI failed: gh $($Arguments[0..1] -join ' ')."
    }
    return ($output -join "`n")
}

function Invoke-GitHubJson {
    param([Parameter(Mandatory)][string[]]$Arguments, [switch]$AllowMissing)
    $text = Invoke-GitHub $Arguments -AllowMissing:$AllowMissing
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return $text | ConvertFrom-Json -AsHashtable
}

function Assert-BaselineTag {
    param([Parameter(Mandatory)][string]$Tag)
    if ($Tag -cnotmatch '^demo-baseline/checkout-v[1-9][0-9]{0,3}$') {
        throw 'BaselineTag must be demo-baseline/checkout-v<N>.'
    }
}

function Resolve-BaselineCommit {
    <# Lightweight tag only, and its commit must already be on main. #>
    param([Parameter(Mandatory)][string]$Tag)
    Assert-BaselineTag $Tag
    $ref = Invoke-GitHubJson @('api', "repos/$Repository/git/ref/tags/$Tag") -AllowMissing
    if (-not $ref) { throw "Baseline tag $Tag does not exist; run Baseline first." }
    if ($ref.object.type -cne 'commit' -or $ref.object.sha -cnotmatch '^[0-9a-f]{40}$') {
        throw "Baseline tag $Tag must be a lightweight tag pointing to a commit."
    }
    $comparison = Invoke-GitHubJson @('api', "repos/$Repository/compare/$($ref.object.sha)...main")
    if ($comparison.status -cnotin 'ahead', 'identical') { throw "Baseline tag $Tag is not an ancestor of main; refusing." }
    return $ref.object.sha
}

function Get-DemoPullRequest {
    $pulls = Invoke-GitHubJson @('api', '--paginate', '--slurp', "repos/$Repository/pulls?state=all&base=$demoBranch&per_page=100")
    return @($pulls | ForEach-Object { $_ } | Where-Object { $_ -and $_.base.ref -ceq $demoBranch })
}

function Get-ProtectedHeadBranch {
    <# Head branches of open pull requests into any other base; Reset never deletes them. #>
    $pulls = Invoke-GitHubJson @('api', '--paginate', '--slurp', "repos/$Repository/pulls?state=open&per_page=100")
    return @($pulls | ForEach-Object { $_ } | Where-Object { $_ -and $_.state -ceq 'open' -and $_.base.ref -cne $demoBranch } |
        ForEach-Object { $_.head.ref } | Sort-Object -Unique -CaseSensitive)
}

function Select-CopilotHeadBranch {
    <# Only same-repository copilot/* branches proposed into demo/checkout; never main or other branches. #>
    param([object[]]$PullRequests, [string[]]$Exclude = @())
    return @($PullRequests | Where-Object {
            $_.base.ref -ceq $demoBranch -and $_.head.repo -and $_.head.repo.full_name -ceq $Repository -and
            $_.head.ref -cmatch '^copilot/[A-Za-z0-9._/-]+$' -and $_.head.ref -cnotin $Exclude
        } | ForEach-Object { $_.head.ref } | Sort-Object -Unique -CaseSensitive)
}

function Get-DemoIssue {
    $issues = Invoke-GitHubJson @('api', '--paginate', '--slurp', "repos/$Repository/issues?state=open&labels=$demoLabel&per_page=100")
    return @($issues | ForEach-Object { $_ } | Where-Object { $_ -and -not $_.ContainsKey('pull_request') })
}

function Get-DemoBranchSha {
    $ref = Invoke-GitHubJson @('api', "repos/$Repository/git/ref/heads/$demoBranch") -AllowMissing
    if ($ref) { return $ref.object.sha }
    return $null
}

function Invoke-Configure {
    $login = if ($Reviewer) { $Reviewer } else { Invoke-GitHub @('api', 'user', '--jq', '.login') }
    $reviewerId = [long](Invoke-GitHub @('api', "users/$login", '--jq', '.id'))
    if ($PSCmdlet.ShouldProcess($Repository, "Create label $demoLabel and gated environment $resetEnvironment")) {
        $null = Invoke-GitHub @('label', 'create', $demoLabel, '--repo', $Repository, '--force', '--color', 'D93F0B',
            '--description', 'Checkout code-loop demo item; closed by the demo reset')
        $body = @{ reviewers = @(@{ type = 'User'; id = $reviewerId })
            deployment_branch_policy = @{ protected_branches = $false; custom_branch_policies = $true } } | ConvertTo-Json -Depth 5 -Compress
        $null = Invoke-GitHub @('api', '--method', 'PUT', "repos/$Repository/environments/$resetEnvironment", '--input', '-') -InputText $body
        $policies = Invoke-GitHubJson @('api', "repos/$Repository/environments/$resetEnvironment/deployment-branch-policies")
        if (-not ($policies.branch_policies | Where-Object { $_.name -ceq 'main' -and $_.type -ceq 'branch' })) {
            $null = Invoke-GitHub @('api', '--method', 'POST', "repos/$Repository/environments/$resetEnvironment/deployment-branch-policies",
                '-f', 'name=main', '-f', 'type=branch')
        }
    }
    $secrets = @((Invoke-GitHub @('secret', 'list', '--repo', $Repository, '--env', $resetEnvironment, '--json', 'name') | ConvertFrom-Json).name)
    if ($resetSecret -notin $secrets) {
        Write-Warning "Set the $resetSecret secret on environment $resetEnvironment; see docs/checkout-code-loop.md."
    }
}

function Invoke-Baseline {
    $existingTags = @(Invoke-GitHubJson @('api', "repos/$Repository/git/matching-refs/tags/$tagPrefix") |
        ForEach-Object { $_ } | Where-Object { $_ } | ForEach-Object { $_.ref })
    $versions = @($existingTags | ForEach-Object {
            if ($_ -cmatch '^refs/tags/demo-baseline/checkout-v([1-9][0-9]{0,3})$') { [int]$Matches[1] } })
    $next = if ($versions.Count) { ($versions | Measure-Object -Maximum).Maximum + 1 } else { 1 }
    $tag = "$tagPrefix$next"
    $mainSha = (Invoke-GitHubJson @('api', "repos/$Repository/git/ref/heads/main")).object.sha
    $branchSha = Get-DemoBranchSha
    if ($PSCmdlet.ShouldProcess("$Repository $tag", "Create immutable baseline tag at main $mainSha")) {
        $null = Invoke-GitHub @('api', '--method', 'POST', "repos/$Repository/git/refs", '-f', "ref=refs/tags/$tag", '-f', "sha=$mainSha")
        if (-not $branchSha) {
            $null = Invoke-GitHub @('api', '--method', 'POST', "repos/$Repository/git/refs",
                '-f', "ref=refs/heads/$demoBranch", '-f', "sha=$mainSha")
        }
    }
    [PSCustomObject]@{
        BaselineTag  = $tag
        Commit       = $mainSha
        DemoBranch   = if ($branchSha) { "exists; run Reset -BaselineTag $tag to move it" } else { 'created at the tag' }
    }
}

function Invoke-Reset {
    $baseline = Resolve-BaselineCommit $BaselineTag
    $pulls = Get-DemoPullRequest
    $openPulls = @($pulls | Where-Object { $_.state -ceq 'open' })
    $branches = Select-CopilotHeadBranch $pulls -Exclude (Get-ProtectedHeadBranch)
    $issues = Get-DemoIssue
    $note = "Closed by the checkout demo reset to ``$BaselineTag``."
    if (-not $PSCmdlet.ShouldProcess("$Repository $demoBranch",
            "Close $($openPulls.Count) pull requests and $($issues.Count) issues, delete $($branches.Count) copilot branches, reset to $BaselineTag")) {
        return
    }
    foreach ($pull in $openPulls) {
        $null = Invoke-GitHub @('api', '--method', 'POST', "repos/$Repository/issues/$($pull.number)/comments", '-f', "body=$note")
        $null = Invoke-GitHub @('api', '--method', 'PATCH', "repos/$Repository/pulls/$($pull.number)", '-f', 'state=closed')
    }
    foreach ($branch in $branches) {
        $null = Invoke-GitHub @('api', '--method', 'DELETE', "repos/$Repository/git/refs/heads/$branch") -AllowMissing
    }
    foreach ($issue in $issues) {
        $null = Invoke-GitHub @('api', '--method', 'POST', "repos/$Repository/issues/$($issue.number)/comments", '-f', "body=$note")
        $null = Invoke-GitHub @('api', '--method', 'PATCH', "repos/$Repository/issues/$($issue.number)",
            '-f', 'state=closed', '-f', 'state_reason=not_planned')
    }
    if (Get-DemoBranchSha) {
        $null = Invoke-GitHub @('api', '--method', 'PATCH', "repos/$Repository/git/refs/heads/$demoBranch",
            '-f', "sha=$baseline", '-F', 'force=true')
    } else {
        $null = Invoke-GitHub @('api', '--method', 'POST', "repos/$Repository/git/refs",
            '-f', "ref=refs/heads/$demoBranch", '-f', "sha=$baseline")
    }
    $after = Get-DemoBranchSha
    if ($after -cne $baseline) { throw "$demoBranch did not move to $BaselineTag." }
    if ($Redeploy) {
        $null = Invoke-GitHub @('workflow', 'run', $deployWorkflow, '--repo', $Repository, '--ref', $demoBranch)
    }
    $summary = [PSCustomObject]@{
        BaselineTag       = $BaselineTag
        DemoBranchCommit  = $after
        ClosedPulls       = @($openPulls | ForEach-Object { $_.number })
        ClosedIssues      = @($issues | ForEach-Object { $_.number })
        DeletedBranches   = $branches
        RedeployRequested = [bool]$Redeploy
        NextStep          = 'Approve the Checkout Routes Deploy run if requested, then run Invoke-CheckoutDemo.ps1 Ready locally.'
    }
    if ($env:GITHUB_STEP_SUMMARY) {
        Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value (@(
                "### Checkout demo reset to ``$BaselineTag``", '',
                "- ``$demoBranch`` at ``$after``",
                "- Closed pull requests: $(@($summary.ClosedPulls) -join ', ')",
                "- Closed issues: $(@($summary.ClosedIssues) -join ', ')",
                "- Deleted branches: $(@($branches) -join ', ')",
                "- Redeploy requested: $([bool]$Redeploy)") -join "`n")
    }
    return $summary
}

function Invoke-Check {
    $baseline = Resolve-BaselineCommit $BaselineTag
    $branchSha = Get-DemoBranchSha
    $openPulls = @(Get-DemoPullRequest | Where-Object { $_.state -ceq 'open' })
    $issues = Get-DemoIssue
    $environment = Invoke-GitHub @('api', "repos/$Repository/environments/$resetEnvironment") -AllowMissing
    $secrets = if ($environment) {
        @((Invoke-GitHub @('secret', 'list', '--repo', $Repository, '--env', $resetEnvironment, '--json', 'name') | ConvertFrom-Json).name)
    } else { @() }
    [PSCustomObject]@{
        BranchAtBaseline = ($branchSha -ceq $baseline)
        OpenDemoPulls    = $openPulls.Count
        OpenDemoIssues   = $issues.Count
        ResetEnvironment = [bool]$environment
        ResetToken       = ($resetSecret -in $secrets)
    }
}

switch ($Action) {
    'Configure' { Invoke-Configure }
    'Baseline' { Invoke-Baseline }
    'Reset' { Invoke-Reset }
    'Check' { Invoke-Check }
}
