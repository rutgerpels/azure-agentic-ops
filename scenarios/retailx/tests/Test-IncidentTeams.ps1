#Requires -Version 7.2
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
$script:checks = 0
function Assert-Test {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    $script:checks++
}
function Assert-Throws {
    param([scriptblock]$Operation, [string]$Message)
    $threw = $false
    try { $null = & $Operation } catch { $threw = $true }
    Assert-Test $threw $Message
}

$entry = Join-Path $repository 'scripts\Invoke-IncidentAgent.ps1'
$helper = Join-Path $repository 'scripts\incident\Teams.ps1'
$errors = $tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($entry, [ref]$tokens, [ref]$errors)
Assert-Test ($errors.Count -eq 0) 'Incident entry point must parse.'
$teamsAst = [System.Management.Automation.Language.Parser]::ParseFile($helper, [ref]$tokens, [ref]$errors)
Assert-Test ($errors.Count -eq 0) 'Teams helper must parse.'
. $helper
# Extract functions without running the executable script or reaching Azure.
foreach ($function in $ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
}, $true)) {
    . ([scriptblock]::Create($function.Extent.Text))
}

$EnvironmentName = 'assist01'
$subscription = '11111111-1111-4111-8111-111111111111'
$groupId = "/subscriptions/$subscription/resourceGroups/rg-retailtx-incident-assist01-swedencentral"
$webName = 'app-rtx-teams-assist01-abcdef'
$projectId = "$groupId/providers/Microsoft.CognitiveServices/accounts/aif-rtx-incident-assist01-abcdef/projects/incident"
$binding = @{
    webAppName = $webName; webAppId = "$groupId/providers/Microsoft.Web/sites/$webName"
    webAppUrl = "https://$webName.azurewebsites.net"; scmUrl = "https://$webName.scm.azurewebsites.net"
    botId = "$groupId/providers/Microsoft.BotService/botServices/bot-rtx-incident-assist01-abcdef"
    botIdentityId = "$groupId/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-retailtx-incident-assist01-teams"
    runtimePrincipalId = '22222222-2222-4222-8222-222222222222'
    botClientId = '33333333-3333-4333-8333-333333333333'
    runtimeAssignmentId = "$projectId/providers/Microsoft.Authorization/roleAssignments/44444444-4444-4444-8444-444444444444"
}
$script:state = @{
    nameSuffix = 'abcdef'; outputs = @{ teams = $binding; webAppName = 'browser' }
    teamsConfig = @{ enabled = $true; userId = $binding.runtimePrincipalId; packageId = $binding.botClientId }
}
Assert-IncidentTeamsState $script:state
Assert-Test ((Get-IncidentHostOutputs).webAppName -ceq 'browser') 'Existing host selection must remain browser-first.'
Assert-Test ((Get-IncidentHostOutputs -Teams).webAppName -ceq $webName) 'Teams jobs must select only the recorded host.'
foreach ($key in @('botId', 'botIdentityId', 'runtimeAssignmentId', 'webAppId', 'scmUrl', 'botClientId')) {
    $bad = $binding.Clone()
    $bad[$key] = 'https://unowned.example/'
    $script:state.outputs.teams = $bad
    Assert-Throws { Assert-IncidentTeamsState $script:state } "Reject drifted $key before deployment or cleanup."
}
$script:state.outputs.teams = $binding
$script:state.teamsResources = $binding.Clone()
$script:state.outputs.teams = @{}
Assert-IncidentTeamsState $script:state
Assert-Test ($script:state.teamsResources.webAppId -ceq $binding.webAppId) 'Scoped cleanup bindings must survive disabled output replacement.'
$script:state = @{ outputs = @{}; nameSuffix = 'abcdef' }
Assert-IncidentTeamsState $script:state
Assert-Throws { Get-IncidentHostOutputs -Teams } 'Legacy manifests must not invent a Teams host.'
Assert-Throws { Invoke-IncidentRequest 'https://unowned.example/api' } 'Control requests must not send Azure tokens to unowned hosts.'

