#Requires -Version 7.2
<#
.SYNOPSIS
Lifecycle for the reviewer-gated identity that applies declared checkout price routes.
.DESCRIPTION
Configure creates an owned resource group, a user-assigned managed identity with one federated
credential for GitHub environment 'checkout-deploy', and that environment with a required human
reviewer and a deployment branch policy allowing only demo/checkout. Configure grants no Azure role.
Grant creates a custom role limited to reading and writing web app configuration, assigns it on the
checkout web app only, and stores the app and group names as environment variables. Check reads
everything back. Remove deletes the assignment, role definition, owned group and GitHub environment.
.PARAMETER Action
Configure, Grant, Check or Remove.
.PARAMETER SubscriptionId
The explicit authorized subscription.
.PARAMETER EnvironmentName
Neutral identifier for the identity's owned resource group.
.PARAMETER CheckoutEnvironmentName
Checkout environment whose web app receives the route-writer role with Grant.
.PARAMETER Repository
GitHub repository in owner/name form.
.PARAMETER Reviewer
GitHub login that must approve each deployment. Defaults to the authenticated gh user.
.PARAMETER RetentionDays
Days until the expiresAt tag on the owned resource group.
.EXAMPLE
./scripts/Invoke-CheckoutDeployIdentity.ps1 Configure -SubscriptionId <guid>
.EXAMPLE
./scripts/Invoke-CheckoutDeployIdentity.ps1 Grant -SubscriptionId <guid> -CheckoutEnvironmentName checkout01
.OUTPUTS
PSCustomObject readiness summary for Check; nothing otherwise.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory, Position = 0)][ValidateSet('Configure', 'Grant', 'Check', 'Remove')][string]$Action,
    [Parameter(Mandatory)][guid]$SubscriptionId,
    [string]$EnvironmentName = 'demo01',
    [string]$CheckoutEnvironmentName = 'checkout01',
    [ValidatePattern('^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$')][string]$Repository = 'rutgerpels/retailtx-agentic-ops-demo',
    [ValidatePattern('^[A-Za-z0-9-]{1,39}$')][string]$Reviewer,
    [string]$Location = 'swedencentral',
    [ValidateRange(1, 90)][int]$RetentionDays = 30
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Azure.Common.psm1') -Force
Assert-RetailEnvironmentName $EnvironmentName
Assert-RetailEnvironmentName $CheckoutEnvironmentName

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$groupName = "rg-retailtx-deploy-$EnvironmentName-$Location"
$identityName = "id-retailtx-checkout-deploy-$EnvironmentName"
$credentialName = 'github-checkout-deploy-environment'
$gitHubEnvironment = 'checkout-deploy'
$deployBranch = 'demo/checkout'
$managedBy = 'retailtx-checkout-deploy'
$checkoutGroupName = "rg-retailtx-checkout-$CheckoutEnvironmentName-$Location"
$roleName = "RetailTx checkout route writer ($EnvironmentName)"
$statePath = Join-Path $repositoryRoot ".azure\$EnvironmentName\checkout-deploy-state.json"
$secretNames = @('AZURE_CLIENT_ID', 'AZURE_TENANT_ID', 'AZURE_SUBSCRIPTION_ID')
$variableNames = @('CHECKOUT_RESOURCE_GROUP', 'CHECKOUT_WEBAPP_NAME')
# Enough for 'az webapp config appsettings list/set'; no site lifecycle, code deploy or other resource types.
$roleActions = @('Microsoft.Web/sites/read', 'Microsoft.Web/sites/config/read',
    'Microsoft.Web/sites/config/write', 'Microsoft.Web/sites/config/list/action')

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
    <# Build the exact subject GitHub issues for jobs in the checkout-deploy environment. #>
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

function Get-EnvironmentDefinition {
    <# Required reviewer plus a custom branch policy; the branch itself is added separately. #>
    param([Parameter(Mandatory)][long]$ReviewerId)
    return @{ reviewers = @(@{ type = 'User'; id = $ReviewerId })
        deployment_branch_policy = @{ protected_branches = $false; custom_branch_policies = $true } }
}

function Get-RoleDefinition {
    param([Parameter(Mandatory)][string]$Scope)
    return @{ Name = $roleName; IsCustom = $true
        Description = 'Read and write configuration of one RetailTx checkout web app for declared price routes.'
        Actions = $roleActions; NotActions = @(); DataActions = @(); NotDataActions = @(); AssignableScopes = @($Scope) }
}

