#Requires -Version 7.2
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:scenarioRoot = Split-Path -Parent $PSScriptRoot
$script:repositoryRoot = Split-Path -Parent (Split-Path -Parent $script:scenarioRoot)
Import-Module (Join-Path $script:repositoryRoot 'scripts\Azure.Common.psm1') -Force

function Invoke-OrderFlowAzure {
    param([hashtable]$State, [string[]]$Arguments, [int]$TimeoutSeconds = 120)
    Invoke-RetailAzure -SubscriptionId $State.subscriptionId -Arguments $Arguments -TimeoutSeconds $TimeoutSeconds
}

function Get-OrderFlowBaseline {
    Get-Content (Join-Path $script:scenarioRoot 'infra\network-baseline.json') -Raw | ConvertFrom-Json -AsHashtable
}

function Assert-OrderFlowCidr {
    param([string]$Cidr)
    if ($Cidr -notmatch '^(\d{1,3}\.){3}\d{1,3}/(\d{1,2})$') { throw 'PresenterCidr must be an IPv4 CIDR.' }
    $parts = $Cidr.Split('/')
    $address = $null
    if (-not [Net.IPAddress]::TryParse($parts[0], [ref]$address) -or
        $address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or
        [int]$parts[1] -lt 24 -or [int]$parts[1] -gt 32) {
        throw 'PresenterCidr must be a narrow IPv4 range (/24 through /32); prefer /32.'
    }
}

function Get-OrderFlowSourceHash {
    $inputs = @('app/backend.py', 'app/common.py', 'app/portal.py', 'app/requirements.txt',
        'app/static/index.html', 'app/static/styles.css', 'app/static/app.js',
        'infra/main.bicep', 'infra/sre.bicep', 'infra/cloud-init.yml', 'infra/network-baseline.json')
    $lines = foreach ($relative in ($inputs | Sort-Object)) {
        $path = Join-Path $script:scenarioRoot $relative.Replace('/', [IO.Path]::DirectorySeparatorChar)
        $text = [IO.File]::ReadAllText($path).Replace("`r`n", "`n")
        $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($text)))
        "$relative $hash"
    }
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($lines -join "`n")))
}

function Save-OrderFlowState {
    param([hashtable]$State, [string]$Path)
    Save-RetailState -State $State -Path $Path
}