$compiled = & az bicep build --file (Join-Path $repository 'infra\incident\main.bicep') --stdout
if ($LASTEXITCODE -ne 0) { throw 'Incident Bicep compilation failed.' }
$template = $compiled -join "`n" | ConvertFrom-Json -AsHashtable
Assert-Test ($template.parameters.enableTeams.defaultValue -eq $false) 'Existing deployments must not enable Teams implicitly.'
$teamsDeployment = @($template.resources | Where-Object { $_.name -ceq 'incident-teams-host' })[0]
Assert-Test ($teamsDeployment.condition -ceq "[parameters('enableTeams')]") 'The new host must remain opt-in.'
$teamsTemplate = $teamsDeployment.properties.template
$web = @($teamsTemplate.resources | Where-Object { $_.type -ceq 'Microsoft.Web/sites' })[0]
Assert-Test ($web.properties.siteConfig.appCommandLine -ceq 'python teams_server.py' -and
    $web.properties.siteConfig.numberOfWorkers -eq 1 -and $web.properties.httpsOnly) 'Teams must have a separate, single-worker HTTPS host.'
$auth = @($teamsTemplate.resources | Where-Object { $_.name.Contains("'authsettingsV2'") })[0]
Assert-Test (-not $auth.properties.platform.enabled) 'Only the isolated channel host uses SDK authentication.'
$bot = @($teamsTemplate.resources | Where-Object { $_.type -ceq 'Microsoft.BotService/botServices' })[0]
Assert-Test ($bot.properties.msaAppType -ceq 'UserAssignedMSI' -and $bot.properties.disableLocalAuth) 'The bot must use managed identity with local auth disabled.'
Assert-Test ($bot.properties.endpoint.Contains('/api/messages')) 'Bot endpoint must bind to its own channel route.'
$plan = @($template.resources | Where-Object { $_.type -ceq 'Microsoft.Web/serverfarms' })[0]
Assert-Test ($plan.sku.capacity -eq 1) 'Receipt locking requires one plan instance.'
$browserAuth = @($template.resources | Where-Object { $_.name.Contains("'authsettingsV2'") })[0]
Assert-Test ($browserAuth.properties.platform.enabled -and
    @($browserAuth.properties.globalValidation.excludedPaths).Count -eq 1 -and
    $browserAuth.properties.globalValidation.excludedPaths[0] -ceq '/health/live') 'Browser authentication must never exempt Teams messages.'
$account = @($template.resources | Where-Object { $_.type -ceq 'Microsoft.CognitiveServices/accounts' })[0]
Assert-Test ($account.properties.networkAcls.ipRules.Contains('union(') -and
    $account.properties.networkAcls.ipRules.Contains("parameters('enableTeams')")) 'Foundry must use the enabled-host outbound-IP union.'
$teamsSettings = @($template.resources | Where-Object {
    $_.type -ceq 'Microsoft.Web/sites/config' -and $_.ContainsKey('condition') -and
    $_.properties.ContainsKey('TEAMS_BOT_CLIENT_ID')
})[0]
Assert-Test ($teamsSettings.properties.DEMO_EVIDENCE_MODE -ceq 'fixture' -and
    -not $teamsSettings.properties.ContainsKey('CHECKOUT_WORKSPACE_ID')) 'Teams must not inherit browser live evidence.'
$source = Get-Content -LiteralPath $entry -Raw
Assert-Test ($source.Contains('enableTeams = [bool]') -and $source.Contains('teamsAllowedObjectId = if')) 'Regular Up must preserve recorded Teams enablement and member admission.'
Assert-Test ($source.Contains('Set-IncidentTeamsRun') -and $source.Contains('Publish-IncidentTeams')) 'Reset and Up must include the enabled Teams surface.'

# Exercise the real readiness predicate with case-sensitive ARM response dictionaries.
$secretlessCheck = @($teamsAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.HashtableAst]
}, $true) | ForEach-Object { $_.KeyValuePairs } |
    Where-Object { $_.Item1.Extent.Text -ceq 'secretlessBot' })
