#Requires -Version 7.2
<#
.SYNOPSIS
Publish the original OrderFlow portal from a reviewer-gated GitHub job.
.DESCRIPTION
Checks the exact source digest and owned application tags before publishing.
This cannot deploy infrastructure, configure SRE or inject/repair a fault.
.EXAMPLE
.\scenarios\orderflow\scripts\Publish-OrderFlow.ps1 -SubscriptionId <guid> -ResourceGroup <group> -WebAppName <app> -OwnerToken <guid> -SourceHash <sha256>
.OUTPUTS
Publication confirmation; no secrets or application identifiers.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][guid]$SubscriptionId,
    [Parameter(Mandatory)][ValidatePattern('^rg-orderflow-[a-z][a-z0-9]{2,11}$')][string]$ResourceGroup,
    [Parameter(Mandatory)][ValidatePattern('^portal-of-[a-z0-9-]+$')][string]$WebAppName,
    [Parameter(Mandatory)][guid]$OwnerToken,
    [Parameter(Mandatory)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$SourceHash
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'OrderFlow.Common.psm1') -Force
$state = @{
    subscriptionId = $SubscriptionId.ToString(); resourceGroup = $ResourceGroup
    sourceHash = $SourceHash; outputs = @{ webAppName = $WebAppName }
}
if ($SourceHash -ine (Get-OrderFlowSourceHash)) { throw 'Source is not the provisioned generation. Do not mix a new portal with an old VM.' }
$app = Invoke-OrderFlowAzure $state @('webapp', 'show', '--resource-group', $ResourceGroup, '--name', $WebAppName)
if ($app.tags.ownerToken -cne $OwnerToken.ToString() -or $app.tags.scenario -cne 'orderflow' -or
    $app.tags.managedBy -cne 'invoke-orderflow') { throw 'Application ownership does not match the approved environment.' }
if (-not $PSCmdlet.ShouldProcess($WebAppName, 'Publish original portal artifact')) { return }
$directory = Join-Path ([IO.Path]::GetTempPath()) "orderflow-publish-$([guid]::NewGuid().ToString('N'))"
$null = New-Item -ItemType Directory -Path $directory
try {
    Publish-OrderFlowPortal $state $directory
} finally {
    # Publish-OrderFlowPortal removes its one ZIP; never recursively delete runner folders.
    Remove-Item -LiteralPath $directory
}
Write-Output 'Portal publication returned successfully. Verify fresh customer requests separately.'