function Get-CheckoutWebApp {
    $checkout = Invoke-Az @('group', 'list', '--query', "[?name=='$checkoutGroupName'] | [0]")
    if (-not $checkout) { throw "Checkout resource group $checkoutGroupName does not exist; deploy it first." }
    $apps = @(Invoke-Az @('webapp', 'list', '--resource-group', $checkoutGroupName,
            '--query', "[?tags.component=='checkout-web'].{id:id, name:name}"))
    if ($apps.Count -ne 1) { throw "Expected exactly one checkout-web app in $checkoutGroupName." }
    return @{ group = $checkout; app = $apps[0] }
}

function Invoke-Configure {
    $state = Read-State
    $ownerToken = if ($state) { $state.ownerToken } else { [guid]::NewGuid().ToString() }
    $subject = Get-OidcSubject
    $tenantId = (Invoke-Az @('account', 'show')).tenantId
    $login = if ($Reviewer) { $Reviewer } else { Invoke-GitHub @('api', 'user', '--jq', '.login') }
    $reviewerId = [long](Invoke-GitHub @('api', "users/$login", '--jq', '.id'))
    $group = Get-OwnedGroup -OwnerToken $ownerToken
    if (-not $group -and $state) { throw "State exists but $groupName is missing. Run Remove before reconfiguring." }

    if (-not $group -and $PSCmdlet.ShouldProcess($groupName, 'Create owned resource group')) {
        $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $statePath)
        $state = @{ subscriptionId = $SubscriptionId.ToString(); tenantId = $tenantId; groupName = $groupName
            identityName = $identityName; ownerToken = $ownerToken; repository = $Repository; subject = $subject }
        Save-RetailState -Path $statePath -State $state
        $expiresAt = (Get-Date).ToUniversalTime().AddDays($RetentionDays).ToString('yyyy-MM-ddTHH:mm:ssZ')
        $null = Invoke-Az @('group', 'create', '--name', $groupName, '--location', $Location, '--tags',
            'demo=retailtx', "environmentId=$EnvironmentName", 'profile=checkout-deploy',
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

    if ($PSCmdlet.ShouldProcess("$Repository environment $gitHubEnvironment", 'Create gated environment and set identity secrets')) {
        $body = Get-EnvironmentDefinition -ReviewerId $reviewerId | ConvertTo-Json -Depth 5 -Compress
        $null = Invoke-GitHub @('api', '--method', 'PUT', "repos/$Repository/environments/$gitHubEnvironment", '--input', '-') -InputText $body
        $policies = Invoke-GitHub @('api', "repos/$Repository/environments/$gitHubEnvironment/deployment-branch-policies") | ConvertFrom-Json
        if (-not ($policies.branch_policies | Where-Object { $_.name -ceq $deployBranch -and $_.type -ceq 'branch' })) {
            $null = Invoke-GitHub @('api', '--method', 'POST', "repos/$Repository/environments/$gitHubEnvironment/deployment-branch-policies",
                '-f', "name=$deployBranch", '-f', 'type=branch')
        }
        $values = @{ AZURE_CLIENT_ID = $state.clientId; AZURE_TENANT_ID = $tenantId; AZURE_SUBSCRIPTION_ID = $SubscriptionId.ToString() }
        foreach ($name in $secretNames) {
            $null = Invoke-GitHub @('secret', 'set', $name, '--repo', $Repository, '--env', $gitHubEnvironment) -InputText $values[$name]
        }
        $state.reviewer = $login
        Save-RetailState -Path $statePath -State $state
    }
}

function Invoke-Grant {
    $state = Read-State
    if (-not $state -or -not $state.principalId) { throw 'Run Configure first.' }
    $null = Get-OwnedGroup -OwnerToken $state.ownerToken
    $target = Get-CheckoutWebApp
    if ($PSCmdlet.ShouldProcess($target.app.name, "Assign '$roleName' to the checkout deploy identity")) {
        $existing = @(Invoke-Az @('role', 'definition', 'list', '--custom-role-only', 'true', '--name', $roleName))
        $definition = Get-RoleDefinition -Scope $target.group.id
        $file = New-TemporaryFile
        try {
            if ($existing.Count -gt 0) { $definition.Id = $existing[0].name }
            Set-Content -LiteralPath $file -Value ($definition | ConvertTo-Json -Depth 5) -Encoding utf8NoBOM
            $verb = if ($existing.Count -gt 0) { 'update' } else { 'create' }
            $null = Invoke-Az @('role', 'definition', $verb, '--role-definition', "@$file")
        } finally { Remove-Item -LiteralPath $file -Force }
        $null = Invoke-Az @('role', 'assignment', 'create', '--assignee-object-id', $state.principalId,
            '--assignee-principal-type', 'ServicePrincipal', '--role', $roleName, '--scope', $target.app.id)
        $null = Invoke-GitHub @('variable', 'set', 'CHECKOUT_RESOURCE_GROUP', '--repo', $Repository, '--env', $gitHubEnvironment,
            '--body', $checkoutGroupName)
        $null = Invoke-GitHub @('variable', 'set', 'CHECKOUT_WEBAPP_NAME', '--repo', $Repository, '--env', $gitHubEnvironment,
            '--body', $target.app.name)
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
    $environmentJson = Invoke-GitHub @('api', "repos/$Repository/environments/$gitHubEnvironment") -AllowMissing
    $environment = if ($environmentJson) { $environmentJson | ConvertFrom-Json } else { $null }
    $reviewers = @(if ($environment) {
        @($environment.protection_rules | Where-Object { $_.type -ceq 'required_reviewers' } |
            ForEach-Object { $_.reviewers } | ForEach-Object { $_.reviewer.login })
    } else { @() })
    $branches = @(if ($environment) {
        @((Invoke-GitHub @('api', "repos/$Repository/environments/$gitHubEnvironment/deployment-branch-policies") |
                ConvertFrom-Json).branch_policies | ForEach-Object { $_.name })
    } else { @() })
    $secrets = @(if ($environment) {
        @(Invoke-GitHub @('secret', 'list', '--repo', $Repository, '--env', $gitHubEnvironment, '--json', 'name') | ConvertFrom-Json | ForEach-Object { $_.name })
    } else { @() })
    $variables = @(if ($environment) {
        @(Invoke-GitHub @('variable', 'list', '--repo', $Repository, '--env', $gitHubEnvironment, '--json', 'name') | ConvertFrom-Json | ForEach-Object { $_.name })
    } else { @() })
    $role = @(Invoke-Az @('role', 'definition', 'list', '--custom-role-only', 'true', '--name', $roleName)) | Select-Object -First 1
    $roleActual = if ($role) { @($role.permissions[0].actions | Sort-Object) -join ',' } else { '' }
    $roles = @(Invoke-Az @('role', 'assignment', 'list', '--assignee', $state.principalId, '--all',
            '--query', '[].{role:roleDefinitionName, scope:scope}'))
    [PSCustomObject]@{
        ResourceGroupOwned      = [bool]$group
        FederatedSubjectMatches = [bool]($credential -and $credential.subject -ceq (Get-OidcSubject))
        RequiredReviewers       = $reviewers
        BranchPolicyOnly        = ($branches.Count -eq 1 -and $branches[0] -ceq $deployBranch)
        EnvironmentSecrets      = -not ($secretNames | Where-Object { $_ -notin $secrets })
        EnvironmentVariables    = -not ($variableNames | Where-Object { $_ -notin $variables })
        RoleActionsExact        = ($roleActual -ceq (($roleActions | Sort-Object) -join ','))
        RoleAssignments         = @($roles | ForEach-Object { "$($_.role) @ $($_.scope)" })
        DeployVerified          = 'Run Checkout Routes Deploy on demo/checkout and approve; readback does not prove token exchange.'
    }
}

function Invoke-Remove {
    $state = Read-State
    if (-not $state) { throw 'No saved state; nothing owned to remove.' }
    $group = Get-OwnedGroup -OwnerToken $state.ownerToken
    if ($PSCmdlet.ShouldProcess("$Repository environment $gitHubEnvironment", 'Delete environment, secrets and variables')) {
        $null = Invoke-GitHub @('api', '--method', 'DELETE', "repos/$Repository/environments/$gitHubEnvironment") -AllowMissing
    }
    if ($PSCmdlet.ShouldProcess($roleName, 'Delete role assignments and custom role definition')) {
        if ($state.principalId) {
            $assignments = @(Invoke-Az @('role', 'assignment', 'list', '--assignee', $state.principalId, '--all', '--query', '[].id'))
            if ($assignments.Count -gt 0) { $null = Invoke-Az (@('role', 'assignment', 'delete', '--ids') + $assignments) }
        }
        $existing = @(Invoke-Az @('role', 'definition', 'list', '--custom-role-only', 'true', '--name', $roleName))
        if ($existing.Count -gt 0) { $null = Invoke-Az @('role', 'definition', 'delete', '--name', $roleName) }
    }
    if ($group -and $PSCmdlet.ShouldProcess($groupName, 'Delete owned resource group, identity and credential')) {
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
