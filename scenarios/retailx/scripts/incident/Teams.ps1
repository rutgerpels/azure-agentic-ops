#Requires -Version 7.2
# Dot-sourced only by the owned incident lifecycle entry point.

function Get-IncidentHostOutputs {
    param([switch]$Teams)
    if (-not $Teams) { return $script:state.outputs }
    if ($script:state.outputs['teams'] -and $script:state.outputs.teams.Count -gt 0) {
        return $script:state.outputs.teams
    }
    if ($script:state['teamsResources']) { return $script:state.teamsResources }
    throw 'No owned Teams host is recorded.'
}

function Get-IncidentTeamsEvidenceSettings {
    $settings = Get-IncidentEvidenceSettings -Teams
    $settings.TEAMS_EVIDENCE_REVISION = if ($script:state['teamsConfig']) {
        [string]$script:state.teamsConfig['evidenceRevision']
    } else { '' }
    return $settings
}

function Stop-IncidentTeamsRuntime {
    param([switch]$AllowMissing)
    $hostOutputs = Get-IncidentHostOutputs -Teams
    $uri = "https://management.azure.com$($hostOutputs.webAppId)?api-version=2024-04-01"
    $web = Invoke-IncidentRequest $uri -AllowMissing:$AllowMissing
    if (-not $web -and $AllowMissing) { return $false }
    if ($web.tags.ownerToken -cne $script:state.ownerToken -or
        $web.identity.principalId -ine $hostOutputs.runtimePrincipalId) {
        throw 'Teams host ownership or runtime identity drifted; stopping refused.'
    }
    $null = Invoke-IncidentAzure @('webapp', 'stop', '--resource-group', $groupName, '--name', $hostOutputs.webAppName)
    $web = Invoke-IncidentRequest $uri
    if ($web.properties.state -cne 'Stopped') {
        throw 'Teams host stop is not verified. Retain state; do not change the evidence binding.'
    }
    if ($script:state['activeJob'] -and $script:state.activeJob['teams'] -and
        $script:state.activeJob.status -ceq 'running') {
        $script:state.activeJob.status = 'outcome-unknown'
        Save-IncidentState
    }
    return $true
}

