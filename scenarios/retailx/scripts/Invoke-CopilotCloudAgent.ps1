#Requires -Version 7.2
<#
.SYNOPSIS
Lifecycle for the GitHub Copilot cloud agent's Azure workload identity.
.DESCRIPTION
Configure creates an owned resource group, a user-assigned managed identity and one
federated credential bound to the repository's exact OIDC subject for GitHub environment
'copilot'. It stores the non-secret client and tenant IDs as Agents and environment secrets.
No Azure role is granted by Configure. Grant assigns Reader on one existing checkout
resource group only. Check reads everything back. Remove deletes the owned group and the
GitHub environment and secrets after verifying ownership.
.PARAMETER Action
Configure, Grant, Check or Remove.
.PARAMETER SubscriptionId
The explicit authorized subscription.
.PARAMETER EnvironmentName
Neutral identifier for the identity's owned resource group.
.PARAMETER CheckoutEnvironmentName
Checkout environment whose resource group receives Reader with Grant.
.PARAMETER Repository
GitHub repository in owner/name form.
.PARAMETER RetentionDays
Days until the expiresAt tag on the owned resource group.
.EXAMPLE
./scenarios/retailx/scripts/Invoke-CopilotCloudAgent.ps1 Configure -SubscriptionId <guid>
.EXAMPLE
./scenarios/retailx/scripts/Invoke-CopilotCloudAgent.ps1 Grant -SubscriptionId <guid> -CheckoutEnvironmentName checkout01
.OUTPUTS
PSCustomObject readiness summary for Check; nothing otherwise.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory, Position = 0)][ValidateSet('Configure', 'Grant', 'Check', 'Remove')][string]$Action,
    [Parameter(Mandatory)][guid]$SubscriptionId,
    [string]$EnvironmentName = 'demo01',
    [string]$CheckoutEnvironmentName = 'checkout01',
    [ValidatePattern('^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$')][string]$Repository = 'rutgerpels/azure-agentic-ops',
    [string]$Location = 'swedencentral',
    [ValidateRange(1, 90)][int]$RetentionDays = 30
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\..\scripts\Azure.Common.psm1') -Force
Assert-RetailEnvironmentName $EnvironmentName
Assert-RetailEnvironmentName $CheckoutEnvironmentName

$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$groupName = "rg-retailtx-copilot-$EnvironmentName-$Location"
$identityName = "id-retailtx-copilot-$EnvironmentName"
$credentialName = 'github-copilot-environment'
$gitHubEnvironment = 'copilot'
$managedBy = 'retailtx-copilot-cloud-agent'
$checkoutGroupName = "rg-retailtx-checkout-$CheckoutEnvironmentName-$Location"
$statePath = Join-Path $repositoryRoot ".azure\$EnvironmentName\copilot-agent-state.json"
$secretNames = @('AZURE_CLIENT_ID', 'AZURE_TENANT_ID')

function Invoke-Az {
    param([Parameter(Mandatory)][string[]]$Arguments)
    Invoke-RetailAzure -SubscriptionId $SubscriptionId -Arguments $Arguments -TimeoutSeconds 300
}

function Invoke-GitHub {
    param([Parameter(Mandatory)][string[]]$Arguments, [string]$InputText, [switch]$AllowMissing)
    if ($PSBoundParameters.ContainsKey('InputText')) { $output = $InputText | & gh @Arguments 2>&1 }
    else { $output = & gh @Arguments 2>&1 }
    if ($LASTEXITCODE -ne 0) {
        if ($AllowMissing -and ($output -join "`n") -match 'HTTP 404|Not Found') { return $null }
        throw "GitHub CLI failed: gh $($Arguments[0..1] -join ' ')."
    }
    return ($output -join "`n")
}

function Get-OidcSubject {
    <# Build the exact subject GitHub issues for jobs in the copilot environment. #>
    $customization = Invoke-GitHub @('api', "repos/$Repository/actions/oidc/customization/sub") | ConvertFrom-Json
    if (-not $customization.use_default) { throw 'Custom OIDC claim templates are not supported by this script.' }
    $prefix = if ($customization.PSObject.Properties['use_immutable_subject'] -and $customization.use_immutable_subject) {
        $customization.sub_claim_prefix
    } else { "repo:$Repository" }
    if ([string]::IsNullOrWhiteSpace($prefix) -or -not $prefix.StartsWith('repo:')) { throw 'Unexpected OIDC subject prefix.' }
    return "${prefix}:environment:$gitHubEnvironment"
}

