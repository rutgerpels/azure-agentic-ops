#Requires -Version 7.2
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repository '..\..\scripts\Azure.Common.psm1') -Force
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
& {
    $sourceFunction = @($ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -ceq 'Get-CheckoutBindingSource'
    }, $true))[0]
    $conversion = @($sourceFunction.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left.Extent.Text -ceq '$created'
    }, $true))
    Assert-Test ($conversion.Count -eq 1) 'Checkout attachment must normalize one deployment generation.'
    $convertGeneration = [scriptblock]::Create($conversion[0].Extent.Text)
    $originalCulture = [Globalization.CultureInfo]::CurrentCulture
    try {
        foreach ($culture in @('en-US', 'nl-NL')) {
            [Globalization.CultureInfo]::CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo($culture)
            foreach ($stamp in @('2026-10-25T16:05:40Z', '2026-10-25T18:05:40+02:00')) {
                $checkout = "{`"createdAtUtc`":`"$stamp`"}" | ConvertFrom-Json -AsHashtable
                . $convertGeneration
                Assert-Test ($created.UtcDateTime.ToString('o') -ceq '2026-10-25T16:05:40.0000000Z') `
                    'Typed JSON timestamps must retain their instant independently of presenter culture.'
                $parsed = ConvertFrom-IncidentJson "{`"createdAtUtc`":`"$stamp`",`"properties`":{`"CHECKOUT_CREATED_AT`":`"$stamp`"}}"
                if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) {
                    Assert-Test ($parsed.createdAtUtc -is [string] -and $parsed.createdAtUtc -ceq $stamp -and
                        $parsed.properties.CHECKOUT_CREATED_AT -is [string] -and
                        $parsed.properties.CHECKOUT_CREATED_AT -ceq $stamp) `
                        'Ownership and app-setting JSON must preserve timestamp strings on PowerShell 7.5+.'
                }
            }
        }
        $checkout = @{ createdAtUtc = 'invalid' }
        Assert-Throws { . $convertGeneration } 'An invalid deployment generation must still fail closed.'
        Assert-Throws { ConvertFrom-IncidentJson 'not-json' } 'Invalid control-plane JSON must still fail explicitly.'
    } finally {
        [Globalization.CultureInfo]::CurrentCulture = $originalCulture
    }
}
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
    $account.properties.networkAcls.ipRules.Contains("parameters('enableTeams')") -and
    $account.properties.networkAcls.ipRules.Contains('.possibleOutboundIpAddresses') -and
    $account.properties.networkAcls.ipRules.Contains('.possibleOutboundIps') -and
    -not $account.properties.networkAcls.ipRules.Contains('.outboundIpAddresses')) 'Foundry must use the enabled-host possible-egress union, never the current subset.'
Assert-Test ($teamsTemplate.outputs.possibleOutboundIps.value.Contains('.possibleOutboundIpAddresses') -and
    -not $teamsTemplate.outputs.possibleOutboundIps.value.Contains('.outboundIpAddresses')) 'Teams must publish its complete possible-egress pool without a current-IP fallback.'
Assert-Test ($account.properties.disableLocalAuth -and
    $account.properties.networkAcls.defaultAction -ceq 'Deny' -and
    @($account.properties.networkAcls.virtualNetworkRules).Count -eq 0) 'The expanded exact-IP pool must not relax authentication or default-deny networking.'
$teamsSettings = @($template.resources | Where-Object {
    $_.type -ceq 'Microsoft.Web/sites/config' -and $_.ContainsKey('condition') -and
    $_.properties.ContainsKey('TEAMS_BOT_CLIENT_ID')
})[0]
Assert-Test ($template.parameters.teamsEvidenceMode.defaultValue -ceq 'fixture' -and
    $teamsSettings.properties.DEMO_EVIDENCE_MODE -ceq "[parameters('teamsEvidenceMode')]" -and
    $teamsSettings.properties.CHECKOUT_WORKSPACE_ID -ceq "[parameters('teamsCheckoutWorkspaceId')]" -and
    $teamsSettings.properties.CHECKOUT_OWNER_TOKEN -ceq "[parameters('teamsCheckoutOwnerToken')]") 'Teams must default to fixtures and use independent explicit checkout parameters.'
$source = Get-Content -LiteralPath $entry -Raw
Assert-Test ($source.Contains('enableTeams = [bool]') -and $source.Contains('teamsAllowedObjectId = if')) 'Regular Up must preserve recorded Teams enablement and member admission.'
Assert-Test ($source.Contains('Set-IncidentTeamsRun') -and $source.Contains('Publish-IncidentTeams')) 'Reset and Up must include the enabled Teams surface.'

& {
    $browser = @{ properties = @{
        outboundIpAddresses = '192.0.2.1'
        possibleOutboundIpAddresses = '192.0.2.1,192.0.2.2'
    } }
    $teams = @{ properties = @{
        outboundIpAddresses = '192.0.2.1'
        possibleOutboundIpAddresses = '192.0.2.1,198.51.100.2'
    } }
    $foundry = @{ properties = @{ networkAcls = @{
        defaultAction = 'Deny'; virtualNetworkRules = @()
        ipRules = @(@{ value = '192.0.2.1' })
    } } }
    Assert-Test (-not (Test-IncidentModelNetwork -Foundry $foundry -Hosts @($browser, $teams))) 'Allowlisting every current IP is insufficient when the possible pools contain more addresses.'
    $foundry.properties.networkAcls.ipRules += @{ value = '192.0.2.2' }
    Assert-Test (Test-IncidentModelNetwork -Foundry $foundry -Hosts @($browser)) 'Browser-only deployments must require only the browser possible pool.'
    Assert-Test (-not (Test-IncidentModelNetwork -Foundry $foundry -Hosts @($browser, $teams))) 'The enabled Teams host must contribute its own possible pool.'
    $foundry.properties.networkAcls.ipRules += @{ value = '198.51.100.2' }
    Assert-Test (Test-IncidentModelNetwork -Foundry $foundry -Hosts @($browser, $teams)) 'Both-host readiness must accept the exact union, including overlapping addresses.'
    Assert-Test (-not (Test-IncidentModelNetwork -Foundry $foundry -Hosts @($browser))) 'Disabled-host addresses must not remain as unexplained extra access.'
    foreach ($extra in @('203.0.113.5', '0.0.0.0/0', '192.0.2.0/24')) {
        $foundry.properties.networkAcls.ipRules += @{ value = $extra }
        Assert-Test (-not (Test-IncidentModelNetwork -Foundry $foundry -Hosts @($browser, $teams))) 'An extra address or broader CIDR must fail exact-pool readiness.'
        $foundry.properties.networkAcls.ipRules = @($foundry.properties.networkAcls.ipRules |
            Where-Object { $_.value -cne $extra })
    }
    foreach ($invalid in @($null, '', ' ', '192.0.2.1,', '192.0.2.1,garbage',
        '192.0.2.0/24', '::1', '999.0.0.1', '192.0.2.01')) {
        $teams.properties.possibleOutboundIpAddresses = $invalid
        $result = @(Test-IncidentModelNetwork -Foundry $foundry -Hosts @($browser, $teams))
        Assert-Test ($result.Count -eq 1 -and $result[0] -ceq $false) 'Absent or invalid possible-egress data must produce exactly one failed predicate, never a current-IP fallback.'
    }
    $teams.properties.Remove('possibleOutboundIpAddresses')
    Assert-Test (-not (Test-IncidentModelNetwork -Foundry $foundry -Hosts @($browser, $teams))) 'A missing possible-egress property must fail closed.'
    $teams.properties.possibleOutboundIpAddresses = '192.0.2.1,198.51.100.2'
    $foundry.properties.networkAcls.defaultAction = 'Allow'
    Assert-Test (-not (Test-IncidentModelNetwork -Foundry $foundry -Hosts @($browser, $teams))) 'Matching IPs must never hide an allow-by-default firewall.'
    $foundry.properties.networkAcls.defaultAction = 'Deny'
    $foundry.properties.networkAcls.virtualNetworkRules = @(@{ id = 'unexpected-subnet' })
    Assert-Test (-not (Test-IncidentModelNetwork -Foundry $foundry -Hosts @($browser, $teams))) 'Additional network admission rules must fail exact-pool readiness.'
    Assert-Test (-not (Test-IncidentModelNetwork -Foundry $foundry -Hosts @())) 'An absent host set must never pass readiness.'
}
$readinessAst = @($ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -ceq 'Test-IncidentReadiness'
}, $true))[0]
$readinessSource = $readinessAst.Extent.Text
Assert-Test ($readinessSource.Contains('Test-IncidentModelNetwork -Foundry $foundry -Hosts $networkHosts') -and
    $readinessSource.Contains('$networkHosts += $teamsWeb')) 'The shared browser/Teams readiness path must execute the tested exact-pool predicate.'
Assert-Test ($teamsAst.Extent.Text.Contains('$null = Test-IncidentReadiness')) 'Teams readiness must also enforce the common Foundry network contract.'
& {
    $statements = @($readinessAst.Body.EndBlock.Statements)
    $checksAssignment = @($statements | Where-Object { $_.Extent.Text.StartsWith('$checks = [ordered]@{') })
    $readyAssignment = @($statements | Where-Object { $_.Extent.Text.StartsWith('$ready = ') })
    Assert-Test ($checksAssignment.Count -eq 1 -and $readyAssignment.Count -eq 1) 'Select the actual readiness predicates and finalization.'
    $buildChecks = [scriptblock]::Create($checksAssignment[0].Extent.Text)
    $finishReadiness = [scriptblock]::Create((@($statements | Where-Object {
        $_.Extent.StartOffset -ge $readyAssignment[0].Extent.StartOffset
    } | ForEach-Object { $_.Extent.Text }) -join "`n"))
    $savedState = $script:state
    $directory = '.'
    $evidenceMode = 'fixture'
    $tenant = '55555555-5555-4555-8555-555555555555'
    $script:state = @{
        agentVersion = '2'; agentEndpointVersion = '2'; bootstrapAssignmentId = ''
        applicationClientId = 'browser-client'; operatorId = 'operator'
        ownerToken = 'owned'; runId = 'current'
        outputs = @{ runtimePrincipalId = 'runtime'; authIdentityClientId = 'sign-in'
            webAppUrl = 'https://synthetic.example/' }
    }
    $app = @{ passwordCredentials = @() }
    $web = @{ identity = @{ principalId = 'runtime' }; properties = @{ httpsOnly = $true } }
    $foundry = @{ properties = @{ disableLocalAuth = $true } }
    $auth = @{ properties = @{
        platform = @{ enabled = $true }
        globalValidation = @{ requireAuthentication = $true; excludedPaths = @('/health/live') }
        identityProviders = @{ azureActiveDirectory = @{
            registration = @{ clientId = 'browser-client'
                openIdIssuer = "https://login.microsoftonline.com/$tenant/v2.0"
                clientSecretSettingName = 'OVERRIDE_USE_MI_FIC_ASSERTION_CLIENTID' }
            validation = @{ defaultAuthorizationPolicy = @{ allowedPrincipals = @{ identities = @('operator') } } }
        } }
    } }
    $settings = @{ properties = @{
        FOUNDRY_AGENT_VERSION = '2'; OVERRIDE_USE_MI_FIC_ASSERTION_CLIENTID = 'sign-in'
        DEMO_OWNER_TOKEN = 'owned'; DEMO_RUN_ID = 'current'
    } }
    function Save-RetailState {
        param([hashtable]$State, [string]$Path)
        $script:retentionReadinessReceipt = $State
    }
    try {
        foreach ($deadline in @('2000-01-01T00:00:00Z', '2999-01-01T00:00:00Z', $null)) {
            if ($null -eq $deadline) { $script:state.Remove('expiresAtUtc') }
            else { $script:state.expiresAtUtc = $deadline }
            . $buildChecks
            Assert-Test (-not $checks.Contains('notExpired')) 'Retention must not be a readiness predicate.'
            $checks.modelNetworkRestricted = $true
            $checks.evidenceModeBound = $true
            $checks.checkoutGrantBound = $true
            $ready = & $finishReadiness
            Assert-Test ($ready.ready -and $script:retentionReadinessReceipt.ready) 'Past, future or absent informational retention must not block browser or inherited Teams readiness.'
            Assert-Test ($script:state['expiresAtUtc'] -ceq $deadline) 'Readiness must not rewrite retention metadata.'
        }
        $script:state.expiresAtUtc = '2000-01-01T00:00:00Z'
        foreach ($failure in @('pinnedAgent', 'runtimeIdentity', 'httpsOnly', 'tenantAdmission',
            'operatorAdmission', 'secretlessSignIn', 'modelKeysDisabled', 'exactRun',
            'bootstrapGrantRemoved', 'modelNetworkRestricted', 'evidenceModeBound', 'checkoutGrantBound')) {
            $script:state.agentEndpointVersion = if ($failure -ceq 'pinnedAgent') { 'old' } else { '2' }
            $web.identity.principalId = if ($failure -ceq 'runtimeIdentity') { 'other' } else { 'runtime' }
            $web.properties.httpsOnly = $failure -cne 'httpsOnly'
            $auth.properties.platform.enabled = $failure -cne 'tenantAdmission'
            $auth.properties.identityProviders.azureActiveDirectory.validation.defaultAuthorizationPolicy.allowedPrincipals.identities =
                if ($failure -ceq 'operatorAdmission') { @('other') } else { @('operator') }
            $app.passwordCredentials = if ($failure -ceq 'secretlessSignIn') { @('unexpected-secret') } else { @() }
            $foundry.properties.disableLocalAuth = $failure -cne 'modelKeysDisabled'
            $settings.properties.DEMO_RUN_ID = if ($failure -ceq 'exactRun') { 'other' } else { 'current' }
            $script:state.bootstrapAssignmentId = if ($failure -ceq 'bootstrapGrantRemoved') { 'pending' } else { '' }
            . $buildChecks
            foreach ($externalCheck in @('modelNetworkRestricted', 'evidenceModeBound', 'checkoutGrantBound')) {
                $checks[$externalCheck] = $failure -cne $externalCheck
            }
            Assert-Throws { & $finishReadiness } "Removing the retention gate must preserve $failure enforcement."
            Assert-Test (-not $script:retentionReadinessReceipt.ready -and
                -not $script:retentionReadinessReceipt.checks[$failure]) 'Rejected readiness must retain the actual failed predicate.'
        }
    } finally {
        $script:state = $savedState
    }
}
& {
    $statements = @($readinessAst.Body.EndBlock.Statements)
    $first = @($statements | Where-Object { $_.Extent.Text -ceq '$networkHosts = @($web)' })[0]
    $last = @($statements | Where-Object {
        $_.Extent.Text -ceq '$checks.modelNetworkRestricted = Test-IncidentModelNetwork -Foundry $foundry -Hosts $networkHosts'
    })[0]
    $networkBlock = [scriptblock]::Create((@($statements | Where-Object {
        $_.Extent.StartOffset -ge $first.Extent.StartOffset -and
        $_.Extent.EndOffset -le $last.Extent.EndOffset
    } | ForEach-Object { $_.Extent.Text }) -join "`n"))
    $savedState = $script:state
    $teamsReads = [Collections.Generic.List[string]]::new()
    $web = @{ properties = @{ possibleOutboundIpAddresses = '192.0.2.1' } }
    $foundry = @{ properties = @{ networkAcls = @{
        defaultAction = 'Deny'; virtualNetworkRules = @()
        ipRules = @(@{ value = '192.0.2.1' })
    } } }
    $checks = @{}
    function Get-IncidentHostOutputs {
        param([switch]$Teams)
        Assert-Test $Teams.IsPresent 'Network readiness must explicitly select the owned Teams host.'
        return @{ webAppId = '/synthetic/owned-teams-host' }
    }
    function Invoke-IncidentRequest {
        param([string]$Uri)
        $teamsReads.Add($Uri)
        return @{ properties = @{ possibleOutboundIpAddresses = '198.51.100.2' } }
    }
    try {
        foreach ($enabled in @($null, $false, $true)) {
            $script:state = if ($null -eq $enabled) { @{} } else { @{ teamsConfig = @{ enabled = $enabled } } }
            $teamsReads.Clear()
            . $networkBlock
            Assert-Test ($teamsReads.Count -eq [int][bool]$enabled) 'Disabled or absent Teams must not be fetched; enabled Teams must be read once.'
            Assert-Test ($checks.modelNetworkRestricted -eq (-not [bool]$enabled)) 'The executed readiness block must require Teams-only addresses exactly when Teams is enabled.'
        }
        $foundry.properties.networkAcls.ipRules += @{ value = '198.51.100.2' }
        . $networkBlock
        Assert-Test $checks.modelNetworkRestricted 'The executed enabled-host readiness block must accept the complete possible-pool union.'
    } finally {
        $script:state = $savedState
    }
}

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
$checkoutSettingNames = @($teamsSettings.properties.Keys | Where-Object { $_ -clike 'CHECKOUT_*' })

# Execute the production all-role readiness accounting, not the attachment's readiness stub.
& {
    $savedState = $script:state
    try {
        $roleChecks = @($teamsAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                $node.Left.Extent.Text -in @('$liveSre', '$sreUris', '$expectedCount',
                    '$checks.onlyExpectedAzureRoles')
        }, $true))
        Assert-Test ($roleChecks.Count -eq 4) 'Select the actual all-role readiness assignments.'
        $roleProbe = [scriptblock]::Create(($roleChecks.Extent.Text -join "`n"))
        $runtimeRole = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
        $logReaderRole = '73c42c96-874c-492b-b04d-ab87d138a893'
        $checkoutGroup = "/subscriptions/$subscription/resourceGroups/owned-checkout"
        $checkoutBinding = @{
            workspaceId = "$checkoutGroup/providers/Microsoft.OperationalInsights/workspaces/ops"
            sreAgentId = "$checkoutGroup/providers/Microsoft.App/agents/checkout"
            sreRoleId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
            sreReaderAssignmentId = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'
        }
        $script:state = @{
            outputs = @{ foundryProjectId = $projectId }
            teamsCheckoutBinding = $checkoutBinding
        }
        $foundryGrant = @{
            role = "/subscriptions/$subscription/providers/Microsoft.Authorization/roleDefinitions/$runtimeRole"
            scope = $projectId
        }
        $workspaceGrant = @{
            role = "/subscriptions/$subscription/providers/Microsoft.Authorization/roleDefinitions/$logReaderRole"
            scope = $checkoutBinding.workspaceId
        }
        $sreGrant = @{
            role = (Get-IncidentSreUris $checkoutBinding).roleId
            scope = $checkoutBinding.sreAgentId
        }
        $expectedEvidence = @{ DEMO_EVIDENCE_MODE = 'live' }
        $allGrants = @($foundryGrant, $workspaceGrant, $sreGrant)
        $checks = @{}
        . $roleProbe
        Assert-Test $checks.onlyExpectedAzureRoles 'Live SRE attachment must accept exactly the three owned runtime grants.'
        $sreGrant.scope = $checkoutGroup
        . $roleProbe
        Assert-Test (-not $checks.onlyExpectedAzureRoles) 'Reject the correct SRE role at a broader resource-group scope.'
        $sreGrant.scope = $checkoutBinding.sreAgentId
        $sreGrant.role = $foundryGrant.role
        . $roleProbe
        Assert-Test (-not $checks.onlyExpectedAzureRoles) 'Reject a different role at the owned SRE agent.'
        $allGrants = @($foundryGrant, $workspaceGrant)
        . $roleProbe
        Assert-Test (-not $checks.onlyExpectedAzureRoles) 'Reject a missing SRE grant for a new attachment.'
        $script:state.teamsCheckoutBinding = @{ workspaceId = $checkoutBinding.workspaceId }
        . $roleProbe
        Assert-Test $checks.onlyExpectedAzureRoles 'Legacy telemetry-only live bindings must retain the two-role expectation.'
        $allGrants += $sreGrant
        . $roleProbe
        Assert-Test (-not $checks.onlyExpectedAzureRoles) 'Legacy bindings must not allow an unrecorded third grant.'
        $expectedEvidence.DEMO_EVIDENCE_MODE = 'fixture'
        $allGrants = @($foundryGrant)
        . $roleProbe
        Assert-Test $checks.onlyExpectedAzureRoles 'Fixture mode must accept only the Foundry grant.'
        $allGrants += $workspaceGrant
        . $roleProbe
        Assert-Test (-not $checks.onlyExpectedAzureRoles) 'Fixture mode must reject retained checkout access.'
    } finally {
        $script:state = $savedState
    }
}

