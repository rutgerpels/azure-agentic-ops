#Requires -Version 7.2
<#
.SYNOPSIS
Check or apply the declared checkout price routes on the live web app.
.DESCRIPTION
scenarios/retailx/infra/checkout/price-routes.json is the source of truth. Check reports drift; Apply sets only drifted
route keys and verifies the result. Only the three route keys are read, so no other app setting
(for example the Application Insights connection string) leaves Azure CLI or reaches the log.
.PARAMETER Action
Check or Apply.
.PARAMETER SubscriptionId
Subscription that holds the checkout web app.
.PARAMETER ResourceGroup
Checkout resource group (from the GitHub environment variable, not discovery).
.PARAMETER WebAppName
Checkout web app name.
.PARAMETER RoutesPath
Declared routes file.
.EXAMPLE
./scenarios/retailx/scripts/Sync-CheckoutRoutes.ps1 Check -SubscriptionId <guid> -ResourceGroup <rg> -WebAppName <app>
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory, Position = 0)][ValidateSet('Check', 'Apply')][string]$Action,
    [Parameter(Mandatory)][guid]$SubscriptionId,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._()-]{1,90}$')][string]$ResourceGroup,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9-]{2,60}$')][string]$WebAppName,
    [string]$RoutesPath = (Join-Path $PSScriptRoot '../infra/checkout/price-routes.json')
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\..\scripts\Azure.Common.psm1') -Force

$routeKeys = @('PRICE_ROUTE_BE', 'PRICE_ROUTE_NL', 'ROUTE_CHANGE_REF')

function Read-DeclaredRoute {
    <# Parse and strictly validate the declared routes; unknown or missing keys are rejected. #>
    param([Parameter(Mandatory)][string]$Path)
    $routes = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
    if ($routes -isnot [hashtable]) { throw 'price-routes.json must be a JSON object.' }
    $keys = @($routes.Keys | Sort-Object -CaseSensitive) -join ','
    if ($keys -cne (($routeKeys | Sort-Object -CaseSensitive) -join ',')) {
        throw "price-routes.json must declare exactly: $($routeKeys -join ', ')."
    }
    foreach ($country in 'BE', 'NL') {
        if ($routes["PRICE_ROUTE_$country"] -isnot [string] -or $routes["PRICE_ROUTE_$country"] -cnotin 'primary', 'legacy') {
            throw "PRICE_ROUTE_$country must be primary or legacy."
        }
    }
    if ($routes.ROUTE_CHANGE_REF -isnot [string] -or $routes.ROUTE_CHANGE_REF -cnotmatch '^[A-Za-z0-9._-]{1,64}$') {
        throw 'ROUTE_CHANGE_REF must be 1-64 letters, digits, dot, underscore or hyphen.'
    }
    return $routes
}

function Get-LiveRoute {
    <# Query only the route keys; values for other settings are never requested. #>
    $query = "[?name=='PRICE_ROUTE_BE' || name=='PRICE_ROUTE_NL' || name=='ROUTE_CHANGE_REF'].{name:name,value:value}"
    $live = @{}
    foreach ($item in @(Invoke-RetailAzure -SubscriptionId $SubscriptionId -Arguments @(
                'webapp', 'config', 'appsettings', 'list', '--resource-group', $ResourceGroup, '--name', $WebAppName, '--query', $query))) {
        if ($item -and $item.name -cin $routeKeys) { $live[$item.name] = [string]$item.value }
    }
    return $live
}

function Get-RouteDrift {
    param([Parameter(Mandatory)][hashtable]$Declared, [Parameter(Mandatory)][hashtable]$Live)
    return @($routeKeys | Where-Object { -not $Live.ContainsKey($_) -or $Live[$_] -cne $Declared[$_] })
}

function Write-RouteSummary {
    <# Route values are non-sensitive demo configuration and safe for the job summary. #>
    param([hashtable]$Declared, [hashtable]$Live, [string[]]$Drift, [string]$Outcome)
    $lines = @("### Checkout price routes: $Outcome", '', '| Setting | Declared | Live |', '|---|---|---|')
    foreach ($key in $routeKeys) {
        $observed = if ($Live.ContainsKey($key)) { $Live[$key] } else { '(missing)' }
        $marker = if ($key -cin $Drift) { ' (drift)' } else { '' }
        $lines += "| ``$key`` | ``$($Declared[$key])`` | ``$observed``$marker |"
    }
    $lines | ForEach-Object { Write-Information $_ -InformationAction Continue }
    if ($env:GITHUB_STEP_SUMMARY) { Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value ($lines -join "`n") }
}

$declared = Read-DeclaredRoute $RoutesPath
$live = Get-LiveRoute
$drift = Get-RouteDrift $declared $live
if ($Action -eq 'Check') {
    Write-RouteSummary $declared $live $drift $(if ($drift) { 'drift detected' } else { 'in sync' })
    if ($drift) { throw "Live checkout routes differ from price-routes.json: $($drift -join ', ')." }
    return
}
if (-not $drift) { Write-RouteSummary $declared $live $drift 'already in sync'; return }
if ($PSCmdlet.ShouldProcess($WebAppName, "Set $($drift -join ', ') from price-routes.json")) {
    $null = Invoke-RetailAzure -SubscriptionId $SubscriptionId -Arguments (@(
            'webapp', 'config', 'appsettings', 'set', '--resource-group', $ResourceGroup, '--name', $WebAppName,
            '--query', '[0].name', '--settings') + @($drift | ForEach-Object { "$_=$($declared[$_])" }))
    $after = Get-LiveRoute
    $remaining = Get-RouteDrift $declared $after
    Write-RouteSummary $declared $after $remaining $(if ($remaining) { 'apply failed' } else { 'applied' })
    if ($remaining) { throw "Route apply did not converge: $($remaining -join ', ')." }
}