function Get-OwnedGroup {
    param([Parameter(Mandatory)][string]$OwnerToken)
    $group = Invoke-Az @('group', 'list', '--query', "[?name=='$groupName'] | [0]")
    if (-not $group) { return $null }
    $tags = $group.tags
    if (-not $tags -or $tags.managedBy -cne $managedBy -or $tags.ownerToken -cne $OwnerToken) {
        throw "Resource group $groupName exists but is not owned by this lifecycle; refusing to adopt or change it."
    }
    return $group
}

function Read-State {
    if (-not (Test-Path -LiteralPath $statePath)) { return $null }
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
    if ($state.subscriptionId -ine $SubscriptionId.ToString() -or $state.groupName -cne $groupName) {
        throw 'Saved state does not match the requested subscription or environment.'
    }
    return $state
}

function Invoke-Configure {
    $state = Read-State
    $ownerToken = if ($state) { $state.ownerToken } else { [guid]::NewGuid().ToString() }
    $subject = Get-OidcSubject
    $tenantId = (Invoke-Az @('account', 'show')).tenantId
    $group = Get-OwnedGroup -OwnerToken $ownerToken
    if (-not $group -and $state) { throw "State exists but $groupName is missing. Run Remove before reconfiguring." }

    if (-not $group -and $PSCmdlet.ShouldProcess($groupName, 'Create owned resource group')) {
        # Persist intent before the first write so an interrupted run can reconcile ownership.
        $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $statePath)
        $state = @{ subscriptionId = $SubscriptionId.ToString(); tenantId = $tenantId; groupName = $groupName
            identityName = $identityName; ownerToken = $ownerToken; repository = $Repository; subject = $subject }
        Save-RetailState -Path $statePath -State $state
        $expiresAt = (Get-Date).ToUniversalTime().AddDays($RetentionDays).ToString('yyyy-MM-ddTHH:mm:ssZ')
        $null = Invoke-Az @('group', 'create', '--name', $groupName, '--location', $Location, '--tags',
            'demo=retailtx', "environmentId=$EnvironmentName", 'profile=copilot-cloud-agent',
            "managedBy=$managedBy", "ownerToken=$ownerToken", "expiresAt=$expiresAt")
    }

    if ($PSCmdlet.ShouldProcess($identityName, 'Create managed identity and federated credential')) {
        $identity = Invoke-Az @('identity', 'list', '--resource-group', $groupName, '--query', "[?name=='$identityName'] | [0]")
        if (-not $identity) {
            $identity = Invoke-Az @('identity', 'create', '--name', $identityName, '--resource-group', $groupName, '--location', $Location)
        }
        $credential = Invoke-Az @('identity', 'federated-credential', 'list', '--identity-name', $identityName,
            '--resource-group', $groupName, '--query', "[?name=='$credentialName'] | [0]")
        if ($credential -and $credential.subject -cne $subject) {
            throw 'Existing federated credential has a different subject; refusing to overwrite it.'
        }
        if (-not $credential) {
            $null = Invoke-Az @('identity', 'federated-credential', 'create', '--name', $credentialName,
                '--identity-name', $identityName, '--resource-group', $groupName,
                '--issuer', 'https://token.actions.githubusercontent.com', '--subject', $subject,
                '--audiences', 'api://AzureADTokenExchange')
        }
        $state.clientId = $identity.clientId
        $state.principalId = $identity.principalId
        Save-RetailState -Path $statePath -State $state
    }

    if ($PSCmdlet.ShouldProcess("$Repository environment $gitHubEnvironment", 'Create environment and set identity secrets')) {
        $null = Invoke-GitHub @('api', '--method', 'PUT', "repos/$Repository/environments/$gitHubEnvironment")
        $values = @{ AZURE_CLIENT_ID = $state.clientId; AZURE_TENANT_ID = $tenantId }
        foreach ($name in $secretNames) {
            # Agents secrets serve Copilot sessions; environment secrets serve manual workflow validation.
            $null = Invoke-GitHub @('secret', 'set', $name, '--repo', $Repository, '--app', 'agents') -InputText $values[$name]
            $null = Invoke-GitHub @('secret', 'set', $name, '--repo', $Repository, '--env', $gitHubEnvironment) -InputText $values[$name]
        }
    }
}

