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

var groupName = 'rg-retailtx-checkout-${environmentName}-${location}'
var tags = {
  demo: 'retailtx'
  environmentId: environmentName
  profile: 'checkout-latency'
  managedBy: 'invoke-checkoutdemo'
  expiresAt: expiresAt
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
  }
}

module observabilityReader 'subscription-reader.bicep' = {
  name: 'checkout-oba-reader-${environmentName}'
  params: {
    principalId: estate.outputs.observabilityPrincipalId
  }
}

module monitorSettings 'monitor-settings.bicep' = if (createMonitorSettings) {
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
output vmName string = estate.outputs.vmName
output agentName string = estate.outputs.agentName
output agentId string = estate.outputs.agentId
output agentEndpoint string = estate.outputs.agentEndpoint
output observabilityAgentId string = estate.outputs.observabilityAgentId
output monitorWorkspaceId string = estate.outputs.monitorWorkspaceId
output observabilityReaderAssignmentId string = observabilityReader.outputs.assignmentId
