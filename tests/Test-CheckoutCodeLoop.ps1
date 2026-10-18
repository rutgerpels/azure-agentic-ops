#Requires -Version 7.2
[CmdletBinding(SupportsShouldProcess)]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$script:checks = 0
function Assert-Test {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    $script:checks++
}
function Assert-Rejected {
    param([scriptblock]$Action, [string]$Message)
    $failure = $null
    try { $null = & $Action } catch { $failure = $_ }
    Assert-Test ($null -ne $failure -and $failure.Exception.Message -like "*$Message*") "Expected rejection: $Message; got $failure"
}
function Get-ScriptFunction {
    <# Return function definitions; the caller dot-sources them at script scope. #>
    param([string]$Path)
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$parseErrors)
    if ($parseErrors) { throw "$Path has syntax errors." }
    $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false) |
        ForEach-Object { [scriptblock]::Create($_.Extent.Text) }
}

# ---------- Declared routes and drift ----------
foreach ($definition in Get-ScriptFunction (Join-Path $repoRoot 'scripts\Sync-CheckoutRoutes.ps1')) { . $definition }
$routeKeys = @('PRICE_ROUTE_BE', 'PRICE_ROUTE_NL', 'ROUTE_CHANGE_REF')
$SubscriptionId = [guid]'11111111-1111-1111-1111-111111111111'
$ResourceGroup = 'rg-test'
$WebAppName = 'app-test'
$declared = Read-DeclaredRoute (Join-Path $repoRoot 'infra\checkout\price-routes.json')
Assert-Test ($declared.PRICE_ROUTE_BE -ceq 'primary' -and $declared.PRICE_ROUTE_NL -ceq 'primary' -and
    $declared.ROUTE_CHANGE_REF -ceq 'baseline') 'Committed routes must match the fault baseline.'
$bicep = Get-Content (Join-Path $repoRoot 'infra\checkout\checkout.bicep') -Raw
Assert-Test ($bicep -like "*loadJsonContent('price-routes.json')*" -and $bicep -notmatch "name: 'PRICE_ROUTE_BE', value: '") 'Bicep must load the declared routes.'
$temp = New-TemporaryFile
try {
    foreach ($case in @(
            @{ json = '{"PRICE_ROUTE_BE":"primary","PRICE_ROUTE_NL":"primary"}'; message = 'exactly' }
            @{ json = '{"PRICE_ROUTE_BE":"primary","PRICE_ROUTE_NL":"primary","ROUTE_CHANGE_REF":"x","EXTRA":"1"}'; message = 'exactly' }
            @{ json = '{"PRICE_ROUTE_BE":"fast","PRICE_ROUTE_NL":"primary","ROUTE_CHANGE_REF":"x"}'; message = 'PRICE_ROUTE_BE' }
            @{ json = '{"PRICE_ROUTE_BE":"primary","PRICE_ROUTE_NL":"primary","ROUTE_CHANGE_REF":"a b;rm"}'; message = 'ROUTE_CHANGE_REF' }
            @{ json = '["primary"]'; message = 'JSON object' })) {
        Set-Content -LiteralPath $temp -Value $case.json
        Assert-Rejected { Read-DeclaredRoute $temp } $case.message
    }
} finally { Remove-Item -LiteralPath $temp -Force }

$script:azCalls = @()
function Invoke-RetailAzure {
    param($SubscriptionId, [string[]]$Arguments)
    $script:azCalls += , $Arguments
    return @(@{ name = 'PRICE_ROUTE_BE'; value = 'legacy' }, @{ name = 'PRICE_ROUTE_NL'; value = 'primary' })
}
$live = Get-LiveRoute
$query = $script:azCalls[0][[array]::IndexOf($script:azCalls[0], '--query') + 1]
Assert-Test ($query -like "*name=='PRICE_ROUTE_BE'*" -and $query -notlike '*APPLICATIONINSIGHTS*' -and $query -like '*{name:name,value:value}*') 'Only route keys may be read.'
$drift = Get-RouteDrift $declared $live
Assert-Test ((@($drift) -join ',') -ceq 'PRICE_ROUTE_BE,ROUTE_CHANGE_REF') 'Changed and missing route keys are drift.'
Assert-Test (@(Get-RouteDrift $declared @{ PRICE_ROUTE_BE = 'primary'; PRICE_ROUTE_NL = 'primary'; ROUTE_CHANGE_REF = 'baseline' }).Count -eq 0) 'Matching routes have no drift.'