function Invoke-Grant {
    $state = Read-State
    if (-not $state -or -not $state.principalId) { throw 'Run Configure first.' }
    $null = Get-OwnedGroup -OwnerToken $state.ownerToken
    $checkout = Invoke-Az @('group', 'list', '--query', "[?name=='$checkoutGroupName'] | [0]")
    if (-not $checkout) { throw "Checkout resource group $checkoutGroupName does not exist; deploy it first." }
    if ($PSCmdlet.ShouldProcess($checkoutGroupName, 'Assign Reader to the Copilot cloud agent identity')) {
        $null = Invoke-Az @('role', 'assignment', 'create', '--assignee-object-id', $state.principalId,
            '--assignee-principal-type', 'ServicePrincipal', '--role', 'Reader', '--scope', $checkout.id)
    }
}

function Invoke-Check {
    $state = Read-State
    if (-not $state) { throw 'No saved state; run Configure first.' }
    $group = Get-OwnedGroup -OwnerToken $state.ownerToken
    $credential = if ($group) {
        Invoke-Az @('identity', 'federated-credential', 'list', '--identity-name', $identityName,
            '--resource-group', $groupName, '--query', "[?name=='$credentialName'] | [0]")
    }
    $expectedSubject = Get-OidcSubject
    $environment = Invoke-GitHub @('api', "repos/$Repository/environments/$gitHubEnvironment") -AllowMissing
    $agentSecrets = @(Invoke-GitHub @('secret', 'list', '--repo', $Repository, '--app', 'agents', '--json', 'name') | ConvertFrom-Json | ForEach-Object { $_.name })
    $environmentSecrets = if ($environment) {
        @(Invoke-GitHub @('secret', 'list', '--repo', $Repository, '--env', $gitHubEnvironment, '--json', 'name') | ConvertFrom-Json | ForEach-Object { $_.name })
    } else { @() }
    $roles = @(Invoke-Az @('role', 'assignment', 'list', '--assignee', $state.principalId, '--all',
            '--query', '[].{role:roleDefinitionName, scope:scope}'))
    [PSCustomObject]@{
        ResourceGroupOwned      = [bool]$group
        FederatedSubjectMatches = [bool]($credential -and $credential.subject -ceq $expectedSubject)
        GitHubEnvironment       = [bool]$environment
        AgentsSecrets           = -not ($secretNames | Where-Object { $_ -notin $agentSecrets })
        EnvironmentSecrets      = -not ($secretNames | Where-Object { $_ -notin $environmentSecrets })
        RoleAssignments         = @($roles | ForEach-Object { "$($_.role) @ $($_.scope)" })
        OidcLoginVerified       = 'Run the copilot-setup-steps workflow; ARM readback does not prove token exchange.'
    }
}

function Invoke-Remove {
    $state = Read-State
    if (-not $state) { throw 'No saved state; nothing owned to remove.' }
    $group = Get-OwnedGroup -OwnerToken $state.ownerToken
    if ($PSCmdlet.ShouldProcess("$Repository secrets and environment $gitHubEnvironment", 'Delete')) {
        foreach ($name in $secretNames) {
            $null = Invoke-GitHub @('secret', 'delete', $name, '--repo', $Repository, '--app', 'agents') -AllowMissing
        }
        $null = Invoke-GitHub @('api', '--method', 'DELETE', "repos/$Repository/environments/$gitHubEnvironment") -AllowMissing
    }
    if ($group -and $PSCmdlet.ShouldProcess($groupName, 'Delete owned resource group, identity and credential')) {
        # Deleting the identity removes its role assignments' effect; delete them explicitly to avoid orphans.
        $assignments = @(Invoke-Az @('role', 'assignment', 'list', '--assignee', $state.principalId, '--all', '--query', '[].id'))
        if ($assignments.Count -gt 0) { $null = Invoke-Az (@('role', 'assignment', 'delete', '--ids') + $assignments) }
        $null = Invoke-Az @('group', 'delete', '--name', $groupName, '--yes')
    }
    if ($PSCmdlet.ShouldProcess($statePath, 'Delete local state')) { Remove-Item -LiteralPath $statePath -Force }
}

switch ($Action) {
    'Configure' { Invoke-Configure }
    'Grant' { Invoke-Grant }
    'Check' { Invoke-Check }
    'Remove' { Invoke-Remove }
}