function Enter-OrderFlowLock {
    param([string]$Directory)
    $null = New-Item -ItemType Directory -Force -Path $Directory
    try {
        return [IO.File]::Open((Join-Path $Directory 'operation.lock'), [IO.FileMode]::OpenOrCreate,
            [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    } catch [IO.IOException] {
        throw 'Another lifecycle process holds this environment lock. Wait; do not remove its lock file.'
    }
}

function Assert-OrderFlowState {
    param([hashtable]$State, [guid]$SubscriptionId, [string]$EnvironmentName)
    if ($State.schemaVersion -ne 1 -or $State.scenario -cne 'orderflow' -or
        $State.subscriptionId -ine $SubscriptionId.ToString() -or
        $State.environmentName -cne $EnvironmentName -or
        $State.resourceGroup -cne "rg-orderflow-$EnvironmentName" -or
        -not ($State.ownerToken -as [guid])) { throw 'Invalid or mismatched OrderFlow ownership state.' }
    $groupId = "/subscriptions/$SubscriptionId/resourceGroups/$($State.resourceGroup)"
    foreach ($key in @('webAppId', 'vmId', 'nsgId', 'ruleId', 'workspaceId', 'alertId', 'agentId', 'sreIdentityId', 'repairAssignmentId')) {
        if ($State.outputs[$key] -and -not $State.outputs[$key].StartsWith("$groupId/providers/", [StringComparison]::OrdinalIgnoreCase)) {
            throw "Output $key is outside the owned resource group."
        }
    }
}

function Assert-OrderFlowOwner {
    param([hashtable]$State)
    $group = Invoke-OrderFlowAzure $State @('group', 'show', '--name', $State.resourceGroup)
    if ($group.tags.ownerToken -cne $State.ownerToken -or $group.tags.scenario -cne 'orderflow' -or
        $group.tags.managedBy -cne 'invoke-orderflow') { throw 'Resource group ownership mismatch; refusing adoption.' }
    if ($group.properties.provisioningState -cne 'Succeeded') { throw 'Resource group is not in Succeeded state.' }
}

function Assert-OrderFlowAction {
    param([hashtable]$State, [string]$Action)
    if ($State.phase -ceq 'removed') { throw 'This generation is retired. Use a new environment identifier.' }
    if ($State.pendingOperation -and $Action -cne 'Observe') {
        throw "Pending/unknown operation: $($State.pendingOperation). Observe it; no automatic replay."
    }
    if ($State.phase -ceq 'deployment-failed' -and $Action -notin @('Observe', 'Down')) {
        throw 'Terminal deployment failure: cleanup only. Never replay provisioning or admit a fault.'
    }
    if ($Action -in @('Publish', 'ConfigureSre', 'Ready', 'Fault') -and $State.fault) {
        throw 'This generation has already admitted a fault. Observe/Undo/Verify/Down only.'
    }
}

function Invoke-OrderFlowRequest {
    param([hashtable]$State, [string]$Uri, [string]$Audience = 'https://management.azure.com/',
        [ValidateSet('GET', 'PUT', 'DELETE')][string]$Method = 'GET',
        [hashtable]$Body, [switch]$AllowMissing, [switch]$Raw, [string]$IfMatch)
    $target = [uri]$Uri
    if ($target.Scheme -cne 'https' -or $target.UserInfo -or -not $target.IsDefaultPort -or
        ($Audience -ceq 'https://management.azure.com/' -and $target.Host -cne 'management.azure.com') -or
        ($Audience -ceq 'https://azuresre.dev' -and -not $target.Host.EndsWith('.azuresre.ai'))) {
        throw 'Unexpected authenticated endpoint.'
    }
    $credential = Invoke-OrderFlowAzure $State @('account', 'get-access-token', '--resource', $Audience)
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

function Get-OrderFlowRule {
    param([hashtable]$State)
    Invoke-OrderFlowRequest $State "https://management.azure.com$($State.outputs.ruleId)?api-version=2024-05-01"
}

function Assert-OrderFlowRule {
    param([hashtable]$Rule, [hashtable]$Expected)
    if ($Rule.properties.provisioningState -cne 'Succeeded') { throw 'NSG rule has not reached Succeeded.' }
    foreach ($key in $Expected.Keys) {
        if ([string]$Rule.properties[$key] -cne [string]$Expected[$key]) { throw "NSG rule differs from expected $key." }
    }
    foreach ($key in @('sourceAddressPrefixes', 'destinationAddressPrefixes', 'sourcePortRanges',
        'destinationPortRanges', 'sourceApplicationSecurityGroups', 'destinationApplicationSecurityGroups')) {
        if (@($Rule.properties[$key] | Where-Object { $null -ne $_ }).Count) { throw "Unexpected plural rule field $key." }
    }
}

function Get-OrderFlowProbe {
    param([hashtable]$State)
    $started = [DateTimeOffset]::UtcNow
    $response = Invoke-WebRequest "$($State.outputs.webAppUrl)/api/health" -TimeoutSec 12 `
        -MaximumRedirection 0 -SkipHttpErrorCheck
    $body = $response.Content | ConvertFrom-Json -AsHashtable
    @{
        observedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        durationMs = [int]([DateTimeOffset]::UtcNow - $started).TotalMilliseconds
        statusCode = [int]$response.StatusCode
        healthy = ($response.StatusCode -eq 200 -and $body.status -ceq 'healthy')
    }
}

function Assert-OrderFlowHealthy {
    param([hashtable]$State)
    for ($i = 0; $i -lt 3; $i++) {
        $probe = Get-OrderFlowProbe $State
        if (-not $probe.healthy) { throw 'Fresh portal-to-Cosmos health probe failed; no fault admitted.' }
        Start-Sleep -Seconds 2
    }
}

function Get-OrderFlowDeployment {
    param([hashtable]$State)
    Invoke-OrderFlowAzure $State @('deployment', 'group', 'show', '--resource-group', $State.resourceGroup,
        '--name', $State.deploymentName)
}

function Assert-OrderFlowInventory {
    param([hashtable]$State)
    $resources = @(Invoke-OrderFlowAzure $State @('resource', 'list', '--resource-group', $State.resourceGroup))
    $diskId = ''
    if ($State.outputs['vmId']) {
        $vm = Invoke-OrderFlowRequest $State "https://management.azure.com$($State.outputs.vmId)?api-version=2024-07-01" -AllowMissing
        if ($vm) {
            if ($vm.tags.ownerToken -cne $State.ownerToken) { throw 'VM ownership mismatch.' }
            $diskId = $vm.properties.storageProfile.osDisk.managedDisk.id
        }
    }
    foreach ($resource in $resources) {
        if ($resource['tags'] -and $resource.tags['ownerToken'] -ceq $State.ownerToken -and
            $resource.tags['scenario'] -ceq 'orderflow') { continue }
        # Compute-created OS disks do not inherit VM tags; verify the exact live parent relationship.
        if ($diskId -and $resource.id -ieq $diskId -and $resource.type -ieq 'Microsoft.Compute/disks') {
            $disk = Invoke-OrderFlowRequest $State "https://management.azure.com$diskId`?api-version=2024-03-02"
            if ($disk.managedBy -ieq $State.outputs.vmId) { continue }
        }
        throw "Unowned resource in group ($($resource.type)); refusing group deletion."
    }
}

function Assert-OrderFlowRoleAbsent {
    param([hashtable]$State)
    if ($State.outputs['repairRoleId']) {
        $role = Invoke-OrderFlowRequest $State "https://management.azure.com$($State.outputs.repairRoleId)?api-version=2022-04-01" -AllowMissing
        if ($role) { throw 'Owned custom role still exists; teardown is not complete.' }
    }
}

function Update-OrderFlowOutputs {
    param([hashtable]$State)
    $deployment = Get-OrderFlowDeployment $State
    if ($deployment.properties.provisioningState -cin @('Failed', 'Canceled')) {
        $operations = @(Invoke-OrderFlowAzure $State @('deployment', 'operation', 'group', 'list',
            '--resource-group', $State.resourceGroup, '--name', $State.deploymentName))
        if (@($operations | Where-Object { $_.properties.provisioningState -cnotin @('Succeeded', 'Failed', 'Canceled') }).Count) {
            throw 'Deployment has nonterminal operations; keep observing, no cleanup admission.'
        }
        # All nested deployments must be terminal before discovering a cleanup-only inventory.
        $nested = @(Invoke-OrderFlowAzure $State @('deployment', 'group', 'list', '--resource-group', $State.resourceGroup))
        if (@($nested | Where-Object { $_.properties.provisioningState -cnotin @('Succeeded', 'Failed', 'Canceled') }).Count) {
            throw 'Nested deployment still active or unknown; cleanup remains blocked.'
        }
        Set-OrderFlowPartialOutputs $State
        $State.failure = @{
            observedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
            deploymentState = $deployment.properties.provisioningState
        }
        $State.pendingOperation = $null
        $State.phase = 'deployment-failed'
        return
    }
    if ($deployment.properties.provisioningState -cne 'Succeeded') {
        throw "Deployment is $($deployment.properties.provisioningState). Observe; do not replay Up."
    }
    foreach ($key in $deployment.properties.outputs.Keys) { $State.outputs[$key] = $deployment.properties.outputs[$key].value }
    $State.pendingOperation = $null
    $State.phase = 'provisioned'
}

function Set-OrderFlowPartialOutputs {
    param([hashtable]$State)
    $resources = @(Invoke-OrderFlowAzure $State @('resource', 'list', '--resource-group', $State.resourceGroup))
    $owned = @($resources | Where-Object { $_['tags'] -and $_.tags['ownerToken'] -ceq $State.ownerToken -and
        $_.tags['scenario'] -ceq 'orderflow' })
    foreach ($entry in @{
        vmId = 'Microsoft.Compute/virtualMachines'; agentId = 'Microsoft.App/agents'
        nsgId = 'Microsoft.Network/networkSecurityGroups'
    }.GetEnumerator()) {
        $matches = @($owned | Where-Object { $_.type -ieq $entry.Value })
        if ($matches.Count -gt 1) { throw 'Ambiguous partial deployment inventory.' }
        if ($matches.Count -eq 1) { $State.outputs[$entry.Key] = $matches[0].id }
    }
    if ($State.outputs['nsgId']) { $State.outputs.ruleId = "$($State.outputs.nsgId)/securityRules/PortalToOrderApi" }
    $identities = @($owned | Where-Object {
        $_.type -ieq 'Microsoft.ManagedIdentity/userAssignedIdentities' -and $_.name -clike "id-sre-of-$($State.environmentName)-*"
    })
    if ($identities.Count -gt 1) { throw 'Ambiguous SRE identity in partial deployment.' }
    if ($identities.Count -eq 1) {
        $identity = Invoke-OrderFlowRequest $State "https://management.azure.com$($identities[0].id)?api-version=2023-01-31"
        $State.outputs.sreIdentityId = $identity.id
        $State.outputs.srePrincipalId = $identity.properties.principalId
        $stem = $identities[0].name.Substring('id-sre-'.Length)
        $groupId = "/subscriptions/$($State.subscriptionId)/resourceGroups/$($State.resourceGroup)"
        $roles = @(Invoke-OrderFlowAzure $State @('role', 'definition', 'list', '--scope', $groupId, '--custom-role-only', 'true'))
        $matches = @($roles | Where-Object {
            $_.roleName -ceq "OrderFlow rule repair $stem" -and ($_.assignableScopes -join ',') -ieq $groupId
        })
        if ($matches.Count -gt 1) { throw 'Ambiguous partial repair role.' }
        if ($matches.Count -eq 1) {
            $State.outputs.repairRoleId = "/subscriptions/$($State.subscriptionId)/providers/Microsoft.Authorization/roleDefinitions/$($matches[0].name)"
            if (-not $State.outputs['ruleId']) { throw 'Repair role without an owned NSG cannot be safely reconciled.' }
            $grants = @(Invoke-OrderFlowAzure $State @('role', 'assignment', 'list', '--scope', $State.outputs.ruleId, '--all'))
            $matches = @($grants | Where-Object { $_.principalId -ieq $State.outputs.srePrincipalId -and
                ($_.roleDefinitionId -split '/')[-1] -ieq ($State.outputs.repairRoleId -split '/')[-1] -and
                $_.scope -ieq $State.outputs.ruleId })
            if ($matches.Count -gt 1) { throw 'Ambiguous partial repair assignment.' }
            if ($matches.Count -eq 1) { $State.outputs.repairAssignmentId = $matches[0].id }
            else { $State.cleanup.assignmentRemoved = $true }
        }
    }
}

function Publish-OrderFlowPortal {
    param([hashtable]$State, [string]$Directory)
    if ($State.sourceHash -ine (Get-OrderFlowSourceHash)) { throw 'App/infra changed since provisioning; use a new environment generation.' }
    $package = Join-Path $Directory 'portal.zip'
    $sources = @('portal.py', 'common.py', 'requirements.txt', 'static') | ForEach-Object { Join-Path $script:scenarioRoot "app\$_" }
    Compress-Archive -Path $sources -DestinationPath $package -Force
    try {
        $null = Invoke-OrderFlowAzure $State @('webapp', 'deploy', '--resource-group', $State.resourceGroup,
            '--name', $State.outputs.webAppName, '--src-path', $package, '--type', 'zip') -TimeoutSeconds 1200
    } finally { Remove-Item -LiteralPath $package -Force }
}

Export-ModuleMember -Function *-OrderFlow*
