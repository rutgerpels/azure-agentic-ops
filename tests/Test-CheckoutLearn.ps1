#Requires -Version 7.2
# Offline contract checks for the SRE Agent portal-learning environment.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
function Assert-Test { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw "FAILED: $Message" } }

$scriptPath = Join-Path $repository 'scripts\Invoke-CheckoutLearn.ps1'
$parseErrors = $null
$null = [Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$parseErrors)
Assert-Test ($parseErrors.Count -eq 0) 'Learning lifecycle script must parse.'
$source = Get-Content -LiteralPath $scriptPath -Raw
Assert-Test ($source.Contains('infra\checkout-learn\main.bicep')) 'Up must deploy the standalone template.'
Assert-Test ($source.Contains("managedBy = 'invoke-checkoutlearn'")) 'Learning resources must carry their own owner.'
Assert-Test (-not $source.Contains('Set-SreConfiguration')) 'The learning lifecycle must not configure the SRE Agent.'

$template = Get-Content -LiteralPath (Join-Path $repository 'docs\agent-context\checkout-learn-investigator.md') -Raw
$known = 'ENVIRONMENT', 'WEB_APP', 'RESOURCE_GROUP', 'VM', 'APP_INSIGHTS', 'WORKSPACE_ID', 'WORKSPACE_GUID', 'SUBSCRIPTION'
foreach ($match in [regex]::Matches($template, '\{\{([A-Z_]+)\}\}')) {
    Assert-Test ($known -contains $match.Groups[1].Value) "Unknown placeholder $($match.Value)."
}
Assert-Test ($template.Contains('RunAzCliWriteCommands')) 'Instructions must request native approval for the rollback.'
Assert-Test ($template.Contains('PRICE_ROUTE_BE=primary')) 'Instructions must name the exact rollback.'

$bicep = Get-Content -LiteralPath (Join-Path $repository 'infra\checkout-learn\estate.bicep') -Raw
Assert-Test ($bicep -notmatch 'Microsoft.App/agents|observabilityAgents') 'Learning estate must not contain agents.'
'Checkout learning environment contract tests passed.'
