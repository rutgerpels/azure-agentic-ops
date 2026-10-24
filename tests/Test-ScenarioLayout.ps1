#Requires -Version 7.2
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$scenarioRoot = Join-Path $repositoryRoot 'scenarios\retailx'
$script:checks = 0

function Assert-Test {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    $script:checks++
}

function Get-LifecyclePath {
    param([string]$Path)
    $scriptDirectory = "'" + (Split-Path -Parent $Path).Replace("'", "''") + "'"
    $EnvironmentName = 'layout01'
    $repository = ''
    $repositoryRoot = ''
    $stateDirectory = ''
    $directory = ''
    $statePath = ''
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errors)
    if ($errors) { throw "Cannot parse lifecycle: $Path" }
    foreach ($statement in $ast.EndBlock.Statements) {
        if ($statement -is [Management.Automation.Language.AssignmentStatementAst] -and
            $statement.Left.Extent.Text -in @('$repository', '$repositoryRoot', '$stateDirectory', '$directory', '$statePath')) {
            . ([scriptblock]::Create($statement.Extent.Text.Replace('$PSScriptRoot', $scriptDirectory)))
        }
        if ($statement -is [Management.Automation.Language.PipelineAst] -and
            $statement.Extent.Text.StartsWith('Import-Module ')) {
            . ([scriptblock]::Create($statement.Extent.Text.Replace('$PSScriptRoot', $scriptDirectory)))
        }
    }
    return @{ root = $repositoryRoot; state = $statePath }
}

$stateFiles = @{
    'Invoke-CheckoutDemo.ps1' = 'checkout-state.json'
    'Invoke-IncidentAgent.ps1' = 'incident-agent-ownership.json'
    'Invoke-CheckoutDeployIdentity.ps1' = 'checkout-deploy-state.json'
    'Invoke-CopilotCloudAgent.ps1' = 'copilot-agent-state.json'
}
Push-Location ([IO.Path]::GetTempPath())
try {
    foreach ($entry in $stateFiles.GetEnumerator()) {
        $paths = Get-LifecyclePath (Join-Path $scenarioRoot "scripts\$($entry.Key)")
        Assert-Test ($paths.root -eq $repositoryRoot) "$($entry.Key) must resolve the real repository root independently of cwd."
        $expected = Join-Path $repositoryRoot ".azure\layout01\$($entry.Value)"
        Assert-Test ($paths.state -eq $expected) "$($entry.Key) must retain its existing ownership-state path."
    }
} finally { Pop-Location }

$sync = Join-Path $scenarioRoot 'scripts\Sync-CheckoutRoutes.ps1'
$ast = [Management.Automation.Language.Parser]::ParseFile($sync, [ref]$null, [ref]$null)
$routeParameter = $ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'RoutesPath' }
$routes = & {
    $scriptDirectory = "'" + (Split-Path -Parent $sync).Replace("'", "''") + "'"
    . ([scriptblock]::Create($routeParameter.DefaultValue.Extent.Text.Replace('$PSScriptRoot', $scriptDirectory)))
}
Assert-Test (Test-Path -LiteralPath $routes) 'Route sync must resolve the declared file after relocation.'

$incident = Get-Content (Join-Path $scenarioRoot 'scripts\Invoke-IncidentAgent.ps1') -Raw
Assert-Test ($incident.Contains('Join-Path $repositoryRoot ".azure\$Name\checkout-state.json"')) `
    'The assistant must attach using the same repository-root checkout manifest.'
[pscustomobject]@{ checks = $script:checks; result = 'Passed (paths and shared imports only; no cloud calls)' }