# ---------- Demo repository reset ----------
foreach ($definition in Get-ScriptFunction (Join-Path $repoRoot 'scripts\Invoke-CheckoutDemoRepo.ps1')) { . $definition }
$Repository = 'owner/repo'
$demoBranch = 'demo/checkout'
$demoLabel = 'checkout-demo'
$tagPrefix = 'demo-baseline/checkout-v'
$deployWorkflow = 'checkout-deploy.yml'
$BaselineTag = 'demo-baseline/checkout-v1'
$Redeploy = [switch]$true
$tagSha = 'a' * 40
$script:compareStatus = 'ahead'
$script:tagType = 'commit'
$script:branchSha = 'b' * 40
$script:ghWrites = @()
$pulls = @(
    @{ number = 7; state = 'open'; base = @{ ref = 'demo/checkout' }; head = @{ ref = 'copilot/fix-drift'; repo = @{ full_name = 'owner/repo' } } }
    @{ number = 8; state = 'closed'; base = @{ ref = 'demo/checkout' }; head = @{ ref = 'copilot/old'; repo = @{ full_name = 'owner/repo' } } }
    @{ number = 9; state = 'open'; base = @{ ref = 'demo/checkout' }; head = @{ ref = 'feature/human'; repo = @{ full_name = 'owner/repo' } } }
    @{ number = 10; state = 'open'; base = @{ ref = 'demo/checkout' }; head = @{ ref = 'copilot/fork'; repo = @{ full_name = 'someone/fork' } } }
    @{ number = 11; state = 'open'; base = @{ ref = 'main' }; head = @{ ref = 'copilot/main-work'; repo = @{ full_name = 'owner/repo' } } }
    @{ number = 12; state = 'closed'; base = @{ ref = 'demo/checkout' }; head = @{ ref = 'copilot/reused'; repo = @{ full_name = 'owner/repo' } } }
    @{ number = 13; state = 'open'; base = @{ ref = 'main' }; head = @{ ref = 'copilot/reused'; repo = @{ full_name = 'owner/repo' } } })
function Invoke-GitHub {
    param([string[]]$Arguments, [string]$InputText, [switch]$AllowMissing)
    $path = @($Arguments | Where-Object { $_ -like 'repos/*' }) + @('') | Select-Object -First 1
    if ($Arguments -contains '--method' -or $Arguments[0] -ceq 'workflow') {
        $script:ghWrites += ($Arguments -join ' ')
        if ($path -ceq "repos/owner/repo/git/refs/heads/$demoBranch") { $script:branchSha = $tagSha }
        return '{}'
    }
    switch -Wildcard ($path) {
        'repos/owner/repo/git/ref/tags/*' { return (@{ object = @{ type = $script:tagType; sha = $tagSha } } | ConvertTo-Json -Depth 5) }
        'repos/owner/repo/compare/*' { return (@{ status = $script:compareStatus } | ConvertTo-Json) }
        'repos/owner/repo/pulls?*' { return (ConvertTo-Json -InputObject @(, $script:pulls) -Depth 6) }
        'repos/owner/repo/issues?*' {
            return (ConvertTo-Json -InputObject @(, @(@{ number = 3 }, @{ number = 7; pull_request = @{} })) -Depth 5)
        }
        'repos/owner/repo/git/ref/heads/*' { return (@{ object = @{ sha = $script:branchSha } } | ConvertTo-Json) }
        default { throw "Unexpected gh mock call: $($Arguments -join ' ')" }
    }
}