function Assert-IncidentTeamsState {
    param([hashtable]$Value)
    if ($Value['teamsConfig']) {
        foreach ($key in @('userId', 'packageId')) { $null = [guid]::Parse($Value.teamsConfig[$key]) }
        if ($Value.teamsConfig.enabled -isnot [bool]) { throw 'Invalid Teams enablement state.' }
        if ($Value.teamsConfig['evidenceMode'] -and $Value.teamsConfig.evidenceMode -cnotin @('fixture', 'live')) {
            throw 'Invalid Teams evidence mode.'
        }
        if ($Value.teamsConfig['evidenceRevision']) { $null = [guid]::Parse($Value.teamsConfig.evidenceRevision) }
        if ($Value.teamsConfig['evidenceMode'] -ceq 'live' -and
            (-not $Value['teamsCheckoutBinding'] -or -not $Value.teamsConfig['evidenceRevision'])) {
            throw 'Live Teams mode requires its own checkout binding and receipt revision.'
        }
    }
    $teams = if ($Value.outputs['teams'] -and $Value.outputs.teams.Count -gt 0) {
        $Value.outputs.teams
    } else { $Value['teamsResources'] }
    if (-not $teams) {
        if ($Value['teamsCheckoutBinding']) { throw 'Teams checkout binding has no recorded host.' }
        return
    }
    $name = "app-rtx-teams-$EnvironmentName-$($Value.nameSuffix)"
    $botName = "bot-rtx-incident-$EnvironmentName-$($Value.nameSuffix)"
    if ($teams.webAppName -cne $name -or
        $teams.webAppId -ine "$groupId/providers/Microsoft.Web/sites/$name" -or
        $teams.botId -ine "$groupId/providers/Microsoft.BotService/botServices/$botName" -or
        $teams.botIdentityId -ine "$groupId/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-retailtx-incident-$EnvironmentName-teams" -or
        -not $teams.runtimeAssignmentId.StartsWith("$groupId/providers/Microsoft.CognitiveServices/accounts/aif-rtx-incident-$EnvironmentName-$($Value.nameSuffix)/projects/incident/providers/Microsoft.Authorization/roleAssignments/", [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Saved Teams resource binding is invalid.'
    }
    foreach ($key in @('runtimePrincipalId', 'botClientId')) { $null = [guid]::Parse($teams[$key]) }
    if ($Value['teamsCheckoutBinding']) {
        $binding = $Value.teamsCheckoutBinding
        if (-not $Value['teamsConfig'] -or $binding.runtimePrincipalId -ine $teams.runtimePrincipalId) {
            throw 'Teams checkout binding belongs to a different runtime.'
        }
        Assert-RetailEnvironmentName $binding.environmentName
        foreach ($key in @('ownerToken', 'readerAssignmentId', 'workspaceCustomerId', 'runtimePrincipalId')) {
            $null = [guid]::Parse($binding[$key])
        }
        $checkoutGroup = $null
        foreach ($pair in @(
            @('workspaceId', 'Microsoft.OperationalInsights/workspaces'),
            @('arcMachineId', 'Microsoft.HybridCompute/machines'),
            @('appInsightsId', 'Microsoft.Insights/components'))) {
            $pattern = '^(/subscriptions/' + [regex]::Escape($subscription) +
                '/resourceGroups/[A-Za-z0-9_.()-]+)/providers/' +
                [regex]::Escape($pair[1]) + '/[A-Za-z0-9_.()-]+$'
            if ([string]$binding[$pair[0]] -inotmatch $pattern) { throw 'Invalid Teams checkout resource scope.' }
            if ($checkoutGroup -and $checkoutGroup -ine $Matches[1]) { throw 'Teams checkout resources do not share an owned group.' }
            $checkoutGroup = $Matches[1]
        }
    }
    $null = [guid]::Parse(($teams.runtimeAssignmentId -split '/')[-1])
    foreach ($key in @('webAppUrl', 'scmUrl')) {
        $uri = [uri]$teams[$key]
        if ($uri.Scheme -cne 'https' -or $uri.Port -ne 443 -or $uri.UserInfo -or
            $uri.Query -or $uri.Fragment -or $uri.AbsolutePath -cne '/' -or
            -not $uri.Host.StartsWith("$name.", [StringComparison]::Ordinal) -or
            -not $uri.Host.EndsWith('.azurewebsites.net', [StringComparison]::Ordinal) -or
            ($key -eq 'scmUrl' -and -not $uri.Host.Contains('.scm.'))) {
            throw 'Saved Teams endpoint is invalid.'
        }
    }
}

function Initialize-IncidentTeams {
    if (-not $script:state.agentVersion -or
        $script:state.agentVersion -cne $script:state.agentEndpointVersion) {
        throw 'Run Up and pin the browser agent before TeamsUp.'
    }
    if (-not (Get-IncidentGroup)) { throw 'The owned incident platform is missing. Run Up first.' }
    if (-not $script:state['teamsConfig']) {
        if (-not $TeamsUserObjectId) { throw 'First TeamsUp requires -TeamsUserObjectId <member-object-guid>.' }
        $userId = ([guid]$TeamsUserObjectId).ToString()
        $user = Invoke-IncidentRequest "https://graph.microsoft.com/v1.0/users/${userId}?`$select=id,accountEnabled,userType"
        if ($user.id -ine $userId -or -not $user.accountEnabled -or $user.userType -cne 'Member') {
            throw 'Teams pilot requires the exact enabled member account in the authorized tenant.'
        }
        $provider = Invoke-IncidentAzure @('provider', 'show', '--namespace', 'Microsoft.BotService')
        if ($provider.registrationState -cne 'Registered') {
            throw 'Microsoft.BotService must be registered by the subscription owner before TeamsUp.'
        }
        $script:state.teamsConfig = @{ enabled = $true; userId = $userId
            packageId = [guid]::NewGuid().ToString(); personalInstallation = 'not-inventoried' }
        Save-IncidentState
    } else {
        if ($TeamsUserObjectId -and ([guid]$TeamsUserObjectId).ToString() -ine $script:state.teamsConfig.userId) {
            throw 'The Teams member is already bound. Use a separate environment for another member.'
        }
        $script:state.teamsConfig.enabled = $true
        Save-IncidentState
    }
    Initialize-IncidentPlatform
    Publish-IncidentTeams
    $null = Test-IncidentReadiness
    $null = Test-IncidentTeamsReadiness
    New-IncidentTeamsPackage
}

function Publish-IncidentTeams {
    $hostOutputs = Get-IncidentHostOutputs -Teams
    # Browser bootstrap can pin a new agent version after the shared ARM deployment.
    Set-IncidentTeamsSettings @{ FOUNDRY_AGENT_VERSION = $script:state.agentVersion }
    $archive = Join-Path $directory 'incident-teams-runtime.zip'
    if (Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive -Force }
    try {
        [IO.Compression.ZipFile]::CreateFromDirectory((Join-Path $repository 'app\incident'), $archive)
        $null = Invoke-IncidentAzure @('webapp', 'deploy', '--resource-group', $groupName,
            '--name', $hostOutputs.webAppName, '--src-path', $archive, '--type', 'zip',
            '--clean', 'true', '--restart', 'true', '--track-status', 'false', '--timeout', '900000') -TimeoutSeconds 1200
    } finally {
        if (Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive -Force }
    }
    $tests = Invoke-IncidentCloudJob 'test' -Teams
    if (-not $tests.pass -or $tests.testsRun -lt 1) { throw 'Teams host cloud tests did not pass.' }
    $script:state.teamsConfig.cloudTests = $tests
    Save-IncidentState
    Wait-IncidentRuntime -Teams
}

function New-IncidentTeamsPackage {
    $hostOutputs = Get-IncidentHostOutputs -Teams
    if (-not $script:state.teamsConfig.enabled) { throw 'Teams is not enabled.' }
    $path = Join-Path $directory 'retailx-teams-personal.zip'
    $tool = Join-Path $repository 'app\incident\teams_package.py'
    & python $tool --bot-id $hostOutputs.botClientId --app-id $script:state.teamsConfig.packageId `
        --hostname ([uri]$hostOutputs.webAppUrl).Host --output $path
    if ($LASTEXITCODE -ne 0) { throw 'Teams package generation failed.' }
    return @{ packagePath = $path; scope = 'personal'; teamsConversationVerified = $false
        nextAction = 'After tenant policy approval, upload this private package in Teams as the bound member. Do not publish tenant-wide.' }
}

function Set-IncidentTeamsSettings {
    param([hashtable]$Values)
    $hostOutputs = Get-IncidentHostOutputs -Teams
    $uri = "https://management.azure.com$($hostOutputs.webAppId)/config/appsettings"
    $settings = Invoke-IncidentRequest "${uri}/list?api-version=2024-04-01" -Method POST
    foreach ($key in $Values.Keys) { $settings.properties[$key] = [string]$Values[$key] }
    $null = Invoke-IncidentRequest "${uri}?api-version=2024-04-01" -Method PUT -Body @{ properties = $settings.properties }
}

function Set-IncidentTeamsRun {
    Set-IncidentTeamsSettings @{ DEMO_RUN_ID = $script:state.runId }
    $hostOutputs = Get-IncidentHostOutputs -Teams
    $null = Invoke-IncidentAzure @('webapp', 'restart', '--resource-group', $groupName, '--name', $hostOutputs.webAppName)
}

function Test-IncidentTeamsReadiness {
    Assert-IncidentTeamsState $script:state
    $hostOutputs = Get-IncidentHostOutputs -Teams
    if (-not $script:state['teamsConfig'] -or -not $script:state.teamsConfig.enabled) {
        throw 'The Teams pilot is disabled.'
    }
    $null = Get-IncidentGroup
    $resources = @(Invoke-IncidentAzure @('resource', 'list', '--resource-group', $groupName))
    Assert-IncidentResourceOwnership -Resources $resources
    $web = Invoke-IncidentRequest "https://management.azure.com$($hostOutputs.webAppId)?api-version=2024-04-01"
    $auth = Invoke-IncidentRequest "https://management.azure.com$($hostOutputs.webAppId)/config/authsettingsV2?api-version=2024-04-01"
    $settings = Invoke-IncidentRequest "https://management.azure.com$($hostOutputs.webAppId)/config/appsettings/list?api-version=2024-04-01" -Method POST
    $expectedEvidence = Get-IncidentTeamsEvidenceSettings
    $bot = Invoke-IncidentRequest "https://management.azure.com$($hostOutputs.botId)?api-version=2022-09-15"
    $identity = Invoke-IncidentRequest "https://management.azure.com$($hostOutputs.botIdentityId)?api-version=2023-01-31"
    $channel = Invoke-IncidentRequest "https://management.azure.com$($hostOutputs.botId)/channels/MsTeamsChannel?api-version=2022-09-15"
    $configuration = Invoke-IncidentRequest "https://management.azure.com$($hostOutputs.webAppId)/config/web?api-version=2024-04-01"
    $plan = Invoke-IncidentRequest "https://management.azure.com$($web.properties.serverFarmId)?api-version=2024-04-01"
    Wait-IncidentRuntime -Teams
    $checks = [ordered]@{
        resourcesOwned = $true
        evidenceModeBound = (@($expectedEvidence.Keys | Where-Object {
            [string]$settings.properties[$_] -cne [string]$expectedEvidence[$_]
        }).Count -eq 0)
        checkoutGrantBound = if ($script:state['teamsCheckoutBinding']) {
            $expectedEvidence.DEMO_EVIDENCE_MODE -ceq 'live' -and (Test-CheckoutGrant -Teams) -and
                (Test-IncidentSreGrant -Teams)
        } else { $expectedEvidence.DEMO_EVIDENCE_MODE -ceq 'fixture' }
        exactMember = ($settings.properties.TEAMS_ALLOWED_OBJECT_ID -ieq $script:state.teamsConfig.userId -and
            $settings.properties.DEMO_TENANT_ID -ieq $tenant)
        exactRun = ($settings.properties.DEMO_OWNER_TOKEN -ceq $script:state.ownerToken -and
            $settings.properties.DEMO_RUN_ID -ceq $script:state.runId)
        pinnedAgent = ($settings.properties.FOUNDRY_AGENT_VERSION -ceq $script:state.agentVersion -and [bool]$script:state.agentVersion)
        separateChannelHost = (-not $auth.properties.platform.enabled -and $web.properties.httpsOnly -and
            $configuration.properties.appCommandLine -ceq 'python teams_server.py')
        singleInstance = ($plan.sku.capacity -eq 1 -and $configuration.properties.numberOfWorkers -eq 1)
        runtimeIdentity = ($web.identity.principalId -ieq $hostOutputs.runtimePrincipalId)
        secretlessBot = ($bot.properties.msaAppType -ceq 'UserAssignedMSI' -and
            $bot.properties.msaAppId -ieq $hostOutputs.botClientId -and
            $bot.properties.msaAppTenantId -ieq $tenant -and
            $bot.properties.msaAppMSIResourceId -ieq $hostOutputs.botIdentityId -and
            $identity.properties.clientId -ieq $hostOutputs.botClientId -and
            $settings.properties.TEAMS_BOT_CLIENT_ID -ieq $hostOutputs.botClientId -and
            ($hostOutputs.botIdentityId -iin @($web.identity.userAssignedIdentities.Keys)) -and
            $bot.properties.disableLocalAuth)
        channelBound = ($bot.properties.endpoint -ceq "$($hostOutputs.webAppUrl)/api/messages" -and
            $channel.properties.properties.isEnabled)
    }
    $grants = @(Invoke-IncidentAzure @('role', 'assignment', 'list', '--assignee-object-id',
        $hostOutputs.runtimePrincipalId, '--scope', $script:state.outputs.foundryProjectId,
        '--include-inherited', '--query', '[].{role:roleDefinitionId,scope:scope}'))
    $checks.runtimeLeastPrivilege = $grants.Count -eq 1 -and
        $grants[0].role -ieq "/subscriptions/$subscription/providers/Microsoft.Authorization/roleDefinitions/$runtimeRole" -and
        $grants[0].scope -ieq $script:state.outputs.foundryProjectId
    $allGrants = @(Invoke-IncidentAzure @('role', 'assignment', 'list', '--assignee-object-id',
        $hostOutputs.runtimePrincipalId, '--all', '--include-inherited',
        '--query', '[].{role:roleDefinitionId,scope:scope}'))
    $liveSre = $expectedEvidence.DEMO_EVIDENCE_MODE -ceq 'live' -and
        [bool]$script:state.teamsCheckoutBinding['sreAgentId']
    $sreUris = if ($liveSre) { Get-IncidentSreUris $script:state.teamsCheckoutBinding } else { $null }
    $expectedCount = if ($liveSre) { 3 } elseif ($expectedEvidence.DEMO_EVIDENCE_MODE -ceq 'live') { 2 } else { 1 }
    $checks.onlyExpectedAzureRoles = $allGrants.Count -eq $expectedCount -and @(
        $allGrants | Where-Object {
            -not (($_.role -ieq "/subscriptions/$subscription/providers/Microsoft.Authorization/roleDefinitions/$runtimeRole" -and
                $_.scope -ieq $script:state.outputs.foundryProjectId) -or
                ($expectedEvidence.DEMO_EVIDENCE_MODE -ceq 'live' -and
                $_.role -ieq "/subscriptions/$subscription/providers/Microsoft.Authorization/roleDefinitions/$logReaderRole" -and
                $_.scope -ieq $script:state.teamsCheckoutBinding.workspaceId) -or
                ($liveSre -and $_.role -ieq $sreUris.roleId -and
                $_.scope -ieq $script:state.teamsCheckoutBinding.sreAgentId))
        }
    ).Count -eq 0
    $botGrants = @(Invoke-IncidentAzure @('role', 'assignment', 'list', '--assignee-object-id',
        $identity.properties.principalId, '--all', '--query', '[].id'))
    $checks.botHasNoAzureRoles = $botGrants.Count -eq 0
    foreach ($policy in @('scm', 'ftp')) {
        $value = Invoke-IncidentRequest "https://management.azure.com$($hostOutputs.webAppId)/basicPublishingCredentialsPolicies/${policy}?api-version=2024-04-01"
        $checks["${policy}BasicAuthDisabled"] = -not $value.properties.allow
    }
    foreach ($case in @('anonymous', 'forged')) {
        $request = @{ Uri = "$($hostOutputs.webAppUrl)/api/messages"; Method = 'POST'
            Body = '{}'; ContentType = 'application/json'; TimeoutSec = 30
            MaximumRedirection = 0; SkipHttpErrorCheck = $true }
        if ($case -eq 'forged') { $request.Headers = @{ Authorization = 'Bearer not-a-jwt' } }
        $response = Invoke-WebRequest @request
        $checks["${case}Denied"] = $response.StatusCode -eq 401
    }
    $null = Test-IncidentReadiness
    $ready = @($checks.Values | Where-Object { -not $_ }).Count -eq 0
    Save-RetailState -State @{ ready = $ready; checks = $checks; evidenceMode = $expectedEvidence.DEMO_EVIDENCE_MODE
        ownerToken = $script:state.ownerToken; runId = $script:state.runId
        checkedAtUtc = [DateTimeOffset]::UtcNow.ToString('o'); teamsConversationVerified = $false
    } -Path (Join-Path $directory 'incident-teams-readiness.json')
    if (-not $ready) { throw "Teams readiness failed: $(@($checks.Keys | Where-Object { -not $checks[$_] }) -join ', ')." }
    return @{ ready = $true; evidenceMode = $expectedEvidence.DEMO_EVIDENCE_MODE; teamsConversationVerified = $false }
}

function Remove-IncidentTeams {
    $hostOutputs = if ($script:state.outputs['teams'] -and $script:state.outputs.teams.Count -gt 0) {
        $script:state.outputs.teams
    } else { $script:state['teamsResources'] }
    if (-not $hostOutputs) { throw 'No recorded Teams resource bindings; inspect the owned deployment or use full Down.' }
    $group = Get-IncidentGroup
    $script:state.teamsResources = $hostOutputs.Clone()
    Save-IncidentState
    if ($group) {
        $resources = @(Invoke-IncidentAzure @('resource', 'list', '--resource-group', $groupName))
        Assert-IncidentResourceOwnership -Resources $resources
    }
    $webUri = "https://management.azure.com$($hostOutputs.webAppId)?api-version=2024-04-01"
    $web = Invoke-IncidentRequest $webUri -AllowMissing
    if ($web) {
        if ($web.tags.ownerToken -cne $script:state.ownerToken) { throw 'Teams host ownership drifted.' }
        $null = Invoke-IncidentAzure @('webapp', 'stop', '--resource-group', $groupName, '--name', $hostOutputs.webAppName)
        $stopped = Invoke-IncidentRequest $webUri
        if ($stopped.properties.state -cne 'Stopped') { throw 'Teams host stop is not verified.' }
    }
    if ($script:state['teamsCheckoutBinding']) {
        Remove-CheckoutGrant -Teams
        $script:state.teamsCheckoutBinding = $null
        $script:state.teamsConfig.evidenceMode = 'fixture'
        $script:state.teamsConfig.evidenceRevision = [guid]::NewGuid().ToString()
        Save-IncidentState
    }
    $grantUri = "https://management.azure.com$($hostOutputs.runtimeAssignmentId)?api-version=2022-04-01"
    $grant = Invoke-IncidentRequest $grantUri -AllowMissing
    if ($grant) {
        if ($grant.properties.principalId -ine $hostOutputs.runtimePrincipalId -or
            $grant.properties.roleDefinitionId -ine "/subscriptions/$subscription/providers/Microsoft.Authorization/roleDefinitions/$runtimeRole") {
            throw 'Unexpected Teams role assignment; deletion refused.'
        }
        $null = Invoke-IncidentRequest $grantUri -Method DELETE
    }
    foreach ($item in @(
        @{ id = $hostOutputs.botId; version = '2022-09-15' },
        @{ id = $hostOutputs.webAppId; version = '2024-04-01' },
        @{ id = $hostOutputs.botIdentityId; version = '2023-01-31' }
    )) {
        $uri = "https://management.azure.com$($item.id)?api-version=$($item.version)"
        $resource = Invoke-IncidentRequest $uri -AllowMissing
        if ($resource) {
            if ($resource.tags.ownerToken -cne $script:state.ownerToken) { throw 'Teams ownership mismatch; deletion refused.' }
            $null = Invoke-IncidentRequest $uri -Method DELETE
        }
        if (Invoke-IncidentRequest $uri -AllowMissing) { throw 'Teams deletion is not yet verified. Retain state and observe TeamsDown again.' }
    }
    if (Invoke-IncidentRequest $grantUri -AllowMissing) { throw 'Teams runtime grant remains.' }
    $script:state.teamsConfig.enabled = $false
    Save-IncidentState
    if ($group) {
        Initialize-IncidentPlatform
        $null = Test-IncidentReadiness
    }
    $receipt = @{ activeTeamsResourcesRemoved = $true; ownerToken = $script:state.ownerToken
        checkedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        teamsClientCleanup = 'Uninstall the personal app in Teams. Tenant/catalog installations are not inventoried or purged.'
        retention = 'Provider-retained data may remain; not a purge claim.' }
    Save-RetailState -State $receipt -Path (Join-Path $directory 'incident-teams-residuals.json')
    return $receipt
}
