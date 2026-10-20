// Belgium checkout-latency demo: Azure front end, simulated on-premises price
// backend, Azure Monitor alerting, Observability Agent and one SRE Agent.
targetScope = 'subscription'

@minLength(3)
@maxLength(12)
param environmentName string
param location string = 'swedencentral'
@description('Observability Agent and Azure Monitor workspace region (preview availability).')
param observabilityLocation string = 'westeurope'
@description('Alert email recipient. Supplied at deployment time; never committed.')
param alertEmail string
@description('Object ID of the presenter who receives SRE Agent Administrator and approves actions.')
param adminObjectId string
param adminPrincipalType string = 'User'
@description('SSH public key for the simulated datacenter VM. Generated locally; break-glass only.')
param adminPublicKey string
@description('Create the subscription default Azure Monitor workspace setting. Only when absent.')
param createMonitorSettings bool = false
param expiresAt string
@description('Opt in to the Arc-backed combined-scenario integration gate.')
param enableArc bool = false
@description('Temporary onboarding identity; removed after Arc registration.')
param bootstrapArc bool = false
param ownerToken string
param onboardingClientId string = ''
@description('Deploy the scripted SRE Agent. False leaves it for manual portal configuration.')
param deploySre bool = true
@description('Deploy the Observability Agent and its Azure Monitor workspace.')
param deployObservability bool = true
param profileName string = 'checkout-latency'
param managedByName string = 'invoke-checkoutdemo'

var groupName = 'rg-retailtx-checkout-${environmentName}-${location}'
var tags = {
  demo: 'retailtx'
  environmentId: environmentName
  profile: profileName
  managedBy: managedByName
  expiresAt: expiresAt
  ownerToken: ownerToken
}

resource group 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: groupName
  location: location
  tags: tags
}

module estate 'checkout.bicep' = {
  scope: group
  name: 'checkout-estate'
  params: {
    environmentName: environmentName
    location: location
    observabilityLocation: observabilityLocation
    tags: tags
    alertEmail: alertEmail
    adminObjectId: adminObjectId
    adminPrincipalType: adminPrincipalType
    adminPublicKey: adminPublicKey
    enableArc: enableArc
    bootstrapArc: bootstrapArc
    ownerToken: ownerToken
    onboardingClientId: onboardingClientId
    deploySre: deploySre
    deployObservability: deployObservability
  }
}

module observabilityReader 'subscription-reader.bicep' = if (deployObservability) {
  name: 'checkout-oba-reader-${environmentName}'
  params: {
    principalId: estate.outputs.observabilityPrincipalId
  }
}

module sreMonitoring 'sre-monitoring.bicep' = if (enableArc && deploySre) {
  name: 'checkout-sre-monitoring-${environmentName}'
  params: { principalId: estate.outputs.srePrincipalId }
}

module monitorSettings 'monitor-settings.bicep' = if (createMonitorSettings && deployObservability) {
  name: 'checkout-monitor-settings-${environmentName}'
  params: {
    monitorWorkspaceId: estate.outputs.monitorWorkspaceId
  }
}

output resourceGroupName string = group.name
output resourceGroupId string = group.id
output webAppName string = estate.outputs.webAppName
output webAppUrl string = estate.outputs.webAppUrl
output appInsightsId string = estate.outputs.appInsightsId
output appInsightsName string = estate.outputs.appInsightsName
output workspaceId string = estate.outputs.workspaceId
output workspaceCustomerId string = estate.outputs.workspaceCustomerId
output alertRuleId string = estate.outputs.alertRuleId
output alertRuleName string = estate.outputs.alertRuleName
output actionGroupId string = estate.outputs.actionGroupId
output serviceAlertRuleName string = estate.outputs.serviceAlertRuleName
output serviceAlertRuleId string = estate.outputs.serviceAlertRuleId
output vmName string = estate.outputs.vmName
output vmId string = estate.outputs.vmId
output arcMachineName string = estate.outputs.arcMachineName
output arcMachineId string = estate.outputs.arcMachineId
output bootstrapIdentityId string = estate.outputs.bootstrapIdentityId
output bootstrapRoleId string = estate.outputs.bootstrapRoleId
output srePrincipalId string = estate.outputs.srePrincipalId
output sreIdentityId string = estate.outputs.sreIdentityId
output onboardingClientId string = estate.outputs.onboardingClientId
output agentName string = estate.outputs.agentName
output agentId string = estate.outputs.agentId
output agentEndpoint string = estate.outputs.agentEndpoint
output observabilityAgentId string = estate.outputs.observabilityAgentId
output monitorWorkspaceId string = estate.outputs.monitorWorkspaceId
output observabilityReaderAssignmentId string = deployObservability ? observabilityReader!.outputs.assignmentId : ''
output sreMonitoringAssignmentId string = enableArc && deploySre ? sreMonitoring!.outputs.assignmentId : ''