Assert-Rejected { Assert-BaselineTag 'v1' } 'demo-baseline'
Assert-Rejected { Assert-BaselineTag 'demo-baseline/checkout-v1;x' } 'demo-baseline'
$script:compareStatus = 'diverged'
Assert-Rejected { Resolve-BaselineCommit $BaselineTag } 'not an ancestor of main'
$script:compareStatus = 'ahead'
$script:tagType = 'tag'
Assert-Rejected { Resolve-BaselineCommit $BaselineTag } 'lightweight'
$script:tagType = 'commit'
Assert-Test ((Get-ProtectedHeadBranch) -join ',' -ceq 'copilot/main-work,copilot/reused') 'Open pull requests into other bases protect their heads.'
Assert-Test ((Select-CopilotHeadBranch $pulls -Exclude (Get-ProtectedHeadBranch)) -join ',' -ceq 'copilot/fix-drift,copilot/old') 'Only same-repo copilot branches into demo/checkout may be deleted.'
Assert-Test ((@(Get-DemoIssue) | ForEach-Object { $_.number }) -join ',' -ceq '3') 'Pull requests must not be treated as demo issues.'

$summary = Invoke-Reset
$writes = $script:ghWrites -join "`n"
Assert-Test ($summary.DemoBranchCommit -ceq $tagSha) 'demo/checkout must equal the baseline tag.'
Assert-Test ($writes -like "*PATCH repos/owner/repo/git/refs/heads/demo/checkout -f sha=$tagSha -F force=true*") 'Reset must force-move only demo/checkout.'
Assert-Test ($writes -notlike '*heads/main*' -and $writes -notlike '*feature/human*' -and $writes -notlike '*copilot/main-work*' -and
    $writes -notlike '*copilot/fork*' -and $writes -notlike '*copilot/reused*') 'Reset must not touch main or unrelated branches.'
Assert-Test ($writes -like '*DELETE repos/owner/repo/git/refs/heads/copilot/old*') 'Reset deletes merged or closed demo copilot branches.'
Assert-Test ($writes -like '*pulls/7 -f state=closed*' -and $writes -like '*pulls/9 -f state=closed*' -and $writes -notlike '*pulls/11*' -and
    $writes -notlike '*pulls/8 *') 'Reset closes only open pull requests into demo/checkout.'
Assert-Test ($writes -like '*issues/3 -f state=closed -f state_reason=not_planned*') 'Reset closes labelled demo issues.'
Assert-Test ($writes -like '*workflow run checkout-deploy.yml --repo owner/repo --ref demo/checkout*') 'Redeploy dispatches the gated deploy on demo/checkout.'

# ---------- Workflow guards ----------
$deploy = Get-Content (Join-Path $repoRoot '.github\workflows\checkout-deploy.yml') -Raw
$reset = Get-Content (Join-Path $repoRoot '.github\workflows\checkout-demo-reset.yml') -Raw
Assert-Test ($deploy -like "*if: github.ref == 'refs/heads/demo/checkout'*" -and $deploy -like '*environment: checkout-deploy*' -and
    $deploy -like '*persist-credentials: false*') 'Deploy must be gated to demo/checkout and its reviewer environment.'
Assert-Test ($reset -like "*if: github.ref == 'refs/heads/main'*" -and $reset -like '*environment: checkout-demo-reset*' -and
    $reset -notmatch '\$\{\{\s*inputs\.[a-z_]+\s*\}\}\s*`?\s*$' -and $reset -like '*BASELINE_TAG: ${{ inputs.baseline_tag }}*') 'Reset must run from main behind its environment, inputs via env only.'
foreach ($workflow in $deploy, $reset) {
    Assert-Test (-not ([regex]::Matches($workflow, 'uses:\s*[^\s@]+@(?![0-9a-f]{40}\b)\S+').Count)) 'Actions must be pinned to full commit SHAs.'
}
[pscustomobject]@{ checks = $script:checks; result = 'Passed (mocked Azure CLI and GitHub CLI only)' }