& {
    $checkoutGroup = "/subscriptions/$subscription/resourceGroups/owned-checkout"
    $script:liveSource = @{
        environmentName = 'checkout01'; ownerToken = '55555555-5555-4555-8555-555555555555'
        workspaceCustomerId = '66666666-6666-4666-8666-666666666666'
        workspaceId = "$checkoutGroup/providers/Microsoft.OperationalInsights/workspaces/ops"
        arcMachineId = "$checkoutGroup/providers/Microsoft.HybridCompute/machines/checkout"
        appInsightsId = "$checkoutGroup/providers/Microsoft.Insights/components/checkout"
        sreAgentId = "$checkoutGroup/providers/Microsoft.App/agents/checkout"
        sreEndpoint = 'https://checkout.azuresre.ai'
        latencyRuleId = "$checkoutGroup/providers/Microsoft.Insights/scheduledQueryRules/latency"
        serviceRuleId = "$checkoutGroup/providers/Microsoft.Insights/scheduledQueryRules/service"
        createdAtUtc = '2026-10-28T07:00:00Z'
    }
    $script:state = @{
        nameSuffix = 'abcdef'; agentVersion = '1'; agentEndpointVersion = '1'
        ownerToken = '88888888-8888-4888-8888-888888888888'
        applicationObjectId = $null; applicationClientId = $null; servicePrincipalId = $null
        outputs = @{ teams = $binding; runtimePrincipalId = '77777777-7777-4777-8777-777777777777' }
        checkoutBinding = @{ environmentName = 'browser-only'; workspaceId = 'browser-workspace' }
        teamsConfig = @{ enabled = $true; userId = $binding.runtimePrincipalId; packageId = $binding.botClientId }
    }
    $CheckoutEnvironmentName = 'checkout01'
    $logReaderRole = '73c42c96-874c-492b-b04d-ab87d138a893'
    $script:liveCalls = [Collections.Generic.List[string]]::new()
    $script:liveGrant = $null
    $script:sreGrant = $null
    $script:sreRole = $null
    $script:keepGrant = $false
    $script:hostPresent = $true
    $script:groupPresent = $true
    $script:cleanupMode = $false
    $script:failStart = $false
    $directory = '.'
    $groupName = ($groupId -split '/')[-1]
    function Get-IncidentGroup { if ($script:groupPresent) { return @{ owned = $true } } }
    function Get-CheckoutBindingSource { param([string]$Name) return $script:liveSource.Clone() }
    function Save-IncidentState {}
    function Stop-IncidentTeamsRuntime {
        param([switch]$AllowMissing)
        $script:liveCalls.Add('stop')
        if (-not $script:hostPresent -and -not $AllowMissing) { throw 'Host is absent.' }
        return $script:hostPresent
    }
    function Set-IncidentStartup {
        param([string]$Command, [switch]$Teams)
        Assert-Test ($Teams -and $Command -ceq 'python teams_server.py') 'Transitions must replace any interrupted job wrapper with the fixed Teams server.'
        $script:liveCalls.Add('serve-only')
    }
    function Set-IncidentTeamsSettings {
        param([hashtable]$Values)
        $script:liveCalls.Add("settings:$($Values.DEMO_EVIDENCE_MODE)")
    }
    function Restart-IncidentRuntime {
        param([switch]$Teams)
        Assert-Test $Teams.IsPresent 'Live Teams transitions must never restart the browser.'
        $script:liveCalls.Add('start')
        if ($script:failStart) { throw 'Simulated start failure after verified grant removal.' }
    }
    function Test-IncidentTeamsReadiness { return @{ ready = $true } }
    function Invoke-IncidentCloudJob { throw 'Attachment must not start or replay inference.' }
    function Invoke-IncidentRequest {
        param([string]$Uri, [string]$Method = 'GET', [object]$Body, [switch]$AllowMissing)
        if ($script:state['teamsCheckoutBinding'] -and $script:state.teamsCheckoutBinding['sreRoleId']) {
            $sreUris = Get-IncidentSreUris $script:state.teamsCheckoutBinding
            if ($Uri -ceq $sreUris.role) {
                if ($Method -ceq 'PUT') {
                    $script:liveCalls.Add('sre-role')
                    $script:sreRole = @{ properties = $Body.properties }
                } elseif ($Method -ceq 'DELETE') {
                    $script:liveCalls.Add('sre-role-delete')
                    if (-not $script:keepGrant) { $script:sreRole = $null }
                }
                return $script:sreRole
            }
            if ($Uri -ceq $sreUris.assignment) {
                if ($Method -ceq 'PUT') {
                    $script:liveCalls.Add('sre-grant')
                    $script:sreGrant = @{ properties = @{
                        principalId = $Body.properties.principalId
                        roleDefinitionId = $Body.properties.roleDefinitionId
                        scope = $script:liveSource.sreAgentId
                    } }
                } elseif ($Method -ceq 'DELETE') {
                    $script:liveCalls.Add('sre-revoke')
                    if (-not $script:keepGrant) { $script:sreGrant = $null }
                }
                return $script:sreGrant
            }
        }
        if (-not $Uri.StartsWith("https://management.azure.com$($script:liveSource.workspaceId)/providers/Microsoft.Authorization/roleAssignments/")) {
            if ($script:cleanupMode -and $Method -ceq 'GET') { return $null }
            throw 'Only the bound checkout workspace grant may be managed.'
        }
        switch ($Method) {
            'PUT' {
                $script:liveCalls.Add('grant')
                $script:liveGrant = @{ properties = @{
                    principalId = $Body.properties.principalId
                    roleDefinitionId = $Body.properties.roleDefinitionId
                    scope = $script:liveSource.workspaceId
                } }
                return @{}
            }
            'DELETE' {
                $script:liveCalls.Add('revoke')
                if (-not $script:keepGrant) { $script:liveGrant = $null }
                return
            }
        }
        return $script:liveGrant
    }
    $attached = Connect-IncidentCheckout -Teams
    Assert-Test ($attached.attached -and -not $attached.liveEvidenceObserved) 'Attach must report configuration, not fabricate live acceptance.'
    Assert-Test ($script:liveGrant.properties.principalId -ceq $binding.runtimePrincipalId -and
        $script:liveGrant.properties.roleDefinitionId.EndsWith("/$logReaderRole")) 'Grant only workspace Reader to the Teams system identity.'
    Assert-Test ($script:liveCalls[0] -ceq 'stop' -and
        $script:liveCalls.IndexOf('serve-only') -lt $script:liveCalls.IndexOf('grant') -and
        $script:liveCalls.IndexOf('grant') -lt $script:liveCalls.IndexOf('settings:live')) 'Stop old work and disable interrupted job wrappers before granting and enabling live evidence.'
    Assert-Test ($script:state.checkoutBinding.environmentName -ceq 'browser-only') 'Teams attachment must not mutate browser binding.'
    Assert-Test ((Test-IncidentSreGrant -Teams) -and
        $script:sreGrant.properties.scope -ceq $script:liveSource.sreAgentId) 'SRE reads must be scoped to the exact owned agent.'
    $script:sreRole.properties.permissions[0].dataActions += 'Microsoft.App/agents/threads/write'
    Assert-Throws { Test-IncidentSreGrant -Teams } 'SRE role drift must reject write permissions.'
    $script:sreRole.properties.permissions[0].dataActions =
        @('Microsoft.App/agents/threads/read', 'Microsoft.App/agents/incidentManagement/read')
    Assert-IncidentTeamsState $script:state
    $revision = $script:state.teamsConfig.evidenceRevision
    $settings = Get-IncidentTeamsEvidenceSettings
    Assert-Test ($settings.DEMO_EVIDENCE_MODE -ceq 'live' -and
        $settings.CHECKOUT_WORKSPACE_ID -ceq $script:liveSource.workspaceCustomerId -and
        $settings.CHECKOUT_SRE_RESOURCE_ID -ceq $script:liveSource.sreAgentId -and
        $settings.CHECKOUT_CREATED_AT -ceq ([DateTimeOffset]$script:liveSource.createdAtUtc).ToUniversalTime().ToString('o') -and
        $settings.TEAMS_EVIDENCE_REVISION -ceq $revision) 'Up must preserve the complete independent Teams binding and receipt revision.'
    $originalCreatedAt = $script:state.teamsCheckoutBinding.createdAtUtc
    try {
        foreach ($stamp in @('2026-10-25T16:05:40.8173794+01:00', '2026-10-25T15:05:40.8173794Z')) {
            $script:state.teamsCheckoutBinding.createdAtUtc = $stamp
            Assert-Test ((Get-IncidentTeamsEvidenceSettings).CHECKOUT_CREATED_AT -ceq
                '2026-10-25T15:05:40.8173794+00:00') `
                'Equivalent deployment instants must emit the exact UTC app-setting representation.'
        }
        $script:state.teamsCheckoutBinding.createdAtUtc = 'invalid'
        Assert-Throws { Get-IncidentTeamsEvidenceSettings } 'Malformed binding timestamps must not produce evidence settings.'
        $script:state.teamsCheckoutBinding.Remove('createdAtUtc')
        Assert-Test ((Get-IncidentTeamsEvidenceSettings).CHECKOUT_CREATED_AT -ceq '') `
            'Legacy telemetry-only bindings must preserve their empty SRE generation setting.'
    } finally {
        $script:state.teamsCheckoutBinding.createdAtUtc = $originalCreatedAt
    }
    $script:liveSource.arcMachineId += '-different'
    Assert-Throws { Connect-IncidentCheckout -Teams } 'A changed Arc binding requires an explicit detach.'
    $script:liveSource.arcMachineId = $script:state.teamsCheckoutBinding.arcMachineId
    $script:liveGrant.properties.principalId = $script:state.outputs.runtimePrincipalId
    Assert-Throws { Test-CheckoutGrant -Teams } 'Reject a workspace reader assigned to the browser instead of Teams.'
    $script:liveGrant.properties.principalId = $binding.runtimePrincipalId
    $script:keepGrant = $true
    Assert-Throws { Disconnect-IncidentCheckout -Teams } 'Do not discard a grant whose deletion is not independently verified.'
    Assert-Test ([bool]$script:state.teamsCheckoutBinding -and
        (Get-IncidentTeamsEvidenceSettings).DEMO_EVIDENCE_MODE -ceq 'fixture') 'Partial detach must retain cleanup bindings without re-enabling live mode on Up.'
    $script:keepGrant = $false
    $detached = Disconnect-IncidentCheckout -Teams
    Assert-Test ($detached.detached -and -not $script:state.teamsCheckoutBinding -and
        -not $script:liveGrant -and -not $script:sreGrant -and
        -not $script:sreRole) 'Detach must verify both external grants and the custom role are absent before clearing state.'
    Assert-Test ($script:state.teamsConfig.evidenceRevision -cne $revision) 'Mode transitions must invalidate saved history and receipts.'
    $settings = Get-IncidentTeamsEvidenceSettings
    Assert-Test ($settings.DEMO_EVIDENCE_MODE -ceq 'fixture' -and
        $settings.CHECKOUT_WORKSPACE_ID -ceq '') 'Detached Teams must contain no live workspace settings.'
    Assert-Test ($script:state.checkoutBinding.environmentName -ceq 'browser-only') 'Teams cleanup must leave the browser attachment alone.'

    $null = Connect-IncidentCheckout -Teams
    $script:failStart = $true
    Assert-Throws { Disconnect-IncidentCheckout -Teams } 'A failed post-cleanup host start must remain an explicit failure.'
    Assert-Test (-not $script:state.teamsCheckoutBinding -and -not $script:liveGrant) 'A verified removed grant must stay removed after a start failure.'
    $script:failStart = $false
    $retried = Disconnect-IncidentCheckout -Teams
    Assert-Test ($retried.detached -and -not $retried.changed -and
        $script:liveCalls[$script:liveCalls.Count - 1] -ceq 'start') 'Retry detach must finish host convergence even if the grant was already removed.'

    $null = Connect-IncidentCheckout -Teams
    $script:hostPresent = $false
    $before = $script:liveCalls.Count
    $detached = Disconnect-IncidentCheckout -Teams
    Assert-Test ($detached.detached -and -not $detached.teamsHostPresent -and
        -not $script:liveGrant) 'A verified missing host must not block external grant cleanup.'
    Assert-Test (@($script:liveCalls.GetRange($before, $script:liveCalls.Count - $before) |
        Where-Object { $_ -in @('start', 'settings:fixture', 'serve-only') }).Count -eq 0) 'Missing-host detach must not write settings or recreate/start the host.'

    function Get-IncidentApplication { return $null }
    function Assert-IncidentResourceOwnership { param([object[]]$Resources) }
    function Save-RetailState { param([hashtable]$State, [string]$Path) }
    function Invoke-IncidentAzure {
        param([string[]]$Arguments, [int]$TimeoutSeconds)
        if ($Arguments[0] -ceq 'group' -and $Arguments[1] -ceq 'delete') {
            $script:groupPresent = $false
            return
        }
        if ($Arguments[0] -ceq 'resource' -and $Arguments[1] -ceq 'list') { return @() }
        throw 'Unexpected Azure operation in cleanup test.'
    }
    $script:hostPresent = $true
    $null = Connect-IncidentCheckout -Teams
    $script:hostPresent = $false
    $script:cleanupMode = $true
    $script:state.checkoutBinding = $null
    $script:state.teamsResources = $script:state.outputs.teams.Clone()
    $script:state.outputs.teams = @{}
    Assert-Test ((Get-IncidentHostOutputs -Teams).webAppId -ceq $binding.webAppId) 'Partial cleanup must retain the verified fallback host binding.'
    & {
        $stop = $teamsAst.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -ceq 'Stop-IncidentTeamsRuntime'
        }, $true)
        . ([scriptblock]::Create($stop.Extent.Text))
        Assert-Test (-not (Stop-IncidentTeamsRuntime -AllowMissing)) 'The actual stop helper must explicitly report a verified absent host through fallback bindings.'
    }
    $down = Remove-IncidentPlatform
    Assert-Test ($down.removed -and -not $script:liveGrant -and
        -not $script:state.teamsCheckoutBinding) 'Full Down must remove external grants with an already-missing Teams host and fallback resource bindings.'

    $script:groupPresent = $true
    $script:hostPresent = $true
    $null = Connect-IncidentCheckout -Teams
    $script:groupPresent = $false
    $script:hostPresent = $false
    function Initialize-IncidentPlatform { throw 'Scoped cleanup must not recreate an absent incident group.' }
    $down = Remove-IncidentTeams
    Assert-Test ($down.activeTeamsResourcesRemoved -and -not $script:liveGrant -and
        -not $script:state.teamsCheckoutBinding) 'TeamsDown must revoke the external grant even after the incident group disappeared.'
}

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