Assert-Test ($secretlessCheck.Count -eq 1) 'The actual secretless-bot readiness predicate must be selected.'
$secretlessProbe = [scriptblock]::Create($secretlessCheck[0].Item2.Extent.Text)
$hostOutputs = $binding
$tenant = '55555555-5555-4555-8555-555555555555'
$bot = @{ properties = @{
    msaAppType = 'UserAssignedMSI'; msaAppId = $binding.botClientId; msaAppTenantId = $tenant
    msaAppMSIResourceId = $binding.botIdentityId; disableLocalAuth = $true
} }
$identity = @{ properties = @{ clientId = $binding.botClientId } }
$settings = @{ properties = @{ TEAMS_BOT_CLIENT_ID = $binding.botClientId } }
foreach ($identityKey in @($binding.botIdentityId, $binding.botIdentityId.ToLowerInvariant(),
    "$($binding.botIdentityId)-unowned")) {
    $attached = @{ $identityKey = @{} } | ConvertTo-Json -Compress | ConvertFrom-Json -AsHashtable
    $web = @{ identity = @{ userAssignedIdentities = $attached } }
    Assert-Test ((& $secretlessProbe) -eq ($identityKey -ieq $binding.botIdentityId)) 'Readiness must tolerate ARM resource-ID casing, but reject another attached identity.'
}
$web.identity.userAssignedIdentities = @{}
Assert-Test (-not (& $secretlessProbe)) 'Readiness must reject a missing bot identity attachment.'
$web.identity.userAssignedIdentities = @{ $binding.botIdentityId = @{} }
$bot.properties.disableLocalAuth = $false
Assert-Test (-not (& $secretlessProbe)) 'Case-insensitive identity matching must not relax the local-auth requirement.'

# Execute the real Up clause and Teams publisher with all cloud operations replaced.
$script:calls = [Collections.Generic.List[string]]::new()
$script:pinnedVersion = ''
$script:state = @{
    outputs = @{ teams = $binding }; agentVersion = '1'; agentEndpointVersion = '1'
    teamsConfig = @{ enabled = $true }
}
$groupName = 'owned-offline-test'
$directory = Join-Path ([IO.Path]::GetTempPath()) "retailx-teams-test-$([guid]::NewGuid().ToString('N'))"
$null = New-Item -ItemType Directory -Path $directory
function Initialize-IncidentPlatform { $script:calls.Add('platform') }
function Publish-IncidentApplication {
    $script:calls.Add('browser-bootstrap')
    $script:state.agentVersion = '2'
    $script:state.agentEndpointVersion = '2'
}
function Set-IncidentTeamsSettings {
    param([hashtable]$Values)
    $script:pinnedVersion = $Values.FOUNDRY_AGENT_VERSION
    $script:calls.Add('teams-pin')
}
function Invoke-IncidentAzure {
    param([string[]]$Arguments, [int]$TimeoutSeconds)
    Assert-Test ($Arguments[0] -ceq 'webapp' -and $Arguments[1] -ceq 'deploy' -and
        $Arguments -contains $binding.webAppName) 'Publish must deploy only the selected Teams host.'
    $script:calls.Add('teams-deploy')
}
function Invoke-IncidentCloudJob {
    param([string]$Command, [switch]$Teams)
    Assert-Test ($Command -ceq 'test' -and $Teams) 'Teams publisher must test the Teams container.'
    $script:calls.Add('teams-tests')
    return @{ pass = $true; testsRun = 1 }
}
function Save-IncidentState {}
function Wait-IncidentRuntime { param([switch]$Teams) }
function Test-IncidentTeamsReadiness {
    $script:calls.Add('teams-ready')
    return @{ ready = $true }
}
function Test-IncidentReadiness { throw 'Enabled Up must finish with both-host Teams readiness.' }
try {
    $switch = @($ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.SwitchStatementAst]
    }, $true) | Where-Object { $_.Condition.Extent.Text -ceq '$Action' })[0]
    $clause = @($switch.Clauses | Where-Object { $_.Item1.Extent.Text -ceq "'Up'" })[0]
    $body = ($clause.Item2.Statements | ForEach-Object { $_.Extent.Text }) -join "`n"
    $result = & ([scriptblock]::Create($body))
    Assert-Test ($result.ready -eq $true) 'Up must return successful readiness only after the enabled Teams check.'
    Assert-Test ($script:pinnedVersion -ceq '2') 'Teams must receive the new browser-bootstrap agent version, not the ARM deployment previous version.'
    Assert-Test (($script:calls -join ',') -ceq 'platform,browser-bootstrap,teams-pin,teams-deploy,teams-tests,teams-ready') 'Up must synchronize Teams before deployment/testing and finish with Teams readiness.'
} finally {
    Remove-Item -LiteralPath $directory -Force
}
[pscustomobject]@{ checks = $script:checks; result = 'Passed (offline lifecycle and compiled infrastructure contracts; no deployment)' }
